#!/bin/bash
# Smoke-tests ways to install Whalebridge end to end in a throwaway macOS VM:
# the Homebrew cask (cap10morgan/brew/whalebridge), the manual zip download
# from the GitHub releases page (README's "Installation" section), and
# optionally a "local" method that builds and installs the current working
# tree instead of a published release — see METHODS below. Each gets its own
# VM, installs the way a real user would (including clearing Gatekeeper's
# unnotarized-app block), launches the actual menu-bar app, and drives the
# Docker API it exposes through the real "whalebridge" docker context.
#
# This complements — doesn't replace — the `integration` job in
# .github/workflows/ci.yml, which tests the daemon/API contract directly
# (raw socktainer binary, hand-wired socket symlink) but never touches any
# install path, Gatekeeper, or the real app.
#
# Requires tart (`brew install cirruslabs/cli/tart`) and, once, running
# `make vm-golden-image` — see scripts/vm-build-golden-image.sh for why: a
# stock Cirrus base image clone can intermittently hang forever on macOS
# Tahoe 26.4+ (openai/tart#1222), so this clones from a local image that's
# already had that fixed rather than Cirrus's stock one directly.
#
# Scope: stops at `container create`/`pull`, same as the integration job —
# booting a container needs a second level of virtualization (this host ->
# this VM -> apple/container's per-container VM), which requires M3+ Apple
# Silicon.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_IMAGE="${BASE_IMAGE:-whalebridge-tahoe-golden}"
CASK="${CASK:-cap10morgan/brew/whalebridge}"
# "cask" and "zip" test the latest published release; "local" builds and
# tests the current working tree instead (including uncommitted changes) —
# there's no Homebrew equivalent to a formula's `head` build here, since
# casks only ever install pre-built artifacts, never build from source.
METHODS="${METHODS:-cask zip}"
REQUIRED_CONTAINER_VERSION="${REQUIRED_CONTAINER_VERSION:-$(sed -n 's|.*apple/container\.git", exact: "\([0-9.]*\)".*|\1|p' "$ROOT/vendor/socktainer/Package.swift" | head -1)}"
[[ -n "$REQUIRED_CONTAINER_VERSION" ]] || { echo "could not determine apple/container version from vendor/socktainer/Package.swift" >&2; exit 1; }

command -v tart >/dev/null || { echo "tart not found — run: brew install cirruslabs/cli/tart" >&2; exit 1; }
if [[ "$BASE_IMAGE" == "whalebridge-tahoe-golden" ]] && ! tart list --quiet 2>/dev/null | grep -qx "$BASE_IMAGE"; then
    echo "$BASE_IMAGE doesn't exist yet — run: make vm-golden-image" >&2
    exit 1
fi

if [[ " $METHODS " == *" cask "* || " $METHODS " == *" zip "* ]]; then
    # Resolved on the host (unauthenticated GitHub API, no `gh` dependency)
    # since the zip asset name embeds the version and there's no stable-name
    # alias for it the way there is for appcast.xml.
    ZIP_URL="${ZIP_URL:-$(curl -fsSL https://api.github.com/repos/cap10morgan/whalebridge/releases/latest \
        | grep -o '"browser_download_url": *"[^"]*\.zip"' | sed 's/.*"\(https[^"]*\)"/\1/')}"
    [[ -n "$ZIP_URL" ]] || { echo "could not resolve the latest release zip URL" >&2; exit 1; }
fi
if [[ " $METHODS " == *" local "* ]]; then
    echo "==> Building the current working tree (make bundle)"
    make -C "$ROOT" bundle
    # A plain `ditto`/`cp -R` of the .app through tart's virtiofs directory
    # share fails with "Too many levels of symbolic links" on Sparkle.
    # framework's Versions-symlink structure — zip it first instead (same as
    # a real release asset) so the guest extracts it onto its own native
    # filesystem, the same path the "zip" method below already relies on.
    ditto -c -k --keepParent "$ROOT/build/Whalebridge.app" "$ROOT/build/Whalebridge-local.zip"
fi

# One full install-through-Docker-API run in its own throwaway VM. Run in a
# subshell (see the loop below) so its `trap cleanup EXIT` — and therefore
# the VM teardown — is scoped to that subshell instead of the whole script,
# letting both install methods run even if one fails.
run_smoke_test() {
    local method="$1" # "cask", "zip", or "local"
    local tag="[$method]"
    # Not `local`: the cleanup() trap below is a plain function, and its
    # EXIT trap fires after run_smoke_test has already returned (once the
    # enclosing subshell starts winding down) — by then a `local` VM_NAME
    # would already be out of scope and unbound under `set -u`.
    VM_NAME="whalebridge-smoke-${method}-$$"

    # A plain nonzero exit from `tart exec` isn't the only failure signal to
    # trust: when the guest agent's control socket is unreachable, observed
    # in practice, `tart exec` can print "Failed to connect to the VM using
    # its control socket" and still exit 0. Capture output and treat that
    # message as failure regardless of exit code.
    vm_try() {
        local out status
        out="$(tart exec "$VM_NAME" bash -c "$1" 2>&1)"
        status=$?
        printf '%s\n' "$out"
        if [[ "$status" -ne 0 ]] || grep -q "Failed to connect to the VM using its control socket" <<<"$out"; then
            return 1
        fi
    }

    # macOS's /bin/bash is stuck at 3.2 (GPLv3), whose `errexit` doesn't
    # reliably propagate a failing function's return status back out through
    # an explicit `(...)` subshell — confirmed directly: even a bare `false`
    # inside a function called via `( fn )` fails to trigger `set -e` on
    # this bash, though it does on 4.x+. Every real call site below uses
    # this exiting wrapper instead of vm_try's plain `return 1`, since `exit`
    # unconditionally tears down the current shell (subshell included) and
    # fires its EXIT trap regardless of errexit semantics — the same
    # mechanism the "guest agent never ready" check already relied on.
    # vm_try itself stays available for cleanup()'s log dump below, which is
    # already mid-failure-handling and shouldn't let a log-dump problem mask
    # the original error.
    vm() { vm_try "$1" || exit 1; }

    cleanup() {
        local status=$?
        if [[ "$status" -ne 0 ]]; then
            echo "--- daemon.log ($method, failure) ---" >&2
            vm_try 'cat "$HOME/Library/Logs/Whalebridge/daemon.log"' >&2 2>&1 || true
        fi
        tart stop "$VM_NAME" >/dev/null 2>&1 || true
        tart delete "$VM_NAME" >/dev/null 2>&1 || true
        exit "$status"
    }
    trap cleanup EXIT

    echo "==> $tag Cloning $BASE_IMAGE"
    tart clone "$BASE_IMAGE" "$VM_NAME"

    echo "==> $tag Booting $VM_NAME"
    local run_args=(--no-graphics)
    # Shares build/ read-only so the "local" method can copy the just-built
    # Whalebridge.app in — mounted under "/Volumes/My Shared Files/build" on
    # the guest.
    [[ "$method" == "local" ]] && run_args+=(--dir="build:$ROOT/build:ro")
    tart run "$VM_NAME" "${run_args[@]}" &
    # The "agent" resolver waits for the Tart Guest Agent, not just DHCP, so
    # it doubles as the readiness check `tart exec` below depends on. A
    # single RPC attempt occasionally times out before the agent's vsock
    # listener is up even within --wait's window, so retry the whole wait a
    # few times rather than treating one failed attempt as fatal.
    local agent_ready=false
    for _ in 1 2 3; do
        if tart ip "$VM_NAME" --wait 120 --resolver agent >/dev/null; then
            agent_ready=true
            break
        fi
    done
    # Exhausting the retries above must not silently fall through into the
    # install steps below against a VM that was never actually reachable —
    # that's exactly what produced a false "All checks passed" once already.
    [[ "$agent_ready" == true ]] || { echo "$tag guest agent never became ready" >&2; exit 1; }

    case "$method" in
    cask)
        echo "==> $tag Installing the whalebridge cask"
        vm "brew install --cask $CASK"
        ;;
    zip)
        echo "==> $tag Downloading and installing the release zip"
        # Mirrors README's "Installation" section: download, unzip, move
        # Whalebridge.app into /Applications.
        vm "
          curl -fsSL -o /tmp/whalebridge.zip '$ZIP_URL' &&
          rm -rf /tmp/wb-extract && mkdir /tmp/wb-extract &&
          ditto -x -k /tmp/whalebridge.zip /tmp/wb-extract &&
          mv /tmp/wb-extract/Whalebridge.app /Applications/Whalebridge.app
        "
        ;;
    local)
        echo "==> $tag Installing the locally-built Whalebridge.app"
        vm '
          rm -rf /tmp/wb-extract && mkdir /tmp/wb-extract &&
          ditto -x -k "/Volumes/My Shared Files/build/Whalebridge-local.zip" /tmp/wb-extract &&
          mv /tmp/wb-extract/Whalebridge.app /Applications/Whalebridge.app
        '
        ;;
    esac

    echo "==> $tag Clearing quarantine (unnotarized — same workaround the cask's caveats/the README document)"
    vm "xattr -cr /Applications/Whalebridge.app"

    echo "==> $tag Installing apple/container $REQUIRED_CONTAINER_VERSION"
    vm "curl -fsSL -o /tmp/container.pkg https://github.com/apple/container/releases/download/$REQUIRED_CONTAINER_VERSION/container-installer-unsigned.pkg && sudo installer -pkg /tmp/container.pkg -target /"

    echo "==> $tag Starting apple/container services"
    # Deliberately not sudo: DaemonManager.start() (app/Sources/Whalebridge/
    # DaemonManager.swift) calls plain `container system start` as the
    # logged-in user, which starts and owns a per-user apiserver instance —
    # running these setup steps under sudo instead stands up a *separate*
    # root-owned apiserver with its own (unset) kernel config that the app
    # never talks to, and `container create` fails with "default kernel not
    # configured" against the real, still-unconfigured one. Match the app's
    # own user context here.
    vm "container system start --enable-kernel-install"
    echo "==> $tag Setting the recommended kernel"
    vm "container system kernel set --recommended --force"

    echo "==> $tag Launching Whalebridge.app"
    # By path, not `-a Whalebridge` — Launch Services hasn't necessarily
    # indexed a just-installed app yet on a fresh VM, and by-name lookup can
    # miss it.
    vm "open /Applications/Whalebridge.app"

    echo "==> $tag Waiting for the daemon socket"
    vm '
      for _ in $(seq 30); do
        [ -S "$HOME/.socktainer/container.sock" ] && exit 0
        sleep 2
      done
      echo "container.sock never appeared" >&2
      exit 1
    '

    echo "==> $tag Installing the docker CLI"
    vm "brew install docker"

    echo "==> $tag Checking docker --context whalebridge version"
    vm "docker --context whalebridge version | grep -q Whalebridge"

    echo "==> $tag Checking image pull"
    vm "docker --context whalebridge pull quay.io/podman/hello && docker --context whalebridge image ls | grep -q podman/hello"

    echo "==> $tag Checking container create/list/remove"
    # `container system start --enable-kernel-install` (and the `kernel set`
    # above) kick off the kernel download in the background, so `create` can
    # in principle race ahead of it and fail with "default kernel not
    # configured" even though the earlier steps reported success. The docker
    # CLI flattens that into a generic "Something went wrong", so there's no
    # specific error text to key a retry on — just retry create itself a
    # bounded number of times; the cleanup trap dumps the daemon log if
    # every attempt fails for some other reason.
    vm '
      for _ in $(seq 10); do
        docker --context whalebridge create --name wb-smoke quay.io/podman/hello && break
        sleep 10
      done
      docker --context whalebridge ps -a | grep -q wb-smoke
      docker --context whalebridge rm wb-smoke
    '

    echo "==> $tag All checks passed"
}

overall=0
for method in $METHODS; do
    echo "########## Testing the $method install path ##########"
    if ! (run_smoke_test "$method"); then
        echo "!!! $method install path FAILED" >&2
        overall=1
    fi
done

exit "$overall"

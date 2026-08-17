#!/bin/bash
# Builds (or rebuilds, with --force) a local tart VM named
# whalebridge-tahoe-golden that scripts/vm-smoke-test.sh clones from instead
# of Cirrus's stock ghcr.io/cirruslabs/macos-tahoe-base image.
#
# Why: on macOS Tahoe 26.4+, a stock clone can intermittently boot into the
# SetupAssistant/MiniBuddy "Welcome to macOS Tahoe" screen instead of
# continuing to a normal session — an Apple behavior change, not a tart bug
# (see https://github.com/openai/tart/issues/1222). That screen requires
# interactive dismissal, which blocks the guest agent's LaunchAgent along
# with everything else, even though the kernel/network are already up — so
# `tart exec`/`tart ip --resolver agent` can hang for minutes with no way to
# recover once it happens (the same shell access needed to dismiss it is
# what the screen is blocking). Since network comes up before the screen
# would appear, this run retries the boot until it gets one that reaches the
# guest agent, then installs the suppression settings from that issue's
# workaround before the screen can ever appear on any future clone of this
# saved VM.
set -euo pipefail

VM_NAME="whalebridge-tahoe-golden"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

command -v tart >/dev/null || { echo "tart not found — run: brew install cirruslabs/cli/tart" >&2; exit 1; }

if tart list --quiet 2>/dev/null | grep -qx "$VM_NAME"; then
    if [[ "$FORCE" != true ]]; then
        echo "$VM_NAME already exists — nothing to do (pass --force to rebuild)"
        exit 0
    fi
    tart stop "$VM_NAME" >/dev/null 2>&1 || true
    tart delete "$VM_NAME"
fi

echo "==> Cloning $BASE_IMAGE"
tart clone "$BASE_IMAGE" "$VM_NAME"

echo "==> Booting $VM_NAME"
tart run "$VM_NAME" --no-graphics &

# A clean boot reaches the agent in well under a minute; a boot that's hit
# the SetupAssistant lockout never will, no matter how long this waits — so
# retry the whole boot from scratch a few times rather than waiting longer,
# same logic vm-smoke-test.sh uses for the ordinary single-RPC-attempt case.
agent_ready=false
for attempt in 1 2 3 4 5; do
    if tart ip "$VM_NAME" --wait 90 --resolver agent >/dev/null; then
        agent_ready=true
        break
    fi
    echo "attempt $attempt: agent never came up (likely the SetupAssistant lockout) — restarting the VM"
    tart stop "$VM_NAME" >/dev/null 2>&1 || true
    tart run "$VM_NAME" --no-graphics &
done
if [[ "$agent_ready" != true ]]; then
    echo "guest agent never became ready after 5 boot attempts" >&2
    tart stop "$VM_NAME" >/dev/null 2>&1 || true
    exit 1
fi

echo "==> Applying SetupAssistant/MiniBuddy suppression (openai/tart#1222 workaround)"
tart exec "$VM_NAME" bash -c '
  sudo mkdir -p "/Library/Managed Preferences"
  sudo defaults write "/Library/Managed Preferences/com.apple.SetupAssistant.managed" SkipSetupItems -dict-add UpdateCompleted -bool true
  sudo defaults write "/Library/Managed Preferences/com.apple.SetupAssistant.managed" SkipCloudSetup -bool true
  defaults write com.apple.SetupAssistant MiniBuddyLaunchedPostMigration -bool true
  sudo defaults write /Library/Preferences/com.apple.SetupAssistant DidSeeCloudSetup -bool true
'

echo "==> Stopping $VM_NAME to save its state"
tart stop "$VM_NAME"

echo "==> $VM_NAME is ready — scripts/vm-smoke-test.sh will clone from it"

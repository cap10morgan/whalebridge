ROOT := $(shell pwd)
DAEMON_BIN := $(ROOT)/vendor/socktainer/.build/release/socktainer

.DEFAULT_GOAL := bundle

# The socktainer identity reported in the Docker API: the vendored release
# when the pin sits exactly on an upstream tag, else the pinned short sha,
# plus "-wbN" because we apply local patches — N is patches/WB_REVISION.
# Policy: bump WB_REVISION whenever patches/ changes against the same
# submodule pin; reset it to 1 when the pin moves.
WB_REVISION = $(shell cat $(ROOT)/patches/WB_REVISION)
SOCKTAINER_BASE_VERSION = $(shell git -C vendor/socktainer describe --tags --exact-match HEAD 2>/dev/null || git -C vendor/socktainer rev-parse --short HEAD)
SOCKTAINER_VERSION = $(SOCKTAINER_BASE_VERSION)-wb$(WB_REVISION)

# Reset the submodule to its pinned tag, then apply our patches (see patches/)
# so the vendor tree never carries hand edits between builds.
.PHONY: daemon
daemon:
	git submodule update --init
	git -C vendor/socktainer checkout -- .
	git -C vendor/socktainer clean -fd
	for p in $(ROOT)/patches/*.patch; do git -C vendor/socktainer apply "$$p"; done
	# Tags aren't fetched by `submodule update` (CI checkouts especially), and
	# the release-vs-sha distinction above needs them; offline is fine — the
	# sha fallback still applies.
	git -C vendor/socktainer fetch --tags --quiet origin 2>/dev/null || true
	$(MAKE) -C vendor/socktainer release BUILD_VERSION="$(SOCKTAINER_VERSION)"

.PHONY: app
app:
	cd app && swift build -c release

.PHONY: icons
icons:
	bash scripts/icons.sh

.PHONY: bundle
bundle: daemon app icons
	bash scripts/bundle.sh

.PHONY: run
run: bundle
	open build/Whalebridge.app

# Run the app unbundled for quick iteration (daemon must be built).
REQUIRED_CONTAINER_VERSION := $(shell sed -n 's|.*apple/container\.git", exact: "\([0-9.]*\)".*|\1|p' vendor/socktainer/Package.swift | head -1)
.PHONY: dev
dev:
	cd app && WHALEBRIDGE_DAEMON=$(DAEMON_BIN) WHALEBRIDGE_CONTAINER_VERSION=$(REQUIRED_CONTAINER_VERSION) \
		WHALEBRIDGE_VERSION=$$(git rev-parse --short HEAD) swift run

# One-time (or --force to rebuild): a local tart base image with the macOS
# Tahoe SetupAssistant lockout (openai/tart#1222) pre-suppressed — see
# scripts/vm-build-golden-image.sh for why vm-smoke-test needs this instead
# of cloning Cirrus's stock image directly.
.PHONY: vm-golden-image
vm-golden-image:
	bash scripts/vm-build-golden-image.sh $(ARGS)

# Installs each of the two published-release install paths (the Homebrew
# cask and the manual release zip) into its own throwaway tart VM and drives
# it over the Docker API — see scripts/vm-smoke-test.sh for what it covers.
# Override which methods run with e.g. `make vm-smoke-test METHODS="cask zip local"`.
.PHONY: vm-smoke-test
vm-smoke-test:
	REQUIRED_CONTAINER_VERSION=$(REQUIRED_CONTAINER_VERSION) METHODS="$(METHODS)" bash scripts/vm-smoke-test.sh

# Same as vm-smoke-test, but builds and installs the current working tree
# (including uncommitted changes) instead of testing a published release —
# there's no Homebrew equivalent to a formula's `head` build for this, since
# casks only ever install pre-built artifacts.
.PHONY: vm-smoke-test-local
vm-smoke-test-local:
	REQUIRED_CONTAINER_VERSION=$(REQUIRED_CONTAINER_VERSION) METHODS=local bash scripts/vm-smoke-test.sh

.PHONY: clean
clean:
	rm -rf build app/.build
	$(MAKE) -C vendor/socktainer clean

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
REQUIRED_CONTAINER_VERSION := $(shell sed -n 's/.*appleContainerVersion = "\([0-9.]*\)".*/\1/p' vendor/socktainer/Package.swift | head -1)
.PHONY: dev
dev:
	cd app && WHALEBRIDGE_DAEMON=$(DAEMON_BIN) WHALEBRIDGE_CONTAINER_VERSION=$(REQUIRED_CONTAINER_VERSION) \
		WHALEBRIDGE_VERSION=$$(git rev-parse --short HEAD) swift run

.PHONY: clean
clean:
	rm -rf build app/.build
	$(MAKE) -C vendor/socktainer clean

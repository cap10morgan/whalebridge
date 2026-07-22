ROOT := $(shell pwd)
DAEMON_BIN := $(ROOT)/vendor/socktainer/.build/release/socktainer

.DEFAULT_GOAL := bundle

# Reset the submodule to its pinned tag, then apply our patches (see patches/)
# so the vendor tree never carries hand edits between builds.
.PHONY: daemon
daemon:
	git submodule update --init
	git -C vendor/socktainer checkout -- .
	git -C vendor/socktainer clean -fd
	for p in $(ROOT)/patches/*.patch; do git -C vendor/socktainer apply "$$p"; done
	$(MAKE) -C vendor/socktainer release

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
	cd app && WHALEBRIDGE_DAEMON=$(DAEMON_BIN) WHALEBRIDGE_CONTAINER_VERSION=$(REQUIRED_CONTAINER_VERSION) swift run

.PHONY: clean
clean:
	rm -rf build app/.build
	$(MAKE) -C vendor/socktainer clean

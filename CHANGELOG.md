# Changelog

All notable changes to Whalebridge are documented in this file.

## [Unreleased]

### Changed
- The menu bar icon now reflects Apple's container services, not just the Whalebridge daemon: it's dimmed whenever docker commands wouldn't work (including a running daemon over stopped container services) and animates while Whalebridge starts or restarts those services, as well as during its own startup.
- Builds made from a bare git commit now identify as that commit's short sha (About dialog, Docker API platform version) instead of masquerading as a release version.
- The socktainer component version in `docker version` now reports the vendored release (or pinned short sha) with a `-wbN` suffix for Whalebridge's local patch revision — e.g. `v1.1.1-wb7` — instead of `0.0.0-dev`.

### Added
- `docker logs --tail N` is now honored (previously the full log was always returned). Line-count-based, so it works despite Apple Container not recording per-line write times — which also remains why `--since`/`--until` can't be supported and `-t` stamps read time rather than emission time.

### Fixed
- A wedged Apple Container runtime (apple/container#1884: container/network operations hang indefinitely while reads keep working) could stop Whalebridge's daemon from starting at all — startup housekeeping (DNS-sidecar adoption, orphaned-network reaping) blocked forever on hung XPC calls and the Docker API socket was never created. That housekeeping is now time-boxed to 30 seconds; on timeout the daemon logs a warning, skips it, and comes up anyway.

## [0.1.5] - 2026-07-22

### Fixed
- `docker buildx build` now works end to end. Two bugs were blocking it: Apple Container only materializes a container's filesystem at start, not at create, so buildx seeding files into its BuildKit builder container before starting it (its docker-container driver's normal bootstrap sequence) failed outright — Whalebridge now bootstraps such a container on demand (booting its VM without yet launching its command) so the seed succeeds, and the `/start` that follows reuses that same bootstrap rather than erroring on a redundant one. Separately, `HostConfig.Privileged` was silently dropped entirely; it's now treated as granting all capabilities (the closest available equivalent), which BuildKit's build container needs to mount build contexts. Verified against two real Dockerfiles (apt-get + multi-stage COPY, and Leiningen/Maven) built and run successfully.
- The 0.1.4 "container's runtime state is missing or corrupted" message was wrong for a container that simply hasn't been started yet — that case (like buildx's, above) now either succeeds automatically or, if the automatic recovery itself fails, correctly says to run `docker start` rather than `docker rm -f`. A container that genuinely started and then lost its state (e.g. an OOM kill) still gets the crash/`docker rm -f` guidance.

## [0.1.4] - 2026-07-22

### Changed
- Containers that don't request a memory limit of their own now default to 75% of host RAM instead of Apple Container's fixed 1 GiB — a limit tight enough that ordinary workloads (e.g. a Node/vite build) can OOM well under it. Configurable in Settings (10-90%, applies the next time Whalebridge starts).
- Errors against a container whose runtime state is missing or corrupted (most often from an abnormal exit, like an OOM kill) now say so and suggest `docker rm -f`, instead of leaking a raw Cocoa/POSIX error like "stdio.log doesn't exist" or "Rootfs not found" — covers `docker logs`, `docker cp`/archive operations, and `docker export`.

## [0.1.3] - 2026-07-21

### Added
- "About Whalebridge" menu item: a dialog with the app icon, current version, GitHub and Check for Updates buttons, and acknowledgment links to socktainer and Apple's container runtime.

### Fixed
- The apiserver-restart fix from 0.1.2 only engaged when Whalebridge itself observed a runtime upgrade within a single run. It now persists the last verified apple/container version across launches, so a runtime that was upgraded before Whalebridge last started (by our own installer flow in an earlier run, or manually) still gets its apiserver restarted instead of trusting a stale already-running process.

## [0.1.2] - 2026-07-21

### Fixed
- Apple's container installer updates files on disk but doesn't restart an already-running apiserver, which can keep serving the pre-upgrade version until something restarts it. socktainer's own compatibility check pings that live process and would fail with a version-mismatch error even after Whalebridge detected the upgrade was installed. Whalebridge now restarts Apple's container services after a runtime install instead of just starting them if they weren't already running.

## [0.1.1] - 2026-07-20

### Changed
- Updated the bundled socktainer daemon to v1.1.1. Upstream absorbed our pull-progress patch as a native feature, so it was dropped rather than reapplied; the platform-branding patch remains.
- Renamed "Daemon" to "Whalebridge" throughout the menu bar UI (status line, start/stop buttons, log menu item, failure messages).

## [0.1.0] - 2026-07-17

Initial release.

### Added
- Bundles and supervises a patched [socktainer](https://github.com/socktainer/socktainer) daemon, exposing the Docker Engine API over Apple's native [container](https://github.com/apple/container) runtime.
- Menu bar UI: daemon and Apple container runtime status, a Containers section listing running containers with a "Stopped" submenu, Docker context management, and a daemon log shortcut.
- Sparkle auto-update with a "Check for Updates" menu item.
- Launch at login, on by default, configurable from a new Settings window.
- Animated menu bar icon while the daemon is starting.
- CI on every push and pull request: app unit tests, socktainer's own test suite run against our patches, and a live integration job driving the real Docker API.
- Tag-triggered release pipeline: build, sign, generate a Sparkle appcast, and publish a GitHub Release.

[Unreleased]: https://github.com/cap10morgan/whalebridge/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/cap10morgan/whalebridge/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/cap10morgan/whalebridge/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/cap10morgan/whalebridge/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/cap10morgan/whalebridge/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/cap10morgan/whalebridge/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/cap10morgan/whalebridge/releases/tag/v0.1.0

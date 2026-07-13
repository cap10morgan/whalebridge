# Whalebridge

A macOS menu bar app that lets Docker API clients (docker CLI, compose,
Testcontainers, IDEs) talk to Apple's native
[container](https://github.com/apple/container) runtime.

Whalebridge bundles and manages a [socktainer](https://github.com/socktainer/socktainer)
daemon — a Docker Engine API (v1.32–v1.51) translation layer over Apple's
Containerization stack — and takes care of everything around it: starting and
supervising the daemon, making sure Apple's container services are running,
and wiring up a Docker context so `docker ps` just works.

## Requirements

- macOS 26+ on Apple silicon
- [apple/container](https://github.com/apple/container/releases) 1.1.x installed
  (`container --version`)
- A Docker API client to point at it (e.g. `brew install docker`)

## Architecture

```
docker CLI ──unix socket──▶ socktainer daemon ──XPC──▶ container-apiserver ──▶ per-container VMs
 (client)     (~/.socktainer/container.sock)            (apple/container)       (Containerization/
                     ▲                                                           Virtualization.framework)
                     │ spawns, supervises, monitors
              Whalebridge.app (menu bar)
```

## Build

```sh
make bundle   # builds the daemon (vendor/socktainer) + app, assembles build/Whalebridge.app
make run      # bundle + launch
make dev      # run the app unbundled via swift run (uses the vendor daemon build)
```

## License

Apache License 2.0 — see [LICENSE](LICENSE). Bundled components are listed in
[NOTICE](NOTICE).

Docker is a registered trademark of Docker, Inc. Whalebridge is not affiliated
with or endorsed by Docker, Inc. or Apple Inc.

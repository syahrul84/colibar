# Colibar

A native macOS menu bar app for managing [Colima](https://github.com/abiosoft/colima) and its Docker containers — grouped by Compose project, the way Laravel Sail stacks actually live.

Colima is CLI-only by design. Colibar puts start/stop, live status, usage stats, and local `.test` domains one click away, without a Dock icon or a main window.

## Features

- **Colima instances** — start/stop/restart any profile, edit CPU/memory/disk from the UI (applies via `colima stop && colima start --cpus … --memory … --disk …`).
- **Containers grouped by Compose project** — collapsible cards with `running/total`, group start/stop/restart, per-container actions.
- **Live usage** — CPU %, memory, and on-disk size per container (`docker stats` sampled off the refresh path), aggregated per project and per VM; VM data-disk fill watching with a warning at 85%.
- **Problems surfaced** — unhealthy / restart-looping containers get an "Attention" card with one-click restart, an orange dot, and a menu bar warning triangle; unexpected container stops post macOS notifications.
- **Local `.test` domains with HTTPS** — per-container opt-in hostnames (`goodbite.test`) served by a built-in reverse proxy on ports 80/443, backed by a managed `/etc/hosts` block and a local CA (openssl). Websockets pass through; `X-Forwarded-*` headers are injected for framework URL generation.
- **Terminal handoffs** — container logs, container shell, whole-project `docker compose logs -f`, and "open Terminal at project directory", all via Terminal.app for a real TTY.
- **Quality of life** — filter field, clickable port badges, launch at login, optional Colima auto-start, battery-aware polling (60s heartbeat while the panel is closed).

## Requirements

- macOS 14+ (Apple Silicon or Intel)
- [Colima](https://github.com/abiosoft/colima) and the docker CLI: `brew install colima docker`
- Xcode command line tools (Swift 5.9+)

## Build & install

```bash
./build-app.sh install
```

Builds with SwiftPM (release), assembles `Colibar.app`, ad-hoc signs it, and installs to `/Applications`. Omit `install` to just build locally.

> Run the app from `/Applications`, not from a working directory under `~/Documents` — macOS TCC re-assesses rebuilt bundles there, which can stall launches.

## Architecture

```
Sources/
  ColibarCore/          # library shared by app + CLI; no UI imports
    Shell.swift         # process runner, PATH resolution, pipe draining, watchdog
    ColimaService.swift # every colima/docker call + output parsing (only file
                        # that needs editing if Colima changes its output)
    Models.swift        # plain structs + compose grouping
    LocalDomains.swift  # .test hostname mapping + /etc/hosts block rendering
    ReverseProxy.swift  # Host-header proxy (Network.framework, no deps)
    DomainService.swift # local CA (openssl), keychain trust, hosts writes
  Colibar/              # the menu bar app (SwiftUI, MenuBarExtra .window)
    AppState.swift      # @MainActor ObservableObject: polling, busy state, prefs
    Views/
  colibar-cli/          # dev verification CLI (parsing + proxy tests)
```

No third-party dependencies.

## Hard-won macOS notes

- **PATH**: Finder-launched apps don't see Homebrew. Binaries are resolved by probing `/opt/homebrew/bin` etc. directly, with a cached login-shell lookup as last resort.
- **Pipes**: `Process` stdout/stderr are drained on concurrent queues with a SIGTERM→SIGKILL watchdog; sequential reads deadlock past one pipe buffer.
- **MenuBarExtra sizing**: `.window` style hugs the content's *ideal* height and a `ScrollView`'s ideal height is zero — content height is measured via `GeometryReader` + `PreferenceKey`.
- **`@AppStorage` in `ObservableObject`**: writes through a SwiftUI `Binding` bypass `didSet` and publish nothing; preferences use `@Published` + manual `UserDefaults`.
- **Certificate trust**: `security add-trusted-cert` **must** be scoped with `-p ssl`. Unscoped, the CA is trusted for code signing too, which drags it into Gatekeeper launch assessments and can stall app launches machine-wide. macOS 15+ also refuses programmatic *system*-domain trust entirely — user-domain trust triggers the system's own confirmation dialog.
- **Trust prompts**: writing `/etc/hosts` uses one `osascript` admin prompt; the staged file is installed with a single privileged `cp`.

## Status

Personal tool, built for one machine but written to be portable. No license chosen yet.

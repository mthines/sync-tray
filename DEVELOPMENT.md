# SyncTray Development Guide

## Prerequisites

- macOS 13+ (Ventura or later)
- Xcode 15+
- [rclone](https://rclone.org/) installed (`brew install rclone`)

## Build & Run

```bash
# Build
xcodebuild -scheme SyncTray -destination 'platform=macOS' build

# Build with pretty output
xcodebuild -scheme SyncTray -destination 'platform=macOS' build 2>&1 | xcbeautify

# Run
open ~/Library/Developer/Xcode/DerivedData/SyncTray-*/Build/Products/Debug/SyncTray.app
```

## Code signing & the Finder extension (local dev)

The `SyncTrayFinderSync` Finder extension **only loads in a code-signed build** —
macOS won't register a Finder extension or grant App Groups otherwise. Set this up
once per clone:

```bash
git config core.hooksPath .githooks                                     # team-guard hook
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig   # then set DEVELOPMENT_TEAM in it
```

Your Team ID lives only in the gitignored `Config/Signing.local.xcconfig`, never in
the committed project. CI and release builds compile unsigned (they pass
`CODE_SIGNING_ALLOWED=NO`), so no team is needed there; `scripts/release-ci.sh`
then signs the release with Developer ID from CI secrets and notarizes it
(see [`docs/release-signing.md`](docs/release-signing.md)).

To exercise the extension:

1. In Xcode set your **Team** on both the `SyncTray` and `SyncTrayFinderSync` targets
   (Signing & Capabilities → Automatically manage signing); confirm both carry the
   `7HVK85DZG7.group.com.synctray.app` App Group.
2. Build & run (⌘R), then enable it under System Settings → General → Login Items &
   Extensions → Extensions → **SyncTray Offline**.
3. Mount a Stream profile and right-click a folder **inside the mount** →
   **SyncTray ▸ Available Offline**. Verify with `pluginkit -m -i com.synctray.app.dev.findersync`.

Debug builds use `.dev` bundle ids (`com.synctray.app.dev` and `com.synctray.app.dev.findersync`,
via `BUNDLE_ID_SUFFIX` in `Config/Signing.xcconfig`), so a dev build never takes over the
Finder registration of an installed release. If you enable both extensions, Finder shows two
"SyncTray" submenus — disable one while you iterate.
4. **After every rebuild, run `killall Finder`** so it reloads the extension.

`scripts/dev.sh` (`nx run synctray:dev`) tries a signed build first (extension loads
when the above is set up) and falls back to unsigned so iteration is never blocked.
Shipping the extension to users (Developer ID signing + notarization) is covered in
[docs/release-signing.md](docs/release-signing.md).

## Project Structure

```
SyncTray/
├── CLI/              # The headless `synctray` command and its ~/.local/bin shim
├── Models/           # Data models and state types
├── Services/         # Business logic and background services
├── Views/            # SwiftUI views
├── Resources/Schemas # JSON Schemas for the files in ~/.config/synctray/
└── SyncTrayApp.swift # App entry point and AppDelegate
SyncTrayFinderSync/   # Finder "Available Offline" extension
FileProviderExtension/ # Design scaffolding only — not part of the build
```

The main pieces:

| Component             | Role                                                                    |
| --------------------- | ----------------------------------------------------------------------- |
| `SyncManager`         | Orchestrates every profile's state, watchers, mounts, and runs          |
| `ProfileStore`        | Reads and writes the authoritative `~/.config/synctray/profiles/*.profile.json` |
| `ConfigFileWatcher`   | Applies external edits to the config folder live                        |
| `SyncSetupService`    | Generates the shared sync script and launchd plists; installs agents    |
| `LogWatcher` / `LogParser` | Follow and parse each profile's rclone JSON log                    |
| `VFSCacheService`     | Stream cache, offline-folder warming, and the rclone RC API            |
| `OverlaySyncService`  | Uploads files created or edited in Cache Only                           |
| `SyncTrayCLI`         | The `synctray` command                                                  |
| `TelemetryService`    | Opt-in OpenTelemetry traces, metrics, and logs                          |

See [CLAUDE.md](CLAUDE.md) for the full architecture and the rules that keep it safe.

## Testing

SyncTray has no XCTest target. The `#if DEBUG` self-test suite in
`SyncTray/Services/ConfigSelfTest.swift` is the test suite, and CI runs it on every PR:

```bash
xcodebuild -scheme SyncTray -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
build/Build/Products/Debug/SyncTray.app/Contents/MacOS/SyncTray --self-test
```

It exits non-zero on any failed assertion. Don't run two self-tests at once: they share a
temporary directory and fail each other at random.

`scripts/check-schema-in-sync.sh` checks that the JSON Schemas still match `SyncProfile`'s
fields. Run it after adding or renaming a profile field; CI runs it too.

## Commit convention and releases

Commits and PR titles follow [Conventional Commits](https://www.conventionalcommits.org/),
and the prefix decides the next version:

| Prefix   | Version bump  | Example                        |
| -------- | ------------- | ------------------------------ |
| `feat:`  | Minor (0.X.0) | `feat: add dark mode support`  |
| `fix:`   | Patch (0.0.X) | `fix: resolve crash on launch` |
| `feat!:` | Major (X.0.0) | `feat!: redesign settings API` |

Other prefixes (`docs:`, `chore:`, `ci:`, …) don't release.

- **Stable releases** are published by CI: merging a `feat:` or `fix:` PR to `main` bumps the
  version, builds, signs, notarizes, publishes the GitHub release, and updates the Homebrew
  tap (`scripts/release-ci.sh`). A local `scripts/release.sh` run refuses, because it can't
  notarize — see [`docs/release-signing.md`](docs/release-signing.md).
- **Betas** are published on demand: an authorized `/beta` comment on an open PR builds and
  publishes a beta of that PR, installable as the `synctray-beta` cask.

## OpenTelemetry (Telemetry)

SyncTray includes opt-in, pseudonymous telemetry powered by [OpenTelemetry](https://opentelemetry.io/) and exported to [Dash0](https://dash0.com/).

### How It Works

Telemetry is **disabled by default**. When a user opts in via Settings, the app emits metrics and traces to the Dash0 OTLP ingress endpoint. All telemetry methods are no-ops when disabled.

### Enabling Telemetry for Development

Two things are required:

1. **Configure environment variables** — copy `.env.example` to `~/.config/synctray/.env` and fill in your auth token:

   ```bash
   cp .env.example ~/.config/synctray/.env
   # Edit ~/.config/synctray/.env with your Dash0 auth token
   ```

   The app reads this file at runtime, so it works regardless of how the app is launched (Nx, Xcode, `open`, Finder, etc.). Process environment variables take precedence over `.env` file values.

   > Without valid auth headers, the telemetry service skips initialization entirely (no wasted network requests).

2. **Toggle "Share usage data" ON** in the app's Settings window.

### Environment Variables

All configuration uses [standard OTel environment variables](https://opentelemetry.io/docs/languages/sdk-configuration/general/):

| Variable                      | Required | Default                                          | Description                                                                                                                                                              |
| ----------------------------- | -------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | No       | `https://ingress.europe-west4.gcp.dash0-dev.com` | Base OTLP endpoint URL. `/v1/traces` and `/v1/metrics` are appended automatically.                                                                                       |
| `OTEL_EXPORTER_OTLP_HEADERS`  | Yes\*    | —                                                | Auth headers as comma-separated `Key=Value` pairs. e.g., `Authorization=Bearer <token>`                                                                                  |
| `OTEL_SERVICE_NAME`           | No       | `synctray`                                       | The `service.name` resource attribute.                                                                                                                                   |
| `OTEL_RESOURCE_ATTRIBUTES`    | No       | —                                                | Additional resource attributes as comma-separated `key=value` pairs. e.g., `deployment.environment.name=development,service.namespace=synctray`                          |
| `DASH0_AUTH_TOKEN`            | No       | —                                                | Convenience alternative to `OTEL_EXPORTER_OTLP_HEADERS`. If set (and `OTEL_EXPORTER_OTLP_HEADERS` is not), automatically creates `Authorization: Bearer <token>` header. |

\*Either `OTEL_EXPORTER_OTLP_HEADERS` or `DASH0_AUTH_TOKEN` must be set for telemetry to initialize.

**Example `.env`:**

```bash
OTEL_SERVICE_NAME=synctray
OTEL_EXPORTER_OTLP_ENDPOINT=https://ingress.europe-west4.gcp.dash0-dev.com
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer dt0-your-token-here
OTEL_RESOURCE_ATTRIBUTES=service.namespace=synctray,deployment.environment.name=development
```

Create a Dash0 auth token at **Settings > Auth Tokens > Create Token** with `Ingesting` permission.

### Token for Release Builds (Distributed App)

For end users to have telemetry work out of the box (when they opt in), the auth token must be embedded at build time via Info.plist variable substitution.

The `DASH0_AUTH_TOKEN` Xcode build setting is empty by default (never committed to source). CI/release builds inject it:

```bash
# CI sets DASH0_AUTH_TOKEN as a secret, then:
xcodebuild -scheme SyncTray -configuration Release \
    -derivedDataPath build \
    DASH0_AUTH_TOKEN="$DASH0_AUTH_TOKEN" \
    build
```

The token is embedded in the app bundle's Info.plist as `Dash0AuthToken`. This is an **ingestion-only** token — it can only write telemetry data, not read or delete it.

Config resolution priority (first non-empty wins):
1. Process environment variables
2. `~/.config/synctray/.env` file
3. Info.plist values embedded at build time

### Release Channel and Version (Beta Tag)

A `/beta` build shows its exact version (e.g. `0.81.0-beta.75.1 (1)`) followed by a **Beta** tag in **App Settings → About**. `CFBundleShortVersionString` can't carry either: a beta only tags the PR head and never bumps it, so it still reads the last stable version the PR branched from.

Both are baked in at build time the same way as the token above. The build settings `SYNCTRAY_RELEASE_CHANNEL` and `SYNCTRAY_RELEASE_VERSION` are empty by default. For every release, `scripts/release-ci.sh` passes the channel (`beta` or `stable`) and the tagged version without its `v`. Info.plist expands them into `SyncTrayReleaseChannel` and `SyncTrayReleaseVersion`. The script then reads both keys back from the built bundle and fails the release if either doesn't match.

The app shows `SyncTrayReleaseVersion` when it is set and falls back to `CFBundleShortVersionString` otherwise. For a CI stable release the two are identical. (The local `scripts/release.sh` refuses to run, because it can't notarize, so every release comes from CI.) Dev builds leave both empty, so they show the plist version and no tag. To preview a beta locally:

```bash
xcodebuild -scheme SyncTray -configuration Debug -derivedDataPath build \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    SYNCTRAY_RELEASE_CHANNEL=beta SYNCTRAY_RELEASE_VERSION=0.81.0-beta.75.1 build
open build/Build/Products/Debug/SyncTray.app
```

### Disabling Telemetry

- **In the app:** Toggle "Share usage data" OFF in Settings. All telemetry methods become no-ops.
- **No auth configured:** If neither `OTEL_EXPORTER_OTLP_HEADERS` nor `DASH0_AUTH_TOKEN` is set (in env, `.env` file, or Info.plist), the service skips setup entirely.

### Running a Local Collector (Optional)

To inspect telemetry locally without sending data to Dash0:

```bash
# Start the OTel Collector with the debug exporter
docker run --rm -p 4318:4318 \
  otel/opentelemetry-collector-contrib:latest \
  --config /dev/stdin <<'EOF'
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    metrics:
      receivers: [otlp]
      exporters: [debug]
    traces:
      receivers: [otlp]
      exporters: [debug]
EOF
```

Then set in your `.env`:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer unused
```

### What's Collected

The in-app **Privacy & Telemetry** sheet (`TelemetryDetailsSheet.swift`) is the user-facing
promise, and the code must stay inside it:

- **Collected:** sync results and durations, error *categories* (never the raw message), sync
  modes and settings in use, trigger counts, launches and profile counts, and the display
  names users give their profiles.
- **Never collected:** file or folder names, file contents, remote names, hostnames, server
  addresses, credentials, error message text, IP addresses, or account details. File
  operations are recorded by normalized extension only.

All three signals are exported over OTLP/HTTP. Metrics use delta temporality and export every
30 seconds. There are more than 50 instruments, covering sync runs, mounts, offline warming,
Cache Only uploads, cache moves, recovery actions, the CLI, and the setup wizard;
`TelemetryService.swift` is the inventory, and
[`.claude/rules/telemetry.md`](.claude/rules/telemetry.md) explains how to add more.

#### Resource attributes

| Attribute                     | Value                                                                        |
| ----------------------------- | ---------------------------------------------------------------------------- |
| `service.name`                | `synctray` (`OTEL_SERVICE_NAME`)                                             |
| `service.namespace`           | `synctray`                                                                   |
| `service.version`             | `<marketing>+<build>.g<gitSHA>`, for example `0.34.0+1.gabc1234`             |
| `service.instance.id`         | Random UUID per install                                                      |
| `enduser.id`                  | HMAC-SHA256 of the hardware UUID — stable across reinstalls, not reversible  |
| `deployment.environment.name` | `development` (Debug) or `production` (Release); overridable                 |
| `vcs.repository.url.full`     | The `origin` URL the binary was built from, credentials stripped            |
| `vcs.ref.head.revision`       | The full commit SHA the binary was built from                                |
| `host.arch`                   | `arm64` or `amd64`                                                           |
| `os.type` / `os.version`      | `darwin` and the macOS version                                               |

Any of these can be overridden or extended with `OTEL_RESOURCE_ATTRIBUTES`.

### Dependencies

The telemetry feature uses [opentelemetry-swift](https://github.com/open-telemetry/opentelemetry-swift) (pinned to exactly 1.17.1, locked by the committed `Package.resolved`) via Swift Package Manager:

- `OpenTelemetryApi` — API interfaces
- `OpenTelemetrySdk` — SDK implementation (stable meter API)
- `OpenTelemetryProtocolExporterHTTP` — OTLP/HTTP exporter

### Key Files

| File                                     | Role                                                                         |
| ---------------------------------------- | ---------------------------------------------------------------------------- |
| `Services/TelemetryService.swift`        | Singleton that configures OTel SDK, creates instruments, and records signals |
| `Models/Settings.swift`                  | `telemetryEnabled`, `installationId`, and `anonymousUserId`                  |
| `SyncTrayApp.swift`                      | Calls `configure()` at launch, `shutdown()` at termination                   |
| `Services/SyncManager.swift`             | Records most sync, mount, and recovery events                                |
| `Views/AppSettingsView.swift`            | The **Share usage data** toggle                                              |
| `Views/Settings/TelemetryOptInBanner.swift`, `TelemetryDetailsSheet.swift` | Opt-in banner and the privacy disclosure     |

## Debugging

Start with `synctray doctor` and `synctray status` — see [docs/cli.md](docs/cli.md).

### Enable Debug Logging

Toggle **Debug Logging** in Settings to enable verbose output in sync log files.

### Inspect launchd Agents

```bash
launchctl list | grep synctray
launchctl print gui/$(id -u)/com.synctray.sync.{shortId}
cat ~/Library/LaunchAgents/com.synctray.sync.*.plist
```

### View Sync Logs

```bash
tail -f ~/.local/log/synctray-sync-{shortId}.log
```

### rclone bisync Cache

Located at `~/Library/Caches/rclone/bisync/`. Use "Fix Sync Issues" in the app to force a `--resync --resync-mode newer`; a reinstall keeps these files (CLAUDE.md Critical Rule 7).

### Lock Files

```bash
ls -la /tmp/synctray-sync-*.lock
```

Stale locks are cleaned on app startup.

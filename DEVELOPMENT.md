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

## Project Structure

```
SyncTray/
├── Models/           # Data models and state types
├── Services/         # Business logic and background services
├── Views/            # SwiftUI views
├── Assets.xcassets/  # App icons and images
└── SyncTrayApp.swift # App entry point and AppDelegate
```

See [CLAUDE.md](CLAUDE.md) for full architecture documentation.

## OpenTelemetry (Telemetry)

SyncTray includes opt-in, anonymous telemetry powered by [OpenTelemetry](https://opentelemetry.io/) and exported to [Dash0](https://dash0.com/).

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

2. **Toggle "Anonymous Usage Data" ON** in the app's Settings window.

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

### Disabling Telemetry

- **In the app:** Toggle "Anonymous Usage Data" OFF in Settings. All telemetry methods become no-ops.
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

**No personal data is collected.** No file paths, profile names, remote names, or account info.

#### Metrics (exported every 60 seconds)

| Metric                         | Type          | Description                         |
| ------------------------------ | ------------- | ----------------------------------- |
| `synctray.sync.duration`       | Histogram     | Sync operation duration (seconds)   |
| `synctray.sync.completed`      | Counter       | Number of completed sync operations |
| `synctray.sync.files_changed`  | Counter       | Number of files changed during sync |
| `synctray.app.profiles.active` | UpDownCounter | Number of active sync profiles      |
| `synctray.app.launch`          | Counter       | Number of app launches              |

All sync metrics include `sync.mode` (bisync/sync/mount) and `sync.result` (success/failure) attributes.

#### Traces

| Span           | Kind     | Attributes                                       |
| -------------- | -------- | ------------------------------------------------ |
| `sync.execute` | INTERNAL | `sync.mode`, `sync.result`, `sync.files_changed` |

#### Resource Attributes

Every signal includes these resource attributes (overridable via `OTEL_RESOURCE_ATTRIBUTES`):

| Attribute                     | Default              | Source                             |
| ----------------------------- | -------------------- | ---------------------------------- |
| `service.name`                | `synctray`           | `OTEL_SERVICE_NAME` env var        |
| `service.namespace`           | `synctray`           | Hardcoded                          |
| `service.version`             | App bundle version   | `CFBundleShortVersionString`       |
| `service.instance.id`         | Anonymous UUID       | Generated on first opt-in          |
| `deployment.environment.name` | —                    | `OTEL_RESOURCE_ATTRIBUTES` env var |
| `os.type`                     | `darwin`             | Hardcoded                          |
| `os.version`                  | macOS version string | `ProcessInfo`                      |

### Dependencies

The telemetry feature uses [opentelemetry-swift](https://github.com/open-telemetry/opentelemetry-swift) (>= 1.0.0) via Swift Package Manager:

- `OpenTelemetryApi` — API interfaces
- `OpenTelemetrySdk` — SDK implementation (stable meter API)
- `OpenTelemetryProtocolExporterHTTP` — OTLP/HTTP exporter

### Key Files

| File                                     | Role                                                                         |
| ---------------------------------------- | ---------------------------------------------------------------------------- |
| `Services/TelemetryService.swift`        | Singleton that configures OTel SDK, creates instruments, and records signals |
| `Models/Settings.swift`                  | `telemetryEnabled` and `installationId` in UserDefaults                      |
| `SyncTrayApp.swift`                      | Calls `configure()` at launch, `shutdown()` at termination                   |
| `Services/SyncManager.swift`             | Records sync completions and profile counts                                  |
| `Views/Settings/ProfileDetailView.swift` | UI toggle for opting in/out                                                  |

## Debugging

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

Located at `~/.cache/rclone/bisync/`. Use "Fix Sync Issues" in the app to force a `--resync`.

### Lock Files

```bash
ls -la /tmp/synctray-sync-*.lock
```

Stale locks are cleaned on app startup.

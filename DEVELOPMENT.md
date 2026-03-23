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

1. **Set the `DASH0_AUTH_TOKEN` environment variable** with a valid Dash0 auth token:

   ```bash
   # In your shell profile (~/.zshrc, ~/.bashrc, etc.)
   export DASH0_AUTH_TOKEN="your-dash0-auth-token-here"
   ```

   Or in Xcode: **Scheme > Run > Arguments > Environment Variables** — add `DASH0_AUTH_TOKEN`.

   > Without a valid token, the telemetry service skips initialization entirely (no wasted network requests).

2. **Toggle "Anonymous Usage Data" ON** in the app's Settings window.

### Disabling Telemetry

- **In the app:** Toggle "Anonymous Usage Data" OFF in Settings. All telemetry methods become no-ops.
- **At build time:** Simply don't set `DASH0_AUTH_TOKEN`. The service detects the placeholder value and skips setup.

### Endpoint Configuration

| Setting | Value |
|---------|-------|
| OTLP Endpoint | `https://ingress.europe-west4.gcp.dash0-dev.com` |
| Metrics path | `/v1/metrics` |
| Traces path | `/v1/traces` |
| Auth header | `Authorization: Bearer $DASH0_AUTH_TOKEN` |

The endpoint is hardcoded in `TelemetryService.swift`. To point at a different collector (e.g., a local one for testing), modify `TelemetryService.endpoint`.

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

Then change the endpoint in `TelemetryService.swift` to `http://localhost:4318`.

### What's Collected

**No personal data is collected.** No file paths, profile names, remote names, or account info.

#### Metrics (exported every 60 seconds)

| Metric | Type | Description |
|--------|------|-------------|
| `synctray.sync.duration` | Histogram | Sync operation duration (seconds) |
| `synctray.sync.completed` | Counter | Number of completed sync operations |
| `synctray.sync.files_changed` | Counter | Number of files changed during sync |
| `synctray.app.profiles.active` | UpDownCounter | Number of active sync profiles |
| `synctray.app.launch` | Counter | Number of app launches |

All sync metrics include `sync.mode` (bisync/sync/mount) and `sync.result` (success/failure) attributes.

#### Traces

| Span | Kind | Attributes |
|------|------|------------|
| `sync.execute` | INTERNAL | `sync.mode`, `sync.result`, `sync.files_changed` |

#### Resource Attributes

Every signal includes:

| Attribute | Value |
|-----------|-------|
| `service.name` | `synctray` |
| `service.namespace` | `synctray` |
| `service.version` | App bundle version |
| `service.instance.id` | Anonymous UUID (generated on first opt-in) |
| `deployment.environment.name` | `production` |
| `os.type` | `darwin` |
| `os.version` | macOS version string |

### Dependencies

The telemetry feature uses [opentelemetry-swift](https://github.com/open-telemetry/opentelemetry-swift) (>= 1.0.0) via Swift Package Manager:

- `OpenTelemetryApi` — API interfaces
- `OpenTelemetrySdk` — SDK implementation (stable meter API)
- `OpenTelemetryProtocolExporterHTTP` — OTLP/HTTP exporter

### Key Files

| File | Role |
|------|------|
| `Services/TelemetryService.swift` | Singleton that configures OTel SDK, creates instruments, and records signals |
| `Models/Settings.swift` | `telemetryEnabled` and `installationId` in UserDefaults |
| `SyncTrayApp.swift` | Calls `configure()` at launch, `shutdown()` at termination |
| `Services/SyncManager.swift` | Records sync completions and profile counts |
| `Views/Settings/ProfileDetailView.swift` | UI toggle for opting in/out |

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

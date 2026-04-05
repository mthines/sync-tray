# Telemetry Instrumentation Guide

This project uses OpenTelemetry (opentelemetry-swift 1.17.1) for anonymous, opt-in telemetry.
All telemetry is gated behind `SyncTraySettings.telemetryEnabled` — methods are no-ops when disabled.

## Architecture

```
TelemetryService.swift (singleton)
├── Traces  → OtlpHttpTraceExporter  → OTLP/HTTP endpoint
├── Metrics → StableOtlpHTTPMetricExporter → OTLP/HTTP endpoint
└── Logs    → OtlpHttpLogExporter    → OTLP/HTTP endpoint
```

All three signals share the same `Resource` (service.name, service.instance.id, os.type, etc.)
so every piece of telemetry is automatically correlated to the installation.

## How to Add New Telemetry

### 1. Add a method to `TelemetryService.swift`

Follow the existing pattern:

```swift
func recordSomethingHappened(profileId: UUID, profileName: String, ...) {
    guard SyncTraySettings.telemetryEnabled else { return }
    ensureSetup()

    // Metric (if counting/measuring)
    someCounter?.add(value: 1, attribute: [
        "synctray.profile.name": .string(profileName),
        "some.attribute": .string(value),
    ])

    // Log (for per-event visibility)
    emitLog(
        severity: .info,  // .info, .warn, .error
        body: "Something happened",
        attributes: [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            // ... additional context
        ]
    )
}
```

### 2. Call it from `SyncManager.swift` (or other services)

```swift
TelemetryService.shared.recordSomethingHappened(
    profileId: profile.id,
    profileName: profile.name
)
```

### 3. For new metric instruments, register them in `setupOTel()`

```swift
someCounter = meter
    .counterBuilder(name: "synctray.something.count")
    .setDescription("Number of something events")
    .setUnit("1")
    .build()
```

## Signal Types and When to Use Each

| Signal | When to use | Example |
|--------|-------------|---------|
| **Metric** | Aggregatable counts, durations, gauges | `synctray.sync.duration`, `synctray.sync.errors` |
| **Span** | Operations with duration (start→end) | Sync lifecycle, mount operations |
| **Log** | Individual events with context | "Sync started", "Transport changed", errors |

## File Operation Telemetry

File operations are tracked as a counter with operation type and **normalized** file extension:
- Extensions are mapped to a fixed allowlist (~30 common types) or `(other)` to cap cardinality
- Files with no extension get `(none)`
- Never include file names, paths, or sizes in attributes

```swift
TelemetryService.shared.recordFileOperation(
    profileName: profileName,
    operation: change.operation.rawValue,  // "Copied", "Deleted", etc.
    filePath: change.path                  // only extension is extracted
)
```

## Profile Configuration Snapshots (RUM)

On app launch and every profile save, a structured log captures the user's chosen configuration:
- `config.sync_mode`, `config.sync_direction`, `config.sync_interval_bucket`
- `config.has_fallback`, `config.has_external_drive`, `config.is_enabled`, `config.is_muted`
- Mount-specific: `config.vfs_cache_mode`, `config.has_pinned_directories`, `config.pinned_directory_count`
- A summary log with `config.total_profiles`, `config.enabled_profiles`, mode breakdown

This lets you understand feature adoption and preference patterns across installations.
**Never** include paths, remote names, or credentials in config snapshots.

## Active Span Lifecycle

For operations with real duration (like syncs), use the `activeSyncSpans` pattern:

1. `recordSyncStarted()` creates a span and stores it in `activeSyncSpans[profileId]`
2. `recordSyncCompleted()` or `recordSyncFailed()` retrieves and ends the span
3. On `shutdown()`, any orphaned spans are ended with `sync.result=app_shutdown`

## Rules

### Privacy
- **Never** include file paths, remote URLs, or user-identifiable data in telemetry
- Only use low-cardinality, bounded values (enum cases, profile names, error types)
- Profile names are user-chosen display names (e.g., "Work", "Personal"), not paths
- Error messages are categorized into types (e.g., "network", "timeout", "permission_denied")
  via `categorizeError()` — the raw message is truncated to 256 chars max

### Naming
- Metric names: `synctray.<domain>.<measurement>` (e.g., `synctray.sync.duration`)
- Span names: `synctray <operation>` (e.g., `synctray sync`, `synctray mount`)
- Attribute names: `synctray.profile.id`, `sync.mode`, `error.type`, etc.

### Attributes always included
- `synctray.profile.id` — UUID identifying the profile
- `synctray.profile.name` — Display name of the profile
- `sync.mode` — bisync, sync, or mount (where relevant)

### Resource attributes (automatic on all signals)
- `service.name` = synctray
- `service.instance.id` = persistent UUID per installation (differentiates users)
- `service.version` = app version
- `os.type` = darwin
- `os.version` = macOS version

## Current Instrumentation

### Metrics
| Metric | Type | Description |
|--------|------|-------------|
| `synctray.sync.duration` | Histogram | Duration of sync operations (seconds) |
| `synctray.sync.completed` | Counter | Sync operations completed (by mode + result) |
| `synctray.sync.files_changed` | Counter | Files changed during sync |
| `synctray.sync.errors` | Counter | Sync errors by type |
| `synctray.app.profiles.active` | UpDownCounter | Number of active profiles |
| `synctray.app.launch` | Counter | App launches |
| `synctray.mount.operations` | Counter | Mount/unmount operations |
| `synctray.directory_watch.triggers` | Counter | Directory change triggers |
| `synctray.transport.fallback_activations` | Counter | Fallback remote activations |
| `synctray.sync.file_operations` | Counter | File operations by type + extension |

### Spans
| Span | Kind | Description |
|------|------|-------------|
| `synctray sync` | INTERNAL | Full sync lifecycle (start→complete/fail) |
| `synctray mount` | INTERNAL | Mount operation |
| `synctray unmount` | INTERNAL | Unmount operation |

### Logs
All key lifecycle events are emitted as structured OTel logs:
- Sync started/completed/failed (with profile context, duration, files changed)
- Mount/unmount success/failure
- Directory watch triggers
- Transport changes (primary ↔ fallback)
- Sync errors (with categorized error type)
- Drive not mounted warnings
- Profile state changes (paused/resumed)
- App launch
- Profile configuration snapshots (RUM — sync mode, interval, feature toggles)
- Configuration summary (profile count breakdown by mode)

## Configuration

Priority (first non-empty wins):
1. Process environment variables
2. `~/.config/synctray/.env` file
3. Info.plist values

Key env vars:
- `OTEL_EXPORTER_OTLP_ENDPOINT` — OTLP endpoint URL
- `OTEL_EXPORTER_OTLP_HEADERS` — Auth headers (comma-separated Key=Value)
- `DASH0_AUTH_TOKEN` — Convenience auth token
- `OTEL_SERVICE_NAME` — Override service name (default: synctray)
- `OTEL_RESOURCE_ATTRIBUTES` — Additional resource attributes

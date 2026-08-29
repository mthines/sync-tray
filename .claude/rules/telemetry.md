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
- Mount-specific: `config.mount_backend` (nfs/macfuse), `config.mount_at_startup` (true/false), `config.vfs_cache_mode`, `config.has_pinned_directories`, `config.pinned_directory_count`
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
- **Never** include file paths, sync remote URLs (rclone remote configs — S3/SFTP/WebDAV
  endpoints, etc.), or user-identifiable data in telemetry
- Only use low-cardinality, bounded values (enum cases, profile names, error types)
- Profile names are user-chosen display names (e.g., "Work", "Personal"), not paths
- Error messages are categorized into types (e.g., "network", "timeout", "permission_denied")
  via `categorizeError()` — the raw message is truncated to 256 chars max
- **Carve-out:** `vcs.repository.url.full` (the *source code* repository's origin
  remote, e.g. `https://github.com/mthines/sync-tray`) is exempt from the remote-URL
  ban above. It identifies the codebase the binary was built from, not a user's sync
  destination, carries no user data, and has embedded credentials stripped at build
  time (see Source correlation below) before it ever reaches telemetry.

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
- `service.namespace` = synctray
- `service.instance.id` = random UUID per installation (changes on reinstall)
- `enduser.id` = HMAC-SHA256 of hardware UUID (stable across reinstalls, not reversible)
- `service.version` = deployment-precise version (see below)
- `deployment.environment.name` = `development` for DEBUG builds, `production` for Release
  (overridable via `OTEL_RESOURCE_ATTRIBUTES`)
- `os.type` = darwin
- `os.version` = macOS version
- `host.arch` = `arm64` / `amd64`, resolved at compile time (a universal binary reports
  the executing slice, not the host's native arch); omitted on any other architecture
  rather than sending an undocumented value
- `vcs.repository.url.full` = canonical https URL of the `origin` remote (see below)
- `vcs.repository.ref.revision` = full commit SHA the binary was built from (see below)

`enduser.id` is the primary user correlation key — it survives app reinstalls because
it's derived from the machine's hardware UUID via a one-way hash.

### Source correlation
`vcs.repository.url.full` and `vcs.repository.ref.revision` let a backend resolve any
signal to the exact source revision that produced it — the pair Dash0 and agentic
tooling look for to jump from a log line straight to the code that emitted it.

Both are injected into `Info.plist` by the `Embed Git Metadata` build phase
(`VCSRepositoryURL` / `GitCommitSHAFull` keys) and read back by
`TelemetryService.infoPlistBuildValue`. The remote URL is normalised at build time:
scp-style SSH (`git@host:owner/repo.git`) and `ssh://` forms are converted to `https://`,
**embedded credentials are stripped**, and the trailing `.git` is dropped. Credentials
must never reach telemetry, so that strip is not optional — if you extend the
normalisation, keep it.

When building from a non-git source tree the phase logs a warning and both attributes
are simply absent, exactly as `service.version` degrades to `<marketing>+<build>`.

### Deployment correlation
`service.version` is the primary key Dash0 uses to correlate telemetry to a specific
release. `TelemetryService.appVersion()` builds it from
`CFBundleShortVersionString` + `CFBundleVersion` + the git short SHA, e.g.
`0.34.0+1.gabc1234`, so every shipped commit is a distinct deployment for
version-aware comparison and regression detection.

The SHA is injected into `Info.plist` (`GitCommitSHA` key) by the `Embed Git Metadata`
Xcode build phase (`PlistBuddy` on the built plist; `alwaysOutOfDate` so it
re-runs every build). When unavailable (non-git source tree), `service.version`
gracefully falls back to `<marketing>+<build>`.

The same phase also writes `GitCommitSHAFull` and `VCSRepositoryURL` — see
[Source correlation](#source-correlation). Any key it writes must stay in sync across
three files: the phase (writer), `SyncTray/Info.plist` (placeholder), and
`TelemetryService.infoPlistBuildValue` (reader).

On launch, `recordDeploymentIfChanged()` compares the current `service.version`
against `SyncTraySettings.lastLaunchedVersion` and, on a change, emits an
`App upgraded` log (`deployment.from_version` / `deployment.to_version`). Dash0
overlays these as dashboard annotations so metric/trace changes can be tied to a
rollout. No event is emitted on a fresh install.

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
| `synctray.remote.config_operations` | Counter | Remote config operations (create/update/delete/connection_test) by provider type + result |
| `synctray.sync.contention` | Counter | Syncs skipped because another was already running (lock file contention) |
| `synctray.logwatcher.recovery` | Counter | LogWatcher recovery events (file_replaced, missed_bytes, polling_error) |
| `synctray.startup.stale_locks_cleaned` | Counter | Stale lock files cleaned on startup (synctray or rclone_bisync) |
| `synctray.sync.check_phase_duration` | Histogram | Duration of bisync listing/check phase (seconds) — main bottleneck for large repos |
| `synctray.drive.events` | Counter | External drive mount/unmount events detected by NSWorkspace |
| `synctray.directory_watch.filtered` | Counter | Directory watch events filtered out (out_of_scope, phantom, metadata) |
| `synctray.sync.resumed_external` | Counter | Externally-started syncs detected and resumed at app startup |
| `synctray.app.settings_opened` | Counter | Settings window opens |
| `synctray.sync.auto_fix_triggered` | Counter | Automatic --resync recovery attempts (`result`: `triggered` or `gave_up_backoff`) |
| `synctray.offline.pin_operations` | Counter | Offline pin/unpin operations from Finder or in-app UI (`action`: `pin` or `unpin`) |
| `synctray.wizard.step` | Counter | Onboarding funnel events (`wizard.outcome`: started/provider_selected/remote_ready/folder_chosen/created/abandoned; `wizard.abandoned_at_step`, `provider.type`) |
| `synctray.remote.oauth` | Counter | OAuth auth outcomes during remote setup (`result`: success/failure/cancelled; `provider.type`) |
| `synctray.recovery.user_action` | Counter | User-initiated sync recovery actions (`recovery.action`: force_sync/resync/retry/…) — distinct from automatic auto-fix |
| `synctray.setting.changed` | Counter | App-wide preference changes (`setting.name`: auto_fix/launch_at_login/debug_logging/telemetry; `setting.enabled`) |
| `synctray.offline.extension_setup` | Counter | Finder-extension enable funnel (`offline.extension_action`: prompt_shown/open_settings/rechecked/enabled) |
| `synctray.offline.cache_clear` | Counter | Cache-clear operations (`offline.preserve_pinned`: whether pinned folders were kept) |

### Spans
| Span | Kind | Description |
|------|------|-------------|
| `synctray sync` | INTERNAL | Full sync lifecycle (start→complete/fail) |
| `synctray mount` | INTERNAL | Mount operation |
| `synctray unmount` | INTERNAL | Unmount operation |

### Logs
All key lifecycle events are emitted as structured OTel logs:
- Sync started/completed/failed (with profile context, duration, files changed; started carries `sync.trigger`: manual/directory_watch/scheduled/startup)
- Mount/unmount success/failure
- Directory watch triggers
- Transport changes (primary ↔ fallback)
- Sync errors (with categorized error type)
- Drive not mounted warnings
- Profile state changes (paused/resumed)
- App launch
- Profile configuration snapshots (RUM — sync mode, interval, feature toggles)
- Configuration summary (profile count breakdown by mode)
- Remote config operations: create/update/delete/connection_test (with provider type and categorized error type)
- Sync contention: sync skipped because another was already running (bottleneck detection)
- LogWatcher recovery: file replaced, missed bytes, polling errors (monitoring health) — **coalesced into episodes**: the first event of a run emits `LogWatcher recovery: <reason>` immediately, further events within a 60s quiet window are folded into a single `LogWatcher recovery episode ended: <reason>` carrying `logwatcher.recovery_count`, `logwatcher.missed_bytes`, and `logwatcher.episode_duration_seconds`. The `synctray.logwatcher.recovery` counter still records **every** event, so the true rate is unaffected. A single-event episode emits no summary.
- Stale lock cleanup: count and type of stale locks cleaned at startup (crash detection)
- Check phase duration: bisync listing/comparison phase timing (bottleneck analysis)
- Session heartbeat: periodic (5min) alive signal with profile state summary (availability)
- Volume events: external drive mount/unmount with affected profile count (drive workflow RUM)
- Sync precondition failures: script_not_found, config_not_found (setup issue detection)
- Resumed external syncs: syncs detected running at startup (launchd overlap detection)
- App upgraded: `service.version` changed since the previous launch (deployment markers)
- Auto-fix: automatic --resync triggered (`triggered`), suppressed by backoff (`gave_up_backoff`), or skipped because the external drive is not mounted (`skipped_drive_not_mounted`)
- Offline pin operations: directory pinned or unpinned via Finder right-click or in-app UI (`offline.action`, `offline.path_count`)
- Wizard step: onboarding funnel events (`wizard.outcome`, `wizard.abandoned_at_step`, `provider.type`) — new-profile flow only, not edit mode
- OAuth outcome: OAuth auth result during remote setup (`result`, `provider.type`)
- User recovery action: user-initiated recovery from the error banner (`recovery.action`) — distinct from automatic auto-fix
- Setting changed: app-wide preference toggled (`setting.name`, `setting.enabled`); the telemetry opt-out is recorded just before telemetry disables
- Offline extension setup: Finder-extension enable-funnel steps (`offline.extension_action`)
- Offline cache clear: cache cleared, with whether pinned folders were preserved (`offline.preserve_pinned`)

## Swift SDK Gotcha: Wildcard View Required

opentelemetry-swift 1.17.1's stable metrics API requires an explicit view registration
with a `".*"` wildcard selector. Without it, instruments silently record to no-op storage
and `collectAllMetrics()` returns empty. This differs from every other OTel SDK.

```swift
StableMeterProviderSdk.builder()
    .setResource(resource: resource)
    .registerView(
        selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
        view: StableView.builder().build()
    )
    .registerMetricReader(reader: metricReader)
    .build()
```

Ref: https://github.com/open-telemetry/opentelemetry-swift/issues/500

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

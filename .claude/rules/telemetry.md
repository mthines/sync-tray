# Telemetry Instrumentation Guide

This project uses OpenTelemetry (opentelemetry-swift 1.17.1) for pseudonymous, opt-in telemetry.
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
- Mount-specific: `config.mount_backend` (nfs/macfuse), `config.mount_at_startup` (true/false), `config.stream_cache_only` (true/false; `n/a` for non-mount — the union-overlay Cache-only mount toggle), `config.vfs_cache_mode`, `config.has_pinned_directories`, `config.pinned_directory_count`, `config.download_connections` (parallel `--transfers`/warm concurrency, 1–16; `0` for non-mount profiles), `config.has_bandwidth_limit` (bool — whether an rclone `--bwlimit` cap is set; presence only, never the rate value; all modes), `config.mount_resilient` (true/false — the bounded rclone `--timeout` hard mount that stops a stalled backend freezing Finder without the soft-mount sticky-EPERM downside; `n/a` for non-mount), `config.cache_fs_type` (bucketed filesystem of the VFS cache volume: apfs/hfs/exfat/fat/ntfs/network/other/unknown; `n/a` for non-mount), `config.cache_volume` (internal/external/unknown; `n/a` for non-mount)
- Two-Way / One-Way: `config.sync_exclude_pattern_count` (number of "Don't Sync" patterns; `0` for mount profiles — the patterns themselves are never sent), `config.sync_include_folder_count` (number of "Sync Only These Folders" selective-folder entries; `0` for mount profiles — the folder names themselves are never sent)
- Folder kind and storage backend (all modes), never the path or the remote's name:
  - `config.local_path_kind` — `SyncPathKind.classify` of the local folder: `desktop`/`documents`/`downloads`/`pictures`/`music`/`movies`/`public` (`~/<Folder>` or below), `icloud_drive` (`~/Library/Mobile Documents`), `cloud_storage` (`~/Library/CloudStorage`), `library` (anything else under `~/Library`), `home_root` (the home folder itself), `home_other`, `external_volume` (`/Volumes/<name>/…`), `other`, `unknown` (empty). Case-insensitive, `~`-expanding, trailing-slash tolerant
  - `config.local_path_privacy_protected` (bool) — true for `desktop`, `documents`, `downloads`, `icloud_drive`, `library`, `external_volume`: folders macOS privacy controls (TCC) can refuse a launchd-run script
  - `config.remote_type` / `config.fallback_remote_type` — the remote's `type = …` from rclone.conf (`RcloneConfigService.remoteType(named:inConfig:)`), bucketed by `RemoteBackendType.bucket` through an allowlist of rclone backend names (`drive`, `protondrive`, `smb`, `s3`, …): a known type is itself, any other type `other`, a missing section / no rclone.conf `unknown`; the fallback is `none` when no fallback is configured. rclone.conf is read once per launch snapshot (and once per profile save), on a background `.utility` queue — the `Profile configuration` logs are emitted on main once it has been read
- A summary log with `config.total_profiles`, `config.enabled_profiles`, mode breakdown

This lets you understand feature adoption and preference patterns across installations.
**Never** include paths, remote names, or credentials in config snapshots.

## Active Span Lifecycle

For operations with real duration (like syncs), use the `activeSyncSpans` pattern:

1. `recordSyncStarted()` creates a span and stores it in `activeSyncSpans[profileId]`
2. `recordSyncCompleted()` or `recordSyncFailed()` retrieves and ends the span
3. On `shutdown()`, any orphaned spans are ended with `sync.result=app_shutdown`

The span exports only when it ends, so a long run is otherwise invisible until it finishes —
the heartbeat's `Sync progress` log (below) covers the time in between and carries the open
span's context.

**A failed run is counted once.** A failed bisync reports its end twice: rclone's "Failed to
bisync: …" notice, then the wrapper's "Bisync failed with exit code N" (sync script and
auto-fix resync) — each a `.syncFailed`. `recordSyncFailed` therefore records nothing for a
failure that repeats one recorded for the same profile within
`TelemetryService.duplicateSyncFailureWindow` (15 s), unless a run started or a success was
recorded in between (`isDuplicateSyncFailure`, pure). Without it,
`synctray.sync.completed{sync.result=failure}` and `synctray.sync.errors` counted every failed
bisync twice and `synctray.sync.duration` got a second, 0 s sample. Force Sync and the profile
editor's resync log no start and report a failure once (Force Sync's own exit line has no
timestamp, so it is never parsed); `SyncManager.beginExclusiveRun` calls
`forgetLastSyncFailure` when one of them starts, so theirs always counts. Covered by
`ConfigSelfTest` AC-TS6. The app applies the same rule to the error state, the "Sync failed"
notification and auto-fix (`SyncManager.syncFailureHandling`, AC-SF1; CLAUDE.md "A failed run
is handled once").

## Per-profile Heartbeat Logs

The 5-minute session heartbeat (`SyncManager.startSessionHeartbeat`) emits the aggregate
`Session heartbeat` log (unchanged — dashboards depend on it) and then, via
`SyncManager.recordProfileHeartbeatTelemetry`, two per-profile logs. State is captured on the
main actor; lock files, rclone.conf and `ps` are read on a background queue
(`SyncManager.profileHeartbeatReports`) and only when telemetry is on, so an opted-out user
gets no extra process spawns. `ps -A` runs at most once per heartbeat, plus one `ps -o args=`
per live lock-holder PID that isn't the app's own.

**`Sync progress`** (info) — one per Two-Way / One-Way profile whose run is live (`isRunLive`'s
rule: registry token or a live lock holder) or whose state is `.syncing`. Correlated to the
open `synctray sync` span. Attributes (`TelemetryService.syncProgressAttributes`, pure):
`synctray.profile.id`, `synctray.profile.name`, `sync.mode`, `sync.progress.has_stats` (false
until rclone's first stats line has been parsed), `sync.run_age_s` (when the app saw the run
start), and with stats: `sync.progress.bytes_transferred`, `sync.progress.bytes_total`,
`sync.progress.transfers_done`, `sync.progress.transfers_total`, `sync.progress.checks_done`,
`sync.progress.checks_total`, `sync.progress.errors`, plus `sync.progress.speed_bps`,
`sync.progress.eta_s`, `sync.progress.elapsed_s`, `sync.progress.listed` when rclone reported
them. **Never** the names of the files in flight (`SyncProgress.transferringFiles`).

**`Profile status`** (info) — one per enabled profile (`TelemetryService.profileStatusAttributes`):
`synctray.profile.id`, `synctray.profile.name`, `sync.mode`, `profile.state`
(`idle`/`syncing`/`paused`/`error`/`drive_not_mounted`/`not_configured`; a profile in
`pausedProfiles` is `paused`), `profile.run_live` (bool, `SyncManager.runLiveness`),
`sync.lock_state`, `sync.session_lock_state`, `error.type` (only in an error state, from the
stored error, or the state's own message when none was stored — "Script not found" / "Config
not found" never store one), `config.local_path_kind`, `config.remote_type`,
`config.fallback_remote_type`.

`sync.lock_state` describes the `/tmp` run lock and `sync.session_lock_state` the rclone bisync
session `.lck` (`SyncRunLock.lockState`, pure):

| Value | Meaning |
|-------|---------|
| `none` | No lock file, or an empty one |
| `pending` | The legacy `"pending"` sentinel (the guard treats it as live) |
| `unreadable` | Neither a PID nor rclone's lock JSON |
| `stale` | The PID is no longer running |
| `live_app` | The PID is the app's own — the launch-gap placeholder |
| `live_verified` | The PID is alive and identified as this profile's run (`SyncAbort.isProfileProcess`: `bash`/the script naming this profile's `configPath`, or an rclone with its `localSyncPath` as a whole argument — not a folder inside it, not a `--filter-from` path under it — whatever its parent) |
| `live_unverified` | The PID is alive but NOT identifiable as this profile's run — the signature of a stale lock whose PID was reused, which `kill(pid, 0)` alone counts as live |
| `n/a` | Both values for a Stream profile (its `/tmp` lock is the mount daemon's for the mount's whole life — Critical Rule 8 / R7); the session value for a One-Way profile (only bisync has a session lock) |

## Error categories

`error.type` (`TelemetryService.categorizeError`, pure) is a bounded bucket of an error
message; the message itself never leaves the machine. Order: the `SyncLogPatterns` checks
(`out_of_sync`/`critical`, `transient_all_files_changed`, `exclusive_mode_unsupported`,
`permission_denied` for EPERM, `io_errors_blocked_deletes`), then the specific buckets of
`TelemetryService.specificErrorBuckets` (lowercased, first match wins), then the original
generic checks (`file_not_found`, `permission_denied`, `timeout`, `network`), else `other`;
`unknown` for no message. A message the old buckets matched keeps its bucket unless it also
names a more specific cause (e.g. a rate-limit or auth phrase), which now wins; besides that,
Go's "directory not empty" moved from `critical` to `directory_not_empty`.

| Bucket | Matches (lowercased) |
|--------|----------------------|
| `disk_full` | "no space left on device" |
| `rate_limited` | "ratelimitexceeded", "userratelimitexceeded", "rate limit exceeded", "too many requests" — before `quota_exceeded`, since Google's per-minute limit says "Quota exceeded … rateLimitExceeded" |
| `quota_exceeded` | "storagequotaexceeded", "quotaexceeded", "quota exceeded", "insufficient storage" |
| `network` | "no such host" (ahead of the generic "no such" → `file_not_found`), "connection reset", "connection refused", "network is unreachable", "broken pipe" — plus the generic "network"/"connection" |
| `timeout` | "context deadline exceeded", "deadline exceeded", "i/o timeout", "timed out", "handshake timeout" — ahead of `auth_failed`, so "oauth2: cannot fetch token: … i/o timeout" stays a timeout; plus the generic "timeout" |
| `tls_certificate` | " x509:", " tls:", "certificate signed by", "certificate has expired", "certificate verify failed" (Go's error prefixes, not the bare words "x509" / "certificate", which would claim errors about a file named "x509.pem" or "…Certificate.pdf"; the two prefixes carry a leading space and are matched against the message with one leading space added, so a message starting with Go's prefix still matches while a path segment named `tls`/`x509` — "…/certs/tls: permission denied" — isn't claimed). Go's TLS alert "tls: bad certificate" is covered by " tls:", so there is no separate "bad certificate" needle, which a file named "Bad Certificate.pdf" would match |
| `auth_failed` | "invalid_grant", "token expired", "expired token", " oauth2:", "401 unauthorized", "authentication failed", "couldn't fetch token", "failed to refresh token" — after `network`/`timeout`/`tls_certificate`, so a token refresh that failed on DNS, TLS or a timeout keeps that cause; the oauth2 prefix carries a leading space like the TLS prefixes, so a folder named `oauth2` — "…/x/oauth2: permission denied" — isn't claimed |
| `name_too_long` | "file name too long", "name too long", "path too long" |
| `invalid_name` | "illegal character", "invalid characters", "invalid name", "invalid file name", "invalid filename" (plural "characters": Go's JSON decoder says "invalid character '<' looking for beginning of value" when a proxy returns HTML, which stays `other`) |
| `checksum_mismatch` | "corrupted on transfer", "hash differ", "hashes differ", "md5 differ", "sizes differ" |
| `file_changed_during_transfer` | "source file is being updated", "changed size during" |
| `file_busy` | "resource busy", "text file busy", "file is locked", "being used by another process" |
| `duplicate_object` | "duplicate object found", "duplicate directory found" — rclone's own sync log phrases ("Duplicate object found in source - ignoring", "Duplicate directory found in destination - ignoring", from fs/march), so a folder or file named e.g. "Duplicate Files" isn't claimed |
| `directory_not_empty` | Go's ENOTEMPTY "directory not empty" — split out of `critical`, whose "not empty" is there for rclone mount's "Directory is not empty" mount-point error (still `critical`) |

`error.operation` (`TelemetryService.categorizeErrorOperation`, pure) on the `Sync error` log and
the `Sync failed` log and span says which rclone operation failed: `copy` | `delete` | `move`
(move or rename) | `list` | `mkdir` | `other`. Conservative: rclone's own prefixes first ("Failed
to copy", "Couldn't delete", "Failed to move"/"Couldn't move"/"Failed to rename", "error
listing"/"failed to list"/"error reading source/destination directory" (rclone's march listing
errors, root directory included), "failed to rmdir" (rclone's rmdir/rmdirs failures, labelled
`delete`), "mkdir" as a word (Go's "mkdir <path>:", rclone's "… mkdir:") or "make directory"), the
bare words "copy"/"delete"/"listing" last, since a file path in the message can contain them.
Log/span only — never a metric label.

## Rules

### Privacy
- **Never** include file paths, sync remote URLs (rclone remote configs — S3/SFTP/WebDAV
  endpoints, etc.), or user-identifiable data in telemetry
- Only use low-cardinality, bounded values (enum cases, profile names, error types)
- Profile names are user-chosen display names (e.g., "Work", "Personal"), not paths
- Error messages are categorized into types (e.g., "network", "timeout", "permission_denied")
  via `categorizeError()` — the raw message is **never** sent (not as an attribute, not as
  a span status description): it routinely carries paths and remote names, and the in-app
  privacy disclosure (`TelemetryDetailsSheet`) promises "never the raw message". See
  [Error categories](#error-categories) for the buckets
- A `permission_denied` failure also carries bounded `error.access_denial`
  (`operation_not_permitted` = EPERM/macOS privacy, `permission_denied` = EACCES/file
  permissions), `error.blocked_path.kind` (`volume_system_folder` / `photos_library` / `photo_booth_library` / `other`)
  and `error.blocked_path.in_sync_folder` from `TelemetryService.accessDenialAttributes` —
  derived from the message, never the path itself
- **Carve-out:** `vcs.repository.url.full` (the *source code* repository's origin
  remote, e.g. `https://github.com/mthines/sync-tray`) is exempt from the remote-URL
  ban above. It identifies the codebase the binary was built from, not a user's sync
  destination, carries no user data, and has embedded credentials stripped at build
  time (see Source correlation below) before it ever reaches telemetry.
- **Carve-out — user-sent diagnostic reports only:** the records a diagnostic report
  uploads (see [Diagnostic reports](#diagnostic-reports-user-sent) below) may carry log
  lines with paths, file and folder names, remote names and raw error text. They are
  exempt from the no-paths rule ONLY because the user explicitly sends each report after
  reading the disclosure (per-send consent, independent of `telemetryEnabled`). Never emit
  report content from any automatic code path, and never add these attributes to an
  automatic event.

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
- `synctray.process.kind` = `app` for the menu-bar app, `cli` for a headless `synctray` run
  (`TelemetryService.processKind`, set by `SyncTrayCLI.dispatch`). Same `service.name` for
  both — filter on this to separate CLI-originated events (a `cache move`, a `mount`) from
  the app's
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
- `vcs.ref.head.revision` = full commit SHA the binary was built from (see below)

`enduser.id` is the primary user correlation key — it survives app reinstalls because
it's derived from the machine's hardware UUID via a one-way hash.

### Source correlation
`vcs.repository.url.full` and `vcs.ref.head.revision` let a backend resolve any
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
| `synctray.sync.errors` | Counter | Sync errors by type (`error.type`); a `permission_denied` failure also carries `error.access_denial` (`operation_not_permitted`/`permission_denied`) — the only access-denial attribute on the counter |
| `synctray.app.profiles.active` | UpDownCounter | Number of active profiles |
| `synctray.app.launch` | Counter | App launches |
| `synctray.mount.operations` | Counter | Mount/unmount operations |
| `synctray.directory_watch.triggers` | Counter | Directory change triggers |
| `synctray.transport.fallback_activations` | Counter | Fallback remote activations |
| `synctray.sync.file_operations` | Counter | File operations by type + extension |
| `synctray.remote.config_operations` | Counter | Remote config operations (create/update/delete/connection_test) by provider type + result |
| `synctray.sync.contention` | Counter | Syncs skipped because another was already running (lock file contention) |
| `synctray.sync.rejected_concurrent_run` | Counter | A rejected concurrent run's own "prior lock file found" failure suppressed rather than surfaced as this profile's failure (the single-run guard's R3 behaviour — CLAUDE.md "One Run Per Profile"), by `rejected_concurrent_run.site`: `sync_failed` or `error_message` |
| `synctray.config.deferred_reinstall` | Counter | External profile edits whose reinstall was deferred because the profile's run was live, by `deferred_reinstall.outcome`: `deferred` (a sync was live at edit time), `applied` (the retry succeeded once the run ended), `failed` (the retry's install call itself threw), `dropped` (the profile was deleted or disabled while the reinstall was deferred, so the retry discarded it) |
| `synctray.logwatcher.recovery` | Counter | LogWatcher recovery events (file_replaced, missed_bytes, polling_error) |
| `synctray.startup.stale_locks_cleaned` | Counter | Stale lock files cleaned on startup (synctray or rclone_bisync) |
| `synctray.sync.check_phase_duration` | Histogram | Duration of bisync listing/check phase (seconds) — main bottleneck for large repos |
| `synctray.drive.events` | Counter | External drive mount/unmount events detected by NSWorkspace |
| `synctray.directory_watch.filtered` | Counter | Directory watch events filtered out (out_of_scope, phantom, metadata) |
| `synctray.sync.resumed_external` | Counter | Externally-started syncs detected and resumed at app startup |
| `synctray.app.settings_opened` | Counter | Settings window opens |
| `synctray.sync.auto_fix_triggered` | Counter | Automatic --resync recovery attempts (`result`: `triggered`, `recurred` — started again although the last resync succeeded and the next sync was out of sync anyway, `gave_up_recurring` — stopped after `AutoFixRecurrence.limit` such recurrences, `gave_up_backoff`, `skipped_drive_not_mounted`, or `blocked_already_running` — the single-run guard refused because another run already held the profile's lock) |
| `synctray.offline.pin_operations` | Counter | Offline pin/unpin operations from Finder or in-app UI (`action`: `pin` or `unpin`) |
| `synctray.wizard.step` | Counter | Onboarding funnel events (`wizard.outcome`: started/provider_selected/remote_ready/folder_chosen/created/abandoned; `wizard.abandoned_at_step`, `provider.type`) |
| `synctray.remote.oauth` | Counter | OAuth auth outcomes during remote setup (`result`: success/failure/cancelled; `provider.type`) |
| `synctray.recovery.user_action` | Counter | User-initiated sync recovery actions (`recovery.action`: force_sync/resync/retry/exclude_blocked_path/…; `recovery.result`: `started`, `staged` — the `exclude_blocked_path` banner action only stages the pattern into the form's "Don't Sync" list, no run started, see `apply_sync_filter` below for when it actually applies — or `blocked_already_running` — the single-run guard refused because another run already held the profile's lock) — distinct from automatic auto-fix |
| `synctray.setting.changed` | Counter | App-wide preference changes (`setting.name`: auto_fix/launch_at_login/debug_logging/telemetry, or menu_bar_icon_color/menu_bar_icon_monochrome/menu_bar_icon_custom with `setting.enabled=true` for the Menu Bar Icon style just chosen — the picked colors are never sent; `setting.enabled`) |
| `synctray.offline.extension_setup` | Counter | Finder-extension enable funnel (`offline.extension_action`: prompt_shown/open_settings/rechecked/enabled) |
| `synctray.offline.cache_clear` | Counter | Cache-clear operations (`offline.preserve_pinned`: whether pinned folders were kept) |
| `synctray.rclone.discovery` | Counter | rclone binary discovery at launch (`rclone.discovery_source`: candidate_path/login_shell/not_found; `rclone.location`: homebrew/usr_local/nix_system/nix_per_user/nix_profile/usr_bin/other/none) |
| `synctray.mount.reinstall_detach` | Counter | Pre-uninstall volume detach attempts for mount-mode profiles, reached on every `SyncSetupService.uninstall` (including the settings-save reinstall path) — `mount.result`: `not_mounted`/`success`/`success_forced`/`failure` |
| `synctray.mount.reinstall_detach.duration` | Histogram | Time taken to gracefully detach a mounted volume before reinstall (seconds) — regression signal for the "settings change freezes an active Stream mount" failure mode; only recorded when the profile was actually mounted |
| `synctray.mount.cache_only_fallback` | Counter | Cache Only was requested (`streamCacheOnly`) but the mount settled on streaming — the silent script fallback when the partial-file exclude list can't be built. The "I enabled Cache Only but it's still streaming/downloading" case; invisible without this. Emitted once at the mode-change edge by `SyncManager.reconcileMountStatesOffMain`, guarded by `resumingFromCacheOnly` so a legitimate drain-and-resume flip isn't counted |
| `synctray.cli.invoked` | Counter | Headless `synctray` CLI invocations (`cli.command`: bounded verb — doctor/status/offline-status/profiles/logs/test-remote/listremotes/remote-folders/telemetry-status/telemetry-on/telemetry-off/settings-show/settings-get/settings-set/sync/mount/unmount/reinstall/install/cache-move/profile-create/profile-show/profile-set/profile-enable/profile-disable/profile-delete/profile-list/report/report-send/help, or `(other)`; `cli.result`: ok/error). Never carries args, paths, profile names, or remotes. Recorded once per run by `runMeasured`, then flushed via `flushForExit` before the process exits |
| `synctray.offline.warm.duration` | Histogram | Duration of an offline-file warming run, seconds (`warm.trigger`: manual/startup/finder_pin; `warm.outcome`: completed/cancelled) |
| `synctray.offline.warm.throughput` | Histogram | Average read throughput of a warming run, MB/s — the primary signal for slow-fallback diagnosis (the SFTP fallback caps aggregate throughput) |
| `synctray.offline.warm.files` | Counter | Files warmed into the VFS content cache (`warm.outcome`: completed/cancelled) |
| `synctray.offline.warm.bytes` | Counter | Bytes read through the mount while warming (`warm.outcome`: completed/cancelled) |
| `synctray.offline.warm.paused` | Counter | Offline-warm pause/resume events (`warm.pause_state`: paused/resumed; `warm.pause_source`: manual = the user's toggle, auto = an app was detected reading the mount, backoff = the warm hit a run of failed reads and paused itself to let a struggling link recover). The warm stops starting new file reads while paused, handing a saturated slow link back to interactive browsing. Auto/backoff events fire on the idle→paused edge |
| `synctray.mount.cached_read.throughput` | Histogram | Throughput of a timed 8 MB read of an already fully-cached file THROUGH a Stream mount, MB/s (`cache.fs_type`, `cache.volume`, `mount.backend`). The signal for "cached files are slow": healthy APFS ≈ 100 MB/s, an exFAT USB cache ≈ 0.2–7 MB/s |
| `synctray.mount.cached_read.first_byte` | Histogram | Time from open to the first 64 KB of that probe read, seconds (same labels) — the "file takes ages to open" symptom |
| `synctray.mount.cached_read.probes` | Counter | Mount read-health probes by `mount.read_health`: `healthy` (≥20 MB/s), `slow` (1–20), `degraded` (<1), `remote_fetch` (the "fully cached" file pulled bytes from the remote — cache-correctness, not speed), `no_candidate`, `failed` |
| `synctray.cache.migration.count` | Counter | Cache-directory migrations by outcome (`cache_migration.outcome`: completed/cancelled/a `CacheMigrationFailure` value/preflight_rejected) and `cache_migration.same_volume` |
| `synctray.cache.migration.duration` | Histogram | Duration of a cache-directory migration run, seconds |
| `synctray.cache.migration.throughput` | Histogram | Average copy throughput of a CROSS-volume cache-directory migration, MB/s (0 for a same-volume rename — a byte-for-byte throughput figure would be meaningless for a rename) |
| `synctray.cache.migration.files` | Counter | Files relocated during a cache-directory migration |
| `synctray.cache.migration.bytes` | Counter | Bytes relocated during a cache-directory migration |
| `synctray.overlay.upload.count` | Counter | Cache Only overlay upload runs by `upload.trigger` (resume/auto_resume/upload_now), `upload.outcome` and `upload.transport` |
| `synctray.overlay.upload.files` | Counter | Overlay files processed by an upload run, by `upload.file_result` (uploaded/conflict/already_uploaded/failed) |
| `synctray.overlay.upload.bytes` | Counter | Bytes uploaded from the Cache Only overlay to the remote |
| `synctray.overlay.upload.duration` | Histogram | Duration of a Cache Only overlay upload run, seconds |
| `synctray.mount.mode_changes` | Counter | Mount mode transitions for a Stream profile (`mount.mode`: streaming/cache_only_manual/cache_only_offline/cache_only_pending) |
| `synctray.mount.auto_resume` | Counter | Automatic Cache Only → Streaming resume decisions (`auto_resume.result`: resumed/deferred_busy/busy_check_failed) |
| `synctray.mount.listing_warm` | Counter | Whole-tree directory-*listing* warm runs on a streaming Stream mount (`listing_warm.outcome`: completed/failed/aborted/skipped — `aborted` = the descent backed off after too many consecutive refresh failures, i.e. the backend connection was dropping and the walk stopped flooding it; `listing_warm.directories_warmed`/`listing_warm.directories_failed`: the per-subtree descent's successful vs failed refresh nodes — a recursive refresh that warmed a whole subtree in one call counts as one `warmed`). Fired once per mount session by `SyncManager.startListingWarm` when the mount monitor first sees a profile mounted **streaming** — metadata only, no file bytes. The signal for "Finder browsing is instant after mount" vs the cold-listing "Loading…" spinner |
| `synctray.mount.listing_warm.duration` | Histogram | Duration of a whole-tree directory-listing warm run on mount, seconds (same labels) — rises with SMB round-trip latency and with how much of the tree the descent had to walk one level at a time (large subtrees where rclone's recursive refresh fails) |
| `synctray.mount.spotlight_marker` | Counter | `.metadata_never_index` marker writes at a streaming Stream mount root (`spotlight_marker.outcome`: written/exists/failed/skipped). Fired once per mount session by `SyncManager.writeSpotlightExclusionMarker` — stops macOS Spotlight bulk-indexing the freshly-mounted volume (a read storm that saturates the download slots and starves Finder). `exists` is the steady state (marker persists on the remote); `failed` means the write threw (e.g. mount not attached) |
| `synctray.mount.interruptions` | Counter | Stream mount interruptions observed by the mount monitor (`mount.interruption_kind`: `stall` = a `statfs` on the mount root has been outstanding for 15 s, the condition macOS reports as "Server connections interrupted"; `drop` = the volume left the mount table under a loaded agent with no deliberate-unmount marker). Also `mount.backend`, `mount.mode`, profile id/name. Emitted at detection by `SyncManager.trackMountInterruption` / `scheduleMountDropCheck` |
| `synctray.mount.interruption.duration` | Histogram | How long an interruption lasted, seconds (`mount.interruption_kind`, `mount.interruption_outcome`: recovered/dropped/unmounted, `mount.backend`, `mount.mode`, profile id/name). A stall runs from the start of the probe that stalled (a lower bound); a drop from when the monitor saw the volume gone |

### Spans
| Span | Kind | Description |
|------|------|-------------|
| `synctray sync` | INTERNAL | Full sync lifecycle (start→complete/fail) |
| `synctray mount` | INTERNAL | Mount operation |
| `synctray unmount` | INTERNAL | Unmount operation |
| `synctray reinstall_detach` | INTERNAL | Pre-uninstall graceful volume detach for a mount-mode profile (fires on every `uninstall`, including settings-save reinstall) |
| `synctray warm` | INTERNAL | Offline-file warming run for a profile's pinned folders (start→complete/cancel). Carries `warm.trigger`, `warm.outcome` (completed/cancelled), `warm.concurrency`, `warm.files`, `warm.bytes`, `warm.duration_seconds`, `warm.throughput_mbps`. Exports on end, so an in-progress warm shows only the "Offline warm started" log, not the span. Cancelled when the cache is cleared, the profile is unmounted, or a newer run supersedes it. |
| `synctray cache_migration` | INTERNAL | Cache-directory move for a Stream profile (start→complete/cancel/fail). Carries `cache_migration.outcome`, `cache_migration.same_volume`, `cache_migration.files`, `cache_migration.bytes`, `cache_migration.duration_seconds`, `cache_migration.throughput_mbps`. Never carries a cache path, source/destination directory, or remote name — only the profile id and its display name, same carve-out as every other span here. |

### Logs
All key lifecycle events are emitted as structured OTel logs:
- Sync started/completed/failed (with profile context, duration, files changed; started carries `sync.trigger`: manual/directory_watch/scheduled/startup; failed — log and span — carries `error.type` and `error.operation`)
- Mount/unmount success/failure
- Directory watch triggers
- Transport changes (primary ↔ fallback)
- Sync errors (with categorized error type and `error.operation` — see [Error categories](#error-categories))
- Drive not mounted warnings
- Profile state changes (paused/resumed)
- App launch
- Profile configuration snapshots (RUM — sync mode, interval, feature toggles)
- Configuration summary (profile count breakdown by mode)
- Remote config operations: create/update/delete/connection_test (with provider type and categorized error type)
- Sync contention: sync skipped because another was already running (bottleneck detection)
- Rejected concurrent run suppressed: a rejected concurrent run's own "prior lock file found"
  failure was ignored rather than surfaced as this profile's failure (`rejected_concurrent_run.site`:
  `sync_failed`/`error_message`) — the signal that the double-bisync race the single-run guard
  closes is (or isn't) still happening
- Deferred external-edit reinstall: `deferred_reinstall.outcome` (`deferred`/`applied`/`failed`/`dropped`) —
  info except `failed`, which logs at warn
- LogWatcher recovery: file replaced, missed bytes, polling errors (monitoring health) — **coalesced into episodes**: the first event of a run emits `LogWatcher recovery: <reason>` immediately, further events within a 60s quiet window are folded into a single `LogWatcher recovery episode ended: <reason>` carrying `logwatcher.recovery_count`, `logwatcher.missed_bytes`, and `logwatcher.episode_duration_seconds`. The `synctray.logwatcher.recovery` counter still records **every** event, so the true rate is unaffected. A single-event episode emits no summary.
- Stale lock cleanup: count and type of stale locks cleaned at startup (crash detection)
- Check phase duration: bisync listing/comparison phase timing (bottleneck analysis)
- Session heartbeat: periodic (5min) alive signal with profile state summary (availability)
- Sync progress: one per live Two-Way / One-Way run on each heartbeat — byte/file/check counts, speed, ETA, `sync.run_age_s`; never file names (see [Per-profile Heartbeat Logs](#per-profile-heartbeat-logs))
- Profile status: one per enabled profile on each heartbeat — `profile.state`, `profile.run_live`, `sync.lock_state` / `sync.session_lock_state` (a `live_unverified` lock is the reused-PID stuck-lock signature), `error.type`, `config.local_path_kind`, `config.remote_type`, `config.fallback_remote_type`
- Volume events: external drive mount/unmount with affected profile count (drive workflow RUM)
- Sync precondition failures: script_not_found, config_not_found (setup issue detection)
- Resumed external syncs: syncs detected running at startup (launchd overlap detection)
- App upgraded: `service.version` changed since the previous launch (deployment markers)
- Auto-fix: automatic --resync triggered (`triggered`), triggered again after a resync that did not stick (`recurred`), stopped because resyncs keep not sticking (`gave_up_recurring`), suppressed by backoff (`gave_up_backoff`), skipped because the external drive is not mounted (`skipped_drive_not_mounted`), or blocked because the single-run guard found another run already holding the profile's lock (`blocked_already_running` — CLAUDE.md "One Run Per Profile")
- Offline pin operations: directory pinned or unpinned via Finder right-click or in-app UI (`offline.action`, `offline.path_count`)
- Wizard step: onboarding funnel events (`wizard.outcome`, `wizard.abandoned_at_step`, `provider.type`) — new-profile flow only, not edit mode
- OAuth outcome: OAuth auth result during remote setup (`result`, `provider.type`)
- User recovery action: user-initiated recovery from the error banner (`recovery.action`, `recovery.result`: `started`, `staged` for `exclude_blocked_path` — it only stages the pattern, see `apply_sync_filter` below — or `blocked_already_running` when the single-run guard refused) — distinct from automatic auto-fix
- Apply sync filter (`profile.operation = "apply_sync_filter"`, via `recordProfileLifecycleOperation`): the staged "Don't Sync" Save follow-up (CLAUDE.md "Don't Sync" patterns / Rule 9's `stopRunThenSync`) — `profile.operation.result` is `sync_now` (nothing was running, Sync Now started immediately), `stop_requested` (a live run is being stopped first, behind the "Stop the Current Sync and Apply?" confirm), `restarted` (the stop finished and Sync Now started), or `not_restarted` (the stop gave up before Sync Now could run, OR the profile was deleted or disabled while the stop was in progress — either way the already-saved filter still applies from the next scheduled run, if the profile still exists and is enabled)
- Setting changed: app-wide preference toggled (`setting.name`, `setting.enabled`); the telemetry opt-out is recorded just before telemetry disables. A Menu Bar Icon style change records `menu_bar_icon_<style>` with `setting.enabled=true`
- Offline extension setup: Finder-extension enable-funnel steps (`offline.extension_action`)
- Offline cache clear: cache cleared, with whether pinned folders were preserved (`offline.preserve_pinned`)
- rclone discovery: where rclone was found at launch, or a warn-level "rclone not found" (`rclone.discovery_source`, `rclone.location`) — measures install-location coverage, e.g. nix-darwin (issue #53). Never emits the raw path.
- Reinstall pre-detach: graceful volume detach before a mount-mode profile's `uninstall` (settings-save reinstall, manual uninstall, or delete), only logged when the profile was mounted — `success` at info, `success_forced` at warn (diskutil needed `unmount force`), `failure` at error (still mounted after both attempts — the freeze condition this replaces)
- Cache Only fell back to streaming: a `streamCacheOnly` profile whose mount settled on streaming instead (the silent script fallback) — a WARN `Cache Only fell back to streaming`, one per mode-change edge, alongside the `synctray.mount.cache_only_fallback` counter. The invisible "I enabled Cache Only but it's still streaming" case made observable
- CLI invoked: one `CLI invoked` record per headless `synctray` run (`cli.command`, `cli.result`, `cli.exit_code`, `cli.duration_seconds`) — info on success, warn on a non-zero exit. Bounded verb only; never args, paths, profile names, or remotes. Emitted by `TelemetryService.recordCLIInvocation`, gated on the telemetry opt-in, flushed by `flushForExit` (a SILENT force-flush of all three signals — unlike `shutdown()`, it prints nothing, so CLI stdout stays clean)
- Offline warm started/completed/cancelled: a pinned-folder warming run began (`Offline warm started`, with `warm.trigger`, `warm.directory_count`, `warm.concurrency`) or ended (`Offline warm completed` or `Offline warm cancelled`, with `warm.outcome`, `warm.files`, `warm.bytes`, `warm.duration_seconds`, `warm.throughput_mbps`). A run is cancelled when the cache is cleared, the profile is unmounted, or a newer run supersedes it. Use `synctray.offline.warm.throughput` to spot the slow-fallback case; filter `warm.outcome=completed` to exclude interrupted runs from throughput analysis.
- Offline warm paused/resumed: `Offline warm paused` / `Offline warm resumed` (`warm.pause_state`, `warm.pause_source`: manual/auto) when the warm yields the link to interactive use — the user's "Pause caching" toggle, or an auto-pause because an app (not Finder or the warmer itself) was seen reading the mount. An auto-pause log also carries `warm.pause_readers` (bounded labels for the processes found reading the mount: an allowlisted macOS component by name, `shell`, or `app` — never a third-party app's name; `TelemetryService.warmPauseReaderSummary`) and `warm.pause_reader_count`. Both are log-only, never on the counter. Paired with the `synctray.offline.warm.paused` counter.
- Cache Only list write failed: warn-level `Cache Only list write failed` (`error.type`, bucketed by `categorizeError`) when the app cannot build a Stream profile's Cache Only partial-file list. The failed walk removes any stale list, so that profile's next offline mount streams instead of mounting Cache Only. Emitted once per failure run — the heartbeat retries every few minutes, and the next failure after a successful write reports again. Never the error text or a path.
- Mount Spotlight marker: `Mount Spotlight marker` once per streaming mount session (`spotlight_marker.outcome`: written/exists/failed/skipped) — info on written/exists, warn otherwise. Records dropping `.metadata_never_index` at the mount root so macOS Spotlight stops bulk-indexing the freshly-mounted network volume (the read storm that saturates the download slots and leaves Finder's listing queued behind the indexer). Never a path — profile id/name only.
- Mount listing warm: `Mount listing warm` once per streaming mount session (`listing_warm.outcome`, `listing_warm.directories_warmed`, `listing_warm.directories_failed`) — info when `completed`, warn on `failed`/`aborted`/`skipped` (`aborted` = the descent backed off after consecutive failures to avoid flooding a failing backend). A per-subtree descent of `/vfs/refresh` (recursive where rclone can walk a subtree, non-recursive + `operations/list` descend where it can't — rclone's recursive refresh returns `directory not found` on large SMB trees) that populates the directory-*listing* cache so first-browse of every folder is instant instead of a live SMB round trip (the "Loading…" spinner). Metadata only — downloads no file bytes; a `failed`/partial outcome is non-fatal, the mount stays fully usable and folders warm lazily on first browse. Never a path or remote name.
- Mount read health: `Mount read health` after each probe (info when `healthy`, warn otherwise) with `mount.read_health`, `cache.fs_type`, `cache.volume`, `mount.backend`, `vfs.cache_files`, `probe.bytes`, `probe.duration_seconds`, `probe.first_byte_seconds`, `probe.throughput_mbps`, `probe.remote_bytes`; `Mount read health probe skipped` (warn) when no fully-cached ≥16 MB file exists (`no_candidate`) or the read failed. Probed from the 5-minute heartbeat, at most once per 30 min per mounted **streaming** profile, never during an offline warm, and only when telemetry is enabled (the probe does no I/O otherwise). Never a file name or path — the probed file is random and unrecorded.
- Mount interrupted / Mount interruption ended: WARN `Mount interrupted` when the mount monitor detects a stall or a drop (`mount.interruption_kind`, `mount.backend`, `mount.mode`), so an interruption that never recovers is still visible; `Mount interruption ended` when it ends (`mount.interruption_outcome`, `mount.interruption_duration_s`) — info when `recovered`, warn when `dropped` or `unmounted`. Paired with `synctray.mount.interruptions` and `synctray.mount.interruption.duration`. Never a path — profile id/name only.
- Diagnostic report sent / failed: one `Diagnostic report sent` (info) or `Diagnostic report failed` (warn) record when the user sends a diagnostic report, with `diagnostics.report_id` (the `ST-XXXXXX` code), `diagnostics.source_ui` (`app`/`cli`), `diagnostics.result` (`sent`/`failed`), `diagnostics.line_count`. Gated on the usage-data opt-in like every other event; never any report content (`TelemetryService.recordDiagnosticReport`). The report itself is a separate upload — see below
- Cache migration started/completed: `Cache migration started` when a Stream profile's cache-directory move begins; `Cache migration completed` (outcome `completed`) or `Cache migration ended` (any other outcome — `cancelled`, a `CacheMigrationFailure` value, optionally `_rolled_back`-suffixed, or `preflight_rejected`) when it ends, carrying `cache_migration.outcome`, `cache_migration.same_volume`, `cache_migration.files`, `cache_migration.bytes`, `cache_migration.duration_seconds`, `cache_migration.throughput_mbps`. Never a cache path, directory, or remote name.

## Diagnostic reports (user-sent)

A diagnostic report (`DiagnosticReport.swift`, CLAUDE.md "Diagnostic reports") is NOT usage
telemetry: it is uploaded only when the user presses **Send** (or runs `synctray report --send`
and confirms), whether or not `telemetryEnabled` is on, and it does not go through the OTel SDK.
`DiagnosticReportUploader` POSTs OTLP/HTTP JSON (`ExportLogsServiceRequest`: resourceLogs →
scopeLogs (scope `synctray.diagnostics`) → logRecords) to `<endpoint>/v1/logs` with
`Content-Type: application/json` and the exporter's own headers, ≤ 200 records and about
1 MB per request (`DiagnosticOTLPEncoder.batches`; a single oversize record goes alone).

**Resource:** the same attributes as every telemetry signal (`TelemetryService.diagnosticResourceAttributes(includeInstallIdentity:)`
— `service.name`, `service.namespace`, `service.version`, `os.type`, `os.version`, `host.arch`,
`deployment.environment.name`, `vcs.*`), with `synctray.process.kind` = `diagnostics`. The
install identity (`service.instance.id`, `enduser.id`) is included ONLY when usage data is on;
with it off both are omitted and `SyncTraySettings.installationId` is never read, so sending a
report never creates an install ID (`DiagnosticReportUploader.resourceAttributes(base:telemetryEnabled:)`).

**Records** (`DiagnosticOTLPEncoder`, pure, AC-DR4):

| Record | Body | Attributes |
|--------|------|------------|
| Summary (first) | `Diagnostic report` | `diagnostics.report_id`, `diagnostics.profile_count` (int), `diagnostics.line_count` (int), `diagnostics.truncated` (bool) |
| One per report line | the redacted line | `diagnostics.report_id`, `diagnostics.source` (`log`/`status`/`doctor`/`config`/`filter`/`locks`/`processes`/`launchd`/`system`), `diagnostics.line` (1-based within its section), `synctray.profile.id` + `synctray.profile.name` for per-profile sections; for an rclone `--use-json-log` line also `rclone.level`, `rclone.msg`, `rclone.object`, `rclone.time` (rclone's own timestamp, as written) when present |

`timeUnixNano` is the report's creation time plus the record's ordinal in nanoseconds — 0 for
the summary, then 1, 2, … in report order — for EVERY record, so a report sits together at send
time and its order survives in a time-sorted view. rclone's own line time is never used as the
timestamp; it is kept as the `rclone.time` string attribute.
`severityNumber`/`severityText` come from rclone's `level`: error/critical → ERROR (17),
warning → WARN (13), notice/info → INFO (9), debug → DEBUG (5); anything else, and every
non-JSON line, INFO. Every line is redacted (`DiagnosticRedactor`) before it is stored, so
these bodies don't carry the passwords, tokens or credentials it recognizes — but they DO carry
paths and file names, which is why this is the only exempt path (see the Privacy carve-out
above).

To find a report: filter logs on `diagnostics.report_id = ST-XXXXXX` (and
`synctray.process.kind = diagnostics`).

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

## Swift SDK Gotcha: `forceFlush()` Does Not Wait for the Send

The OTLP/HTTP exporters (`OtlpHttpLogExporter`, `OtlpHttpTraceExporter`,
`StableOtlpHTTPMetricExporter`) start the HTTP request and return `.success` before
it completes, so `forceFlush()` returning only means the requests have *started*.
A process that exits right after the flush kills the request — the CLI on every
run, and the app on quit. Before this was handled, no `CLI invoked`
(`synctray.process.kind=cli`) record had ever reached Dash0.

So every exporter is built with `useSession: Self.exportSession`, and
`flushForExit` waits (inside its 3 s deadline) until that session has nothing in
flight (`waitUntilIdle`); the app's `shutdown()` does the same with a 2 s deadline.
A new exporter must use the same session, or its exit-time events are lost again. Covered by `ConfigSelfTest` AC-CLI14.

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

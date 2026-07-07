# SyncTray Development Guidelines

## Project Overview

SyncTray is a macOS menu bar application that provides Google Drive-style background folder sync using rclone's bisync feature. It enables seamless two-way synchronization between local folders and any of rclone's 70+ supported cloud providers (Dropbox, OneDrive, Google Drive, S3, SFTP, etc.).

### Key Features
- **Multi-profile support**: Configure multiple sync pairs (local folder ↔ cloud remote)
- **Three sync modes**: Two-way sync (bisync), one-way sync (upload/download), and stream (mount)
- **Background sync via launchd**: Scheduled syncs run automatically at configurable intervals
- **Real-time file monitoring**: FSEvents-based directory watching triggers syncs on local changes
- **External drive support**: Auto-detects when external drives are mounted/unmounted
- **Live progress tracking**: Parses rclone JSON logs for real-time transfer progress
- **macOS notifications**: Batch notifications for file changes with "Open Directory" action
- **Fallback remote**: Automatic failover to an alternative remote when the primary is unreachable
- **Auto-fix sync issues**: Automatically runs `--resync` recovery when bisync detects an out-of-sync state (app-wide setting, default ON). Skipped when the profile's external drive is unmounted — a `--resync` against a missing/empty local path can't safely fix anything, so the profile is left in `.driveNotMounted` and resumes normally once the drive reconnects.

### Sync Modes

| Mode | rclone Command | Description |
|------|----------------|-------------|
| Two-Way Sync | `rclone bisync` | Bidirectional sync - changes on either side sync to the other |
| One-Way Upload | `rclone sync local remote` | Local is authoritative, uploads to remote |
| One-Way Download | `rclone sync remote local` | Remote is authoritative, downloads to local |
| Stream (Mount) | `rclone nfsmount` (default) or `rclone mount` | Virtual filesystem - files stream on-demand without local copy |

#### Mount Mode Backends
Stream (Mount) mode supports two backends, chosen per-profile via `mountBackend`
(`MountBackend` enum). Both share the same VFS cache layer, so caching, retention,
pinned-directory warming, and the RC API behave identically across them.

| Backend | rclone command | Requirements | When to use |
|---------|----------------|--------------|-------------|
| **NFS** (`nfs`, default for new profiles) | `rclone nfsmount` | None beyond rclone itself | **Kext-free.** rclone runs a local NFS server and mounts it via the built-in macOS NFS client. No macFUSE, no kernel/system extension, no admin approval — works on locked-down / MDM-managed Macs where kexts are blocked. |
| **macFUSE** (`macfuse`, legacy) | `rclone mount` | macFUSE + official rclone binary | Classic FUSE mount. Broader filesystem compatibility, but needs a kernel extension. Profiles created before the NFS backend existed default here so their behaviour is unchanged on upgrade. |

**Backend defaults & migration:** the default backend is `nfs` everywhere — for
newly created profiles and for profiles persisted before this field existed. A
legacy profile with no `mountBackend` key decodes as `nfs` (the Swift model default)
and the sync script applies the **same `nfs` fallback** when the key is absent from a
profile's JSON, so the app and the generated script never disagree. This means a
profile that previously mounted via macFUSE switches to the kext-free NFS backend on
its next mount (the VFS cache is shared, so no re-download); users who specifically
want FUSE can select **macFUSE** in the profile editor, which re-installs the launchd
agent with `rclone mount`. Legacy profiles also pick up the new `--vfs-cache-max-age`
default (168h) on the next script run — previously the flag was unset and rclone used
its built-in 1h default; total cache size stays bounded by `--vfs-cache-max-size`.

**Auto-mount on startup (`mountAtStartup`, default true):** a per-profile toggle for
whether a Stream profile mounts on its own. It gates the launchd plist's `RunAtLoad`
and `KeepAlive` (both `<true/>` only when enabled) — macOS reloads every LaunchAgent
plist at each login, so those keys, not merely whether the app `launchctl load`ed the
agent, decide login/reboot auto-mount. When enabled: mounts at login and the app also
re-mounts it on launch (`mountProfilesAtStartup`, a safety net if the agent was
unloaded). When disabled: the plist won't auto-start, so the profile mounts only when
the user clicks **Mount** — which does `launchctl load` **plus** `launchctl kickstart`
(`SyncSetupService.startAgent`), because with `RunAtLoad=false` loading alone won't
start the job. `mountAtStartup` is an app/launchd-level setting and is deliberately
**not** written to the script's `{shortId}.json` (the script never reads it); it does
force a plist regeneration on save (part of `needsReinstall`).

**The generated per-profile config (`{shortId}.json`) is the script's single source
of truth.** `SyncSetupService.generateProfileConfig` writes this file (read by the
sync script via `parse_json`); it is *separate* from the full `SyncProfile` that
`ProfileStore` persists to `UserDefaults`. Any mount setting the script consumes
(`mountBackend`, `vfsCacheMaxAge`, `vfsCacheMode`, …) **must be emitted by
`generateProfileConfig`** — a field present in the model, UI, and `Codable` but
missing from this writer silently never reaches the script, which then falls back to
its default. (This was the cause of the "NFS selected but macFUSE still runs" bug:
`mountBackend`/`vfsCacheMaxAge` were added everywhere except `generateProfileConfig`.)

**Cache retention (`vfsCacheMaxAge`):** the "Keep Cached For" setting maps to
rclone's `--vfs-cache-max-age` (default `168h` = 7 days). A used file stays in the
VFS cache until this long has passed *since it was last accessed* (the timer resets
on each open); `--vfs-cache-max-size` still bounds total cache size with LRU
eviction. There is no rclone-native per-file "pin" — `pinnedDirectories` are kept
warm app-side via the RC API + reads (see Offline Files).

**NFS backend caveats:** writes require `--vfs-cache-mode` ≥ `writes` (default is
`full`, so this is satisfied). The NFS client couples access/modification times,
which can occasionally cause an extra re-upload after a file is merely viewed in
Finder. `--allow-non-empty` is a FUSE-only option and is ignored for the NFS backend.

The **macFUSE** backend additionally requires the official rclone binary
(Homebrew's rclone can't mount):

```bash
# Only needed for the macFUSE backend — the NFS backend needs none of this.
brew install --cask macfuse
# Restart Mac

# Replace Homebrew rclone with official binary
brew uninstall rclone
curl -O https://downloads.rclone.org/rclone-current-osx-arm64.zip
unzip rclone-current-osx-arm64.zip
cd rclone-*-osx-arm64
sudo cp rclone /usr/local/bin/
sudo chmod +x /usr/local/bin/rclone
```

### How It Works
1. User configures a profile: local path, rclone remote, and sync interval
2. SyncTray generates a shell script and launchd plist for scheduled syncs
3. LogWatcher monitors the sync log file for state changes and progress
4. DirectoryWatcher monitors the local folder for file changes (triggers immediate sync)
5. NotificationService batches and displays file change notifications

## Architecture

```
SyncTray/
├── Models/           # Data models and state types
├── Services/         # Business logic and background services
├── Views/            # SwiftUI views
├── Assets.xcassets/  # App icons and images
└── SyncTrayApp.swift # App entry point and AppDelegate
SyncTrayFinderSync/   # FinderSync app extension (kext-free, sandboxed)
├── FinderSyncExtension.swift # FIFinderSync subclass — contextual menu, badges, IPC
├── Info.plist        # NSExtension point: com.apple.FinderSync
├── SyncTrayFinderSync.entitlements # App sandbox + App Group (7HVK85DZG7.group.com.synctray.app)
└── Assets.xcassets/  # Badge images (badge-cloud, badge-downloaded)
```

### FinderSync Extension

The `SyncTrayFinderSync` app extension adds a right-click Finder contextual menu
(**SyncTray ▸ Available Offline**, a single checkmarked toggle: checked = kept offline,
unchecked = streams online-only) plus cloud/checkmark file badges, for directories
inside rclone NFS mount paths. Release extension bundle ID: `com.synctray.app.findersync`.
Requires no kernel extension (kext-free NFS backend only).

#### App Group IPC Contract

Two distinct IPC mechanisms are used. Both use App Group ID `7HVK85DZG7.group.com.synctray.app`:

| Direction | Mechanism | Key / File | Contents |
|-----------|-----------|------------|----------|
| Host → Extension | `UserDefaults(suiteName: "7HVK85DZG7.group.com.synctray.app")` | `com.synctray.app.mountPaths` | `[String]` — active NFS mount paths |
| Host → Extension | `UserDefaults(suiteName: "7HVK85DZG7.group.com.synctray.app")` | `com.synctray.app.profileData` | `[[String:Any]]` — profileId, pinnedDirectories, vfsCachePath per profile |
| Extension → Host | JSON file in App Group container | `pending-pin-request.json` | `{action, profileId, paths[]}` |
| Extension ↔ Host | Darwin distributed notification | `com.synctray.app.pinRequest` | Zero-payload wake signal — **bidirectional** |

The `com.synctray.app.pinRequest` notification is used **both ways**: the extension posts
it to wake the host when a pin/unpin request file is pending; the host posts it
(`SyncManager.notifyFinderSyncReload`) after it updates the App Group data (on pin/unpin
**and** whenever mount paths change in `updateAppGroupMountPaths`) so the extension
reloads its `directoryURLs` and repaints badges. The host reads/deletes
`pending-pin-request.json` on each notification and on a 1-second fallback poll timer
(active only when mount profiles exist); its own posts find no file → harmless no-op.

#### Extension lifecycle — loading & auto-refresh

Finder (not SyncTray) owns the extension process and **does not reload the plug-in when
the app bundle is replaced** (e.g. by `brew upgrade`) — it keeps serving the pre-upgrade
binary until Finder is relaunched. SyncTray manages this so the user needn't restart
Finder by hand:

- **On quit** (`applicationWillTerminate`) it `pkill`s `SyncTrayFinderSync`, so no stale
  extension process lingers.
- **On launch** (`refreshFinderSyncExtensionIfNeeded`) it re-registers the appex with
  `pluginkit -a`, and — if the app version changed since `SyncTraySettings.finderSetupVersion`
  **and** the extension is enabled — relaunches Finder so it loads the new binary. Gated
  on *enabled* (no Finder flicker for non-Stream users) and *version changed* (at most
  once per upgrade).
- The launch relaunch can race the NFS mount coming up; the extension is re-woken when
  mount paths are written (see the bidirectional notification above), so it re-registers
  `directoryURLs` once the mount establishes.
- The cask's `uninstall quit: "com.synctray.app"` quits the app before an upgrade so the
  quit handler fires. The cask `caveats` still tells users to `killall Finder` as a manual
  fallback. **On a brand-new install the user must enable the extension once** in System
  Settings — a macOS consent gate no app can bypass; the in-app card guides it.

#### Code signing — required to test the extension; disabled on CI/release

macOS **will not load a Finder extension (or grant App Group access) in an unsigned
app**. So the FinderSync menu only appears in a **code-signed** build:

- **Local testing:** set your **Team** on *both* the `SyncTray` and `SyncTrayFinderSync`
  targets (Signing & Capabilities → Automatic), confirm the `7HVK85DZG7.group.com.synctray.app`
  App Group is on both, then Build & Run. Enable it once under System Settings →
  General → Login Items & Extensions → Extensions, and right-click a folder **inside a
  mounted Stream profile's path** (FinderSync only decorates registered mount dirs).
  `pluginkit -m -i com.synctray.app.dev.findersync` should list it once loaded.
- **Debug builds use a `.dev` bundle id** so a dev build never collides with an
  installed release. `BUNDLE_ID_SUFFIX` (`Config/Signing.xcconfig`, `[config=Debug] = .dev`)
  gives Debug the ids `com.synctray.app.dev` / `com.synctray.app.dev.findersync`;
  Release keeps `com.synctray.app` / `com.synctray.app.findersync`. Both extensions
  register independently, so `nr synctray:dev` no longer hijacks the brew app's Finder
  registration (previously the shared id made whichever built last invalidate the other).
  Caveat: if you enable **both** the dev and release extensions, Finder shows two
  "SyncTray" submenus — disable one while iterating. `scripts/dev.sh` targets the `.dev`
  id and the in-app enabled-check switches id via `#if DEBUG`.
- **CI / release build unsigned on purpose.** `CODE_SIGNING_ALLOWED=NO` is **not**
  hardcoded in the project — it is passed on the `xcodebuild` command line by both the
  CI `test` job (`.github/workflows/ci.yml`) and `scripts/release-ci.sh`. This keeps the
  build gate green without signing credentials while letting local dev sign normally.
  Consequence: the brew-distributed (unsigned) app **cannot** show the offline menu —
  shipping it requires Developer ID signing + notarization + App Group provisioning.
  The release pipeline (`scripts/release-ci.sh`) does this automatically when the
  signing secrets are present; setup is documented in [`docs/release-signing.md`](docs/release-signing.md).
  Local dev-setup steps live in [`DEVELOPMENT.md`](DEVELOPMENT.md).

#### Cross-Target String Constants

`kAppGroupID` (`7HVK85DZG7.group.com.synctray.app`), `kMountPathsKey`, and
`kPinRequestNotificationName` (`com.synctray.app.pinRequest`) are defined as string
literals in **both** `FinderSyncExtension.swift` and `SyncManager.swift` independently.
The two targets are separate compilation units. If you rename either constant, rename both.

#### VFS Content Warming (Bug Fix)

`VFSCacheService.warmDirectory(_:for:)` fixes a pre-existing bug: the old
`refreshPinnedDirectories` only called `/vfs/refresh` (listing-cache metadata), which
does not populate the rclone VFS content cache. `warmDirectory` now:

1. Calls `/vfs/refresh` first (listing cache pre-step).
2. Walks `profile.localSyncPath/<dir>` via `FileManager.enumerator`.
3. Opens each file ≤ 100 MB via `FileHandle` and reads 64 KB chunks — the act of
   reading through the NFS mount populates `~/.cache/rclone/vfs/…`.

I/O budget: sequential reads (not concurrent), 2 GB total ceiling per call, cancellable
between files via `try Task.checkCancellation()`.

### Models/

| File | Purpose |
|------|---------|
| `SyncProfile.swift` | Profile model with sync paths, remote config, fallback remote config, computed file paths |
| `SyncState.swift` | Sync state enum, progress struct, file change model, `ActiveTransport`, `SyncLogPatterns` for log parsing |
| `RcloneLogEntry.swift` | JSON models for parsing rclone `--use-json-log` output |
| `Settings.swift` | Global app settings (debug logging toggle, auto-fix sync issues toggle) |

### Services/

| File | Purpose |
|------|---------|
| `SyncManager.swift` | Central orchestrator - manages all profile states, log watchers, directory watchers |
| `ProfileStore.swift` | Persistent storage for profiles (JSON files in `~/.config/synctray/profiles/`) |
| `SyncSetupService.swift` | Generates sync scripts, launchd plists, manages agent install/uninstall |
| `LogWatcher.swift` | FSEvents + polling hybrid file watcher for rclone log files |
| `LogParser.swift` | Parses plain text and JSON log lines into typed `ParsedLogEvent` |
| `DirectoryWatcher.swift` | FSEvents-based directory monitoring with debouncing |
| `NotificationService.swift` | Batched macOS notifications with action support |
| `TelemetryService.swift` | Opt-in OTel telemetry (traces, metrics, logs) via OTLP/HTTP |

### Views/

| File | Purpose |
|------|---------|
| `MenuBarView.swift` | Menu bar dropdown with profile status, recent changes, quick actions |
| `SettingsView.swift` | Settings window with profile list and detail editor |
| `AppSettingsView.swift` | Global app settings — launch at login, telemetry toggle, debug logging |
| `ProfileListView.swift` | Sidebar list of profiles with add/delete controls |
| `StatusHeaderView.swift` | Header showing current sync state and progress |
| `SyncProgressDetailView.swift` | Detailed per-file transfer progress during sync |
| `RecentChangesView.swift` | List of recently synced files |
| `TelemetryOptInBanner.swift` | Dismissable banner prompting telemetry opt-in (consent-versioned) |
| `TelemetryDetailsSheet.swift` | Full privacy disclosure sheet — reachable from wizard, banner, and settings |
| `SetupWizardView.swift` | New-profile creation wizard, including optional `.helpImprove` epilogue step |

## Data Flow

### Sync Monitoring Pipeline
```
launchd triggers sync script
        ↓
Script writes to log file (~/.local/log/synctray-sync-{shortId}.log)
        ↓
LogWatcher detects file changes (FSEvents + polling fallback)
        ↓
LogParser parses lines → ParsedLogEvent (syncStarted, stats, fileChange, syncCompleted, etc.)
        ↓
SyncManager updates state dictionaries (profileStates, profileProgress, etc.)
        ↓
SwiftUI views react to @Published changes
```

### File Change Detection Pipeline
```
User modifies file in local sync folder
        ↓
DirectoryWatcher receives FSEvents callback
        ↓
Filters out metadata files (.DS_Store, ._*, .tmp, etc.)
        ↓
Debounces rapid changes (15 second window)
        ↓
SyncManager.triggerManualSync() called
        ↓
Sync script executed → log written → monitoring pipeline picks up
```

### Fallback Remote Pipeline
```
Sync script starts
        ↓
Check if FALLBACK_REMOTE is configured (from profile JSON)
        ↓
If set: rclone lsd primary remote (3s connect timeout)
        ↓
Unreachable? → Log "using fallback: X"
    ├─ Same wire type + no path change (fallbackRequiresCacheRebuild=false):
    │   env var overrides swap transport (preserves bisync cache)
    └─ Different wire type OR explicit path (fallbackRequiresCacheRebuild=true):
        swap entire REMOTE reference (bisync rebuilds listings, ~12s)
        ↓
Reachable? → Log "Using primary remote: X"
        ↓
LogParser detects transport message → SyncManager.profileTransports updated
        ↓
MenuBarView shows transport icon (wifi=primary, antenna=fallback)
```

**Primary recovery (fallback → primary switch-back).** The reachability check above runs
once per *script execution*. Sync/bisync profiles re-run on their `StartInterval`, so they
naturally return to the primary on the next scheduled sync once it's reachable. A **mount**
is a long-lived `rclone nfsmount` that picks its remote once at mount time (its launchd
agent is `RunAtLoad`+`KeepAlive`, no `StartInterval`), so it would otherwise stay on the
fallback until the next relaunch/login/manual remount. `SyncManager.startPrimaryRecoveryMonitor`
closes that gap: a 2-minute timer probes the primary (`isRemoteReachable`, hard-timeout —
SMB can hang past its own timeouts) for any mounted mount-mode profile currently on the
fallback (`ActiveTransport.fallback`), and when the primary is reachable again it remounts
on the primary (`remountOnPrimary` = unmount → mount, so the script re-picks the remote).
The switch causes a brief mount hiccup; `recoveringToPrimary` guards against stacking remounts.

**Bisync cache preservation:** When primary and fallback remotes share the same
rclone wire type (e.g., WebDAV LAN → WebDAV QuickConnect, both `type = webdav`)
and `fallbackRemotePath` is empty, the sync script uses `RCLONE_CONFIG_*`
environment variable overrides to change the transport while keeping the rclone
remote name unchanged. This means bisync's listing cache (keyed by remote name +
path) remains valid across failover events.

When primary and fallback have **different** wire types (e.g., SMB → SFTP), the
script swaps the full remote reference to `<fallbackRemote>:<path>` regardless of
whether `fallbackRemotePath` is set. This forces bisync to rebuild listings on
the first switch (~12s for 85K files, no data re-download) but avoids cache
poisoning from byte-level filename encoding differences (macOS SMB normalises to
NFD; SFTP passes NFC verbatim — same human-readable name, different byte
sequence).

The branching condition is determined at profile install/save time by comparing
`provider.rcloneType` for the primary and fallback remotes (read via
`RcloneConfigService.readRemoteConfig`), stored as `fallbackRequiresCacheRebuild`
in the profile JSON. Profiles created before this field was added default to
`false` (legacy env-var-override behaviour). The field re-evaluates on every
profile save, so users can correct it by re-saving the profile.

## Key Design Patterns

### Multi-Profile State Management

SyncManager maintains parallel dictionaries keyed by profile UUID:

```swift
@Published private(set) var profileStates: [UUID: SyncState] = [:]
@Published private(set) var profileProgress: [UUID: SyncProgress] = [:]
@Published private(set) var profileErrors: [UUID: String] = [:]
@Published private(set) var profileTransports: [UUID: ActiveTransport] = [:]
private var logWatchers: [UUID: LogWatcher] = [:]
private var directoryWatchers: [UUID: DirectoryWatcher] = [:]
// Auto-fix backoff (in-memory, not persisted):
private var autoFixAttempts: [UUID: [Date]] = [:]     // timestamps of recent fix attempts
private var autoFixSuppressed: Set<UUID> = []          // profiles where auto-fix is paused
```

This allows independent state tracking per profile while maintaining a single source of truth.

### @MainActor Thread Safety

SyncManager is marked `@MainActor` to ensure all state mutations happen on the main thread:

```swift
@MainActor
final class SyncManager: ObservableObject {
    // All @Published properties are safely mutated on main thread
}
```

Background work (process execution, file I/O) happens on dispatch queues with results marshaled back to main actor.

### Hybrid File Monitoring

LogWatcher uses FSEvents as primary mechanism with polling fallback:

1. **FSEvents**: Low-latency file change detection via `DispatchSource.makeFileSystemObjectSource`
2. **Polling fallback**: Timer-based check every 2.5-5 seconds catches missed events
3. **Inode tracking**: Detects file replacement (atomic writes) and reopens file handle

### Centralized Log Pattern Matching

`SyncLogPatterns` enum in `SyncState.swift` provides single source of truth for log parsing:

```swift
SyncLogPatterns.isSyncStarted(message)
SyncLogPatterns.isSyncCompleted(message)
SyncLogPatterns.isSyncFailed(message)
SyncLogPatterns.extractExitCode(from: message)
SyncLogPatterns.cleanErrorMessage(message)
```

Used by both `LogParser` and `SyncManager` for consistent behavior.

## Critical Rules

### 1. Threading & Main Thread Safety
**NEVER access @State, @Binding, @Published, or any UI-related properties from a background thread.**

When dispatching work to background threads:
1. Capture ALL needed values from state properties BEFORE dispatching
2. Use explicit `self.` when updating state from within closures
3. ALWAYS update UI state on the main thread via `DispatchQueue.main.async`

```swift
// CORRECT
func doBackgroundWork() {
    // Capture values on main thread FIRST
    let capturedValue = self.someStateProperty
    let capturedPath = self.localSyncPath

    DispatchQueue.global(qos: .userInitiated).async {
        // Use captured values, not state properties
        let result = process(capturedPath)

        // Update UI on main thread
        DispatchQueue.main.async {
            self.isLoading = false
            self.result = result
        }
    }
}

// WRONG - will cause freezing/crashes
func doBackgroundWork() {
    DispatchQueue.global(qos: .userInitiated).async {
        let path = self.localSyncPath  // BAD: accessing @State from background
        // ...
        isLoading = false  // BAD: updating @State from background
    }
}
```

### 2. Process Execution
- Always run external processes (rclone, shell commands) on background threads
- Use `Process` with pipes for stdout/stderr
- Set `readabilityHandler` for real-time output streaming
- Remember to nil out handlers after process completes

### 3. SwiftUI Best Practices
- Use `.controlSize(.small)` or `.controlSize(.mini)` for inline spinners in buttons
- Avoid `scaleEffect()` for sizing ProgressView - it causes layout issues
- Keep views focused and extract complex logic into helper functions
- Use `@State` for view-local state, `@ObservedObject` for shared state

### 4. File Operations
- Use FileManager for local file operations
- Handle errors gracefully with user-friendly messages
- Create directories with `withIntermediateDirectories: true`
- Always check if files/directories exist before operations

### 5. Error Handling
- Provide actionable error messages to users
- Log detailed errors for debugging
- Offer recovery actions when possible (e.g., "Fix Sync Issues" button)
- **Clear cached errors** when config changes or fix operations start:
  ```swift
  syncManager.clearError(for: profile.id)
  ```

### 6. State Consistency
- When updating profile configuration, clear related cached state:
  ```swift
  // Profile paths changed - clear any stale errors
  syncManager.clearError(for: profile.id)
  // Restart watchers with new paths
  syncManager.refreshSettings()
  ```
- Use `SyncLogPatterns` for all log message categorization to maintain consistency

## Debugging

### Enable Debug Logging
In Settings, toggle "Debug Logging" to enable verbose output. Debug messages are written via `SyncTraySettings.debugLog()` and appear in the sync log files.

### Inspect launchd Agents
```bash
# List SyncTray agents
launchctl list | grep synctray

# Check agent status
launchctl print gui/$(id -u)/com.synctray.sync.{shortId}

# View agent definition
cat ~/Library/LaunchAgents/com.synctray.sync.*.plist
```

### View Sync Logs
```bash
# Tail live log
tail -f ~/.local/log/synctray-sync-{shortId}.log

# View profile config
cat ~/.config/synctray/profiles/{shortId}.json
```

### rclone bisync Cache
rclone bisync maintains state in:
```
~/.cache/rclone/bisync/
```

To force a fresh sync, use "Fix Sync Issues" in the app (runs `--resync`).

### Lock Files
If sync appears stuck, check for stale lock files:
```bash
ls -la /tmp/synctray-sync-*.lock
```

The app automatically cleans stale locks on startup.

## Build & Test

```bash
# Build the project
xcodebuild -scheme SyncTray -destination 'platform=macOS' build

# Build with verbose output
xcodebuild -scheme SyncTray -destination 'platform=macOS' build 2>&1 | xcbeautify

# Run the app
open ~/Library/Developer/Xcode/DerivedData/SyncTray-*/Build/Products/Debug/SyncTray.app
```

## Key Files Reference

| File | Purpose |
|------|---------|
| `SyncProfile.swift` | Profile model with computed paths (configPath, logPath, plistPath, etc.) |
| `SyncSetupService.swift` | Script generation, launchd management, profile installation |
| `SyncManager.swift` | Central state manager, LogWatcher/DirectoryWatcher coordination |
| `SettingsView.swift` | Main settings UI with profile editing |
| `ProfileStore.swift` | Profile persistence (JSON files) |
| `SyncLogPatterns` | Centralized log message pattern matching (includes `isOutOfSyncError`) |
| `TelemetryService.swift` | OTel singleton — traces, metrics, logs via OTLP/HTTP |
| `TelemetryDetailsSheet.swift` | Shared privacy disclosure sheet for wizard, banner, and settings |
| `Settings.swift` | Global settings including `installationId`, `anonymousUserId`, and `autoFixSyncIssues` |

## Telemetry

Anonymous, opt-in telemetry using OpenTelemetry (opentelemetry-swift 1.17.1). All methods are no-ops unless `SyncTraySettings.telemetryEnabled` is true. See `.claude/rules/telemetry.md` for the full instrumentation guide and how to add new telemetry.

### Three signals
- **Traces**: Sync lifecycle spans with real duration (start→complete/fail), mount/unmount spans
- **Metrics**: 20 instruments — sync duration + check phase histograms, operation counters (sync, mount, file ops, contention, recovery, volume events, filter stats, offline pin/unpin), profile gauge (delta temporality, 30s export interval)
- **Logs**: Structured log records for all key events (sync lifecycle, mount, transport changes, errors, config snapshots, session heartbeat, stale lock cleanup, precondition failures)

### User correlation
- `service.instance.id` — random UUID per install (changes on reinstall)
- `enduser.id` — HMAC-SHA256 of hardware UUID (stable across reinstalls, not reversible)

### Deployment correlation
- `service.version` — `<marketing>+<build>.g<gitSHA>` (e.g. `0.34.0+1.gabc1234`); the git SHA is injected by the `Embed Git Commit SHA` Xcode build phase. Primary key Dash0 uses to correlate telemetry to a release.
- `deployment.environment.name` — `development` (DEBUG) / `production` (Release), overridable via `OTEL_RESOURCE_ATTRIBUTES`.
- `App upgraded` log on version change between launches → Dash0 dashboard annotations.

### Privacy
No file paths, remote names, or credentials in telemetry. File operations tracked by normalized extension only. Error messages categorized into low-cardinality types. Profile names are user-chosen display names, not paths.

### Configuration
Priority: process env vars > `~/.config/synctray/.env` > Info.plist. Key vars: `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `DASH0_AUTH_TOKEN`.

## Generated Files (per profile)

| Path | Purpose |
|------|---------|
| `~/.config/synctray/profiles/{shortId}.json` | Profile config |
| `~/.config/synctray/profiles/{shortId}-exclude.txt` | Exclude filter (user-editable) |
| `~/.local/bin/synctray-sync.sh` | Shared sync script (all profiles) |
| `~/Library/LaunchAgents/com.synctray.sync.{shortId}.plist` | launchd schedule |
| `~/.local/log/synctray-sync-{shortId}.log` | Sync logs |
| `/tmp/synctray-sync-{shortId}.lock` | Lock file (prevents concurrent syncs) |

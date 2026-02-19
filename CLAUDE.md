# SyncTray Development Guidelines

## Project Overview

SyncTray is a macOS menu bar application that provides Google Drive-style background folder sync using rclone's bisync feature. It enables seamless two-way synchronization between local folders and any of rclone's 70+ supported cloud providers (Dropbox, OneDrive, Google Drive, S3, SFTP, etc.).

### Key Features
- **Multi-profile support**: Configure multiple sync pairs (local folder ↔ cloud remote)
- **Background sync via launchd**: Scheduled syncs run automatically at configurable intervals
- **Real-time file monitoring**: FSEvents-based directory watching triggers syncs on local changes
- **External drive support**: Auto-detects when external drives are mounted/unmounted
- **Live progress tracking**: Parses rclone JSON logs for real-time transfer progress
- **macOS notifications**: Batch notifications for file changes with "Open Directory" action

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
```

### Models/

| File | Purpose |
|------|---------|
| `SyncProfile.swift` | Profile model with sync paths, remote config, computed file paths |
| `SyncState.swift` | Sync state enum, progress struct, file change model, `SyncLogPatterns` for log parsing |
| `RcloneLogEntry.swift` | JSON models for parsing rclone `--use-json-log` output |
| `Settings.swift` | Global app settings (debug logging toggle) |

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

### Views/

| File | Purpose |
|------|---------|
| `MenuBarView.swift` | Menu bar dropdown with profile status, recent changes, quick actions |
| `SettingsView.swift` | Settings window with profile list and detail editor |
| `ProfileListView.swift` | Sidebar list of profiles with add/delete controls |
| `StatusHeaderView.swift` | Header showing current sync state and progress |
| `SyncProgressDetailView.swift` | Detailed per-file transfer progress during sync |
| `RecentChangesView.swift` | List of recently synced files |

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

## Key Design Patterns

### Multi-Profile State Management

SyncManager maintains parallel dictionaries keyed by profile UUID:

```swift
@Published private(set) var profileStates: [UUID: SyncState] = [:]
@Published private(set) var profileProgress: [UUID: SyncProgress] = [:]
@Published private(set) var profileErrors: [UUID: String] = [:]
private var logWatchers: [UUID: LogWatcher] = [:]
private var directoryWatchers: [UUID: DirectoryWatcher] = [:]
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
| `SyncLogPatterns` | Centralized log message pattern matching |

## Generated Files (per profile)

| Path | Purpose |
|------|---------|
| `~/.config/synctray/profiles/{shortId}.json` | Profile config |
| `~/.config/synctray/profiles/{shortId}-exclude.txt` | Exclude filter (user-editable) |
| `~/.local/bin/synctray-sync.sh` | Shared sync script (all profiles) |
| `~/Library/LaunchAgents/com.synctray.sync.{shortId}.plist` | launchd schedule |
| `~/.local/log/synctray-sync-{shortId}.log` | Sync logs |
| `/tmp/synctray-sync-{shortId}.lock` | Lock file (prevents concurrent syncs) |

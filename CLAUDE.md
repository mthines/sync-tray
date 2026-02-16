# SyncTray Development Guidelines

## Project Overview
SyncTray is a macOS menu bar application for managing rclone bisync profiles. It uses SwiftUI for the UI and manages background sync operations via launchd.

## Architecture
- **Models/**: Data models (SyncProfile, etc.)
- **Views/**: SwiftUI views (SettingsView, etc.)
- **Services/**: Business logic (SyncManager, SyncSetupService, ProfileStore)

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

## Build & Test
```bash
# Build the project
xcodebuild -scheme SyncTray -destination 'platform=macOS' build

# Run the app
open ~/Library/Developer/Xcode/DerivedData/SyncTray-*/Build/Products/Debug/SyncTray.app
```

## Key Files
- `SyncProfile.swift` - Profile model with computed paths
- `SyncSetupService.swift` - Script generation and launchd management
- `SyncManager.swift` - Sync state management and monitoring
- `SettingsView.swift` - Main settings UI
- `ProfileStore.swift` - Profile persistence

## Generated Files (per profile)
- `~/.config/synctray/profiles/{shortId}.json` - Profile config
- `~/.config/synctray/profiles/{shortId}-exclude.txt` - Exclude filter (user-editable)
- `~/.local/bin/synctray-sync.sh` - Shared sync script
- `~/Library/LaunchAgents/com.synctray.sync.{shortId}.plist` - launchd schedule
- `~/.local/log/synctray-sync-{shortId}.log` - Sync logs

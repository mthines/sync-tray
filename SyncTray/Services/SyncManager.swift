import Foundation
import AppKit
import Combine
import ServiceManagement

@MainActor
final class SyncManager: ObservableObject {
    @Published private(set) var currentState: SyncState = .idle
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var recentChanges: [FileChange] = []
    @Published private(set) var isManualSyncRunning = false
    @Published private(set) var syncProgress: SyncProgress?

    /// State per profile (keyed by profile ID)
    @Published private(set) var profileStates: [UUID: SyncState] = [:]

    /// Last error message per profile (for display in UI)
    @Published private(set) var profileErrors: [UUID: String] = [:]

    /// Profiles with muted file change notifications (for current sync only)
    @Published private(set) var mutedProfileNotifications: Set<UUID> = []

    let profileStore: ProfileStore

    private var logWatchers: [UUID: LogWatcher] = [:]
    private var directoryWatchers: [UUID: DirectoryWatcher] = [:]
    private let logParser = LogParser()
    private let notificationService = NotificationService.shared
    private let setupService = SyncSetupService.shared

    private var workspaceObserver: NSObjectProtocol?
    private var currentSyncChanges: [UUID: [FileChange]] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Track the last error message per profile (for correlating with syncFailed events)
    private var lastSeenErrorMessage: [UUID: String] = [:]

    /// Profiles where we're monitoring an externally-started sync
    private var monitoringExternalSyncs: Set<UUID> = []

    /// Timers polling for sync completion
    private var syncCompletionPollers: [UUID: DispatchSourceTimer] = [:]

    private let maxRecentChanges = 20

    init(profileStore: ProfileStore? = nil) {
        self.profileStore = profileStore ?? ProfileStore()
        setupWorkspaceObserver()
        setupProfileObserver()
        cleanupStaleLockFiles()
        detectAndResumeRunningSyncs()  // After cleanup, detect external syncs
        checkInitialState()
        startWatchingAllProfiles()
    }

    deinit {
        // Cancel all sync completion pollers
        for timer in syncCompletionPollers.values {
            timer.cancel()
        }
        syncCompletionPollers.removeAll()

        // Stop all directory watchers
        for watcher in directoryWatchers.values {
            watcher.stop()
        }
        directoryWatchers.removeAll()

        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    func refreshSettings() {
        startWatchingAllProfiles()
        checkInitialState()
    }

    /// Trigger manual sync for all enabled profiles, or a specific profile
    func triggerManualSync(for profile: SyncProfile? = nil) {
        guard !isManualSyncRunning else { return }

        let profilesToSync: [SyncProfile]
        if let profile = profile {
            profilesToSync = [profile]
        } else {
            profilesToSync = profileStore.enabledProfiles
        }

        guard !profilesToSync.isEmpty else {
            currentState = .notConfigured
            return
        }

        isManualSyncRunning = true

        Task {
            // Run all profile syncs in parallel for better performance
            await withTaskGroup(of: Void.self) { group in
                for profile in profilesToSync {
                    group.addTask {
                        await self.runSyncScript(for: profile)
                    }
                }
            }
            await MainActor.run {
                isManualSyncRunning = false
            }
        }
    }

    func openLogFile(for profile: SyncProfile? = nil) {
        let logPath: String
        if let profile = profile {
            logPath = profile.logPath
        } else if let firstEnabled = profileStore.enabledProfiles.first {
            logPath = firstEnabled.logPath
        } else {
            return
        }

        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        }
    }

    func openSyncDirectory(for profile: SyncProfile? = nil) {
        let syncPath: String
        if let profile = profile {
            syncPath = profile.localSyncPath
        } else if let firstEnabled = profileStore.enabledProfiles.first {
            syncPath = firstEnabled.localSyncPath
        } else {
            return
        }

        if !syncPath.isEmpty && FileManager.default.fileExists(atPath: syncPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: syncPath))
        }
    }

    func openFileInFinder(_ change: FileChange) {
        // Try to find the file in any of the enabled profiles
        for profile in profileStore.enabledProfiles {
            let fullPath = (profile.localSyncPath as NSString).appendingPathComponent(change.path)
            let url = URL(fileURLWithPath: fullPath)

            if FileManager.default.fileExists(atPath: fullPath) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
        }

        // File might have been deleted, try the first profile's path
        if let profile = profileStore.enabledProfiles.first {
            let fullPath = (profile.localSyncPath as NSString).appendingPathComponent(change.path)
            let parentDir = (fullPath as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: parentDir) {
                NSWorkspace.shared.open(URL(fileURLWithPath: parentDir))
            }
        }
    }

    func enableLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                print("Failed to register login item: \(error)")
            }
        }
    }

    func disableLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                print("Failed to unregister login item: \(error)")
            }
        }
    }

    var isLoginItemEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    // MARK: - Profile Management

    /// Enable/disable scheduled sync for a profile
    func setProfileEnabled(_ profile: SyncProfile, enabled: Bool) {
        var updatedProfile = profile
        updatedProfile.isEnabled = enabled
        profileStore.update(updatedProfile)

        if enabled {
            do {
                try setupService.install(profile: updatedProfile)
                startWatching(profile: updatedProfile)
            } catch {
                print("Failed to install profile: \(error)")
            }
        } else {
            do {
                try setupService.uninstall(profile: updatedProfile)
                stopWatching(profileId: profile.id)
            } catch {
                print("Failed to uninstall profile: \(error)")
            }
        }

        updateAggregateState()
    }

    /// Get state for a specific profile
    func state(for profileId: UUID) -> SyncState {
        profileStates[profileId] ?? .idle
    }

    /// Get last error message for a specific profile
    /// Only returns errors detected during this session (not persisted across app restarts)
    func lastError(for profileId: UUID) -> String? {
        return profileErrors[profileId]
    }

    /// Clear the cached error for a profile (call when config changes or fix is attempted)
    func clearError(for profileId: UUID) {
        profileErrors[profileId] = nil
        if case .error = profileStates[profileId] {
            profileStates[profileId] = .idle
        }
        updateAggregateState()
    }

    /// Set the syncing state for a profile (used by views running direct resyncs)
    func setSyncing(for profileId: UUID, isSyncing: Bool) {
        if isSyncing {
            profileStates[profileId] = .syncing
            profileErrors[profileId] = nil
        } else {
            profileStates[profileId] = .idle
        }
        updateAggregateState()
    }

    /// Returns true if we're monitoring an externally-started sync for this profile
    func isMonitoringExternalSync(for profileId: UUID) -> Bool {
        monitoringExternalSyncs.contains(profileId)
    }

    // MARK: - Notification Muting

    /// Mute file change notifications for a profile's current sync
    func muteNotifications(for profileId: UUID) {
        mutedProfileNotifications.insert(profileId)
    }

    /// Unmute notifications for a profile (called when sync ends)
    func unmuteNotifications(for profileId: UUID) {
        mutedProfileNotifications.remove(profileId)
    }

    /// Check if notifications are muted for a profile
    func isNotificationsMuted(for profileId: UUID) -> Bool {
        mutedProfileNotifications.contains(profileId)
    }

    /// Read the last error message from a log file
    private func readLastErrorFromLog(_ logPath: String) -> String? {
        guard FileManager.default.fileExists(atPath: logPath),
              let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Look for error lines in reverse order (most recent first)
        let lines = content.components(separatedBy: .newlines).reversed()
        var errorMessages: [String] = []
        var criticalErrors: [String] = []  // Track critical/actionable errors separately
        var foundFailedMarker = false

        for line in lines {
            // Stop when we hit a sync start marker (previous run)
            if SyncLogPatterns.isSyncStarted(line) && foundFailedMarker {
                break
            }

            // If the most recent sync was successful, there's no error to show
            if SyncLogPatterns.isSyncCompleted(line) {
                return nil
            }

            // Mark that we found the failure point
            if SyncLogPatterns.isSyncFailed(line) {
                foundFailedMarker = true
                continue
            }

            // Only collect errors after we found the failure marker
            guard foundFailedMarker else { continue }

            // Extract error message from line (supports CRITICAL and JSON formats)
            guard let rawMsg = SyncLogPatterns.extractErrorMessage(from: line) else { continue }

            // Clean up ANSI codes
            var msg = SyncLogPatterns.stripANSICodes(rawMsg)

            // Skip generic abort messages - they don't provide useful info
            if SyncLogPatterns.isGenericAbortMessage(msg) {
                continue
            }

            // Transient "all files were changed" error should not be shown
            if SyncLogPatterns.isTransientAllFilesChangedError(msg) {
                continue
            }

            // Clean up error message prefixes
            msg = SyncLogPatterns.cleanErrorMessage(msg)

            guard !msg.isEmpty else { continue }

            // Track critical/actionable errors separately (they're more useful to show)
            if SyncLogPatterns.isCriticalError(msg) && !criticalErrors.contains(msg) {
                criticalErrors.append(msg)
            } else if !errorMessages.contains(msg) {
                errorMessages.append(msg)
            }

            // Stop after finding enough errors
            if criticalErrors.count >= 1 || errorMessages.count >= 2 {
                break
            }
        }

        // Prefer critical errors over general errors
        let bestError = criticalErrors.first ?? errorMessages.first

        if let error = bestError {
            // Truncate if too long
            if error.count > 300 {
                return String(error.prefix(300)) + "..."
            }
            return error
        }

        return nil
    }

    // MARK: - Private Methods

    /// Check if a sync is currently running for this profile via lock file
    /// Returns the PID if found, nil otherwise
    private func detectRunningSyncPID(for profile: SyncProfile) -> Int32? {
        let lockPath = profile.lockFilePath
        guard FileManager.default.fileExists(atPath: lockPath),
              let pidStr = try? String(contentsOfFile: lockPath, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr),
              kill(pid, 0) == 0 else {
            return nil
        }
        return pid
    }

    /// Detect running syncs at startup and start monitoring them
    private func detectAndResumeRunningSyncs() {
        for profile in profileStore.enabledProfiles {
            if let pid = detectRunningSyncPID(for: profile) {
                profileStates[profile.id] = .syncing
                monitoringExternalSyncs.insert(profile.id)
                startPollingForSyncCompletion(profile: profile, pid: pid)
            }
        }
        updateAggregateState()
    }

    /// Poll until the sync process exits
    private func startPollingForSyncCompletion(profile: SyncProfile, pid: Int32) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3.0)

        let profileId = profile.id
        let lockPath = profile.lockFilePath

        timer.setEventHandler { [weak self] in
            // Check if process exited or lock file removed
            if kill(pid, 0) != 0 || !FileManager.default.fileExists(atPath: lockPath) {
                timer.cancel()
                DispatchQueue.main.async {
                    self?.handleExternalSyncCompleted(profileId: profileId)
                }
            }
        }

        syncCompletionPollers[profile.id] = timer
        timer.resume()
    }

    /// Handle when an externally-monitored sync completes
    private func handleExternalSyncCompleted(profileId: UUID) {
        syncCompletionPollers[profileId]?.cancel()
        syncCompletionPollers.removeValue(forKey: profileId)
        monitoringExternalSyncs.remove(profileId)

        // Determine success/failure from log
        if let profile = profileStore.profile(for: profileId),
           let error = readLastErrorFromLog(profile.logPath) {
            profileStates[profileId] = .error("Sync failed")
            profileErrors[profileId] = error
        } else {
            profileStates[profileId] = .idle
            lastSyncTime = Date()
        }

        updateAggregateState()
    }

    /// Clean up stale lock files on app startup
    /// Removes /tmp lock files where the PID is no longer running
    /// Also removes rclone bisync .lck files if no rclone process is running
    private func cleanupStaleLockFiles() {
        let fm = FileManager.default

        // Clean up SyncTray's /tmp lock files
        for profile in profileStore.profiles {
            let lockPath = profile.lockFilePath
            guard fm.fileExists(atPath: lockPath) else { continue }

            // Read PID and check if process is still running
            if let pidString = try? String(contentsOfFile: lockPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidString) {
                // kill with signal 0 checks if process exists without sending a signal
                if kill(pid, 0) != 0 {
                    // Process not running - remove stale lock
                    try? fm.removeItem(atPath: lockPath)
                }
            } else {
                // Could not read/parse PID - remove the lock file
                try? fm.removeItem(atPath: lockPath)
            }
        }

        // Clean up rclone bisync lock files if no rclone process is running
        cleanupRcloneBisyncLocks()
    }

    /// Remove stale rclone bisync .lck files when no rclone process is running
    /// This allows sync to continue from where it left off after an interrupted sync
    private func cleanupRcloneBisyncLocks() {
        let fm = FileManager.default
        let bisyncDir = "\(NSHomeDirectory())/Library/Caches/rclone/bisync"

        // Check if any rclone process is running
        let rcloneRunning = isRcloneProcessRunning()

        if rcloneRunning {
            // rclone is running, don't remove lock files
            return
        }

        // No rclone running - remove all stale .lck files
        guard let files = try? fm.contentsOfDirectory(atPath: bisyncDir) else { return }

        for file in files where file.hasSuffix(".lck") {
            let fullPath = "\(bisyncDir)/\(file)"
            try? fm.removeItem(atPath: fullPath)
            SyncTraySettings.debugLog("Removed stale rclone bisync lock: \(file)")
        }
    }

    /// Check if any rclone process is currently running
    private func isRcloneProcessRunning() -> Bool {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "rclone"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func setupProfileObserver() {
        profileStore.$profiles
            .sink { [weak self] _ in
                self?.startWatchingAllProfiles()
                self?.updateAggregateState()
            }
            .store(in: &cancellables)
    }

    private func startWatchingAllProfiles() {
        // Stop all existing log watchers
        for (id, watcher) in logWatchers {
            watcher.stopWatching()
            logWatchers.removeValue(forKey: id)
        }

        // Stop all existing directory watchers
        for (id, watcher) in directoryWatchers {
            watcher.stop()
            directoryWatchers.removeValue(forKey: id)
        }

        // Start watchers for all enabled profiles
        for profile in profileStore.enabledProfiles {
            startWatching(profile: profile)        // Log watcher
            startWatchingDirectory(for: profile)   // Directory watcher
        }
    }

    private func startWatching(profile: SyncProfile) {
        let watcher = LogWatcher(logPath: profile.logPath)
        watcher.delegate = self
        watcher.startWatching()
        logWatchers[profile.id] = watcher

        // If a sync is already running (detected at startup), use faster polling
        if profileStates[profile.id] == .syncing {
            watcher.setActivelySyncing(true)
        } else {
            profileStates[profile.id] = .idle
        }
    }

    /// Start watching a profile's local sync directory for file changes
    private func startWatchingDirectory(for profile: SyncProfile) {
        guard !profile.localSyncPath.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: profile.localSyncPath) else { return }

        let profileId = profile.id
        let profileName = profile.name
        let watchPath = profile.localSyncPath
        let shortId = String(profileId.uuidString.prefix(8))
        SyncTraySettings.debugLog("Starting watcher for '\(profileName)' [id:\(shortId)] at: \(watchPath)")

        let watcher = DirectoryWatcher(
            paths: [watchPath],
            debounceInterval: 5.0,
            debugLabel: "\(profileName) [\(shortId)]"
        ) { [weak self] in
            Task { @MainActor in
                SyncTraySettings.debugLog("Change callback fired for '\(profileName)' [id:\(shortId)] -> triggering sync")
                self?.handleDirectoryChange(for: profileId)
            }
        }
        watcher.start()
        directoryWatchers[profile.id] = watcher
    }

    /// Handle file system changes detected by DirectoryWatcher
    private func handleDirectoryChange(for profileId: UUID) {
        // Skip if profile is already syncing (avoid duplicate work)
        if profileStates[profileId] == .syncing {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - already syncing")
            return
        }

        // Skip if drive not mounted
        if profileStates[profileId] == .driveNotMounted {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - drive not mounted")
            return
        }

        // Get profile and verify it's still valid
        guard let profile = profileStore.profile(for: profileId),
              profile.isEnabled else {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - profile not found or disabled")
            return
        }

        SyncTraySettings.debugLog("DirectoryWatcher: Triggering sync for '\(profile.name)' (path: \(profile.localSyncPath))")

        // Trigger sync for this specific profile
        // Note: Lock file in sync script handles concurrent sync prevention
        Task {
            await runSyncScript(for: profile)
        }
    }

    private func stopWatching(profileId: UUID) {
        logWatchers[profileId]?.stopWatching()
        logWatchers.removeValue(forKey: profileId)

        directoryWatchers[profileId]?.stop()
        directoryWatchers.removeValue(forKey: profileId)

        profileStates.removeValue(forKey: profileId)
    }

    private func checkInitialState() {
        if profileStore.profiles.isEmpty {
            currentState = .notConfigured
            return
        }

        // Check each enabled profile
        for profile in profileStore.enabledProfiles {
            if !profile.drivePathToMonitor.isEmpty &&
               !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
                profileStates[profile.id] = .driveNotMounted
            } else {
                profileStates[profile.id] = .idle
            }
        }

        updateAggregateState()
    }

    /// Update the aggregate state (worst state wins)
    private func updateAggregateState() {
        if profileStore.profiles.isEmpty {
            currentState = .notConfigured
            return
        }

        if profileStore.enabledProfiles.isEmpty {
            currentState = .idle
            return
        }

        // Priority: error > syncing > driveNotMounted > idle
        var hasError = false
        var hasSyncing = false
        var hasDriveNotMounted = false
        var errorMessage: String?

        for state in profileStates.values {
            switch state {
            case .error(let msg):
                hasError = true
                errorMessage = msg
            case .syncing:
                hasSyncing = true
            case .driveNotMounted:
                hasDriveNotMounted = true
            default:
                break
            }
        }

        if hasError {
            currentState = .error(errorMessage ?? "Unknown error")
        } else if hasSyncing {
            currentState = .syncing
        } else if hasDriveNotMounted {
            currentState = .driveNotMounted
        } else {
            currentState = .idle
        }
    }

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleVolumeMount(notification)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleVolumeUnmount(notification)
            }
        }
    }

    private func handleVolumeMount(_ notification: Notification) {
        guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else {
            return
        }

        for profile in profileStore.enabledProfiles {
            let drivePath = profile.drivePathToMonitor
            guard !drivePath.isEmpty else { continue }

            if drivePath.hasPrefix(volumePath) || volumePath == drivePath {
                notificationService.resetDriveNotMountedState(for: profile.id)
                if profileStates[profile.id] == .driveNotMounted {
                    profileStates[profile.id] = .idle
                }

                // Restart directory watcher for this profile (path is now available)
                directoryWatchers[profile.id]?.stop()
                directoryWatchers.removeValue(forKey: profile.id)
                startWatchingDirectory(for: profile)
            }
        }

        updateAggregateState()
    }

    private func handleVolumeUnmount(_ notification: Notification) {
        guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else {
            return
        }

        for profile in profileStore.enabledProfiles {
            let drivePath = profile.drivePathToMonitor
            guard !drivePath.isEmpty else { continue }

            if drivePath.hasPrefix(volumePath) || volumePath == drivePath {
                profileStates[profile.id] = .driveNotMounted
                notificationService.notifyDriveNotMounted(profileId: profile.id, profileName: profile.name)
            }
        }

        updateAggregateState()
    }

    private func runSyncScript(for profile: SyncProfile) async {
        // Check if drive is mounted
        if !profile.drivePathToMonitor.isEmpty &&
           !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
            await MainActor.run {
                profileStates[profile.id] = .driveNotMounted
                notificationService.notifyDriveNotMounted(profileId: profile.id, profileName: profile.name)
                updateAggregateState()
            }
            return
        }

        guard FileManager.default.fileExists(atPath: SyncProfile.sharedScriptPath) else {
            await MainActor.run {
                profileStates[profile.id] = .error("Script not found")
                updateAggregateState()
            }
            return
        }

        guard FileManager.default.fileExists(atPath: profile.configPath) else {
            await MainActor.run {
                profileStates[profile.id] = .error("Config not found")
                updateAggregateState()
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [SyncProfile.sharedScriptPath, profile.configPath]

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            print("Failed to run sync script for \(profile.name): \(error)")
        }
    }

    private func processLogEvent(_ event: ParsedLogEvent, profileId: UUID) {
        let profile = profileStore.profile(for: profileId)
        let profileName = profile?.name ?? "Unknown"
        let syncDirectoryPath = profile?.localSyncPath ?? ""

        switch event.type {
        case .syncStarted:
            profileStates[profileId] = .syncing
            profileErrors[profileId] = nil  // Clear previous error on new sync
            lastSeenErrorMessage[profileId] = nil  // Clear last seen error
            syncProgress = nil  // Reset progress for new sync
            currentSyncChanges[profileId] = []
            logWatchers[profileId]?.setActivelySyncing(true)  // Increase polling frequency
            notificationService.notifySyncStarted(profileId: profileId, profileName: profileName)

        case .syncCompleted:
            profileStates[profileId] = .idle
            profileErrors[profileId] = nil  // Clear error on success
            lastSeenErrorMessage[profileId] = nil
            syncProgress = nil  // Clear progress when sync completes
            unmuteNotifications(for: profileId)  // Clear mute state
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            lastSyncTime = event.timestamp
            let changesCount = currentSyncChanges[profileId]?.count ?? 0
            notificationService.notifySyncCompleted(
                changesCount: changesCount,
                profileId: profileId,
                profileName: profileName,
                syncDirectoryPath: syncDirectoryPath
            )
            currentSyncChanges[profileId] = nil

        case .syncFailed(let exitCode, let message):
            // Check if the error message (or the last seen error) is a transient one
            let errorToCheck = message ?? lastSeenErrorMessage[profileId]
            if let msg = errorToCheck, SyncLogPatterns.isTransientAllFilesChangedError(msg) {
                // Transient "all files were changed" - just clear state, don't show error
                syncProgress = nil
                lastSeenErrorMessage[profileId] = nil
                unmuteNotifications(for: profileId)  // Clear mute state even on transient
                logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
                currentSyncChanges.removeAll()
                // Reset to idle since this isn't a real error
                profileStates[profileId] = .idle
                break
            }

            profileStates[profileId] = .error("Exit code \(exitCode)")
            syncProgress = nil  // Clear progress on failure
            lastSeenErrorMessage[profileId] = nil
            unmuteNotifications(for: profileId)  // Clear mute state on failure
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            // Only use the syncFailed message if we don't already have a more specific error
            if profileErrors[profileId] == nil, let msg = message {
                profileErrors[profileId] = msg
            }
            let errorDescription = profileErrors[profileId] ?? message ?? "Exit code \(exitCode)"
            notificationService.notifySyncError(
                "Sync failed: \(errorDescription)",
                profileId: profileId,
                profileName: profile?.name
            )
            currentSyncChanges[profileId] = nil

        case .errorMessage(let message):
            // Track all error messages so we can correlate with syncFailed events
            lastSeenErrorMessage[profileId] = message

            // Transient "all files were changed" error should not be stored as a displayed error
            if SyncLogPatterns.isTransientAllFilesChangedError(message) {
                break
            }

            // Prefer critical/actionable errors over file-level errors
            // Critical errors tell us what to do (e.g., "out of sync", "resync")
            // File-level errors (e.g., "Path1 file not found") are less actionable
            let isCriticalError = SyncLogPatterns.isCriticalError(message)
            let existingIsCritical = profileErrors[profileId].map {
                SyncLogPatterns.isCriticalError($0)
            } ?? false

            // Store error if: no existing error, OR new error is critical and existing isn't
            if profileErrors[profileId] == nil || (isCriticalError && !existingIsCritical) {
                profileErrors[profileId] = message
            }

        case .driveNotMounted:
            profileStates[profileId] = .driveNotMounted
            notificationService.notifyDriveNotMounted(profileId: profileId, profileName: profileName)

        case .syncAlreadyRunning:
            break

        case .fileChange(var change):
            change.profileName = profileName
            if currentSyncChanges[profileId] == nil {
                currentSyncChanges[profileId] = []
            }
            currentSyncChanges[profileId]?.append(change)
            addRecentChange(change)
            // Only send notification if not muted
            if !mutedProfileNotifications.contains(profileId) {
                notificationService.notifyFileChange(change, profileId: profileId, syncDirectoryPath: syncDirectoryPath)
            }

        case .stats(let stats):
            if let bytes = stats.bytes, let totalBytes = stats.totalBytes, totalBytes > 0 {
                syncProgress = SyncProgress(
                    bytesTransferred: Int64(bytes),
                    totalBytes: Int64(totalBytes),
                    eta: stats.eta,
                    speed: stats.speed,
                    transfersDone: stats.transfers ?? 0,
                    totalTransfers: stats.totalTransfers ?? 0,
                    checksDone: stats.checks ?? 0,
                    totalChecks: stats.totalChecks ?? 0,
                    elapsedTime: stats.elapsedTime,
                    errors: stats.errors ?? 0,
                    transferringFiles: stats.transferring ?? [],
                    listedCount: stats.listed
                )
            }

        case .unknown:
            break
        }

        updateAggregateState()
    }

    private func addRecentChange(_ change: FileChange) {
        recentChanges.insert(change, at: 0)
        if recentChanges.count > maxRecentChanges {
            recentChanges = Array(recentChanges.prefix(maxRecentChanges))
        }
    }

    /// Find which profile a log watcher belongs to
    private func profileId(for watcher: LogWatcher) -> UUID? {
        for (id, w) in logWatchers {
            if w === watcher {
                return id
            }
        }
        return nil
    }
}

// MARK: - LogWatcherDelegate

extension SyncManager: LogWatcherDelegate {
    nonisolated func logWatcher(_ watcher: LogWatcher, didReceiveNewLines lines: [String]) {
        // Process synchronously when already on main thread for immediate state updates
        // This fixes the race condition where UI renders before state is updated
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                processLogLinesForWatcher(watcher, lines: lines)
            }
        } else {
            Task { @MainActor in
                self.processLogLinesForWatcher(watcher, lines: lines)
            }
        }
    }

    /// Process log lines for a watcher (must be called on main actor)
    private func processLogLinesForWatcher(_ watcher: LogWatcher, lines: [String]) {
        guard let profileId = profileId(for: watcher) else { return }

        for line in lines {
            if let event = logParser.parse(line: line) {
                processLogEvent(event, profileId: profileId)
            }
        }
    }
}

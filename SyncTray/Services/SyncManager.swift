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

    /// State per profile (keyed by profile ID)
    @Published private(set) var profileStates: [UUID: SyncState] = [:]

    /// Last error message per profile (for display in UI)
    @Published private(set) var profileErrors: [UUID: String] = [:]

    let profileStore: ProfileStore

    private var logWatchers: [UUID: LogWatcher] = [:]
    private let logParser = LogParser()
    private let notificationService = NotificationService.shared
    private let setupService = SyncSetupService.shared

    private var workspaceObserver: NSObjectProtocol?
    private var currentSyncChanges: [FileChange] = []
    private var cancellables = Set<AnyCancellable>()

    private let maxRecentChanges = 20

    init(profileStore: ProfileStore? = nil) {
        self.profileStore = profileStore ?? ProfileStore()
        setupWorkspaceObserver()
        setupProfileObserver()
        checkInitialState()
        startWatchingAllProfiles()
    }

    deinit {
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
            for profile in profilesToSync {
                await runSyncScript(for: profile)
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
    func lastError(for profileId: UUID) -> String? {
        // If we have a cached error, return it
        if let error = profileErrors[profileId] {
            return error
        }

        // Otherwise, try to read the last error from the log file
        guard let profile = profileStore.profile(for: profileId) else { return nil }
        return readLastErrorFromLog(profile.logPath)
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
        var foundFailedMarker = false

        for line in lines {
            // Stop when we hit a "Starting bisync" marker (previous run)
            if line.contains("Starting bisync") && foundFailedMarker {
                break
            }

            // If the most recent sync was successful, there's no error to show
            if line.contains("Bisync completed successfully") {
                return nil
            }

            // Mark that we found the failure point
            if line.contains("Bisync failed with exit code") {
                foundFailedMarker = true
                continue
            }

            // Only collect errors after we found the failure marker
            guard foundFailedMarker else { continue }

            // Check for rclone JSON error messages
            if line.contains("\"level\":\"error\"") || line.contains("\"level\":\"notice\"") {
                // Parse the error message from JSON
                if let msgRange = line.range(of: "\"msg\":\""),
                   let endRange = line[msgRange.upperBound...].range(of: "\"") {
                    var errorMsg = String(line[msgRange.upperBound..<endRange.lowerBound])

                    // Clean up ANSI codes
                    errorMsg = errorMsg.replacingOccurrences(of: "\\u001b[", with: "")
                    errorMsg = errorMsg.replacingOccurrences(of: #"\[\d+m"#, with: "", options: .regularExpression)
                    errorMsg = errorMsg.replacingOccurrences(of: "[0m", with: "")
                    errorMsg = errorMsg.replacingOccurrences(of: "[31m", with: "")
                    errorMsg = errorMsg.replacingOccurrences(of: "[33m", with: "")
                    errorMsg = errorMsg.replacingOccurrences(of: "[35m", with: "")
                    errorMsg = errorMsg.replacingOccurrences(of: "[36m", with: "")

                    // Always skip generic "Bisync aborted" messages - they don't provide useful info
                    if errorMsg.contains("Bisync aborted") || errorMsg.contains("Failed to bisync") {
                        continue
                    }

                    // Clean up prefixes
                    if let range = errorMsg.range(of: "Bisync critical error: ") {
                        errorMsg = String(errorMsg[range.upperBound...])
                    }

                    if !errorMsg.isEmpty && !errorMessages.contains(errorMsg) {
                        errorMessages.append(errorMsg)
                    }

                    // Stop after finding 2 meaningful errors
                    if errorMessages.count >= 2 {
                        break
                    }
                }
            }
        }

        // Return the most specific error found
        if let firstError = errorMessages.first {
            // Truncate if too long
            if firstError.count > 300 {
                return String(firstError.prefix(300)) + "..."
            }
            return firstError
        }

        return nil
    }

    // MARK: - Private Methods

    private func setupProfileObserver() {
        profileStore.$profiles
            .sink { [weak self] _ in
                self?.startWatchingAllProfiles()
                self?.updateAggregateState()
            }
            .store(in: &cancellables)
    }

    private func startWatchingAllProfiles() {
        // Stop all existing watchers
        for (id, watcher) in logWatchers {
            watcher.stopWatching()
            logWatchers.removeValue(forKey: id)
        }

        // Start watchers for all enabled profiles
        for profile in profileStore.enabledProfiles {
            startWatching(profile: profile)
        }
    }

    private func startWatching(profile: SyncProfile) {
        let watcher = LogWatcher(logPath: profile.logPath)
        watcher.delegate = self
        watcher.startWatching()
        logWatchers[profile.id] = watcher
        profileStates[profile.id] = .idle
    }

    private func stopWatching(profileId: UUID) {
        logWatchers[profileId]?.stopWatching()
        logWatchers.removeValue(forKey: profileId)
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
                notificationService.resetDriveNotMountedState()
                if profileStates[profile.id] == .driveNotMounted {
                    profileStates[profile.id] = .idle
                }
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
                notificationService.notifyDriveNotMounted()
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
                notificationService.notifyDriveNotMounted()
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
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Failed to run sync script for \(profile.name): \(error)")
        }
    }

    private func processLogEvent(_ event: ParsedLogEvent, profileId: UUID) {
        switch event.type {
        case .syncStarted:
            profileStates[profileId] = .syncing
            profileErrors[profileId] = nil  // Clear previous error on new sync
            currentSyncChanges.removeAll()
            notificationService.notifySyncStarted()

        case .syncCompleted:
            profileStates[profileId] = .idle
            profileErrors[profileId] = nil  // Clear error on success
            lastSyncTime = event.timestamp
            notificationService.notifySyncCompleted(changesCount: currentSyncChanges.count)
            currentSyncChanges.removeAll()

        case .syncFailed(let exitCode, let message):
            let errorMsg = message ?? "Exit code \(exitCode)"
            profileStates[profileId] = .error("Exit code \(exitCode)")
            if let msg = message {
                profileErrors[profileId] = msg
            }
            let profile = profileStore.profile(for: profileId)
            notificationService.notifySyncError(
                "Sync failed: \(errorMsg)",
                profileId: profileId,
                profileName: profile?.name
            )
            currentSyncChanges.removeAll()

        case .errorMessage(let message):
            // Store error message for display (don't change state yet, wait for syncFailed)
            profileErrors[profileId] = message

        case .driveNotMounted:
            profileStates[profileId] = .driveNotMounted
            notificationService.notifyDriveNotMounted()

        case .syncAlreadyRunning:
            break

        case .fileChange(let change):
            currentSyncChanges.append(change)
            addRecentChange(change)
            notificationService.notifyFileChange(change)

        case .stats:
            break

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
        Task { @MainActor in
            guard let profileId = profileId(for: watcher) else { return }

            for line in lines {
                if let event = logParser.parse(line: line) {
                    processLogEvent(event, profileId: profileId)
                }
            }
        }
    }
}

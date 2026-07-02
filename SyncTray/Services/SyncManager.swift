import Foundation
import AppKit
import Combine
import ServiceManagement

@MainActor
final class SyncManager: ObservableObject {
    @Published private(set) var currentState: SyncState = .idle
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var recentChanges: [FileChange] = []
    /// Profiles with an in-flight app-initiated ("Sync Now" / directory-watch) run.
    /// Per-profile so one hung profile no longer blocks manual syncs for all others.
    @Published private(set) var manualSyncingProfiles: Set<UUID> = []

    /// True while any profile has an app-initiated sync in flight.
    /// Computed from `manualSyncingProfiles` so existing view bindings keep working;
    /// SwiftUI re-reads it whenever the published set changes.
    var isManualSyncRunning: Bool { !manualSyncingProfiles.isEmpty }

    /// Sync progress per profile (keyed by profile ID)
    @Published private(set) var profileProgress: [UUID: SyncProgress] = [:]

    /// Aggregate sync progress (first syncing profile's progress) - for menu bar icon
    var syncProgress: SyncProgress? {
        // Find the first profile that is currently syncing and has progress
        for (profileId, state) in profileStates {
            if state == .syncing, let progress = profileProgress[profileId] {
                return progress
            }
        }
        return nil
    }

    /// State per profile (keyed by profile ID)
    @Published private(set) var profileStates: [UUID: SyncState] = [:]

    /// Last error message per profile (for display in UI)
    @Published private(set) var profileErrors: [UUID: String] = [:]

    /// Mount state per profile (for mount mode profiles only)
    @Published private(set) var profileMountStates: [UUID: MountState] = [:]

    /// Active transport per profile (primary or fallback)
    @Published private(set) var profileTransports: [UUID: ActiveTransport] = [:]

    /// Paused profiles (session-only, not persisted - resets on app restart)
    @Published private(set) var pausedProfiles: Set<UUID> = []

    let profileStore: ProfileStore

    private var logWatchers: [UUID: LogWatcher] = [:]
    private var directoryWatchers: [UUID: DirectoryWatcher] = [:]
    private let logParser = LogParser()
    private let notificationService = NotificationService.shared
    private let setupService = SyncSetupService.shared
    private let cacheService = VFSCacheService.shared

    private var heartbeatTimer: DispatchSourceTimer?
    private var workspaceObserver: NSObjectProtocol?
    private var currentSyncChanges: [UUID: [FileChange]] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Track the last error message per profile (for correlating with syncFailed events)
    private var lastSeenErrorMessage: [UUID: String] = [:]

    /// Track sync start times per profile for duration measurement
    private var syncStartTimes: [UUID: Date] = [:]

    /// Track check phase: once totalChecks > 0 and checksDone < totalChecks, phase is active
    private var checkPhaseStartTimes: [UUID: Date] = [:]
    private var checkPhaseReported: Set<UUID> = []

    /// Profiles where we're monitoring an externally-started sync
    private var monitoringExternalSyncs: Set<UUID> = []

    /// Timers polling for sync completion
    private var syncCompletionPollers: [UUID: DispatchSourceTimer] = [:]

    // MARK: - Auto-Fix Backoff State

    /// Timestamps of the last consecutive auto-fix attempts per profile (in-memory only, not persisted).
    /// Used to implement backoff: if 2+ attempts within autoFixBackoffWindow seconds both fail, stop auto-fixing.
    private var autoFixAttempts: [UUID: [Date]] = [:]

    /// Profiles where auto-fix has been suppressed due to repeated failures.
    /// Reset when the profile completes a successful sync.
    private var autoFixSuppressed: Set<UUID> = []

    /// Profiles where an auto-fix resync is currently in-flight.
    /// Prevents a second Task from being dispatched before the first completes.
    private var autoFixInFlight: Set<UUID> = []

    /// The time window (seconds) within which consecutive auto-fix failures trigger backoff suppression.
    private let autoFixBackoffWindow: TimeInterval = 5 * 60  // 5 minutes

    private let maxRecentChanges = 20

    init(profileStore: ProfileStore? = nil) {
        self.profileStore = profileStore ?? ProfileStore()
        setupWorkspaceObserver()
        setupProfileObserver()
        cleanupStaleLockFiles()
        setupService.refreshSharedScriptIfChanged()  // Propagate script template updates
        setupService.cleanupStaleMounts(mountProfiles: self.profileStore.profiles)  // Clean up stale mounts on startup
        detectAndResumeRunningSyncs()  // After cleanup, detect external syncs
        checkInitialState()
        startWatchingAllProfiles()
        updateMountStates()  // Initialize mount states for mount mode profiles
        // Report active profile count and configuration snapshot for telemetry
        TelemetryService.shared.recordProfileCount(self.profileStore.enabledProfiles.count)
        TelemetryService.shared.recordAllProfileConfigurations(self.profileStore.profiles)
        startSessionHeartbeat()
    }

    deinit {
        // Cancel heartbeat timer
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

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
        let profilesToSync: [SyncProfile]
        if let profile = profile {
            // Skip if this specific profile is paused
            guard !isPaused(for: profile.id) else {
                SyncTraySettings.debugLog("Skipping manual sync for paused profile: \(profile.name)")
                return
            }
            // Per-profile guard: don't double-trigger a profile that's already
            // running an app-initiated sync (a different profile hanging no
            // longer blocks this one).
            guard !manualSyncingProfiles.contains(profile.id) else { return }
            profilesToSync = [profile]
        } else {
            // Filter out paused profiles and any already mid-sync
            profilesToSync = profileStore.enabledProfiles.filter {
                !isPaused(for: $0.id) && !manualSyncingProfiles.contains($0.id)
            }
        }

        guard !profilesToSync.isEmpty else {
            // Only surface "not configured" when there genuinely are no enabled
            // profiles — not when they're simply all mid-sync already.
            if profileStore.enabledProfiles.isEmpty {
                currentState = .notConfigured
            }
            return
        }

        let syncingIds = profilesToSync.map { $0.id }
        manualSyncingProfiles.formUnion(syncingIds)

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
                manualSyncingProfiles.subtract(syncingIds)
            }
        }
    }

    // MARK: - Mount Mode Management

    /// Mount a profile (for mount mode only)
    func mountProfile(_ profile: SyncProfile) {
        guard profile.isMountMode else { return }

        profileMountStates[profile.id] = .mounting

        Task {
            do {
                // Check if already mounted
                if setupService.isMounted(profile: profile) {
                    await MainActor.run {
                        profileMountStates[profile.id] = .mounted
                    }
                    return
                }

                // Load the launchd agent (which will trigger the mount script)
                let success = setupService.loadAgent(for: profile)

                await MainActor.run {
                    if success {
                        // Give mount a moment to establish
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                            if self?.setupService.isMounted(profile: profile) == true {
                                self?.profileMountStates[profile.id] = .mounted
                                TelemetryService.shared.recordMountOperation(
                                    profileId: profile.id,
                                    profileName: profile.name,
                                    operation: "mount",
                                    result: "success"
                                )
                                // Auto-refresh pinned directories after successful mount
                                if !profile.pinnedDirectories.isEmpty {
                                    Task {
                                        // Wait for RC API to be ready
                                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                                        await self?.cacheService.refreshPinnedDirectories(for: profile)
                                    }
                                }
                            } else {
                                self?.profileMountStates[profile.id] = .failed("Mount did not establish")
                                TelemetryService.shared.recordMountOperation(
                                    profileId: profile.id,
                                    profileName: profile.name,
                                    operation: "mount",
                                    result: "failure"
                                )
                            }
                        }
                    } else {
                        profileMountStates[profile.id] = .failed("Failed to load launchd agent")
                        TelemetryService.shared.recordMountOperation(
                            profileId: profile.id,
                            profileName: profile.name,
                            operation: "mount",
                            result: "failure"
                        )
                    }
                }
            }
        }
    }

    /// Unmount a profile (for mount mode only)
    func unmountProfile(_ profile: SyncProfile) {
        guard profile.isMountMode else { return }

        Task {
            do {
                try setupService.unmount(profile: profile)
                await MainActor.run {
                    profileMountStates[profile.id] = .unmounted
                    TelemetryService.shared.recordMountOperation(
                        profileId: profile.id,
                        profileName: profile.name,
                        operation: "unmount",
                        result: "success"
                    )
                }
            } catch {
                await MainActor.run {
                    profileMountStates[profile.id] = .failed(error.localizedDescription)
                    TelemetryService.shared.recordMountOperation(
                        profileId: profile.id,
                        profileName: profile.name,
                        operation: "unmount",
                        result: "failure"
                    )
                }
            }
        }
    }

    /// Get mount state for a specific profile
    func mountState(for profileId: UUID) -> MountState {
        profileMountStates[profileId] ?? .unmounted
    }

    /// Update mount states for all mount mode profiles
    func updateMountStates() {
        for profile in profileStore.enabledProfiles where profile.isMountMode {
            let isMounted = setupService.isMounted(profile: profile)
            if isMounted {
                profileMountStates[profile.id] = .mounted
            } else if profileMountStates[profile.id] == nil || profileMountStates[profile.id] == .mounted {
                // Only update to unmounted if it was previously mounted or unknown
                profileMountStates[profile.id] = .unmounted
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
                objectWillChange.send()  // Notify SwiftUI to update UI
            } catch {
                print("Failed to register login item: \(error)")
            }
        }
    }

    func disableLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
                objectWillChange.send()  // Notify SwiftUI to update UI
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

    /// Get active transport for a specific profile
    func activeTransport(for profileId: UUID) -> ActiveTransport {
        profileTransports[profileId] ?? .unknown
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

    // MARK: - Auto-Fix

    /// Attempt an automatic --resync recovery for the given profile.
    ///
    /// Called from `processLogEvent` when the auto-fix setting is enabled and the
    /// profile enters an out-of-sync error state. Implements a backoff guard:
    /// if the same profile triggers auto-fix **twice within 5 minutes**, auto-fix
    /// is suppressed for that profile until a successful sync clears the suppression.
    /// Note: suppression fires on the 2nd trigger (not the 2nd confirmed failure),
    /// because confirming failure requires the log-watcher round-trip.
    ///
    /// Reuses the same rclone bisync --resync process that `ProfileDetailView.runResync()`
    /// runs, but without UI state (the progress bar / output panel in the settings
    /// view is driven by the profile state change visible via `@Published profileStates`).
    func triggerAutoFix(for profile: SyncProfile) {
        let profileId = profile.id

        // Respect the global setting
        guard SyncTraySettings.autoFixSyncIssues else { return }

        // Skip paused profiles — auto-fix should never fire while the user has sync paused
        guard !isPaused(for: profileId) else {
            SyncTraySettings.debugLog("Auto-fix skipped: profile '\(profile.name)' is paused")
            return
        }

        // Auto-fix only applies to bisync mode — one-way sync and mount profiles do not
        // produce "out of sync" errors and have no --resync concept.
        guard profile.syncMode == .bisync else { return }

        // Never auto-resync against an unmounted external drive. The local path is missing
        // or replaced by an empty mount point, so a --resync would run against an empty/partial
        // local tree — exactly the case that cannot be safely auto-fixed. Reflect reality in the
        // UI and return WITHOUT recording an attempt, so the backoff budget is not consumed by a
        // condition the user can only resolve by reconnecting the drive.
        if !profile.drivePathToMonitor.isEmpty,
           !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
            SyncTraySettings.debugLog("Auto-fix skipped: external drive not mounted for '\(profile.name)'")
            TelemetryService.shared.recordAutoFixTriggered(
                profileId: profileId,
                profileName: profile.name,
                result: "skipped_drive_not_mounted"
            )
            profileStates[profileId] = .driveNotMounted
            updateAggregateState()
            return
        }

        // Skip if a resync is already in-flight for this profile
        guard !autoFixInFlight.contains(profileId) else {
            SyncTraySettings.debugLog("Auto-fix skipped: resync already in-flight for '\(profile.name)'")
            return
        }

        // Respect per-profile suppression (backoff guard) — return silently after the first
        // transition notification so the user is not spammed on every subsequent syncFailed event.
        guard !autoFixSuppressed.contains(profileId) else {
            SyncTraySettings.debugLog("Auto-fix suppressed (backoff) for '\(profile.name)'")
            return
        }

        // Record the attempt and check backoff threshold
        let now = Date()
        var attempts = autoFixAttempts[profileId] ?? []
        // Prune attempts outside the backoff window
        attempts = attempts.filter { now.timeIntervalSince($0) < autoFixBackoffWindow }
        attempts.append(now)
        autoFixAttempts[profileId] = attempts

        if attempts.count >= 2 {
            // Two failures within the window — suppress further auto-fix for this profile.
            // Only notify once (on the transition into suppressed state).
            autoFixSuppressed.insert(profileId)
            TelemetryService.shared.recordAutoFixTriggered(
                profileId: profileId,
                profileName: profile.name,
                result: "gave_up_backoff"
            )
            SyncTraySettings.debugLog("Auto-fix giving up (backoff) for '\(profile.name)' after \(attempts.count) attempts")
            notificationService.notifyAutoFixSuppressed(profileId: profileId, profileName: profile.name)
            return
        }

        // Good to go — notify user and start the resync
        SyncTraySettings.debugLog("Auto-fix triggering resync for '\(profile.name)'")
        TelemetryService.shared.recordAutoFixTriggered(
            profileId: profileId,
            profileName: profile.name,
            result: "triggered"
        )

        // Post a macOS notification so the user can see what's happening
        notificationService.notifyAutoFix(profileId: profileId, profileName: profile.name)

        // Clear current error and mark syncing so the UI updates
        clearError(for: profileId)
        setSyncing(for: profileId, isSyncing: true)
        // Ensure the log-watcher uses its faster polling cadence so it sees the
        // upcoming "Starting bisync" / "Bisync completed" markers promptly.
        logWatchers[profileId]?.setActivelySyncing(true)

        // Mark in-flight before dispatching
        autoFixInFlight.insert(profileId)

        Task {
            await performResync(for: profile)
        }
    }

    /// Resolve the remote reference and env-var overrides a resync should target,
    /// honouring the currently active transport (primary vs fallback) the same way
    /// the launchd sync script does. Without this, a resync launched while the
    /// profile runs on fallback would rebuild the wrong (primary) bisync pair.
    /// - Returns: the effective "remote:path" plus RCLONE_CONFIG_* env overrides
    ///   (non-empty only for the same-wire-type fallback that preserves the cache
    ///   by keeping the primary remote name).
    func resolveActiveRemote(for profile: SyncProfile) -> (remotePath: String, extraEnv: [String: String]) {
        let transport = profileTransports[profile.id] ?? .unknown
        let primaryRemotePath = "\(profile.rcloneRemote):\(profile.remotePath)"

        guard transport.isFallback, !profile.fallbackRemote.isEmpty else {
            return (primaryRemotePath, [:])
        }

        if profile.fallbackRequiresCacheRebuild || !profile.fallbackRemotePath.isEmpty {
            // Different wire type OR explicit path: swap full remote reference.
            // bisync uses a separate listing pair — consistent with the script.
            let effectiveFallbackPath = profile.fallbackRemotePath.isEmpty
                ? profile.remotePath : profile.fallbackRemotePath
            return ("\(profile.fallbackRemote):\(effectiveFallbackPath)", [:])
        }

        // Same wire type, same path: use env-var overrides to preserve bisync cache.
        let primaryRemoteName = profile.rcloneRemote.hasSuffix(":")
            ? String(profile.rcloneRemote.dropLast()) : profile.rcloneRemote
        let upperName = primaryRemoteName.uppercased().replacingOccurrences(of: "-", with: "_")
        var extraEnv: [String: String] = [:]
        if let fallbackConfig = RcloneConfigService.shared.readRemoteConfig(name: profile.fallbackRemote) {
            for (key, value) in fallbackConfig.values {
                let envKey = "RCLONE_CONFIG_\(upperName)_\(key.uppercased().replacingOccurrences(of: "-", with: "_"))"
                extraEnv[envKey] = value
            }
        }
        return (primaryRemotePath, extraEnv)
    }

    /// Run `rclone bisync --resync` for a profile directly (no UI output panel).
    /// Called by `triggerAutoFix`. On completion, state is updated via the existing
    /// log-watcher pipeline (same as scheduled syncs).
    private func performResync(for profile: SyncProfile) async {
        let profileId = profile.id

        // Capture all values from the main actor before going to the background
        let rcloneRemote = profile.rcloneRemote
        let localSyncPath = profile.localSyncPath
        let drivePathToMonitor = profile.drivePathToMonitor
        let filterPath = profile.filterFilePath
        let lockPath = profile.lockFilePath
        let logPath = profile.logPath
        let syncMode = profile.syncMode
        let syncDirection = profile.syncDirection
        let additionalFlags = profile.additionalRcloneFlags
        let fallbackTransport = profileTransports[profileId] ?? .unknown
        let fallbackRemote = profile.fallbackRemote
        let (effectiveRemotePath, extraEnv) = resolveActiveRemote(for: profile)
        let bisyncDir = "\(NSHomeDirectory())/Library/Caches/rclone/bisync"

        // Pre-flight: if a live lock already exists for a running process, skip.
        if let existingPidStr = try? String(contentsOfFile: lockPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           let existingPid = Int32(existingPidStr),
           kill(existingPid, 0) == 0 {
            SyncTraySettings.debugLog("Resync already in progress for '\(profile.name)', skipping auto-fix")
            autoFixInFlight.remove(profileId)
            setSyncing(for: profileId, isSyncing: false)
            return
        }

        // Re-check the external drive right before launching — it may have been unplugged in
        // the window between triggerAutoFix's guard and now (a resync can be queued behind an
        // in-flight sync, and large repos take ~12s). Running --resync against a vanished mount
        // point is the unsafe case we must never reach.
        if !drivePathToMonitor.isEmpty,
           !FileManager.default.fileExists(atPath: drivePathToMonitor) {
            SyncTraySettings.debugLog("Auto-fix aborted: external drive unmounted before resync for '\(profile.name)'")
            autoFixInFlight.remove(profileId)
            profileStates[profileId] = .driveNotMounted
            updateAggregateState()
            return
        }

        // Write a sentinel lock file NOW — before process.run() — so launchd cannot
        // spawn a concurrent rclone bisync against the same remote/path in the gap
        // between process creation and PID availability.
        let lockURL = URL(fileURLWithPath: lockPath)
        let sentinelWritten = (try? Data("pending".utf8).write(to: lockURL)) != nil
        if !sentinelWritten {
            SyncTraySettings.debugLog("Could not write sentinel lock for '\(profile.name)' — aborting auto-fix")
            autoFixInFlight.remove(profileId)
            setSyncing(for: profileId, isSyncing: false)
            return
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let fileManager = FileManager.default

                    // Remove stale bisync .lck files before resync (same as runResync in the view)
                    if let files = try? fileManager.contentsOfDirectory(atPath: bisyncDir) {
                        for file in files where file.hasSuffix(".lck") {
                            try? fileManager.removeItem(atPath: "\(bisyncDir)/\(file)")
                        }
                    }

                    // Locate rclone binary
                    let rclonePaths = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
                    guard let rclonePath = rclonePaths.first(where: { fileManager.fileExists(atPath: $0) }) else {
                        try? fileManager.removeItem(atPath: lockPath)
                        continuation.resume(throwing: NSError(
                            domain: "SyncManager",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "rclone not found"]
                        ))
                        return
                    }

                    let isFallbackActive = fallbackTransport.isFallback

                    var arguments: [String]

                    if syncMode == .bisync {
                        // --resync-mode newer: prefer the newest version per file so a
                        // stale remote copy never overwrites fresher local edits (the
                        // bare --resync default is path1 = remote wins).
                        arguments = ["bisync", effectiveRemotePath, localSyncPath,
                                     "--resync", "--resync-mode", "newer",
                                     "--verbose", "--use-json-log", "--stats", "2s"]
                    } else if syncDirection == .localToRemote {
                        arguments = ["sync", localSyncPath, effectiveRemotePath,
                                     "--verbose", "--use-json-log", "--stats", "2s"]
                    } else {
                        arguments = ["sync", effectiveRemotePath, localSyncPath,
                                     "--verbose", "--use-json-log", "--stats", "2s"]
                    }

                    if fileManager.fileExists(atPath: filterPath) {
                        arguments.append(contentsOf: ["--filter-from", filterPath])
                    }

                    // Resolve which remote name to check for no_check_certificate
                    let certCheckRemote = (isFallbackActive && !fallbackRemote.isEmpty)
                        ? fallbackRemote : rcloneRemote
                    if RcloneConfigService.shared.readRemoteConfig(name: certCheckRemote)?.values["no_check_certificate"] == "true" {
                        arguments.append("--no-check-certificate")
                    }

                    if !additionalFlags.isEmpty {
                        let extra = additionalFlags.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        arguments.append(contentsOf: extra)
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: rclonePath)
                    process.arguments = arguments

                    // Merge fallback env-var overrides into the process environment
                    if !extraEnv.isEmpty {
                        var env = ProcessInfo.processInfo.environment
                        for (key, value) in extraEnv {
                            env[key] = value
                        }
                        process.environment = env
                    }

                    // Route rclone output into the profile log file so the LogWatcher
                    // pipeline fires `.syncStarted` / `.syncCompleted` / `.syncFailed`.
                    // Without this, the profile would stay in `.syncing` indefinitely —
                    // the watcher would never see process termination. The bracket
                    // markers below mirror what `synctray-sync.sh` writes via `tee`.
                    if !fileManager.fileExists(atPath: logPath) {
                        fileManager.createFile(atPath: logPath, contents: nil)
                    }
                    let timestampFormatter = DateFormatter()
                    timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
                    let appendLog: (String) -> Void = { message in
                        let line = "\(timestampFormatter.string(from: Date())) - \(message)\n"
                        guard let data = line.data(using: .utf8),
                              let handle = FileHandle(forWritingAtPath: logPath) else { return }
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }

                    guard let processLog = FileHandle(forWritingAtPath: logPath) else {
                        try? fileManager.removeItem(atPath: lockPath)
                        continuation.resume(throwing: NSError(
                            domain: "SyncManager",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "could not open log file"]
                        ))
                        return
                    }
                    processLog.seekToEndOfFile()
                    process.standardOutput = processLog
                    process.standardError = processLog

                    appendLog("Starting bisync (auto-fix --resync)")

                    process.terminationHandler = { proc in
                        try? processLog.close()
                        let exit = proc.terminationStatus
                        appendLog(exit == 0
                            ? "Bisync completed successfully"
                            : "Bisync failed with exit code \(exit)")
                        try? fileManager.removeItem(atPath: lockPath)
                        continuation.resume()
                    }

                    do {
                        try process.run()
                        // Overwrite sentinel with the real PID now that we have it
                        try? "\(process.processIdentifier)".write(
                            toFile: lockPath, atomically: true, encoding: .utf8)
                    } catch {
                        try? processLog.close()
                        appendLog("Auto-fix failed to launch rclone: \(error.localizedDescription)")
                        try? fileManager.removeItem(atPath: lockPath)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            SyncTraySettings.debugLog("Auto-fix process error for '\(profile.name)': \(error)")
            autoFixInFlight.remove(profileId)
            setSyncing(for: profileId, isSyncing: false)
            return
        }

        // Clear in-flight on clean exit. State after completion (idle / error) is set by
        // the log-watcher pipeline via .syncCompleted / .syncFailed.
        autoFixInFlight.remove(profileId)
    }

    // MARK: - Notification Muting

    /// Mute file change notifications for a profile (persisted)
    func muteNotifications(for profileId: UUID) {
        guard var profile = profileStore.profile(for: profileId) else { return }
        profile.isMuted = true
        profileStore.update(profile)
    }

    /// Unmute notifications for a profile (persisted)
    func unmuteNotifications(for profileId: UUID) {
        guard var profile = profileStore.profile(for: profileId) else { return }
        profile.isMuted = false
        profileStore.update(profile)
    }

    /// Check if notifications are muted for a profile
    func isNotificationsMuted(for profileId: UUID) -> Bool {
        profileStore.profile(for: profileId)?.isMuted ?? false
    }

    // MARK: - Pause/Resume

    /// Check if a profile is paused
    func isPaused(for profileId: UUID) -> Bool {
        pausedProfiles.contains(profileId)
    }

    /// Check if all enabled profiles are paused
    var isAllPaused: Bool {
        let enabledIds = Set(profileStore.enabledProfiles.map { $0.id })
        guard !enabledIds.isEmpty else { return false }
        return enabledIds.isSubset(of: pausedProfiles)
    }

    /// Pause syncing for a specific profile (stops directory watcher, blocks manual/scheduled syncs)
    func pauseProfile(_ profileId: UUID) {
        guard let profile = profileStore.profile(for: profileId) else { return }

        pausedProfiles.insert(profileId)

        // Stop directory watcher for this profile
        directoryWatchers[profileId]?.stop()
        directoryWatchers.removeValue(forKey: profileId)

        // Actually stop scheduled syncs. Previously pause only set an in-memory
        // flag, so launchd kept firing the sync script every interval — the
        // "paused" profile still hammered the remote and the spinner never
        // rested. Unload the agent so no new runs start.
        setupService.unloadAgent(for: profile)

        // Terminate any in-flight run for this profile and clear its lock, so a
        // hung/slow sync can't keep holding the lock and block a later resume.
        terminateRunningSync(for: profile)

        // Close any open telemetry span so it isn't later reported as abandoned.
        TelemetryService.shared.recordSyncSkipped(
            profileId: profileId,
            profileName: profile.name,
            reason: "paused"
        )

        // Update profile state to paused
        profileStates[profileId] = .paused
        profileProgress[profileId] = nil
        logWatchers[profileId]?.setActivelySyncing(false)

        updateAggregateState()

        SyncTraySettings.debugLog("Paused profile: \(profile.name)")
        TelemetryService.shared.recordProfileStateChange(
            profileId: profileId,
            profileName: profile.name,
            action: "paused"
        )
    }

    /// Terminate any running sync process for `profile` (identified via its lock
    /// file PID) and remove the lock so a killed/stale run can't block the next
    /// start. Best-effort: signals the process group (launchd runs each job as
    /// its own group leader) so the bash script and its rclone child both stop.
    /// Safe to call when nothing is running.
    private func terminateRunningSync(for profile: SyncProfile) {
        if let pid = detectRunningSyncPID(for: profile) {
            // Negative PID targets the whole process group; fall back to the
            // single process if it isn't a group leader.
            if kill(-pid, SIGTERM) != 0 {
                kill(pid, SIGTERM)
            }
        }
        // Stop any external-sync completion poller watching this profile.
        syncCompletionPollers[profile.id]?.cancel()
        syncCompletionPollers.removeValue(forKey: profile.id)
        monitoringExternalSyncs.remove(profile.id)
        // Remove the lock file so the next run isn't blocked by a stale lock.
        try? FileManager.default.removeItem(atPath: profile.lockFilePath)
    }

    /// Resume syncing for a specific profile (restarts directory watcher)
    func resumeProfile(_ profileId: UUID) {
        guard let profile = profileStore.profile(for: profileId),
              profile.isEnabled else { return }

        pausedProfiles.remove(profileId)

        // Reload the launchd agent that pause unloaded so scheduled syncs run
        // again. (No-op if it somehow never unloaded.)
        setupService.loadAgent(for: profile)

        // Restart directory watcher for this profile
        startWatchingDirectory(for: profile)

        // Reset state to idle (or check drive mount status)
        if !profile.drivePathToMonitor.isEmpty &&
           !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
            profileStates[profileId] = .driveNotMounted
        } else {
            profileStates[profileId] = .idle
        }

        updateAggregateState()

        SyncTraySettings.debugLog("Resumed profile: \(profile.name)")
        TelemetryService.shared.recordProfileStateChange(
            profileId: profileId,
            profileName: profile.name,
            action: "resumed"
        )
    }

    /// Pause all enabled profiles
    func pauseAllProfiles() {
        for profile in profileStore.enabledProfiles {
            pauseProfile(profile.id)
        }
    }

    /// Resume all paused profiles
    func resumeAllProfiles() {
        // Create a copy since we're modifying the set while iterating
        let profilesToPause = pausedProfiles
        for profileId in profilesToPause {
            resumeProfile(profileId)
        }
    }

    /// Toggle pause state for a specific profile
    func togglePause(for profileId: UUID) {
        if isPaused(for: profileId) {
            resumeProfile(profileId)
        } else {
            pauseProfile(profileId)
        }
    }

    /// Toggle pause state for all profiles
    func togglePauseAll() {
        if isAllPaused {
            resumeAllProfiles()
        } else {
            pauseAllProfiles()
        }
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
        var resumedCount = 0
        for profile in profileStore.enabledProfiles {
            if let pid = detectRunningSyncPID(for: profile) {
                profileStates[profile.id] = .syncing
                monitoringExternalSyncs.insert(profile.id)
                startPollingForSyncCompletion(profile: profile, pid: pid)
                resumedCount += 1
            }
        }
        if resumedCount > 0 {
            TelemetryService.shared.recordResumedExternalSync(
                profileId: UUID(), // aggregate event
                profileName: "all",
                count: resumedCount
            )
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
        var staleLockCount = 0

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
                    staleLockCount += 1
                }
            } else {
                // Could not read/parse PID - remove the lock file
                try? fm.removeItem(atPath: lockPath)
                staleLockCount += 1
            }
        }

        if staleLockCount > 0 {
            TelemetryService.shared.recordStaleLockCleanup(count: staleLockCount, lockType: "synctray")
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

        var bisyncLockCount = 0
        for file in files where file.hasSuffix(".lck") {
            let fullPath = "\(bisyncDir)/\(file)"
            try? fm.removeItem(atPath: fullPath)
            bisyncLockCount += 1
            SyncTraySettings.debugLog("Removed stale rclone bisync lock: \(file)")
        }

        if bisyncLockCount > 0 {
            TelemetryService.shared.recordStaleLockCleanup(count: bisyncLockCount, lockType: "rclone_bisync")
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
        let enabledProfileIds = Set(profileStore.enabledProfiles.map { $0.id })

        // Remove watchers for profiles that are no longer enabled
        // (Don't touch watchers for profiles that are still enabled - avoids interrupting active syncs)
        for id in logWatchers.keys where !enabledProfileIds.contains(id) {
            logWatchers[id]?.stopWatching()
            logWatchers.removeValue(forKey: id)
        }
        for id in directoryWatchers.keys where !enabledProfileIds.contains(id) {
            directoryWatchers[id]?.stop()
            directoryWatchers.removeValue(forKey: id)
        }

        // Add watchers only for profiles that don't already have them
        for profile in profileStore.enabledProfiles {
            if logWatchers[profile.id] == nil {
                startWatching(profile: profile)
            }
            // Skip directory watching for mount mode profiles (no need to watch - files stream on-demand)
            if directoryWatchers[profile.id] == nil && !profile.isMountMode {
                startWatchingDirectory(for: profile)
            }
        }
    }

    private func startWatching(profile: SyncProfile) {
        let watcher = LogWatcher(logPath: profile.logPath)
        watcher.profileName = profile.name
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
        // Skip directory watching for mount mode (files stream on-demand, no sync needed)
        guard !profile.isMountMode else { return }

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
        watcher.profileName = profileName
        watcher.start()
        directoryWatchers[profile.id] = watcher
    }

    /// Handle file system changes detected by DirectoryWatcher
    private func handleDirectoryChange(for profileId: UUID) {
        // Skip if profile is paused
        if isPaused(for: profileId) {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - profile paused")
            return
        }

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

        TelemetryService.shared.recordDirectoryWatchTrigger(
            profileId: profileId,
            profileName: profile.name
        )

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
            // Don't override state for profiles that are currently syncing
            if profileStates[profile.id] == .syncing {
                continue
            }

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

        // Priority: error > syncing > driveNotMounted > paused > idle
        var hasError = false
        var hasSyncing = false
        var hasDriveNotMounted = false
        var hasPaused = false
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
            case .paused:
                hasPaused = true
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
        } else if hasPaused && isAllPaused {
            // Only show paused aggregate state if ALL profiles are paused
            currentState = .paused
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

        var affectedCount = 0
        for profile in profileStore.enabledProfiles {
            let drivePath = profile.drivePathToMonitor
            guard !drivePath.isEmpty else { continue }

            if drivePath.hasPrefix(volumePath) || volumePath == drivePath {
                affectedCount += 1
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

        if affectedCount > 0 {
            TelemetryService.shared.recordVolumeEvent(event: "mounted", affectedProfiles: affectedCount)
        }

        updateAggregateState()
    }

    private func handleVolumeUnmount(_ notification: Notification) {
        guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else {
            return
        }

        var affectedCount = 0
        for profile in profileStore.enabledProfiles {
            let drivePath = profile.drivePathToMonitor
            guard !drivePath.isEmpty else { continue }

            if drivePath.hasPrefix(volumePath) || volumePath == drivePath {
                affectedCount += 1
                profileStates[profile.id] = .driveNotMounted
                if !isNotificationsMuted(for: profile.id) {
                    notificationService.notifyDriveNotMounted(profileId: profile.id, profileName: profile.name)
                }
            }
        }

        if affectedCount > 0 {
            TelemetryService.shared.recordVolumeEvent(event: "unmounted", affectedProfiles: affectedCount)
        }

        updateAggregateState()
    }

    private func runSyncScript(for profile: SyncProfile) async {
        // Check if profile is paused
        if isPaused(for: profile.id) {
            SyncTraySettings.debugLog("Skipping sync script for paused profile: \(profile.name)")
            return
        }

        // Check if drive is mounted
        if !profile.drivePathToMonitor.isEmpty &&
           !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
            await MainActor.run {
                profileStates[profile.id] = .driveNotMounted
                if !isNotificationsMuted(for: profile.id) {
                    notificationService.notifyDriveNotMounted(profileId: profile.id, profileName: profile.name)
                }
                updateAggregateState()
            }
            return
        }

        guard FileManager.default.fileExists(atPath: SyncProfile.sharedScriptPath) else {
            await MainActor.run {
                profileStates[profile.id] = .error("Script not found")
                TelemetryService.shared.recordSyncPreconditionFailure(
                    profileId: profile.id,
                    profileName: profile.name,
                    reason: "script_not_found"
                )
                updateAggregateState()
            }
            return
        }

        guard FileManager.default.fileExists(atPath: profile.configPath) else {
            await MainActor.run {
                profileStates[profile.id] = .error("Config not found")
                TelemetryService.shared.recordSyncPreconditionFailure(
                    profileId: profile.id,
                    profileName: profile.name,
                    reason: "config_not_found"
                )
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
            profileProgress[profileId] = nil  // Reset progress for new sync
            currentSyncChanges[profileId] = []
            syncStartTimes[profileId] = Date()  // Record start time for duration tracking
            checkPhaseStartTimes.removeValue(forKey: profileId)  // Reset check phase tracking
            checkPhaseReported.remove(profileId)
            logWatchers[profileId]?.setActivelySyncing(true)  // Increase polling frequency
            // Don't send notification - the menu bar icon updates to show syncing state
            notificationService.clearPendingChanges(for: profileId)
            TelemetryService.shared.recordSyncStarted(
                profileId: profileId,
                profileName: profileName,
                syncMode: profile?.syncMode ?? .bisync,
                syncDirection: profile?.syncDirection,
                hasFallback: profile?.hasFallback ?? false
            )

        case .syncCompleted:
            profileStates[profileId] = .idle
            profileErrors[profileId] = nil  // Clear error on success
            lastSeenErrorMessage[profileId] = nil
            profileProgress[profileId] = nil  // Clear progress when sync completes
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            lastSyncTime = event.timestamp
            // Successful sync clears backoff suppression and in-flight state for this profile
            autoFixSuppressed.remove(profileId)
            autoFixAttempts[profileId] = nil
            autoFixInFlight.remove(profileId)
            let changesCount = currentSyncChanges[profileId]?.count ?? 0
            // Report telemetry for successful sync
            let completedDuration = syncStartTimes[profileId].map { Date().timeIntervalSince($0) } ?? 0
            syncStartTimes[profileId] = nil
            TelemetryService.shared.recordSyncCompleted(
                profileId: profileId,
                profileName: profileName,
                mode: profile?.syncMode ?? .bisync,
                duration: completedDuration,
                filesChanged: changesCount
            )
            if !isNotificationsMuted(for: profileId) {
                notificationService.notifySyncCompleted(
                    changesCount: changesCount,
                    profileId: profileId,
                    profileName: profileName,
                    syncDirectoryPath: syncDirectoryPath
                )
            } else {
                // Still clean up pending state even when muted
                notificationService.clearPendingChanges(for: profileId)
            }
            currentSyncChanges[profileId] = nil

        case .syncFailed(let exitCode, let message):
            // Check if the error message (or the last seen error) is a transient one
            let errorToCheck = message ?? lastSeenErrorMessage[profileId]
            if let msg = errorToCheck, SyncLogPatterns.isTransientAllFilesChangedError(msg) {
                // Transient "all files were changed" - just clear state, don't show error
                profileProgress[profileId] = nil
                lastSeenErrorMessage[profileId] = nil
                syncStartTimes[profileId] = nil
                logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
                currentSyncChanges[profileId] = nil  // Only clear this profile's changes
                // Reset to idle since this isn't a real error
                profileStates[profileId] = .idle
                break
            }

            profileStates[profileId] = .error("Exit code \(exitCode)")
            profileProgress[profileId] = nil  // Clear progress on failure
            lastSeenErrorMessage[profileId] = nil
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            // Report telemetry for failed sync
            let failedDuration = syncStartTimes[profileId].map { Date().timeIntervalSince($0) } ?? 0
            syncStartTimes[profileId] = nil
            TelemetryService.shared.recordSyncFailed(
                profileId: profileId,
                profileName: profileName,
                mode: profile?.syncMode ?? .bisync,
                duration: failedDuration,
                filesChanged: currentSyncChanges[profileId]?.count ?? 0,
                exitCode: exitCode,
                errorMessage: message ?? profileErrors[profileId]
            )
            // Only use the syncFailed message if we don't already have a more specific error
            if profileErrors[profileId] == nil, let msg = message {
                profileErrors[profileId] = msg
            }
            let errorDescription = profileErrors[profileId] ?? message ?? "Exit code \(exitCode)"
            if !isNotificationsMuted(for: profileId) {
                notificationService.notifySyncError(
                    "Sync failed: \(errorDescription)",
                    profileId: profileId,
                    profileName: profile?.name
                )
            }
            currentSyncChanges[profileId] = nil

            // Clear in-flight sentinel so the backoff state can accept the next attempt.
            // The backoff counter (autoFixAttempts) and suppression (autoFixSuppressed) still
            // apply — this only unblocks the in-flight guard.
            autoFixInFlight.remove(profileId)

            // Auto-fix: if the stored error is an out-of-sync error and the setting is on,
            // trigger an automatic --resync recovery.
            if let storedError = profileErrors[profileId],
               SyncLogPatterns.isOutOfSyncError(storedError),
               let currentProfile = profile {
                triggerAutoFix(for: currentProfile)
            }

        case .transportChanged(let transport):
            profileTransports[profileId] = transport
            TelemetryService.shared.recordTransportChange(
                profileId: profileId,
                profileName: profileName,
                transport: transport.isPrimary ? "primary" : "fallback"
            )

        case .errorMessage(let message):
            // Track all error messages so we can correlate with syncFailed events
            lastSeenErrorMessage[profileId] = message

            // Transient "all files were changed" error should not be stored as a displayed error
            if SyncLogPatterns.isTransientAllFilesChangedError(message) {
                break
            }

            TelemetryService.shared.recordSyncError(
                profileId: profileId,
                profileName: profileName,
                errorMessage: message
            )

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
            let previousState = profileStates[profileId]
            profileStates[profileId] = .driveNotMounted
            // Only emit telemetry/notification on state transition, not every poll
            if previousState != .driveNotMounted {
                TelemetryService.shared.recordDriveNotMounted(
                    profileId: profileId,
                    profileName: profileName
                )
                if !isNotificationsMuted(for: profileId) {
                    notificationService.notifyDriveNotMounted(profileId: profileId, profileName: profileName)
                }
            }

        case .syncSkipped(let reason):
            // A scheduled run exited early without syncing (remote failed the
            // pre-flight reachability check). "Starting bisync" already set the
            // profile to `.syncing` and opened a telemetry span; close both here
            // so the profile returns to rest instead of appearing to sync for
            // 11–37 min until the next run abandons the stale span.
            logWatchers[profileId]?.setActivelySyncing(false)
            profileProgress[profileId] = nil
            syncStartTimes[profileId] = nil
            checkPhaseStartTimes.removeValue(forKey: profileId)
            checkPhaseReported.remove(profileId)
            // Only downgrade from `.syncing`; never clobber a real error,
            // paused, or driveNotMounted state.
            if profileStates[profileId] == .syncing {
                profileStates[profileId] = .idle
            }
            TelemetryService.shared.recordSyncSkipped(
                profileId: profileId,
                profileName: profileName,
                reason: reason
            )

        case .syncAlreadyRunning:
            TelemetryService.shared.recordSyncContention(
                profileId: profileId,
                profileName: profileName
            )

        case .fileChange(var change):
            change.profileName = profileName
            if currentSyncChanges[profileId] == nil {
                currentSyncChanges[profileId] = []
            }
            currentSyncChanges[profileId]?.append(change)
            addRecentChange(change)
            TelemetryService.shared.recordFileOperation(
                profileName: profileName,
                operation: change.operation.rawValue,
                filePath: change.path
            )
            // Only send notification if not muted
            if !isNotificationsMuted(for: profileId) {
                notificationService.notifyFileChange(change, profileId: profileId, syncDirectoryPath: syncDirectoryPath)
            }

        case .stats(let stats):
            if let bytes = stats.bytes, let totalBytes = stats.totalBytes, totalBytes > 0 {
                let checksDone = stats.checks ?? 0
                let totalChecks = stats.totalChecks ?? 0

                // Track check phase duration (listing/comparison phase in bisync)
                if totalChecks > 0 && checksDone < totalChecks && checkPhaseStartTimes[profileId] == nil {
                    checkPhaseStartTimes[profileId] = Date()
                    checkPhaseReported.remove(profileId)
                }
                if totalChecks > 0 && checksDone >= totalChecks && !checkPhaseReported.contains(profileId),
                   let checkStart = checkPhaseStartTimes[profileId] {
                    let checkDuration = Date().timeIntervalSince(checkStart)
                    TelemetryService.shared.recordCheckPhaseDuration(
                        profileName: profileName,
                        syncMode: profile?.syncMode.rawValue ?? "unknown",
                        durationSeconds: checkDuration,
                        checksCompleted: checksDone,
                        totalChecks: totalChecks
                    )
                    checkPhaseReported.insert(profileId)
                    checkPhaseStartTimes.removeValue(forKey: profileId)
                }

                profileProgress[profileId] = SyncProgress(
                    bytesTransferred: Int64(bytes),
                    totalBytes: Int64(totalBytes),
                    eta: stats.eta,
                    speed: stats.speed,
                    transfersDone: stats.transfers ?? 0,
                    totalTransfers: stats.totalTransfers ?? 0,
                    checksDone: checksDone,
                    totalChecks: totalChecks,
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

    /// Start a 5-minute session heartbeat for availability monitoring
    private func startSessionHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 300, repeating: 300)  // every 5 minutes
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let enabled = self.profileStore.enabledProfiles.count
                let syncing = self.profileStates.values.filter { $0 == .syncing }.count
                let paused = self.pausedProfiles.count
                let errors = self.profileStates.values.filter {
                    if case .error = $0 { return true }; return false
                }.count
                TelemetryService.shared.recordSessionHeartbeat(
                    enabledProfiles: enabled,
                    syncingProfiles: syncing,
                    pausedProfiles: paused,
                    errorProfiles: errors
                )
            }
        }
        heartbeatTimer = timer
        timer.resume()
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

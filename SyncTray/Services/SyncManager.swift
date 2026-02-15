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

    private var logWatcher: LogWatcher?
    private let logParser = LogParser()
    private let notificationService = NotificationService.shared

    private var workspaceObserver: NSObjectProtocol?
    private var currentSyncChanges: [FileChange] = []

    private let maxRecentChanges = 20

    init() {
        setupWorkspaceObserver()
        checkInitialState()
        startWatching()
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    func refreshSettings() {
        startWatching()
        checkInitialState()
    }

    func triggerManualSync() {
        guard !isManualSyncRunning else { return }

        let scriptPath = SyncTraySettings.syncScriptPath
        guard !scriptPath.isEmpty && FileManager.default.fileExists(atPath: scriptPath) else {
            currentState = .error("Sync script not configured")
            return
        }

        let drivePath = SyncTraySettings.drivePathToMonitor
        if !drivePath.isEmpty && !FileManager.default.fileExists(atPath: drivePath) {
            currentState = .driveNotMounted
            notificationService.notifyDriveNotMounted()
            return
        }

        isManualSyncRunning = true

        Task {
            await runSyncScript()
            await MainActor.run {
                isManualSyncRunning = false
            }
        }
    }

    func openLogFile() {
        let logPath = SyncTraySettings.logFilePath
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        }
    }

    func openSyncDirectory() {
        let syncPath = SyncTraySettings.syncDirectoryPath
        if !syncPath.isEmpty && FileManager.default.fileExists(atPath: syncPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: syncPath))
        }
    }

    func openFileInFinder(_ change: FileChange) {
        let syncDir = SyncTraySettings.syncDirectoryPath
        guard !syncDir.isEmpty else { return }

        let fullPath = (syncDir as NSString).appendingPathComponent(change.path)
        let url = URL(fileURLWithPath: fullPath)

        if FileManager.default.fileExists(atPath: fullPath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // File might have been deleted, open parent directory
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

    // MARK: - Private Methods

    private func startWatching() {
        logWatcher?.stopWatching()
        logWatcher = LogWatcher(logPath: SyncTraySettings.logFilePath)
        logWatcher?.delegate = self
        logWatcher?.startWatching()
    }

    private func checkInitialState() {
        let logPath = SyncTraySettings.logFilePath
        if logPath.isEmpty {
            currentState = .notConfigured
            return
        }

        let drivePath = SyncTraySettings.drivePathToMonitor
        if !drivePath.isEmpty && !FileManager.default.fileExists(atPath: drivePath) {
            currentState = .driveNotMounted
            return
        }

        currentState = .idle
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
        let drivePath = SyncTraySettings.drivePathToMonitor
        guard !drivePath.isEmpty else { return }

        guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path,
              drivePath.hasPrefix(volumePath) || volumePath == drivePath else {
            return
        }

        notificationService.resetDriveNotMountedState()
        if currentState == .driveNotMounted {
            currentState = .idle
        }
    }

    private func handleVolumeUnmount(_ notification: Notification) {
        let drivePath = SyncTraySettings.drivePathToMonitor
        guard !drivePath.isEmpty else { return }

        guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path,
              drivePath.hasPrefix(volumePath) || volumePath == drivePath else {
            return
        }

        currentState = .driveNotMounted
        notificationService.notifyDriveNotMounted()
    }

    private func runSyncScript() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [SyncTraySettings.syncScriptPath]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Failed to run sync script: \(error)")
        }
    }

    private func processLogEvent(_ event: ParsedLogEvent) {
        switch event.type {
        case .syncStarted:
            currentState = .syncing
            currentSyncChanges.removeAll()
            notificationService.notifySyncStarted()

        case .syncCompleted:
            currentState = .idle
            lastSyncTime = event.timestamp
            notificationService.notifySyncCompleted(changesCount: currentSyncChanges.count)
            currentSyncChanges.removeAll()

        case .syncFailed(let exitCode):
            currentState = .error("Exit code \(exitCode)")
            notificationService.notifySyncError("Sync failed with exit code \(exitCode)")
            currentSyncChanges.removeAll()

        case .driveNotMounted:
            currentState = .driveNotMounted
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
    }

    private func addRecentChange(_ change: FileChange) {
        recentChanges.insert(change, at: 0)
        if recentChanges.count > maxRecentChanges {
            recentChanges = Array(recentChanges.prefix(maxRecentChanges))
        }
    }
}

// MARK: - LogWatcherDelegate

extension SyncManager: LogWatcherDelegate {
    nonisolated func logWatcher(_ watcher: LogWatcher, didReceiveNewLines lines: [String]) {
        Task { @MainActor in
            for line in lines {
                if let event = logParser.parse(line: line) {
                    processLogEvent(event)
                }
            }
        }
    }
}

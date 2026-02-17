import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()

    /// Per-profile pending file changes (keyed by profile ID)
    private var pendingFileChanges: [UUID: [FileChange]] = [:]
    /// Per-profile batch timers (keyed by profile ID)
    private var batchTimers: [UUID: Timer] = [:]
    private let batchDelay: TimeInterval = 2.0

    /// Per-profile "drive not mounted" notification state (keyed by profile ID)
    private var hasNotifiedDriveNotMounted: [UUID: Bool] = [:]

    private let categoryIdentifier = "SYNC_NOTIFICATION"
    private let openDirectoryActionIdentifier = "OPEN_DIRECTORY"
    private let muteActionIdentifier = "MUTE_CURRENT_SYNC"

    /// Per-profile sync directory paths (keyed by profile ID)
    private var syncDirectoryPaths: [UUID: String] = [:]

    private init() {
        setupNotificationCategories()
    }

    private func setupNotificationCategories() {
        let openDirectoryAction = UNNotificationAction(
            identifier: openDirectoryActionIdentifier,
            title: "Open Directory",
            options: [.foreground]
        )

        let muteAction = UNNotificationAction(
            identifier: muteActionIdentifier,
            title: "Mute Current Sync",
            options: []  // No .foreground - runs in background
        )

        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [openDirectoryAction, muteAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func notifySyncStarted(profileId: UUID, profileName: String) {
        // Clear only this profile's pending changes
        pendingFileChanges[profileId] = nil
        batchTimers[profileId]?.invalidate()
        batchTimers[profileId] = nil

        sendNotification(
            title: "SyncTray: \(profileName)",
            body: "Sync started...",
            sound: nil,
            profileId: profileId
        )
    }

    func notifyFileChange(_ change: FileChange, profileId: UUID, syncDirectoryPath: String) {
        // Store sync directory path for this profile
        syncDirectoryPaths[profileId] = syncDirectoryPath

        // Append to this profile's pending changes
        if pendingFileChanges[profileId] == nil {
            pendingFileChanges[profileId] = []
        }
        pendingFileChanges[profileId]?.append(change)

        // Invalidate and create a new timer for this profile
        batchTimers[profileId]?.invalidate()
        batchTimers[profileId] = Timer.scheduledTimer(withTimeInterval: batchDelay, repeats: false) { [weak self, profileId] _ in
            self?.sendBatchedFileNotification(for: profileId)
        }
    }

    func notifySyncCompleted(changesCount: Int, profileId: UUID, profileName: String, syncDirectoryPath: String) {
        // Store sync directory path for this profile
        syncDirectoryPaths[profileId] = syncDirectoryPath

        // Invalidate this profile's timer
        batchTimers[profileId]?.invalidate()
        batchTimers[profileId] = nil

        if let changes = pendingFileChanges[profileId], !changes.isEmpty {
            sendBatchedFileNotification(for: profileId, profileName: profileName)
        } else if changesCount == 0 {
            return
        }

        // Clean up this profile's state
        pendingFileChanges[profileId] = nil
        syncDirectoryPaths[profileId] = nil
    }

    private func sendBatchedFileNotification(for profileId: UUID, profileName: String? = nil) {
        guard let changes = pendingFileChanges[profileId], !changes.isEmpty else { return }

        // Clear this profile's pending changes
        pendingFileChanges[profileId] = nil

        let title = profileName != nil ? "SyncTray: \(profileName!)" : "SyncTray"
        let body: String

        if changes.count <= 3 {
            let fileNames = changes.map { change in
                "\(change.operation.rawValue): \(change.fileName)"
            }
            body = fileNames.joined(separator: "\n")
        } else {
            body = "\(changes.count) files synced"
        }

        // Get directory from first change for "Open Directory" action
        let directoryPath: String?
        if let firstChange = changes.first {
            let syncDir = syncDirectoryPaths[profileId] ?? ""
            if !syncDir.isEmpty {
                directoryPath = (syncDir as NSString).appendingPathComponent(firstChange.directory)
            } else {
                directoryPath = nil
            }
        } else {
            directoryPath = nil
        }

        sendNotification(
            title: title,
            body: body,
            sound: .default,
            directoryPath: directoryPath,
            profileId: profileId
        )
    }

    func notifySyncError(_ message: String, profileId: UUID? = nil, profileName: String? = nil) {
        let title = profileName != nil ? "SyncTray: \(profileName!)" : "SyncTray Error"
        sendNotification(
            title: title,
            body: message,
            sound: .defaultCritical,
            isCritical: true,
            profileId: profileId
        )
    }

    func notifyDriveNotMounted(profileId: UUID, profileName: String) {
        guard hasNotifiedDriveNotMounted[profileId] != true else { return }
        hasNotifiedDriveNotMounted[profileId] = true

        sendNotification(
            title: "SyncTray: \(profileName)",
            body: "External drive not mounted. Sync paused.",
            sound: nil,
            profileId: profileId
        )
    }

    /// Reset the "drive not mounted" notification state for a specific profile or all profiles
    func resetDriveNotMountedState(for profileId: UUID? = nil) {
        if let profileId = profileId {
            hasNotifiedDriveNotMounted[profileId] = nil
        } else {
            hasNotifiedDriveNotMounted.removeAll()
        }
    }

    private func sendNotification(
        title: String,
        body: String,
        sound: UNNotificationSound?,
        isCritical: Bool = false,
        directoryPath: String? = nil,
        profileId: UUID? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryIdentifier

        if let sound = sound {
            content.sound = sound
        }

        if isCritical {
            content.interruptionLevel = .critical
        }

        // Add directory path for "Open Directory" action
        if let path = directoryPath {
            content.userInfo["directoryPath"] = path
        } else if let profileId = profileId, let syncDir = syncDirectoryPaths[profileId], !syncDir.isEmpty {
            content.userInfo["directoryPath"] = syncDir
        }

        // Add profile ID to open specific profile in Settings
        if let profileId = profileId {
            content.userInfo["profileId"] = profileId.uuidString
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send notification: \(error)")
            }
        }
    }
}

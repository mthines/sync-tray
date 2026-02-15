import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()

    private var pendingFileChanges: [FileChange] = []
    private var batchTimer: Timer?
    private let batchDelay: TimeInterval = 2.0

    private var hasNotifiedDriveNotMounted = false

    private let categoryIdentifier = "SYNC_NOTIFICATION"
    private let openDirectoryActionIdentifier = "OPEN_DIRECTORY"

    /// Current sync directory path, set by SyncManager when processing changes
    var currentSyncDirectoryPath: String = ""

    private init() {
        setupNotificationCategories()
    }

    private func setupNotificationCategories() {
        let openDirectoryAction = UNNotificationAction(
            identifier: openDirectoryActionIdentifier,
            title: "Open Directory",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [openDirectoryAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func notifySyncStarted() {
        pendingFileChanges.removeAll()
        batchTimer?.invalidate()

        sendNotification(
            title: "SyncTray",
            body: "Sync started...",
            sound: nil
        )
    }

    func notifyFileChange(_ change: FileChange) {
        pendingFileChanges.append(change)

        batchTimer?.invalidate()
        batchTimer = Timer.scheduledTimer(withTimeInterval: batchDelay, repeats: false) { [weak self] _ in
            self?.sendBatchedFileNotification()
        }
    }

    func notifySyncCompleted(changesCount: Int) {
        batchTimer?.invalidate()

        if !pendingFileChanges.isEmpty {
            sendBatchedFileNotification()
        } else if changesCount == 0 {
            return
        }
    }

    private func sendBatchedFileNotification() {
        guard !pendingFileChanges.isEmpty else { return }

        let changes = pendingFileChanges
        pendingFileChanges.removeAll()

        let title = "SyncTray"
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
            let syncDir = currentSyncDirectoryPath
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
            directoryPath: directoryPath
        )
    }

    func notifySyncError(_ message: String) {
        sendNotification(
            title: "SyncTray Error",
            body: message,
            sound: .defaultCritical,
            isCritical: true
        )
    }

    func notifyDriveNotMounted() {
        guard !hasNotifiedDriveNotMounted else { return }
        hasNotifiedDriveNotMounted = true

        sendNotification(
            title: "SyncTray",
            body: "External drive not mounted. Sync paused.",
            sound: nil
        )
    }

    func resetDriveNotMountedState() {
        hasNotifiedDriveNotMounted = false
    }

    private func sendNotification(
        title: String,
        body: String,
        sound: UNNotificationSound?,
        isCritical: Bool = false,
        directoryPath: String? = nil
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
        } else if !currentSyncDirectoryPath.isEmpty {
            content.userInfo["directoryPath"] = currentSyncDirectoryPath
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

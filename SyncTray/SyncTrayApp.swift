import SwiftUI
import UserNotifications

@main
struct SyncTrayApp: App {
    @StateObject private var syncManager: SyncManager

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Perform migration if needed
        Self.performMigrationIfNeeded()

        // Create the sync manager
        let manager = SyncManager()
        _syncManager = StateObject(wrappedValue: manager)

        // Share with AppDelegate for window creation
        AppDelegate.sharedSyncManager = manager
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(syncManager)
        } label: {
            MenuBarIcon(state: syncManager.currentState)
        }
        .menuBarExtraStyle(.window)
    }

    /// Migrate from single-profile to multi-profile if needed
    private static func performMigrationIfNeeded() {
        guard SyncTraySettings.needsMultiProfileMigration else { return }

        // Create a temporary profile store to perform migration
        let profileStore = ProfileStore()

        // Create a profile from legacy settings
        if let profile = SyncTraySettings.createProfileFromLegacySettings() {
            profileStore.add(profile)

            // Try to uninstall legacy launchd agent
            let setupService = SyncSetupService.shared
            if setupService.isLegacyInstalled() {
                try? setupService.uninstallLegacy()
            }

            // Install the new profile
            do {
                try setupService.install(profile: profile)
            } catch {
                print("Failed to install migrated profile: \(error)")
            }
        }

        // Mark migration as complete
        SyncTraySettings.markMigrationComplete()

        // Optionally clear legacy settings
        // SyncTraySettings.clearLegacySettings()
    }
}

struct MenuBarIcon: View {
    let state: SyncState

    var body: some View {
        Image(systemName: state.iconName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(state.iconColor)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Shared instance for easy access
    static var shared: AppDelegate?

    /// Profile ID to select when Settings window opens (set from notification tap)
    static var pendingProfileSelection: UUID?

    /// Flag to open settings on first view appearance
    static var shouldOpenSettingsOnLaunch = true

    /// Shared sync manager (set by SyncTrayApp)
    static var sharedSyncManager: SyncManager?

    /// The settings window
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Store shared instance
        AppDelegate.shared = self
        // Check if another instance is already running
        let runningApps = NSWorkspace.shared.runningApplications
        let myBundleId = Bundle.main.bundleIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier

        let otherInstances = runningApps.filter { app in
            app.bundleIdentifier == myBundleId && app.processIdentifier != myPID
        }

        if !otherInstances.isEmpty {
            // Another instance is running, activate it and quit this one
            otherInstances.first?.activate()
            NSApp.terminate(nil)
            return
        }

        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermissions()

        // Open Settings window on launch
        if AppDelegate.shouldOpenSettingsOnLaunch {
            AppDelegate.shouldOpenSettingsOnLaunch = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openSettingsWindow()
            }
        }
    }

    func openSettingsWindow() {
        print("[SyncTray] openSettingsWindow called, shared=\(AppDelegate.shared != nil), manager=\(AppDelegate.sharedSyncManager != nil)")

        // Activate app first
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        // If window already exists, just show it
        if let window = settingsWindow {
            print("[SyncTray] Showing existing window")
            window.makeKeyAndOrderFront(nil)
            // Ensure app is frontmost
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        // Create the settings window with SwiftUI content
        guard let syncManager = AppDelegate.sharedSyncManager else {
            print("[SyncTray] ERROR: sharedSyncManager is nil!")
            return
        }
        print("[SyncTray] Creating new settings window")

        let settingsView = SettingsView()
            .environmentObject(syncManager)

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "SyncTray Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 650))
        window.minSize = NSSize(width: 600, height: 500)
        window.center()
        window.isReleasedWhenClosed = false

        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        // Ensure app is frontmost
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        print("[SyncTray] Window created and shown")
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    // Handle notification actions
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        // Check if this notification has a profile ID (error notification)
        if let profileIdString = userInfo["profileId"] as? String,
           let profileId = UUID(uuidString: profileIdString) {
            // Store the profile ID and open Settings
            AppDelegate.pendingProfileSelection = profileId

            // Open Settings window first, then post notification to select profile
            DispatchQueue.main.async {
                self.openSettingsWindow()

                // Post notification after a short delay to ensure Settings window is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NotificationCenter.default.post(
                        name: .selectProfile,
                        object: nil,
                        userInfo: ["profileId": profileId]
                    )
                }
            }
        } else if response.actionIdentifier == "OPEN_DIRECTORY" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // Open directory action
            if let urlString = userInfo["directoryPath"] as? String {
                let url = URL(fileURLWithPath: urlString)
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

extension Notification.Name {
    static let selectProfile = Notification.Name("selectProfile")
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
}

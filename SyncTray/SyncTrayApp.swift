import SwiftUI
import UserNotifications

@main
struct SyncTrayApp: App {
    @StateObject private var syncManager = SyncManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(syncManager)
        } label: {
            MenuBarIcon(state: syncManager.currentState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(syncManager)
        }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermissions()
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
        if response.actionIdentifier == "OPEN_DIRECTORY" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            if let urlString = response.notification.request.content.userInfo["directoryPath"] as? String {
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

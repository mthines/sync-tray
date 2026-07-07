import SwiftUI
import UserNotifications

@main
struct SyncTrayApp: App {
    @StateObject private var syncManager: SyncManager

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Run any pending data migrations before loading profiles
        MigrationRunner.runPendingMigrations()

        // Initialize telemetry (no-op if disabled)
        TelemetryService.shared.configure()

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
            MenuBarIcon(
                state: syncManager.currentState,
                progress: syncManager.syncProgress?.percentage
            )
        }
        .menuBarExtraStyle(.window)
    }

}

struct MenuBarIcon: View {
    let state: SyncState
    let progress: Double?  // 0-100, nil when not syncing

    var body: some View {
        switch state {
        case .syncing:
            CircularProgressIcon(percentage: progress ?? 0, color: .systemBlue)
        case .idle:
            CircularProgressIcon(percentage: 100, color: .gray)
        default:
            Image(systemName: state.iconName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(state.iconColor)
        }
    }
}

struct CircularProgressIcon: View {
    let percentage: Double  // 0-100
    let color: NSColor      // Progress arc color

    var body: some View {
        Image(nsImage: createProgressImage(percentage: percentage, color: color))
    }

    private func createProgressImage(percentage: Double, color: NSColor) -> NSImage {
        let size: CGFloat = 14
        let lineWidth: CGFloat = 2
        let imageSize = NSSize(width: size, height: size)

        let image = NSImage(size: imageSize, flipped: false) { rect in
            let inset = lineWidth / 2
            let circleRect = rect.insetBy(dx: inset, dy: inset)

            // Background circle (gray)
            let backgroundPath = NSBezierPath(ovalIn: circleRect)
            NSColor.gray.withAlphaComponent(0.4).setStroke()
            backgroundPath.lineWidth = lineWidth
            backgroundPath.stroke()

            // Progress arc (clockwise from top)
            if percentage > 0 {
                let center = NSPoint(x: rect.midX, y: rect.midY)
                let radius = (min(rect.width, rect.height) - lineWidth) / 2
                let startAngle: CGFloat = 90  // Top (in AppKit coordinates)
                let endAngle = 90 - (percentage / 100 * 360)

                let progressPath = NSBezierPath()
                progressPath.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: true
                )
                progressPath.lineWidth = lineWidth
                progressPath.lineCapStyle = .round
                color.setStroke()
                progressPath.stroke()
            }

            return true
        }
        image.isTemplate = false  // Keep colors (don't use template rendering)
        return image
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
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

        // Make the Finder extension "just work" after an install/upgrade — no manual
        // Finder restart required.
        refreshFinderSyncExtensionIfNeeded()

        // Record app launch telemetry
        TelemetryService.shared.recordAppLaunch()

        // Open Settings window on launch
        if AppDelegate.shouldOpenSettingsOnLaunch {
            AppDelegate.shouldOpenSettingsOnLaunch = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openSettingsWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminateFinderSyncExtension()
        TelemetryService.shared.shutdown()
    }

    /// Terminate the FinderSync extension process when SyncTray quits.
    ///
    /// Finder — not SyncTray — owns the extension's lifecycle, so it otherwise keeps
    /// running after we quit and, after an app update (e.g. a `brew upgrade`), can keep
    /// serving *stale* code from the pre-update process until Finder is relaunched. That
    /// was the "old process" that made the right-click menu / icons look wrong. Killing it
    /// on quit matches the user's expectation ("quitting SyncTray closes the SyncTray
    /// Offline extension too") and guarantees Finder spawns a fresh copy from the current
    /// bundle next time it's needed. Safe: Finder relaunches the extension on demand, and
    /// it rebuilds its state from the shared App Group data on launch.
    private func terminateFinderSyncExtension() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // -x: match the exact process name (the extension's executable).
        proc.arguments = ["-x", "SyncTrayFinderSync"]
        try? proc.run()
        proc.waitUntilExit()
    }

    /// The FinderSync extension's bundle id. Debug builds use a `.dev` suffix so a dev
    /// build never collides with an installed release (see Config/Signing.xcconfig).
    private var finderExtensionBundleID: String {
        #if DEBUG
        return "com.synctray.app.dev.findersync"
        #else
        return "com.synctray.app.findersync"
        #endif
    }

    /// Make the Finder extension "just work" after an install or upgrade — without the
    /// user manually restarting Finder.
    ///
    /// Finder (not SyncTray) owns the extension and does NOT reload the plug-in when the
    /// app bundle is replaced (e.g. by `brew upgrade`); it keeps serving the old binary
    /// until it relaunches. So on launch we:
    ///   1. (Re)register the embedded appex with LaunchServices/pluginkit (idempotent).
    ///   2. If the app version changed since we last did this AND the extension is
    ///      enabled, relaunch Finder so it loads the new binary. Gating on *enabled*
    ///      means users who don't use Stream mode never see a Finder relaunch; gating on
    ///      *version changed* means it happens at most once per upgrade, never on a
    ///      normal launch.
    ///
    /// The first-ever enable still needs one-time user approval in System Settings (a
    /// macOS security gate no app can silently bypass); the in-app card guides that.
    private func refreshFinderSyncExtensionIfNeeded() {
        guard let appexURL = Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("SyncTrayFinderSync.appex"),
              FileManager.default.fileExists(atPath: appexURL.path) else { return }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let versionChanged = SyncTraySettings.finderSetupVersion != currentVersion
        let bundleID = finderExtensionBundleID

        DispatchQueue.global(qos: .utility).async {
            // Keep the registration pointed at the current bundle (idempotent).
            Self.runProcess("/usr/bin/pluginkit", ["-a", appexURL.path])

            guard versionChanged else { return }

            // Only relaunch Finder if the extension is actually enabled ("+") — otherwise
            // there's nothing loaded to refresh and we'd flicker Finder for no reason.
            let status = Self.runProcess("/usr/bin/pluginkit", ["-m", "-i", bundleID])
            if status.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+") {
                Self.runProcess("/usr/bin/killall", ["Finder"])
            }
        }

        // Record immediately so a transient failure doesn't relaunch Finder every launch;
        // the refresh is a best-effort, once-per-version action.
        SyncTraySettings.finderSetupVersion = currentVersion
    }

    /// Run a command and return its stdout (empty string on failure). Background-thread only.
    @discardableResult
    private static func runProcess(_ launchPath: String, _ arguments: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        } catch {
            return ""
        }
    }

    /// Called when the user clicks the Dock icon. While Settings is open the app is in
    /// `.regular` activation policy and shows in the Dock; clicking that icon should
    /// reopen / unminimize the Settings window, not be a no-op.
    ///
    /// - `flag` is `false` when there are no visible windows (closed or miniaturized).
    ///   `makeKeyAndOrderFront` inside `openSettingsWindow` deminiaturizes if needed.
    /// - When `flag` is `true` we return `true` and let AppKit bring the app forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openSettingsWindow()
        }
        return true
    }

    func openSettingsWindow() {
        SyncTraySettings.debugLog("[SyncTray] openSettingsWindow called, shared=\(AppDelegate.shared != nil), manager=\(AppDelegate.sharedSyncManager != nil)")

        TelemetryService.shared.recordSettingsOpened()

        // Switch to regular activation policy so the window appears in cmd+tab and the Dock.
        // This is reverted to .accessory when the settings window closes (see windowWillClose).
        NSApp.setActivationPolicy(.regular)

        // Activate app first
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        // If window already exists, just show it
        if let window = settingsWindow {
            SyncTraySettings.debugLog("[SyncTray] Showing existing window")
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Create the settings window with SwiftUI content
        guard let syncManager = AppDelegate.sharedSyncManager else {
            print("[SyncTray] ERROR: sharedSyncManager is nil!")
            return
        }
        SyncTraySettings.debugLog("[SyncTray] Creating new settings window")

        let settingsView = SettingsView()
            .environmentObject(syncManager)

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "SyncTray Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 650))
        window.minSize = NSSize(width: 600, height: 500)
        window.center()
        // isReleasedWhenClosed = false keeps the NSWindow object alive after the user
        // closes it so we can re-show it via makeKeyAndOrderFront without recreating it.
        // The delegate is set once here and remains valid for the lifetime of the window
        // because the same NSWindow instance is reused on every subsequent open.
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        SyncTraySettings.debugLog("[SyncTray] Window created and shown")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Guard: only react to the settings window closing. If AppDelegate is ever set
        // as the delegate for a second window (e.g. an About panel), that window closing
        // must not revert the activation policy while Settings is still open.
        guard notification.object as? NSWindow === settingsWindow else { return }

        // Revert to accessory (menu-bar-only) policy once the settings window closes,
        // so the app disappears from cmd+tab and the Dock when there is no window open.
        //
        // We dispatch asynchronously to let the window finish closing first — calling
        // setActivationPolicy synchronously inside windowWillClose can confuse AppKit
        // and leave a phantom Dock tile behind on some macOS versions.
        //
        // Race guard: if openSettingsWindow() is called before this async block runs
        // (rapid close-then-reopen), the window will already be visible again. In that
        // case we must NOT revert to .accessory or the app disappears from cmd+tab while
        // its window is on screen. We check isVisible as a proxy for "was reopened".
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.settingsWindow, !window.isVisible else { return }
            NSApp.setActivationPolicy(.accessory)
        }
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

        // Handle mute action
        if response.actionIdentifier == "MUTE_PROFILE" {
            if let profileIdString = userInfo["profileId"] as? String,
               let profileId = UUID(uuidString: profileIdString) {
                DispatchQueue.main.async {
                    AppDelegate.sharedSyncManager?.muteNotifications(for: profileId)
                }
            }
            completionHandler()
            return
        }

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

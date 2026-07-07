import Cocoa
import FinderSync

// MARK: - Cross-target IPC Constants
//
// These string literals are intentionally duplicated in the extension and in
// SyncManager (the host app). The two targets are separate compilation units
// and cannot share a Swift file. Treat them as a cross-target contract:
// if you rename one, rename both.

/// App Group identifier shared between host app and this extension.
private let kAppGroupID = "7HVK85DZG7.group.com.synctray.app"

/// UserDefaults key for the mount-path array written by the host app.
private let kMountPathsKey = "com.synctray.app.mountPaths"

/// UserDefaults key for per-profile data (profileId, pinnedDirectories, vfsCachePath) written by the host app.
private let kProfileDataKey = "com.synctray.app.profileData"

/// Filename of the pending pin/unpin request written by this extension into the App Group container.
private let kPendingPinRequestFile = "pending-pin-request.json"

/// Darwin notification name posted by this extension when a pin/unpin request is pending.
private let kPinRequestNotificationName = "com.synctray.app.pinRequest"

// MARK: - Badge State

/// Cached badge state for a directory path (updated async, read sync by Finder).
enum BadgeState {
    case cloud        // directory not in VFS cache — show icloud badge
    case downloaded   // directory exists in VFS cache — show checkmark.icloud badge
}

// MARK: - FinderSync Extension

@objc(FinderSyncExtension)
class FinderSyncExtension: FIFinderSync {

    // MARK: - State

    /// Cached badge state keyed by canonical directory path string.
    /// Updated asynchronously; read synchronously on the Finder thread (O(1) dict lookup).
    private var badgeStates: [String: BadgeState] = [:]

    /// Currently registered mount paths (read from App Group UserDefaults).
    private var registeredPaths: [String] = []

    /// Profile data loaded from the App Group — maps localSyncPath → {profileId, pinnedDirectories}.
    private var profileData: [String: ProfileEntry] = [:]

    private struct ProfileEntry {
        let profileId: String
        var pinnedDirectories: [String]
        var vfsCachePath: String
    }

    // MARK: - Init / Deinit

    override init() {
        super.init()
        registerBadges()
        loadMountPaths()
        setupDarwinNotificationObserver()
        setupAppearanceObserver()
    }

    deinit {
        // Remove the Darwin notification observer to avoid a dangling-pointer crash.
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(kPinRequestNotificationName as CFString),
            nil
        )
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Appearance Change Observation

    /// Watch for system light/dark switches so already-registered badges get
    /// re-tinted. (Menu icons don't need this — the menu is rebuilt on each
    /// right-click and picks up the current appearance then.)
    private func setupAppearanceObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func appearanceChanged() {
        registerBadges()
    }

    // MARK: - Appearance-Aware Icons

    /// The system-wide dark-mode flag, read from the global domain.
    ///
    /// A Finder extension's own `NSApp.effectiveAppearance` does **not** reliably
    /// track the system light/dark setting — it stays Aqua (light). That makes
    /// template images (`isTemplate = true`) tint their glyph dark even in dark
    /// mode, so menu icons and file badges render black-on-dark (invisible).
    /// `AppleInterfaceStyle` lives in `NSGlobalDomain` and is readable from any
    /// process regardless of its own effective appearance, so it's the reliable
    /// signal here.
    private var systemIsDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    /// An SF Symbol explicitly tinted for the current system appearance —
    /// white in dark mode, near-black in light mode — so it stays visible in
    /// Finder's menus and file badges (which don't honour template tinting from
    /// an extension). Callers must re-request the image when the appearance
    /// changes; the contextual menu is rebuilt per right-click and badges are
    /// re-registered by `appearanceChanged()`.
    private func adaptiveSymbol(_ name: String,
                                accessibilityDescription: String,
                                size: CGFloat = 16) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) ?? NSImage()
        let color: NSColor = systemIsDarkMode ? .white : NSColor(white: 0.15, alpha: 1.0)
        let tinted = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? base
        tinted.size = NSSize(width: size, height: size)
        return tinted
    }

    // MARK: - Badge Registration

    private func registerBadges() {
        let controller = FIFinderSyncController.default()
        controller.setBadgeImage(
            adaptiveSymbol("icloud", accessibilityDescription: "Not cached"),
            label: "Not Available Offline",
            forBadgeIdentifier: "badge-cloud"
        )
        controller.setBadgeImage(
            adaptiveSymbol("checkmark.icloud", accessibilityDescription: "Cached offline"),
            label: "Available Offline",
            forBadgeIdentifier: "badge-downloaded"
        )
    }

    // MARK: - Mount Path Loading

    private func loadMountPaths() {
        guard let defaults = UserDefaults(suiteName: kAppGroupID) else {
            NSLog("[SyncTrayFinderSync] Failed to open App Group UserDefaults — mount paths not loaded")
            return
        }

        let paths = defaults.stringArray(forKey: kMountPathsKey) ?? []
        registeredPaths = paths

        // Load profile entries (profileId + pinnedDirectories + vfsCachePath)
        if let profileDataRaw = defaults.object(forKey: kProfileDataKey) as? [[String: Any]] {
            var newProfileData: [String: ProfileEntry] = [:]
            for raw in profileDataRaw {
                guard let localSyncPath = raw["localSyncPath"] as? String,
                      let profileId = raw["profileId"] as? String else { continue }
                let pinned = raw["pinnedDirectories"] as? [String] ?? []
                let cachePath = raw["vfsCachePath"] as? String ?? ""
                newProfileData[localSyncPath] = ProfileEntry(
                    profileId: profileId,
                    pinnedDirectories: pinned,
                    vfsCachePath: cachePath
                )
            }
            profileData = newProfileData
        }

        // Register directories with Finder
        let urls = paths.map { URL(fileURLWithPath: $0) }
        FIFinderSyncController.default().directoryURLs = Set(urls)

        // Async-update badge states for all registered directories
        updateBadgeStatesAsync()
    }

    // MARK: - Darwin Notification Observer

    private func setupDarwinNotificationObserver() {
        // CFNotificationCenter requires a C-callable callback. Pass `self` via the
        // `observer` UnsafeRawPointer and cast it back inside the callback.
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let ext = Unmanaged<FinderSyncExtension>.fromOpaque(observer).takeUnretainedValue()
                // The C callback is on an arbitrary thread — dispatch to main.
                DispatchQueue.main.async {
                    ext.loadMountPaths()
                }
            },
            kPinRequestNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - Badge State Update (async)

    private func updateBadgeStatesAsync() {
        let snapshotProfileData = profileData
        Task.detached(priority: .background) { [weak self] in
            var newStates: [String: BadgeState] = [:]
            for (localSyncPath, entry) in snapshotProfileData {
                for dir in entry.pinnedDirectories {
                    let canonicalPath = (localSyncPath as NSString).appendingPathComponent(dir)
                    // Determine badge: check if the dir exists in the VFS cache directory.
                    // The VFS cache mirrors the mount at: {vfsCachePath}/vfs/{remoteName}/{remotePath}/{dir}
                    // We use a conservative heuristic: if the cache path exists, it's downloaded.
                    // The extension doesn't know the remote name, so we fall back to checking
                    // whether the directory path under the VFS cache root exists at all.
                    let cacheRoot = entry.vfsCachePath
                    let hasCachePath = !cacheRoot.isEmpty && FileManager.default.fileExists(atPath: cacheRoot)
                    newStates[canonicalPath] = hasCachePath ? .downloaded : .cloud
                }
            }
            // Capture newStates as an immutable copy to avoid the concurrency warning.
            let captured = newStates
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.badgeStates = captured
                // Repaint badges immediately so Finder reflects a just-pinned folder
                // without waiting for it to re-request (which it otherwise only does on
                // navigation/refresh). This is the visible feedback after a pin/unpin.
                for (path, state) in captured {
                    FIFinderSyncController.default().setBadgeIdentifier(
                        state == .downloaded ? "badge-downloaded" : "badge-cloud",
                        for: URL(fileURLWithPath: path)
                    )
                }
            }
        }
    }

    // MARK: - FIFinderSync: Badges

    override func requestBadgeIdentifier(for url: URL) {
        let path = url.path
        // If we don't have a state yet, kick off async update and show cloud badge.
        if badgeStates[path] == nil {
            updateBadgeStatesAsync()
        }
        let state = badgeStates[path] ?? .cloud
        FIFinderSyncController.default().setBadgeIdentifier(
            state == .downloaded ? "badge-downloaded" : "badge-cloud",
            for: url
        )
    }

    // MARK: - FIFinderSync: Contextual Menu

    override var toolbarItemName: String {
        return "SyncTray Offline"
    }

    override var toolbarItemToolTip: String {
        return "Make selected folder available offline via SyncTray"
    }

    override var toolbarItemImage: NSImage {
        return NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "SyncTray Offline") ?? NSImage()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return menu
        }

        guard let selectedItems = FIFinderSyncController.default().selectedItemURLs(),
              !selectedItems.isEmpty else {
            return menu
        }

        // Determine if ALL selected items are pinned (to decide which action to show).
        let allPinned = selectedItems.allSatisfy { url in
            guard let entry = profileEntry(for: url) else { return false }
            let rel = relativePath(url: url, mountPath: entry.0)
            return entry.1.pinnedDirectories.contains(rel)
        }

        // Group our action under a branded "SyncTray ▸" submenu so it doesn't clutter
        // the top-level Finder menu. A single "Available Offline" toggle carries a
        // checkmark when the folder is kept on this Mac — the Google-Drive pattern
        // (checked = offline-ready, unchecked = streams online-only).
        let parentItem = NSMenuItem(title: "SyncTray", action: nil, keyEquivalent: "")
        // Explicitly tinted for the current system appearance — a template image
        // would render dark in dark mode here (see `adaptiveSymbol`).
        parentItem.image = adaptiveSymbol("externaldrive.badge.icloud", accessibilityDescription: "SyncTray")

        let submenu = NSMenu(title: "SyncTray")
        let offlineItem = NSMenuItem(
            title: "Available Offline",
            action: #selector(toggleOfflineSelected(_:)),
            keyEquivalent: ""
        )
        offlineItem.target = self
        offlineItem.state = allPinned ? .on : .off
        submenu.addItem(offlineItem)

        parentItem.submenu = submenu
        menu.addItem(parentItem)

        return menu
    }

    // MARK: - Pin / Unpin Actions

    @objc private func toggleOfflineSelected(_ sender: AnyObject?) {
        // Toggle: if every selected item is already kept offline, unpin; otherwise pin.
        guard let selectedItems = FIFinderSyncController.default().selectedItemURLs(),
              !selectedItems.isEmpty else { return }
        let allPinned = selectedItems.allSatisfy { url in
            guard let entry = profileEntry(for: url) else { return false }
            let rel = relativePath(url: url, mountPath: entry.0)
            return entry.1.pinnedDirectories.contains(rel)
        }
        performPinAction(action: allPinned ? "unpin" : "pin")
    }

    private func performPinAction(action: String) {
        guard let selectedItems = FIFinderSyncController.default().selectedItemURLs(),
              !selectedItems.isEmpty else { return }

        // Group paths by profile
        var requestsByProfile: [String: (mountPath: String, paths: [String])] = [:]
        for url in selectedItems {
            guard let (mountPath, entry) = profileEntry(for: url) else { continue }
            let rel = relativePath(url: url, mountPath: mountPath)
            if requestsByProfile[entry.profileId] == nil {
                requestsByProfile[entry.profileId] = (mountPath: mountPath, paths: [])
            }
            requestsByProfile[entry.profileId]?.paths.append(rel)
        }

        for (profileId, info) in requestsByProfile {
            writePinRequest(action: action, profileId: profileId, paths: info.paths)
        }

        // Post Darwin notification to wake host app
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDistributedCenter(),
            CFNotificationName(kPinRequestNotificationName as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - IPC: Write Pending Pin Request

    private func writePinRequest(action: String, profileId: String, paths: [String]) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: kAppGroupID
        ) else {
            NSLog("[SyncTrayFinderSync] App Group container not accessible — cannot write pin request")
            return
        }

        let requestURL = containerURL.appendingPathComponent(kPendingPinRequestFile)
        let payload: [String: Any] = [
            "action": action,
            "profileId": profileId,
            "paths": paths
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
            try data.write(to: requestURL, options: .atomic)
        } catch {
            NSLog("[SyncTrayFinderSync] Failed to write pin request: \(error)")
        }
    }

    // MARK: - Helpers

    /// Find the profile entry and mount path for a given URL.
    private func profileEntry(for url: URL) -> (String, ProfileEntry)? {
        let path = url.path
        for (mountPath, entry) in profileData {
            if path.hasPrefix(mountPath) {
                return (mountPath, entry)
            }
        }
        return nil
    }

    /// Get the relative path of a URL within a mount path.
    private func relativePath(url: URL, mountPath: String) -> String {
        var rel = url.path
        if rel.hasPrefix(mountPath) {
            rel = String(rel.dropFirst(mountPath.count))
        }
        if rel.hasPrefix("/") {
            rel = String(rel.dropFirst())
        }
        return rel
    }
}

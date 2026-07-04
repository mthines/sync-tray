import Cocoa
import FinderSync

// MARK: - Cross-target IPC Constants
//
// These string literals are intentionally duplicated in the extension and in
// SyncManager (the host app). The two targets are separate compilation units
// and cannot share a Swift file. Treat them as a cross-target contract:
// if you rename one, rename both.

/// App Group identifier shared between host app and this extension.
private let kAppGroupID = "group.com.synctray.app"

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
    }

    deinit {
        // Remove the Darwin notification observer to avoid a dangling-pointer crash.
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(kPinRequestNotificationName as CFString),
            nil
        )
    }

    // MARK: - Badge Registration

    private func registerBadges() {
        let controller = FIFinderSyncController.default()
        controller.setBadgeImage(
            NSImage(systemSymbolName: "icloud", accessibilityDescription: "Not cached") ?? NSImage(),
            label: "Not Available Offline",
            forBadgeIdentifier: "badge-cloud"
        )
        controller.setBadgeImage(
            NSImage(systemSymbolName: "checkmark.icloud", accessibilityDescription: "Cached offline") ?? NSImage(),
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
                self?.badgeStates = captured
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

        if allPinned {
            let item = NSMenuItem(
                title: "Remove from Offline",
                action: #selector(unpinSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(
                title: "Make Available Offline",
                action: #selector(pinSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        return menu
    }

    // MARK: - Pin / Unpin Actions

    @objc private func pinSelected(_ sender: AnyObject?) {
        performPinAction(action: "pin")
    }

    @objc private func unpinSelected(_ sender: AnyObject?) {
        performPinAction(action: "unpin")
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

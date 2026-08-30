import Foundation

/// The install/uninstall work a profile-config delta implies.
enum ProfileReconcileAction: Equatable {
    /// Nothing sync/mount-related changed (e.g. only the display name).
    case none
    /// Was disabled, is now enabled — install the launchd agent.
    case install
    /// Was enabled, is now disabled — uninstall the launchd agent.
    case uninstall
    /// Still enabled, but a field that needs a fresh script/plist/agent changed.
    case reinstall
}

extension SyncManager {
    /// Decide what reconcile work a profile edit requires, given the
    /// previously-installed profile and the new (edited) profile values.
    ///
    /// Pure — no I/O, no side effects. This is the SINGLE source of truth for
    /// "what work does this delta need": both the Save button
    /// (`ProfileDetailView.saveProfile`) and the external-edit watcher
    /// (`SyncManager.applyExternalProfileEdit`) call this so they can never
    /// drift apart (see plan Decisions — a watcher-only copy of this logic
    /// would leave live-edited profiles stale).
    static func reconcileAction(from current: SyncProfile, to updated: SyncProfile) -> ProfileReconcileAction {
        if current.isEnabled != updated.isEnabled {
            return updated.isEnabled ? .install : .uninstall
        }
        guard updated.isEnabled else { return .none }

        let needsReinstall =
            current.rcloneRemote != updated.rcloneRemote ||
            current.remotePath != updated.remotePath ||
            current.localSyncPath != updated.localSyncPath ||
            current.syncIntervalMinutes != updated.syncIntervalMinutes ||
            current.additionalRcloneFlags != updated.additionalRcloneFlags ||
            current.syncMode != updated.syncMode ||
            current.syncDirection != updated.syncDirection ||
            current.fallbackRemote != updated.fallbackRemote ||
            current.fallbackRemotePath != updated.fallbackRemotePath ||
            current.mountBackend != updated.mountBackend ||
            current.vfsCacheMode != updated.vfsCacheMode ||
            current.vfsCacheMaxSize != updated.vfsCacheMaxSize ||
            current.vfsCacheMaxAge != updated.vfsCacheMaxAge ||
            current.vfsCachePath != updated.vfsCachePath ||
            current.mountAtStartup != updated.mountAtStartup

        return needsReinstall ? .reinstall : .none
    }
}

/// Applies a `settings.json` edit, ISOLATING the launch-at-login
/// (`SMAppService`) call from every other safe-key application so a thrown
/// error there can never corrupt state already applied by this reconcile —
/// or any other state, since this type never touches profile data at all.
///
/// Dependency-injected (rather than calling `SMAppService` directly) so
/// `ConfigSelfTest` can exercise the isolation guarantee by injecting a
/// failing `applyLoginItem` closure, without needing a real, possibly-signed
/// login-item registration to succeed or fail in a controlled way.
enum SettingsReconciler {
    static func apply(
        safeSettings: [AppSettingsFileStore.SafeKey: Bool],
        applySafeKey: (AppSettingsFileStore.SafeKey, Bool) -> Void,
        currentLoginItemEnabled: () -> Bool,
        applyLoginItem: (Bool) throws -> Void
    ) {
        for key in AppSettingsFileStore.SafeKey.allCases where key != .launchAtLogin {
            if let value = safeSettings[key] {
                applySafeKey(key, value)
            }
        }

        guard let desiredLoginItem = safeSettings[.launchAtLogin],
              desiredLoginItem != currentLoginItemEnabled() else { return }

        do {
            try applyLoginItem(desiredLoginItem)
        } catch {
            // ISOLATED: a failure here must not affect anything applied above,
            // or any profile state — this method never touches profiles.
            SyncTraySettings.debugLog("[SettingsReconciler] launch-at-login edit failed: \(error)")
        }
    }
}

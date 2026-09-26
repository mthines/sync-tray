import Foundation

/// Cleans up the "(Offline)" sibling browse point left behind by a retired feature.
///
/// A prior release maintained a read-only symlink named `"<mount-name> (Offline)"`
/// next to a Stream profile's mount point, pointing into the VFS cache's DATA tree, so
/// already-cached files stayed browsable in Finder with no network and no live rclone
/// process. That feature is removed (superseded by the union-overlay Cache-only mode,
/// which keeps the SAME mount point usable offline instead of adding a sibling). This
/// type only removes what the old feature left behind — it never creates anything.
///
/// Pure predicate + a thin filesystem apply, mirroring the shape the retired
/// browse-point-management type used: `shouldRemove` computes over an observed
/// on-disk state with no I/O (unit-testable), `removeIfPresent` is the only member
/// that touches `FileManager`. `nonisolated` throughout so both the CLI (no actor
/// context) and `@MainActor` call sites (`SyncManager`, `ProfileListView`) can call
/// it directly.
enum LegacyOfflineLink {
    /// Path of the legacy browse point: a sibling of the mount point named
    /// `"<mount-name> (Offline)"`. `nil` only when there is no mount point to sit
    /// beside (empty `localSyncPath`).
    nonisolated static func linkPath(for profile: SyncProfile) -> String? {
        let mount = profile.localSyncPath
        guard !mount.isEmpty else { return nil }
        let ns = mount as NSString
        let parent = ns.deletingLastPathComponent
        let name = ns.lastPathComponent
        guard !name.isEmpty, !parent.isEmpty else { return nil }
        return (parent as NSString).appendingPathComponent("\(name) (Offline)")
    }

    /// Whether the item at `linkPath` should be removed: it must be a SYMLINK (never a
    /// real directory/file — that could be a user's own folder that merely shares the
    /// name) whose destination contains a `/vfs/` path component (i.e. it points into
    /// a VFS cache data tree, the sole thing the retired feature ever linked to). A
    /// symlink pointing anywhere else is left alone — it isn't ours to clean up.
    nonisolated static func shouldRemoveLegacyOfflineLink(isSymlink: Bool, destination: String) -> Bool {
        guard isSymlink else { return false }
        return destination.split(separator: "/").contains("vfs")
    }

    /// Filesystem apply for one profile: reads the current state at `linkPath`, asks
    /// `shouldRemoveLegacyOfflineLink`, and removes the symlink if so. Never throws —
    /// a failure to clean up a stale convenience link must not break launch, delete, or
    /// reconcile flows. Returns whether a link was removed.
    @discardableResult
    nonisolated static func removeIfPresent(
        for profile: SyncProfile, fileManager: FileManager = .default
    ) -> Bool {
        guard let link = linkPath(for: profile),
              let attrs = try? fileManager.attributesOfItem(atPath: link),
              (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: link)
        else { return false }

        guard shouldRemoveLegacyOfflineLink(isSymlink: true, destination: destination) else { return false }
        return (try? fileManager.removeItem(atPath: link)) != nil
    }
}

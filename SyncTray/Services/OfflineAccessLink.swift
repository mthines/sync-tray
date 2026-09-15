import Foundation

/// Pure planning + a thin filesystem apply for the per-profile **offline access**
/// browse point.
///
/// rclone's `nfsmount` is a *streaming* VFS cache: when the network drops, the
/// backend connection dies, the NFS server stalls, and macOS drops the live mount
/// ("Server connections interrupted"). No rclone flag makes the live mount serve
/// purely-from-cache offline. What DOES survive offline is the on-disk VFS **data**
/// tree (`{vfsCachePath}/vfs/{key}`), which mirrors the remote folder tree as real
/// local files for everything already cached.
///
/// So when `offlineAccessEnabled` is on, SyncTray maintains a **read-only symlink**
/// named `"<mount-name> (Offline)"` as a *sibling of the mount point* that points
/// straight at that data tree. Cached files stay browsable in Finder with no
/// internet and with no rclone process involved.
///
/// The link is a sibling — **never** the mount point itself. Symlink-swapping the
/// live mount point is what caused the `mount_nfs` exit-66 crash (the abandoned
/// offline-shadow approach); this design deliberately never touches it.
///
/// Pure by design (mirrors `CacheMigrationPlanner`): `linkPath`, `target`, and
/// `action` compute over a `SyncProfile` + an observed on-disk state and do no I/O,
/// so the decision matrix is unit-testable (`ConfigSelfTest` AC-OA1). `apply(...)`
/// is the only member that touches `FileManager`.
enum OfflineAccessLink {
    /// Path of the read-only "(Offline)" browse point: a sibling of the mount point
    /// named `"<mount-name> (Offline)"`. Returns `nil` only when there is no mount
    /// point to sit beside (empty `localSyncPath`). Deliberately does NOT gate on
    /// `isMountMode`/`offlineAccessEnabled` — the caller needs the path to *remove* a
    /// stale link after a profile is switched off mount mode or the flag is cleared.
    static func linkPath(for profile: SyncProfile) -> String? {
        let mount = profile.localSyncPath
        guard !mount.isEmpty else { return nil }
        let ns = mount as NSString
        let parent = ns.deletingLastPathComponent
        let name = ns.lastPathComponent
        guard !name.isEmpty, !parent.isEmpty else { return nil }
        return (parent as NSString).appendingPathComponent("\(name) (Offline)")
    }

    /// Absolute path of the symlink target: the profile's VFS cache **data**
    /// directory, `{vfsCachePath}/vfs/{cacheRelativePath}`. Pure — computed from the
    /// profile alone, so it resolves even before the cache dir exists on disk (the
    /// link simply dangles until the first mount/warm populates the cache). Shares
    /// `cacheRelativePath(for:)` with `VFSCacheService.cacheDirectory(for:)` so the
    /// two can never disagree about which subtree a profile owns.
    static func target(for profile: SyncProfile) -> String {
        let base = (profile.vfsCachePath as NSString).expandingTildeInPath
        let vfsDir = (base as NSString).appendingPathComponent(CacheTreeKind.content.rawValue)
        return (vfsDir as NSString).appendingPathComponent(VFSCacheService.cacheRelativePath(for: profile))
    }

    /// What the maintainer should do this pass.
    enum Action: Equatable {
        case create(link: String, target: String)
        case remove(link: String)
        case none
    }

    /// Decide the action for a profile given the current on-disk link state.
    ///
    /// - `linkExists`: whether a symlink already exists at `linkPath(for:)`.
    /// - `currentTarget`: the destination that link currently points at, if any
    ///   (so a re-point after a `vfsCachePath` change is detected and corrected).
    ///
    /// The link is wanted only for a **mount-mode** profile with
    /// `offlineAccessEnabled` on; anything else means "remove a link if one is
    /// there" — which also cleans up after a mode switch or a disable.
    static func action(for profile: SyncProfile, linkExists: Bool, currentTarget: String?) -> Action {
        guard let link = linkPath(for: profile) else { return .none }
        let wanted = profile.isMountMode && profile.offlineAccessEnabled
        if wanted {
            let want = target(for: profile)
            if linkExists && currentTarget == want { return .none }
            return .create(link: link, target: want)
        }
        return linkExists ? .remove(link: link) : .none
    }

    /// Force-remove the offline browse point for a profile that is being **deleted**,
    /// regardless of its `offlineAccessEnabled` flag (which would otherwise say "keep
    /// it"). Only ever removes a *symlink* — never a real directory — so it can never
    /// destroy a user folder that merely shares the "(Offline)" name. Returns whether
    /// a link was removed.
    @discardableResult
    static func removeLink(for profile: SyncProfile, fileManager: FileManager = .default) -> Bool {
        guard let link = linkPath(for: profile),
              let attrs = try? fileManager.attributesOfItem(atPath: link),
              (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else { return false }
        return (try? fileManager.removeItem(atPath: link)) != nil
    }

    /// Filesystem apply for one profile. Reads the current link state, asks `action`
    /// what to do, then makes it so. Returns the action taken (`.none` when already
    /// correct) so callers/telemetry can log real changes. Never throws — a failure
    /// to maintain a convenience browse point must not break mount/reconcile flows;
    /// it's logged and swallowed.
    @discardableResult
    static func apply(for profile: SyncProfile,
                      fileManager: FileManager = .default,
                      log: ((String) -> Void)? = nil) -> Action {
        guard let link = linkPath(for: profile) else { return .none }

        // Observe current state: is there a symlink at `link`, and where does it point?
        var linkExists = false
        var currentTarget: String? = nil
        if let attrs = try? fileManager.attributesOfItem(atPath: link),
           (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            linkExists = true
            currentTarget = try? fileManager.destinationOfSymbolicLink(atPath: link)
        }

        let decision = action(for: profile, linkExists: linkExists, currentTarget: currentTarget)
        switch decision {
        case .none:
            return .none
        case .create(_, let want):
            // Remove a stale link (wrong target) first; createSymbolicLink fails if the
            // path is occupied. We only ever remove a *symlink* here, never a real dir —
            // if a real directory/file sits at `link` (e.g. a user folder), leave it be.
            if linkExists {
                try? fileManager.removeItem(atPath: link)
            } else if fileManager.fileExists(atPath: link) {
                // A non-symlink already occupies the path — don't clobber a real item.
                log?("Offline access: \(link) exists but is not a symlink — leaving it untouched")
                return .none
            }
            do {
                try fileManager.createSymbolicLink(atPath: link, withDestinationPath: want)
                log?("Offline access: linked \(link) → \(want)")
            } catch {
                log?("Offline access: failed to link \(link): \(error.localizedDescription)")
                return .none
            }
            return decision
        case .remove:
            do {
                try fileManager.removeItem(atPath: link)
                log?("Offline access: removed \(link)")
            } catch {
                log?("Offline access: failed to remove \(link): \(error.localizedDescription)")
                return .none
            }
            return decision
        }
    }
}

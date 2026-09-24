import Foundation

/// Adopt a pre-existing, remote-named VFS cache tree into a profile's **stable cache
/// identity** tree, so switching on `stableCacheIdentity` never costs a re-download.
///
/// # Why this exists
///
/// rclone derives the VFS cache location from the mounted Fs: `{cache-dir}/vfs/{fsName}/
/// {fsRoot}` for the data and `{cache-dir}/vfsMeta/{fsName}/{fsRoot}` for the byte-range
/// sidecars. `fsName` is the *remote name*, so the cache is keyed by which remote the
/// profile happens to point at:
///
/// ```
/// {root}/vfs/synology/Kaiju/KAIJU        <- while on the LAN, via SMB
/// {root}/vfs/synology-sftp/Kaiju/KAIJU   <- same files, after switching to SFTP
/// ```
///
/// Two trees, the same bytes, downloaded twice — and the second one starts empty, which is
/// what turns "I changed my remote because I'm not on my local network" into a full re-fetch.
///
/// `stableCacheIdentity` fixes that going forward by mounting an env-var-defined remote
/// named after the PROFILE (`synctray_{shortId}`) whose connection parameters are copied from
/// whichever remote is active, so `fsName` never changes. But flipping that on would *itself*
/// strand the tree already on disk under the old name. This type is the one-time rename that
/// closes the gap: it moves `vfs/{legacyName}/{remotePath}` (and its `vfsMeta` sibling) to
/// `vfs/{identity}/{remotePath}` before the first mount under the new identity.
///
/// # Shape
///
/// Pure planner (`plan`) + a thin filesystem apply (`apply`), mirroring
/// `CacheMigrationPlanner`/`OfflineAccessLink`, so the decision matrix is testable with no
/// disk (`ConfigSelfTest` AC-CI1) and the I/O is one small, obvious function.
///
/// # Deliberate non-goals
///
/// - **Never merges.** If a tree already exists at the destination the legacy tree is left
///   exactly where it is (`.destinationOccupied`). Merging two partially-warm caches means
///   reconciling two `vfsMeta` byte-range sets per file; getting that wrong silently serves
///   corrupt bytes, so the safe outcome is to keep both and let the cache re-warm the delta.
/// - **Rename only, never copy.** Both trees live under the same `--cache-dir`, so this is
///   always a same-directory rename: atomic, instant, and no free-space requirement, even for
///   the ~95 GB caches this is meant to preserve. A cross-root relocation is a different
///   feature and already exists (`CacheMigrationService`).
enum CacheIdentityMigration {

    /// What the migration should do for one `CacheTreeKind`.
    enum Action: Equatable {
        /// Rename `source` to `destination` (same cache root, so an atomic rename).
        case adopt(source: String, destination: String)
        /// Nothing to do: identity disabled, no legacy tree, or already migrated.
        case none
        /// A tree already exists at the destination AND a legacy tree exists. Left alone
        /// on purpose — see "Deliberate non-goals".
        case destinationOccupied(source: String, destination: String)
    }

    /// The on-disk facts `plan` needs, passed in so the planner itself does no I/O.
    struct Observation: Equatable {
        let legacyExists: Bool
        let destinationExists: Bool
    }

    /// Absolute path of a profile's cache subtree for one tree kind under `key`.
    static func subtreePath(root: String, kind: CacheTreeKind, key: String) -> String {
        let base = CacheMigrationPlanner.normalizeRoot(root)
        let kindDir = (base as NSString).appendingPathComponent(kind.rawValue)
        return (kindDir as NSString).appendingPathComponent(key)
    }

    /// Every legacy cache key a profile's bytes could be sitting under: its primary remote
    /// name, plus the fallback remote's name when one is configured.
    ///
    /// The fallback is included because the mount only keeps one shared tree across a
    /// failover when `fallbackRequiresCacheRebuild` is false; a profile that failed over
    /// under an older build (or a non-mount profile later switched to Stream) can legitimately
    /// have a second `vfs/{fallback}/…` tree. Candidates are returned primary-first, and
    /// `plan` adopts the FIRST one that exists, so the primary's tree always wins.
    ///
    /// Returns `[]` for a profile whose cache is not remote-named to begin with
    /// (`stableCacheIdentity` off), and never returns a key equal to the identity key.
    static func legacyKeys(for profile: SyncProfile) -> [String] {
        guard profile.stableCacheIdentity else { return [] }
        let identityKey = VFSCacheService.cacheRelativePath(for: profile)
        var names = [profile.primaryRemoteName]
        if !profile.fallbackRemote.isEmpty {
            names.append(profile.fallbackRemote)
        }
        var seen = Set<String>()
        return names.compactMap { name -> String? in
            let trimmed = name.replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let key = VFSCacheService.legacyCacheRelativePath(
                remoteName: trimmed, remotePath: profile.remotePath)
            guard key != identityKey, seen.insert(key).inserted else { return nil }
            return key
        }
    }

    /// Decide the action for one tree kind, given the legacy key under consideration and
    /// what is on disk. Pure.
    static func plan(
        profile: SyncProfile,
        kind: CacheTreeKind,
        legacyKey: String,
        observation: Observation
    ) -> Action {
        guard profile.isMountMode, profile.stableCacheIdentity else { return .none }
        let source = subtreePath(root: profile.vfsCachePath, kind: kind, key: legacyKey)
        let destination = subtreePath(
            root: profile.vfsCachePath, kind: kind,
            key: VFSCacheService.cacheRelativePath(for: profile))
        guard source != destination, observation.legacyExists else { return .none }
        if observation.destinationExists {
            return .destinationOccupied(source: source, destination: destination)
        }
        return .adopt(source: source, destination: destination)
    }

    /// Adopt whichever legacy tree exists, for every `CacheTreeKind`, for one profile.
    ///
    /// Runs before the mount comes up (called from `SyncSetupService.install`), so no rclone
    /// process holds the trees. Returns the actions actually taken, for logging/telemetry.
    ///
    /// The data (`vfs`) and metadata (`vfsMeta`) trees are adopted **together, data last**:
    /// `vfsMeta` carries the downloaded byte-range list that proves a cached file is complete,
    /// so a crash between the two must never leave data without its metadata (rclone would
    /// treat the cache as unpopulated and re-download). Losing metadata-without-data is the
    /// harmless direction — rclone just re-fetches those entries.
    ///
    /// Never throws: failing to adopt an old cache costs a re-download, which is bad, but
    /// blocking the install would be worse.
    @discardableResult
    static func apply(
        for profile: SyncProfile,
        fileManager: FileManager = .default,
        log: ((String) -> Void)? = nil
    ) -> [Action] {
        guard profile.isMountMode, profile.stableCacheIdentity else { return [] }

        var taken: [Action] = []
        for legacyKey in legacyKeys(for: profile) {
            // Decide for both kinds against the SAME legacy key before moving anything, so a
            // half-adopted pair can't happen just because the two kinds disagreed.
            let planned: [(CacheTreeKind, Action)] = [CacheTreeKind.meta, CacheTreeKind.content]
                .map { kind in
                    let source = subtreePath(root: profile.vfsCachePath, kind: kind, key: legacyKey)
                    let destination = subtreePath(
                        root: profile.vfsCachePath, kind: kind,
                        key: VFSCacheService.cacheRelativePath(for: profile))
                    let observation = Observation(
                        legacyExists: fileManager.fileExists(atPath: source),
                        destinationExists: fileManager.fileExists(atPath: destination))
                    return (kind, plan(profile: profile, kind: kind,
                                       legacyKey: legacyKey, observation: observation))
                }

            // Only adopt when nothing is in the way for EITHER kind — adopting data whose
            // metadata destination is occupied would pair the new data with a stale
            // byte-range list, which is the one outcome that can serve wrong bytes.
            if planned.contains(where: {
                if case .destinationOccupied = $0.1 { return true }
                return false
            }) {
                for (kind, action) in planned where action != .none {
                    if case .destinationOccupied(let source, _) = action {
                        log?("Cache identity: \(kind.rawValue) tree already present for "
                             + "'\(profile.name)' — leaving \(source) in place")
                        taken.append(action)
                    }
                }
                continue
            }

            for (kind, action) in planned {
                guard case .adopt(let source, let destination) = action else { continue }
                let parent = (destination as NSString).deletingLastPathComponent
                do {
                    try fileManager.createDirectory(
                        atPath: parent, withIntermediateDirectories: true)
                    try fileManager.moveItem(atPath: source, toPath: destination)
                    log?("Cache identity: adopted \(kind.rawValue) cache for '\(profile.name)': "
                         + "\(source) → \(destination)")
                    taken.append(action)
                } catch {
                    log?("Cache identity: failed to adopt \(kind.rawValue) cache for "
                         + "'\(profile.name)': \(error.localizedDescription)")
                }
            }

            // One legacy tree per profile is enough; stop at the first that was adopted.
            if taken.contains(where: { if case .adopt = $0 { return true }; return false }) {
                break
            }
        }
        return taken
    }
}

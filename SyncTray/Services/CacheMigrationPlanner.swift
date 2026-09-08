import Foundation

/// The two fixed-name sibling trees rclone maintains under `--cache-dir`.
/// The rawValue IS the on-disk directory name, so the names live in one
/// place — adding a third tree kind is one edit.
enum CacheTreeKind: String, CaseIterable, Equatable {
    case content = "vfs"
    case meta = "vfsMeta"
}

/// One physical subtree a migration touches: `{root}/{kind.rawValue}/{relativePath}`.
struct CacheSubtree: Equatable, Hashable {
    let kind: CacheTreeKind
    let relativePath: String  // e.g. "synology/Kaiju/KAIJU"
}

/// A resolved, ready-to-run cache migration. `sourceRoot`/`destinationRoot`
/// are normalized (tilde-expanded, no trailing "/").
struct CacheMigrationPlan: Equatable {
    let sourceRoot: String
    let destinationRoot: String
    /// Content + metadata subtrees for every migrating profile (the moving
    /// profile plus any overlapping sibling in `coMigrate`).
    let subtrees: [CacheSubtree]
    /// Descendant keys deliberately left behind. Reserved for a future
    /// partial-move mode — today `plan(...)` either includes an overlapping
    /// sibling's subtrees (co-migrated) or rejects the whole plan
    /// (`unresolvedOverlap`), so this is always empty; kept as a plan field
    /// because `CacheMigrationEngine.preflight` reads it to decide whether the
    /// same-volume whole-directory fast path is still safe.
    let excludedRelativePaths: [String]
    /// Every profile whose `vfsCachePath` should be rewritten to
    /// `destinationRoot` once the move completes — the moving profile plus
    /// any co-migrated overlapping sibling.
    let profileIdsToRewrite: [UUID]
    /// Always empty in a plan returned by `.success` — a non-empty value only
    /// ever appears inside the `.unresolvedOverlap` rejection case.
    let unresolvedOverlaps: [UUID]
    /// Other mount-mode profiles that share `sourceRoot` but whose cache key
    /// does NOT overlap the moving profile's — informational, for the "these
    /// profiles also use this cache root" prompt (R14). Migrating one of
    /// these is a SEPARATE, independent `plan(...)` call (its subtree doesn't
    /// touch the moving profile's bytes at all), not part of this plan.
    let sameRootProfiles: [UUID]

    /// Swap source/destination for a rollback run — same subtrees, same
    /// exclusions, same rewrite set, opposite direction.
    func reversed() -> CacheMigrationPlan {
        CacheMigrationPlan(
            sourceRoot: destinationRoot,
            destinationRoot: sourceRoot,
            subtrees: subtrees,
            excludedRelativePaths: excludedRelativePaths,
            profileIdsToRewrite: profileIdsToRewrite,
            unresolvedOverlaps: unresolvedOverlaps,
            sameRootProfiles: sameRootProfiles
        )
    }
}

enum CacheMigrationRejection: Equatable {
    case notMountMode
    case emptyDestination
    case destinationEqualsSource
    case destinationNestedWithSource
    case unresolvedOverlap([UUID])
}

enum CacheMigrationPlanner {
    /// Tilde-expand and standardize a cache root so equality/nesting
    /// comparisons and disk operations agree — matches
    /// `SyncSetupService.install`'s `expandingTildeInPath` on the same field.
    static func normalizeRoot(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        if expanded.count > 1, expanded.hasSuffix("/") {
            expanded.removeLast()
        }
        return expanded
    }

    /// Classify every OTHER mount-mode profile sharing `sourceRoot` against
    /// `moving`'s cache key: `overlapping` (nested either direction, or an
    /// identical key — the SAME bytes on disk) vs `sameRoot` (a disjoint key
    /// that merely shares the root directory). Shared by `plan(...)` and
    /// `SyncManager.cachePathChangeIntent` (the Save-time prompt) so the two
    /// can never disagree about who's affected by a move.
    static func classifySiblings(
        of moving: SyncProfile,
        sourceRoot: String,
        allProfiles: [SyncProfile]
    ) -> (overlapping: [SyncProfile], sameRoot: [SyncProfile]) {
        let movingKey = VFSCacheService.cacheRelativePath(for: moving)
        let siblings = allProfiles.filter {
            $0.id != moving.id && $0.isMountMode && normalizeRoot($0.vfsCachePath) == sourceRoot
        }
        var overlapping: [SyncProfile] = []
        var sameRoot: [SyncProfile] = []
        for sibling in siblings {
            let siblingKey = VFSCacheService.cacheRelativePath(for: sibling)
            if siblingKey == movingKey || isNested(siblingKey, in: movingKey) || isNested(movingKey, in: siblingKey) {
                overlapping.append(sibling)
            } else {
                sameRoot.append(sibling)
            }
        }
        return (overlapping, sameRoot)
    }

    /// Resolve which subtrees a Stream profile's cache move touches.
    ///
    /// - `coMigrate` names OVERLAPPING siblings (same bytes on disk) the
    ///   caller has decided to move along with `moving`. Any overlapping
    ///   sibling NOT in `coMigrate` rejects the whole plan with
    ///   `.unresolvedOverlap` — moving `moving`'s subtree alone would carry
    ///   away (or leave stranded) bytes that sibling still needs.
    /// - A merely-same-root (non-overlapping) sibling is never rejected and
    ///   never auto-included: it is reported in `sameRootProfiles` for the
    ///   caller to offer as an independent, separate migration.
    static func plan(
        moving: SyncProfile,
        allProfiles: [SyncProfile],
        to destination: String,
        coMigrate: Set<UUID>
    ) -> Result<CacheMigrationPlan, CacheMigrationRejection> {
        guard moving.isMountMode else { return .failure(.notMountMode) }

        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return .failure(.emptyDestination) }

        let sourceRoot = normalizeRoot(moving.vfsCachePath)
        let destinationRoot = normalizeRoot(trimmedDestination)

        guard destinationRoot != sourceRoot else { return .failure(.destinationEqualsSource) }
        guard !isNested(destinationRoot, in: sourceRoot), !isNested(sourceRoot, in: destinationRoot) else {
            return .failure(.destinationNestedWithSource)
        }

        let (overlapping, sameRoot) = classifySiblings(of: moving, sourceRoot: sourceRoot, allProfiles: allProfiles)

        let unresolved = overlapping.filter { !coMigrate.contains($0.id) }
        guard unresolved.isEmpty else {
            return .failure(.unresolvedOverlap(unresolved.map { $0.id }))
        }

        let migratingProfiles = [moving] + overlapping.filter { coMigrate.contains($0.id) }

        var subtrees: [CacheSubtree] = []
        for profile in migratingProfiles {
            let key = VFSCacheService.cacheRelativePath(for: profile)
            for kind in CacheTreeKind.allCases {
                subtrees.append(CacheSubtree(kind: kind, relativePath: key))
            }
        }

        return .success(CacheMigrationPlan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            subtrees: subtrees,
            excludedRelativePaths: [],
            profileIdsToRewrite: migratingProfiles.map { $0.id },
            unresolvedOverlaps: [],
            sameRootProfiles: sameRoot.map { $0.id }
        ))
    }

    /// True when `candidate` is a strict descendant of `ancestor` (not equal).
    private static func isNested(_ candidate: String, in ancestor: String) -> Bool {
        candidate != ancestor && candidate.hasPrefix(ancestor + "/")
    }
}

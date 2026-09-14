import Foundation

// MARK: - P1 — offline browse shadow-link decision

/// Whether the (empty, unmounted) mountpoint should be replaced with a
/// symlink into the cache DATA subtree so the warmed cache stays browsable
/// and writable while the profile is unmounted (D1). Pure — the caller
/// resolves `cacheDataDirExists`/`cacheDataDirNonEmpty` from disk (or an
/// injected filesystem in tests) and passes them in.
enum ShadowLinkDecision: Equatable {
    case create(target: String)
    case skip
}

// MARK: - Shadow-creation scoping (R22 / D7)

/// Every reason a mount-mode profile's volume gets detached. Only
/// `.userInitiated` (the "going offline" case — the feature's whole
/// purpose) may create an offline-browse shadow. `remountOnPrimary`,
/// settings-save reinstall, cache-directory migration, and profile delete
/// must NEVER leave a shadow behind — see the plan's D7 caller audit table.
enum UnmountReason: Equatable {
    case userInitiated
    case remountOnPrimary
    case settingsReinstall
    case cacheMigration
    case profileDelete
}

// MARK: - P2 — offline-authored file classification

/// Why a candidate file was excluded from the offline-upload set. There is
/// deliberately NO case representing a delete/propagate-removal action —
/// deletions are never propagated (R8); the result type this reason feeds
/// (`OfflineReconcilePlan`) has no delete variant, so a missing remote file
/// is structurally unrepresentable as an action.
enum SkipReason: Equatable {
    /// Sidecar'd but `isCacheComplete` failed — sparse/partial, or (P3,
    /// deferred) an in-place edit whose size changed.
    case incomplete
    /// **BLOCKER guard (R19).** No sidecar, but not fully block-allocated —
    /// a sparse orphan (interrupted download, crashed mid-write, an
    /// independently evicted sidecar, or rclone writing data before the
    /// sidecar). Uploading this would zero-overwrite the remote original.
    case sparseNoSidecar
    /// Sidecar'd, complete, and not newer than the unmount boundary — a
    /// normal rclone-cached file, nothing to upload.
    case unchanged
    /// `.DS_Store` / `._*` Finder metadata, or a match against the
    /// profile's `warmExcludePatterns`.
    case excluded
}

enum OfflineFileClassification: Equatable {
    case upload
    case skip(reason: SkipReason)
}

/// Groups `classifyOfflineFile`'s inputs (code-quality param grouping,
/// carried over from Phase 1 review).
struct OfflineFileFacts {
    let relativePath: String
    let name: String
    /// Whether a `vfsMeta/{key}/{relativePath}` sidecar exists. A sidecar
    /// proves rclone streamed this file at some point — the safe signal
    /// that a NO-sidecar file is user-authored (never rclone-streamed).
    let hasSidecar: Bool
    /// Logical file size in bytes (`st_size`).
    let dataSize: Int64
    /// Allocated size in bytes (`st_blocks * 512`). Used ONLY for the
    /// no-sidecar branch's sparse guard (R19) — a sidecar'd file's
    /// completeness is proven by `isCacheComplete`'s byte-range coverage
    /// instead, which is a stronger signal than block allocation.
    let allocatedBytes: Int64
    /// Decoded `vfsMeta` sidecar, when `hasSidecar` is true.
    let sidecarMeta: VFSCacheService.VFSCacheMeta?
    /// Reserved for the deferred P3 in-place-edit gate (a same-size edit's
    /// mtime vs. the unmount boundary). Unused by the P2 decision below.
    let modifiedDate: Date?

    init(
        relativePath: String,
        name: String,
        hasSidecar: Bool,
        dataSize: Int64,
        allocatedBytes: Int64,
        sidecarMeta: VFSCacheService.VFSCacheMeta?,
        modifiedDate: Date? = nil
    ) {
        self.relativePath = relativePath
        self.name = name
        self.hasSidecar = hasSidecar
        self.dataSize = dataSize
        self.allocatedBytes = allocatedBytes
        self.sidecarMeta = sidecarMeta
        self.modifiedDate = modifiedDate
    }
}

/// One entry in an offline-authored-file scan, ready to be classified.
struct OfflineScanEntry {
    let facts: OfflineFileFacts
}

/// The result of `planOfflineReconcile`. Deliberately has NO delete/removal
/// case (R8) — a remote path with no corresponding cache-scan entry simply
/// never appears here; there is no action type that could express deleting
/// it. This makes deletion-propagation a compile-time impossibility rather
/// than a runtime guard that could be forgotten or bypassed.
struct OfflineReconcilePlan: Equatable {
    let uploads: [String]
}

enum OfflineShadowPlanner {
    // MARK: - P1

    /// Pure truth table for D1: create the shadow only when there is
    /// something to browse and the profile is not currently mounted.
    static func shadowLinkDecision(
        isMounted: Bool,
        cacheDataDirExists: Bool,
        cacheDataDirNonEmpty: Bool,
        dataRoot: String
    ) -> ShadowLinkDecision {
        guard !isMounted else { return .skip }
        guard cacheDataDirExists, cacheDataDirNonEmpty else { return .skip }
        return .create(target: dataRoot)
    }

    /// D7 — the single source of truth for "does this unmount reason create
    /// an offline shadow?". Every caller that detaches a mount-mode
    /// profile's volume maps its own reason to this enum and asks; only
    /// `.userInitiated` says yes.
    static func shouldCreateShadow(reason: UnmountReason) -> Bool {
        reason == .userInitiated
    }

    // MARK: - P2

    /// The BLOCKER-closing classification (R19/D11). A file uploads only
    /// when it is PROVABLY fully present:
    ///   (a) no sidecar AND fully block-allocated (`allocatedBytes >=
    ///       dataSize`) — a genuinely new, complete, user-authored file, or
    ///   (b) sidecar'd AND `isCacheComplete` — reused verbatim from
    ///       `VFSCacheService`, no duplicated range logic.
    /// Metadata/exclude matches are checked first so they never fall through
    /// to either upload path (R9/R20).
    static func classifyOfflineFile(
        _ facts: OfflineFileFacts,
        unmountBoundary: Date,
        exclude: VFSCacheService.ExcludeMatcher
    ) -> OfflineFileClassification {
        if facts.name == ".DS_Store" || facts.name.hasPrefix("._") {
            return .skip(reason: .excluded)
        }
        if !exclude.isEmpty, exclude.matches(relativePath: facts.relativePath, name: facts.name) {
            return .skip(reason: .excluded)
        }

        if facts.hasSidecar {
            guard let meta = facts.sidecarMeta,
                  VFSCacheService.isCacheComplete(meta: meta, expectedSize: facts.dataSize) else {
                return .skip(reason: .incomplete)
            }
            // P2 scope only uploads NEW (no-sidecar) files. A sidecar'd,
            // complete file is a normal rclone-cached file — P3 (in-place
            // edit re-upload) is designed but deferred; see plan D9/AC-OFF12.
            return .skip(reason: .unchanged)
        }

        // No sidecar: user-authored. MUST be fully block-allocated before it
        // may ever be uploaded — this is the BLOCKER guard (R19). A
        // sidecar-less file can still be SPARSE: an interrupted download, a
        // crash mid-write, an independently evicted sidecar
        // (`--vfs-cache-max-age`), or rclone writing data before the
        // sidecar. Uploading it as "complete" would zero-overwrite the
        // remote original.
        guard facts.allocatedBytes >= facts.dataSize else {
            return .skip(reason: .sparseNoSidecar)
        }
        return .upload
    }

    /// Reduce a scan to the set of relative paths eligible for upload.
    /// Structurally cannot produce a delete action (R8) — see
    /// `OfflineReconcilePlan`'s doc comment.
    static func planOfflineReconcile(
        scan: [OfflineScanEntry],
        unmountBoundary: Date,
        exclude: VFSCacheService.ExcludeMatcher
    ) -> OfflineReconcilePlan {
        var uploads: [String] = []
        for entry in scan {
            if case .upload = classifyOfflineFile(entry.facts, unmountBoundary: unmountBoundary, exclude: exclude) {
                uploads.append(entry.facts.relativePath)
            }
        }
        return OfflineReconcilePlan(uploads: uploads)
    }

    // MARK: - Reconcile-once-per-mount-session guard (mirrors `SyncManager.shouldAutoWarmOnMount`)

    /// Returns true exactly once per mount session — the first tick a
    /// profile is seen mounted with pending offline-authored files — and
    /// false on every later tick while it stays mounted. Seeing it
    /// unmounted re-arms it, so a later remount reconciles again. A profile
    /// with nothing pending never reconciles. Distinct state
    /// (`reconciledMounts`) from the warm guard's `autoWarmedMounts` — the
    /// two concerns have different re-arm semantics and must not share a set.
    static func shouldReconcileOnMount(
        isMounted: Bool,
        hasPendingFiles: Bool,
        profileId: UUID,
        alreadyReconciled: inout Set<UUID>
    ) -> Bool {
        guard isMounted else {
            alreadyReconciled.remove(profileId)
            return false
        }
        guard hasPendingFiles else { return false }
        return alreadyReconciled.insert(profileId).inserted
    }
}

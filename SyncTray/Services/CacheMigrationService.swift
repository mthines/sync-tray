import Foundation

// MARK: - Injected filesystem

/// Every filesystem/volume primitive the migration engine needs, injected so
/// `ConfigSelfTest` can drive `preflight`/`run` against an inert fake — no
/// real disk I/O — mirroring `CLIEnvironment`'s struct-of-closures idiom.
struct CacheMigrationFileSystem {
    var directoryExists: (String) -> Bool
    var fileExists: (String) -> Bool
    var enumerateFiles: (String) -> [(relativePath: String, size: Int64)]
    var fileSize: (String) -> Int64?
    var createDirectory: (String) throws -> Void
    var copyFile: (_ from: String, _ to: String) throws -> Void
    var copyFileDataOnly: (_ from: String, _ to: String) throws -> Void
    var moveItem: (_ from: String, _ to: String) throws -> Void
    var removeItem: (String) throws -> Void
    var removeEmptyDirectories: (String) -> Void
    var volumeIdentifier: (String) -> String?
    var availableCapacity: (String) -> Int64?

    /// The real filesystem: actual `FileManager` calls. Uses the classic
    /// `attributesOfFileSystem(forPath:)`/`.systemNumber` APIs (stable since
    /// the earliest Foundation) rather than `URLResourceKey.volumeIdentifierKey`,
    /// since this host has no compiler to catch a resource-key typo.
    ///
    /// - Parameter isCancelled: polled inside the chunked data-only copy
    ///   fallback (finding 6) so a Cancel can interrupt a single very large
    ///   file instead of only taking effect at the next file boundary.
    ///   `fs.copyFile` (`FileManager.copyItem`, the primary, faster path)
    ///   is a single opaque system call and cannot be interrupted mid-transfer
    ///   this way — that residual gap is documented at the call site.
    static func production(isCancelled: @escaping () -> Bool = { false }) -> CacheMigrationFileSystem {
        let fm = FileManager.default
        return CacheMigrationFileSystem(
            directoryExists: { path in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            },
            fileExists: { fm.fileExists(atPath: $0) },
            enumerateFiles: { root in
                guard let enumerator = fm.enumerator(atPath: root) else { return [] }
                var results: [(relativePath: String, size: Int64)] = []
                while let rel = enumerator.nextObject() as? String {
                    let full = (root as NSString).appendingPathComponent(rel)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
                    let size = (try? fm.attributesOfItem(atPath: full))?[.size] as? Int64
                    results.append((rel, size ?? 0))
                }
                return results
            },
            fileSize: { path in
                guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
                return attrs[.size] as? Int64
            },
            createDirectory: { path in
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            },
            copyFile: { from, to in
                try fm.copyItem(atPath: from, toPath: to)
            },
            copyFileDataOnly: { from, to in
                // Stream in fixed-size chunks rather than `fm.contents(atPath:)`
                // + a single `Data.write` — the whole-file-in-memory approach
                // previously spiked RSS to the size of the largest cached
                // file (finding 8), and a VFS cache routinely holds files
                // well beyond what's safe to hold in memory at once. Mirrors
                // the chunked-read pattern `VFSCacheService.warmDirectory`
                // already uses for the same reason.
                guard fm.createFile(atPath: to, contents: nil) else {
                    throw CacheMigrationIOError.dataReadFailed
                }
                guard let reader = FileHandle(forReadingAtPath: from) else {
                    throw CacheMigrationIOError.dataReadFailed
                }
                defer { try? reader.close() }
                guard let writer = FileHandle(forWritingAtPath: to) else {
                    throw CacheMigrationIOError.dataReadFailed
                }
                defer { try? writer.close() }
                let chunkSize = 4 * 1024 * 1024
                while true {
                    if isCancelled() { throw CacheMigrationIOError.cancelled }
                    guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                    try writer.write(contentsOf: chunk)
                }
            },
            moveItem: { from, to in
                try fm.moveItem(atPath: from, toPath: to)
            },
            removeItem: { path in
                try fm.removeItem(atPath: path)
            },
            removeEmptyDirectories: { root in
                CacheMigrationFileSystem.pruneEmptyDirectories(at: root, fm: fm)
            },
            volumeIdentifier: { path in
                guard let existing = CacheMigrationFileSystem.nearestExistingAncestor(of: path, fm: fm),
                      let attrs = try? fm.attributesOfItem(atPath: existing),
                      let systemNumber = attrs[.systemNumber] as? NSNumber else { return nil }
                return systemNumber.stringValue
            },
            availableCapacity: { path in
                guard let existing = CacheMigrationFileSystem.nearestExistingAncestor(of: path, fm: fm),
                      let attrs = try? fm.attributesOfFileSystem(forPath: existing),
                      let free = attrs[.systemFreeSize] as? NSNumber else { return nil }
                return free.int64Value
            }
        )
    }

    /// Walk up from `path` to the nearest ancestor that exists on disk — the
    /// destination root may not exist yet, but its parent volume does.
    private static func nearestExistingAncestor(of path: String, fm: FileManager) -> String? {
        var current = path
        var guardCount = 0
        while !fm.fileExists(atPath: current) {
            guard current != "/", !current.isEmpty, guardCount < 64 else { return "/" }
            current = (current as NSString).deletingLastPathComponent
            guardCount += 1
        }
        return current
    }

    private static func pruneEmptyDirectories(at root: String, fm: FileManager) {
        guard let contents = try? fm.contentsOfDirectory(atPath: root) else { return }
        for name in contents {
            let full = (root as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            pruneEmptyDirectories(at: full, fm: fm)
            if (try? fm.contentsOfDirectory(atPath: full))?.isEmpty == true {
                try? fm.removeItem(atPath: full)
            }
        }
    }
}

enum CacheMigrationIOError: Error {
    case dataReadFailed
    /// Thrown from `copyFileDataOnly`'s chunk loop when the caller's
    /// `isCancelled` flips mid-transfer (finding 6) — distinguished from
    /// `dataReadFailed` so `moveFile` can report a clean cancellation
    /// instead of a genuine I/O failure (no rollback of files this run
    /// already completed).
    case cancelled
}

// MARK: - Cross-thread cancellation bridging

/// `Task.isCancelled` only reflects the CURRENT task's cancellation state.
/// Read from inside a plain `DispatchQueue.global(...).async` closure — which
/// is NOT itself a `Task` — it always returns `false`, even after the
/// enclosing `Task` has been cancelled (finding 2: this left the Cancel
/// button and the supersede-in-flight path permanently inert, since the
/// migration engine's `isCancelled` closure ran inside exactly such a
/// closure). This box lets an outer, genuinely cancellable `Task` hand its
/// cancellation across that thread boundary to a synchronous background
/// closure the engine polls.
final class CacheMigrationCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

// MARK: - Preflight

struct CacheMigrationPreflight: Equatable {
    let totalFiles: Int
    let totalBytes: Int64
    /// Excludes destination files already present at a matching size — the
    /// resume-skip set (R29).
    let bytesToCopy: Int64
    let sameVolume: Bool
}

enum CacheMigrationPreflightRejection: Error, Equatable {
    case nothingToMove
    case destinationUnwritable
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case plan(CacheMigrationRejection)
    /// `isCancelled` fired before or during the source-tree enumeration
    /// (finding 6) — `CacheMigrationRunner.migrate` normalizes this back to
    /// the top-level `CacheMigrationOutcome.Result.cancelled` every caller
    /// already handles correctly, rather than a distinct rejection reason
    /// callers would each need a new switch case for.
    case cancelled
}

enum CacheMigrationFailure: String, Equatable {
    case verifyMismatch
    case countMismatch
    case ioError
    case destinationUnwritable
    /// The mount could not be gracefully detached before the move — the
    /// orchestration must abort rather than relocate files out from under a
    /// still-writing `rclone nfsmount` (finding 7: a swallowed detach
    /// failure previously let the move proceed anyway).
    case mountDetachFailed
}

struct CacheMigrationOutcome: Equatable {
    enum Result: Equatable {
        case completed
        case cancelled
        case failed(CacheMigrationFailure, rolledBack: Bool)
        case preflightRejected(CacheMigrationPreflightRejection)
    }
    let result: Result
    let filesMoved: Int
    let bytesMoved: Int64
    let sameVolume: Bool
}

/// Pure decision: should a migration outcome cause `vfsCachePath` to be
/// persisted? `.completed` obviously may (R20). `.preflightRejected(.nothingToMove)`
/// ALSO may: an empty source cache carries none of the "incomplete data"
/// risk R20 guards against, so silently dropping the user's directory
/// choice would serve no purpose.
///
/// This is the SINGLE, real gate: `SyncManager.migrateCacheDirectory` and
/// the CLI's `migrateCacheProcess` each branch on `if shouldPersist(...)`,
/// with no case list of their own to drift from it. That is a correction of
/// an earlier state in which this function had been widened to cover
/// `.nothingToMove` while BOTH call sites still carried their own
/// hand-copied `.completed` + `.nothingToMove` branches — so the doc's
/// "single gate" claim was false, and the one place that did call this
/// function used it as `case .completed where shouldPersist(outcome)`,
/// a dead guard the matched pattern had already decided.
///
/// The lesson it encodes: a shared decision helper only *is* the decision
/// when every caller's control flow actually hangs off its return value.
enum CacheMigrationPersistDecision {
    static func shouldPersist(_ outcome: CacheMigrationOutcome) -> Bool {
        switch outcome.result {
        case .completed: return true
        case .preflightRejected(.nothingToMove): return true
        default: return false
        }
    }
}

// MARK: - Engine

struct CacheMigrationEngine {
    /// Free space required beyond the payload before a cross-volume move is allowed.
    static let freeSpaceHeadroomBytes: Int64 = 512 * 1024 * 1024

    let fs: CacheMigrationFileSystem
    let isCancelled: () -> Bool
    let onProgress: (_ filesDone: Int, _ bytesDone: Int64, _ currentFile: String) -> Void

    init(
        fs: CacheMigrationFileSystem,
        isCancelled: @escaping () -> Bool = { false },
        onProgress: @escaping (_ filesDone: Int, _ bytesDone: Int64, _ currentFile: String) -> Void = { _, _, _ in }
    ) {
        self.fs = fs
        self.isCancelled = isCancelled
        self.onProgress = onProgress
    }

    /// Compute totals, the same-volume verdict, and the resume-skip set;
    /// reject on insufficient space before a single byte is copied (R2).
    func preflight(_ plan: CacheMigrationPlan) -> Result<CacheMigrationPreflight, CacheMigrationPreflightRejection> {
        // Checked up front AND between subtrees inside `sourceFiles` (finding
        // 6) — the full-tree enumeration that backs the "Preparing…" phase
        // previously never polled cancellation at all, so Cancel stayed
        // inert until the walk finished on its own.
        if isCancelled() { return .failure(.cancelled) }
        guard let files = sourceFiles(for: plan) else { return .failure(.cancelled) }

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        var bytesToCopy: Int64 = 0
        for file in files {
            let destPath = (plan.destinationRoot as NSString).appendingPathComponent(file.relativePath)
            if let existing = fs.fileSize(destPath), existing == file.size {
                continue  // resume skip — already relocated by a prior run
            }
            bytesToCopy += file.size
        }

        // Determine same-volume BEFORE creating anything at the destination.
        // Creating the destination root first would materialize an
        // unmounted `/Volumes/...` path as a plain directory on the BOOT
        // disk, which then reads back as "same volume" as the source —
        // silently skipping the free-space preflight below (finding 9).
        let sourceVolume = fs.volumeIdentifier(plan.sourceRoot)
        let sameVolume = sourceVolume != nil && sourceVolume == fs.volumeIdentifier(plan.destinationRoot)
        let usesFastPath = sameVolume && plan.excludedRelativePaths.isEmpty && !Self.hasNestedSubtrees(plan.subtrees)

        if !usesFastPath {
            guard let available = fs.availableCapacity(plan.destinationRoot) else {
                return .failure(.destinationUnwritable)
            }
            let required = bytesToCopy + Self.freeSpaceHeadroomBytes
            guard available >= required else {
                return .failure(.insufficientSpace(requiredBytes: required, availableBytes: available))
            }
        }

        if !fs.directoryExists(plan.destinationRoot) {
            guard (try? fs.createDirectory(plan.destinationRoot)) != nil else {
                return .failure(.destinationUnwritable)
            }
        }

        // `.nothingToMove` is returned ONLY after the destination has been
        // proven writable (space checked, directory created or already
        // present) — never before. Two call sites (`SyncManager`,
        // `SyncTrayCLI`) treat `.nothingToMove` as persistable exactly like
        // `.completed` (finding 11 from the prior fix round); persisting
        // `vfsCachePath` onto a destination that was never proven to exist
        // or be writable would be exactly the incomplete-cache risk R20
        // guards against (finding 2).
        guard !files.isEmpty else { return .failure(.nothingToMove) }

        return .success(CacheMigrationPreflight(
            totalFiles: files.count,
            totalBytes: totalBytes,
            bytesToCopy: bytesToCopy,
            sameVolume: sameVolume
        ))
    }

    /// Relocate `plan`'s subtrees: the same-volume whole-directory rename
    /// fast path when nothing is excluded AND no two subtrees nest,
    /// otherwise a per-file copy → verify → delete walk.
    ///
    /// Nested subtrees (a co-migrating ancestor + descendant profile sharing
    /// the same bytes on disk, R15) can't both use a whole-directory
    /// `moveItem`: whichever subtree moves second finds its destination
    /// already partially created by the first (finding 5) and
    /// `FileManager.moveItem` refuses to move onto an existing target. The
    /// per-file walk already dedups nested subtrees correctly (`sourceFiles`),
    /// so it's the only path that is safe for them.
    func run(_ plan: CacheMigrationPlan, _ preflight: CacheMigrationPreflight) -> CacheMigrationOutcome {
        let usesFastPath = preflight.sameVolume && plan.excludedRelativePaths.isEmpty && !Self.hasNestedSubtrees(plan.subtrees)
        return usesFastPath ? fastPathMove(plan, preflight) : moveFiles(plan, preflight)
    }

    /// True when two subtrees of the SAME kind nest (one's relative path is
    /// a strict descendant of another's) — the case a whole-directory
    /// `moveItem` fast path cannot handle safely.
    private static func hasNestedSubtrees(_ subtrees: [CacheSubtree]) -> Bool {
        for a in subtrees {
            for b in subtrees where b.kind == a.kind && b.relativePath != a.relativePath {
                if b.relativePath.hasPrefix(a.relativePath + "/") { return true }
            }
        }
        return false
    }

    /// Same-volume, no-exclusions fast path: atomically rename each subtree
    /// ROOT (never a single file inside it) instead of walking file-by-file.
    private func fastPathMove(_ plan: CacheMigrationPlan, _ preflight: CacheMigrationPreflight) -> CacheMigrationOutcome {
        // Subtrees already renamed on this pass, newest last — so a failure
        // partway through can put them back. Without this, a failure on the
        // SECOND subtree left `vfs` at the destination and `vfsMeta` at the
        // source: the split cache this whole feature exists to prevent
        // (rclone reads the two as one unit and re-downloads everything when
        // they disagree), reported as `filesMoved: 0, rolledBack: false` so
        // nothing recorded that it had happened.
        var renamed: [(source: String, dest: String)] = []
        for subtree in plan.subtrees {
            if isCancelled() {
                // A cancel between subtrees is recoverable and is NOT rolled
                // back, matching the per-file path's between-file guarantee:
                // a resumed run skips a subtree whose source is already gone
                // and moves the rest.
                return CacheMigrationOutcome(result: .cancelled, filesMoved: 0, bytesMoved: 0, sameVolume: preflight.sameVolume)
            }
            let sourcePath = subtreePath(subtree, root: plan.sourceRoot)
            guard fs.directoryExists(sourcePath) else { continue }  // nothing cached for this subtree yet

            let destPath = subtreePath(subtree, root: plan.destinationRoot)
            let parent = (destPath as NSString).deletingLastPathComponent
            if !fs.directoryExists(parent) {
                try? fs.createDirectory(parent)
            }
            do {
                try fs.moveItem(sourcePath, destPath)
            } catch {
                let rolledBack = fastPathRollback(renamed)
                return CacheMigrationOutcome(result: .failed(.ioError, rolledBack: rolledBack), filesMoved: 0, bytesMoved: 0, sameVolume: preflight.sameVolume)
            }
            renamed.append((source: sourcePath, dest: destPath))
            onProgress(0, 0, subtree.relativePath)
        }
        onProgress(preflight.totalFiles, preflight.totalBytes, "")
        return CacheMigrationOutcome(
            result: .completed, filesMoved: preflight.totalFiles, bytesMoved: preflight.totalBytes, sameVolume: preflight.sameVolume
        )
    }

    /// Rename each already-relocated subtree root back to where it came
    /// from, newest first. Same-volume by construction (the fast path only
    /// runs when source and destination share a volume), so this is a
    /// cheap metadata operation, not a re-copy.
    ///
    /// - Returns: whether EVERY subtree made it back. `false` means the
    ///   caller must report `rolledBack: false` — some bytes are still at
    ///   the destination and the two trees may still disagree.
    private func fastPathRollback(_ renamed: [(source: String, dest: String)]) -> Bool {
        var ok = true
        for entry in renamed.reversed() {
            let parent = (entry.source as NSString).deletingLastPathComponent
            if !fs.directoryExists(parent) {
                try? fs.createDirectory(parent)
            }
            do {
                try fs.moveItem(entry.dest, entry.source)
            } catch {
                ok = false
            }
        }
        return ok
    }

    /// Per-file copy → verify → delete walk, used whenever the fast path
    /// isn't safe (cross-volume, or a descendant is excluded from the move).
    private func moveFiles(_ plan: CacheMigrationPlan, _ preflight: CacheMigrationPreflight) -> CacheMigrationOutcome {
        guard let files = sourceFiles(for: plan) else {
            return CacheMigrationOutcome(result: .cancelled, filesMoved: 0, bytesMoved: 0, sameVolume: preflight.sameVolume)
        }
        var filesMoved = 0
        var bytesMoved: Int64 = 0
        var movedDestPaths: [String] = []

        for file in files {
            if isCancelled() {
                return CacheMigrationOutcome(result: .cancelled, filesMoved: filesMoved, bytesMoved: bytesMoved, sameVolume: preflight.sameVolume)
            }

            let sourcePath = (plan.sourceRoot as NSString).appendingPathComponent(file.relativePath)
            let destPath = (plan.destinationRoot as NSString).appendingPathComponent(file.relativePath)

            // Resume skip: destination already at a matching size from a
            // prior, interrupted run — nothing left to copy, just finish
            // cleaning up the now-redundant source copy.
            if let existing = fs.fileSize(destPath), existing == file.size {
                try? fs.removeItem(sourcePath)
                // Once the source copy is gone the destination holds the
                // file's ONLY copy, so a later rollback has to restore it
                // exactly like a file this run copied itself. Tracking it
                // only in the copy arm below stranded every resumed file at
                // the destination while `rollback` still reported success,
                // leaving a "reverted" source tree silently incomplete
                // (finding 5). Keyed on the source actually being gone, not
                // on the removal call: if it survived, the destination is
                // still redundant and rollback has nothing to restore here.
                guard !fs.fileExists(sourcePath) else {
                    // The source survived its removal — the same condition
                    // `moveFile` reports as `.ioError` below. Reporting it
                    // the same way here keeps the two arms consistent:
                    // counting it moved and finishing `.completed` would
                    // leave a duplicate at the source, and the final
                    // count/bytes reconciliation would still pass because
                    // the file DID reach the destination.
                    let rolledBack = rollback(destPaths: movedDestPaths, plan: plan)
                    return CacheMigrationOutcome(result: .failed(.ioError, rolledBack: rolledBack), filesMoved: filesMoved, bytesMoved: bytesMoved, sameVolume: preflight.sameVolume)
                }
                movedDestPaths.append(destPath)
                filesMoved += 1
                bytesMoved += file.size
                onProgress(filesMoved, bytesMoved, file.relativePath)
                continue
            }
            if fs.fileExists(destPath) {
                try? fs.removeItem(destPath)  // stale partial at a different size
            }

            switch moveFile(from: sourcePath, to: destPath, expectedSize: file.size) {
            case .success:
                filesMoved += 1
                bytesMoved += file.size
                movedDestPaths.append(destPath)
                onProgress(filesMoved, bytesMoved, file.relativePath)
            case .cancelled:
                // Cancelled mid-transfer of THIS file (finding 6) — the
                // partial destination was already removed by `moveFile`.
                // Files this run already completed successfully are NOT
                // rolled back, matching the between-file cancel guarantee.
                return CacheMigrationOutcome(result: .cancelled, filesMoved: filesMoved, bytesMoved: bytesMoved, sameVolume: preflight.sameVolume)
            case .failure(let reason):
                let rolledBack = rollback(destPaths: movedDestPaths, plan: plan)
                return CacheMigrationOutcome(result: .failed(reason, rolledBack: rolledBack), filesMoved: filesMoved, bytesMoved: bytesMoved, sameVolume: preflight.sameVolume)
            }
        }

        guard reconcile(filesMoved: filesMoved, bytesMoved: bytesMoved, against: preflight) else {
            let rolledBack = rollback(destPaths: movedDestPaths, plan: plan)
            return CacheMigrationOutcome(result: .failed(.countMismatch, rolledBack: rolledBack), filesMoved: filesMoved, bytesMoved: bytesMoved, sameVolume: preflight.sameVolume)
        }

        // Only prune empty source directories once the move is CONFIRMED
        // complete — pruning before reconcile would remove the parent
        // directories a rollback needs to restore into (finding 10).
        // Scoped to just the `vfs`/`vfsMeta` trees, never the whole shared
        // cache root: `vfsCachePath` commonly defaults to the SAME parent
        // rclone's bisync cache lives under (`~/.cache/rclone/bisync/`), so
        // an unscoped prune could remove an unrelated bisync profile's
        // state directories.
        for kind in CacheTreeKind.allCases {
            fs.removeEmptyDirectories("\(plan.sourceRoot)/\(kind.rawValue)")
        }

        return CacheMigrationOutcome(result: .completed, filesMoved: filesMoved, bytesMoved: bytesMoved, sameVolume: preflight.sameVolume)
    }

    /// The outcome of moving a single file. A plain `Result<Void,
    /// CacheMigrationFailure>` cannot represent "cancelled mid-transfer"
    /// (finding 6) distinctly from a genuine I/O failure, so this adds a
    /// third case: `.cancelled` must NOT trigger a rollback of files this
    /// run already completed, while `.failure` must.
    private enum FileMoveResult {
        case success
        case cancelled
        case failure(CacheMigrationFailure)
    }

    /// Copy → compare the destination byte size to the source → only then
    /// delete the source (R19). Never deletes the source before the sizes match.
    private func moveFile(from sourcePath: String, to destPath: String, expectedSize: Int64) -> FileMoveResult {
        // Create the destination's parent directory first — neither
        // `copyItem` nor the data-only fallback creates intermediate
        // directories, so on a fresh destination root every cross-volume
        // file would otherwise fail on the very first copy (finding 1).
        let destParent = (destPath as NSString).deletingLastPathComponent
        if !fs.directoryExists(destParent) {
            do {
                try fs.createDirectory(destParent)
            } catch {
                return .failure(.ioError)
            }
        }

        do {
            try fs.copyFile(sourcePath, destPath)
        } catch {
            do {
                try fs.copyFileDataOnly(sourcePath, destPath)
            } catch CacheMigrationIOError.cancelled {
                // Cancelled mid-transfer (finding 6) — remove the in-flight
                // destination partial so no half-file lingers, mirroring the
                // between-file cancel guarantee, and report a clean
                // cancellation rather than an I/O failure.
                try? fs.removeItem(destPath)
                return .cancelled
            } catch {
                return .failure(.ioError)
            }
        }

        guard fs.fileSize(destPath) == expectedSize else {
            try? fs.removeItem(destPath)
            return .failure(.verifyMismatch)
        }

        do {
            try fs.removeItem(sourcePath)
        } catch {
            return .failure(.ioError)
        }
        return .success
    }

    /// Final count/byte cross-check against the preflight totals (R19's
    /// "after the loop" half).
    private func reconcile(filesMoved: Int, bytesMoved: Int64, against preflight: CacheMigrationPreflight) -> Bool {
        filesMoved == preflight.totalFiles && bytesMoved == preflight.totalBytes
    }

    /// Move already-relocated files from THIS run back to the source on an
    /// integrity failure. Every file that failed verification never had its
    /// source deleted, so only files that completed the full
    /// copy → verify → delete need restoring.
    private func rollback(destPaths: [String], plan: CacheMigrationPlan) -> Bool {
        var ok = true
        for destPath in destPaths.reversed() {
            guard destPath.hasPrefix(plan.destinationRoot + "/") else { ok = false; continue }
            let relative = String(destPath.dropFirst(plan.destinationRoot.count + 1))
            let sourcePath = (plan.sourceRoot as NSString).appendingPathComponent(relative)
            let sourceParent = (sourcePath as NSString).deletingLastPathComponent
            if !fs.directoryExists(sourceParent) {
                try? fs.createDirectory(sourceParent)
            }
            do {
                try fs.copyFile(destPath, sourcePath)
                // Both sizes must be PRESENT and equal. `Int64? == Int64?`
                // is `true` when both sides are `nil` (e.g. the copy silently
                // no-op'd against a still-missing source) — comparing the
                // optionals directly would then treat a copy that produced
                // NOTHING as a verified match and delete the last remaining
                // copy at `destPath` (finding 4).
                guard let sourceSize = fs.fileSize(sourcePath),
                      let destSize = fs.fileSize(destPath),
                      sourceSize == destSize else {
                    ok = false
                    continue
                }
                try fs.removeItem(destPath)
            } catch {
                ok = false
            }
        }
        return ok
    }

    /// Collect every source file across the plan's subtrees exactly once,
    /// even when two subtrees nest (a co-migrating parent + child share
    /// bytes on disk — R15's "no double-move, no double-count").
    ///
    /// Returns `nil` when `isCancelled` fires BETWEEN subtrees (finding 6) —
    /// a partial file list must never silently stand in for the real
    /// totals, since `preflight`'s space check and `moveFiles`'s
    /// `reconcile` both trust this list completely; a caller that got a
    /// truncated array back would compute a wrong total and could turn a
    /// deliberate cancel into a spurious `.countMismatch` failure. There is
    /// no polling point WITHIN a single subtree's `enumerateFiles` call — it
    /// returns one fully-materialized array — so a cancel requested mid-walk
    /// of one very large subtree still only takes effect at the next
    /// subtree boundary; this is a smaller, documented version of the same
    /// residual gap `copyFile`'s non-interruptible primary copy path has.
    private func sourceFiles(for plan: CacheMigrationPlan) -> [(relativePath: String, size: Int64)]? {
        var seen = Set<String>()
        var files: [(relativePath: String, size: Int64)] = []
        for subtree in plan.subtrees {
            if isCancelled() { return nil }
            let subtreeRoot = subtreePath(subtree, root: plan.sourceRoot)
            guard fs.directoryExists(subtreeRoot) else { continue }
            for entry in fs.enumerateFiles(subtreeRoot) {
                let key = "\(subtree.kind.rawValue)/\(subtree.relativePath)/\(entry.relativePath)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                files.append((key, entry.size))
            }
        }
        return files
    }

    private func subtreePath(_ subtree: CacheSubtree, root: String) -> String {
        "\(root)/\(subtree.kind.rawValue)/\(subtree.relativePath)"
    }
}

// MARK: - Shared plan → preflight → run orchestration

/// Plan → preflight → run in one call — the shared core BOTH `SyncManager`
/// (MainActor, warm-cancel + launchd bracket wrapped around this) and the
/// headless CLI (synchronous, no `SyncManager`) drive. Pure orchestration
/// over the injected filesystem; no launchd, no telemetry, no profile
/// persistence — callers layer those around it.
enum CacheMigrationRunner {
    static func migrate(
        moving: SyncProfile,
        allProfiles: [SyncProfile],
        destination: String,
        coMigrate: Set<UUID>,
        fs: CacheMigrationFileSystem,
        isCancelled: @escaping () -> Bool = { false },
        onPreflight: (_ preflight: CacheMigrationPreflight) -> Void = { _ in },
        onProgress: @escaping (_ filesDone: Int, _ bytesDone: Int64, _ currentFile: String) -> Void = { _, _, _ in }
    ) -> (plan: CacheMigrationPlan?, outcome: CacheMigrationOutcome) {
        switch CacheMigrationPlanner.plan(moving: moving, allProfiles: allProfiles, to: destination, coMigrate: coMigrate) {
        case .failure(let rejection):
            return (nil, CacheMigrationOutcome(
                result: .preflightRejected(.plan(rejection)), filesMoved: 0, bytesMoved: 0, sameVolume: false
            ))
        case .success(let plan):
            let engine = CacheMigrationEngine(fs: fs, isCancelled: isCancelled, onProgress: onProgress)
            switch engine.preflight(plan) {
            case .failure(.cancelled):
                // Normalize to the SAME top-level `.cancelled` result the
                // per-file cancel path already produces (finding 6), rather
                // than a distinct `.preflightRejected` reason every caller
                // would need its own new switch case for — `shouldPersist`,
                // the progress-phase switches, and the telemetry label all
                // already treat `.cancelled` correctly.
                return (plan, CacheMigrationOutcome(result: .cancelled, filesMoved: 0, bytesMoved: 0, sameVolume: false))
            case .failure(let rejection):
                return (plan, CacheMigrationOutcome(
                    result: .preflightRejected(rejection), filesMoved: 0, bytesMoved: 0, sameVolume: false
                ))
            case .success(let preflight):
                // Publish the computed totals BEFORE the file loop starts, so a
                // caller tracking progress (SyncManager.cacheMigrationProgress)
                // has files/bytes TOTALS from the first tick instead of only
                // after the whole run finishes (finding 14: an indeterminate
                // progress bar for the entire run).
                onPreflight(preflight)
                return (plan, engine.run(plan, preflight))
            }
        }
    }
}

// MARK: - Launchd + warm-cancel bracket

/// Mirrors the launchd + warm-cancel choreography in
/// `SyncManager.migrateCacheDirectory`: cancel warm for every affected
/// profile, uninstall before the move, install on EVERY exit path via
/// `defer` (including a thrown error). Extracted as an injected-closure unit
/// so the ORDERING is spy-testable without a real `SyncManager`/launchd.
/// `migrateCacheDirectory` performs these same steps directly (rather than
/// calling this) because `checks.yaml`'s AC-9/AC-10 assert the literal call
/// sequence in its own body — kept intentionally tiny so the two can't
/// practically drift.
enum CacheMigrationBracket {
    @discardableResult
    static func run<T>(
        affectedProfileIds: [UUID],
        installedProfileIds: [UUID],
        cancelWarm: (UUID) -> Void,
        uninstall: (UUID) -> Void,
        install: (UUID) -> Void,
        body: () -> T
    ) -> T {
        for id in affectedProfileIds { cancelWarm(id) }
        for id in installedProfileIds { uninstall(id) }
        defer {
            for id in installedProfileIds { install(id) }
        }
        return body()
    }
}

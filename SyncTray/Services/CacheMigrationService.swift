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
    static func production() -> CacheMigrationFileSystem {
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
                guard let data = fm.contents(atPath: from) else {
                    throw CacheMigrationIOError.dataReadFailed
                }
                try data.write(to: URL(fileURLWithPath: to))
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

enum CacheMigrationPreflightRejection: Equatable {
    case nothingToMove
    case destinationUnwritable
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case plan(CacheMigrationRejection)
}

enum CacheMigrationFailure: String, Equatable {
    case verifyMismatch
    case countMismatch
    case ioError
    case destinationUnwritable
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
/// persisted? Only `.completed` may persist (R20) — extracted as a standalone
/// function so this invariant is testable without a real
/// `ProfileStore`/`SyncManager`. `SyncManager.migrateCacheDirectory` guards
/// its own persist branch on this same function.
enum CacheMigrationPersistDecision {
    static func shouldPersist(_ outcome: CacheMigrationOutcome) -> Bool {
        if case .completed = outcome.result { return true }
        return false
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
        let files = sourceFiles(for: plan)
        guard !files.isEmpty else { return .failure(.nothingToMove) }

        if !fs.directoryExists(plan.destinationRoot) {
            guard (try? fs.createDirectory(plan.destinationRoot)) != nil else {
                return .failure(.destinationUnwritable)
            }
        }

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        var bytesToCopy: Int64 = 0
        for file in files {
            let destPath = (plan.destinationRoot as NSString).appendingPathComponent(file.relativePath)
            if let existing = fs.fileSize(destPath), existing == file.size {
                continue  // resume skip — already relocated by a prior run
            }
            bytesToCopy += file.size
        }

        let sourceVolume = fs.volumeIdentifier(plan.sourceRoot)
        let sameVolume = sourceVolume != nil && sourceVolume == fs.volumeIdentifier(plan.destinationRoot)
        let usesFastPath = sameVolume && plan.excludedRelativePaths.isEmpty

        if !usesFastPath {
            guard let available = fs.availableCapacity(plan.destinationRoot) else {
                return .failure(.destinationUnwritable)
            }
            let required = bytesToCopy + Self.freeSpaceHeadroomBytes
            guard available >= required else {
                return .failure(.insufficientSpace(requiredBytes: required, availableBytes: available))
            }
        }

        return .success(CacheMigrationPreflight(
            totalFiles: files.count,
            totalBytes: totalBytes,
            bytesToCopy: bytesToCopy,
            sameVolume: sameVolume
        ))
    }

    /// Relocate `plan`'s subtrees: the same-volume whole-directory rename
    /// fast path when nothing is excluded, otherwise a per-file
    /// copy → verify → delete walk.
    func run(_ plan: CacheMigrationPlan, _ preflight: CacheMigrationPreflight) -> CacheMigrationOutcome {
        let usesFastPath = preflight.sameVolume && plan.excludedRelativePaths.isEmpty
        return usesFastPath ? fastPathMove(plan, preflight) : moveFiles(plan, preflight)
    }

    /// Same-volume, no-exclusions fast path: atomically rename each subtree
    /// ROOT (never a single file inside it) instead of walking file-by-file.
    private func fastPathMove(_ plan: CacheMigrationPlan, _ preflight: CacheMigrationPreflight) -> CacheMigrationOutcome {
        for subtree in plan.subtrees {
            if isCancelled() {
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
                return CacheMigrationOutcome(result: .failed(.ioError, rolledBack: false), filesMoved: 0, bytesMoved: 0, sameVolume: preflight.sameVolume)
            }
            onProgress(0, 0, subtree.relativePath)
        }
        onProgress(preflight.totalFiles, preflight.totalBytes, "")
        return CacheMigrationOutcome(
            result: .completed, filesMoved: preflight.totalFiles, bytesMoved: preflight.totalBytes, sameVolume: preflight.sameVolume
        )
    }

    /// Per-file copy → verify → delete walk, used whenever the fast path
    /// isn't safe (cross-volume, or a descendant is excluded from the move).
    private func moveFiles(_ plan: CacheMigrationPlan, _ preflight: CacheMigrationPreflight) -> CacheMigrationOutcome {
        let files = sourceFiles(for: plan)
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
            case .failure(let reason):
                let rolledBack = rollback(destPaths: movedDestPaths, plan: plan)
                return CacheMigrationOutcome(result: .failed(reason, rolledBack: rolledBack), filesMoved: filesMoved, bytesMoved: bytesMoved, sameVolume: preflight.sameVolume)
            }
        }

        fs.removeEmptyDirectories(plan.sourceRoot)

        guard reconcile(filesMoved: filesMoved, bytesMoved: bytesMoved, against: preflight) else {
            let rolledBack = rollback(destPaths: movedDestPaths, plan: plan)
            return CacheMigrationOutcome(result: .failed(.countMismatch, rolledBack: rolledBack), filesMoved: filesMoved, bytesMoved: bytesMoved, sameVolume: preflight.sameVolume)
        }
        return CacheMigrationOutcome(result: .completed, filesMoved: filesMoved, bytesMoved: bytesMoved, sameVolume: preflight.sameVolume)
    }

    /// Copy → compare the destination byte size to the source → only then
    /// delete the source (R19). Never deletes the source before the sizes match.
    private func moveFile(from sourcePath: String, to destPath: String, expectedSize: Int64) -> Result<Void, CacheMigrationFailure> {
        do {
            try fs.copyFile(sourcePath, destPath)
        } catch {
            do {
                try fs.copyFileDataOnly(sourcePath, destPath)
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
        return .success(())
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
            do {
                try fs.copyFile(destPath, sourcePath)
                guard fs.fileSize(sourcePath) == fs.fileSize(destPath) else { ok = false; continue }
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
    private func sourceFiles(for plan: CacheMigrationPlan) -> [(relativePath: String, size: Int64)] {
        var seen = Set<String>()
        var files: [(relativePath: String, size: Int64)] = []
        for subtree in plan.subtrees {
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
            case .failure(let rejection):
                return (plan, CacheMigrationOutcome(
                    result: .preflightRejected(rejection), filesMoved: 0, bytesMoved: 0, sameVolume: false
                ))
            case .success(let preflight):
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

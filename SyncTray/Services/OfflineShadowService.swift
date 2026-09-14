import Foundation

// MARK: - Injected filesystem

/// Every filesystem primitive the offline-shadow engine needs, injected so
/// `ConfigSelfTest` can drive it against an inert fake — no real disk I/O —
/// mirroring `CacheMigrationFileSystem`'s struct-of-closures idiom.
struct OfflineShadowFileSystem {
    var fileExists: (String) -> Bool
    var isSymlink: (String) -> Bool
    var directoryExists: (String) -> Bool
    var directoryIsEmpty: (String) -> Bool
    /// Relative paths of every REGULAR file under `root` (recursive).
    var listFiles: (_ root: String) -> [String]
    var fileSize: (String) -> Int64?
    /// `st_blocks * 512` — the allocated-bytes signal the R19 sparse guard
    /// needs. Falls back to `fileSize` for a filesystem/fake that can't
    /// report allocation (never UNDER-reports, so the guard degrades safe).
    var allocatedBytes: (String) -> Int64?
    var createSymbolicLink: (_ atPath: String, _ withDestinationPath: String) throws -> Void
    var removeItem: (String) throws -> Void
    var createDirectory: (String) throws -> Void
    var moveItem: (_ from: String, _ to: String) throws -> Void
    /// Copies file DATA from `from` to `to`. In production this is a
    /// same-host chunked copy; when `to` is under a mounted profile's
    /// `localSyncPath` this is the "write through the mount" step (D4) that
    /// hands the bytes to rclone's VFS write-back.
    var copyFileData: (_ from: String, _ to: String) throws -> Void
    var writeTextFile: (_ path: String, _ contents: String) throws -> Void
    var readTextFile: (String) -> String?

    /// The real filesystem. Uses the classic `stat(2)` call (via
    /// `FileManager.attributesOfItem`, which surfaces `.systemNumber` /
    /// `.size` but NOT block-count) for `allocatedBytes`, so that one
    /// specifically shells out to `stat(2)` directly — Foundation has no
    /// `FileAttributeKey` for `st_blocks`.
    static func production() -> OfflineShadowFileSystem {
        let fm = FileManager.default
        return OfflineShadowFileSystem(
            fileExists: { fm.fileExists(atPath: $0) },
            isSymlink: { path in
                (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
            },
            directoryExists: { path in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            },
            directoryIsEmpty: { path in
                (try? fm.contentsOfDirectory(atPath: path))?.isEmpty ?? true
            },
            listFiles: { root in
                guard let enumerator = fm.enumerator(atPath: root) else { return [] }
                var results: [String] = []
                while let rel = enumerator.nextObject() as? String {
                    let full = (root as NSString).appendingPathComponent(rel)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
                    results.append(rel)
                }
                return results
            },
            fileSize: { path in
                (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64
            },
            allocatedBytes: { path in
                var st = stat()
                guard stat(path, &st) == 0 else { return nil }
                return Int64(st.st_blocks) * 512
            },
            createSymbolicLink: { atPath, target in
                try fm.createSymbolicLink(atPath: atPath, withDestinationPath: target)
            },
            removeItem: { path in try fm.removeItem(atPath: path) },
            createDirectory: { path in
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            },
            moveItem: { from, to in try fm.moveItem(atPath: from, toPath: to) },
            copyFileData: { from, to in
                // Chunked, mirroring `CacheMigrationFileSystem.copyFileDataOnly` —
                // a whole-file-in-memory copy is unsafe for a large offline file.
                guard fm.createFile(atPath: to, contents: nil) else {
                    throw OfflineShadowIOError.writeFailed
                }
                guard let reader = FileHandle(forReadingAtPath: from) else {
                    throw OfflineShadowIOError.readFailed
                }
                defer { try? reader.close() }
                guard let writer = FileHandle(forWritingAtPath: to) else {
                    throw OfflineShadowIOError.writeFailed
                }
                defer { try? writer.close() }
                let chunkSize = 4 * 1024 * 1024
                while true {
                    guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                    try writer.write(contentsOf: chunk)
                }
            },
            writeTextFile: { path, contents in
                try contents.write(toFile: path, atomically: true, encoding: .utf8)
            },
            readTextFile: { path in try? String(contentsOfFile: path, encoding: .utf8) }
        )
    }
}

enum OfflineShadowIOError: Error {
    case readFailed
    case writeFailed
}

// MARK: - Engine

enum OfflineShadowService {
    // MARK: P1 — shadow link

    /// Resolve a `ShadowLinkDecision` from disk state via the injected `fs`
    /// (the impure boundary; the truth table itself lives in
    /// `OfflineShadowPlanner.shadowLinkDecision`, pure and self-tested).
    static func shadowLinkDecision(dataRoot: String, isMounted: Bool, fs: OfflineShadowFileSystem) -> ShadowLinkDecision {
        let exists = fs.directoryExists(dataRoot)
        let nonEmpty = exists && !fs.directoryIsEmpty(dataRoot)
        return OfflineShadowPlanner.shadowLinkDecision(
            isMounted: isMounted, cacheDataDirExists: exists, cacheDataDirNonEmpty: nonEmpty, dataRoot: dataRoot
        )
    }

    /// Execute a `ShadowLinkDecision` at `mountPath`. `.skip` is a no-op.
    /// `.create` replaces whatever is currently at `mountPath` (expected to
    /// be the empty mountpoint directory, or a stale shadow from a previous
    /// session) with a symlink to `target`. Throws are the CALLER's to
    /// catch — `SyncManager.unmountProfile` wraps this in a `do/catch` that
    /// logs and continues (AC-OFF8), so a failure here can never block an
    /// unmount.
    static func applyShadowLink(_ decision: ShadowLinkDecision, mountPath: String, fs: OfflineShadowFileSystem) throws {
        guard case .create(let target) = decision else { return }
        if fs.isSymlink(mountPath) || fs.fileExists(mountPath) {
            try fs.removeItem(mountPath)
        }
        try fs.createSymbolicLink(mountPath, target)
    }

    /// Defensive teardown of a shadow symlink left at the mountpoint, mirroring
    /// the generated script's own guard (D2) — belt-and-braces for a
    /// Swift-driven mount attempt that might race ahead of (or run instead
    /// of) the script's own teardown. Best-effort; never throws.
    static func tearDownShadowLink(mountPath: String, fs: OfflineShadowFileSystem) {
        if fs.isSymlink(mountPath) {
            try? fs.removeItem(mountPath)
        }
    }

    // MARK: D6 — unmount marker + auxiliary roots

    /// The `vfsPending`/`vfsOffline` subtree roots for a profile, mirroring
    /// `VFSCacheService.cacheSubtreeRoots(for:)`'s key derivation so all
    /// four trees (`vfs`, `vfsMeta`, `vfsPending`, `vfsOffline`) can never
    /// disagree about which subtree a profile owns.
    static func auxiliaryRoots(for profile: SyncProfile) -> (pending: String, offline: String) {
        let base = (profile.vfsCachePath as NSString).expandingTildeInPath
        let key = VFSCacheService.cacheRelativePath(for: profile)
        let pending = ((base as NSString).appendingPathComponent("vfsPending") as NSString).appendingPathComponent(key)
        let offline = ((base as NSString).appendingPathComponent("vfsOffline") as NSString).appendingPathComponent(key)
        return (pending, offline)
    }

    static func unmountMarkerPath(offlineRoot: String) -> String {
        (offlineRoot as NSString).appendingPathComponent("unmounted-at")
    }

    static func writeUnmountMarker(at path: String, timestamp: Date, fs: OfflineShadowFileSystem) throws {
        let parent = (path as NSString).deletingLastPathComponent
        if !fs.directoryExists(parent) {
            try fs.createDirectory(parent)
        }
        try fs.writeTextFile(path, ISO8601DateFormatter().string(from: timestamp))
    }

    /// Best-effort; never throws — a failure to clear the marker just means
    /// the next mount's sweep re-scans (idempotent, if slightly wasteful).
    static func clearUnmountMarker(at path: String, fs: OfflineShadowFileSystem) {
        try? fs.removeItem(path)
    }

    static func hasPendingFiles(pendingRoot: String, fs: OfflineShadowFileSystem) -> Bool {
        fs.directoryExists(pendingRoot) && !fs.directoryIsEmpty(pendingRoot)
    }

    // MARK: P2 — scan / stage (Swift-side mirror; production staging is the bash sweep, D3)

    /// Scan `dataRoot` for offline-authored candidates and build their
    /// `OfflineFileFacts`. This is the Swift-side MIRROR of the bash
    /// staging sweep's decision (used by self-test to prove the two agree,
    /// and available as a future non-script entry point) — production
    /// staging runs in the generated sync script BEFORE Swift ever sees a
    /// mount (D3: deterministic, app-independent, closes the
    /// launchd-without-app race).
    static func scanOfflineAuthored(dataRoot: String, metaRoot: String, fs: OfflineShadowFileSystem) -> [OfflineScanEntry] {
        fs.listFiles(dataRoot).map { rel in
            let dataPath = (dataRoot as NSString).appendingPathComponent(rel)
            let metaPath = (metaRoot as NSString).appendingPathComponent(rel)
            let hasSidecar = fs.fileExists(metaPath)
            let size = fs.fileSize(dataPath) ?? 0
            let allocated = fs.allocatedBytes(dataPath) ?? size
            var meta: VFSCacheService.VFSCacheMeta?
            if hasSidecar, let raw = fs.readTextFile(metaPath), let data = raw.data(using: .utf8) {
                meta = try? JSONDecoder().decode(VFSCacheService.VFSCacheMeta.self, from: data)
            }
            let facts = OfflineFileFacts(
                relativePath: rel,
                name: (rel as NSString).lastPathComponent,
                hasSidecar: hasSidecar,
                dataSize: size,
                allocatedBytes: allocated,
                sidecarMeta: meta
            )
            return OfflineScanEntry(facts: facts)
        }
    }

    /// Move each planned upload out of `dataRoot` into `pendingRoot` via a
    /// same-volume RENAME (R5 — zero extra disk, no duplication of
    /// already-cached data). The Swift-side mirror of the bash sweep's `mv`
    /// step; production staging is the script (D3).
    static func stagePending(plan: OfflineReconcilePlan, dataRoot: String, pendingRoot: String, fs: OfflineShadowFileSystem) {
        for rel in plan.uploads {
            let source = (dataRoot as NSString).appendingPathComponent(rel)
            let dest = (pendingRoot as NSString).appendingPathComponent(rel)
            let parent = (dest as NSString).deletingLastPathComponent
            if !fs.directoryExists(parent) {
                try? fs.createDirectory(parent)
            }
            try? fs.moveItem(source, dest)
        }
    }

    // MARK: P2 — injection (D4)

    /// Copy each staged file (`pendingRoot`) through the live mount into
    /// `localSyncPath`, so rclone caches it dirty and write-backs to the
    /// remote. The staged copy is deleted ONLY once a `vfsMeta` sidecar
    /// appears for it at `metaRoot` — proof rclone accepted the write into
    /// its own cache. A write that fails, or whose handoff hasn't been
    /// confirmed yet, RETAINS the staged copy so nothing is ever lost.
    @discardableResult
    static func inject(pendingRoot: String, metaRoot: String, localSyncPath: String, fs: OfflineShadowFileSystem) -> (injected: Int, retained: Int) {
        var injected = 0
        var retained = 0
        for rel in fs.listFiles(pendingRoot) {
            let staged = (pendingRoot as NSString).appendingPathComponent(rel)
            let dest = (localSyncPath as NSString).appendingPathComponent(rel)
            let destParent = (dest as NSString).deletingLastPathComponent
            if !fs.directoryExists(destParent) {
                try? fs.createDirectory(destParent)
            }
            do {
                try fs.copyFileData(staged, dest)
            } catch {
                retained += 1
                continue
            }
            let metaPath = (metaRoot as NSString).appendingPathComponent(rel)
            if fs.fileExists(metaPath) {
                try? fs.removeItem(staged)
                injected += 1
            } else {
                retained += 1
            }
        }
        return (injected, retained)
    }
}

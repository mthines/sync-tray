import Foundation

/// Owns the Cache-only **overlay** — the writable directory a cache-only union mount
/// checks FIRST, so every new file and every edit lands there instead of touching the
/// read-only streaming cache — and the engine that pushes those files to the remote.
///
/// Two upload flows share the same planner and execution core:
///  - **Drain** (leaving Cache Only, either via "Resume Syncing" or automatically):
///    upload, verify, then DELETE the overlay copy.
///  - **Keep** ("Upload Now", staying in Cache Only): upload, verify, KEEP the overlay
///    copy, and record a manifest entry so a later run treats it as already uploaded
///    instead of re-uploading or re-deciding.
///
/// Mirrors `CacheMigrationService`'s shape: an injected dependency protocol
/// (`OverlayRemoteClient`) for the network edge, a pure static planner, and an `async`
/// run method — so the planner is unit-testable with no process/network, and the
/// engine is testable against REAL rclone pointed at a local-dir remote.
struct OverlaySyncService {
    init() {}

    // MARK: - Ignore list

    /// Names never treated as pending overlay content: pure macOS/Finder noise and
    /// rclone's own partial-transfer marker. The SAME list is interpolated into the
    /// sync script's Python (D6/D18) so the two layers can never disagree about what
    /// counts as "not really a user file".
    static let ignoredNamePatterns: [String] = [
        ".DS_Store", "._*", ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", "*.partial",
    ]

    /// Minimal single-segment glob (`*` = any run of characters within this ONE
    /// filename — there is no path separator to consider, since this only ever
    /// compares a bare last-path-component).
    nonisolated static func isIgnored(name: String) -> Bool {
        ignoredNamePatterns.contains { matches(pattern: $0, name: name) }
    }

    private static func matches(pattern: String, name: String) -> Bool {
        guard pattern.contains("*") else { return pattern == name }
        let parts = pattern.components(separatedBy: "*")
        var remainder = Substring(name)
        for (i, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if i == 0 {
                guard remainder.hasPrefix(part) else { return false }
                remainder = remainder.dropFirst(part.count)
            } else if i == parts.count - 1 {
                return remainder.hasSuffix(part)
            } else {
                guard let range = remainder.range(of: part) else { return false }
                remainder = remainder[range.upperBound...]
            }
        }
        return true
    }

    // MARK: - Scanning

    /// POSIX `realpath()` — see `scan`'s doc comment for why this, and not any Foundation
    /// path-resolution API, is required here. Falls back to the input unchanged if the path
    /// doesn't exist or resolution otherwise fails (matches `scan`'s own guard: a missing
    /// root is handled by the caller, not here).
    nonisolated static func canonicalPath(_ path: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    struct OverlayFile: Equatable {
        let relativePath: String  // mount-relative, no leading slash, "/" separators
        let absolutePath: String
        let size: Int64
        let modificationDate: Date
    }

    /// Recursively list every regular file under the overlay directory, skipping
    /// ignored names (and everything beneath an ignored directory) at any depth.
    nonisolated static func scan(
        overlayPath: String, fileManager: FileManager = .default
    ) -> [OverlayFile] {
        guard fileManager.fileExists(atPath: overlayPath) else { return [] }
        // Resolve symlinks in the ROOT before enumerating: `FileManager.enumerator` returns
        // each descendant's REAL (symlink-resolved) path, e.g. under macOS's `/tmp` ->
        // `/private/tmp` and `/var` -> `/private/var` — while a caller-supplied `overlayPath`
        // (typically built from `NSTemporaryDirectory()` in tests, or a user-chosen cache
        // directory that traverses a symlink) may not be. Deriving `prefixLen` from the
        // UNresolved string while the enumerator hands back resolved paths silently
        // mis-slices every relative path. Resolving once up front keeps the two in lockstep.
        //
        // Deliberately the POSIX `realpath()`, NOT `NSString.resolvingSymlinksInPath` /
        // `URL.resolvingSymlinksInPath()` — both Foundation APIs special-case `/tmp`, `/var`,
        // `/etc` and leave them UNresolved (a long-standing Apple compatibility carve-out),
        // which silently reproduces this exact bug for any path built from
        // `NSTemporaryDirectory()`. `realpath()` has no such carve-out.
        let resolvedRoot = canonicalPath(overlayPath)
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: resolvedRoot),
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ]
        ) else { return [] }

        var results: [OverlayFile] = []
        let prefixLen = resolvedRoot.count + 1
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if isIgnored(name: name) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ]), values.isRegularFile == true else { continue }

            let path = url.path
            guard path.count > prefixLen else { continue }
            let rel = String(path.dropFirst(prefixLen))
            results.append(OverlayFile(
                relativePath: rel,
                absolutePath: path,
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            ))
        }
        return results
    }

    /// Overlay files (ignore list applied) not yet recorded as uploaded in the
    /// manifest — the guard R16/D12 uses to refuse a cache-directory move.
    nonisolated static func pendingCount(
        overlayPath: String, manifest: [String: ManifestEntry], fileManager: FileManager = .default
    ) -> Int {
        scan(overlayPath: overlayPath, fileManager: fileManager)
            .filter { manifest[$0.relativePath] == nil }
            .count
    }

    // MARK: - Manifest

    /// One overlay file already pushed to the remote by "Upload Now" (kept in the
    /// overlay). Recorded so a later run can tell an unchanged uploaded file (skip)
    /// from one that changed since (re-upload).
    struct ManifestEntry: Codable, Equatable {
        var localSize: Int64
        var localModTime: Date
        var remoteSize: Int64
        var remoteModTime: Date
        var uploadedAs: String
        var uploadedAt: Date
    }

    nonisolated static func loadManifest(path: String, fileManager: FileManager = .default) -> [String: ManifestEntry] {
        guard let data = fileManager.contents(atPath: path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: ManifestEntry].self, from: data)) ?? [:]
    }

    @discardableResult
    nonisolated static func saveManifest(
        _ manifest: [String: ManifestEntry], path: String, fileManager: FileManager = .default
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(manifest) else { return false }
        try? fileManager.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    // MARK: - Remote fingerprint

    /// The remote state (size + modtime) a cache entry's `vfsMeta` `Fingerprint` field
    /// records, e.g. `"356508,2024-10-10 07:08:11 +0000 UTC"` or with fractional
    /// seconds `"356508,2024-10-10 07:08:11.123456789 +0000 UTC"` (Go's default
    /// `time.Time.String()` shape; the trailing zone abbreviation is ignored — the
    /// numeric offset is authoritative). An optional trailing `,<hash>` is ignored too.
    struct RemoteState: Equatable {
        let size: Int64
        let modTime: Date
    }

    private static let fingerprintRegex = try! NSRegularExpression(
        pattern: #"^(\d+),(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})(?:\.\d+)? ([+-]\d{4}) \S+"#
    )

    nonisolated static func parseFingerprint(_ fingerprint: String) -> RemoteState? {
        let range = NSRange(fingerprint.startIndex..., in: fingerprint)
        guard let match = fingerprintRegex.firstMatch(in: fingerprint, range: range) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: fingerprint) else { return nil }
            return String(fingerprint[r])
        }
        guard let sizeStr = group(1), let size = Int64(sizeStr),
              let dateStr = group(2), let timeStr = group(3), let offsetStr = group(4)
        else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        guard let date = formatter.date(from: "\(dateStr) \(timeStr) \(offsetStr)") else { return nil }
        return RemoteState(size: size, modTime: date)
    }

    // MARK: - Conflict naming

    /// `dir/stem.sync-conflict-YYYYMMDD-HHMMSS.ext` (local time; last extension only —
    /// a dotfile or extensionless name gets the suffix appended to the whole name).
    /// `existing` is asked (network lookup, injected) whether a candidate relative
    /// path is already taken remotely; `-2`, `-3`, … are appended until it says no.
    nonisolated static func conflictName(
        for relativePath: String, date: Date, existing: (String) -> Bool
    ) -> String {
        let ns = relativePath as NSString
        let dir = ns.deletingLastPathComponent
        let filename = ns.lastPathComponent
        let ext = (filename as NSString).pathExtension
        let stem = ext.isEmpty ? filename : String(filename.dropLast(ext.count + 1))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)

        func candidate(suffix: String) -> String {
            let base = "\(stem).sync-conflict-\(stamp)\(suffix)"
            let name = ext.isEmpty ? base : "\(base).\(ext)"
            return dir.isEmpty ? name : "\(dir)/\(name)"
        }

        var counter = 2
        var result = candidate(suffix: "")
        while existing(result) {
            result = candidate(suffix: "-\(counter)")
            counter += 1
        }
        return result
    }

    // MARK: - Planner

    enum OverlayAction: Equatable {
        case alreadyUploaded
        case upload(dest: String)
        case uploadConflict(dest: String)
    }

    enum UploadMode: Equatable { case drain, keep }

    /// Pure decision for one overlay file — no I/O, no network. `expected` is the
    /// remote state this file was fetched/uploaded against (manifest entry, else the
    /// cached base file's fingerprint, else absent — "new file"); `remote` is what a
    /// (network) listing actually found there right now.
    nonisolated static func plan(
        file: OverlayFile,
        manifestEntry: ManifestEntry?,
        expected: RemoteState?,
        remote: RemoteState?,
        now: Date = Date()
    ) -> OverlayAction {
        if let manifestEntry,
           manifestEntry.localSize == file.size,
           abs(manifestEntry.localModTime.timeIntervalSince(file.modificationDate)) <= 1 {
            return .alreadyUploaded
        }
        guard let remote else {
            return .upload(dest: file.relativePath)
        }
        guard let expected else {
            // Present remote, unparseable/absent expected fingerprint — safe direction.
            return .uploadConflict(dest: file.relativePath)
        }
        if remote.size == expected.size, abs(remote.modTime.timeIntervalSince(expected.modTime)) <= 1 {
            return .upload(dest: file.relativePath)
        }
        return .uploadConflict(dest: file.relativePath)
    }

    // MARK: - Remote client

    enum OverlayUploadError: Error, Equatable {
        case unreachable
        case timedOut
        case verifyMismatch(expected: Int64, actual: Int64)
        case rcloneFailed(exitCode: Int32)
    }

    struct RemoteEntry: Equatable {
        let name: String
        let size: Int64
        let modTime: Date
    }

    protocol OverlayRemoteClient {
        /// Non-recursive listing of one remote directory (mount-relative to the
        /// profile's remote path). Empty directory / not-found (rclone `lsjson` exit
        /// 3) is `.success([])`, never an error.
        func listFiles(remoteDir: String) -> Result<[RemoteEntry], OverlayUploadError>

        /// Upload `localPath` to `remoteDestination` (a full `remote:path` string) and
        /// verify the result. Returns `.success` ONLY once the remote's reported size
        /// after upload matches `expectedSize`.
        func upload(
            localPath: String, remoteDestination: String, expectedSize: Int64
        ) -> Result<Void, OverlayUploadError>
    }

    // MARK: - Progress / Result

    struct OverlayUploadProgress: Equatable {
        var filesDone: Int
        var filesTotal: Int
        var bytesDone: Int64
        var bytesTotal: Int64
    }

    struct OverlayUploadResult: Equatable {
        var uploaded: Int = 0
        var conflicts: Int = 0
        var alreadyUploaded: Int = 0
        var failed: Int = 0
        var bytes: Int64 = 0
        var remainingPending: Int = 0
        var transport: String = "none"  // "primary" | "fallback" | "none"
    }

    // MARK: - Engine

    /// Run the upload engine for one profile's overlay against the given remote
    /// (already-resolved `remote:path` string — primary or fallback), in `.drain`
    /// (leaving Cache Only) or `.keep` (Upload Now) mode.
    func run(
        profile: SyncProfile,
        remoteBase: String,
        mode: UploadMode,
        transport: String,
        client: OverlayRemoteClient,
        now: Date = Date(),
        fileManager: FileManager = .default,
        progress: ((OverlayUploadProgress) -> Void)? = nil
    ) async -> OverlayUploadResult {
        var manifest = Self.loadManifest(path: profile.overlayManifestPath, fileManager: fileManager)
        var result = OverlayUploadResult()
        result.transport = transport

        var files = Self.scan(overlayPath: profile.overlayPath, fileManager: fileManager)
        if mode == .keep {
            // Still being written — leave pending rather than racing an in-flight save.
            files = files.filter { now.timeIntervalSince($0.modificationDate) >= 30 }
        }

        let cacheRoots = VFSCacheService.shared.cacheSubtreeRoots(for: profile)
        let bytesTotal = files.reduce(Int64(0)) { $0 + $1.size }
        var bytesDone: Int64 = 0
        progress?(OverlayUploadProgress(filesDone: 0, filesTotal: files.count, bytesDone: 0, bytesTotal: bytesTotal))

        var dirListingCache: [String: Result<[RemoteEntry], OverlayUploadError>] = [:]
        func listing(for dir: String) -> Result<[RemoteEntry], OverlayUploadError> {
            if let cached = dirListingCache[dir] { return cached }
            let fetched = client.listFiles(remoteDir: dir)
            dirListingCache[dir] = fetched
            return fetched
        }

        for (index, file) in files.enumerated() {
            defer {
                progress?(OverlayUploadProgress(
                    filesDone: index + 1, filesTotal: files.count, bytesDone: bytesDone, bytesTotal: bytesTotal))
            }

            let dir = (file.relativePath as NSString).deletingLastPathComponent
            let baseName = ((file.relativePath as NSString).lastPathComponent)
                .precomposedStringWithCanonicalMapping
            var remoteEntry: RemoteEntry?
            if case .success(let entries) = listing(for: dir) {
                remoteEntry = entries.first { $0.name.precomposedStringWithCanonicalMapping == baseName }
            }
            let remoteState = remoteEntry.map { RemoteState(size: $0.size, modTime: $0.modTime) }

            var expected: RemoteState?
            if let entry = manifest[file.relativePath] {
                expected = RemoteState(size: entry.remoteSize, modTime: entry.remoteModTime)
            } else {
                let metaPath = (cacheRoots.meta as NSString).appendingPathComponent(file.relativePath)
                if let metaData = fileManager.contents(atPath: metaPath),
                   let meta = try? JSONDecoder().decode(VFSCacheService.VFSCacheMeta.self, from: metaData),
                   let fingerprint = meta.Fingerprint {
                    expected = Self.parseFingerprint(fingerprint)
                }
            }

            let action = Self.plan(
                file: file, manifestEntry: manifest[file.relativePath],
                expected: expected, remote: remoteState, now: now)

            switch action {
            case .alreadyUploaded:
                result.alreadyUploaded += 1
                if mode == .drain {
                    try? fileManager.removeItem(atPath: file.absolutePath)
                    manifest.removeValue(forKey: file.relativePath)
                }

            case .upload(let dest), .uploadConflict(let dest):
                var finalDest = dest
                let isConflict: Bool
                if case .uploadConflict = action {
                    isConflict = true
                    finalDest = Self.conflictName(for: dest, date: now) { candidate in
                        let candidateDir = (candidate as NSString).deletingLastPathComponent
                        let candidateName = ((candidate as NSString).lastPathComponent)
                            .precomposedStringWithCanonicalMapping
                        if case .success(let entries) = listing(for: candidateDir) {
                            return entries.contains {
                                $0.name.precomposedStringWithCanonicalMapping == candidateName
                            }
                        }
                        return false
                    }
                } else {
                    isConflict = false
                }

                let remoteDestination = "\(remoteBase)/\(finalDest)"
                switch client.upload(
                    localPath: file.absolutePath, remoteDestination: remoteDestination, expectedSize: file.size
                ) {
                case .success:
                    if isConflict { result.conflicts += 1 } else { result.uploaded += 1 }
                    result.bytes += file.size
                    bytesDone += file.size
                    if mode == .drain {
                        try? fileManager.removeItem(atPath: file.absolutePath)
                        // A CLEAN (non-Dirty) shadowed base cache entry is now stale —
                        // delete it so it can't resurface in a later Cache-only session.
                        // A Dirty one is an unsynced streaming recording; leave it, rclone
                        // uploads it when streaming resumes.
                        let dataPath = (cacheRoots.data as NSString).appendingPathComponent(file.relativePath)
                        let metaPath = (cacheRoots.meta as NSString).appendingPathComponent(file.relativePath)
                        if let metaData = fileManager.contents(atPath: metaPath),
                           let meta = try? JSONDecoder().decode(VFSCacheService.VFSCacheMeta.self, from: metaData),
                           meta.Dirty != true {
                            try? fileManager.removeItem(atPath: dataPath)
                            try? fileManager.removeItem(atPath: metaPath)
                        }
                        manifest.removeValue(forKey: file.relativePath)
                    } else {
                        manifest[file.relativePath] = ManifestEntry(
                            localSize: file.size,
                            localModTime: file.modificationDate,
                            remoteSize: file.size,
                            remoteModTime: now,
                            uploadedAs: finalDest,
                            uploadedAt: now
                        )
                    }
                case .failure:
                    result.failed += 1
                }
            }
        }

        Self.saveManifest(manifest, path: profile.overlayManifestPath, fileManager: fileManager)
        if mode == .drain {
            Self.removeEmptyDirectories(under: profile.overlayPath, fileManager: fileManager)
        }
        result.remainingPending = Self.pendingCount(
            overlayPath: profile.overlayPath, manifest: manifest, fileManager: fileManager)
        return result
    }

    /// Remove now-empty directories left behind by a drain, bottom-up (deepest first)
    /// so a parent only empties out after its children are gone. Never removes the
    /// overlay root itself.
    private static func removeEmptyDirectories(under root: String, fileManager: FileManager) {
        guard let enumerator = fileManager.enumerator(atPath: root) else { return }
        var directories: [String] = []
        for case let rel as String in enumerator {
            let full = (root as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                directories.append(full)
            }
        }
        // Deepest paths first so a child empties before its parent is checked.
        for dir in directories.sorted(by: { $0.count > $1.count }) {
            if (try? fileManager.contentsOfDirectory(atPath: dir))?.isEmpty == true {
                try? fileManager.removeItem(atPath: dir)
            }
        }
    }

    // MARK: - Production remote client

    /// rclone-backed `OverlayRemoteClient`. `remoteName` is the bare remote (no
    /// trailing path) to run `lsjson`/`copyto` against; `remotePath` is the profile's
    /// remote path prefix every relative path is resolved beneath.
    struct ProductionOverlayRemoteClient: OverlayRemoteClient {
        let remoteName: String
        let remotePath: String
        let noCheckCertificate: Bool
        let timeout: TimeInterval

        init(remoteName: String, remotePath: String, noCheckCertificate: Bool = false, timeout: TimeInterval = 60) {
            self.remoteName = remoteName
            self.remotePath = remotePath
            self.noCheckCertificate = noCheckCertificate
            self.timeout = timeout
        }

        private func fullPath(_ dir: String) -> String {
            let trimmedRemote = remotePath.isEmpty ? "" : "\(remotePath)/"
            let combined = dir.isEmpty ? remotePath : "\(trimmedRemote)\(dir)"
            return "\(remoteName):\(combined)"
        }

        func listFiles(remoteDir: String) -> Result<[RemoteEntry], OverlayUploadError> {
            var args = ["lsjson", fullPath(remoteDir), "--files-only", "--no-mimetype"]
            if noCheckCertificate { args.append("--no-check-certificate") }
            let (exit, stdout, _) = CLIEnvironment.runRcloneProcess(args: args, timeout: timeout)
            if exit == 3 { return .success([]) }  // directory not found == empty
            guard exit == 0 else { return .failure(.rcloneFailed(exitCode: exit)) }
            guard let data = stdout.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return .success([]) }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]

            let entries: [RemoteEntry] = raw.compactMap { item in
                guard let name = item["Name"] as? String,
                      let size = (item["Size"] as? NSNumber)?.int64Value,
                      let modTimeStr = item["ModTime"] as? String,
                      let modTime = formatter.date(from: modTimeStr) ?? fallbackFormatter.date(from: modTimeStr)
                else { return nil }
                return RemoteEntry(name: name, size: size, modTime: modTime)
            }
            return .success(entries)
        }

        func upload(
            localPath: String, remoteDestination: String, expectedSize: Int64
        ) -> Result<Void, OverlayUploadError> {
            var args = [
                "copyto", localPath, remoteDestination,
                "--contimeout", "10s", "--timeout", "60s",
                "--retries", "2", "--low-level-retries", "3",
            ]
            if noCheckCertificate { args.append("--no-check-certificate") }
            // 120s floor + 64 KiB/s budget, mirroring the plan's watchdog formula.
            let watchdog = 120 + Double(expectedSize) / 65536.0
            let (exit, _, _) = CLIEnvironment.runRcloneProcess(args: args, timeout: watchdog)
            guard exit == 0 else { return .failure(.rcloneFailed(exitCode: exit)) }

            let (statExit, statOut, _) = CLIEnvironment.runRcloneProcess(
                args: ["lsjson", remoteDestination, "--stat"] + (noCheckCertificate ? ["--no-check-certificate"] : []),
                timeout: timeout)
            guard statExit == 0,
                  let data = statOut.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let actualSize = (obj["Size"] as? NSNumber)?.int64Value
            else { return .failure(.rcloneFailed(exitCode: statExit)) }

            guard actualSize == expectedSize else {
                return .failure(.verifyMismatch(expected: expectedSize, actual: actualSize))
            }
            return .success(())
        }
    }
}

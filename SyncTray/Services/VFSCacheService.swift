import Foundation

/// Represents a cached file or directory in the VFS cache
struct CachedItem: Identifiable, Comparable {
    let id: String  // relative path
    let name: String
    let relativePath: String
    let fullPath: String
    let size: Int64
    let modifiedDate: Date
    let isDirectory: Bool

    static func < (lhs: CachedItem, rhs: CachedItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory  // directories first
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

/// Summary of VFS cache usage for a profile
struct CacheStats {
    let totalSize: Int64
    let fileCount: Int
    let directoryCount: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

/// Service for managing rclone VFS cache files and RC API interactions
final class VFSCacheService {
    static let shared = VFSCacheService()

    private init() {}

    // MARK: - Cache Directory Scanning

    /// Get the VFS cache directory path for a profile's remote
    func cacheDirectory(for profile: SyncProfile) -> String? {
        let baseCachePath = profile.vfsCachePath
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseCachePath) else { return nil }

        // rclone stores VFS cache in: {cache-dir}/vfs/{remote-name}/
        // The remote name has the colon stripped
        let vfsDir = (baseCachePath as NSString).appendingPathComponent("vfs")
        guard fm.fileExists(atPath: vfsDir) else { return nil }

        // Try to find the remote's cache directory
        let remoteName = profile.rcloneRemote.replacingOccurrences(of: ":", with: "")
        let remoteDir = (vfsDir as NSString).appendingPathComponent(remoteName)

        if fm.fileExists(atPath: remoteDir) {
            // If remotePath is set, check subdirectory
            if !profile.remotePath.isEmpty {
                let fullPath = (remoteDir as NSString).appendingPathComponent(profile.remotePath)
                if fm.fileExists(atPath: fullPath) {
                    return fullPath
                }
            }
            return remoteDir
        }

        return nil
    }

    /// Ask the running mount for the authoritative on-disk cache location and totals via
    /// the RC API. This is correct even when the mount is running on the **fallback**
    /// remote: rclone keys the disk cache by the *active* remote name, so the path guessed
    /// from `profile.rcloneRemote` (the primary) points at an empty directory after a
    /// failover. `/vfs/stats` → `diskCache` reports the real path and counts regardless.
    func rcDiskCache(port: Int) async -> (path: String, files: Int, bytes: Int64)? {
        guard port > 0,
              let stats = try? await getVFSStats(port: port),
              let disk = stats["diskCache"] as? [String: Any],
              let path = disk["path"] as? String else { return nil }
        let files = (disk["files"] as? NSNumber)?.intValue ?? 0
        let bytes = (disk["bytesUsed"] as? NSNumber)?.int64Value ?? 0
        return (path, files, bytes)
    }

    /// Resolve the on-disk cache directory, preferring the mount's live RC report (which
    /// is fallback-aware) and falling back to the primary-remote path guess when RC is
    /// unavailable (mount not up).
    func resolvedCacheDirectory(for profile: SyncProfile) async -> String? {
        if let rc = await rcDiskCache(port: profile.rcPort) { return rc.path }
        return cacheDirectory(for: profile)
    }

    /// RC-aware cache stats — scans the directory the live mount actually uses.
    func resolvedCacheStats(for profile: SyncProfile) async -> CacheStats {
        guard let baseDir = await resolvedCacheDirectory(for: profile) else {
            return CacheStats(totalSize: 0, fileCount: 0, directoryCount: 0)
        }
        return scanCacheStats(baseDir: baseDir)
    }

    /// RC-aware cached-item listing — lists from the directory the live mount actually uses.
    func resolvedCachedItems(for profile: SyncProfile, at relativePath: String = "") async -> [CachedItem] {
        guard let baseDir = await resolvedCacheDirectory(for: profile) else { return [] }
        return scanCachedItems(baseDir: baseDir, at: relativePath)
    }

    /// Scan the VFS cache for a profile and return cached items at the given relative path
    func listCachedItems(for profile: SyncProfile, at relativePath: String = "") -> [CachedItem] {
        guard let baseDir = cacheDirectory(for: profile) else { return [] }
        return scanCachedItems(baseDir: baseDir, at: relativePath)
    }

    /// List cached items under `baseDir` at `relativePath` (shared by the sync and
    /// RC-aware entry points).
    private func scanCachedItems(baseDir: String, at relativePath: String) -> [CachedItem] {
        let scanDir: String
        if relativePath.isEmpty {
            scanDir = baseDir
        } else {
            scanDir = (baseDir as NSString).appendingPathComponent(relativePath)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: scanDir) else { return [] }

        do {
            let contents = try fm.contentsOfDirectory(atPath: scanDir)
            return contents.compactMap { name -> CachedItem? in
                // Skip hidden/metadata files
                guard !name.hasPrefix(".") else { return nil }

                let fullPath = (scanDir as NSString).appendingPathComponent(name)
                let itemRelPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"

                guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { return nil }

                let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
                let size = (attrs[.size] as? Int64) ?? 0
                let modified = (attrs[.modificationDate] as? Date) ?? Date.distantPast

                return CachedItem(
                    id: itemRelPath,
                    name: name,
                    relativePath: itemRelPath,
                    fullPath: fullPath,
                    size: size,  // For directories, shows metadata size (not recursive)
                    modifiedDate: modified,
                    isDirectory: isDir
                )
            }.sorted()
        } catch {
            return []
        }
    }

    /// Get cache statistics for a profile
    func cacheStats(for profile: SyncProfile) -> CacheStats {
        guard let baseDir = cacheDirectory(for: profile) else {
            return CacheStats(totalSize: 0, fileCount: 0, directoryCount: 0)
        }
        return scanCacheStats(baseDir: baseDir)
    }

    /// Recursively total the files, directories, and bytes under `baseDir` (shared by the
    /// sync and RC-aware entry points).
    private func scanCacheStats(baseDir: String) -> CacheStats {
        var totalSize: Int64 = 0
        var fileCount = 0
        var dirCount = 0

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: baseDir) else {
            return CacheStats(totalSize: 0, fileCount: 0, directoryCount: 0)
        }

        while let path = enumerator.nextObject() as? String {
            guard !(path as NSString).lastPathComponent.hasPrefix(".") else { continue }
            let fullPath = (baseDir as NSString).appendingPathComponent(path)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { continue }

            if (attrs[.type] as? FileAttributeType) == .typeDirectory {
                dirCount += 1
            } else {
                fileCount += 1
                totalSize += (attrs[.size] as? Int64) ?? 0
            }
        }

        return CacheStats(totalSize: totalSize, fileCount: fileCount, directoryCount: dirCount)
    }

    /// Delete a specific cached item (file or directory)
    /// Prefers RC API when port > 0 (mount is active) to avoid corrupting open file handles
    func deleteCachedItem(_ item: CachedItem, rcPort: Int = 0) async throws {
        if rcPort > 0, item.isDirectory, await isRCAvailable(port: rcPort) {
            try await forgetDirectory(item.relativePath, port: rcPort)
        }
        // Also remove from disk (RC forget only evicts from VFS layer, not disk cache)
        try FileManager.default.removeItem(atPath: item.fullPath)
    }

    /// Synchronous delete for non-async contexts (use deleteCachedItem(_:rcPort:) when possible)
    func deleteCachedItemSync(_ item: CachedItem) throws {
        try FileManager.default.removeItem(atPath: item.fullPath)
    }

    /// Clear all cached files for a profile
    /// Prefers RC API when mount is active to safely evict from VFS layer first
    /// - Parameter preservePinned: when true, files under the profile's
    ///   `pinnedDirectories` are kept so pinned folders stay available offline.
    func clearCache(for profile: SyncProfile, preservePinned: Bool = false) async throws {
        let port = profile.rcPort
        let pinned = preservePinned ? profile.pinnedDirectories : []
        guard let baseDir = cacheDirectory(for: profile) else { return }
        let fm = FileManager.default

        // Nothing to preserve → clear everything (and drop the whole VFS listing when mounted).
        if pinned.isEmpty {
            if port > 0, await isRCAvailable(port: port) {
                try? await forgetDirectory("", port: port)
            }
            if let contents = try? fm.contentsOfDirectory(atPath: baseDir) {
                for item in contents {
                    try fm.removeItem(atPath: (baseDir as NSString).appendingPathComponent(item))
                }
            }
            return
        }

        // Preserve pinned → remove only cache entries that aren't a pinned directory
        // (or inside one).
        try clearUnpinned(dir: baseDir, base: baseDir, pinned: pinned, fm: fm)
    }

    /// Recursively remove cached entries whose path relative to `base` is neither a
    /// pinned directory nor inside one. A directory that merely *contains* a pinned dir
    /// is recursed into, so only its unpinned children are deleted.
    private func clearUnpinned(dir: String, base: String, pinned: [String], fm: FileManager) throws {
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for entry in entries {
            let full = (dir as NSString).appendingPathComponent(entry)
            let rel = String(full.dropFirst(base.count + 1))
            if pinned.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
                continue  // the pinned dir itself, or a file inside it — keep
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue && pinned.contains(where: { $0.hasPrefix(rel + "/") }) {
                try clearUnpinned(dir: full, base: base, pinned: pinned, fm: fm)  // ancestor of a pin
            } else {
                try fm.removeItem(atPath: full)
            }
        }
    }

    /// Synchronous cache clear (for use in non-async contexts)
    func clearCacheSync(for profile: SyncProfile) throws {
        guard let baseDir = cacheDirectory(for: profile) else { return }
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: baseDir) {
            for item in contents {
                let path = (baseDir as NSString).appendingPathComponent(item)
                try fm.removeItem(atPath: path)
            }
        }
    }

    // MARK: - RC API (Remote Control)

    /// Refresh/pre-cache a directory via rclone RC API
    func refreshDirectory(_ dir: String, port: Int) async throws {
        let url = URL(string: "http://localhost:\(port)/vfs/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // rclone's rc parses `/vfs/refresh` params as strings — a JSON boolean is
        // rejected with `value must be string "recursive"=true`, which rclone logs and
        // the LogParser then surfaces as a spurious "Sync error". Send the string.
        let body: [String: Any] = ["dir": dir, "recursive": "true"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw VFSCacheError.rcRequestFailed
        }
    }

    /// Forget (evict) a directory from VFS cache via rclone RC API
    func forgetDirectory(_ dir: String, port: Int) async throws {
        let url = URL(string: "http://localhost:\(port)/vfs/forget")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["dir": dir]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw VFSCacheError.rcRequestFailed
        }
    }

    /// Get VFS stats via rclone RC API
    func getVFSStats(port: Int) async throws -> [String: Any] {
        let url = URL(string: "http://localhost:\(port)/vfs/stats")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VFSCacheError.rcRequestFailed
        }
        return json
    }

    /// Check if the RC API is available for a profile
    func isRCAvailable(port: Int) async -> Bool {
        let url = URL(string: "http://localhost:\(port)/core/version")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Translate a user glob into an anchored regex fragment (no `^`/`$`), path-aware.
    ///
    /// Segment semantics, so a pattern can target folders at any depth:
    /// - `**/` matches zero or more leading directories, so `**/BACKUP/**` catches a
    ///   `BACKUP` folder at the top level *and* nested anywhere.
    /// - `**` on its own matches across `/` (any number of path segments).
    /// - `*` matches within one segment (does not cross `/`); `?` matches one non-`/` char.
    /// Every other character is matched literally (regex metacharacters escaped).
    static func globToRegex(_ glob: String) -> String {
        let chars = Array(glob)
        let n = chars.count
        var out = ""
        var i = 0
        while i < n {
            let c = chars[i]
            if c == "*" && i + 1 < n && chars[i + 1] == "*" {
                if i + 2 < n && chars[i + 2] == "/" {
                    out += "(?:.*/)?"   // **/  → zero or more leading dirs
                    i += 3
                } else {
                    out += ".*"          // trailing/standalone ** → cross segments
                    i += 2
                }
            } else if c == "*" {
                out += "[^/]*"          // * → within a single segment
                i += 1
            } else if c == "?" {
                out += "[^/]"
                i += 1
            } else {
                if "\\.^$|()[]{}+".contains(c) { out += "\\" }
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Compiled, **case-sensitive** matcher for a profile's `warmExcludePatterns`. Built once
    /// per warm run (regex compilation per file would be far too costly for large trees).
    /// Each pattern is matched against both the bare file name and the file's path relative
    /// to the pinned directory, so `*.bak` matches by name at any depth and `**/BACKUP/**`
    /// matches by subpath.
    struct ExcludeMatcher {
        private let regexes: [NSRegularExpression]

        init(patterns: [String]) {
            regexes = patterns.compactMap { pattern in
                let p = pattern.trimmingCharacters(in: .whitespaces)
                guard !p.isEmpty else { return nil }
                // No `.caseInsensitive` → matching is case-sensitive by design.
                return try? NSRegularExpression(pattern: "^" + VFSCacheService.globToRegex(p) + "$")
            }
        }

        var isEmpty: Bool { regexes.isEmpty }

        func matches(relativePath: String, name: String) -> Bool {
            for re in regexes {
                let nameRange = NSRange(name.startIndex..., in: name)
                if re.firstMatch(in: name, range: nameRange) != nil { return true }
                let relRange = NSRange(relativePath.startIndex..., in: relativePath)
                if re.firstMatch(in: relativePath, range: relRange) != nil { return true }
            }
            return false
        }
    }

    /// Estimated work for warming a directory: number of regular files and their total bytes.
    struct WarmEstimate { let files: Int; let bytes: Int64 }

    /// Count the regular files and total bytes under a pinned directory with a metadata-only
    /// walk (no byte reads). Used to give the warming UI a determinate progress bar. Files
    /// matching the profile's exclude patterns are not counted, so the total matches what the
    /// warmer will actually download.
    func estimateWarmWork(_ dir: String, for profile: SyncProfile) -> WarmEstimate {
        let fullDirPath = (profile.localSyncPath as NSString).appendingPathComponent(dir)
        let fm = FileManager.default
        guard fm.fileExists(atPath: fullDirPath),
              let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: fullDirPath),
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return WarmEstimate(files: 0, bytes: 0) }

        let matcher = ExcludeMatcher(patterns: profile.warmExcludePatterns)
        let prefixLen = fullDirPath.count + 1
        var files = 0
        var bytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let rv = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  rv.isRegularFile == true else { continue }
            let rel = fileURL.path.count > prefixLen ? String(fileURL.path.dropFirst(prefixLen)) : fileURL.lastPathComponent
            if !matcher.isEmpty,
               matcher.matches(relativePath: rel, name: fileURL.lastPathComponent) { continue }
            files += 1
            bytes += Int64(rv.fileSize ?? 0)
        }
        return WarmEstimate(files: files, bytes: bytes)
    }

    /// Number of files warmed concurrently. A single read stream through the NFS→rclone→
    /// backend path is latency-bound (especially on the SFTP fallback), so several parallel
    /// reads use far more of the available bandwidth. Matches rclone's default `--transfers`.
    static let defaultWarmConcurrency = 4

    /// Warm a single directory by: first calling `/vfs/refresh` (listing cache), then
    /// reading file bytes through the NFS mount to populate the rclone VFS content cache.
    ///
    /// A pinned folder means "keep this fully offline", so every file is read regardless of
    /// size. Total disk use stays bounded by rclone's `--vfs-cache-max-size` (LRU eviction at
    /// the cache layer), not an app-side ceiling. Up to `concurrency` files are read in
    /// parallel; `Task.isCancelled` and the `isStillPinned` check between scheduling files
    /// allow unmount / unpin to interrupt the run.
    ///
    /// - Parameters:
    ///   - dir: Relative directory path within the profile's localSyncPath.
    ///   - profile: The mount-mode profile whose NFS mount to read through.
    ///   - concurrency: Max files to read in parallel.
    ///   - isStillPinned: Live predicate re-evaluated between files; when it returns
    ///     false (the directory was unpinned mid-warm) the loop stops scheduling.
    ///   - onStart: Called when a file's read begins, with its name. Several files may be in
    ///     flight at once (up to `concurrency`), so a caller tracking the in-flight set should
    ///     add the name here and remove it in `onFileComplete`. Runs off the main actor.
    ///   - onProgress: Called for each chunk read, with the bytes in that chunk, so a caller
    ///     can advance byte-level progress *while a file is still downloading* (large files on
    ///     a slow link would otherwise show no movement until they finish). Runs off the main actor.
    ///   - onFileComplete: Called when a file's read finishes, with its name (matching the
    ///     `onStart` name) so the caller can remove it from the in-flight set. Runs off the main actor.
    func warmDirectory(
        _ dir: String,
        for profile: SyncProfile,
        concurrency: Int = defaultWarmConcurrency,
        isStillPinned: @Sendable () async -> Bool,
        onStart: (@Sendable (_ name: String) async -> Void)? = nil,
        onProgress: (@Sendable (_ bytes: Int64) async -> Void)? = nil,
        onFileComplete: (@Sendable (_ name: String) async -> Void)? = nil
    ) async {
        let port = profile.rcPort
        let mountPath = profile.localSyncPath
        let fullDirPath = (mountPath as NSString).appendingPathComponent(dir)

        // Step 1: refresh rclone's in-memory listing cache (metadata only).
        try? await refreshDirectory(dir, port: port)

        // Step 2: walk and read file bytes through the mount to populate the VFS content cache.
        let fm = FileManager.default
        guard fm.fileExists(atPath: fullDirPath) else {
            SyncTraySettings.debugLog("warmDirectory: directory not found at \(fullDirPath), skipping byte-read")
            return
        }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: fullDirPath),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let maxConcurrent = max(1, concurrency)
        let matcher = ExcludeMatcher(patterns: profile.warmExcludePatterns)
        let prefixLen = fullDirPath.count + 1

        // Bounded-concurrency task group: keep up to `maxConcurrent` file reads in flight,
        // starting a new one each time a running one completes.
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for case let fileURL as URL in enumerator {
                // Between scheduling files, honour cancellation and a mid-warm unpin.
                if Task.isCancelled { break }
                guard await isStillPinned() else {
                    SyncTraySettings.debugLog("warmDirectory: '\(dir)' was unpinned during warming, stopping")
                    break
                }

                guard let rv = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      rv.isRegularFile == true else { continue }

                let name = fileURL.lastPathComponent
                let path = fileURL.path

                // Skip files matching the profile's offline exclude globs (e.g. *.bak or
                // **/BACKUP/**), so backups and other unwanted files never download into the
                // offline cache.
                if !matcher.isEmpty {
                    let rel = path.count > prefixLen ? String(path.dropFirst(prefixLen)) : name
                    if matcher.matches(relativePath: rel, name: name) { continue }
                }

                if running >= maxConcurrent {
                    await group.next()      // wait for a slot
                    running -= 1
                }
                running += 1
                await onStart?(name)
                group.addTask {
                    // Reading bytes through the mount is what populates the rclone VFS
                    // content cache (not the RC /vfs/refresh call above). Report each chunk
                    // as it arrives so byte progress advances mid-file. 1 MB chunks keep the
                    // NFS round-trips (and the main-actor progress hops) low on slow links.
                    guard let fileHandle = FileHandle(forReadingAtPath: path) else {
                        await onFileComplete?(name)
                        return
                    }
                    let chunkSize = 1024 * 1024  // 1 MB
                    while let chunk = try? fileHandle.read(upToCount: chunkSize), !chunk.isEmpty {
                        await onProgress?(Int64(chunk.count))
                        if Task.isCancelled { break }
                    }
                    try? fileHandle.close()
                    await onFileComplete?(name)
                }
            }
            await group.waitForAll()
        }

        SyncTraySettings.debugLog("warmDirectory: Finished warming '\(dir)'")
    }

    // MARK: - Errors

    enum VFSCacheError: LocalizedError {
        case rcRequestFailed
        case cacheDirectoryNotFound

        var errorDescription: String? {
            switch self {
            case .rcRequestFailed:
                return "Failed to communicate with rclone RC API"
            case .cacheDirectoryNotFound:
                return "VFS cache directory not found"
            }
        }
    }
}

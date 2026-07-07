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

    /// Scan the VFS cache for a profile and return cached items at the given relative path
    func listCachedItems(for profile: SyncProfile, at relativePath: String = "") -> [CachedItem] {
        guard let baseDir = cacheDirectory(for: profile) else { return [] }

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

    /// Pre-cache all pinned directories for a profile.
    ///
    /// This calls `warmDirectory(_:for:)` for each pinned directory, which:
    /// 1. Calls `/vfs/refresh` to refresh rclone's in-memory directory-stat cache.
    /// 2. Opens and reads file bytes through the NFS mount to populate the VFS content cache.
    func refreshPinnedDirectories(for profile: SyncProfile) async {
        guard !profile.pinnedDirectories.isEmpty else { return }

        for dir in profile.pinnedDirectories {
            // Startup warm: the passed profile is the live state at this point.
            await warmDirectory(dir, for: profile) { profile.pinnedDirectories.contains(dir) }
        }
    }

    /// Warm a single directory by: first calling `/vfs/refresh` (listing cache), then
    /// reading file bytes through the NFS mount to populate the rclone VFS content cache.
    ///
    /// I/O budget: reads are sequential (not concurrent); total bytes ceiling is 2 GB per call;
    /// `try Task.checkCancellation()` between files allows the task to be cancelled by unmount
    /// or unpin operations.
    ///
    /// - Parameters:
    ///   - dir: Relative directory path within the profile's localSyncPath.
    ///   - profile: The mount-mode profile whose NFS mount to read through.
    ///   - isStillPinned: Live predicate re-evaluated between files; when it returns
    ///     false (the directory was unpinned mid-warm) the read loop stops early.
    func warmDirectory(_ dir: String, for profile: SyncProfile, isStillPinned: @Sendable () async -> Bool) async {
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

        var totalBytesRead: Int64 = 0
        let maxTotalBytes: Int64 = 2 * 1024 * 1024 * 1024  // 2 GB ceiling
        let maxFileBytes: Int64 = 100 * 1024 * 1024         // 100 MB per-file ceiling
        let chunkSize = 64 * 1024                            // 64 KB read chunks

        for case let fileURL as URL in enumerator {
            // Check cancellation between files (allows unmount / unpin to interrupt).
            do { try Task.checkCancellation() } catch { return }

            // Stop if the directory was unpinned while we were warming (live check).
            guard await isStillPinned() else {
                SyncTraySettings.debugLog("warmDirectory: '\(dir)' was unpinned during warming, stopping")
                return
            }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true else { continue }

            let fileSize = Int64(resourceValues.fileSize ?? 0)

            if fileSize > maxFileBytes {
                SyncTraySettings.debugLog("warmDirectory: Skipping large file (\(fileSize) bytes): \(fileURL.lastPathComponent)")
                continue
            }

            if totalBytesRead + fileSize > maxTotalBytes {
                SyncTraySettings.debugLog("warmDirectory: 2 GB total ceiling reached, stopping warm for '\(dir)'")
                return
            }

            // Read file bytes through the mount — this is what actually populates
            // the rclone VFS content cache (not the RC /vfs/refresh call above).
            guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else { continue }

            var fileBytesRead: Int64 = 0
            while let chunk = try? fileHandle.read(upToCount: chunkSize), !chunk.isEmpty {
                fileBytesRead += Int64(chunk.count)
            }
            try? fileHandle.close()

            totalBytesRead += fileBytesRead
        }

        SyncTraySettings.debugLog("warmDirectory: Finished warming '\(dir)' — \(totalBytesRead) bytes read through mount")
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

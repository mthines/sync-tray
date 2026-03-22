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
                    size: isDir ? directorySize(at: fullPath) : size,
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
    func deleteCachedItem(_ item: CachedItem) throws {
        try FileManager.default.removeItem(atPath: item.fullPath)
    }

    /// Clear all cached files for a profile
    func clearCache(for profile: SyncProfile) throws {
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

        let body: [String: Any] = ["dir": dir, "recursive": true]
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

    /// Pre-cache all pinned directories for a profile
    func refreshPinnedDirectories(for profile: SyncProfile) async {
        guard !profile.pinnedDirectories.isEmpty else { return }
        let port = profile.rcPort

        for dir in profile.pinnedDirectories {
            try? await refreshDirectory(dir, port: port)
        }
    }

    // MARK: - Helpers

    private func directorySize(at path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }

        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               (attrs[.type] as? FileAttributeType) != .typeDirectory {
                total += (attrs[.size] as? Int64) ?? 0
            }
        }
        return total
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

import Foundation

/// A sync profile representing a single rclone remote/target configuration
struct SyncProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String                    // Display name (e.g., "Work", "Personal")
    var rcloneRemote: String            // e.g., "synology-kaiju:"
    var remotePath: String              // e.g., "Kaiju"
    var localSyncPath: String           // e.g., "/Volumes/SeagateHD/Kaiju"
    var drivePathToMonitor: String      // e.g., "/Volumes/SeagateHD" (empty if not external)
    var syncIntervalMinutes: Int        // default: 15
    var additionalRcloneFlags: String   // optional extra flags
    var isEnabled: Bool                 // whether scheduled sync is active
    var isMuted: Bool                   // whether notifications are muted for this profile
    var syncMode: SyncMode              // bisync (two-way), sync (one-way), or mount (streaming)
    var syncDirection: SyncDirection    // direction for one-way sync

    // Fallback remote (used when primary remote is unreachable)
    var fallbackRemote: String          // e.g., "synology-sftp" (empty = no fallback)
    var fallbackRemotePath: String      // e.g., "/volume1/Kaiju" (empty = same as primary remotePath)

    // Mount mode specific settings
    var vfsCacheMode: VFSCacheMode      // VFS cache mode for mount (default: full)
    var vfsCacheMaxSize: String         // Max cache size (e.g., "10G")
    var vfsCachePath: String            // Cache directory path (default: ~/.cache/rclone)
    var allowNonEmptyMount: Bool        // Allow mounting to non-empty folders (default: false)
    var pinnedDirectories: [String]     // Directories to automatically cache offline (mount mode)
    var rcPort: Int                     // Port for rclone RC (remote control) API (mount mode)

    /// Short ID for file naming (first 8 chars of UUID)
    var shortId: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    /// Returns true if this profile is in mount mode
    var isMountMode: Bool {
        syncMode == .mount
    }

    // MARK: - Computed Paths

    /// Shared script path (single script for all profiles)
    static var sharedScriptPath: String {
        "\(NSHomeDirectory())/.local/bin/synctray-sync.sh"
    }

    /// Profile config directory
    static var configDirectory: String {
        "\(NSHomeDirectory())/.config/synctray/profiles"
    }

    /// Profile-specific config file (JSON)
    var configPath: String {
        "\(Self.configDirectory)/\(shortId).json"
    }

    /// Profile-specific launchd plist
    var plistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/com.synctray.sync.\(shortId).plist"
    }

    /// Profile-specific log file
    var logPath: String {
        "\(NSHomeDirectory())/.local/log/synctray-sync-\(shortId).log"
    }

    /// Profile-specific exclude filter file
    var filterFilePath: String {
        "\(Self.configDirectory)/\(shortId)-exclude.txt"
    }

    var launchdLabel: String {
        "com.synctray.sync.\(shortId)"
    }

    var lockFilePath: String {
        "/tmp/synctray-sync-\(shortId).lock"
    }

    // MARK: - Full Remote Path

    /// Full remote path for rclone (e.g., "synology-kaiju:Kaiju")
    var fullRemotePath: String {
        if remotePath.isEmpty {
            return rcloneRemote.hasSuffix(":") ? rcloneRemote : "\(rcloneRemote):"
        }
        let remote = rcloneRemote.hasSuffix(":") ? String(rcloneRemote.dropLast()) : rcloneRemote
        return "\(remote):\(remotePath)"
    }

    // MARK: - Fallback

    /// Whether a fallback remote is configured
    var hasFallback: Bool {
        !fallbackRemote.isEmpty
    }

    /// Full fallback remote path for rclone (e.g., "synology-sftp:/volume1/Kaiju")
    var fullFallbackRemotePath: String {
        let path = fallbackRemotePath.isEmpty ? remotePath : fallbackRemotePath
        let remote = fallbackRemote.hasSuffix(":") ? String(fallbackRemote.dropLast()) : fallbackRemote
        if path.isEmpty {
            return "\(remote):"
        }
        return "\(remote):\(path)"
    }

    // MARK: - Validation

    var isValid: Bool {
        !name.isEmpty && !rcloneRemote.isEmpty && !remotePath.isEmpty && !localSyncPath.isEmpty
    }

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        name: String = "",
        rcloneRemote: String = "",
        remotePath: String = "",
        localSyncPath: String = "",
        drivePathToMonitor: String = "",
        syncIntervalMinutes: Int = 5,
        additionalRcloneFlags: String = "",
        isEnabled: Bool = false,
        isMuted: Bool = false,
        syncMode: SyncMode = .bisync,
        syncDirection: SyncDirection = .localToRemote,
        fallbackRemote: String = "",
        fallbackRemotePath: String = "",
        vfsCacheMode: VFSCacheMode = .full,
        vfsCacheMaxSize: String = "10G",
        vfsCachePath: String = "",
        allowNonEmptyMount: Bool = false,
        pinnedDirectories: [String] = [],
        rcPort: Int = 0
    ) {
        self.id = id
        self.name = name
        self.rcloneRemote = rcloneRemote
        self.remotePath = remotePath
        self.localSyncPath = localSyncPath
        self.drivePathToMonitor = drivePathToMonitor
        self.syncIntervalMinutes = syncIntervalMinutes
        self.additionalRcloneFlags = additionalRcloneFlags
        self.isEnabled = isEnabled
        self.isMuted = isMuted
        self.syncMode = syncMode
        self.syncDirection = syncDirection
        self.fallbackRemote = fallbackRemote
        self.fallbackRemotePath = fallbackRemotePath
        self.vfsCacheMode = vfsCacheMode
        self.vfsCacheMaxSize = vfsCacheMaxSize
        self.vfsCachePath = vfsCachePath.isEmpty ? "\(NSHomeDirectory())/.cache/rclone" : vfsCachePath
        self.allowNonEmptyMount = allowNonEmptyMount
        self.pinnedDirectories = pinnedDirectories
        self.rcPort = rcPort > 0 ? rcPort : SyncProfile.defaultRCPort(for: id)
    }

    /// Generate a deterministic RC port from the profile UUID (range: 5800-5899)
    /// Uses djb2 hash for stability (Swift's hashValue is randomized per process)
    static func defaultRCPort(for id: UUID) -> Int {
        let bytes = Array(id.uuidString.utf8)
        var hash: UInt32 = 5381
        for byte in bytes {
            hash = ((hash &<< 5) &+ hash) &+ UInt32(byte)
        }
        return 5800 + Int(hash % 100)
    }

    /// Create a new profile with default values
    static func newProfile() -> SyncProfile {
        SyncProfile(name: "New Profile")
    }
}

// MARK: - Codable (backwards compatibility)

extension SyncProfile {
    enum CodingKeys: String, CodingKey {
        case id, name, rcloneRemote, remotePath, localSyncPath
        case drivePathToMonitor, syncIntervalMinutes, additionalRcloneFlags
        case isEnabled, isMuted, syncMode, syncDirection
        case fallbackRemote, fallbackRemotePath
        case vfsCacheMode, vfsCacheMaxSize, vfsCachePath, allowNonEmptyMount
        case pinnedDirectories, rcPort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rcloneRemote = try container.decode(String.self, forKey: .rcloneRemote)
        remotePath = try container.decode(String.self, forKey: .remotePath)
        localSyncPath = try container.decode(String.self, forKey: .localSyncPath)
        drivePathToMonitor = try container.decode(String.self, forKey: .drivePathToMonitor)
        syncIntervalMinutes = try container.decode(Int.self, forKey: .syncIntervalMinutes)
        additionalRcloneFlags = try container.decode(String.self, forKey: .additionalRcloneFlags)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        // Backwards compatibility: default to false if not present
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        // Backwards compatibility: default to bisync if not present
        syncMode = try container.decodeIfPresent(SyncMode.self, forKey: .syncMode) ?? .bisync
        // Backwards compatibility: default to localToRemote if not present
        syncDirection = try container.decodeIfPresent(SyncDirection.self, forKey: .syncDirection) ?? .localToRemote
        // Backwards compatibility: fallback remote defaults to empty (disabled)
        fallbackRemote = try container.decodeIfPresent(String.self, forKey: .fallbackRemote) ?? ""
        fallbackRemotePath = try container.decodeIfPresent(String.self, forKey: .fallbackRemotePath) ?? ""
        // Backwards compatibility: mount mode settings with defaults
        vfsCacheMode = try container.decodeIfPresent(VFSCacheMode.self, forKey: .vfsCacheMode) ?? .full
        vfsCacheMaxSize = try container.decodeIfPresent(String.self, forKey: .vfsCacheMaxSize) ?? "10G"
        let cachePath = try container.decodeIfPresent(String.self, forKey: .vfsCachePath) ?? ""
        vfsCachePath = cachePath.isEmpty ? "\(NSHomeDirectory())/.cache/rclone" : cachePath
        // Backwards compatibility: default to false if not present
        allowNonEmptyMount = try container.decodeIfPresent(Bool.self, forKey: .allowNonEmptyMount) ?? false
        // Backwards compatibility: default to empty array if not present
        pinnedDirectories = try container.decodeIfPresent([String].self, forKey: .pinnedDirectories) ?? []
        // Backwards compatibility: generate default RC port if not present
        let decodedRCPort = try container.decodeIfPresent(Int.self, forKey: .rcPort) ?? 0
        rcPort = decodedRCPort > 0 ? decodedRCPort : SyncProfile.defaultRCPort(for: id)
    }
}

// MARK: - Hashable

extension SyncProfile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

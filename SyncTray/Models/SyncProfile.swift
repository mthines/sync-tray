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

    // Mount mode specific settings
    var vfsCacheMode: VFSCacheMode      // VFS cache mode for mount (default: full)
    var vfsCacheMaxSize: String         // Max cache size (e.g., "10G")
    var vfsCachePath: String            // Cache directory path (default: ~/.cache/rclone/vfs)
    var allowNonEmptyMount: Bool        // Allow mounting to non-empty folders (default: false)

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
        vfsCacheMode: VFSCacheMode = .full,
        vfsCacheMaxSize: String = "10G",
        vfsCachePath: String = "",
        allowNonEmptyMount: Bool = false
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
        self.vfsCacheMode = vfsCacheMode
        self.vfsCacheMaxSize = vfsCacheMaxSize
        self.vfsCachePath = vfsCachePath.isEmpty ? "\(NSHomeDirectory())/.cache/rclone/vfs" : vfsCachePath
        self.allowNonEmptyMount = allowNonEmptyMount
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
        case vfsCacheMode, vfsCacheMaxSize, vfsCachePath, allowNonEmptyMount
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
        // Backwards compatibility: mount mode settings with defaults
        vfsCacheMode = try container.decodeIfPresent(VFSCacheMode.self, forKey: .vfsCacheMode) ?? .full
        vfsCacheMaxSize = try container.decodeIfPresent(String.self, forKey: .vfsCacheMaxSize) ?? "10G"
        let cachePath = try container.decodeIfPresent(String.self, forKey: .vfsCachePath) ?? ""
        vfsCachePath = cachePath.isEmpty ? "\(NSHomeDirectory())/.cache/rclone/vfs" : cachePath
        // Backwards compatibility: default to false if not present
        allowNonEmptyMount = try container.decodeIfPresent(Bool.self, forKey: .allowNonEmptyMount) ?? false
    }
}

// MARK: - Hashable

extension SyncProfile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

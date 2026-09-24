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
    /// True when primary and fallback remotes use different rclone wire types (e.g. smb vs sftp).
    /// When true, the sync script swaps the full REMOTE reference on fallback activation instead of
    /// using env-var overrides — bisync cache is intentionally rebuilt to avoid NFD/NFC divergence.
    /// Populated at install/save time. Defaults to false for profiles created before this field existed.
    var fallbackRequiresCacheRebuild: Bool

    // Mount mode specific settings
    var mountBackend: MountBackend      // Mount backend: nfs (kext-free, default) or macfuse
    var vfsCacheMode: VFSCacheMode      // VFS cache mode for mount (default: full)
    var vfsCacheMaxSize: String         // Max cache size (e.g., "10G")
    var vfsCacheMaxAge: String          // Keep cached files this long since last access (e.g., "168h")
    var vfsCachePath: String            // Cache directory path (default: ~/.cache/rclone)
    var allowNonEmptyMount: Bool        // Allow mounting to non-empty folders (default: false)
    var mountAtStartup: Bool            // Auto-mount when SyncTray launches (mount mode, default: true)
    /// Maintain a read-only "<mount-name> (Offline)" browse point next to the mount that
    /// links straight to the VFS cache DATA tree, so already-cached files stay readable in
    /// Finder even when the network is down and the live `rclone nfsmount` has stalled/dropped
    /// (rclone's streaming VFS cannot itself serve purely-from-cache offline). App-side only —
    /// never written to the script's `{shortId}.json`. Mount mode; default: true. See the
    /// "Offline access" section in CLAUDE.md.
    var offlineAccessEnabled: Bool
    /// Key the VFS cache by a **profile-owned** identity (`synctray_{shortId}`) instead of
    /// by the rclone remote name. rclone derives the cache location from the mounted Fs's
    /// name + root (`{cache}/vfs/{fsName}/{fsRoot}`), so with this off, changing a profile's
    /// `rcloneRemote` — LAN SMB at home, SFTP/QuickConnect away — re-keys the whole cache
    /// and re-downloads everything into a second tree. With it on, SyncTray mounts an
    /// env-var-defined remote named after the PROFILE whose connection parameters are copied
    /// from whichever remote is currently active, so one cache is shared across every remote
    /// the profile ever points at. Mount mode only; default true. `CacheIdentityMigration`
    /// adopts a pre-existing remote-named tree on the next install, so turning this on never
    /// costs a re-download. See "Cache identity" in CLAUDE.md.
    var stableCacheIdentity: Bool
    /// Cache-Only (Offline): serve this Stream profile from the VFS cache and stop trying to
    /// keep up with the remote. The mount still comes up (so existing absolute paths keep
    /// resolving — a Reaper project referencing the mount point does not have to be relinked)
    /// but it is mounted `--read-only`, with change detection reduced to the fast fingerprint,
    /// cache retention pinned open so nothing expires while the remote is out of reach, every
    /// remote call bounded by a short timeout, and the app-side offline warmer suppressed.
    /// Cached files then open at local-disk speed instead of blocking on per-file
    /// revalidation against a remote that is slow or gone.
    ///
    /// Two reversible trade-offs, both surfaced in the UI: an uncached file errors instead of
    /// downloading, and `--read-only` pauses write-back, so a recording still queued in the
    /// cache is deferred (not lost) until the mode is switched off. Mount mode only;
    /// default false.
    var streamCacheOnly: Bool
    var pinnedDirectories: [String]     // Directories to automatically cache offline (mount mode)
    /// Glob patterns excluded from offline warming, matched **case-sensitively** against each
    /// file's name and its path relative to the pinned dir. Supports `*` (within a segment),
    /// `?`, and `**` (across segments), so `*.bak` skips backup files and `**/BACKUP/**` skips
    /// every folder named BACKUP at any depth (e.g. "*.bak", "*.tmp", "**/BACKUP/**").
    /// Excluded files are skipped by the warmer so they never download into the offline cache.
    var warmExcludePatterns: [String]
    var rcPort: Int                     // Port for rclone RC (remote control) API (mount mode)
    /// Number of files rclone downloads in parallel — drives the mount's `--transfers`
    /// AND the app-side offline-warm concurrency (`VFSCacheService`), kept in lockstep.
    /// Higher saturates a fast wired link; 1–2 is faster on Wi-Fi / a mesh backhaul / a
    /// slow remote, where extra parallel transfers contend for a shared half-duplex link
    /// (and thrash a spinning-disk cache) and collapse aggregate throughput. Clamped to
    /// 1...16. Defaults to 2 — a safe value for the common case (a NAS reached over Wi-Fi
    /// or a mesh, and/or a spinning-disk cache); users on a fast wired link raise it.
    var downloadConnections: Int

    /// Short ID for file naming (first 8 chars of UUID)
    var shortId: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    /// Returns true if this profile is in mount mode
    var isMountMode: Bool {
        syncMode == .mount
    }

    // MARK: - Cache Identity

    /// The rclone remote name this profile's VFS cache is keyed by when
    /// `stableCacheIdentity` is on — derived from the profile UUID, so it never changes
    /// when the user re-points `rcloneRemote` or a fallback activates.
    ///
    /// Only `[a-z0-9_]` by construction (`synctray_` + 8 lowercase hex chars), which
    /// matters twice: rclone accepts it as a remote name, and it maps to the
    /// `RCLONE_CONFIG_<NAME>_<KEY>` environment variables that define the remote without
    /// any escaping.
    var cacheIdentityName: String {
        "synctray_\(shortId)"
    }

    /// Remote name (colon stripped) of the profile's PRIMARY remote — the name rclone
    /// keyed the cache by before `stableCacheIdentity` existed, and still does when the
    /// flag is off.
    var primaryRemoteName: String {
        rcloneRemote.hasSuffix(":") ? String(rcloneRemote.dropLast()) : rcloneRemote
    }

    /// The remote name rclone will report as the mounted Fs's name, i.e. the first path
    /// component of the profile's cache subtree.
    var effectiveCacheRemoteName: String {
        stableCacheIdentity ? cacheIdentityName : primaryRemoteName
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

    /// NEW authoritative per-profile file carrying the FULL `SyncProfile`
    /// (including fields the derived `configPath` JSON omits: `isEnabled`,
    /// `isMuted`, `mountAtStartup`). This is the external-agent-editable
    /// surface; `configPath` remains the derived, frozen subset the sync
    /// script reads and stays byte-for-byte unchanged.
    var profileFilePath: String {
        "\(Self.configDirectory)/\(shortId).profile.json"
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

    // MARK: - Local Directory Inspection

    /// Counts items in a local directory that a user would recognise as "their files",
    /// ignoring SyncTray's own state folder and pure macOS metadata noise.
    ///
    /// Used to warn before pointing a sync at a folder that already has content: on the
    /// first sync SyncTray merges the local folder with the remote, which can produce
    /// duplicates, unexpected overwrites, or hard-to-undo deletions.
    static func meaningfulItemCount(at path: String) -> Int {
        guard !path.isEmpty else { return 0 }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return 0 }

        let ignored: Set<String> = [".DS_Store", ".localized"]
        return contents.filter { name in
            !name.hasPrefix(".synctray") && !ignored.contains(name)
        }.count
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
        fallbackRequiresCacheRebuild: Bool = false,
        mountBackend: MountBackend = .nfs,
        vfsCacheMode: VFSCacheMode = .full,
        vfsCacheMaxSize: String = "10G",
        vfsCacheMaxAge: String = "168h",
        vfsCachePath: String = "",
        allowNonEmptyMount: Bool = false,
        mountAtStartup: Bool = true,
        offlineAccessEnabled: Bool = true,
        stableCacheIdentity: Bool = true,
        streamCacheOnly: Bool = false,
        pinnedDirectories: [String] = [],
        warmExcludePatterns: [String] = [],
        rcPort: Int = 0,
        downloadConnections: Int = 2
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
        self.fallbackRequiresCacheRebuild = fallbackRequiresCacheRebuild
        self.mountBackend = mountBackend
        self.vfsCacheMode = vfsCacheMode
        self.vfsCacheMaxSize = vfsCacheMaxSize
        self.vfsCacheMaxAge = vfsCacheMaxAge
        self.vfsCachePath = vfsCachePath.isEmpty ? "\(NSHomeDirectory())/.cache/rclone" : vfsCachePath
        self.allowNonEmptyMount = allowNonEmptyMount
        self.mountAtStartup = mountAtStartup
        self.offlineAccessEnabled = offlineAccessEnabled
        self.stableCacheIdentity = stableCacheIdentity
        self.streamCacheOnly = streamCacheOnly
        self.pinnedDirectories = pinnedDirectories
        self.warmExcludePatterns = warmExcludePatterns
        self.rcPort = rcPort > 0 ? rcPort : SyncProfile.defaultRCPort(for: id)
        self.downloadConnections = min(16, max(1, downloadConnections))
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
        case fallbackRemote, fallbackRemotePath, fallbackRequiresCacheRebuild
        case mountBackend
        case vfsCacheMode, vfsCacheMaxSize, vfsCacheMaxAge, vfsCachePath, allowNonEmptyMount
        case mountAtStartup, offlineAccessEnabled
        case stableCacheIdentity, streamCacheOnly
        case pinnedDirectories, warmExcludePatterns, rcPort
        case downloadConnections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rcloneRemote = try container.decode(String.self, forKey: .rcloneRemote)
        remotePath = try container.decode(String.self, forKey: .remotePath)
        localSyncPath = try container.decode(String.self, forKey: .localSyncPath)
        // Optional-with-default so an agent (or dropped file) can author a
        // MINIMAL profile — id/name/remote/paths are the only truly-required
        // keys. These three mirror the memberwise-init defaults exactly, so an
        // app-written file (which always emits them) round-trips unchanged.
        drivePathToMonitor = try container.decodeIfPresent(String.self, forKey: .drivePathToMonitor) ?? ""
        syncIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes) ?? 5
        additionalRcloneFlags = try container.decodeIfPresent(String.self, forKey: .additionalRcloneFlags) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        // Backwards compatibility: default to false if not present
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        // Backwards compatibility: default to bisync if not present
        syncMode = try container.decodeIfPresent(SyncMode.self, forKey: .syncMode) ?? .bisync
        // Backwards compatibility: default to localToRemote if not present
        syncDirection = try container.decodeIfPresent(SyncDirection.self, forKey: .syncDirection) ?? .localToRemote
        // Backwards compatibility: fallback remote defaults to empty (disabled)
        fallbackRemote = try container.decodeIfPresent(String.self, forKey: .fallbackRemote) ?? ""
        fallbackRemotePath = try container.decodeIfPresent(String.self, forKey: .fallbackRemotePath) ?? ""
        // Backwards compatibility: defaults to false (preserves env-var-override behaviour for old profiles)
        fallbackRequiresCacheRebuild = try container.decodeIfPresent(
            Bool.self, forKey: .fallbackRequiresCacheRebuild) ?? false
        // Backwards compatibility: mount mode settings with defaults.
        // Profiles with no explicit backend default to the kext-free NFS backend —
        // it needs no macFUSE install, so it's the lowest-friction default. A profile
        // that was running on macFUSE switches to NFS on its next mount (the VFS cache
        // is shared, so no re-download); users who specifically want FUSE can pick
        // macFUSE in the profile editor.
        mountBackend = try container.decodeIfPresent(MountBackend.self, forKey: .mountBackend) ?? .nfs
        vfsCacheMode = try container.decodeIfPresent(VFSCacheMode.self, forKey: .vfsCacheMode) ?? .full
        vfsCacheMaxSize = try container.decodeIfPresent(String.self, forKey: .vfsCacheMaxSize) ?? "10G"
        vfsCacheMaxAge = try container.decodeIfPresent(String.self, forKey: .vfsCacheMaxAge) ?? "168h"
        let cachePath = try container.decodeIfPresent(String.self, forKey: .vfsCachePath) ?? ""
        vfsCachePath = cachePath.isEmpty ? "\(NSHomeDirectory())/.cache/rclone" : cachePath
        // Backwards compatibility: default to false if not present
        allowNonEmptyMount = try container.decodeIfPresent(Bool.self, forKey: .allowNonEmptyMount) ?? false
        // Backwards compatibility: auto-mount on startup defaults to true (matches the
        // pre-existing behaviour where an installed mount profile always came up on launch)
        mountAtStartup = try container.decodeIfPresent(Bool.self, forKey: .mountAtStartup) ?? true
        // Backwards compatibility: offline access defaults to true, so a profile
        // persisted before this field existed gains the read-only "(Offline)" browse
        // point on its next mount (the VFS cache is shared, so nothing re-downloads).
        offlineAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .offlineAccessEnabled) ?? true
        // Backwards compatibility: a profile persisted before this field existed adopts the
        // profile-stable cache identity on its next install. That re-keys the cache subtree
        // from vfs/{remote}/… to vfs/synctray_{shortId}/… — which would strand an existing
        // warm cache, so `CacheIdentityMigration` renames the legacy tree into place first.
        // Nothing re-downloads; set it false to stay on the remote-named layout.
        stableCacheIdentity = try container.decodeIfPresent(Bool.self, forKey: .stableCacheIdentity) ?? true
        // Backwards compatibility: cache-only is opt-in, so an existing profile keeps
        // streaming from the remote exactly as before.
        streamCacheOnly = try container.decodeIfPresent(Bool.self, forKey: .streamCacheOnly) ?? false
        // Backwards compatibility: default to empty array if not present
        pinnedDirectories = try container.decodeIfPresent([String].self, forKey: .pinnedDirectories) ?? []
        // Backwards compatibility: default to empty array if not present
        warmExcludePatterns = try container.decodeIfPresent([String].self, forKey: .warmExcludePatterns) ?? []
        // Backwards compatibility: generate default RC port if not present
        let decodedRCPort = try container.decodeIfPresent(Int.self, forKey: .rcPort) ?? 0
        rcPort = decodedRCPort > 0 ? decodedRCPort : SyncProfile.defaultRCPort(for: id)
        // Backwards compatibility: parallel downloads default to 2 (a safe value on a
        // contended Wi-Fi/mesh link or spinning-disk cache). Clamped to the supported
        // 1...16 range so a hand-edited profile file can never inject an out-of-range
        // --transfers.
        let decodedConnections = try container.decodeIfPresent(Int.self, forKey: .downloadConnections) ?? 2
        downloadConnections = min(16, max(1, decodedConnections))
    }
}

// MARK: - Hashable

extension SyncProfile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

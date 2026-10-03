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
    /// Cache-Only: mount this Stream profile as a writable union overlay over the VFS
    /// cache's DATA tree instead of streaming from the remote. The overlay directory is
    /// checked FIRST (so new files and edits land there, never touching the cache) and the
    /// read-only cache tree SECOND; the script hides partially-downloaded files. Reads of
    /// already-cached files are served at local-disk speed, and files created or edited
    /// while in this mode are queued for upload (`OverlaySyncService`) the next time the
    /// profile switches back to Streaming (or via "Upload Now" without switching). The mount
    /// also enters this mode AUTOMATICALLY when the primary remote is unreachable at mount
    /// time (see CLAUDE.md's "Cache-Only overlay mode" section); this flag only tracks the
    /// user's MANUAL choice ("Cache Only" button) — `MountMode` (read from the running
    /// mount's state file) is the source of truth for which mode is actually active,
    /// including the automatic ones. Mount mode only; default false.
    var streamCacheOnly: Bool
    var pinnedDirectories: [String]     // Directories to automatically cache offline (mount mode)
    /// Glob patterns excluded from offline warming, matched **case-sensitively** against each
    /// file's name and its path relative to the pinned dir. Supports `*` (within a segment),
    /// `?`, and `**` (across segments), so `*.bak` skips backup files and `**/BACKUP/**` skips
    /// every folder named BACKUP at any depth (e.g. "*.bak", "*.tmp", "**/BACKUP/**").
    /// Excluded files are skipped by the warmer so they never download into the offline cache.
    var warmExcludePatterns: [String]
    /// "Don't Sync" globs for Two-Way and One-Way profiles — the same syntax and matching
    /// rules as `warmExcludePatterns` (case-sensitive; `*` within a segment, `?`, `**` across
    /// segments; matched against each file's name and its path relative to the sync folder).
    /// Translated into rclone filter rules by `SyncExcludeFilter` and written into a managed
    /// block at the top of the profile's exclude filter file, so matching files stop syncing in
    /// both directions. Nothing is deleted on either side. Ignored in mount mode.
    var syncExcludePatterns: [String]
    /// Selective folders (Option A) for Two-Way and One-Way profiles — when non-empty, ONLY
    /// these folders (paths relative to the profile's root pair: `remotePath` on the remote
    /// side, `localSyncPath` on the local side) are synced; an empty list keeps today's
    /// "sync everything" behaviour byte-for-byte. Entries are literal folder paths (no
    /// globs — wildcards belong in `syncExcludePatterns`), normalized at every boundary
    /// (trimmed, leading/trailing `/` stripped, `.`/`..` segments and blank entries dropped,
    /// de-duplicated keeping order). Compiled into a managed TAIL block of the exclude
    /// filter file by `SyncExcludeFilter` (after the "Don't Sync" head block), so every
    /// exclude still wins first-match. Ignored in mount mode. Not emitted into the derived
    /// `{shortId}.json` — the script reads it only via the compiled filter file.
    var syncIncludeFolders: [String]
    var rcPort: Int                     // Port for rclone RC (remote control) API (mount mode)
    /// Number of files rclone downloads in parallel — drives the mount's `--transfers`
    /// AND the app-side offline-warm concurrency (`VFSCacheService`), kept in lockstep.
    /// Higher saturates a fast wired link; 1–2 is faster on Wi-Fi / a mesh backhaul / a
    /// slow remote, where extra parallel transfers contend for a shared half-duplex link
    /// (and thrash a spinning-disk cache) and collapse aggregate throughput. Clamped to
    /// 1...16. Defaults to 2 — a safe value for the common case (a NAS reached over Wi-Fi
    /// or a mesh, and/or a spinning-disk cache); users on a fast wired link raise it.
    var downloadConnections: Int
    /// Optional bandwidth cap passed to rclone's `--bwlimit` on every command this
    /// profile runs (mount, sync, bisync) — so the streaming/warm mount, a one-way
    /// sync, and a bisync all stay under it. rclone's own format: a single rate
    /// (`10M` = 10 MByte/s) or `up:down` (`1M:512k`), a bare number in KiByte/s, or
    /// `off`. Empty = unlimited (rclone's default). Capping the shared uplink is the
    /// knob for "SyncTray is saturating my network / freezing Finder": a live mount
    /// that maxes the link can stall the local NFS server and drop the volume, and a
    /// cap keeps headroom. Validated app/CLI-side (`SyncProfile.isValidBandwidthLimit`)
    /// to a shell-safe single-rate spec — no spaces, so it can't break the generated
    /// script — and trimmed; an invalid value is rejected at the boundary, never written.
    var bandwidthLimit: String
    /// Mount resilience (Stream mode only, default true). When on, the generated mount
    /// command bounds how long a stalled backend can hang the mount via rclone's
    /// `--timeout 30s --contimeout 10s` (down from rclone's 5m/1m defaults): rclone's NFS
    /// server is local and always answers, so `--timeout` makes a wedged backend return a
    /// bounded NFS error for the held RPC in ~30s instead of blocking the reading process
    /// for minutes. The mount stays the macOS default `hard` mount — SyncTray does NOT pass
    /// `-o soft`. A prior release mounted the NFS client `-o soft,timeo=100,retrans=3`, but
    /// on a flaky backend `soft` made the client cache an EPERM on a transient stall, which
    /// Finder showed as "you don't have permission to see its contents" + red badges that
    /// stuck until remount; a `hard` mount self-heals once the backend answers again, and
    /// the rclone `--timeout` already covers the freeze. Default ON because the freeze is
    /// the common pain and the hard mount no longer has the soft downside; off drops back to
    /// rclone's stock 5m/1m timeouts. Applies to both the nfsmount and macFUSE backends.
    var mountResilient: Bool

    /// Short ID for file naming (first 8 chars of UUID)
    var shortId: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    /// Returns true if this profile is in mount mode
    var isMountMode: Bool {
        syncMode == .mount
    }

    // MARK: - Cache Identity

    /// Remote name (colon stripped) of the profile's PRIMARY remote — the name rclone
    /// keys the VFS cache by (`{cache}/vfs/{primaryRemoteName}/{remotePath}`), exactly
    /// as it did before the (removed) "Share the cache across remotes" feature and
    /// exactly as an older build still expects. See "Cache identity" in CLAUDE.md.
    var primaryRemoteName: String {
        rcloneRemote.hasSuffix(":") ? String(rcloneRemote.dropLast()) : rcloneRemote
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

    /// HTTP Basic user for a Stream mount's rclone RC API (the password is the secret
    /// in `rcAuthPath(port:)`). Mirrored by the sync script's `RCLONE_RC_USER`.
    static let rcUser = "synctray"

    /// 0600 file holding the RC API secret for the mount listening on `port`. Written by
    /// the sync script (the mount can start under launchd with no app running) and read by
    /// `VFSCacheService.rcRequest`. Kept OUTSIDE `~/.config/synctray`, which the config
    /// watcher and `MigrationRunner` treat as profile/settings JSON. The script derives
    /// the same path as `$HOME/.local/state/synctray/rc/$RC_PORT.auth` — rename both.
    static func rcAuthPath(port: Int) -> String {
        "\(NSHomeDirectory())/.local/state/synctray/rc/\(port).auth"
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

    /// Script-consumed token marker: when present, the sync script's bisync branch runs
    /// `--resync --resync-mode newer` (newer copy wins) instead of its usual incremental
    /// sync, then removes the marker on exit 0 ONLY if its content still matches the token
    /// it read at start (so an edit landing mid-run re-arms rather than being swallowed).
    /// Written by `SyncSetupService.writeExcludeFilter` after the filter file, only when a
    /// bisync profile's compiled include rules change (see CLAUDE.md "Critical Rule 7" —
    /// this is the resync-safe alternative to deleting bisync listings). Removed by a plain
    /// `uninstall` (disable/delete) alongside the filter file. Never emitted into the
    /// derived `{shortId}.json` — the script derives this same path on its own.
    var resyncPendingPath: String {
        "\(Self.configDirectory)/\(shortId).resync-pending"
    }

    /// Per-session consumption record for `resyncPendingPath` — written by the sync script
    /// next to the marker so a primary/fallback pair with distinct full-remote-swap sessions
    /// (see "Fallback Remote Pipeline" in CLAUDE.md) each get their own one-time resync before
    /// the marker is cleared. Removed alongside the marker by a plain `uninstall`.
    var resyncConsumedPath: String {
        "\(resyncPendingPath).consumed"
    }

    var launchdLabel: String {
        "com.synctray.sync.\(shortId)"
    }

    var lockFilePath: String {
        "/tmp/synctray-sync-\(shortId).lock"
    }

    // MARK: - Cache-Only overlay paths

    /// Root directory for every profile's Cache-only overlay/writes-cache/exclude-list —
    /// a sibling of the streaming `vfs`/`vfsMeta` trees, never inside either, so none of
    /// this state can ever appear as a file inside the union mount.
    var overlayRootPath: String {
        let base = (vfsCachePath as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent("synctray-overlay")
    }

    /// The writable Cache-only overlay directory for THIS profile — the union mount's
    /// FIRST upstream, so every new file and every edit lands here, never touching the
    /// read-only streaming cache.
    var overlayPath: String {
        (overlayRootPath as NSString).appendingPathComponent(shortId)
    }

    /// Upload-tracking manifest (path + size + mtime AT UPLOAD TIME) for overlay files
    /// already pushed to the remote by "Upload Now" without leaving Cache-only, so a
    /// later drain/keep run can tell an unchanged uploaded file from one needing
    /// re-upload. **Swift WRITES it (`OverlaySyncService.saveManifest`); the sync script
    /// READS it (never writes) at mount time** to apply the same "is this file pending?"
    /// rule as `OverlaySyncService.pendingCount`, so an Upload-Now-and-kept file no longer
    /// forces a spurious `cache-only-pending` mode on remount. Emitted into the derived
    /// `{shortId}.json` as `overlayManifestPath`.
    var overlayManifestPath: String {
        "\(overlayRootPath)/\(shortId).manifest.json"
    }

    /// Regenerated on every Cache-only mount start: one line per partially-downloaded
    /// file under the streaming cache's data tree, so it stays hidden in the union mount
    /// instead of surfacing a truncated read.
    var cacheOnlyExcludePath: String {
        "\(overlayRootPath)/\(shortId).exclude.txt"
    }

    /// A SEPARATE, small VFS cache directory for the cache-only union mount's own
    /// `--vfs-cache-mode writes` bookkeeping (dirty-write tracking for saves into the
    /// overlay). Never the streaming `--cache-dir` — a write here must never touch the
    /// read-only data tree the same mount also serves.
    var cacheOnlyCachePath: String {
        "\(overlayRootPath)/\(shortId).vfscache"
    }

    /// Per-profile rclone config (chmod 0600) defining the `union` remote the cache-only
    /// mount runs under. Lives beside the other per-profile config files, outside the
    /// overlay tree.
    var cacheOnlyConfigPath: String {
        "\(Self.configDirectory)/\(shortId).cacheonly.rclone.conf"
    }

    /// Per-boot mode-signalling file the sync script writes right before starting rclone
    /// — one of `MountMode`'s raw values. Lives in `/tmp` (like the lock file), never
    /// under `~/.config/synctray`, which `MigrationRunner` walks as profile/settings JSON.
    var mountModePath: String {
        "/tmp/synctray-mount-\(shortId).mode"
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
        streamCacheOnly: Bool = false,
        pinnedDirectories: [String] = [],
        warmExcludePatterns: [String] = [],
        syncExcludePatterns: [String] = [],
        syncIncludeFolders: [String] = [],
        rcPort: Int = 0,
        downloadConnections: Int = 2,
        bandwidthLimit: String = "",
        mountResilient: Bool = true
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
        self.streamCacheOnly = streamCacheOnly
        self.pinnedDirectories = pinnedDirectories
        self.warmExcludePatterns = warmExcludePatterns
        self.syncExcludePatterns = syncExcludePatterns
        self.syncIncludeFolders = SyncProfile.normalizedSyncIncludeFolders(syncIncludeFolders)
        self.rcPort = rcPort > 0 ? rcPort : SyncProfile.defaultRCPort(for: id)
        self.downloadConnections = min(16, max(1, downloadConnections))
        self.bandwidthLimit = SyncProfile.normalizedBandwidthLimit(bandwidthLimit)
        self.mountResilient = mountResilient
    }

    /// A `--bwlimit` value SyncTray will pass to rclone, trimmed. Returns "" (unlimited)
    /// for empty/whitespace or anything not matching the shell-safe single-rate grammar
    /// `isValidBandwidthLimit` accepts — so a bad value never reaches the generated script.
    static func normalizedBandwidthLimit(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return isValidBandwidthLimit(trimmed) ? trimmed : ""
    }

    /// True for a bandwidth spec SyncTray supports: empty (unlimited), `off`, or a single
    /// rate `<number><unit?>` optionally as `up:down`, where unit is one of rclone's
    /// b/K/M/G/T/P (with optional `i`, case-insensitive). Deliberately NOT the full rclone
    /// grammar (no space-separated timetables) so the value is a single shell-safe token
    /// the script can pass as one argument.
    static func isValidBandwidthLimit(_ value: String) -> Bool {
        if value.isEmpty { return true }
        let rate = "(?:off|[0-9]+(?:\\.[0-9]+)?[bBkKmMgGtTpP]?i?)"
        let pattern = "^\(rate)(?::\(rate))?$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    /// Normalizes a raw `syncIncludeFolders` list: trims whitespace, strips leading/trailing
    /// `/`, drops any entry that's empty, `/`, or fails `isValidSyncIncludeFolder` (contains a
    /// `.`/`..` path segment, an empty segment, or a line break), then de-duplicates while
    /// keeping first-seen order. Used by the memberwise init and the decoder so every entry
    /// point produces the same, script-safe list.
    static func normalizedSyncIncludeFolders(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            var trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasPrefix("/") { trimmed.removeFirst() }
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            guard isValidSyncIncludeFolder(trimmed), seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// True for a literal, relative folder path safe to compile into an rclone filter rule:
    /// non-empty, no line breaks, and no `.`/`..`/empty path segment (which would otherwise
    /// let an entry escape the profile's root pair or match unintentionally broadly).
    /// Wildcards are deliberately NOT validated here — include folders are literal paths;
    /// globs belong in `syncExcludePatterns`.
    static func isValidSyncIncludeFolder(_ value: String) -> Bool {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("\n"), !trimmed.contains("\r") else { return false }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        for segment in segments {
            if segment.isEmpty || segment == "." || segment == ".." { return false }
        }
        return true
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
        case mountAtStartup
        case streamCacheOnly
        case pinnedDirectories, warmExcludePatterns, syncExcludePatterns, syncIncludeFolders, rcPort
        case downloadConnections
        case bandwidthLimit
        case mountResilient
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
        // Note: the retired cache-pinning and offline-browse-point keys from a
        // superseded feature (see the retired migration slot) are simply ignored if
        // present in an old profile file — no CodingKey, no decode.
        // Backwards compatibility: cache-only is opt-in, so an existing profile keeps
        // streaming from the remote exactly as before.
        streamCacheOnly = try container.decodeIfPresent(Bool.self, forKey: .streamCacheOnly) ?? false
        // Backwards compatibility: default to empty array if not present
        pinnedDirectories = try container.decodeIfPresent([String].self, forKey: .pinnedDirectories) ?? []
        // Backwards compatibility: default to empty array if not present
        warmExcludePatterns = try container.decodeIfPresent([String].self, forKey: .warmExcludePatterns) ?? []
        // Backwards compatibility: default to empty array if not present
        syncExcludePatterns = try container.decodeIfPresent([String].self, forKey: .syncExcludePatterns) ?? []
        // Backwards compatibility: default to empty array if not present. Normalized so a
        // hand-edited profile file can never inject a `.`/`..` escape or a blank entry.
        let decodedIncludeFolders = try container.decodeIfPresent([String].self, forKey: .syncIncludeFolders) ?? []
        syncIncludeFolders = SyncProfile.normalizedSyncIncludeFolders(decodedIncludeFolders)
        // Backwards compatibility: generate default RC port if not present
        let decodedRCPort = try container.decodeIfPresent(Int.self, forKey: .rcPort) ?? 0
        rcPort = decodedRCPort > 0 ? decodedRCPort : SyncProfile.defaultRCPort(for: id)
        // Backwards compatibility: parallel downloads default to 2 (a safe value on a
        // contended Wi-Fi/mesh link or spinning-disk cache). Clamped to the supported
        // 1...16 range so a hand-edited profile file can never inject an out-of-range
        // --transfers.
        let decodedConnections = try container.decodeIfPresent(Int.self, forKey: .downloadConnections) ?? 2
        downloadConnections = min(16, max(1, decodedConnections))
        // Backwards compatibility: no cap by default. Normalized (trimmed + validated to a
        // shell-safe single-rate spec) so a hand-edited profile file can never inject a
        // malformed or space-carrying value into the generated script's rclone command.
        let decodedBandwidth = try container.decodeIfPresent(String.self, forKey: .bandwidthLimit) ?? ""
        bandwidthLimit = SyncProfile.normalizedBandwidthLimit(decodedBandwidth)
        // Default true: a profile persisted before this field existed is upgraded to the
        // resilient mount on its next mount, which is the safer default for the freeze.
        mountResilient = try container.decodeIfPresent(Bool.self, forKey: .mountResilient) ?? true
    }
}

// MARK: - Hashable

extension SyncProfile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

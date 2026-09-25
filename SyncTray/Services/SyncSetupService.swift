import Foundation

/// Service for generating and managing sync scripts and launchd configuration
final class SyncSetupService {
    static let shared = SyncSetupService()

    private init() {}

    // MARK: - Constants

    /// Legacy access-check file name.
    ///
    /// SyncTray no longer uses rclone bisync's `--check-access` (which required a
    /// sentinel file to be uploaded to the remote). Access is now verified by a
    /// read-only pre-flight in the sync script that mutates nothing. This constant
    /// is retained only so leftover files from older versions can be cleaned up.
    static let checkFileName = ".synctray-check"

    /// Default content for the exclude filter file (uses rclone filter-from format)
    /// Each exclude rule must be prefixed with "- "
    private static let defaultExcludeFilter = """
        # macOS metadata
        - ._*
        - .DS_Store
        - .fseventsd

        # Windows thumbs/previews
        - Thumbs.db
        - Thumbs.db:Encryptable
        - ehthumbs.db
        - desktop.ini

        # Synology system folders
        - #recycle/**
        - #snapshot/**
        - @eadir/**

        # Other temp/junk
        - *.tmp
        - *.temp
        - ~$*

        # rclone partial transfer files (prevents cascading .partial.partial... issue)
        - *.partial

        # SyncTray legacy access-check sentinel (no longer used; excluded so it is never synced)
        - .synctray-check
        """

    // MARK: - Rclone Path Helper

    private func findRclonePath() -> String? {
        RcloneLocator.resolve()
    }

    // MARK: - Public Methods (Profile-based)

    /// Check if a profile's scheduled sync is currently installed
    func isInstalled(profile: SyncProfile) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: profile.plistPath) && fm.fileExists(atPath: profile.configPath)
            && fm.fileExists(atPath: SyncProfile.sharedScriptPath)
    }

    /// Check if a profile's launchd agent is currently loaded
    func isLoaded(profile: SyncProfile) -> Bool {
        let result = runCommand("/bin/launchctl", arguments: ["list", profile.launchdLabel])
        return result.exitCode == 0
    }

    /// Rewrite the shared sync script if the installed copy differs from the
    /// current template. The script is normally only written on profile
    /// install/save, so without this an app update would leave already-installed
    /// profiles running the old script until the next re-save.
    /// Called once at app startup. No-op when no profile has been installed yet.
    func refreshSharedScriptIfChanged() {
        let path = SyncProfile.sharedScriptPath
        guard FileManager.default.fileExists(atPath: path) else { return }

        let current = generateSyncScript()
        let onDisk = try? String(contentsOfFile: path, encoding: .utf8)
        guard onDisk != current else { return }

        do {
            try current.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path)
            SyncTraySettings.debugLog("Refreshed shared sync script (template changed)")
        } catch {
            print("Failed to refresh shared sync script: \(error)")
        }
    }

    /// Generate and install the sync script and launchd plist for a profile
    /// - Parameters:
    ///   - profile: The sync profile to install
    ///   - loadAgent: Whether to load the launchd agent immediately (default: true).
    ///                Set to false if you need to run resync first to avoid race conditions.
    func install(profile: SyncProfile, loadAgent: Bool = true) throws {
        // Validate required settings
        guard !profile.rcloneRemote.isEmpty else {
            throw SetupError.missingRcloneRemote
        }
        guard !profile.localSyncPath.isEmpty else {
            throw SetupError.missingLocalPath
        }
        guard !profile.remotePath.isEmpty else {
            throw SetupError.missingRemotePath
        }

        // Create directories if needed
        try createDirectories(for: profile)

        // For mount mode, ensure VFS cache directory exists. Consolidating any stray
        // suffixed cache tree (see "Cache identity" in CLAUDE.md) happens in the sync
        // script itself, on EVERY mount start (install, app launch, login, Mount
        // button) — not here — because a login mount runs the script standalone,
        // without the app; a Swift-only consolidation could be skipped by a mount
        // the app never saw come up.
        if profile.isMountMode {
            let cacheDir = (profile.vfsCachePath as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: cacheDir) {
                try FileManager.default.createDirectory(
                    atPath: cacheDir, withIntermediateDirectories: true)
            }
        }

        // Generate and write the shared script (only if it doesn't exist or needs update)
        let script = generateSyncScript()
        try script.write(toFile: SyncProfile.sharedScriptPath, atomically: true, encoding: .utf8)

        // Make script executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: SyncProfile.sharedScriptPath
        )

        // Generate and write profile config JSON
        let config = generateProfileConfig(for: profile)
        try config.write(toFile: profile.configPath, atomically: true, encoding: .utf8)

        // Generate and write exclude filter (preserves existing user edits)
        // Only needed for sync modes, not mount
        if !profile.isMountMode {
            try writeExcludeFilter(for: profile)
        }

        // Generate and write plist
        let plist = generateLaunchdPlist(for: profile)
        try plist.write(toFile: profile.plistPath, atomically: true, encoding: .utf8)

        // Load the launchd agent (unless deferred for resync)
        if loadAgent {
            _ = runCommand("/bin/launchctl", arguments: ["load", profile.plistPath])
        }
    }

    /// Load the launchd agent for a profile (used after deferred install)
    /// - Returns: true if agent loaded successfully
    @discardableResult
    func loadAgent(for profile: SyncProfile) -> Bool {
        let plistPath = profile.plistPath
        print("[SyncTray] loadAgent called for plist: \(plistPath)")
        print("[SyncTray] plist exists: \(FileManager.default.fileExists(atPath: plistPath))")

        let result = runCommand("/bin/launchctl", arguments: ["load", plistPath])
        print("[SyncTray] launchctl load exit code: \(result.exitCode), output: \(result.output)")
        return result.exitCode == 0
    }

    /// Force a fresh start of a loaded agent's job now, killing any existing
    /// instance first (`kickstart -k`). This is the reliable "(re)mount now" action:
    /// it starts the mount for opt-out profiles (whose RunAtLoad is false so `load`
    /// alone won't run them), AND it recovers a zombie — an `rclone nfsmount` that
    /// kept running (holding the RC port, KeepAlive sees it alive so won't restart
    /// it) after its volume was detached. The `-k` kill re-runs the script, whose
    /// orphan-cleanup + fresh mount then succeed.
    /// - Returns: true if launchctl reported success.
    @discardableResult
    func startAgent(for profile: SyncProfile) -> Bool {
        let uid = getuid()
        let target = "gui/\(uid)/\(profile.launchdLabel)"
        let result = runCommand("/bin/launchctl", arguments: ["kickstart", "-k", target])
        print("[SyncTray] launchctl kickstart -k \(target) exit: \(result.exitCode), output: \(result.output)")
        return result.exitCode == 0
    }

    /// Whether the profile's launchd job currently has a live process. Used as a
    /// liveness signal while polling for a mount to establish: `rclone nfsmount`
    /// walks the whole VFS cache before it attaches the NFS volume, which on a
    /// large cache takes minutes (observed ~112s for a 121GB / 12k-file cache), so
    /// a not-yet-mounted profile whose agent is still running is *establishing*,
    /// not failed. A job that reports no PID (its script/rclone exited and — for a
    /// non-KeepAlive profile — nothing respawned it) is the fail-fast signal that
    /// the mount attempt is genuinely dead rather than slow.
    func isMountAgentRunning(profile: SyncProfile) -> Bool {
        let result = runCommand("/bin/launchctl", arguments: ["list", profile.launchdLabel])
        guard result.exitCode == 0 else { return false }
        // A running job's dict contains a `"PID" = <n>;` entry; a loaded-but-idle
        // job (script exited, awaiting its next KeepAlive/schedule) omits it.
        return result.output.contains("\"PID\" =")
    }

    /// Unload the launchd agent WITHOUT removing any files. Used by pause so a
    /// paused profile stops firing scheduled syncs; resume calls `loadAgent`.
    @discardableResult
    func unloadAgent(for profile: SyncProfile) -> Bool {
        let result = runCommand("/bin/launchctl", arguments: ["unload", profile.plistPath])
        print("[SyncTray] launchctl unload exit code: \(result.exitCode), output: \(result.output)")
        return result.exitCode == 0
    }

    /// Uninstall the sync configuration for a profile
    func uninstall(profile: SyncProfile) throws {
        // For mount-mode profiles, detach the volume gracefully BEFORE unloading the
        // launchd agent. `rclone nfsmount`/`rclone mount` does not exit when its
        // volume is torn down by killing the process out from under it (see
        // `unmount(profile:)` below) — it can leave a stale mount-table entry
        // pointing at a dead server, so any in-flight file access (e.g. an active
        // Stream read) hangs until the entry is cleaned up. This path is reachable
        // any time a mounted profile is uninstalled — including the settings-save
        // reinstall flow (`ProfileDetailView.reinstallSync`), which previously went
        // straight to `launchctl unload` with no detach step at all and could freeze
        // an in-progress stream read for as long as the stale mount lingered.
        if profile.isMountMode {
            let detachStart = Date()
            let wasMounted = isMounted(profile: profile)
            var detachResult = "not_mounted"
            if wasMounted {
                let result = runCommand("/usr/sbin/diskutil", arguments: ["unmount", profile.localSyncPath])
                if result.exitCode == 0 {
                    detachResult = "success"
                } else {
                    let forceResult = runCommand(
                        "/usr/sbin/diskutil", arguments: ["unmount", "force", profile.localSyncPath])
                    detachResult = forceResult.exitCode == 0 ? "success_forced" : "failure"
                }
            }
            let detachDuration = Date().timeIntervalSince(detachStart)
            TelemetryService.shared.recordReinstallDetach(
                profileId: profile.id,
                profileName: profile.name,
                wasMounted: wasMounted,
                result: detachResult,
                durationSeconds: detachDuration
            )
        }

        // Unload the launchd agent first
        _ = runCommand("/bin/launchctl", arguments: ["unload", profile.plistPath])

        // Remove profile-specific files
        let fm = FileManager.default

        if fm.fileExists(atPath: profile.plistPath) {
            try fm.removeItem(atPath: profile.plistPath)
        }

        if fm.fileExists(atPath: profile.configPath) {
            try fm.removeItem(atPath: profile.configPath)
        }

        if fm.fileExists(atPath: profile.filterFilePath) {
            try fm.removeItem(atPath: profile.filterFilePath)
        }

        // Clean up /tmp lock file
        if fm.fileExists(atPath: profile.lockFilePath) {
            try? fm.removeItem(atPath: profile.lockFilePath)
        }

        // Clean up rclone bisync cache files (listings, locks)
        cleanupBisyncCache(for: profile)

        // Note: We don't remove the shared script as other profiles may use it
        // Note: We don't remove log files to preserve history
    }

    /// Remove rclone bisync cache files for a profile (listing files, lock files)
    private func cleanupBisyncCache(for profile: SyncProfile) {
        let cacheDir = (("~/Library/Caches/rclone/bisync" as NSString).expandingTildeInPath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: cacheDir) else { return }

        // Build the base name that rclone uses for cache files
        // Format: {remote}_{remotePath}..{localPath}
        let remote = "\(profile.rcloneRemote)_\(profile.remotePath)"
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")

        var localPath = profile.localSyncPath
        if localPath.hasPrefix("/") {
            localPath = String(localPath.dropFirst())
        }
        let local = localPath.replacingOccurrences(of: "/", with: "_")

        let baseName = "\(remote)..\(local)"

        // Find and remove all files matching this profile's base name
        if let files = try? fm.contentsOfDirectory(atPath: cacheDir) {
            for file in files where file.hasPrefix(baseName) {
                let fullPath = (cacheDir as NSString).appendingPathComponent(file)
                try? fm.removeItem(atPath: fullPath)
            }
        }
    }

    /// Reload the launchd agent for a profile
    func reload(profile: SyncProfile) {
        _ = runCommand("/bin/launchctl", arguments: ["unload", profile.plistPath])
        _ = runCommand("/bin/launchctl", arguments: ["load", profile.plistPath])
    }

    /// Update just the profile config (without reinstalling the script)
    func updateConfig(for profile: SyncProfile) throws {
        let config = generateProfileConfig(for: profile)
        try config.write(toFile: profile.configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Mount Mode Methods

    /// Check if a profile's mount is currently active
    func isMounted(profile: SyncProfile) -> Bool {
        let result = runCommand("/sbin/mount", arguments: [])
        return result.output.contains(" on \(profile.localSyncPath) ")
    }

    /// A single `isMounted` sample taken immediately after `uninstall`
    /// returns can false-positive: a stale mount-table entry can briefly
    /// linger even after a successful `diskutil unmount` (the exact failure
    /// mode `uninstall`'s own doc comment names), and a `KeepAlive` launchd
    /// agent can win a race and remount before the caller gets to check.
    /// Poll a few times with a short delay before concluding the volume is
    /// GENUINELY still attached, rather than aborting an entire cache
    /// migration on one sample (finding 4). Bounded to a few hundred
    /// milliseconds total — this runs synchronously on whichever thread
    /// calls it, matching the existing synchronous `diskutil`/`launchctl`
    /// invocations in `uninstall`/`install`.
    func isMountedAfterBoundedRecheck(profile: SyncProfile, attempts: Int = 3, delaySeconds: TimeInterval = 0.15) -> Bool {
        for attempt in 0..<attempts {
            if !isMounted(profile: profile) { return false }
            if attempt < attempts - 1 {
                Thread.sleep(forTimeInterval: delaySeconds)
            }
        }
        return true
    }

    /// Unmount a mounted profile and stop its daemon.
    func unmount(profile: SyncProfile) throws {
        guard profile.isMountMode else {
            throw SetupError.notMountMode
        }

        // Detach the volume if it's currently mounted (graceful, then force).
        if isMounted(profile: profile) {
            let result = runCommand("/usr/sbin/diskutil", arguments: ["unmount", profile.localSyncPath])
            if result.exitCode != 0 {
                let forceResult = runCommand(
                    "/usr/sbin/diskutil", arguments: ["unmount", "force", profile.localSyncPath])
                if forceResult.exitCode != 0 {
                    throw SetupError.unmountFailed(forceResult.output)
                }
            }
        }

        // Stop the rclone daemon. `rclone nfsmount` does NOT exit when its volume is
        // detached — it keeps its NFS server + RC port alive as a "running but
        // unmounted" zombie, and KeepAlive would immediately remount it. Unloading
        // the agent terminates rclone and makes the unmount stick; the Mount button
        // (loadAgent + kickstart) brings it back on demand, and an enabled
        // mountAtStartup re-mounts it on the next launch/login. Runs even when the
        // volume was already detached, so it also reaps a pre-existing zombie.
        _ = unloadAgent(for: profile)
    }

    /// Clean up **orphaned** mounts on app startup — a mount point still in the mount
    /// table whose `rclone` process is gone (e.g. left behind by a crash), which macOS
    /// would otherwise surface as a dead volume.
    ///
    /// Matches mount points against the known mount-mode profile paths rather than
    /// the filesystem type. This is both backend-agnostic (handles macFUSE *and* the
    /// kext-free NFS backend, whose `mount` lines don't contain "rclone") and safe —
    /// it will never force-unmount an unrelated NFS share the user mounted themselves.
    ///
    /// **Liveness gate (critical):** a managed mount point is force-unmounted ONLY when
    /// its owning profile's launchd job is NOT running — i.e. no live `rclone` is serving
    /// it. A HEALTHY live mount (job running) is left untouched. Without this gate, every
    /// app launch tore down a perfectly good stream and let launchd `KeepAlive` remount it
    /// (a multi-minute cache walk on a large VFS cache), which macOS reports as "Server
    /// connections interrupted" — a self-inflicted disconnect on startup.
    /// - Parameter mountProfiles: mount-mode profiles whose paths are owned by SyncTray.
    func cleanupStaleMounts(mountProfiles: [SyncProfile]) {
        let managed = mountProfiles.filter { $0.isMountMode }
        guard !managed.isEmpty else { return }
        // Map mount point → owning profile so we can check that profile's liveness.
        let profileByPath = Dictionary(managed.map { ($0.localSyncPath, $0) },
                                       uniquingKeysWith: { first, _ in first })

        let result = runCommand("/sbin/mount", arguments: [])
        let lines = result.output.components(separatedBy: "\n")

        for line in lines {
            // Extract the mount point from a line like "remote: on /path (osxfuse...)"
            // or "localhost:/ on /path (nfs, ...)".
            guard let onRange = line.range(of: " on "),
                  let parenRange = line.range(of: " (") else { continue }
            let mountPoint = String(line[onRange.upperBound..<parenRange.lowerBound])

            // Only touch paths SyncTray manages — never a user's own NFS/FUSE mount.
            guard let profile = profileByPath[mountPoint] else { continue }

            // Leave a HEALTHY live mount alone; only clear a genuine orphan (job dead).
            if isMountAgentRunning(profile: profile) { continue }
            _ = runCommand("/usr/sbin/diskutil", arguments: ["unmount", "force", mountPoint])
        }
    }

    /// Initializes sync paths by creating the local directory and removing any
    /// obsolete `.synctray-check` files left behind by older versions.
    /// - Returns: nil on success, error message on failure
    func initializeSyncPaths(for profile: SyncProfile) -> String? {
        let fileManager = FileManager.default

        // 1. Create local directory if needed
        if !fileManager.fileExists(atPath: profile.localSyncPath) {
            do {
                try fileManager.createDirectory(
                    atPath: profile.localSyncPath, withIntermediateDirectories: true)
            } catch {
                return "Failed to create local directory: \(error.localizedDescription)"
            }
        }

        // 2. Remove any obsolete .synctray-check files (best-effort).
        //    SyncTray no longer relies on rclone --check-access, so nothing is
        //    written to the remote — access is verified read-only in the sync script.
        cleanupLegacyCheckFiles(for: profile)

        return nil  // Success
    }

    /// Best-effort, recursive removal of the legacy `.synctray-check` access-check file
    /// from the local and remote trees (root and all nested directories).
    ///
    /// SyncTray previously uploaded this sentinel so rclone bisync's `--check-access`
    /// could verify both sides were mounted. That mechanism has been replaced by a
    /// read-only pre-flight in the sync script, so the file is now obsolete. SyncTray
    /// only ever wrote one at each root, but we scan the whole tree to also catch any
    /// copies a user (or an older/manual setup) may have scattered into subdirectories.
    ///
    /// Safe to call repeatedly; never throws. The remote deletion lists the remote, so
    /// call this from a background context.
    func cleanupLegacyCheckFiles(for profile: SyncProfile, rclonePath: String? = nil) {
        let fileManager = FileManager.default

        // Local: remove every .synctray-check at any depth under the sync root.
        if let enumerator = fileManager.enumerator(atPath: profile.localSyncPath) {
            for case let relativePath as String in enumerator
            where (relativePath as NSString).lastPathComponent == Self.checkFileName {
                let fullPath = (profile.localSyncPath as NSString).appendingPathComponent(relativePath)
                try? fileManager.removeItem(atPath: fullPath)
            }
        }

        // Remote: delete every .synctray-check at any depth. Skip if we can't resolve a
        // path/remote. The `--include <basename>` filter matches the file at any level and
        // (because an include is present) rclone implicitly excludes everything else, so no
        // user data is ever touched.
        guard let rclonePath = rclonePath ?? findRclonePath(),
              !profile.rcloneRemote.isEmpty, !profile.remotePath.isEmpty else { return }

        let remoteRoot = "\(profile.rcloneRemote):\(profile.remotePath)"
        let skipCert = RcloneConfigService.shared.readRemoteConfig(name: profile.rcloneRemote)?.values["no_check_certificate"] == "true"
        _ = runRcloneSimple(
            rclonePath: rclonePath,
            args: ["delete", remoteRoot, "--include", Self.checkFileName],
            skipCert: skipCert)
    }

    /// Run rclone with given args, return exit code (or -1 on launch failure).
    /// Adds connection/operation timeouts so unreachable remotes fail within ~15s.
    private func runRcloneSimple(rclonePath: String, args: [String], skipCert: Bool) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclonePath)
        var fullArgs = args + ["--contimeout", "5s", "--timeout", "15s", "--retries", "1", "--low-level-retries", "1"]
        if skipCert { fullArgs.append("--no-check-certificate") }
        process.arguments = fullArgs
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// Checks if listing files exist for this profile's path combination
    func hasExistingListings(for profile: SyncProfile) -> Bool {
        let cacheDir = (("~/Library/Caches/rclone/bisync" as NSString).expandingTildeInPath)

        // Build the path hash that rclone uses for listing filenames
        // rclone format: {remote}_{remotePath}..{localPath} with / replaced by _ and leading _ removed
        let remote = "\(profile.rcloneRemote)_\(profile.remotePath)"
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")

        // Remove leading slash before replacing to match rclone's format
        var localPath = profile.localSyncPath
        if localPath.hasPrefix("/") {
            localPath = String(localPath.dropFirst())
        }
        let local = localPath.replacingOccurrences(of: "/", with: "_")

        let baseName = "\(remote)..\(local)"

        // Only check for .lst files (not .lst-new which are incomplete/partial)
        // The .lst files are only created after a successful bisync completes
        let listingPath1 = (cacheDir as NSString).appendingPathComponent("\(baseName).path1.lst")
        let listingPath2 = (cacheDir as NSString).appendingPathComponent("\(baseName).path2.lst")

        let fm = FileManager.default
        // Both listing files must exist for sync to work without --resync
        return fm.fileExists(atPath: listingPath1) && fm.fileExists(atPath: listingPath2)
    }

    // MARK: - Legacy Methods (for backward compatibility during migration)

    /// Check if the legacy single-profile scheduled sync is installed
    func isLegacyInstalled() -> Bool {
        let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/com.synctray.sync.plist"
        let scriptPath = "\(NSHomeDirectory())/.local/bin/synctray-sync.sh"

        // Check if it's the old-style script (without config file support)
        if FileManager.default.fileExists(atPath: scriptPath),
            let content = try? String(contentsOfFile: scriptPath, encoding: .utf8)
        {
            // Old scripts have hardcoded REMOTE= values, new ones read from config
            return content.contains("REMOTE=\"") && !content.contains("CONFIG_FILE=")
        }

        return FileManager.default.fileExists(atPath: plistPath)
    }

    /// Uninstall legacy single-profile configuration
    func uninstallLegacy() throws {
        let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/com.synctray.sync.plist"

        _ = runCommand("/bin/launchctl", arguments: ["unload", plistPath])

        let fm = FileManager.default
        if fm.fileExists(atPath: plistPath) {
            try fm.removeItem(atPath: plistPath)
        }
        // Don't remove the script path since we'll reuse it
    }

    // MARK: - Script Generation

    /// `OverlaySyncService.ignoredNamePatterns` rendered as a Python list literal, so the
    /// script's "is this overlay file real or Finder junk" check can never drift from the
    /// Swift-side overlay scanner/uploader that uses the exact same list (D18 — one source
    /// for the ignore list, never retyped in bash/Python).
    private var overlayIgnorePatternsPythonLiteral: String {
        "[" + OverlaySyncService.ignoredNamePatterns.map { "'\($0)'" }.joined(separator: ", ") + "]"
    }

    /// Generate the shared sync script that reads config from JSON
    /// Supports bisync (two-way), sync (one-way), and mount (streaming, or a Cache Only
    /// union-overlay mount) modes. Internal (not `private`) so the self-test harness can
    /// render it directly and dry-run it end to end (`SYNCTRAY_DRY_RUN=1`) without going
    /// through `install`/`launchctl` — this codebase has no XCTest target, so exercising the
    /// generated script IS the test for the mount branch's mode-selection and command logic.
    func generateSyncScript() -> String {
        return """
            #!/bin/bash
            # SyncTray Sync Script
            # This script reads profile configuration from a JSON file
            # Supports bisync (two-way), sync (one-way), and mount (streaming) modes
            # DO NOT EDIT - This file is managed by SyncTray

            # launchd hands us a minimal PATH that omits /sbin. The NFS backend
            # (`rclone nfsmount`) shells out to the system `mount` / `mount_nfs`
            # binaries, both in /sbin — without this they fail with
            # "exec: \\"mount\\": executable file not found in $PATH". Prepend the
            # system sbin dirs so both backends resolve their helpers.
            export PATH="/sbin:/usr/sbin:/usr/bin:/bin:$PATH"

            CONFIG_FILE="$1"

            if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
                echo "Error: Config file not specified or not found: $CONFIG_FILE"
                exit 1
            fi

            # Parse JSON config using Python (available on all macOS)
            parse_json() {
                python3 -c "import json,sys; d=json.load(open('$CONFIG_FILE')); print(d.get('$1', '$2'))"
            }

            REMOTE=$(parse_json "remote" "")
            LOCAL_PATH=$(parse_json "localPath" "")
            LOG_FILE=$(parse_json "logPath" "")
            LOCK_FILE=$(parse_json "lockFile" "")
            DRIVE_PATH=$(parse_json "drivePath" "")
            ADDITIONAL_FLAGS=$(parse_json "additionalFlags" "")
            FILTER_FILE=$(parse_json "filterPath" "")
            SYNC_MODE=$(parse_json "syncMode" "bisync")
            SYNC_DIRECTION=$(parse_json "syncDirection" "localToRemote")
            FALLBACK_REMOTE=$(parse_json "fallbackRemote" "")
            FALLBACK_PATH=$(parse_json "fallbackRemotePath" "")
            FALLBACK_REQUIRES_CACHE_REBUILD=$(parse_json "fallbackRequiresCacheRebuild" "false")
            REMOTE_PATH=$(parse_json "remotePath" "")
            # Default to the kext-free NFS backend when the key is absent — the Swift
            # model decodes the same default. Keep the two in lockstep so a profile
            # whose JSON predates the mountBackend field mounts via nfsmount (no macFUSE
            # install required) rather than falling back to FUSE.
            MOUNT_BACKEND=$(parse_json "mountBackend" "nfs")
            VFS_CACHE_MODE=$(parse_json "vfsCacheMode" "full")
            VFS_CACHE_MAX_SIZE=$(parse_json "vfsCacheMaxSize" "10G")
            VFS_CACHE_MAX_AGE=$(parse_json "vfsCacheMaxAge" "168h")
            VFS_CACHE_PATH=$(parse_json "vfsCachePath" "$HOME/.cache/rclone")
            # Expand a leading `~` ONCE, here, and use the result everywhere below.
            # `vfsCachePath` is stored raw (the CLI and the file-backed config both keep a
            # user-written `~`) and every Swift read site expands on read, but the shell
            # passes it through quoted — so an unexpanded value made rclone create a
            # directory literally named `~` in its working directory, silently putting the
            # cache somewhere neither the app nor the preflight looks.
            VFS_CACHE_PATH="${VFS_CACHE_PATH/#\\~/$HOME}"
            # Cache Only: the user's MANUAL choice (persisted). The script may also pick
            # a Cache Only flavour on its own — see mode selection below — regardless of
            # this flag.
            STREAM_CACHE_ONLY=$(parse_json "streamCacheOnly" "false")
            # Cache-only / mode-signalling paths — Swift is the single source of these
            # (SyncProfile computed paths + VFSCacheService.cacheSubtreeRoots), so the
            # script and the app can never disagree about which directory is which.
            # Empty defaults keep an old derived config (predating these keys) mounting
            # streaming-only, with a warning, instead of failing outright.
            MOUNT_MODE_PATH=$(parse_json "mountModePath" "")
            OVERLAY_PATH=$(parse_json "overlayPath" "")
            CACHE_ONLY_CONFIG_PATH=$(parse_json "cacheOnlyConfigPath" "")
            CACHE_ONLY_EXCLUDE_PATH=$(parse_json "cacheOnlyExcludePath" "")
            CACHE_ONLY_CACHE_PATH=$(parse_json "cacheOnlyCachePath" "")
            CACHE_DATA_PATH=$(parse_json "cacheDataPath" "")
            CACHE_META_PATH=$(parse_json "cacheMetaPath" "")
            # Parallel downloaders. Defaults to 2 — a safe value on a contended Wi-Fi/mesh
            # link (or spinning-disk cache) where extra streams contend and collapse
            # aggregate throughput. Raise it (up to 16) for a fast wired link.
            DOWNLOAD_CONNECTIONS=$(parse_json "downloadConnections" "2")
            ALLOW_NON_EMPTY=$(parse_json "allowNonEmptyMount" "false")
            RC_PORT=$(parse_json "rcPort" "0")

            if [[ -z "$REMOTE" || -z "$LOCAL_PATH" ]]; then
                echo "Error: Invalid config - missing remote or localPath"
                exit 1
            fi

            # Find rclone binary. Cover the common package-manager locations,
            # including nix-darwin's system and per-user profiles which live outside
            # Homebrew's dirs (issue #53). $USER can be unset under launchd, so derive
            # it. Fall back to a PATH lookup for any other install layout.
            RCLONE_USER="${USER:-$(id -un)}"
            RCLONE_BIN=""
            RCLONE_CANDIDATES=(
                /opt/homebrew/bin/rclone
                /usr/local/bin/rclone
                /run/current-system/sw/bin/rclone
                "/etc/profiles/per-user/$RCLONE_USER/bin/rclone"
                "$HOME/.nix-profile/bin/rclone"
                /usr/bin/rclone
            )
            for path in "${RCLONE_CANDIDATES[@]}"; do
                if [[ -x "$path" ]]; then
                    RCLONE_BIN="$path"
                    break
                fi
            done

            if [[ -z "$RCLONE_BIN" ]]; then
                RCLONE_BIN=$(command -v rclone 2>/dev/null || true)
            fi

            if [[ -z "$RCLONE_BIN" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: rclone not found" >> "$LOG_FILE"
                exit 1
            fi

            # Helper: check if a remote has no_check_certificate set in rclone config
            check_no_cert() {
                local remote_name="$1"
                local rclone_conf="$HOME/.config/rclone/rclone.conf"
                if [[ -f "$rclone_conf" ]]; then
                    local in_section=false
                    while IFS= read -r line; do
                        if [[ "$line" == "[$remote_name]" ]]; then
                            in_section=true
                        elif [[ "$line" =~ ^\\[.+\\]$ ]] && $in_section; then
                            break
                        elif $in_section && [[ "$line" == *"no_check_certificate"*"="*"true"* ]]; then
                            echo "--no-check-certificate"
                            return
                        fi
                    done < "$rclone_conf"
                fi
            }

            # Re-emit one remote's stored rclone config as RCLONE_CONFIG_<NAME>_<KEY> export
            # lines, reading `rclone config dump` JSON on stdin.
            #   $1 — remote to read FROM (as it appears in rclone.conf)
            #   $2 — already upper-cased/underscored name to export UNDER
            # The caller `eval`s the output. Both arguments are passed as argv, never
            # interpolated into the Python source, and every value goes through
            # `shlex.quote`, so a config value containing a quote, a space, a backslash or a
            # `$` round-trips intact. (It previously did not: the `\\"` escapes were consumed
            # by the enclosing double-quoted shell string before Python ever saw them, so a
            # password containing a double quote produced an unterminated `eval`.)
            dump_remote_as_env() {
                python3 -c "
            import json, shlex, sys
            remote, prefix = sys.argv[1], sys.argv[2]
            for k, v in json.load(sys.stdin).get(remote, {}).items():
                key = k.upper().replace('-', '_')
                print('export RCLONE_CONFIG_%s_%s=%s' % (prefix, key, shlex.quote(str(v))))
            " "$1" "$2"
            }

            REMOTE_NAME="${REMOTE%%:*}"
            NO_CHECK_CERT=$(check_no_cert "$REMOTE_NAME")

            # Run a command with a HARD wall-clock timeout. macOS ships no
            # coreutils `timeout`, and rclone's own --contimeout/--timeout are
            # not always honoured by the SMB backend (a hibernating/unreachable
            # NAS could hang the reachability probe for many minutes while
            # holding the lock). This kills the probe if it overruns so the run
            # exits promptly and releases the lock. Returns 124 on timeout.
            run_with_timeout() {
                local secs="$1"; shift
                "$@" &
                local cmd_pid=$!
                ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null; sleep 2; kill -KILL "$cmd_pid" 2>/dev/null ) &
                local watchdog_pid=$!
                wait "$cmd_pid" 2>/dev/null
                local status=$?
                kill "$watchdog_pid" 2>/dev/null
                wait "$watchdog_pid" 2>/dev/null
                return $status
            }

            # Check if drive is mounted (if configured)
            if [[ -n "$DRIVE_PATH" && ! -d "$DRIVE_PATH" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Drive not mounted, skipping sync" >> "$LOG_FILE"
                exit 0
            fi

            # Acquire the lock ATOMICALLY. `set -o noclobber` makes the '>'
            # redirection fail if the file already exists, so the check and the
            # write are a single atomic step — closing the check-then-write
            # (TOCTOU) race where two launchd/manual runs could both pass the
            # old `[[ -f ]]` test and start concurrently. The PID is still stored
            # as the file's contents, so the app's lock readers are unchanged.
            acquire_lock() {
                ( set -o noclobber; echo $$ > "$LOCK_FILE" ) 2>/dev/null
            }

            if ! acquire_lock; then
                PID=$(cat "$LOCK_FILE" 2>/dev/null)
                if [[ -n "$PID" ]] && ps -p "$PID" > /dev/null 2>&1; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync already running (PID $PID), skipping" >> "$LOG_FILE"
                    exit 0
                fi
                # Lock owner is gone — reclaim the stale lock and retry once.
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Removing stale lock (PID ${PID:-unknown} not running)" >> "$LOG_FILE"
                rm -f "$LOCK_FILE"
                if ! acquire_lock; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Could not acquire lock, skipping" >> "$LOG_FILE"
                    exit 0
                fi
            fi
            trap 'rm -f "$LOCK_FILE"' EXIT

            # Ensure local sync directory exists
            mkdir -p "$LOCAL_PATH"

            # Remote fallback: if primary remote is unreachable, try fallback remote.
            # NEVER for mount mode — a Stream profile picks its rclone mode (streaming /
            # cache-only-*) independently below, and its fallback remote is only ever an
            # Upload Now target driven from the app side. Failing a MOUNT over here would
            # need a second vfs/{fallback}/… cache tree (the subtree keys on remote name
            # + path), which is exactly the bug this whole change removes — see "Cache
            # identity" in CLAUDE.md.
            if [[ "$SYNC_MODE" != "mount" && -n "$FALLBACK_REMOTE" ]]; then
                REMOTE_NAME="${REMOTE%%:*}"
                # Quick reachability check on primary remote (3s connect timeout)
                if ! run_with_timeout 15 $RCLONE_BIN lsd "${REMOTE_NAME}:" --contimeout 3s --timeout 8s --max-depth 0 $NO_CHECK_CERT &>/dev/null; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Primary remote unreachable, using fallback: $FALLBACK_REMOTE" >> "$LOG_FILE"
                    # Re-check cert setting for the fallback remote
                    NO_CHECK_CERT=$(check_no_cert "$FALLBACK_REMOTE")

                    if [[ -z "$FALLBACK_PATH" && "$FALLBACK_REQUIRES_CACHE_REBUILD" != "true" && "$FALLBACK_REQUIRES_CACHE_REBUILD" != "True" ]]; then
                        # Same remote name preserved: use env var overrides to swap transport.
                        # This preserves the bisync listing cache since the remote name stays the same.
                        UPPER_NAME=$(echo "$REMOTE_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
                        eval "$($RCLONE_BIN config dump 2>/dev/null | dump_remote_as_env "$FALLBACK_REMOTE" "$UPPER_NAME")"
                    else
                        # Different wire type OR explicit path change: swap entire REMOTE reference.
                        # bisync will rebuild listings on first switch (~12s for 85K files).
                        REMOTE="${FALLBACK_REMOTE}:${FALLBACK_PATH:-$REMOTE_PATH}"
                    fi
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Using primary remote: $REMOTE_NAME" >> "$LOG_FILE"
                fi
            fi

            # Build rclone command based on sync mode
            if [[ "$SYNC_MODE" == "mount" ]]; then
                # Mount mode - stream files on-demand
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting mount" >> "$LOG_FILE"

                # VFS CACHE PREFLIGHT
                #
                # When --cache-dir is not writable, rclone logs "Failed to create vfs cache -
                # disabling" and then MOUNTS ANYWAY with no cache at all. Every read becomes a
                # remote round trip, which reads to a user as "streaming got mysteriously
                # slow" rather than as a failure. The common trigger is a cache directory on
                # an external drive that isn't attached: /Volumes/<Drive> is then a
                # root-owned placeholder and the mkdir fails with EPERM.
                #
                # Refuse the mount instead. launchd's KeepAlive retries, so the profile comes
                # up by itself once the drive is back — with its cache intact.
                #
                # This checks the SAME path that goes to --cache-dir (both expanded above),
                # so the preflight can't pass while rclone caches somewhere else.
                if ! mkdir -p "$VFS_CACHE_PATH" 2>/dev/null || [[ ! -w "$VFS_CACHE_PATH" ]]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: VFS cache directory not writable: $VFS_CACHE_PATH - refusing to mount uncached" >> "$LOG_FILE"
                    # Release the lock BEFORE backing off. KeepAlive restarts us on exit, so
                    # the sleep only exists to stop a hot respawn loop while the drive is
                    # away — holding the lock through it would silently swallow a manual
                    # Mount (the app's trigger takes the same lock) for 30s at a time.
                    rm -f "$LOCK_FILE"
                    trap - EXIT
                    sleep 30
                    exit 1
                fi

                # Ensure mount point exists
                mkdir -p "$LOCAL_PATH"

                # Check if already mounted
                if mount | grep -q " on $LOCAL_PATH "; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Already mounted at $LOCAL_PATH" >> "$LOG_FILE"
                    exit 0
                fi

                # Not mounted, but a previous rclone for this mount point may still
                # be alive after a failed attempt (its RC/NFS server keeps holding
                # the RC port). If we start a new one it collides with
                # "bind: address already in use" and the mount never establishes —
                # and launchd's KeepAlive turns that into a retry storm. Clear any
                # such orphan (scoped to THIS mount point) before starting.
                # Anchor the mount point with a trailing space so a profile whose
                # path is a prefix of another (…/Reaper vs …/Reaper/Temp) can't match
                # and kill the wrong mount's rclone. The path is a positional arg
                # always followed by " --vfs-cache-mode …" on the command line.
                STALE_MOUNT_PIDS=$(pgrep -f "rclone .*mount .*${LOCAL_PATH} " 2>/dev/null)
                if [[ -n "$STALE_MOUNT_PIDS" ]]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Clearing orphaned rclone for $LOCAL_PATH: $STALE_MOUNT_PIDS" >> "$LOG_FILE"
                    kill $STALE_MOUNT_PIDS 2>/dev/null
                    # Wait briefly for the RC port to be released
                    sleep 2
                fi

                # CACHE KEY CONSOLIDATION
                #
                # Defining a remote via RCLONE_CONFIG_<NAME>_* environment variables used to
                # make rclone suffix the cache directory name ("detected overridden config -
                # adding {hash} suffix to name"), landing the cache at vfs/{primary}{hash}/…
                # instead of vfs/{primary}/…. That env-var trick is gone from this script
                # (mount mode no longer swaps remotes — see the removed fallback branch above
                # and CLAUDE.md's "Cache identity" section), but a tree a PAST run left behind
                # under a suffixed name is still on disk. Consolidate it into the unsuffixed
                # location on every mount start, before rclone comes up, so a leftover
                # suffixed tree is adopted rather than abandoned and re-downloaded.
                #
                # Deferred (not run at all) while another rclone mount process is using the
                # SAME --cache-dir: two nested profiles can share one suffixed tree, and
                # racing a live mount's cache with a rename mid-flight is not safe.
                if pgrep -f "cache-dir ${VFS_CACHE_PATH} " >/dev/null 2>&1; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Cache key consolidation deferred (another rclone mount is using this cache dir)" >> "$LOG_FILE"
                else
                    python3 -c "
            import os, sys

            primary, remote_path, cache_root, log_file = sys.argv[1:5]

            def log(msg):
                try:
                    with open(log_file, 'a') as f:
                        f.write(msg + chr(10))
                except Exception:
                    pass

            try:
                vfs_base = os.path.join(cache_root, 'vfs')
                meta_base = os.path.join(cache_root, 'vfsMeta')
                prefix = primary + '{'

                def subtree(base, name):
                    root = os.path.join(base, name)
                    return os.path.join(root, remote_path) if remote_path else root

                def clear_if_empty(path):
                    # An EMPTY destination directory tree (no file anywhere under it) is
                    # what a mount of the unsuffixed key leaves behind before any byte was
                    # cached. Treat it as absent: remove only its empty directories, bottom
                    # up, with os.rmdir (never rmtree). Anything that is not an empty
                    # directory -- a file, a symlink -- makes rmdir fail, so the path still
                    # exists afterwards and counts as populated.
                    if os.path.islink(path) or not os.path.isdir(path):
                        return
                    for root, dirs, files in os.walk(path):
                        if files:
                            return
                    for root, dirs, files in os.walk(path, topdown=False):
                        try:
                            os.rmdir(root)
                        except OSError:
                            return

                def prune_ancestors(path, base):
                    ancestor = os.path.dirname(path)
                    while ancestor.startswith(base) and ancestor != base:
                        try:
                            os.rmdir(ancestor)
                        except OSError:
                            break
                        ancestor = os.path.dirname(ancestor)

                chosen = None
                if os.path.isdir(vfs_base):
                    candidates = []
                    for name in os.listdir(vfs_base):
                        if not (name.startswith(prefix) and name.endswith('}')):
                            continue
                        suffix = name[len(prefix):-1]
                        if not suffix or not all(c.isalnum() or c in '_-' for c in suffix):
                            continue
                        probe = subtree(vfs_base, name)
                        if os.path.isdir(probe):
                            try:
                                candidates.append((name, os.path.getmtime(probe)))
                            except OSError:
                                pass
                    if candidates:
                        candidates.sort(key=lambda item: item[1], reverse=True)
                        chosen = candidates[0][0]

                # ONE decision for the vfs/vfsMeta PAIR. The two trees are only meaningful
                # together: rclone deletes cached data whose metadata sidecar is missing, and
                # a sidecar without its data describes bytes that are not there. So move
                # nothing unless BOTH source trees exist and NEITHER destination is populated,
                # and never merge into an occupied destination.
                if chosen:
                    src_meta, src_vfs = subtree(meta_base, chosen), subtree(vfs_base, chosen)
                    dst_meta, dst_vfs = subtree(meta_base, primary), subtree(vfs_base, primary)
                    if not (os.path.isdir(src_meta) and os.path.isdir(src_vfs)):
                        log('Cache key: leaving ' + src_vfs + ' in place (its vfs and vfsMeta trees are not both present)')
                    else:
                        clear_if_empty(dst_meta)
                        clear_if_empty(dst_vfs)
                        if os.path.lexists(dst_meta) or os.path.lexists(dst_vfs):
                            log('Cache key: leaving ' + src_vfs + ' in place (destination already populated)')
                        else:
                            # vfsMeta first: an interruption between the two renames can only
                            # leave metadata ahead of data, never data without its byte ranges.
                            os.makedirs(os.path.dirname(dst_meta), exist_ok=True)
                            os.rename(src_meta, dst_meta)
                            try:
                                os.makedirs(os.path.dirname(dst_vfs), exist_ok=True)
                                os.rename(src_vfs, dst_vfs)
                            except Exception as e:
                                try:
                                    os.rename(dst_meta, src_meta)
                                    log('Cache key: vfs move failed, rolled vfsMeta back to ' + src_meta + ': ' + str(e))
                                except Exception as rollback_error:
                                    log('Cache key: vfs move failed AND vfsMeta rollback failed (' + dst_meta + '): ' + str(e) + ' / ' + str(rollback_error))
                            else:
                                log('Cache key: moved ' + src_meta + ' -> ' + dst_meta)
                                log('Cache key: moved ' + src_vfs + ' -> ' + dst_vfs)
                                prune_ancestors(src_meta, meta_base)
                                prune_ancestors(src_vfs, vfs_base)
            except Exception as e:
                log('Cache key consolidation error: ' + str(e))
            " "$REMOTE_NAME" "$REMOTE_PATH" "$VFS_CACHE_PATH" "$LOG_FILE"
                fi

                # Choose the mount backend:
                #   nfs     -> rclone nfsmount (built-in NFS server + native macOS NFS
                #              client). Kext-free: needs no macFUSE, works on locked-down
                #              Macs. This is the default for new profiles.
                #   macfuse -> rclone mount (classic FUSE; requires macFUSE + official rclone)
                if [[ "$MOUNT_BACKEND" == "macfuse" ]]; then
                    MOUNT_SUBCMD="mount"
                else
                    MOUNT_SUBCMD="nfsmount"
                fi
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Mount backend: $MOUNT_BACKEND ($MOUNT_SUBCMD)" >> "$LOG_FILE"

                # Name the mounted volume after the mount-point folder so Finder
                # shows e.g. "Temp" instead of the auto-generated NFS share name
                # ("localhost:/synology home Reaper"). macFUSE already derives the
                # volume name from the mountpoint; the NFS backend does not, so set
                # it explicitly. --volname is supported on macOS for both backends,
                # and both streaming and Cache Only mounts want it.
                MOUNT_VOLNAME=$(basename "$LOCAL_PATH")

                # MOUNT MODE SELECTION
                #
                # Four tokens (MountMode in SyncState.swift): "streaming", or one of three
                # Cache Only flavours — "cache-only-manual" (the user's own toggle),
                # "cache-only-pending" (files are queued in the overlay from a previous Cache
                # Only session and haven't finished uploading), and "cache-only-offline" (the
                # primary remote is unreachable right now). Any Cache Only flavour mounts the
                # SAME union remote; the token only changes what the status card shows and
                # what auto-resume watches for.
                #
                # A derived config written by an OLDER app build has none of the cache-only
                # keys (mountModePath is empty) — degrade to streaming-only rather than
                # half-apply a mode this script version doesn't know how to fully wire.
                MOUNT_MODE="\(MountMode.streaming.rawValue)"
                if [[ -z "$MOUNT_MODE_PATH" ]]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Cache Only unavailable (config predates this feature) - streaming only" >> "$LOG_FILE"
                else
                    OVERLAY_PENDING=$(python3 -c "
            import fnmatch, json, os, sys

            overlay_path, cache_path = sys.argv[1], sys.argv[2]
            ignore_patterns = \(overlayIgnorePatternsPythonLiteral)

            def is_ignored(name):
                return any(fnmatch.fnmatchcase(name, p) for p in ignore_patterns)

            pending = False

            if overlay_path and os.path.isdir(overlay_path):
                for root, dirs, files in os.walk(overlay_path):
                    dirs[:] = [d for d in dirs if not is_ignored(d)]
                    if any(not is_ignored(f) for f in files):
                        pending = True
                        break

            if not pending and cache_path:
                meta_dir = os.path.join(cache_path, 'vfsMeta')
                if os.path.isdir(meta_dir):
                    for root, dirs, files in os.walk(meta_dir):
                        for f in files:
                            try:
                                with open(os.path.join(root, f)) as fh:
                                    meta = json.load(fh)
                            except Exception:
                                continue
                            if meta.get('Dirty') is True:
                                pending = True
                                break
                        if pending:
                            break

            print('true' if pending else 'false')
            " "$OVERLAY_PATH" "$CACHE_ONLY_CACHE_PATH")

                    if [[ "$STREAM_CACHE_ONLY" == "true" || "$STREAM_CACHE_ONLY" == "True" ]]; then
                        MOUNT_MODE="\(MountMode.cacheOnlyManual.rawValue)"
                    elif [[ "$OVERLAY_PENDING" == "true" ]]; then
                        MOUNT_MODE="\(MountMode.cacheOnlyPending.rawValue)"
                    elif ! run_with_timeout 15 $RCLONE_BIN lsd "${REMOTE_NAME}:" --contimeout 3s --timeout 8s --max-depth 0 $NO_CHECK_CERT &>/dev/null; then
                        MOUNT_MODE="\(MountMode.cacheOnlyOffline.rawValue)"
                    fi
                fi
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Mount mode: $MOUNT_MODE" >> "$LOG_FILE"
                if [[ -n "$MOUNT_MODE_PATH" ]]; then
                    echo "$MOUNT_MODE" > "$MOUNT_MODE_PATH"
                fi

                if [[ "$MOUNT_MODE" == "\(MountMode.streaming.rawValue)" ]]; then
                    # STREAMING — talk to the remote directly through the VFS cache. Both
                    # mount backends share this cache layer, so retention/eviction
                    # (--vfs-cache-max-size / --vfs-cache-max-age) behaves identically.
                    # Note: No --daemon flag - launchd manages the process lifecycle.
                    RCLONE_CMD="$RCLONE_BIN $MOUNT_SUBCMD \\"$REMOTE\\" \\"$LOCAL_PATH\\" --vfs-cache-mode $VFS_CACHE_MODE --vfs-cache-max-size $VFS_CACHE_MAX_SIZE --cache-dir \\"$VFS_CACHE_PATH\\" --log-level INFO --use-json-log"

                    # Throughput tuning. Reading a file through the mount (streaming or
                    # offline warming) otherwise trickles: the nfsmount -> rclone-NFS-server
                    # -> VFS hop paces the backend download at the slow NFS read rate instead
                    # of racing ahead at line speed. Measured on a DS223 over SMB: a raw
                    # single stream does ~17 MB/s and 4 parallel ~37 MB/s, yet an untuned warm
                    # delivered ~1.2 MB/s.
                    #   --vfs-read-ahead / --buffer-size : download far ahead of the reader so
                    #       the cache fills at backend speed, decoupled from NFS read latency.
                    #   --transfers : parallel VFS cache downloaders, from the profile's
                    #       downloadConnections setting (kept in lockstep with the app-side
                    #       warm concurrency in VFSCacheService). Fewer streams win on a
                    #       contended wireless/mesh link; more on fast wired.
                    #   --vfs-read-chunk-size(-limit) : large, growing range reads = fewer
                    #       round trips on high-latency backends.
                    #   --dir-cache-time / --attr-timeout : fewer metadata round trips.
                    # Cost: --buffer-size is per open file, so an active warm of N files uses
                    # up to N x 128M RAM (transient; released when the files close).
                    #
                    # --dir-cache-time 1000h (~41 days): folder LISTINGS must survive a long
                    # OFFLINE period. When the remote is unreachable, rclone serves fully-cached
                    # file *data* from disk regardless — but Finder browsing also needs the
                    # directory listing, and once dir-cache-time expires rclone tries to
                    # re-list from the (unreachable) remote. A short window (rclone's 5m
                    # default, or the old 12h) would expire mid-trip and break offline
                    # browsing. Freshness tradeoff — and it applies ONLINE too: a longer
                    # dir-cache-time also raises the ceiling on how long an out-of-band remote
                    # change stays invisible in Finder while the mount is up; it surfaces on
                    # the next explicit recursive /vfs/refresh (startup/mount, and
                    # offline-warm) instead of within a shorter auto-expiry. Offline WRITES
                    # need no flag here: under --vfs-cache-mode full a write while the remote
                    # is down lands in the VFS cache as dirty and rclone retries the
                    # write-back until it returns. If the remote stays down long enough for
                    # the mode selection above to notice on the NEXT mount start, that queued
                    # write becomes the overlay's job instead (Cache Only Pending) — see the
                    # automatic-entry note in CLAUDE.md.
                    RCLONE_CMD="$RCLONE_CMD --buffer-size 128M --vfs-read-ahead 256M --transfers $DOWNLOAD_CONNECTIONS --vfs-read-chunk-size 128M --vfs-read-chunk-size-limit off --attr-timeout 5s --dir-cache-time 1000h --vfs-cache-max-age $VFS_CACHE_MAX_AGE"
                    RCLONE_CMD="$RCLONE_CMD --volname \\"$MOUNT_VOLNAME\\""

                    # Add RC (remote control) API for cache management. Streaming-only — a
                    # Cache Only mount never exposes the RC API (nothing there needs
                    # refreshing/warming while the mount is deliberately not talking to the
                    # remote).
                    if [[ "$RC_PORT" != "0" && -n "$RC_PORT" ]]; then
                        RCLONE_CMD="$RCLONE_CMD --rc --rc-addr=localhost:$RC_PORT --rc-no-auth"
                    fi
                else
                    # CACHE ONLY — a writable "synctray-overlay" directory layered in FRONT of
                    # the read-only streaming cache's DATA tree via an rclone `union` remote
                    # (search/create/action_policy = ff, first-found wins), at the SAME mount
                    # point the streaming mount uses. This is why the mount still comes up:
                    # every absolute path a running app already has open keeps resolving,
                    # which a separate read-only sibling folder cannot give you.
                    #   - A read sees the overlay copy first if one exists, else the cache.
                    #   - A write/create/delete always lands in the overlay — the cache tree
                    #     is mounted `:ro` and is never touched.
                    # Partially-downloaded cache files are hidden via --exclude-from so a
                    # half-fetched file never presents as if it were complete.
                    mkdir -p "$OVERLAY_PATH"
                    mkdir -p "$CACHE_ONLY_CACHE_PATH"

                    python3 -c "
            import os, sys

            overlay_path, data_path, conf_path = sys.argv[1:4]
            backslash = chr(92)
            dquote = chr(34)

            # rclone's upstreams list is space-separated with double-quoting for a path
            # containing a space (NOT Python's repr() -- its single-quote wrapping is never
            # unwrapped by rclone's config parser, so the literal quote characters become
            # part of the path and every listing/read fails with directory-not-found).
            # Built from chr(34)/chr(92), never a literal quote or backslash character typed
            # directly, since this whole block is itself embedded inside a bash
            # double-quoted string (python3 -c followed by a quote). A literal quote
            # character here would close THAT string early, leaving the rest of this block
            # to be parsed as bash -- exactly the bug this comment is here to prevent
            # reintroducing.
            def quote(path):
                return dquote + path.replace(backslash, backslash + backslash).replace(dquote, backslash + dquote) + dquote

            lines = [
                '[synctray_cacheonly]',
                'type = union',
                'upstreams = ' + quote(overlay_path) + ' ' + quote(data_path + ':ro'),
                'action_policy = ff',
                'create_policy = ff',
                'search_policy = ff',
            ]
            os.makedirs(os.path.dirname(conf_path), exist_ok=True)
            with open(conf_path, 'w') as fh:
                fh.write(chr(10).join(lines) + chr(10))
            os.chmod(conf_path, 0o600)
            " "$OVERLAY_PATH" "$CACHE_DATA_PATH" "$CACHE_ONLY_CONFIG_PATH"

                    # Partial-file exclusion (regenerated on every Cache Only mount start —
                    # what's complete can change between mounts as streaming downloads more).
                    python3 -c "
            import json, os, sys

            data_root, meta_root, exclude_path = sys.argv[1:4]
            backslash = chr(92)

            def is_complete(meta, expected_size):
                if meta.get('Size') != expected_size:
                    return False
                if expected_size == 0:
                    return True
                ranges = meta.get('Rs') or []
                if not ranges:
                    return False
                covered = 0
                for r in sorted(ranges, key=lambda x: x.get('Pos', 0)):
                    pos, size = r.get('Pos', 0), r.get('Size', 0)
                    if pos < 0 or size < 0 or pos > covered:
                        return False
                    covered = max(covered, pos + size)
                return covered >= expected_size

            def escape(rel):
                rel = rel.replace(backslash, backslash + backslash)
                for ch in ('*', '?', '[', ']', '{', '}'):
                    rel = rel.replace(ch, backslash + ch)
                return rel

            lines = []
            if data_root and os.path.isdir(data_root):
                for root, dirs, files in os.walk(data_root):
                    for name in files:
                        full = os.path.join(root, name)
                        rel = os.path.relpath(full, data_root)
                        try:
                            size = os.path.getsize(full)
                        except OSError:
                            continue
                        complete = False
                        try:
                            with open(os.path.join(meta_root, rel)) as fh:
                                meta = json.load(fh)
                            complete = is_complete(meta, size)
                        except Exception:
                            complete = False
                        if not complete:
                            lines.append('/' + escape(rel))

            os.makedirs(os.path.dirname(exclude_path), exist_ok=True)
            with open(exclude_path, 'w') as fh:
                fh.write(chr(10).join(lines))
                if lines:
                    fh.write(chr(10))
            " "$CACHE_DATA_PATH" "$CACHE_META_PATH" "$CACHE_ONLY_EXCLUDE_PATH"

                    RCLONE_CMD="$RCLONE_BIN $MOUNT_SUBCMD synctray_cacheonly: \\"$LOCAL_PATH\\" --config \\"$CACHE_ONLY_CONFIG_PATH\\" --exclude-from \\"$CACHE_ONLY_EXCLUDE_PATH\\" --vfs-cache-mode writes --cache-dir \\"$CACHE_ONLY_CACHE_PATH\\" --vfs-write-back 2s --dir-cache-time 1m --log-level INFO --use-json-log --volname \\"$MOUNT_VOLNAME\\""

                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Cache Only: union(overlay=$OVERLAY_PATH, cache=$CACHE_DATA_PATH:ro), no --rc" >> "$LOG_FILE"
                fi

                # --allow-non-empty is a FUSE mount option; it is not valid for the
                # NFS backend, so only pass it when mounting via macFUSE. Needed by
                # both streaming and Cache Only.
                if [[ "$MOUNT_SUBCMD" == "mount" && ( "$ALLOW_NON_EMPTY" == "true" || "$ALLOW_NON_EMPTY" == "True" || "$ALLOW_NON_EMPTY" == "1" ) ]]; then
                    RCLONE_CMD="$RCLONE_CMD --allow-non-empty"
                fi

                # DRY-RUN TEST SEAM
                #
                # Reading through a real NFS/FUSE mount requires an actual rclone mount and
                # macOS-level permissions this project's self-test harness cannot assume (and
                # this codebase has no XCTest target - see CLAUDE.md's Testing section). Set
                # SYNCTRAY_DRY_RUN=1 to render the fully-resolved mode + command instead of
                # calling rclone, so ConfigSelfTest can assert on script BEHAVIOR (mode
                # selection, union config, exclude list, flag composition) without ever
                # mounting anything.
                if [[ "$SYNCTRAY_DRY_RUN" == "1" ]]; then
                    echo "SYNCTRAY_DRY_RUN_MODE=$MOUNT_MODE"
                    echo "SYNCTRAY_DRY_RUN_CMD=$RCLONE_CMD"
                    echo "SYNCTRAY_DRY_RUN_ENV_OVERRIDES=$(env | grep -c '^RCLONE_CONFIG_' || true)"
                    rm -f "$LOCK_FILE"
                    trap - EXIT
                    exit 0
                fi
            elif [[ "$SYNC_MODE" == "bisync" ]]; then
                # Two-way bidirectional sync
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting bisync" >> "$LOG_FILE"

                # Read-only pre-flight reachability check. This replaces the old
                # --check-access mechanism, which required uploading a .synctray-check
                # sentinel to the remote. We now verify the remote is reachable WITHOUT
                # writing anything: if it is offline we skip this run (exit 0) rather than
                # risk bisync acting on a phantom-empty listing, and retry next interval.
                #
                # We probe the remote ROOT (not the sync subpath) so a not-yet-created
                # path on a freshly configured profile does not cause a false skip — the
                # first run still reaches bisync and self-bootstraps via --resync.
                #
                # Catastrophic mass-deletion (a reachable-but-wiped side) remains guarded
                # by bisync's own --max-delete (default 50%), which aborts with a "too
                # many deletes" error instead of propagating the deletion.
                PREFLIGHT_REMOTE_NAME="${REMOTE%%:*}"
                if ! run_with_timeout 45 $RCLONE_BIN lsd "${PREFLIGHT_REMOTE_NAME}:" --max-depth 0 --contimeout 10s --timeout 30s --retries 1 --low-level-retries 1 $NO_CHECK_CERT &>/dev/null; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Remote unreachable, skipping sync (will retry next interval)" >> "$LOG_FILE"
                    exit 0
                fi

                # Self-bootstrap: if this (remote, local) pair has no prior bisync
                # listings, bisync would abort with "cannot find prior Path1/Path2
                # listings". That happens on the FIRST run against a new transport
                # pair (e.g. first fallback activation after a REMOTE swap, or a
                # brand-new profile). Run that first sync as --resync with
                # newer-wins so failover works unattended (no app required) and a
                # stale remote copy can never overwrite newer local edits.
                #
                # Session name mirrors rclone's bilib.SessionName/CanonicalPath:
                # trim leading/trailing slashes, replace whitespace and /:?* with
                # "_", join path1..path2. (Backslashes, which rclone also replaces,
                # cannot occur in macOS paths or these remote names.)
                # A pair counts as having state when a .lst OR .lst-new listing
                # exists for BOTH sides — bisync --recover resumes from .lst-new.
                BISYNC_WORKDIR="$HOME/Library/Caches/rclone/bisync"
                SESSION_NAME=$(python3 -c "
            import sys
            def canon(p):
                p = p.strip('/')
                return ''.join('_' if (ch.isspace() or ch in '/:?*') else ch for ch in p)
            print(canon(sys.argv[1]) + '..' + canon(sys.argv[2]))
            " "$REMOTE" "$LOCAL_PATH")
                BOOTSTRAP_FLAGS=""
                if [[ ! -e "$BISYNC_WORKDIR/$SESSION_NAME.path1.lst" && ! -e "$BISYNC_WORKDIR/$SESSION_NAME.path1.lst-new" ]] \\
                    || [[ ! -e "$BISYNC_WORKDIR/$SESSION_NAME.path2.lst" && ! -e "$BISYNC_WORKDIR/$SESSION_NAME.path2.lst-new" ]]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Bootstrapping sync state (--resync, newer wins): first run for this transport pair" >> "$LOG_FILE"
                    BOOTSTRAP_FLAGS="--resync --resync-mode newer"
                fi

                RCLONE_CMD="$RCLONE_BIN bisync \\"$REMOTE\\" \\"$LOCAL_PATH\\" --verbose --use-json-log --stats 2s --filter-from \\"$FILTER_FILE\\" --resilient --recover --conflict-resolve newer --conflict-loser num --conflict-suffix sync-conflict-{DateOnly}-"

                if [[ -n "$BOOTSTRAP_FLAGS" ]]; then
                    RCLONE_CMD="$RCLONE_CMD $BOOTSTRAP_FLAGS"
                fi
            else
                # One-way sync
                if [[ "$SYNC_DIRECTION" == "localToRemote" ]]; then
                    # Local is source, remote is destination (backup/upload)
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting sync (local → remote)" >> "$LOG_FILE"
                    RCLONE_CMD="$RCLONE_BIN sync \\"$LOCAL_PATH\\" \\"$REMOTE\\" --verbose --use-json-log --stats 2s --filter-from \\"$FILTER_FILE\\""
                else
                    # Remote is source, local is destination (download/mirror)
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting sync (remote → local)" >> "$LOG_FILE"
                    RCLONE_CMD="$RCLONE_BIN sync \\"$REMOTE\\" \\"$LOCAL_PATH\\" --verbose --use-json-log --stats 2s --filter-from \\"$FILTER_FILE\\""
                fi
            fi

            if [[ -n "$NO_CHECK_CERT" ]]; then
                RCLONE_CMD="$RCLONE_CMD $NO_CHECK_CERT"
            fi

            if [[ -n "$ADDITIONAL_FLAGS" ]]; then
                RCLONE_CMD="$RCLONE_CMD $ADDITIONAL_FLAGS"
            fi

            # Run sync command
            eval "$RCLONE_CMD" 2>&1 | tee -a "$LOG_FILE"

            EXIT_CODE=${PIPESTATUS[0]}

            if [[ $EXIT_CODE -eq 0 ]]; then
                if [[ "$SYNC_MODE" == "bisync" ]]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Bisync completed successfully" >> "$LOG_FILE"
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync completed successfully" >> "$LOG_FILE"
                fi
            else
                if [[ "$SYNC_MODE" == "bisync" ]]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Bisync failed with exit code $EXIT_CODE" >> "$LOG_FILE"
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync failed with exit code $EXIT_CODE" >> "$LOG_FILE"
                fi
            fi

            echo "" >> "$LOG_FILE"
            """
    }

    /// Returns true when primary and fallback remotes have different rclone wire types,
    /// meaning the bisync cache must be rebuilt on fallback activation.
    /// Uses rcloneType (e.g. "webdav", "smb", "sftp") so that .synology and .webdav
    /// (both wire type "webdav") are treated as compatible.
    ///
    /// Limitation: RcloneConfigService.providerFromRcloneType maps unrecognised rclone
    /// types (s3, azureblob, b2, ftp, etc.) to .webdav as a fallback, so two different
    /// unrecognised types both resolve to rcloneType "webdav" and are incorrectly treated
    /// as cache-compatible. This is safe for the wizard-supported type set; users with
    /// manually-added exotic remotes should set fallbackRemotePath explicitly to force a
    /// REMOTE swap via the existing path-based branch.
    private func computeFallbackRequiresCacheRebuild(profile: SyncProfile) -> Bool {
        guard profile.hasFallback else { return false }
        let configService = RcloneConfigService.shared
        let primaryName = profile.rcloneRemote.hasSuffix(":")
            ? String(profile.rcloneRemote.dropLast())
            : profile.rcloneRemote
        let fallbackName = profile.fallbackRemote.hasSuffix(":")
            ? String(profile.fallbackRemote.dropLast())
            : profile.fallbackRemote
        guard let primaryConfig = configService.readRemoteConfig(name: primaryName),
              let fallbackConfig = configService.readRemoteConfig(name: fallbackName) else {
            // Cannot read config — default to safe behaviour (force REMOTE swap, no cache poisoning)
            return true
        }
        return primaryConfig.provider.rcloneType != fallbackConfig.provider.rcloneType
    }

    /// Cache-only / mode-signalling paths the script needs but does not derive itself
    /// (D7) — Swift is the single source (`SyncProfile` computed paths +
    /// `VFSCacheService.cacheSubtreeRoots`) so the script and the app can never
    /// disagree about which directory is which. Included for every profile (harmless
    /// for a non-mount one — the script only reads these in its mount branch).
    private func mountCacheOnlyConfigKeys(for profile: SyncProfile) -> [String: Any] {
        let roots = VFSCacheService.shared.cacheSubtreeRoots(for: profile)
        return [
            "mountModePath": profile.mountModePath,
            "overlayPath": profile.overlayPath,
            "cacheOnlyConfigPath": profile.cacheOnlyConfigPath,
            "cacheOnlyExcludePath": profile.cacheOnlyExcludePath,
            "cacheOnlyCachePath": profile.cacheOnlyCachePath,
            "cacheDataPath": roots.data,
            "cacheMetaPath": roots.meta,
        ]
    }

    /// Generate profile-specific JSON config.
    /// Not private — `ConfigSelfTest` calls this directly to verify the
    /// derived config's key set stays frozen (AC-2) without going through
    /// the side-effecting `install(profile:)` (which touches launchd).
    func generateProfileConfig(for profile: SyncProfile) -> String {
        let config: [String: Any] = [
            "profileId": profile.id.uuidString,
            "name": profile.name,
            "remote": profile.fullRemotePath,
            "localPath": profile.localSyncPath,
            "logPath": profile.logPath,
            "lockFile": profile.lockFilePath,
            "drivePath": profile.drivePathToMonitor,
            "additionalFlags": profile.additionalRcloneFlags,
            "filterPath": profile.filterFilePath,
            "syncIntervalMinutes": profile.syncIntervalMinutes,
            "syncMode": profile.syncMode.rawValue,
            "syncDirection": profile.syncDirection.rawValue,
            "fallbackRemote": profile.fallbackRemote,
            "fallbackRemotePath": profile.fallbackRemotePath,
            "fallbackRequiresCacheRebuild": computeFallbackRequiresCacheRebuild(profile: profile),
            "remotePath": profile.remotePath,
            "mountBackend": profile.mountBackend.rawValue,
            "vfsCacheMode": profile.vfsCacheMode.rawValue,
            "vfsCacheMaxSize": profile.vfsCacheMaxSize,
            "vfsCacheMaxAge": profile.vfsCacheMaxAge,
            "vfsCachePath": profile.vfsCachePath,
            "allowNonEmptyMount": profile.allowNonEmptyMount,
            "streamCacheOnly": profile.streamCacheOnly,
            "pinnedDirectories": profile.pinnedDirectories,
            "rcPort": profile.rcPort,
            "downloadConnections": profile.downloadConnections,
        ].merging(mountCacheOnlyConfigKeys(for: profile)) { _, new in new }

        if let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return "{}"
    }

    private func generateLaunchdPlist(for profile: SyncProfile) -> String {
        let scriptPath = SyncProfile.sharedScriptPath
        let configPath = profile.configPath
        let logDir = (profile.logPath as NSString).deletingLastPathComponent
        let launchdLogPath = logDir + "/synctray-launchd-\(profile.shortId).log"

        if profile.isMountMode {
            // Mount mode: use KeepAlive to maintain the daemon — but only when the
            // profile is set to auto-mount. macOS reloads every LaunchAgent plist at
            // each login, so RunAtLoad/KeepAlive (not merely whether we `launchctl
            // load`ed it) decide whether it mounts on its own. Gating both on
            // mountAtStartup makes the setting effective at login/reboot; an opt-out
            // profile is mounted only on demand (the Mount button → startAgent).
            let autoStart = profile.mountAtStartup ? "<true/>" : "<false/>"
            return """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>\(profile.launchdLabel)</string>

                    <key>ProgramArguments</key>
                    <array>
                        <string>\(scriptPath)</string>
                        <string>\(configPath)</string>
                    </array>

                    <key>KeepAlive</key>
                    \(autoStart)

                    <key>RunAtLoad</key>
                    \(autoStart)

                    <key>StandardOutPath</key>
                    <string>\(launchdLogPath)</string>

                    <key>StandardErrorPath</key>
                    <string>\(launchdLogPath)</string>

                    <key>EnvironmentVariables</key>
                    <dict>
                        <key>PATH</key>
                        <string>/opt/homebrew/bin:/usr/local/bin:/run/current-system/sw/bin:/etc/profiles/per-user/\(NSUserName())/bin:\(NSHomeDirectory())/.nix-profile/bin:/usr/bin:/bin</string>
                    </dict>
                </dict>
                </plist>
                """
        } else {
            // Sync modes: use StartInterval for periodic execution
            let intervalSeconds = profile.syncIntervalMinutes * 60
            return """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>\(profile.launchdLabel)</string>

                    <key>ProgramArguments</key>
                    <array>
                        <string>\(scriptPath)</string>
                        <string>\(configPath)</string>
                    </array>

                    <key>StartInterval</key>
                    <integer>\(intervalSeconds)</integer>

                    <key>RunAtLoad</key>
                    <true/>

                    <key>StandardOutPath</key>
                    <string>\(launchdLogPath)</string>

                    <key>StandardErrorPath</key>
                    <string>\(launchdLogPath)</string>

                    <key>EnvironmentVariables</key>
                    <dict>
                        <key>PATH</key>
                        <string>/opt/homebrew/bin:/usr/local/bin:/run/current-system/sw/bin:/etc/profiles/per-user/\(NSUserName())/bin:\(NSHomeDirectory())/.nix-profile/bin:/usr/bin:/bin</string>
                    </dict>
                </dict>
                </plist>
                """
        }
    }

    // MARK: - Helpers

    private func createDirectories(for profile: SyncProfile) throws {
        let fm = FileManager.default

        // Create ~/.local/bin if needed
        let binDir = (SyncProfile.sharedScriptPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: binDir) {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        }

        // Create ~/.local/log if needed
        let logDir = (profile.logPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: logDir) {
            try fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        // Create ~/.config/synctray/profiles if needed
        if !fm.fileExists(atPath: SyncProfile.configDirectory) {
            try fm.createDirectory(
                atPath: SyncProfile.configDirectory, withIntermediateDirectories: true)
        }

        // LaunchAgents directory should already exist, but just in case
        let agentsDir = (profile.plistPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: agentsDir) {
            try fm.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
        }
    }

    /// Write the exclude filter file for a profile (only if it doesn't exist)
    private func writeExcludeFilter(for profile: SyncProfile) throws {
        let filterPath = profile.filterFilePath
        // Only create if it doesn't exist (preserve user edits)
        if !FileManager.default.fileExists(atPath: filterPath) {
            try Self.defaultExcludeFilter.write(
                toFile: filterPath, atomically: true, encoding: .utf8)
        }
    }

    private func runCommand(_ command: String, arguments: [String]) -> (
        output: String, exitCode: Int32
    ) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("", -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return (output, process.terminationStatus)
    }

    // MARK: - Errors

    enum SetupError: LocalizedError {
        case missingRcloneRemote
        case missingLocalPath
        case missingRemotePath
        case scriptGenerationFailed
        case plistGenerationFailed
        case notMountMode
        case unmountFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingRcloneRemote:
                return "Rclone remote is required"
            case .missingLocalPath:
                return "Local sync path is required"
            case .missingRemotePath:
                return "Remote folder path is required"
            case .scriptGenerationFailed:
                return "Failed to generate sync script"
            case .plistGenerationFailed:
                return "Failed to generate launchd plist"
            case .notMountMode:
                return "Profile is not in mount mode"
            case .unmountFailed(let message):
                return "Failed to unmount: \(message)"
            }
        }
    }
}

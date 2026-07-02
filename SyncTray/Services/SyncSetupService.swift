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
        let paths = ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone", "/usr/bin/rclone"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
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

        // For mount mode, ensure VFS cache directory exists
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

    /// Explicitly (re)start a loaded agent's job now, regardless of RunAtLoad.
    /// Needed for mount profiles with `mountAtStartup == false`: their plist has
    /// RunAtLoad/KeepAlive = false, so `launchctl load` alone won't start the mount —
    /// the Mount button uses this to kick it off on demand.
    /// - Returns: true if launchctl reported success.
    @discardableResult
    func startAgent(for profile: SyncProfile) -> Bool {
        let uid = getuid()
        let target = "gui/\(uid)/\(profile.launchdLabel)"
        let result = runCommand("/bin/launchctl", arguments: ["kickstart", target])
        print("[SyncTray] launchctl kickstart \(target) exit: \(result.exitCode), output: \(result.output)")
        return result.exitCode == 0
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

    /// Unmount a mounted profile
    func unmount(profile: SyncProfile) throws {
        guard profile.isMountMode else {
            throw SetupError.notMountMode
        }

        // Check if mounted
        guard isMounted(profile: profile) else {
            return // Already unmounted
        }

        // Try graceful unmount first
        let result = runCommand("/usr/sbin/diskutil", arguments: ["unmount", profile.localSyncPath])

        if result.exitCode != 0 {
            // Force unmount if graceful fails
            let forceResult = runCommand("/usr/sbin/diskutil", arguments: ["unmount", "force", profile.localSyncPath])
            if forceResult.exitCode != 0 {
                throw SetupError.unmountFailed(forceResult.output)
            }
        }
    }

    /// Clean up stale mounts on app startup.
    ///
    /// Matches mount points against the known mount-mode profile paths rather than
    /// the filesystem type. This is both backend-agnostic (handles macFUSE *and* the
    /// kext-free NFS backend, whose `mount` lines don't contain "rclone") and safe —
    /// it will never force-unmount an unrelated NFS share the user mounted themselves.
    /// - Parameter mountProfiles: mount-mode profiles whose paths are owned by SyncTray.
    func cleanupStaleMounts(mountProfiles: [SyncProfile]) {
        let managedPaths = Set(mountProfiles.filter { $0.isMountMode }.map { $0.localSyncPath })
        guard !managedPaths.isEmpty else { return }

        let result = runCommand("/sbin/mount", arguments: [])
        let lines = result.output.components(separatedBy: "\n")

        for line in lines {
            // Extract the mount point from a line like "remote: on /path (osxfuse...)"
            // or "localhost:/ on /path (nfs, ...)".
            guard let onRange = line.range(of: " on "),
                  let parenRange = line.range(of: " (") else { continue }
            let mountPoint = String(line[onRange.upperBound..<parenRange.lowerBound])

            // Only unmount paths SyncTray manages — never a user's own NFS/FUSE mount.
            if managedPaths.contains(mountPoint) {
                _ = runCommand("/usr/sbin/diskutil", arguments: ["unmount", "force", mountPoint])
            }
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

    /// Generate the shared sync script that reads config from JSON
    /// Supports bisync (two-way), sync (one-way), and mount (streaming) modes
    private func generateSyncScript() -> String {
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
            ALLOW_NON_EMPTY=$(parse_json "allowNonEmptyMount" "false")
            RC_PORT=$(parse_json "rcPort" "0")

            if [[ -z "$REMOTE" || -z "$LOCAL_PATH" ]]; then
                echo "Error: Invalid config - missing remote or localPath"
                exit 1
            fi

            # Find rclone binary (check multiple locations)
            RCLONE_BIN=""
            for path in /usr/local/bin/rclone /opt/homebrew/bin/rclone /usr/bin/rclone; do
                if [[ -x "$path" ]]; then
                    RCLONE_BIN="$path"
                    break
                fi
            done

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

            # Remote fallback: if primary remote is unreachable, try fallback remote
            if [[ -n "$FALLBACK_REMOTE" ]]; then
                REMOTE_NAME="${REMOTE%%:*}"
                # Quick reachability check on primary remote (3s connect timeout)
                if ! run_with_timeout 15 $RCLONE_BIN lsd "${REMOTE_NAME}:" --contimeout 3s --timeout 8s --max-depth 0 $NO_CHECK_CERT &>/dev/null; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Primary remote unreachable, using fallback: $FALLBACK_REMOTE" >> "$LOG_FILE"
                    # Re-check cert setting for the fallback remote
                    NO_CHECK_CERT=$(check_no_cert "$FALLBACK_REMOTE")

                    if [[ -z "$FALLBACK_PATH" && "$FALLBACK_REQUIRES_CACHE_REBUILD" != "true" && "$FALLBACK_REQUIRES_CACHE_REBUILD" != "True" ]]; then
                        # Same wire type, same path: use env var overrides to swap transport.
                        # This preserves bisync cache since the remote name stays the same.
                        UPPER_NAME=$(echo "$REMOTE_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
                        eval "$($RCLONE_BIN config dump 2>/dev/null | python3 -c "
            import json, sys
            d = json.load(sys.stdin).get('${FALLBACK_REMOTE}', {})
            name = '${UPPER_NAME}'
            for k, v in d.items():
                safe_k = k.upper().replace('-', '_')
                print(f'export RCLONE_CONFIG_{name}_{safe_k}=\\\"' + str(v).replace('\\\"', '\\\\\\\"') + '\\\"')
            ")"
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

                # Mount command with VFS cache settings.
                # Both backends share the same VFS cache layer, so retention/eviction
                # (--vfs-cache-max-size / --vfs-cache-max-age) behaves identically.
                # Note: No --daemon flag - launchd manages the process lifecycle.
                RCLONE_CMD="$RCLONE_BIN $MOUNT_SUBCMD \\"$REMOTE\\" \\"$LOCAL_PATH\\" --vfs-cache-mode $VFS_CACHE_MODE --vfs-cache-max-size $VFS_CACHE_MAX_SIZE --vfs-cache-max-age $VFS_CACHE_MAX_AGE --cache-dir \\"$VFS_CACHE_PATH\\" --log-level INFO --use-json-log"

                # Name the mounted volume after the mount-point folder so Finder
                # shows e.g. "Temp" instead of the auto-generated NFS share name
                # ("localhost:/synology home Reaper"). macFUSE already derives the
                # volume name from the mountpoint; the NFS backend does not, so set
                # it explicitly. --volname is supported on macOS for both backends.
                MOUNT_VOLNAME=$(basename "$LOCAL_PATH")
                RCLONE_CMD="$RCLONE_CMD --volname \\"$MOUNT_VOLNAME\\""

                # Add RC (remote control) API for cache management
                if [[ "$RC_PORT" != "0" && -n "$RC_PORT" ]]; then
                    RCLONE_CMD="$RCLONE_CMD --rc --rc-addr=localhost:$RC_PORT --rc-no-auth"
                fi

                # --allow-non-empty is a FUSE mount option; it is not valid for the
                # NFS backend, so only pass it when mounting via macFUSE.
                if [[ "$MOUNT_SUBCMD" == "mount" && ( "$ALLOW_NON_EMPTY" == "true" || "$ALLOW_NON_EMPTY" == "True" || "$ALLOW_NON_EMPTY" == "1" ) ]]; then
                    RCLONE_CMD="$RCLONE_CMD --allow-non-empty"
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

    /// Generate profile-specific JSON config
    private func generateProfileConfig(for profile: SyncProfile) -> String {
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
            "pinnedDirectories": profile.pinnedDirectories,
            "rcPort": profile.rcPort,
        ]

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
                        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
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
                        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
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

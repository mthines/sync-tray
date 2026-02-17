import Foundation

/// Service for generating and managing sync scripts and launchd configuration
final class SyncSetupService {
    static let shared = SyncSetupService()

    private init() {}

    // MARK: - Constants

    /// The check file name used by rclone bisync --check-access
    /// This file must exist in both local and remote paths for sync to work
    /// Note: rclone's --check-filename expects a filename, not a path
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
        """

    // MARK: - Rclone Path Helper

    private func findRclonePath() -> String? {
        let paths = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
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
        try writeExcludeFilter(for: profile)

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

    /// Initializes sync paths by creating directories and check file (.synctray-check)
    /// - Returns: nil on success, error message on failure
    func initializeSyncPaths(for profile: SyncProfile) -> String? {
        guard let rclonePath = findRclonePath() else {
            return "rclone not found"
        }

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

        // 2. Create local check file (.synctray-check)
        let localCheckFile = (profile.localSyncPath as NSString).appendingPathComponent(
            Self.checkFileName)

        if !fileManager.fileExists(atPath: localCheckFile) {
            fileManager.createFile(atPath: localCheckFile, contents: nil)
        }

        // 3. Create remote check file using rclone touch
        let remoteCheckFile = "\(profile.rcloneRemote):\(profile.remotePath)/\(Self.checkFileName)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["touch", remoteCheckFile]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                return "Failed to create remote check file (exit code \(process.terminationStatus))"
            }
        } catch {
            return "Failed to run rclone touch: \(error.localizedDescription)"
        }

        return nil  // Success
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
    private func generateSyncScript() -> String {
        return """
            #!/bin/bash
            # SyncTray Sync Script
            # This script reads profile configuration from a JSON file
            # DO NOT EDIT - This file is managed by SyncTray

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

            if [[ -z "$REMOTE" || -z "$LOCAL_PATH" ]]; then
                echo "Error: Invalid config - missing remote or localPath"
                exit 1
            fi

            # Check if drive is mounted (if configured)
            if [[ -n "$DRIVE_PATH" && ! -d "$DRIVE_PATH" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Drive not mounted, skipping sync" >> "$LOG_FILE"
                exit 0
            fi

            # Check if another sync is already running
            if [[ -f "$LOCK_FILE" ]]; then
                PID=$(cat "$LOCK_FILE")
                if ps -p "$PID" > /dev/null 2>&1; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync already running (PID $PID), skipping" >> "$LOG_FILE"
                    exit 0
                fi
            fi

            # Create lock file
            echo $$ > "$LOCK_FILE"
            trap "rm -f $LOCK_FILE" EXIT

            # Ensure sync directory exists
            mkdir -p "$LOCAL_PATH"

            echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting bisync" >> "$LOG_FILE"

            # Build rclone command
            RCLONE_CMD="/opt/homebrew/bin/rclone bisync \\"$REMOTE\\" \\"$LOCAL_PATH\\" --verbose --use-json-log --stats 2s --filter-from \\"$FILTER_FILE\\" --check-access --check-filename .synctray-check --resilient --recover --conflict-resolve newer --conflict-loser num --conflict-suffix sync-conflict-{DateOnly}-"

            if [[ -n "$ADDITIONAL_FLAGS" ]]; then
                RCLONE_CMD="$RCLONE_CMD $ADDITIONAL_FLAGS"
            fi

            # Run bisync
            eval "$RCLONE_CMD" 2>&1 | tee -a "$LOG_FILE"

            EXIT_CODE=${PIPESTATUS[0]}

            if [[ $EXIT_CODE -eq 0 ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Bisync completed successfully" >> "$LOG_FILE"
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Bisync failed with exit code $EXIT_CODE" >> "$LOG_FILE"
            fi

            echo "" >> "$LOG_FILE"
            """
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
        let intervalSeconds = profile.syncIntervalMinutes * 60
        let scriptPath = SyncProfile.sharedScriptPath
        let configPath = profile.configPath
        let logDir = (profile.logPath as NSString).deletingLastPathComponent
        let launchdLogPath = logDir + "/synctray-launchd-\(profile.shortId).log"

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
            }
        }
    }
}

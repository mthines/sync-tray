import Foundation

/// Service for generating and managing sync scripts and launchd configuration
final class SyncSetupService {
    static let shared = SyncSetupService()

    private init() {}

    // MARK: - Public Methods

    /// Check if the scheduled sync is currently installed and loaded
    func isInstalled() -> Bool {
        let plistPath = SyncTraySettings.generatedPlistPath
        let scriptPath = SyncTraySettings.generatedScriptPath

        return FileManager.default.fileExists(atPath: plistPath) &&
               FileManager.default.fileExists(atPath: scriptPath)
    }

    /// Check if the launchd agent is currently loaded
    func isLoaded() -> Bool {
        let result = runCommand("/bin/launchctl", arguments: ["list", "com.synctray.sync"])
        return result.exitCode == 0
    }

    /// Generate and install the sync script and launchd plist
    func install() throws {
        // Validate required settings
        guard !SyncTraySettings.rcloneRemote.isEmpty else {
            throw SetupError.missingRcloneRemote
        }
        guard !SyncTraySettings.localSyncPath.isEmpty else {
            throw SetupError.missingLocalPath
        }

        // Create directories if needed
        try createDirectories()

        // Generate and write script
        let script = generateSyncScript()
        try script.write(toFile: SyncTraySettings.generatedScriptPath, atomically: true, encoding: .utf8)

        // Make script executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: SyncTraySettings.generatedScriptPath
        )

        // Generate and write plist
        let plist = generateLaunchdPlist()
        try plist.write(toFile: SyncTraySettings.generatedPlistPath, atomically: true, encoding: .utf8)

        // Update settings to use generated paths
        SyncTraySettings.syncScriptPath = SyncTraySettings.generatedScriptPath
        SyncTraySettings.logFilePath = SyncTraySettings.generatedLogPath
        SyncTraySettings.syncDirectoryPath = SyncTraySettings.localSyncPath
        SyncTraySettings.isScheduledSyncInstalled = true
        SyncTraySettings.hasCompletedSetup = true

        // Load the launchd agent
        _ = runCommand("/bin/launchctl", arguments: ["load", SyncTraySettings.generatedPlistPath])
    }

    /// Uninstall the sync script and launchd plist
    func uninstall() throws {
        // Unload the launchd agent first
        _ = runCommand("/bin/launchctl", arguments: ["unload", SyncTraySettings.generatedPlistPath])

        // Remove files
        let fm = FileManager.default

        if fm.fileExists(atPath: SyncTraySettings.generatedPlistPath) {
            try fm.removeItem(atPath: SyncTraySettings.generatedPlistPath)
        }

        if fm.fileExists(atPath: SyncTraySettings.generatedScriptPath) {
            try fm.removeItem(atPath: SyncTraySettings.generatedScriptPath)
        }

        SyncTraySettings.isScheduledSyncInstalled = false
    }

    /// Reload the launchd agent (useful after settings change)
    func reload() {
        _ = runCommand("/bin/launchctl", arguments: ["unload", SyncTraySettings.generatedPlistPath])
        _ = runCommand("/bin/launchctl", arguments: ["load", SyncTraySettings.generatedPlistPath])
    }

    // MARK: - Script Generation

    private func generateSyncScript() -> String {
        let remote = SyncTraySettings.rcloneRemote
        let localPath = SyncTraySettings.localSyncPath
        let logFile = SyncTraySettings.generatedLogPath
        let drivePath = SyncTraySettings.drivePathToMonitor
        let additionalFlags = SyncTraySettings.additionalRcloneFlags

        var script = """
        #!/bin/bash
        # SyncTray Generated Sync Script
        # Generated: \(ISO8601DateFormatter().string(from: Date()))
        # DO NOT EDIT - This file is managed by SyncTray

        REMOTE="\(remote)"
        LOCAL_PATH="\(localPath)"
        LOG_FILE="\(logFile)"
        LOCK_FILE="/tmp/synctray-sync.lock"

        """

        // Add drive check if configured
        if !drivePath.isEmpty {
            script += """

            # Check if drive is mounted
            DRIVE="\(drivePath)"
            if [[ ! -d "$DRIVE" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Drive not mounted, skipping sync" >> "$LOG_FILE"
                exit 0
            fi

            """
        }

        script += """

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

        # Run bisync
        /opt/homebrew/bin/rclone bisync "$REMOTE" "$LOCAL_PATH" \\
            --verbose \\
            --use-json-log \\
            --check-access \\
            --resilient \\
            --recover \\
            --conflict-resolve newer \\
            --conflict-loser num \\
            --conflict-suffix sync-conflict-{DateOnly}- \\
        """

        // Add additional flags if provided
        if !additionalFlags.isEmpty {
            script += "    \(additionalFlags) \\\n"
        }

        script += """
            2>&1 | tee -a "$LOG_FILE"

        EXIT_CODE=${PIPESTATUS[0]}

        if [[ $EXIT_CODE -eq 0 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Bisync completed successfully" >> "$LOG_FILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Bisync failed with exit code $EXIT_CODE" >> "$LOG_FILE"
        fi

        echo "" >> "$LOG_FILE"
        """

        return script
    }

    private func generateLaunchdPlist() -> String {
        let intervalSeconds = SyncTraySettings.syncIntervalMinutes * 60
        let scriptPath = SyncTraySettings.generatedScriptPath
        let logPath = (SyncTraySettings.generatedLogPath as NSString).deletingLastPathComponent + "/synctray-launchd.log"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.synctray.sync</string>

            <key>ProgramArguments</key>
            <array>
                <string>\(scriptPath)</string>
            </array>

            <key>StartInterval</key>
            <integer>\(intervalSeconds)</integer>

            <key>RunAtLoad</key>
            <true/>

            <key>StandardOutPath</key>
            <string>\(logPath)</string>

            <key>StandardErrorPath</key>
            <string>\(logPath)</string>

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

    private func createDirectories() throws {
        let fm = FileManager.default

        // Create ~/.local/bin if needed
        let binDir = (SyncTraySettings.generatedScriptPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: binDir) {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        }

        // Create ~/.local/log if needed
        let logDir = (SyncTraySettings.generatedLogPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: logDir) {
            try fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        // LaunchAgents directory should already exist, but just in case
        let agentsDir = (SyncTraySettings.generatedPlistPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: agentsDir) {
            try fm.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
        }
    }

    private func runCommand(_ command: String, arguments: [String]) -> (output: String, exitCode: Int32) {
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
        case scriptGenerationFailed
        case plistGenerationFailed

        var errorDescription: String? {
            switch self {
            case .missingRcloneRemote:
                return "Rclone remote is required"
            case .missingLocalPath:
                return "Local sync path is required"
            case .scriptGenerationFailed:
                return "Failed to generate sync script"
            case .plistGenerationFailed:
                return "Failed to generate launchd plist"
            }
        }
    }
}

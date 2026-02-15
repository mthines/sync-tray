import Foundation

struct SyncTraySettings {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        // Sync Configuration
        static let rcloneRemote = "rcloneRemote"
        static let localSyncPath = "localSyncPath"
        static let drivePathToMonitor = "drivePathToMonitor"
        static let syncIntervalMinutes = "syncIntervalMinutes"
        static let additionalRcloneFlags = "additionalRcloneFlags"

        // Generated Paths (read-only, derived)
        static let logFilePath = "logFilePath"
        static let syncScriptPath = "syncScriptPath"

        // Legacy (kept for compatibility)
        static let syncDirectoryPath = "syncDirectoryPath"
        static let hasCompletedSetup = "hasCompletedSetup"
        static let isScheduledSyncInstalled = "isScheduledSyncInstalled"
    }

    // MARK: - Sync Configuration

    /// Rclone remote path (e.g., "synology-kaiju:Kaiju")
    static var rcloneRemote: String {
        get { defaults.string(forKey: Keys.rcloneRemote) ?? "" }
        set { defaults.set(newValue, forKey: Keys.rcloneRemote) }
    }

    /// Local directory to sync (e.g., "/Volumes/SeagateHD/Kaiju")
    static var localSyncPath: String {
        get { defaults.string(forKey: Keys.localSyncPath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.localSyncPath) }
    }

    /// Drive path to monitor for mount/unmount (e.g., "/Volumes/SeagateHD")
    static var drivePathToMonitor: String {
        get { defaults.string(forKey: Keys.drivePathToMonitor) ?? "" }
        set { defaults.set(newValue, forKey: Keys.drivePathToMonitor) }
    }

    /// Sync interval in minutes (default: 15)
    static var syncIntervalMinutes: Int {
        get {
            let value = defaults.integer(forKey: Keys.syncIntervalMinutes)
            return value > 0 ? value : 15
        }
        set { defaults.set(newValue, forKey: Keys.syncIntervalMinutes) }
    }

    /// Additional rclone flags (optional)
    static var additionalRcloneFlags: String {
        get { defaults.string(forKey: Keys.additionalRcloneFlags) ?? "" }
        set { defaults.set(newValue, forKey: Keys.additionalRcloneFlags) }
    }

    // MARK: - Generated File Paths

    static var generatedScriptPath: String {
        "\(NSHomeDirectory())/.local/bin/synctray-sync.sh"
    }

    static var generatedLogPath: String {
        "\(NSHomeDirectory())/.local/log/synctray-sync.log"
    }

    static var generatedPlistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/com.synctray.sync.plist"
    }

    // MARK: - Legacy Settings (for manual configuration)

    static var logFilePath: String {
        get { defaults.string(forKey: Keys.logFilePath) ?? defaultLogFilePath }
        set { defaults.set(newValue, forKey: Keys.logFilePath) }
    }

    static var defaultLogFilePath: String {
        "\(NSHomeDirectory())/.local/log/rclone-sync.log"
    }

    static var syncScriptPath: String {
        get { defaults.string(forKey: Keys.syncScriptPath) ?? defaultSyncScriptPath }
        set { defaults.set(newValue, forKey: Keys.syncScriptPath) }
    }

    static var defaultSyncScriptPath: String {
        "\(NSHomeDirectory())/.local/bin/rclone-sync.sh"
    }

    /// Sync directory path (alias for localSyncPath for compatibility)
    static var syncDirectoryPath: String {
        get { defaults.string(forKey: Keys.syncDirectoryPath) ?? localSyncPath }
        set { defaults.set(newValue, forKey: Keys.syncDirectoryPath) }
    }

    // MARK: - Status

    static var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedSetup) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedSetup) }
    }

    static var isScheduledSyncInstalled: Bool {
        get { defaults.bool(forKey: Keys.isScheduledSyncInstalled) }
        set { defaults.set(newValue, forKey: Keys.isScheduledSyncInstalled) }
    }

    // MARK: - Validation

    static var isConfigured: Bool {
        !logFilePath.isEmpty && FileManager.default.fileExists(atPath: logFilePath)
    }

    static var canGenerateSync: Bool {
        !rcloneRemote.isEmpty && !localSyncPath.isEmpty
    }

    static func validatePaths() -> [String] {
        var errors: [String] = []

        if logFilePath.isEmpty {
            errors.append("Log file path is not set")
        }

        if !syncScriptPath.isEmpty && !FileManager.default.fileExists(atPath: syncScriptPath) {
            errors.append("Sync script not found at: \(syncScriptPath)")
        }

        if !syncDirectoryPath.isEmpty && !FileManager.default.fileExists(atPath: syncDirectoryPath) {
            errors.append("Sync directory not found at: \(syncDirectoryPath)")
        }

        return errors
    }
}

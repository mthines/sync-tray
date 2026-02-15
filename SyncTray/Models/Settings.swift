import Foundation

struct SyncTraySettings {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let logFilePath = "logFilePath"
        static let syncScriptPath = "syncScriptPath"
        static let syncDirectoryPath = "syncDirectoryPath"
        static let drivePathToMonitor = "drivePathToMonitor"
        static let hasCompletedSetup = "hasCompletedSetup"
    }

    // MARK: - Log File Path
    static var logFilePath: String {
        get {
            defaults.string(forKey: Keys.logFilePath) ?? defaultLogFilePath
        }
        set {
            defaults.set(newValue, forKey: Keys.logFilePath)
        }
    }

    static var defaultLogFilePath: String {
        "\(NSHomeDirectory())/.local/log/rclone-sync.log"
    }

    // MARK: - Sync Script Path
    static var syncScriptPath: String {
        get {
            defaults.string(forKey: Keys.syncScriptPath) ?? defaultSyncScriptPath
        }
        set {
            defaults.set(newValue, forKey: Keys.syncScriptPath)
        }
    }

    static var defaultSyncScriptPath: String {
        "\(NSHomeDirectory())/.local/bin/rclone-sync.sh"
    }

    // MARK: - Sync Directory Path (local folder being synced)
    static var syncDirectoryPath: String {
        get {
            defaults.string(forKey: Keys.syncDirectoryPath) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Keys.syncDirectoryPath)
        }
    }

    // MARK: - Drive Path to Monitor (for mount detection)
    static var drivePathToMonitor: String {
        get {
            defaults.string(forKey: Keys.drivePathToMonitor) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Keys.drivePathToMonitor)
        }
    }

    // MARK: - Setup Status
    static var hasCompletedSetup: Bool {
        get {
            defaults.bool(forKey: Keys.hasCompletedSetup)
        }
        set {
            defaults.set(newValue, forKey: Keys.hasCompletedSetup)
        }
    }

    // MARK: - Validation
    static var isConfigured: Bool {
        !logFilePath.isEmpty && FileManager.default.fileExists(atPath: logFilePath)
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

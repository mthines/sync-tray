import Foundation
import os.log

/// Global app settings (not profile-specific)
struct SyncTraySettings {
    private static let logger = Logger(subsystem: "com.synctray.app", category: "debug")
    private static let defaults = UserDefaults.standard

    private enum Keys {
        // Legacy keys for migration
        static let rcloneRemote = "rcloneRemote"
        static let localSyncPath = "localSyncPath"
        static let drivePathToMonitor = "drivePathToMonitor"
        static let syncIntervalMinutes = "syncIntervalMinutes"
        static let additionalRcloneFlags = "additionalRcloneFlags"
        static let logFilePath = "logFilePath"
        static let syncScriptPath = "syncScriptPath"
        static let syncDirectoryPath = "syncDirectoryPath"
        static let hasCompletedSetup = "hasCompletedSetup"
        static let isScheduledSyncInstalled = "isScheduledSyncInstalled"

        // Migration flag
        static let hasCompletedMultiProfileMigration = "hasCompletedMultiProfileMigration"

        // Debug settings
        static let debugLoggingEnabled = "debugLoggingEnabled"
    }

    // MARK: - Debug Settings

    /// Enable verbose debug logging for file watchers and sync triggers
    static var debugLoggingEnabled: Bool {
        get { defaults.bool(forKey: Keys.debugLoggingEnabled) }
        set { defaults.set(newValue, forKey: Keys.debugLoggingEnabled) }
    }

    /// Log a debug message if debug logging is enabled
    static func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        logger.info("\(message, privacy: .public)")
    }

    // MARK: - Migration Support

    /// Check if we need to migrate from single-profile to multi-profile
    static var needsMultiProfileMigration: Bool {
        !defaults.bool(forKey: Keys.hasCompletedMultiProfileMigration) &&
        !legacyRcloneRemote.isEmpty
    }

    static func markMigrationComplete() {
        defaults.set(true, forKey: Keys.hasCompletedMultiProfileMigration)
    }

    // MARK: - Legacy Settings (for reading during migration)

    static var legacyRcloneRemote: String {
        defaults.string(forKey: Keys.rcloneRemote) ?? ""
    }

    static var legacyLocalSyncPath: String {
        defaults.string(forKey: Keys.localSyncPath) ?? ""
    }

    static var legacyDrivePathToMonitor: String {
        defaults.string(forKey: Keys.drivePathToMonitor) ?? ""
    }

    static var legacySyncIntervalMinutes: Int {
        let value = defaults.integer(forKey: Keys.syncIntervalMinutes)
        return value > 0 ? value : 15
    }

    static var legacyAdditionalRcloneFlags: String {
        defaults.string(forKey: Keys.additionalRcloneFlags) ?? ""
    }

    /// Create a SyncProfile from legacy settings
    static func createProfileFromLegacySettings() -> SyncProfile? {
        guard !legacyRcloneRemote.isEmpty else { return nil }

        // Parse rclone remote into remote and path
        let parts = legacyRcloneRemote.components(separatedBy: ":")
        let remote = parts.first ?? ""
        let remotePath = parts.dropFirst().joined(separator: ":")

        return SyncProfile(
            name: "Default",
            rcloneRemote: remote,
            remotePath: remotePath,
            localSyncPath: legacyLocalSyncPath,
            drivePathToMonitor: legacyDrivePathToMonitor,
            syncIntervalMinutes: legacySyncIntervalMinutes,
            additionalRcloneFlags: legacyAdditionalRcloneFlags,
            isEnabled: true
        )
    }

    /// Clear legacy settings after migration
    static func clearLegacySettings() {
        defaults.removeObject(forKey: Keys.rcloneRemote)
        defaults.removeObject(forKey: Keys.localSyncPath)
        defaults.removeObject(forKey: Keys.drivePathToMonitor)
        defaults.removeObject(forKey: Keys.syncIntervalMinutes)
        defaults.removeObject(forKey: Keys.additionalRcloneFlags)
        defaults.removeObject(forKey: Keys.logFilePath)
        defaults.removeObject(forKey: Keys.syncScriptPath)
        defaults.removeObject(forKey: Keys.syncDirectoryPath)
        defaults.removeObject(forKey: Keys.hasCompletedSetup)
        defaults.removeObject(forKey: Keys.isScheduledSyncInstalled)
    }
}

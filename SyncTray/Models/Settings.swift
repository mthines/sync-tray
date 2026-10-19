import AppKit
import Foundation
import CryptoKit
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

        // Auto-fix settings
        static let autoFixSyncIssues = "autoFixSyncIssues"

        // Telemetry settings
        static let telemetryEnabled = "telemetryEnabled"
        static let installationId = "installationId"
        static let telemetryBannerDismissedVersion = "telemetryBannerDismissedVersion"
        static let lastLaunchedVersion = "lastLaunchedVersion"
        static let finderSetupVersion = "finderSetupVersion"
    }

    // MARK: - Telemetry Settings

    /// Whether anonymous telemetry is enabled. Off by default (opt-in).
    static var telemetryEnabled: Bool {
        get { defaults.bool(forKey: Keys.telemetryEnabled) }
        set { defaults.set(newValue, forKey: Keys.telemetryEnabled) }
    }

    /// A persistent anonymous installation ID (UUID) for correlating metrics.
    /// Generated once and stored in UserDefaults. Never contains personal data.
    static var installationId: String {
        if let existing = defaults.string(forKey: Keys.installationId) {
            return existing
        }
        let newId = UUID().uuidString
        defaults.set(newId, forKey: Keys.installationId)
        return newId
    }

    /// A stable, anonymous user identifier derived from the hardware UUID.
    /// HMAC-SHA256(hardwareUUID, key: "synctray-telemetry") — not reversible,
    /// survives reinstalls, and correlates all telemetry to the same physical machine.
    static var anonymousUserId: String {
        let hardwareUUID = platformUUID() ?? installationId
        let key = SymmetricKey(data: Data("synctray-telemetry".utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(hardwareUUID.utf8),
            using: key
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Read the hardware UUID from IOKit (stable across reinstalls).
    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        let key = kIOPlatformUUIDKey as CFString
        guard let uuid = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        return uuid
    }

    /// The one-line description of what telemetry shares, shown by the app's opt-in
    /// banner and the CLI's first-run question, so the two always say the same thing.
    static let telemetryConsentSummary = "Usage data — sync results, error types, feature usage, profile names. No file names, remote names, or credentials."

    /// The current consent banner version. Bump this to re-show the banner to all users,
    /// even those who previously dismissed it. Independent of the app version.
    static let currentTelemetryConsentVersion = 1

    /// The consent banner version the user last dismissed (or opted in on).
    /// Returns 0 if the user has never interacted with the banner.
    static var telemetryBannerDismissedVersion: Int {
        get { defaults.integer(forKey: Keys.telemetryBannerDismissedVersion) }
        set { defaults.set(newValue, forKey: Keys.telemetryBannerDismissedVersion) }
    }

    /// Whether the banner should be shown — true if the user hasn't dismissed the current version.
    static var telemetryBannerDismissed: Bool {
        telemetryBannerDismissedVersion >= currentTelemetryConsentVersion
    }

    /// The `service.version` recorded the last time the app launched.
    /// Used to detect upgrades (deployment markers) across launches.
    /// nil on a fresh install (no upgrade event should be emitted then).
    static var lastLaunchedVersion: String? {
        get { defaults.string(forKey: Keys.lastLaunchedVersion) }
        set { defaults.set(newValue, forKey: Keys.lastLaunchedVersion) }
    }

    /// App version the FinderSync extension was last (re)loaded for. When this differs
    /// from the current version — i.e. after an install/upgrade — SyncTray relaunches
    /// Finder on the next launch so it drops the stale extension and loads the new
    /// binary, without the user restarting Finder manually. Kept separate from
    /// `lastLaunchedVersion` so telemetry's deployment tracking and this can't race.
    static var finderSetupVersion: String? {
        get { defaults.string(forKey: Keys.finderSetupVersion) }
        set { defaults.set(newValue, forKey: Keys.finderSetupVersion) }
    }

    // MARK: - Auto-Fix Settings

    /// Automatically run --resync when bisync detects an out-of-sync state. On by default.
    static var autoFixSyncIssues: Bool {
        get {
            // UserDefaults.bool returns false when key is absent — default ON requires
            // registering a default or using object(forKey:) and treating nil as true.
            if defaults.object(forKey: Keys.autoFixSyncIssues) == nil {
                return true  // default ON
            }
            return defaults.bool(forKey: Keys.autoFixSyncIssues)
        }
        set { defaults.set(newValue, forKey: Keys.autoFixSyncIssues) }
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

// MARK: - Menu Bar Icon Appearance

/// How the menu bar status icon is drawn (App Settings → Menu Bar Icon).
///
/// An accessibility setting. The default ring — a blue arc over a faint gray track —
/// can have very little contrast: macOS tints a translucent menu bar with the
/// wallpaper, so a blue wallpaper puts the blue arc on a blue background.
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    /// The default: a blue ring while syncing, a gray ring when idle, and colored
    /// symbols for the paused, error, drive and setup states.
    case color
    /// A template image: macOS draws every state in the menu bar's own text color
    /// (black or white, following the wallpaper and dark mode), the way Apple's own
    /// menu bar icons are drawn. The highest-contrast choice.
    case monochrome
    /// The ring in two colors the user picks: one for syncing, one for idle.
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .color: return "Color"
        case .monochrome: return "Monochrome"
        case .custom: return "Custom"
        }
    }

    var caption: String {
        switch self {
        case .color:
            return "Blue while syncing, gray when idle, colored symbols for other states."
        case .monochrome:
            return "Drawn in the menu bar's own text color, like Apple's icons. Easiest to see on any wallpaper."
        case .custom:
            return "Pick the ring's colors. Paused, error, and drive symbols keep their usual colors."
        }
    }
}

/// Everything the menu bar icon renderer needs, resolved from the stored preference
/// so the drawing code never reads UserDefaults itself.
struct MenuBarIconAppearance {
    /// UserDefaults keys. `SyncTrayApp` reads them with `@AppStorage`, so the menu bar
    /// icon redraws as soon as `AppSettingsView` (which writes them) changes one.
    /// Deliberately not mirrored into `settings.json` (`AppSettingsFileStore` is a
    /// Bool-only safe-key mirror); they are display preferences, not sync behaviour.
    static let styleKey = "menuBarIconStyle"
    static let syncingColorKey = "menuBarIconSyncingColor"
    static let idleColorKey = "menuBarIconIdleColor"

    static let defaultStyle: MenuBarIconStyle = .color
    /// The `.color` style's colors, and the fallback for an unset or unreadable custom color.
    static let defaultSyncingColor = NSColor.systemBlue
    static let defaultIdleColor = NSColor.gray
    /// Opacity of the unfilled part of the ring.
    static let trackOpacity: CGFloat = 0.4

    /// The arc drawn while syncing.
    let syncingColor: NSColor
    /// The full ring drawn when idle.
    let idleColor: NSColor
    /// The unfilled part of the ring behind the syncing arc.
    let trackColor: NSColor
    /// Draw as a template image: macOS supplies the color (the menu bar's text color)
    /// and only the alpha of what is drawn matters.
    let isTemplate: Bool
    /// Whether the paused, error, drive and setup symbols keep their status colors.
    let usesStatusColors: Bool

    /// The look before this setting existed, and what an unset preference resolves to.
    static let standard = MenuBarIconAppearance.resolve(
        style: MenuBarIconAppearance.defaultStyle, syncingHex: "", idleHex: ""
    )

    static func resolve(style: MenuBarIconStyle, syncingHex: String, idleHex: String) -> MenuBarIconAppearance {
        switch style {
        case .color:
            return MenuBarIconAppearance(
                syncingColor: defaultSyncingColor,
                idleColor: defaultIdleColor,
                trackColor: NSColor.gray.withAlphaComponent(trackOpacity),
                isTemplate: false,
                usesStatusColors: true
            )
        case .monochrome:
            // Any opaque color works here: a template image keeps only the alpha.
            return MenuBarIconAppearance(
                syncingColor: .black,
                idleColor: .black,
                trackColor: NSColor.black.withAlphaComponent(trackOpacity),
                isTemplate: true,
                usesStatusColors: false
            )
        case .custom:
            let syncing = color(fromHex: syncingHex) ?? defaultSyncingColor
            return MenuBarIconAppearance(
                syncingColor: syncing,
                idleColor: color(fromHex: idleHex) ?? defaultIdleColor,
                // The track follows the syncing color, so a light color picked for a dark
                // or saturated menu bar isn't paired with a gray track that disappears.
                trackColor: syncing.withAlphaComponent(trackOpacity),
                isTemplate: false,
                usesStatusColors: true
            )
        }
    }

    /// Parses `#RRGGBB` (the `#` optional, either case) into an opaque sRGB color.
    /// Returns nil for anything else, including an empty string (an unset color).
    static func color(fromHex hex: String) -> NSColor? {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6,
              digits.allSatisfy({ $0.isHexDigit }),
              let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// `#RRGGBB` for a color, converted to sRGB first; opacity is dropped. Returns nil
    /// for a color with no sRGB equivalent, such as a pattern image.
    static func hexString(from color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int {
            Int((min(max(component, 0), 1) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent)
        )
    }
}

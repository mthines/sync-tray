import Foundation

/// Mirrors a SAFE, enumerated subset of `SyncTraySettings` to
/// `~/.config/synctray/settings.json` so it can be hand-edited live by an
/// external agent or human, the same way `{shortId}.profile.json` mirrors a
/// profile.
///
/// Only the four keys in `SafeKey` are ever written. Adding a new key is an
/// explicit, reviewable opt-in — never derived automatically from
/// `SyncTraySettings`' full key set — so secrets (`installationId`,
/// `anonymousUserId`) and any other sensitive key can never leak into the file
/// just because someone added a property to `SyncTraySettings`.
enum AppSettingsFileStore {
    /// Enumerated safe-key allowlist. Each case is a key this file may mirror.
    enum SafeKey: String, CaseIterable {
        case debugLoggingEnabled
        case autoFixSyncIssues
        case telemetryEnabled
        case launchAtLogin
    }

    /// Relative `$schema` reference from `settings.json` (which lives directly
    /// in the config directory) to the installed schema file.
    private static let schemaRef = "./schema/settings.schema.json"

    static var defaultDirectory: String {
        "\(NSHomeDirectory())/.config/synctray"
    }

    static var settingsFilePath: String {
        "\(defaultDirectory)/settings.json"
    }

    /// Snapshot the current safe settings from `SyncTraySettings` (the source
    /// of truth). `isLoginItemEnabled` is passed in because that state lives
    /// in `SMAppService`, not `SyncTraySettings`.
    static func currentSafeSettings(isLoginItemEnabled: Bool) -> [SafeKey: Bool] {
        [
            .debugLoggingEnabled: SyncTraySettings.debugLoggingEnabled,
            .autoFixSyncIssues: SyncTraySettings.autoFixSyncIssues,
            .telemetryEnabled: SyncTraySettings.telemetryEnabled,
            .launchAtLogin: isLoginItemEnabled,
        ]
    }

    /// Write `settings.json` (safe keys + `$schema`) into `directory` (defaults
    /// to the real config directory; overridable for self-test isolation).
    /// Notes the write's content hash in `ConfigSelfWriteRegistry` so
    /// `ConfigFileWatcher` ignores the FSEvent this write produces.
    /// - Returns: the written file path, or nil on failure.
    @discardableResult
    static func writeSettingsFile(
        isLoginItemEnabled: Bool,
        directory: String = AppSettingsFileStore.defaultDirectory
    ) -> String? {
        var payload: [String: Any] = ["$schema": schemaRef]
        for (key, value) in currentSafeSettings(isLoginItemEnabled: isLoginItemEnabled) {
            payload[key.rawValue] = value
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }

        let path = "\(directory)/settings.json"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            ConfigSelfWriteRegistry.shared.noteSelfWrite(contentHash: ConfigSelfWriteRegistry.hash(data))
            return path
        } catch {
            print("Failed to write settings.json: \(error)")
            return nil
        }
    }

    /// Read the safe keys present in the `settings.json` at `path` (defaults to
    /// the real settings file). A key absent from the file is simply absent
    /// from the result — callers treat "absent" as "leave unchanged", never
    /// as "reset to a default".
    static func readSafeSettings(at path: String = AppSettingsFileStore.settingsFilePath) -> [SafeKey: Bool] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var result: [SafeKey: Bool] = [:]
        for key in SafeKey.allCases {
            if let value = json[key.rawValue] as? Bool {
                result[key] = value
            }
        }
        return result
    }
}

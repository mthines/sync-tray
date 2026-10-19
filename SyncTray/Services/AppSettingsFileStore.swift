import Foundation

/// Mirrors a SAFE, enumerated subset of `SyncTraySettings` to
/// `~/.config/synctray/settings.json` so it can be hand-edited live by an
/// external agent or human, the same way `{shortId}.profile.json` mirrors a
/// profile.
///
/// Only the keys in `SafeKey` (on/off) and `StringKey` (validated strings) are
/// ever written. Adding a new key is an explicit, reviewable opt-in — never derived automatically from
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

    /// String-valued keys, each validated by `normalize` before it is stored or
    /// applied. The raw value is also the `UserDefaults` key the app reads
    /// (`MenuBarIconAppearance`'s `@AppStorage` keys).
    enum StringKey: String, CaseIterable {
        case menuBarIconStyle
        case menuBarIconSyncingColor
        case menuBarIconIdleColor

        /// Values the CLI lists in its help and errors.
        var allowedValues: String {
            switch self {
            case .menuBarIconStyle:
                return MenuBarIconStyle.allCases.map(\.rawValue).joined(separator: "|")
            case .menuBarIconSyncingColor, .menuBarIconIdleColor:
                return "#RRGGBB, or '' for the default color"
            }
        }

        /// The canonical stored form of `raw`, or nil when it isn't a valid value.
        /// A style must be one of `MenuBarIconStyle`; a color is `#RRGGBB`
        /// (uppercased, `#` added) or empty for "use the default color".
        func normalize(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch self {
            case .menuBarIconStyle:
                return MenuBarIconStyle(rawValue: trimmed.lowercased())?.rawValue
            case .menuBarIconSyncingColor, .menuBarIconIdleColor:
                if trimmed.isEmpty { return "" }
                guard let color = MenuBarIconAppearance.color(fromHex: trimmed) else { return nil }
                return MenuBarIconAppearance.hexString(from: color)
            }
        }

        /// The value an unset preference resolves to.
        var defaultValue: String {
            switch self {
            case .menuBarIconStyle: return MenuBarIconAppearance.defaultStyle.rawValue
            case .menuBarIconSyncingColor, .menuBarIconIdleColor: return ""
            }
        }
    }

    /// Every key `settings.json` may carry, in file order (`$schema` aside).
    /// `schema/settings.schema.json`'s properties must match it exactly — AC-ST1.
    static var allKeyNames: [String] {
        SafeKey.allCases.map(\.rawValue) + StringKey.allCases.map(\.rawValue)
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

    /// Snapshot the current string settings from `defaults` (the store the
    /// app's `@AppStorage` reads). An unset or invalid stored value reports
    /// its default, so the file never mirrors a value the app wouldn't use.
    static func currentStringSettings(defaults: UserDefaults = .standard) -> [StringKey: String] {
        var result: [StringKey: String] = [:]
        for key in StringKey.allCases {
            let stored = defaults.string(forKey: key.rawValue) ?? key.defaultValue
            result[key] = key.normalize(stored) ?? key.defaultValue
        }
        return result
    }

    /// Set one key in `settings.json`, keeping every other key as the file has it.
    /// For a writer outside the app (the CLI): rewriting the whole file from its own
    /// view could flip `launchAtLogin`, which the running app applies on any change.
    /// A missing file is created from the current settings.
    @discardableResult
    static func updateSettingsFile(
        _ key: SafeKey,
        to value: Bool,
        isLoginItemEnabled: Bool,
        directory: String = AppSettingsFileStore.defaultDirectory
    ) -> Bool {
        updateSettingsFile(values: [key.rawValue: value], isLoginItemEnabled: isLoginItemEnabled, directory: directory)
    }

    /// Set several keys at once (values already validated: `Bool` for a `SafeKey`,
    /// a normalized `String` for a `StringKey`), keeping every other key as the
    /// file has it. One write, so the running app reconciles the change once.
    @discardableResult
    static func updateSettingsFile(
        values: [String: Any],
        isLoginItemEnabled: Bool,
        directory: String = AppSettingsFileStore.defaultDirectory
    ) -> Bool {
        let path = "\(directory)/settings.json"
        var payload: [String: Any]
        if let data = FileManager.default.contents(atPath: path),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            payload = existing
        } else {
            payload = currentPayload(isLoginItemEnabled: isLoginItemEnabled)
        }
        for (key, value) in values { payload[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The whole file as the app would write it: `$schema` plus every key.
    private static func currentPayload(isLoginItemEnabled: Bool) -> [String: Any] {
        var payload: [String: Any] = ["$schema": schemaRef]
        for (key, value) in currentSafeSettings(isLoginItemEnabled: isLoginItemEnabled) {
            payload[key.rawValue] = value
        }
        for (key, value) in currentStringSettings() {
            payload[key.rawValue] = value
        }
        return payload
    }

    /// `UserDefaults` key holding the key/value pairs the app last wrote to
    /// `settings.json` (JSON), so launch can tell an edit made outside the app
    /// from a value the app changed itself without rewriting the file.
    static let lastWrittenSnapshotKey = "settingsFileLastWrittenSnapshot"

    /// Write `settings.json` (every key + `$schema`) into `directory` (defaults
    /// to the real config directory; overridable for self-test isolation).
    /// Notes the write's content hash in `ConfigSelfWriteRegistry` so
    /// `ConfigFileWatcher` ignores the FSEvent this write produces, and stores
    /// the written values in `defaults` as the last-written snapshot. Only this
    /// whole-file write updates the snapshot — `updateSettingsFile` (the CLI)
    /// doesn't, so a CLI write counts as an edit made outside the app.
    /// - Returns: the written file path, or nil on failure.
    @discardableResult
    static func writeSettingsFile(
        isLoginItemEnabled: Bool,
        directory: String = AppSettingsFileStore.defaultDirectory,
        defaults: UserDefaults = .standard
    ) -> String? {
        let payload = currentPayload(isLoginItemEnabled: isLoginItemEnabled)

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }

        let path = "\(directory)/settings.json"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            ConfigSelfWriteRegistry.shared.noteSelfWrite(contentHash: ConfigSelfWriteRegistry.hash(data))
            var snapshot = payload
            snapshot["$schema"] = nil
            if let snapshotData = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
                defaults.set(snapshotData, forKey: lastWrittenSnapshotKey)
            }
            return path
        } catch {
            print("Failed to write settings.json: \(error)")
            return nil
        }
    }

    /// The values the app last wrote to `settings.json`, or nil when it never
    /// has (or the stored snapshot is unreadable).
    static func lastWrittenSnapshot(defaults: UserDefaults = .standard) -> [String: Any]? {
        guard let data = defaults.data(forKey: lastWrittenSnapshotKey) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The whole `settings.json` at `path` as a JSON object, or nil when it is
    /// missing or not a JSON object.
    static func readSettingsFileJSON(at path: String = AppSettingsFileStore.settingsFilePath) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The keys whose valid value in `file` differs from what the app last wrote
    /// (`snapshot`) — the edits made outside the app since then (a hand edit, or
    /// the CLI's merge write). Launch applies only these, so a value the app
    /// changed without rewriting the file (the telemetry banner) is never
    /// reverted by the stale file. Values compare normalized (`Bool` for a
    /// `SafeKey`, `StringKey.normalize` for a `StringKey`); a key missing from
    /// the snapshot counts as changed, an invalid file value never does. A nil
    /// snapshot (the app has never written the file, e.g. the first launch after
    /// an upgrade) changes nothing: the app's own settings stay authoritative.
    static func keysChangedSinceLastWrite(file: [String: Any], snapshot: [String: Any]?) -> Set<String> {
        guard let snapshot else { return [] }
        var changed: Set<String> = []
        for key in SafeKey.allCases {
            guard let value = file[key.rawValue] as? Bool else { continue }
            if snapshot[key.rawValue] as? Bool != value { changed.insert(key.rawValue) }
        }
        for key in StringKey.allCases {
            guard let raw = file[key.rawValue] as? String, let value = key.normalize(raw) else { continue }
            let previous = (snapshot[key.rawValue] as? String).flatMap(key.normalize)
            if previous != value { changed.insert(key.rawValue) }
        }
        return changed
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

    /// Read the string keys present in the `settings.json` at `path`, normalized.
    /// A key that is absent, not a string, or not a valid value is left out —
    /// "leave unchanged", the same rule as `readSafeSettings`.
    static func readStringSettings(at path: String = AppSettingsFileStore.settingsFilePath) -> [StringKey: String] {
        guard let json = readSettingsFileJSON(at: path) else { return [:] }

        var result: [StringKey: String] = [:]
        for key in StringKey.allCases {
            if let raw = json[key.rawValue] as? String, let value = key.normalize(raw) {
                result[key] = value
            }
        }
        return result
    }
}

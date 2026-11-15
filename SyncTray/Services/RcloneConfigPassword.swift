import Foundation
import Security

/// Support for an encrypted `rclone.conf` (`rclone config encryption`).
///
/// rclone asks for the config password before it can read any remote. A launchd run has no
/// terminal, so SyncTray stores the password in the macOS Keychain and hands rclone a
/// `RCLONE_PASSWORD_COMMAND` that asks the app for it. The password is never written to
/// profile files, plists, logs, telemetry or process arguments.
///
/// The command runs the SyncTray binary itself (`<exe> rclone-password get`), so the Keychain
/// item's default access list trusts only the signed app — another process running as the user
/// can't read it silently with `security find-generic-password`.
enum RcloneConfigPassword {
    /// First bytes rclone writes to an encrypted config.
    static let encryptedMarker = "RCLONE_ENCRYPT_V0:"

    /// Keychain service. Debug builds use their own item, like the `.dev` bundle id.
    static var keychainService: String {
        #if DEBUG
        return "com.synctray.rclone-config.dev"
        #else
        return "com.synctray.rclone-config"
        #endif
    }

    static let keychainAccount = "rclone.conf"

    // MARK: - Pure helpers

    /// True when rclone.conf text is an encrypted config.
    static func isEncrypted(configContents: String) -> Bool {
        configContents.hasPrefix(encryptedMarker)
            || configContents.contains("\n" + encryptedMarker)
    }

    /// Single-quote `value` for a POSIX shell (`'` becomes `'\''`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command rclone runs to obtain the password. rclone does NOT use a shell for it: it
    /// splits the string itself (space-separated, CSV-style double quotes, `""` for a literal
    /// quote) and execs the result, so single quotes would be taken as part of the path. The
    /// path is double-quoted that way, which also means nothing in it is ever shell-expanded.
    static func passwordCommand(executablePath: String) -> String {
        "\"" + executablePath.replacingOccurrences(of: "\"", with: "\"\"") + "\" rclone-password get"
    }

    /// `base` plus `RCLONE_PASSWORD_COMMAND`, unless the user already supplies a password
    /// (`RCLONE_CONFIG_PASS`) or their own command — theirs wins.
    static func environment(base: [String: String], executablePath: String?) -> [String: String] {
        var env = base
        guard let executablePath, !executablePath.isEmpty else { return env }
        if (env["RCLONE_CONFIG_PASS"] ?? "").isEmpty, (env["RCLONE_PASSWORD_COMMAND"] ?? "").isEmpty {
            env["RCLONE_PASSWORD_COMMAND"] = passwordCommand(executablePath: executablePath)
        }
        return env
    }

    /// Path of the running SyncTray binary, for the password command.
    static var currentExecutablePath: String? {
        Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first
    }

    /// The process environment every rclone child should get.
    static func rcloneEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        for (key, value) in extra { base[key] = value }
        return environment(base: base, executablePath: currentExecutablePath)
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    /// Whether a password is stored. Asks for attributes only, so it never shows a prompt.
    static var isStored: Bool {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The stored password, or nil. May prompt for an untrusted (e.g. unsigned dev) build.
    static func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ password: String) -> Bool {
        let data = Data(password.utf8)
        let update = SecItemUpdate(
            baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = baseQuery()
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func clear() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// The one way to build an rclone `Process`: it carries the password environment, so an
/// encrypted rclone.conf opens without a terminal. Callers set pipes and run it themselves.
enum RcloneProcess {
    static func make(
        rclonePath: String, arguments: [String], extraEnv: [String: String] = [:]
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = arguments
        process.environment = RcloneConfigPassword.rcloneEnvironment(extra: extraEnv)
        return process
    }
}

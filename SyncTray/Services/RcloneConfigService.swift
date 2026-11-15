import Foundation
import AppKit

/// Service for managing rclone configuration (remotes)
final class RcloneConfigService {
    static let shared = RcloneConfigService()

    private init() {}

    // MARK: - Constants

    /// Path to rclone configuration file
    private var configPath: String {
        "\(NSHomeDirectory())/.config/rclone/rclone.conf"
    }

    // MARK: - Encrypted config

    /// Whether rclone.conf is an encrypted config (`rclone config encryption`). An encrypted
    /// file has no readable sections, so every direct read below goes through rclone instead.
    func configIsEncrypted() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: configPath) else { return false }
        defer { try? handle.close() }
        // The marker is on the first non-comment line; a short head is enough.
        let head = handle.readData(ofLength: 512)
        return RcloneConfigPassword.isEncrypted(configContents: String(decoding: head, as: UTF8.self))
    }

    /// Run rclone with a hard timeout and the password environment. `environment` replaces
    /// the default one when given (used to verify a candidate password).
    func runRclone(
        _ args: [String], timeout: TimeInterval, environment: [String: String]? = nil
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        guard let rclonePath = findRclonePath() else { return (127, "", "rclone not found") }
        let proc = RcloneProcess.make(rclonePath: rclonePath, arguments: args)
        if let environment { proc.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { return (-1, "", "\(error)") }
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let (out, err) = Self.drainPipes(stdout: outPipe, stderr: errPipe)
        proc.waitUntilExit()
        watchdog.cancel()
        return (proc.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    private let dumpLock = NSLock()
    private var cachedDump: (at: Date, remotes: [String: [String: String]])?

    /// Every remote's settings via `rclone config dump` (decrypts an encrypted config).
    /// Cached for a few seconds — a settings screen asks for several remotes in a row.
    func dumpConfig() -> [String: [String: String]]? {
        dumpLock.lock()
        if let cached = cachedDump, Date().timeIntervalSince(cached.at) < 5 {
            dumpLock.unlock()
            return cached.remotes
        }
        dumpLock.unlock()
        let result = runRclone(["config", "dump"], timeout: 15)
        guard result.exitCode == 0,
              let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        else { return nil }
        var remotes: [String: [String: String]] = [:]
        for (name, raw) in object {
            guard let fields = raw as? [String: Any] else { continue }
            remotes[name] = fields.mapValues { "\($0)" }
        }
        dumpLock.lock()
        cachedDump = (Date(), remotes)
        dumpLock.unlock()
        return remotes
    }

    private func invalidateDumpCache() {
        dumpLock.lock()
        cachedDump = nil
        dumpLock.unlock()
    }

    /// `rclone config create|update` for an encrypted config, where the file can't be edited
    /// as text. Values were already obscured by the caller, hence `--no-obscure`. NOTE: the
    /// values are rclone arguments, so they are visible in `ps` for the moment rclone runs —
    /// the cost of letting rclone own the encryption; plain-text configs keep the file path.
    private func configCreateOrUpdate(_ verb: String, _ config: RemoteConfiguration) throws {
        var args = ["config", verb, config.name]
        if verb == "create" { args.append(config.provider.rcloneType) }
        for (key, value) in config.values.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            args += [key, value]
        }
        if let token = config.oauthToken { args += ["token", token] }
        args += ["--non-interactive", "--no-obscure"]
        let result = runRclone(args, timeout: 30)
        invalidateDumpCache()
        guard result.exitCode == 0 else { throw ConfigError.configWriteFailed }
    }

    // MARK: - Rclone Path

    private func findRclonePath() -> String? {
        RcloneLocator.resolve()
    }

    /// Check if rclone is installed
    func isRcloneInstalled() -> Bool {
        findRclonePath() != nil
    }

    /// Get rclone version string
    func getRcloneVersion() -> String? {
        guard let rclonePath = findRclonePath() else { return nil }

        let process = RcloneProcess.make(rclonePath: rclonePath, arguments: [])
        let pipe = Pipe()
        process.arguments = ["version"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // First line contains version: "rclone v1.65.0"
                return output.components(separatedBy: "\n").first
            }
        } catch {
            return nil
        }

        return nil
    }

    // MARK: - Remote Management

    /// List all configured remotes
    func listRemotes() -> [String] {
        guard let rclonePath = findRclonePath() else { return [] }

        let process = RcloneProcess.make(rclonePath: rclonePath, arguments: [])
        let pipe = Pipe()
        let errPipe = Pipe()
        process.arguments = ["listremotes"]
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
            let (data, _) = Self.drainPipes(stdout: pipe, stderr: errPipe)
            process.waitUntilExit()
            // A failed run (e.g. an encrypted config with no password) has nothing to list;
            // its error text is NOT a remote name.
            guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
                return []
            }
            return Self.parseRemoteNames(output).map { $0 + ":" }
        } catch {
            return []
        }

        return []
    }

    /// Remote names from `rclone listremotes` stdout: only lines of the form `name:`.
    static func parseRemoteNames(_ output: String) -> [String] {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasSuffix(":") && $0.count > 1 && !$0.contains(" ") }
            .map { String($0.dropLast()) }
    }

    /// Check if a remote name already exists
    func remoteExists(_ name: String) -> Bool {
        let remoteName = name.hasSuffix(":") ? name : "\(name):"
        return listRemotes().contains(remoteName)
    }

    /// Add a new remote to rclone config
    func addRemote(_ config: RemoteConfiguration) throws {
        if configIsEncrypted() {
            if listRemotes().contains(config.name) { throw ConfigError.remoteAlreadyExists(config.name) }
            var configToWrite = config
            obscurePasswordFields(&configToWrite)
            try configCreateOrUpdate("create", configToWrite)
            return
        }
        // Read existing config
        var existingConfig = ""
        if FileManager.default.fileExists(atPath: configPath) {
            existingConfig = try String(contentsOfFile: configPath, encoding: .utf8)
        }

        // Check for duplicate
        if existingConfig.contains("[\(config.name)]") {
            throw ConfigError.remoteAlreadyExists(config.name)
        }

        // Obscure password before writing
        var configToWrite = config
        obscurePasswordFields(&configToWrite)

        // Generate new section
        let newSection = configToWrite.generateConfigSection()

        // Append to config
        let newConfig = existingConfig.isEmpty
            ? newSection
            : "\(existingConfig)\n\n\(newSection)"

        try writeConfig(newConfig)
    }

    /// Write rclone.conf readable by the owner only (0600). The file holds OAuth tokens
    /// and passwords that `rclone reveal` turns back into plain text, and rclone keeps a
    /// file's existing mode when it saves, so the mode set here is the one it keeps.
    private func writeConfig(_ contents: String) throws {
        let fileManager = FileManager.default

        // 0700 applies only to directories created here; an existing one is left alone.
        let configDir = (configPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(
            atPath: configDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // A new file is created 0600 before anything is written to it, and an existing
        // looser file is tightened first; the atomic write keeps the existing file's mode.
        if !fileManager.fileExists(atPath: configPath) {
            guard fileManager.createFile(
                atPath: configPath,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw ConfigError.configWriteFailed
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)

        try contents.write(toFile: configPath, atomically: true, encoding: .utf8)

        // Enforce 0600 on the file the atomic write left behind.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
    }

    /// Tighten an rclone.conf that an earlier SyncTray wizard created world-readable
    /// (0644). Runs once per launch; only a regular file owned by this user with group
    /// or other bits set is changed, and nothing is ever created. `attributesOfItem`
    /// does not follow a final symlink, so a symlinked rclone.conf is left alone.
    func tightenConfigPermissionsIfLoose() {
        let fileManager = FileManager.default
        guard let attrs = try? fileManager.attributesOfItem(atPath: configPath),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attrs[.posixPermissions] as? Int,
              mode & 0o077 != 0 else { return }

        // Keep the owner bits as they are and drop only group/other.
        try? fileManager.setAttributes([.posixPermissions: mode & 0o700], ofItemAtPath: configPath)
    }

    /// Read configuration for an existing remote from rclone.conf
    /// Returns a RemoteConfiguration pre-populated with the remote's current settings.
    func readRemoteConfig(name: String) -> RemoteConfiguration? {
        if configIsEncrypted() {
            guard var values = dumpConfig()?[name], let type = values.removeValue(forKey: "type") else { return nil }
            return Self.remoteConfiguration(name: name, rcloneType: type, values: values)
        }
        guard FileManager.default.fileExists(atPath: configPath),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }

        // Parse INI-style config file
        let lines = content.components(separatedBy: "\n")
        var inSection = false
        var values: [String: String] = [:]
        var rcloneType: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "[\(name)]" {
                inSection = true
                continue
            }

            if inSection {
                // Stop at next section
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    break
                }

                // Parse key = value
                if let eqRange = trimmed.range(of: " = ") {
                    let key = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
                    let value = String(trimmed[eqRange.upperBound...])
                    if key == "type" {
                        rcloneType = value
                    } else {
                        values[key] = value
                    }
                }
            }
        }

        guard inSection, let type = rcloneType else { return nil }
        return Self.remoteConfiguration(name: name, rcloneType: type, values: values)
    }

    /// Build a `RemoteConfiguration` from a remote's `type` and its other key/values — shared
    /// by the plain-text parser and the `rclone config dump` reader.
    static func remoteConfiguration(
        name: String, rcloneType type: String, values: [String: String]
    ) -> RemoteConfiguration {
        let provider = providerFromRcloneType(type, values: values)
        var config = RemoteConfiguration(name: name, provider: provider)

        // Copy values (overriding defaults)
        for (key, value) in values {
            config.values[key] = value
        }

        // Extract OAuth token if present
        if let token = values["token"] {
            config.oauthToken = token
            config.values.removeValue(forKey: "token")
        }

        return config
    }

    /// rclone.conf's raw text, or nil when it is missing or unreadable. Blocking file I/O —
    /// call it off the main thread on a hot path. Used by telemetry's
    /// `RemoteBackendType.types(for:rcloneConfig:)`, which reads it once per snapshot.
    func readConfigContents() -> String? {
        if configIsEncrypted() {
            // Telemetry only looks up each remote's `type`, so render just that from the
            // decrypted dump — no secrets are copied out of it.
            guard let remotes = dumpConfig() else { return nil }
            return remotes.keys.sorted().map { "[\($0)]\ntype = \(remotes[$0]?["type"] ?? "")" }
                .joined(separator: "\n\n")
        }
        return try? String(contentsOfFile: configPath, encoding: .utf8)
    }

    /// The raw `type` value of the `[name]` section in rclone.conf text `content` — e.g.
    /// `drive`, `protondrive`, `smb` — or nil when there is no such section or it has no
    /// `type` line (an encrypted rclone.conf has no readable sections at all). The same INI
    /// reading as `readRemoteConfig(name:)`, but also accepts a hand-written `type=drive`
    /// without spaces and skips `#`/`;` comment lines. Pure, so the self-test can drive it
    /// on a string (AC-TS4).
    static func remoteType(named name: String, inConfig content: String) -> String? {
        guard !name.isEmpty else { return nil }
        var inSection = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Reached the next section without seeing a `type` line.
                if inSection { return nil }
                inSection = trimmed == "[\(name)]"
                continue
            }
            guard inSection, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
                  let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "type" else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Map rclone type string to RemoteProvider
    private static func providerFromRcloneType(_ type: String, values: [String: String]) -> RemoteProvider {
        switch type {
        case "drive":
            return .googleDrive
        case "dropbox":
            return .dropbox
        case "onedrive":
            return .oneDrive
        case "webdav":
            if isSynologyRemote(values: values) {
                return .synology
            }
            return .webdav
        case "sftp":
            return .sftp
        case "smb":
            return .smb
        default:
            return .webdav
        }
    }

    /// Detect whether a WebDAV remote is a Synology NAS based on config values
    private static func isSynologyRemote(values: [String: String]) -> Bool {
        if let vendor = values["vendor"], vendor == "synology" {
            return true
        }
        guard let url = values["url"]?.lowercased() else { return false }
        // Synology DSM ports
        if url.contains(":5005") || url.contains(":5006") || url.contains(":5001") {
            return true
        }
        // Synology QuickConnect
        if url.contains("quickconnect.to") {
            return true
        }
        // Synology DDNS domains
        if url.contains(".synology.me") || url.contains(".dsm.") {
            return true
        }
        return false
    }

    /// Update an existing remote (delete old config section, write new one)
    func updateRemote(_ config: RemoteConfiguration) throws {
        if configIsEncrypted() {
            // `config update` only changes the keys it is given, so drop the section first to
            // keep "delete + rewrite" semantics (a cleared field must really go away).
            try deleteRemote(config.name)
            var configToWrite = config
            obscurePasswordFields(&configToWrite)
            try configCreateOrUpdate("create", configToWrite)
            return
        }
        // Delete the existing remote first
        try deleteRemote(config.name)

        // Read existing config (after deletion)
        var existingConfig = ""
        if FileManager.default.fileExists(atPath: configPath) {
            existingConfig = try String(contentsOfFile: configPath, encoding: .utf8)
        }

        // Obscure password before writing
        var configToWrite = config
        obscurePasswordFields(&configToWrite)

        // Generate new section
        let newSection = configToWrite.generateConfigSection()

        // Append to config
        let newConfig = existingConfig.isEmpty
            ? newSection
            : "\(existingConfig)\n\n\(newSection)"

        try writeConfig(newConfig)
    }

    /// Delete a remote from rclone config
    func deleteRemote(_ name: String) throws {
        guard let rclonePath = findRclonePath() else {
            throw ConfigError.rcloneNotFound
        }

        let process = RcloneProcess.make(rclonePath: rclonePath, arguments: ["config", "delete", name])
        invalidateDumpCache()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw ConfigError.deleteFailed(name)
        }
    }

    /// Test connection to a remote path (e.g. "synology:" or "synology:Kaiju")
    func testConnection(_ remotePath: String) async -> Result<Void, ConfigError> {
        guard let rclonePath = findRclonePath() else {
            return .failure(.rcloneNotFound)
        }

        // Check if remote has no_check_certificate set
        let remoteName = remotePath.replacingOccurrences(of: ":", with: "").split(separator: "/").first.map(String.init) ?? remotePath.replacingOccurrences(of: ":", with: "")
        let skipCert = readRemoteConfig(name: remoteName)?.values["no_check_certificate"] == "true"

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = RcloneProcess.make(rclonePath: rclonePath, arguments: [])
                let pipe = Pipe()
                let remote = remotePath.contains(":") ? remotePath : "\(remotePath):"
                var args = ["lsd", remote, "--contimeout", "10s"]
                if skipCert {
                    args.append("--no-check-certificate")
                }
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .success(()))
                    } else {
                        let error = String(data: data, encoding: .utf8) ?? "Connection failed"
                        continuation.resume(returning: .failure(.connectionFailed(error)))
                    }
                } catch {
                    continuation.resume(returning: .failure(.connectionFailed(error.localizedDescription)))
                }
            }
        }
    }

    // MARK: - OAuth Flow

    /// Start OAuth flow for a provider
    /// Opens system browser and runs rclone authorize to capture token
    func startOAuthFlow(
        for provider: RemoteProvider,
        completion: @escaping (Result<String, ConfigError>) -> Void
    ) {
        guard let rclonePath = findRclonePath() else {
            completion(.failure(.rcloneNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = RcloneProcess.make(rclonePath: rclonePath, arguments: [])
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.arguments = ["authorize", provider.rcloneType]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()

                // Capture output in background
                var outputData = Data()
                var errorData = Data()

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    outputData.append(handle.availableData)
                }

                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    errorData.append(handle.availableData)
                }

                process.waitUntilExit()

                // Clean up handlers
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 {
                    let output = String(data: outputData, encoding: .utf8) ?? ""

                    // Extract token from output
                    // rclone outputs: Paste the following into your remote machine --->
                    // {"access_token":"...","token_type":"Bearer",...}
                    // <---End paste
                    if let token = self.extractToken(from: output) {
                        DispatchQueue.main.async {
                            completion(.success(token))
                        }
                    } else {
                        DispatchQueue.main.async {
                            completion(.failure(.tokenExtractionFailed))
                        }
                    }
                } else {
                    let error = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    DispatchQueue.main.async {
                        completion(.failure(.oauthFailed(error)))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.oauthFailed(error.localizedDescription)))
                }
            }
        }
    }

    /// Extract OAuth token JSON from rclone authorize output
    private func extractToken(from output: String) -> String? {
        // Look for JSON token between markers
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") && trimmed.contains("access_token") {
                return trimmed
            }
        }

        // Alternative: look for token between paste markers
        if let startRange = output.range(of: "--->"),
           let endRange = output.range(of: "<---")
        {
            let tokenRange = startRange.upperBound..<endRange.lowerBound
            let tokenSection = String(output[tokenRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Find JSON in the section
            if let jsonStart = tokenSection.range(of: "{"),
               let jsonEnd = tokenSection.range(of: "}", options: .backwards)
            {
                let json = String(tokenSection[jsonStart.lowerBound...jsonEnd.upperBound])
                return json
            }
        }

        return nil
    }

    // MARK: - Password Obscuring

    /// Obscure password fields in a RemoteConfiguration before writing to config.
    /// Skips values that are already obscured (read back from an existing config).
    private func obscurePasswordFields(_ config: inout RemoteConfiguration) {
        for field in config.provider.requiredFields where field.type == .password {
            guard let value = config.values[field.key], !value.isEmpty else { continue }
            // If the value can be revealed, it's already obscured — don't double-obscure
            if isAlreadyObscured(value) { continue }
            if let obscured = obscurePassword(value) {
                config.values[field.key] = obscured
            }
        }
    }

    /// Check if a password string is already in rclone's obscured format
    private func isAlreadyObscured(_ value: String) -> Bool {
        guard let rclonePath = findRclonePath() else { return false }

        let process = RcloneProcess.make(rclonePath: rclonePath, arguments: [])
        let pipe = Pipe()
        process.arguments = ["reveal", value]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Obscure a password using rclone (for secure storage in config)
    func obscurePassword(_ password: String) -> String? {
        guard let rclonePath = findRclonePath() else { return nil }

        let process = RcloneProcess.make(rclonePath: rclonePath, arguments: [])
        let pipe = Pipe()
        process.arguments = ["obscure", password]
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - List Remote Contents

    /// Folder names from `rclone lsf --dirs-only` output: one name per line, each ending in `/`.
    /// Uses `lsf` rather than `lsd` because `lsd` prints names in a whitespace-padded column,
    /// and splitting that on whitespace turned "My Folder" into "Folder". Names are kept
    /// verbatim, so leading and trailing spaces survive.
    static func parseDirectoryListing(_ output: String) -> [String] {
        output.components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { $0.hasSuffix("/") && $0.count > 1 }
            .map { String($0.dropLast()) }
            .sorted()
    }

    /// The `rclone` arguments every folder listing uses — the folder chooser, the
    /// setup wizard and `synctray remote folders` — paired with `parseDirectoryListing`.
    static func folderListingArguments(_ target: String, skipCertCheck: Bool) -> [String] {
        ["lsf", target, "--dirs-only"] + (skipCertCheck ? ["--no-check-certificate"] : [])
    }

    /// Reads a child's stdout and stderr to EOF at the same time. Reading one pipe
    /// to EOF before the other deadlocks once the child fills the unread pipe's
    /// ~64 KB buffer: it blocks writing, so the pipe being read never closes.
    /// Call before `waitUntilExit()`.
    static func drainPipes(stdout: Pipe, stderr: Pipe) -> (out: Data, err: Data) {
        var err = Data()
        let errGroup = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: errGroup) {
            err = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        errGroup.wait()
        return (out, err)
    }

    /// List folders at the root of a remote
    func listFolders(remote: String) async -> Result<[String], ConfigError> {
        guard let rclonePath = findRclonePath() else {
            return .failure(.rcloneNotFound)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = RcloneProcess.make(rclonePath: rclonePath, arguments: [])
                let pipe = Pipe()
                let errPipe = Pipe()
                let remotePath = remote.hasSuffix(":") ? remote : "\(remote):"
                let remoteName = remote.replacingOccurrences(of: ":", with: "")
                let skipCert = self.readRemoteConfig(name: remoteName)?.values["no_check_certificate"] == "true"
                process.arguments = Self.folderListingArguments(remotePath, skipCertCheck: skipCert)
                process.standardOutput = pipe
                process.standardError = errPipe

                do {
                    try process.run()
                    let (data, errData) = Self.drainPipes(stdout: pipe, stderr: errPipe)
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        let output = String(decoding: data, as: UTF8.self)
                        continuation.resume(returning: .success(Self.parseDirectoryListing(output)))
                    } else {
                        let error = String(data: errData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(returning: .failure(.connectionFailed(error)))
                    }
                } catch {
                    continuation.resume(returning: .failure(.connectionFailed(error.localizedDescription)))
                }
            }
        }
    }

    // MARK: - Errors

    enum ConfigError: LocalizedError {
        case rcloneNotFound
        case remoteAlreadyExists(String)
        case deleteFailed(String)
        case connectionFailed(String)
        case oauthFailed(String)
        case tokenExtractionFailed
        case configWriteFailed

        var errorDescription: String? {
            switch self {
            case .rcloneNotFound:
                return "rclone is not installed. Please install it with: brew install rclone"
            case .remoteAlreadyExists(let name):
                return "A remote named '\(name)' already exists"
            case .deleteFailed(let name):
                return "Failed to delete remote '\(name)'"
            case .connectionFailed(let error):
                return SyncLogPatterns.isRcloneConfigPasswordError(error)
                    ? SyncLogPatterns.rcloneConfigPasswordHint
                    : "Connection failed: \(error)"
            case .oauthFailed(let error):
                return "Authentication failed: \(error)"
            case .tokenExtractionFailed:
                return "Failed to extract authentication token"
            case .configWriteFailed:
                return "Failed to write rclone configuration"
            }
        }
    }
}

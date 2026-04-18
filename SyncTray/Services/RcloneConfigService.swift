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

    // MARK: - Rclone Path

    private func findRclonePath() -> String? {
        let paths = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Check if rclone is installed
    func isRcloneInstalled() -> Bool {
        findRclonePath() != nil
    }

    /// Get rclone version string
    func getRcloneVersion() -> String? {
        guard let rclonePath = findRclonePath() else { return nil }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
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

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["listremotes"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        } catch {
            return []
        }

        return []
    }

    /// Check if a remote name already exists
    func remoteExists(_ name: String) -> Bool {
        let remoteName = name.hasSuffix(":") ? name : "\(name):"
        return listRemotes().contains(remoteName)
    }

    /// Add a new remote to rclone config
    func addRemote(_ config: RemoteConfiguration) throws {
        // Ensure config directory exists
        let configDir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: configDir,
            withIntermediateDirectories: true
        )

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

        try newConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Read configuration for an existing remote from rclone.conf
    /// Returns a RemoteConfiguration pre-populated with the remote's current settings.
    func readRemoteConfig(name: String) -> RemoteConfiguration? {
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

    /// Map rclone type string to RemoteProvider
    private func providerFromRcloneType(_ type: String, values: [String: String]) -> RemoteProvider {
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
    private func isSynologyRemote(values: [String: String]) -> Bool {
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
        // Delete the existing remote first
        try deleteRemote(config.name)

        // Ensure config directory exists
        let configDir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: configDir,
            withIntermediateDirectories: true
        )

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

        try newConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Delete a remote from rclone config
    func deleteRemote(_ name: String) throws {
        guard let rclonePath = findRclonePath() else {
            throw ConfigError.rcloneNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["config", "delete", name]

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
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: rclonePath)
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
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: rclonePath)
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

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
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

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
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

    /// List folders at the root of a remote
    func listFolders(remote: String) async -> Result<[String], ConfigError> {
        guard let rclonePath = findRclonePath() else {
            return .failure(.rcloneNotFound)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: rclonePath)
                let remotePath = remote.hasSuffix(":") ? remote : "\(remote):"
                let remoteName = remote.replacingOccurrences(of: ":", with: "")
                let skipCert = self.readRemoteConfig(name: remoteName)?.values["no_check_certificate"] == "true"
                var args = ["lsd", remotePath]
                if skipCert {
                    args.append("--no-check-certificate")
                }
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        if let output = String(data: data, encoding: .utf8) {
                            // Parse lsd output format: "     -1 2000-01-01 01:00:00        -1 FolderName"
                            // Format: size date time count name (with variable whitespace)
                            let folders = output.components(separatedBy: "\n")
                                .compactMap { line -> String? in
                                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                                    guard !trimmed.isEmpty else { return nil }
                                    // Match: -1 YYYY-MM-DD HH:MM:SS -1 FolderName
                                    // (size) (date) (time) (count) (name)
                                    let pattern = #"^-?\d+\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+-?\d+\s+(.+)$"#
                                    if let regex = try? NSRegularExpression(pattern: pattern),
                                       let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                                       let folderRange = Range(match.range(at: 1), in: trimmed) {
                                        return String(trimmed[folderRange])
                                    }
                                    return nil
                                }
                            continuation.resume(returning: .success(folders))
                        } else {
                            continuation.resume(returning: .success([]))
                        }
                    } else {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let error = String(data: data, encoding: .utf8) ?? "Unknown error"
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
                return "Connection failed: \(error)"
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

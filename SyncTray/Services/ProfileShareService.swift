import Foundation

/// Encodes and decodes shared profile files. Owns the per-provider redaction
/// allowlist so there's a single place to audit what leaves the user's machine.
final class ProfileShareService {
    static let shared = ProfileShareService()

    private init() {}

    // MARK: - Errors

    enum ShareError: LocalizedError {
        case unsupportedVersion(Int)
        case decodeFailed(String)
        case encodeFailed(String)
        case missingProfile
        case missingRemote
        case remoteCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "This file was exported by a newer version of SyncTray (format v\(v))."
            case .decodeFailed(let msg):
                return "Could not read the shared profile: \(msg)"
            case .encodeFailed(let msg):
                return "Could not export profile: \(msg)"
            case .missingProfile:
                return "The shared file does not contain a profile."
            case .missingRemote:
                return "The shared file does not contain a remote configuration."
            case .remoteCreationFailed(let msg):
                return "Failed to create remote: \(msg)"
            }
        }
    }

    // MARK: - Redaction

    /// Fields that must never appear in an export. Always stripped, regardless of user toggles.
    /// Source of truth for what leaves the machine.
    static func sensitiveFields(for provider: RemoteProvider) -> Set<String> {
        switch provider {
        case .googleDrive:
            // OAuth token handled separately. root_folder_id often points at a
            // private folder shared only with the exporter's account.
            return ["root_folder_id"]
        case .dropbox:
            return []
        case .oneDrive:
            return ["drive_id"]
        case .synology, .webdav:
            return ["user", "pass"]
        case .smb:
            return ["user", "pass"]
        case .sftp:
            return ["user", "pass", "key_file"]
        }
    }

    /// Returns true if the field would be stripped on export (used for UI redaction badges).
    static func isSensitiveField(_ key: String, provider: RemoteProvider) -> Bool {
        sensitiveFields(for: provider).contains(key) || key == "token"
    }

    // MARK: - Export

    struct ExportOptions {
        var includeProfile: Bool = true
        var includePrimaryRemote: Bool = true
        var includeFallbackRemote: Bool = true
        var includeExcludeFilter: Bool = true
    }

    /// Build a `SharedProfile` from a live `SyncProfile`, applying redaction.
    func makeSharedProfile(from profile: SyncProfile, options: ExportOptions) -> SharedProfile {
        var shared = SharedProfile()

        if options.includeProfile {
            shared.profile = SharedProfileBody(
                name: profile.name,
                rcloneRemote: profile.rcloneRemote,
                remotePath: profile.remotePath,
                syncIntervalMinutes: profile.syncIntervalMinutes,
                additionalRcloneFlags: profile.additionalRcloneFlags,
                syncMode: profile.syncMode,
                syncDirection: profile.syncDirection,
                fallbackRemote: profile.fallbackRemote,
                fallbackRemotePath: profile.fallbackRemotePath,
                vfsCacheMode: profile.vfsCacheMode,
                vfsCacheMaxSize: profile.vfsCacheMaxSize,
                allowNonEmptyMount: profile.allowNonEmptyMount,
                pinnedDirectories: profile.pinnedDirectories
            )
        }

        if options.includePrimaryRemote {
            let name = profile.rcloneRemote.hasSuffix(":")
                ? String(profile.rcloneRemote.dropLast())
                : profile.rcloneRemote
            if !name.isEmpty,
               let cfg = RcloneConfigService.shared.readRemoteConfig(name: name) {
                shared.remote = redact(cfg)
            }
        }

        if options.includeFallbackRemote, !profile.fallbackRemote.isEmpty {
            let name = profile.fallbackRemote.hasSuffix(":")
                ? String(profile.fallbackRemote.dropLast())
                : profile.fallbackRemote
            if let cfg = RcloneConfigService.shared.readRemoteConfig(name: name) {
                shared.fallbackRemote = redact(cfg)
            }
        }

        if options.includeExcludeFilter,
           FileManager.default.fileExists(atPath: profile.filterFilePath),
           let contents = try? String(contentsOfFile: profile.filterFilePath, encoding: .utf8),
           !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shared.excludeFilter = contents
        }

        return shared
    }

    /// Apply the redaction allowlist to a `RemoteConfiguration`, returning a `SharedRemote`
    /// safe to write to disk.
    private func redact(_ config: RemoteConfiguration) -> SharedRemote {
        var safe = config.values
        for key in Self.sensitiveFields(for: config.provider) {
            safe.removeValue(forKey: key)
        }
        // OAuth `token` lives on `RemoteConfiguration.oauthToken`, but defend against it
        // ever appearing in `values` directly.
        safe.removeValue(forKey: "token")
        // Drop empty values to keep the file tidy.
        safe = safe.filter { !$0.value.isEmpty }
        return SharedRemote(name: config.name, provider: config.provider, values: safe)
    }

    // MARK: - Encoding

    func encode(_ shared: SharedProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            return try encoder.encode(shared)
        } catch {
            throw ShareError.encodeFailed(error.localizedDescription)
        }
    }

    /// Returns the encoded JSON as a String, suitable for clipboard or preview display.
    func encodeAsString(_ shared: SharedProfile) throws -> String {
        let data = try encode(shared)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Decoding

    func decode(_ data: Data) throws -> SharedProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let shared: SharedProfile
        do {
            shared = try decoder.decode(SharedProfile.self, from: data)
        } catch {
            throw ShareError.decodeFailed(error.localizedDescription)
        }

        if shared.synctrayVersion > SharedProfile.currentVersion {
            throw ShareError.unsupportedVersion(shared.synctrayVersion)
        }

        return shared
    }

    func decode(fileURL: URL) throws -> SharedProfile {
        let data = try Data(contentsOf: fileURL)
        return try decode(data)
    }

    // MARK: - Import

    /// Result returned by `installImport` so the caller can navigate to the new profile.
    struct ImportResult {
        let profile: SyncProfile
        let primaryRemoteName: String
        let fallbackRemoteName: String?
    }

    /// Materializes a shared profile + remote into the user's rclone config and profile store.
    ///
    /// - Parameters:
    ///   - shared: Decoded shared file.
    ///   - localSyncPath: Recipient's local sync path (required).
    ///   - drivePathToMonitor: Optional drive path if the recipient is using an external drive.
    ///   - primaryRemoteOverride: A user-edited primary remote (with credentials filled in).
    ///   - primaryRemoteAction: Whether to create a fresh remote or reuse an existing one of the same name.
    ///   - fallbackRemoteOverride: User-edited fallback remote (credentials filled in), if applicable.
    ///   - fallbackRemoteAction: Reuse vs create for the fallback remote.
    ///   - profileStore: Store to add the new profile to.
    @MainActor
    func installImport(
        shared: SharedProfile,
        localSyncPath: String,
        drivePathToMonitor: String,
        primaryRemoteOverride: RemoteConfiguration?,
        primaryRemoteAction: RemoteAction,
        fallbackRemoteOverride: RemoteConfiguration?,
        fallbackRemoteAction: RemoteAction,
        profileStore: ProfileStore
    ) throws -> ImportResult {
        guard let body = shared.profile else { throw ShareError.missingProfile }

        // Track newly-created remotes so we can roll them back if a later step fails.
        var rollbackRemoteNames: [String] = []

        let primaryName: String
        if shared.remote != nil {
            primaryName = try resolveRemote(
                override: primaryRemoteOverride,
                action: primaryRemoteAction
            )
            if case .create = primaryRemoteAction {
                rollbackRemoteNames.append(primaryName)
            }
        } else if !body.rcloneRemote.isEmpty,
                  RcloneConfigService.shared.remoteExists(body.rcloneRemote) {
            // No remote in the file — recipient already has one with the right name.
            primaryName = body.rcloneRemote
        } else {
            throw ShareError.missingRemote
        }

        var fallbackName: String?
        if !body.fallbackRemote.isEmpty {
            do {
                if shared.fallbackRemote != nil {
                    let resolved = try resolveRemote(
                        override: fallbackRemoteOverride,
                        action: fallbackRemoteAction
                    )
                    fallbackName = resolved
                    if case .create = fallbackRemoteAction {
                        rollbackRemoteNames.append(resolved)
                    }
                } else if RcloneConfigService.shared.remoteExists(body.fallbackRemote) {
                    fallbackName = body.fallbackRemote
                }
                // If fallback isn't resolvable, silently drop it — the profile still works without it.
            } catch {
                // Roll back any remotes we created in this transaction.
                for name in rollbackRemoteNames {
                    try? RcloneConfigService.shared.deleteRemote(name)
                }
                throw error
            }
        }

        // Build the new profile.
        var newProfile = SyncProfile(
            name: body.name,
            rcloneRemote: primaryName,
            remotePath: body.remotePath,
            localSyncPath: localSyncPath,
            drivePathToMonitor: drivePathToMonitor,
            syncIntervalMinutes: body.syncIntervalMinutes,
            additionalRcloneFlags: body.additionalRcloneFlags,
            isEnabled: false,                       // never auto-arm on import
            isMuted: false,
            syncMode: body.syncMode,
            syncDirection: body.syncDirection,
            fallbackRemote: fallbackName ?? "",
            fallbackRemotePath: body.fallbackRemotePath,
            vfsCacheMode: body.vfsCacheMode,
            vfsCacheMaxSize: body.vfsCacheMaxSize,
            allowNonEmptyMount: body.allowNonEmptyMount,
            pinnedDirectories: body.pinnedDirectories
        )

        // Disambiguate the display name if one already exists.
        newProfile.name = profileStore.uniqueName(basedOn: body.name)

        profileStore.add(newProfile)

        // Write the exclude filter file alongside the profile, if provided.
        if let filter = shared.excludeFilter,
           !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.createDirectory(
                atPath: SyncProfile.configDirectory,
                withIntermediateDirectories: true
            )
            try? filter.write(toFile: newProfile.filterFilePath, atomically: true, encoding: .utf8)
        }

        return ImportResult(
            profile: newProfile,
            primaryRemoteName: primaryName,
            fallbackRemoteName: fallbackName
        )
    }

    /// What to do when an import wants to install a remote whose name already exists.
    enum RemoteAction {
        /// Create the remote (the override's name has already been resolved to be unique).
        case create
        /// Reuse the existing remote with the given name; don't write to rclone.conf.
        case reuse(String)
    }

    private func resolveRemote(
        override: RemoteConfiguration?,
        action: RemoteAction
    ) throws -> String {
        switch action {
        case .reuse(let name):
            return name
        case .create:
            guard let cfg = override else { throw ShareError.missingRemote }
            do {
                try RcloneConfigService.shared.addRemote(cfg)
                return cfg.name
            } catch {
                throw ShareError.remoteCreationFailed(error.localizedDescription)
            }
        }
    }

    /// Materializes a `RemoteConfiguration` from a `SharedRemote`, ready to be edited
    /// by the recipient. Default values for required fields are applied automatically.
    func makeEditableRemote(from shared: SharedRemote) -> RemoteConfiguration {
        var cfg = RemoteConfiguration(name: shared.name, provider: shared.provider)
        for (key, value) in shared.values {
            cfg.values[key] = value
        }
        return cfg
    }
}

// MARK: - ProfileStore helpers

extension ProfileStore {
    /// Returns a name that doesn't clash with any existing profile name. Appends "(2)", "(3)", etc.
    func uniqueName(basedOn name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Imported Profile" : trimmed
        let existing = Set(profiles.map { $0.name })
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base) (\(i))") { i += 1 }
        return "\(base) (\(i))"
    }
}

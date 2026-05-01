import Foundation

/// On-disk format for sharing a sync profile + remote between users.
///
/// The format strips credentials (passwords, OAuth tokens, usernames, key paths) and
/// machine-specific values (local paths, UUIDs, RC ports). The recipient supplies
/// their own credentials and local path during import.
struct SharedProfile: Codable {
    /// Schema version. Bump when making incompatible changes.
    static let currentVersion: Int = 1

    /// Default file extension for exports.
    static let fileExtension: String = "synctrayprofile"

    var synctrayVersion: Int = SharedProfile.currentVersion
    var exportedAt: Date = Date()

    /// The profile body — sync settings without machine-specific paths.
    var profile: SharedProfileBody?

    /// The primary remote — provider config without credentials.
    var remote: SharedRemote?

    /// Optional fallback remote (only present if the source profile had one).
    var fallbackRemote: SharedRemote?

    /// Optional contents of the profile's exclude filter file.
    var excludeFilter: String?
}

extension SharedProfile: Identifiable {
    /// Synthetic id derived from the export timestamp + name. Sufficient for
    /// SwiftUI's `.sheet(item:)` since only one shared profile is presented at a time.
    var id: String {
        "\(exportedAt.timeIntervalSince1970)-\(profile?.name ?? "shared")"
    }
}

/// The shareable subset of a `SyncProfile`. Excludes id, local paths, drive paths,
/// `isEnabled`/`isMuted`, vfs cache path, and rcPort — all of which are
/// machine- or user-specific.
struct SharedProfileBody: Codable {
    var name: String
    var rcloneRemote: String        // remote name only — credentials live in `SharedRemote`
    var remotePath: String
    var syncIntervalMinutes: Int
    var additionalRcloneFlags: String
    var syncMode: SyncMode
    var syncDirection: SyncDirection

    /// Reference to the fallback remote (name only). Empty when no fallback.
    var fallbackRemote: String
    var fallbackRemotePath: String

    var vfsCacheMode: VFSCacheMode
    var vfsCacheMaxSize: String
    var allowNonEmptyMount: Bool
    var pinnedDirectories: [String]
}

/// Provider config for a single remote with sensitive fields stripped.
/// Stores values as a key/value map — the recipient fills in credentials at import.
struct SharedRemote: Codable {
    var name: String
    var provider: RemoteProvider
    var values: [String: String]
}

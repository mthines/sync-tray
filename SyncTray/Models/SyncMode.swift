import Foundation

/// The synchronization mode for a profile
enum SyncMode: String, Codable, CaseIterable, Identifiable {
    /// Two-way bidirectional sync (rclone bisync)
    /// Changes on either side are synchronized to the other
    case bisync = "bisync"

    /// One-way sync (rclone sync)
    /// Source is authoritative, destination is overwritten
    case sync = "sync"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bisync:
            return "Two-Way Sync"
        case .sync:
            return "One-Way Sync"
        }
    }

    var description: String {
        switch self {
        case .bisync:
            return "Changes sync both ways between local and remote"
        case .sync:
            return "Source overwrites destination (backup or mirror)"
        }
    }

    var iconName: String {
        switch self {
        case .bisync:
            return "arrow.left.arrow.right"
        case .sync:
            return "arrow.right"
        }
    }
}

/// The direction for one-way sync mode
enum SyncDirection: String, Codable, CaseIterable, Identifiable {
    /// Local folder is source, remote is destination (upload/backup)
    case localToRemote = "localToRemote"

    /// Remote is source, local folder is destination (download/mirror)
    case remoteToLocal = "remoteToLocal"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localToRemote:
            return "Local → Remote"
        case .remoteToLocal:
            return "Remote → Local"
        }
    }

    var description: String {
        switch self {
        case .localToRemote:
            return "Upload local changes to remote (backup)"
        case .remoteToLocal:
            return "Download remote to local (mirror)"
        }
    }

    var iconName: String {
        switch self {
        case .localToRemote:
            return "arrow.up.to.line"
        case .remoteToLocal:
            return "arrow.down.to.line"
        }
    }
}

import Foundation

/// The synchronization mode for a profile
enum SyncMode: String, Codable, CaseIterable, Identifiable {
    /// Two-way bidirectional sync (rclone bisync)
    /// Changes on either side are synchronized to the other
    case bisync = "bisync"

    /// One-way sync (rclone sync)
    /// Source is authoritative, destination is overwritten
    case sync = "sync"

    /// Mount remote as virtual filesystem (rclone mount / nfsmount)
    /// Files are streamed on-demand without local sync
    case mount = "mount"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bisync:
            return "Two-Way Sync"
        case .sync:
            return "One-Way Sync"
        case .mount:
            return "Stream (Mount)"
        }
    }

    var description: String {
        switch self {
        case .bisync:
            return "Changes sync both ways between local and remote"
        case .sync:
            return "Source overwrites destination (backup or mirror)"
        case .mount:
            return "Stream files on-demand without local sync"
        }
    }

    var iconName: String {
        switch self {
        case .bisync:
            return "arrow.left.arrow.right"
        case .sync:
            return "arrow.right"
        case .mount:
            return "externaldrive.badge.icloud"
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

/// VFS cache mode for mount mode
enum VFSCacheMode: String, Codable, CaseIterable, Identifiable {
    /// No caching - all operations go directly to remote
    case off = "off"

    /// Cache file structure only (metadata)
    case minimal = "minimal"

    /// Cache file structure and written files
    case writes = "writes"

    /// Full caching - cache reads and writes (recommended)
    case full = "full"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .minimal:
            return "Minimal"
        case .writes:
            return "Writes"
        case .full:
            return "Full"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "No caching (slowest, saves space)"
        case .minimal:
            return "Cache metadata only"
        case .writes:
            return "Cache metadata and written files"
        case .full:
            return "Cache reads and writes (recommended)"
        }
    }
}

/// The filesystem backend used to expose a mount-mode profile in Finder.
///
/// `nfs` uses rclone's built-in NFS server + the macOS native NFS client
/// (`rclone nfsmount`). It needs **no kernel extension** and nothing extra to
/// install, so it works on locked-down / MDM-managed Macs where macFUSE's
/// kext approval is blocked. This is the default.
///
/// `macfuse` uses the classic `rclone mount` (FUSE). It requires macFUSE (a
/// system/kernel extension) plus the official rclone binary, and is kept for
/// users who already have that set up and want its broader filesystem
/// compatibility.
enum MountBackend: String, Codable, CaseIterable, Identifiable {
    /// Kext-free NFS mount via `rclone nfsmount` (default — no macFUSE needed)
    case nfs = "nfs"

    /// Classic FUSE mount via `rclone mount` (requires macFUSE)
    case macfuse = "macfuse"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nfs:
            return "NFS (no macFUSE)"
        case .macfuse:
            return "macFUSE"
        }
    }

    var description: String {
        switch self {
        case .nfs:
            return "Kext-free — works without macFUSE or special permissions"
        case .macfuse:
            return "Requires macFUSE and the official rclone binary"
        }
    }

    /// The rclone subcommand used to establish the mount
    var rcloneSubcommand: String {
        switch self {
        case .nfs:
            return "nfsmount"
        case .macfuse:
            return "mount"
        }
    }
}

import FileProvider
import UniformTypeIdentifiers

/// An `NSFileProviderItem` backed by one rclone listing entry.
///
/// The item identifier is the remote-relative path; the root container maps to an
/// empty path. This keeps identifiers stable and lets the enumerator translate
/// directly to/from `operations/list` results.
///
/// NOTE(mac): not yet compiled — see FileProviderExtension/README.md.
final class FileProviderItem: NSObject, NSFileProviderItem {

    private let entry: RcloneRCClient.ListEntry
    private let parentPath: String
    /// Whether the user pinned this item for offline ("Keep Downloaded").
    private let isPinned: Bool

    init(entry: RcloneRCClient.ListEntry, parentPath: String, isPinned: Bool) {
        self.entry = entry
        self.parentPath = parentPath
        self.isPinned = isPinned
    }

    // Identifier == remote-relative path. Empty path == root.
    var itemIdentifier: NSFileProviderItemIdentifier {
        entry.Path.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(entry.Path)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        parentPath.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(parentPath)
    }

    var filename: String { entry.Name }

    var contentType: UTType {
        if entry.IsDir { return .folder }
        let ext = (entry.Name as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    var documentSize: NSNumber? { entry.IsDir ? nil : NSNumber(value: entry.Size) }

    var capabilities: NSFileProviderItemCapabilities {
        entry.IsDir ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
                    : [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting]
    }

    /// Pinned items are kept downloaded and never evicted; others stream on demand
    /// and may be evicted under disk pressure. (macOS 13+. Pre-13: use
    /// `NSFileProviderManager.evictItem` imperatively instead.)
    var contentPolicy: NSFileProviderContentPolicy {
        isPinned ? .downloadEagerlyAndKeepDownloaded : .downloadLazily
    }

    /// Content version must change whenever the remote bytes change so the system
    /// re-fetches. TODO(mac): fold a content hash/etag in when the remote exposes one.
    var itemVersion: NSFileProviderItemVersion {
        let modToken = Data((entry.ModTime ?? "0").utf8)
        let metaToken = Data("\(entry.Size)".utf8)
        return NSFileProviderItemVersion(contentVersion: modToken, metadataVersion: metaToken)
    }
}

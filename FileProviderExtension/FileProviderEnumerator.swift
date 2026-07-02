import FileProvider

/// Enumerates a directory (or the working set) by translating rclone listings into
/// `NSFileProviderItem`s.
///
/// Change tracking uses a per-domain monotonic **sync anchor**. v1 detects remote
/// changes by polling listings (the host app signals `.workingSet` on its watcher
/// cadence); `enumerateChanges` then diffs and returns a fresh anchor. A push-style
/// `vfs/changenotify` feed is a v3 optimization.
///
/// NOTE(mac): not yet compiled — see FileProviderExtension/README.md.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private let identifier: NSFileProviderItemIdentifier
    private let fs: String
    private let client: RcloneRCClient
    private let pinnedPaths: Set<String>

    init(identifier: NSFileProviderItemIdentifier,
         fs: String,
         client: RcloneRCClient,
         pinnedPaths: Set<String>) {
        self.identifier = identifier
        self.fs = fs
        self.client = client
        self.pinnedPaths = pinnedPaths
    }

    func invalidate() {}

    private var remotePath: String {
        identifier == .rootContainer ? "" : identifier.rawValue
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        Task {
            do {
                let entries = try await client.list(fs: fs, remote: remotePath)
                let items = entries.map {
                    FileProviderItem(entry: $0,
                                     parentPath: remotePath,
                                     isPinned: pinnedPaths.contains($0.Path))
                }
                observer.didEnumerate(items)
                // Single page for v1. TODO(mac): page large directories with a cursor.
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                         from anchor: NSFileProviderSyncAnchor) {
        // v1: re-list and let the system reconcile by itemVersion. A precise diff
        // (updated vs deleted) against a persisted snapshot is the correctness upgrade.
        Task {
            do {
                let entries = try await client.list(fs: fs, remote: remotePath)
                let items = entries.map {
                    FileProviderItem(entry: $0,
                                     parentPath: remotePath,
                                     isPinned: pinnedPaths.contains($0.Path))
                }
                observer.didUpdate(items)
                observer.finishEnumeratingChanges(upTo: bumped(anchor), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // TODO(mac): persist the anchor per domain in the App Group container.
        completionHandler(NSFileProviderSyncAnchor(Data("0".utf8)))
    }

    private func bumped(_ anchor: NSFileProviderSyncAnchor) -> NSFileProviderSyncAnchor {
        let current = Int(String(decoding: anchor.rawValue, as: UTF8.self)) ?? 0
        return NSFileProviderSyncAnchor(Data("\(current + 1)".utf8))
    }
}

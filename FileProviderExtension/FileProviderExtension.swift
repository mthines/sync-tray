import FileProvider

/// Entry point for SyncTray's native, kext-free streaming. One instance runs per
/// registered `NSFileProviderDomain` (one per mount-mode profile).
///
/// Responsibilities (replicated extension contract):
///   • `item(for:)`              — metadata for an identifier
///   • `fetchContents(for:…)`    — materialize a dataless file on demand (streaming)
///   • create/modify/delete      — local → remote writes (v2)
///   • `enumerator(for:)`        — directory + working-set enumeration
///
/// rclone access goes through `RcloneRCClient` against an `rclone rcd` daemon the host
/// app launches. See docs/file-provider-streaming.md.
///
/// NOTE(mac): not yet compiled / not yet a target — see FileProviderExtension/README.md.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain
    private let client: RcloneRCClient
    /// rclone remote for this domain (e.g. "mydrive:"). TODO(mac): read from the
    /// App Group config keyed by domain identifier (= profile UUID).
    private let fs: String
    /// Pinned (kept-offline) remote paths for this domain. TODO(mac): load + observe
    /// from the App Group container so host-app pin/unpin reflects here.
    private let pinnedPaths: Set<String>

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        // TODO(mac): resolve real port/remote/pins from shared App Group config.
        self.client = RcloneRCClient(port: 5800)
        self.fs = ""
        self.pinnedPaths = []
        super.init()
    }

    func invalidate() {}

    // MARK: - Item metadata

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void)
        -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                if identifier == .rootContainer {
                    let root = RcloneRCClient.ListEntry(
                        Path: "", Name: "/", Size: 0, MimeType: nil,
                        ModTime: nil, IsDir: true, ID: nil)
                    completionHandler(FileProviderItem(entry: root, parentPath: "", isPinned: false), nil)
                } else {
                    // Look the item up in its parent listing.
                    let parent = (identifier.rawValue as NSString).deletingLastPathComponent
                    let entries = try await client.list(fs: fs, remote: parent)
                    guard let match = entries.first(where: { $0.Path == identifier.rawValue }) else {
                        completionHandler(nil, NSFileProviderError(.noSuchItem))
                        progress.completedUnitCount = 1
                        return
                    }
                    completionHandler(
                        FileProviderItem(entry: match, parentPath: parent,
                                         isPinned: pinnedPaths.contains(match.Path)), nil)
                }
            } catch {
                completionHandler(nil, error)
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    // MARK: - Materialize on demand (streaming)

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void)
        -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let data = try await client.cat(fs: fs, remote: itemIdentifier.rawValue)
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try data.write(to: tmp)

                let parent = (itemIdentifier.rawValue as NSString).deletingLastPathComponent
                let entries = try await client.list(fs: fs, remote: parent)
                let entry = entries.first { $0.Path == itemIdentifier.rawValue }
                let item = entry.map {
                    FileProviderItem(entry: $0, parentPath: parent,
                                     isPinned: pinnedPaths.contains($0.Path))
                }
                completionHandler(tmp, item, nil)
            } catch {
                completionHandler(nil, nil, error)
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    // MARK: - Writes (v2)

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void)
        -> Progress {
        // TODO(mac, v2): rclone operations/uploadfile, then return the created item.
        completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void)
        -> Progress {
        // TODO(mac, v2): upload changed contents / apply rename/move via rclone.
        completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void)
        -> Progress {
        // TODO(mac, v2): rclone operations/deletefile or purge for directories.
        completionHandler(NSFileProviderError(.notAuthenticated))
        return Progress()
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        FileProviderEnumerator(identifier: containerItemIdentifier,
                               fs: fs,
                               client: client,
                               pinnedPaths: pinnedPaths)
    }
}

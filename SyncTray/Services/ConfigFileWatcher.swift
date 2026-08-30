import Foundation
import CryptoKit

/// Tracks content hashes of files SyncTray itself just wrote under
/// `~/.config/synctray`, so `ConfigFileWatcher` can distinguish an external
/// edit from an echo of its own write and skip reconciling on self-writes.
///
/// Content hash (not mtime) is the guard: an mtime-only check is not robust
/// against a rewrite that lands in the same second, which is common when the
/// app writes a profile file and the watcher's FSEvents latency window fires
/// shortly after.
final class ConfigSelfWriteRegistry {
    static let shared = ConfigSelfWriteRegistry()

    /// Pending self-write hashes → the time each was noted. Self-bounding:
    /// entries are never guaranteed to be consumed (FSEvents coalesce, and each
    /// `save()` rewrites EVERY profile file so rapid self-writes can leave
    /// hashes no matching event ever claims). Two bounds keep this from growing
    /// without limit — a 30s TTL (far larger than the ~1s debounce + FSEvents
    /// latency, so a legitimate echo is never evicted before it arrives) and a
    /// 512-entry hard cap evicting oldest-first.
    private var pending: [String: Date] = [:]
    private let lock = NSLock()

    /// Entries older than this are evicted on the next mutation.
    private let ttl: TimeInterval = 30
    /// Hard cap on retained entries; oldest are evicted first once exceeded.
    private let maxEntries = 512

    private init() {}

    /// SHA-256 hex digest of file content.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Record that SyncTray itself just wrote content with this hash — the
    /// next matching FSEvent should be treated as an echo, not an external edit.
    func noteSelfWrite(contentHash: String) {
        lock.lock()
        defer { lock.unlock() }
        pending[contentHash] = Date()
        evictStaleLocked(now: Date())
    }

    /// Returns true (and CONSUMES the entry) if this content hash matches a
    /// recently self-written file. Consuming avoids a stale hash silently
    /// suppressing a later, genuinely external edit that happens to produce
    /// identical bytes (e.g. a hand-edit that toggles a field back to the
    /// value SyncTray itself last wrote). Also opportunistically evicts stale
    /// entries so an unconsumed hash can never accumulate.
    func consumeIfSelfWrite(contentHash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let hit = pending.removeValue(forKey: contentHash) != nil
        evictStaleLocked(now: Date())
        return hit
    }

    /// Evict entries past their TTL, then enforce the entry cap by removing the
    /// oldest first. Caller must hold `lock`.
    private func evictStaleLocked(now: Date) {
        for (hash, noted) in pending where now.timeIntervalSince(noted) > ttl {
            pending.removeValue(forKey: hash)
        }
        guard pending.count > maxEntries else { return }
        let overflow = pending.count - maxEntries
        let oldest = pending.sorted { $0.value < $1.value }.prefix(overflow)
        for (hash, _) in oldest {
            pending.removeValue(forKey: hash)
        }
    }
}

/// Watches `~/.config/synctray` for external edits to `*.profile.json` and
/// `settings.json` and routes debounced changes through the SAME reconcile
/// path the in-app Save button uses — never a bare in-memory struct swap.
///
/// Reuses `DirectoryWatcher`'s FSEvents+debounce PATTERN but is intentionally
/// a separate, lighter type rather than a subclass/reuse of `DirectoryWatcher`
/// itself — that class is tuned for sync-triggering (15s debounce, phantom-path
/// detection, metadata filtering), the wrong shape for config, which needs a
/// short debounce and self-write suppression instead.
final class ConfigFileWatcher {
    private var stream: FSEventStreamRef?
    private let watchedDirectory: String
    private let onProfileChange: (String) -> Void
    private let onSettingsChange: () -> Void
    private let debounceInterval: TimeInterval

    private var debounceTimer: DispatchSourceTimer?
    private let debounceQueue = DispatchQueue(label: "com.synctray.config-watcher.debounce")
    /// Paths seen since the last debounce fired; coalesced on each reset.
    private var pendingPaths: Set<String> = []

    /// - Parameters:
    ///   - watchedDirectory: defaults to the real `~/.config/synctray`; overridable for tests.
    ///   - debounceInterval: short (~1s) — config edits are small, hand-typed files, not a
    ///     sync-triggering directory where 15s debounce avoids reacting to every intermediate write.
    init(
        watchedDirectory: String = "\(NSHomeDirectory())/.config/synctray",
        debounceInterval: TimeInterval = 1.0,
        onProfileChange: @escaping (String) -> Void,
        onSettingsChange: @escaping () -> Void
    ) {
        self.watchedDirectory = watchedDirectory
        self.debounceInterval = debounceInterval
        self.onProfileChange = onProfileChange
        self.onSettingsChange = onSettingsChange
    }

    deinit { stop() }

    /// Start watching. No-op if already started or the directory doesn't exist yet
    /// (the app ensures it exists at launch via `ConfigSchemaInstaller.writeSchemas()`).
    func start() {
        guard stream == nil else { return }
        guard FileManager.default.fileExists(atPath: watchedDirectory) else { return }

        let pathsToWatch = [watchedDirectory] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)

        guard let stream = FSEventStreamCreate(
            nil,
            configWatcherCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            flags
        ) else {
            print("ConfigFileWatcher: Failed to create FSEventStream")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        debounceTimer?.cancel()
        debounceTimer = nil

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Forwards to the shared self-write registry. Kept as an instance method
    /// so callers holding a `ConfigFileWatcher` reference (rather than the
    /// registry singleton) have a natural place to note a write.
    func noteSelfWrite(contentHash: String) {
        ConfigSelfWriteRegistry.shared.noteSelfWrite(contentHash: contentHash)
    }

    fileprivate func handleEvents(_ eventPaths: [String]) {
        let inScope = eventPaths.filter {
            $0 == watchedDirectory || $0.hasPrefix(watchedDirectory + "/")
        }
        guard !inScope.isEmpty else { return }

        debounceQueue.async { [weak self] in
            guard let self else { return }
            self.pendingPaths.formUnion(inScope)
            self.resetDebounceTimer()
        }
    }

    private func resetDebounceTimer() {
        debounceTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: debounceQueue)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let paths = self.pendingPaths
            self.pendingPaths.removeAll()
            self.debounceTimer = nil
            DispatchQueue.main.async {
                self.processChangedPaths(Array(paths))
            }
        }
        debounceTimer = timer
        timer.resume()
    }

    private func processChangedPaths(_ paths: [String]) {
        for path in paths {
            // A half-written file (partial JSON) either fails `shouldReconcile`'s
            // read/decode-adjacent hash check trivially (still reconciles — the
            // hash just won't match a self-write) or the downstream decode in
            // `applyExternalProfileEdit`/`applyExternalSettingsEdit` fails and is
            // skipped there; either way the next complete-write event reconciles.
            guard Self.shouldReconcile(forFileAt: path) else { continue }
            classify(path)
        }
    }

    private func classify(_ path: String) {
        let filename = (path as NSString).lastPathComponent
        if filename.hasSuffix(".profile.json") {
            onProfileChange(path)
        } else if filename == "settings.json" {
            onSettingsChange()
        }
        // Anything else under ~/.config/synctray (derived {shortId}.json, the
        // exclude filter, schema/) is not an authoritative agent-editable
        // surface and is intentionally ignored here.
    }

    /// Pure, directly-testable suppression check: reads the file at `path`,
    /// hashes its content, and returns false (do not reconcile) if that hash
    /// matches a write SyncTray itself just performed. A missing/unreadable
    /// file (e.g. deleted, or caught mid-write) also returns false.
    static func shouldReconcile(forFileAt path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let hash = ConfigSelfWriteRegistry.hash(data)
        if ConfigSelfWriteRegistry.shared.consumeIfSelfWrite(contentHash: hash) {
            return false
        }
        return true
    }
}

// MARK: - FSEvents Callback

private func configWatcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo = clientCallBackInfo else { return }

    let watcher = Unmanaged<ConfigFileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

    watcher.handleEvents(paths)
}

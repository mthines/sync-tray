import Foundation

/// Live progress of a VFS content-warming run for a mount-mode profile's pinned folders.
///
/// Published per profile on `SyncManager.warmProgress` and consumed by
/// `OfflineFilesSection`. One value tracks a whole run (which may cover several pinned
/// directories), so the same struct drives the manual "Sync All" button, the post-mount
/// startup warm, and Finder-triggered pins.
struct WarmProgress: Equatable {
    enum Phase: Equatable {
        case preparing          // estimating work + /vfs/refresh listing pre-step
        case downloading        // reading file bytes through the mount
        case completed
        case failed(String)
    }

    var phase: Phase
    var currentFile: String     // most recently started file (several may be in flight)
    var currentDirectory: String
    var filesDone: Int          // files fully read (advances on completion, not start)
    var filesInFlight: Int      // files currently downloading in parallel
    var filesTotal: Int         // 0 = not yet estimated / unknown
    var bytesDone: Int64        // bytes actually read through the mount so far
    var bytesTotal: Int64       // 0 = unknown
    var startedAt: Date
    var finishedAt: Date?

    init(startedAt: Date = Date()) {
        self.phase = .preparing
        self.currentFile = ""
        self.currentDirectory = ""
        self.filesDone = 0
        self.filesInFlight = 0
        self.filesTotal = 0
        self.bytesDone = 0
        self.bytesTotal = 0
        self.startedAt = startedAt
        self.finishedAt = nil
    }

    /// True while the run is still working (preparing or downloading).
    var isActive: Bool {
        switch phase {
        case .preparing, .downloading: return true
        case .completed, .failed: return false
        }
    }

    /// Determinate fraction [0, 1]. Byte-based when the total size is known, so the bar
    /// moves smoothly as bytes stream (file-based progress barely moves for big files).
    /// Falls back to file count, then indeterminate.
    var fractionComplete: Double? {
        if bytesTotal > 0 { return min(1.0, Double(bytesDone) / Double(bytesTotal)) }
        if filesTotal > 0 { return min(1.0, Double(filesDone) / Double(filesTotal)) }
        return nil
    }

    /// Wall-clock duration, frozen at `finishedAt` once the run ends.
    var elapsed: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Average throughput in bytes/second over the run so far (0 until time elapses).
    var bytesPerSecond: Double {
        let seconds = elapsed
        guard seconds > 0 else { return 0 }
        return Double(bytesDone) / seconds
    }

    var formattedBytesDone: String {
        ByteCountFormatter.string(fromByteCount: bytesDone, countStyle: .file)
    }

    var formattedBytesTotal: String {
        ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file)
    }

    /// "84.9 MB / 2.1 GB" when the total is known, else just the amount done.
    var formattedBytesProgress: String {
        guard bytesTotal > 0 else { return formattedBytesDone }
        return "\(formattedBytesDone) / \(formattedBytesTotal)"
    }

    var formattedElapsed: String {
        let total = max(0, Int(elapsed.rounded()))
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    var formattedRate: String {
        let rate = Int64(bytesPerSecond.rounded())
        return ByteCountFormatter.string(fromByteCount: rate, countStyle: .file) + "/s"
    }
}

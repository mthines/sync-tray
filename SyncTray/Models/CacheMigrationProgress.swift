import Foundation

/// Live progress of a cache-directory move for a Stream (mount) profile.
/// Mirrors `WarmProgress`'s shape (phases, published-per-profile,
/// determinate-fraction helper) for an UNRELATED operation — see plan
/// Decisions for why this is a separate model rather than reusing `WarmProgress`.
struct CacheMigrationProgress: Equatable {
    enum Phase: Equatable {
        case preflight    // computing totals / same-volume verdict / resume-skip set
        case moving       // copying or renaming subtrees
        case completed
        case cancelled
        case failed(String)
    }

    var phase: Phase
    var currentFile: String
    var filesDone: Int
    var filesTotal: Int
    var bytesDone: Int64
    var bytesTotal: Int64
    var sameVolume: Bool
    var startedAt: Date
    var finishedAt: Date?

    init(startedAt: Date = Date()) {
        self.phase = .preflight
        self.currentFile = ""
        self.filesDone = 0
        self.filesTotal = 0
        self.bytesDone = 0
        self.bytesTotal = 0
        self.sameVolume = false
        self.startedAt = startedAt
        self.finishedAt = nil
    }

    /// True while the run is still working (preflight or moving).
    var isActive: Bool {
        switch phase {
        case .preflight, .moving: return true
        case .completed, .cancelled, .failed: return false
        }
    }

    /// Determinate fraction [0, 1]. Byte-based when the total size is known
    /// (moves smoothly through large files), falling back to file count.
    var fractionComplete: Double? {
        if bytesTotal > 0 { return min(1.0, Double(bytesDone) / Double(bytesTotal)) }
        if filesTotal > 0 { return min(1.0, Double(filesDone) / Double(filesTotal)) }
        return nil
    }

    /// Wall-clock duration, frozen at `finishedAt` once the run ends.
    var elapsed: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var formattedBytesProgress: String {
        TransferFormat.bytesProgress(done: bytesDone, total: bytesTotal)
    }

    var formattedElapsed: String {
        TransferFormat.elapsed(elapsed)
    }

    var formattedRate: String {
        TransferFormat.rate(bytesDone: bytesDone, elapsedSeconds: elapsed)
    }
}

/// Shared byte/rate/elapsed formatting for transfer-style progress models.
/// Extracted so `CacheMigrationProgress` doesn't duplicate `WarmProgress`'s
/// formatters verbatim; retrofitting `WarmProgress` onto this helper is a
/// recorded follow-up (see plan Out of Scope) rather than done here, since
/// there is no local compiler to catch a mistake in that unrelated model.
enum TransferFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func bytesProgress(done: Int64, total: Int64) -> String {
        guard total > 0 else { return bytes(done) }
        return "\(bytes(done)) / \(bytes(total))"
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    static func rate(bytesDone: Int64, elapsedSeconds: TimeInterval) -> String {
        guard elapsedSeconds > 0 else { return "0 KB/s" }
        let value = Int64((Double(bytesDone) / elapsedSeconds).rounded())
        return bytes(value) + "/s"
    }
}

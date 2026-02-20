import SwiftUI

struct SyncProgress: Equatable {
    let bytesTransferred: Int64
    let totalBytes: Int64
    let eta: Int?          // seconds
    let speed: Double?     // bytes/sec
    let transfersDone: Int
    let totalTransfers: Int

    // New fields for detailed progress
    let checksDone: Int
    let totalChecks: Int
    let elapsedTime: Double?
    let errors: Int
    let transferringFiles: [TransferringFile]
    let listedCount: Int?

    var percentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes) * 100
    }

    var checksPercentage: Double {
        guard totalChecks > 0 else { return 0 }
        return Double(checksDone) / Double(totalChecks) * 100
    }

    var transfersPercentage: Double {
        guard totalTransfers > 0 else { return 0 }
        return Double(transfersDone) / Double(totalTransfers) * 100
    }

    var formattedProgress: String {
        let transferred = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let pct = Int(percentage)

        if let eta = eta, eta > 0 {
            let etaStr = SyncFormatters.formatETA(eta)
            return "Syncing: \(transferred) / \(total) (\(pct)%) - ETA \(etaStr)"
        }
        return "Syncing: \(transferred) / \(total) (\(pct)%)"
    }

    /// Formatted line for bytes transfer: "19.9 GiB / 253.7 GiB, 8%, 35.5 MiB/s, ETA 1h52m"
    var formattedTransferLine: String {
        let transferred = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let pct = Int(percentage)

        var parts = ["\(transferred) / \(total)", "\(pct)%"]

        if let spd = speed, spd > 0 {
            let speedStr = ByteCountFormatter.string(fromByteCount: Int64(spd), countStyle: .file)
            parts.append("\(speedStr)/s")
        }

        if let eta = eta, eta > 0 {
            parts.append("ETA \(SyncFormatters.formatETA(eta))")
        }

        return parts.joined(separator: ", ")
    }

    /// Formatted line for checks: "3 / 3, 100%"
    var formattedChecksLine: String? {
        guard totalChecks > 0 else { return nil }
        return "\(checksDone) / \(totalChecks), \(Int(checksPercentage))%"
    }

    /// Formatted line for file transfers: "116 / 10128, 1%"
    var formattedTransfersLine: String? {
        guard totalTransfers > 0 else { return nil }
        return "\(transfersDone) / \(totalTransfers), \(Int(transfersPercentage))%"
    }

    /// Formatted elapsed time: "9m59.9s"
    var formattedElapsedTime: String? {
        guard let elapsed = elapsedTime, elapsed > 0 else { return nil }
        let totalSeconds = Int(elapsed)
        let fraction = elapsed - Double(totalSeconds)
        let tenths = Int(fraction * 10)

        if totalSeconds < 60 {
            return "\(totalSeconds).\(tenths)s"
        }
        if totalSeconds < 3600 {
            let mins = totalSeconds / 60
            let secs = totalSeconds % 60
            return "\(mins)m\(secs).\(tenths)s"
        }
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return "\(hours)h\(mins)m\(secs)s"
    }

    /// Create with default values for optional fields (for backward compatibility)
    init(
        bytesTransferred: Int64,
        totalBytes: Int64,
        eta: Int?,
        speed: Double?,
        transfersDone: Int,
        totalTransfers: Int,
        checksDone: Int = 0,
        totalChecks: Int = 0,
        elapsedTime: Double? = nil,
        errors: Int = 0,
        transferringFiles: [TransferringFile] = [],
        listedCount: Int? = nil
    ) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.eta = eta
        self.speed = speed
        self.transfersDone = transfersDone
        self.totalTransfers = totalTransfers
        self.checksDone = checksDone
        self.totalChecks = totalChecks
        self.elapsedTime = elapsedTime
        self.errors = errors
        self.transferringFiles = transferringFiles
        self.listedCount = listedCount
    }
}

enum SyncState: Equatable {
    case idle
    case syncing
    case error(String)
    case driveNotMounted
    case notConfigured

    var iconName: String {
        switch self {
        case .idle:
            return "arrow.triangle.2.circlepath"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        case .driveNotMounted:
            return "externaldrive.badge.xmark"
        case .notConfigured:
            return "gearshape.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .idle:
            return .secondary
        case .syncing:
            return .blue
        case .error:
            return .red
        case .driveNotMounted:
            return .orange
        case .notConfigured:
            return .yellow
        }
    }

    var statusText: String {
        switch self {
        case .idle:
            return "Idle"
        case .syncing:
            return "Syncing..."
        case .error(let message):
            return "Error: \(message)"
        case .driveNotMounted:
            return "Drive not mounted"
        case .notConfigured:
            return "Setup required"
        }
    }
}

struct FileChange: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let path: String
    let operation: Operation
    var profileName: String = ""

    enum Operation: String {
        case copied = "Copied"
        case deleted = "Deleted"
        case updated = "Updated"
        case renamed = "Renamed"
        case unknown = "Changed"

        var icon: String {
            switch self {
            case .copied:
                return "plus.circle.fill"
            case .deleted:
                return "minus.circle.fill"
            case .updated:
                return "arrow.clockwise.circle.fill"
            case .renamed:
                return "pencil.circle.fill"
            case .unknown:
                return "circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .copied:
                return .green
            case .deleted:
                return .red
            case .updated:
                return .blue
            case .renamed:
                return .purple
            case .unknown:
                return .secondary
            }
        }
    }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }

    static func == (lhs: FileChange, rhs: FileChange) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Sync Log Pattern Matching

/// Centralized patterns for parsing and categorizing sync log messages.
/// Used by both LogParser and SyncManager for consistent behavior.
enum SyncLogPatterns {
    // MARK: - Sync State Detection

    /// Patterns indicating sync has started
    static func isSyncStarted(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("starting bisync") || lower.contains("starting sync")
    }

    /// Patterns indicating sync completed successfully
    static func isSyncCompleted(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("bisync successful") ||
               lower.contains("completed successfully") ||
               lower.contains("sync complete")
    }

    /// Patterns indicating sync failed
    static func isSyncFailed(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("bisync failed") ||
               lower.contains("failed with exit code") ||
               lower.contains("failed to bisync")
    }

    /// Patterns indicating drive not mounted
    static func isDriveNotMounted(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("drive not mounted") || lower.contains("not mounted")
    }

    /// Patterns indicating sync already running
    static func isSyncAlreadyRunning(_ message: String) -> Bool {
        message.lowercased().contains("already running")
    }

    // MARK: - Error Categorization

    /// Transient "all files changed" error that should be ignored.
    /// This is expected after a `--resync` and resolves on the next sync.
    static func isTransientAllFilesChangedError(_ message: String) -> Bool {
        message.contains("all files were changed") || message.contains("Safety abort")
    }

    /// Generic messages that don't provide useful error info
    static func isGenericAbortMessage(_ message: String) -> Bool {
        message.contains("Bisync aborted") || message.contains("Failed to bisync")
    }

    /// Critical/actionable errors that tell the user what to do
    static func isCriticalError(_ message: String) -> Bool {
        message.contains("out of sync") ||
        message.contains("resync") ||
        message.contains("critical") ||
        message.contains("lock file") ||
        message.contains("check file") ||
        message.contains("Access test failed") ||
        message.contains("Failed to initialise") ||
        message.contains("malformed rule")
    }

    // MARK: - Error Message Cleanup

    /// Prefixes to strip from error messages for cleaner display
    static func cleanErrorMessage(_ message: String) -> String {
        var cleaned = message

        // Strip common prefixes
        let prefixes = [
            "Bisync critical error: ",
            "Bisync aborted. "
        ]

        for prefix in prefixes {
            if let range = cleaned.range(of: prefix) {
                cleaned = String(cleaned[range.upperBound...])
                break
            }
        }

        return cleaned
    }

    // MARK: - Exit Code Extraction

    /// Extract exit code from a failure message like "Bisync failed with exit code 1"
    static func extractExitCode(from message: String) -> Int? {
        let pattern = #"exit code (\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let codeRange = Range(match.range(at: 1), in: message),
              let code = Int(message[codeRange]) else {
            return nil
        }
        return code
    }

    // MARK: - Log Line Error Extraction

    /// Check if a log line contains a plain text CRITICAL error
    static func isCriticalLogLine(_ line: String) -> Bool {
        line.contains("CRITICAL:")
    }

    /// Check if a log line contains a JSON error or notice level message
    static func isJSONErrorLine(_ line: String) -> Bool {
        line.contains("\"level\":\"error\"") || line.contains("\"level\":\"notice\"")
    }

    /// Extract error message from a log line (supports both CRITICAL and JSON formats)
    /// Returns nil if no error message can be extracted
    static func extractErrorMessage(from line: String) -> String? {
        // Check for plain text CRITICAL errors (format: "2026/02/16 06:42:11 CRITICAL: ...")
        if isCriticalLogLine(line) {
            if let range = line.range(of: "CRITICAL: ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        // Check for rclone JSON error/notice messages
        else if isJSONErrorLine(line) {
            // Parse the error message from JSON
            if let msgRange = line.range(of: "\"msg\":\""),
               let endRange = line[msgRange.upperBound...].range(of: "\"") {
                return String(line[msgRange.upperBound..<endRange.lowerBound])
            }
        }
        return nil
    }

    /// Strip ANSI escape codes from a message
    static func stripANSICodes(_ message: String) -> String {
        var result = message
        result = result.replacingOccurrences(of: "\\u001b[", with: "")
        result = result.replacingOccurrences(of: #"\[\d+m"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "[0m", with: "")
        result = result.replacingOccurrences(of: "[31m", with: "")
        result = result.replacingOccurrences(of: "[33m", with: "")
        result = result.replacingOccurrences(of: "[35m", with: "")
        result = result.replacingOccurrences(of: "[36m", with: "")
        return result
    }
}

// MARK: - Legacy Alias

/// Alias for backward compatibility
typealias SyncErrorCategory = SyncLogPatterns

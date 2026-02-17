import Foundation

struct ParsedLogEvent {
    enum EventType {
        case syncStarted
        case syncCompleted
        case syncFailed(exitCode: Int, message: String?)
        case driveNotMounted
        case syncAlreadyRunning
        case fileChange(FileChange)
        case stats(RcloneStats)
        case errorMessage(String)
        case unknown
    }

    let timestamp: Date
    let type: EventType
    let rawLine: String
}

final class LogParser {
    private let jsonDecoder = JSONDecoder()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // Regex to strip ANSI escape codes
    private let ansiPattern = try? NSRegularExpression(pattern: #"\u001B\[[0-9;]*[A-Za-z]"#)

    func parse(line: String) -> ParsedLogEvent? {
        let cleanLine = stripANSI(line)

        // Try JSON parsing first (rclone --use-json-log output)
        if cleanLine.hasPrefix("{") && cleanLine.hasSuffix("}") {
            return parseJSONLine(cleanLine)
        }

        // Fall back to plain text parsing (script markers)
        return parsePlainTextLine(cleanLine)
    }

    private func stripANSI(_ text: String) -> String {
        guard let pattern = ansiPattern else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private func parseJSONLine(_ line: String) -> ParsedLogEvent? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }

        guard let entry = try? jsonDecoder.decode(RcloneLogEntry.self, from: data) else {
            return nil
        }

        let timestamp = entry.date ?? Date()

        // Check for file operations
        if let fileChange = entry.fileChange {
            return ParsedLogEvent(
                timestamp: timestamp,
                type: .fileChange(fileChange),
                rawLine: line
            )
        }

        // Check for stats
        if let stats = entry.stats {
            return ParsedLogEvent(
                timestamp: timestamp,
                type: .stats(stats),
                rawLine: line
            )
        }

        // Check message for sync events (in JSON format)
        let msg = stripANSI(entry.msg)

        // Capture error messages from rclone
        if entry.level == "error" {
            // Clean up error message using centralized patterns
            var errorMsg = SyncLogPatterns.cleanErrorMessage(msg)

            // Truncate very long messages
            if errorMsg.count > 200 {
                errorMsg = String(errorMsg.prefix(200)) + "..."
            }

            return ParsedLogEvent(
                timestamp: timestamp,
                type: .errorMessage(errorMsg),
                rawLine: line
            )
        }

        // Check for sync failure messages (notice level)
        if SyncLogPatterns.isSyncFailed(msg) {
            // Transient "all files were changed" error should not trigger error UI
            if SyncLogPatterns.isTransientAllFilesChangedError(msg) {
                return ParsedLogEvent(
                    timestamp: timestamp,
                    type: .unknown,
                    rawLine: line
                )
            }
            let exitCode = SyncLogPatterns.extractExitCode(from: msg) ?? 1
            return ParsedLogEvent(
                timestamp: timestamp,
                type: .syncFailed(exitCode: exitCode, message: msg),
                rawLine: line
            )
        }

        return ParsedLogEvent(
            timestamp: timestamp,
            type: .unknown,
            rawLine: line
        )
    }

    private func parsePlainTextLine(_ line: String) -> ParsedLogEvent? {
        // Parse timestamp: "2026-02-14 10:30:00 - Message"
        let pattern = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) - (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        guard let timestampRange = Range(match.range(at: 1), in: line),
              let messageRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let timestampStr = String(line[timestampRange])
        let message = String(line[messageRange])
        let timestamp = dateFormatter.date(from: timestampStr) ?? Date()

        let eventType = parseEventType(from: message)

        return ParsedLogEvent(
            timestamp: timestamp,
            type: eventType,
            rawLine: line
        )
    }

    private func parseEventType(from message: String) -> ParsedLogEvent.EventType {
        if SyncLogPatterns.isSyncStarted(message) {
            return .syncStarted
        }

        if SyncLogPatterns.isSyncCompleted(message) {
            return .syncCompleted
        }

        if SyncLogPatterns.isSyncFailed(message) {
            let exitCode = SyncLogPatterns.extractExitCode(from: message) ?? -1
            return .syncFailed(exitCode: exitCode, message: nil)
        }

        if SyncLogPatterns.isDriveNotMounted(message) {
            return .driveNotMounted
        }

        if SyncLogPatterns.isSyncAlreadyRunning(message) {
            return .syncAlreadyRunning
        }

        return .unknown
    }
}

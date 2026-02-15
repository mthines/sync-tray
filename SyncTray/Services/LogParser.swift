import Foundation

struct ParsedLogEvent {
    enum EventType {
        case syncStarted
        case syncCompleted
        case syncFailed(exitCode: Int, message: String?)
        case driveNotMounted
        case syncAlreadyRunning
        case fileChange(FileChange)
        case stats(transfers: Int, errors: Int)
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
                type: .stats(transfers: stats.transfers ?? 0, errors: stats.errors ?? 0),
                rawLine: line
            )
        }

        // Check message for sync events (in JSON format)
        let msg = stripANSI(entry.msg)

        // Capture error messages from rclone
        if entry.level == "error" {
            // Extract meaningful error message
            var errorMsg = msg

            // Clean up common rclone error prefixes
            if let range = errorMsg.range(of: "Bisync critical error: ") {
                errorMsg = String(errorMsg[range.upperBound...])
            } else if let range = errorMsg.range(of: "Bisync aborted. ") {
                errorMsg = String(errorMsg[range.upperBound...])
            }

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

        if msg.contains("Failed to bisync") {
            return ParsedLogEvent(
                timestamp: timestamp,
                type: .syncFailed(exitCode: 1, message: msg),
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
        let lowercased = message.lowercased()

        if lowercased.contains("starting bisync") || lowercased.contains("starting sync") {
            return .syncStarted
        }

        if lowercased.contains("completed successfully") || lowercased.contains("sync complete") {
            return .syncCompleted
        }

        if lowercased.contains("failed with exit code") {
            let pattern = #"exit code (\d+)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
               let codeRange = Range(match.range(at: 1), in: message),
               let code = Int(message[codeRange]) {
                return .syncFailed(exitCode: code, message: nil)
            }
            return .syncFailed(exitCode: -1, message: nil)
        }

        if lowercased.contains("drive not mounted") || lowercased.contains("not mounted") {
            return .driveNotMounted
        }

        if lowercased.contains("already running") {
            return .syncAlreadyRunning
        }

        return .unknown
    }
}

import Foundation

struct RcloneLogEntry: Codable {
    let level: String
    let msg: String
    let time: String
    let object: String?
    let objectType: String?
    let stats: RcloneStats?
    let source: String?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case level, msg, time, object, source, size
        case objectType = "objectType"
        case stats
    }
}

struct RcloneStats: Codable {
    let bytes: Int?
    let checks: Int?
    let deletedDirs: Int?
    let deletes: Int?
    let elapsedTime: Double?
    let errors: Int?
    let eta: Int?
    let fatalError: Bool?
    let renames: Int?
    let retryError: Bool?
    let speed: Double?
    let totalBytes: Int?
    let totalChecks: Int?
    let totalTransfers: Int?
    let transferTime: Double?
    let transfers: Int?
}

extension RcloneLogEntry {
    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: time) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: time)
    }

    var fileChange: FileChange? {
        // First, try with the object field (standard rclone format)
        if let objectPath = object, !objectPath.isEmpty {
            if let operation = parseOperation(from: msg) {
                return FileChange(
                    timestamp: date ?? Date(),
                    path: objectPath,
                    operation: operation
                )
            }
        }

        // Fall back to parsing bisync-style messages
        return parseBisyncFileChange(from: msg)
    }

    /// Parse bisync-style messages like:
    /// - "- Path1    File was deleted          - KAIJU/file.mp4"
    /// - "- Path2    File is new               - folder/newfile.txt"
    private func parseBisyncFileChange(from message: String) -> FileChange? {
        let pattern = #"- Path[12]\s+(.+?)\s+-\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let opRange = Range(match.range(at: 1), in: message),
              let pathRange = Range(match.range(at: 2), in: message) else {
            return nil
        }

        let opText = String(message[opRange]).lowercased()
        let filePath = String(message[pathRange])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        let operation: FileChange.Operation?
        if opText.contains("deleted") { operation = .deleted }
        else if opText.contains("new") { operation = .copied }
        else if opText.contains("changed") || opText.contains("newer") || opText.contains("older") { operation = .updated }
        else { return nil }

        return FileChange(timestamp: date ?? Date(), path: filePath, operation: operation!)
    }

    private func parseOperation(from message: String) -> FileChange.Operation? {
        let lowercased = message.lowercased()

        if lowercased.contains("copied") || lowercased.contains("copy") {
            if lowercased.contains("new") {
                return .copied
            }
            return .updated
        }
        if lowercased.contains("deleted") || lowercased.contains("delete") {
            return .deleted
        }
        if lowercased.contains("renamed") || lowercased.contains("rename") || lowercased.contains("moved") {
            return .renamed
        }
        if lowercased.contains("updated") || lowercased.contains("update") {
            return .updated
        }

        return nil
    }
}

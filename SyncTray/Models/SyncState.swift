import SwiftUI

struct SyncProgress: Equatable {
    let bytesTransferred: Int64
    let totalBytes: Int64
    let eta: Int?          // seconds
    let speed: Double?     // bytes/sec
    let transfersDone: Int
    let totalTransfers: Int

    var percentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes) * 100
    }

    var formattedProgress: String {
        let transferred = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let pct = Int(percentage)

        if let eta = eta, eta > 0 {
            let etaStr = formatETA(eta)
            return "Syncing: \(transferred) / \(total) (\(pct)%) - ETA \(etaStr)"
        }
        return "Syncing: \(transferred) / \(total) (\(pct)%)"
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
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

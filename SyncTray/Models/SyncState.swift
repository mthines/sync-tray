import SwiftUI

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

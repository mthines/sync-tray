import SwiftUI

struct RecentChangesView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Changes")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)

            if syncManager.recentChanges.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(syncManager.recentChanges) { change in
                            FileChangeRow(change: change)
                                .onTapGesture {
                                    syncManager.openFileInFinder(change)
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 300)
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("No recent changes")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 20)
            Spacer()
        }
    }
}

struct FileChangeRow: View {
    let change: FileChange
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: change.operation.icon)
                .foregroundColor(change.operation.color)
                .font(.system(size: 12))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(change.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(change.directory)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            Text(change.timestamp, formatter: timeFormatter)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHovered ? Color.primary.opacity(0.1) : Color.primary.opacity(0.03))
        .cornerRadius(4)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Click to reveal in Finder")
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }
}

#Preview {
    RecentChangesView()
        .environmentObject(SyncManager())
        .frame(width: 320)
}

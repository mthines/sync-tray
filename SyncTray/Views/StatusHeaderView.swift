import SwiftUI

struct StatusHeaderView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .font(.system(size: 28))
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                if syncManager.currentState == .syncing, let progress = syncManager.syncProgress {
                    // Line 1: Bytes progress with ETA
                    Text(progress.formattedTransferLine)
                        .font(.headline)
                        .lineLimit(1)

                    // Line 2: File counts (compact)
                    HStack(spacing: 8) {
                        if progress.totalTransfers > 0 {
                            Text("\(progress.transfersDone)/\(progress.totalTransfers) files")
                        }
                        if progress.totalChecks > 0 {
                            Text("\(progress.checksDone)/\(progress.totalChecks) checks")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else {
                    Text(syncManager.currentState.statusText)
                        .font(.headline)

                    if let lastSync = syncManager.lastSyncTime {
                        Text("Last sync: \(lastSync, formatter: relativeDateFormatter)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No recent sync")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if syncManager.currentState == .syncing {
            if #available(macOS 15.0, *) {
                Image(systemName: syncManager.currentState.iconName)
                    .foregroundColor(syncManager.currentState.iconColor)
                    .symbolEffect(.rotate, options: .repeating)
            } else if #available(macOS 14.0, *) {
                Image(systemName: syncManager.currentState.iconName)
                    .foregroundColor(syncManager.currentState.iconColor)
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Image(systemName: syncManager.currentState.iconName)
                    .foregroundColor(syncManager.currentState.iconColor)
            }
        } else {
            Image(systemName: syncManager.currentState.iconName)
                .foregroundColor(syncManager.currentState.iconColor)
        }
    }

    private var relativeDateFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }
}

#Preview {
    StatusHeaderView()
        .environmentObject(SyncManager())
        .padding()
}

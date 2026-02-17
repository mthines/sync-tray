import SwiftUI

/// Detailed sync progress view showing transfer stats, file counts, and per-file progress
struct SyncProgressDetailView: View {
    let progress: SyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Overall transfer progress with progress bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Transferred:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(progress.formattedTransferLine)
                        .font(.caption.monospaced())
                }

                ProgressView(value: progress.percentage, total: 100)
                    .progressViewStyle(.linear)
            }

            // Checks line (if applicable)
            if let checksLine = progress.formattedChecksLine {
                HStack {
                    Text("Checks:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(checksLine)
                        .font(.caption.monospaced())
                }
            }

            // Transfers count line (file count)
            if let transfersLine = progress.formattedTransfersLine {
                HStack {
                    Text("Files:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(transfersLine)
                        .font(.caption.monospaced())
                }
            }

            // Elapsed time
            if let elapsedTime = progress.formattedElapsedTime {
                HStack {
                    Text("Elapsed:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(elapsedTime)
                        .font(.caption.monospaced())
                }
            }

            // Per-file transfer details (if any active transfers)
            if !progress.transferringFiles.isEmpty {
                Divider()
                    .padding(.vertical, 2)

                Text("Transferring:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                ForEach(progress.transferringFiles.prefix(4)) { file in
                    TransferringFileRow(file: file)
                }

                if progress.transferringFiles.count > 4 {
                    Text("  + \(progress.transferringFiles.count - 4) more...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(6)
    }
}

/// Row showing individual file transfer progress
struct TransferringFileRow: View {
    let file: TransferringFile

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("*")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.truncatedName(maxLength: 45))
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(file.formattedProgress)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact progress view for the menu bar popup
struct CompactSyncProgressView: View {
    let progress: SyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
        }
    }
}

#Preview("Detail View") {
    SyncProgressDetailView(
        progress: SyncProgress(
            bytesTransferred: 19_894_000_000,
            totalBytes: 253_685_000_000,
            eta: 6733,
            speed: 35_554_000,
            transfersDone: 116,
            totalTransfers: 10128,
            checksDone: 3,
            totalChecks: 3,
            elapsedTime: 599.9,
            errors: 0,
            transferringFiles: [
                TransferringFile(
                    name: "KAIJU/Media/Concerts/2025/Full Set Stage Side.mp4",
                    size: 11_217_000_000,
                    bytes: 4_935_000_000,
                    percentage: 44,
                    speed: 4_292_000,
                    speedAvg: nil,
                    eta: 1491
                ),
                TransferringFile(
                    name: "KAIJU/Media/Concerts/2025/VID20250313201738.mp4",
                    size: 10_801_000_000,
                    bytes: 5_292_000_000,
                    percentage: 49,
                    speed: 21_012_000,
                    speedAvg: nil,
                    eta: 263
                )
            ],
            listedCount: nil
        )
    )
    .frame(width: 350)
    .padding()
}

#Preview("Compact View") {
    CompactSyncProgressView(
        progress: SyncProgress(
            bytesTransferred: 19_894_000_000,
            totalBytes: 253_685_000_000,
            eta: 6733,
            speed: 35_554_000,
            transfersDone: 116,
            totalTransfers: 10128,
            checksDone: 3,
            totalChecks: 3,
            elapsedTime: 599.9,
            errors: 0,
            transferringFiles: [],
            listedCount: nil
        )
    )
    .padding()
}

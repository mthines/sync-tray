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

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(progress.transferringFiles.prefix(20)) { file in
                            TransferringFileRow(file: file)
                        }
                    }
                }
                .frame(maxHeight: 150)
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
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Progress percentage circle
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                    .frame(width: 16, height: 16)

                Circle()
                    .trim(from: 0, to: CGFloat(file.percentage ?? 0) / 100)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                // Filename
                Text(file.fileName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Directory path + size info
                HStack(spacing: 4) {
                    Text(file.directory)
                        .lineLimit(1)
                        .truncationMode(.head)

                    if let bytes = file.bytes, let size = file.size, size > 0 {
                        Text("•")
                        let downloadedStr = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                        let totalStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                        Text("\(downloadedStr) / \(totalStr)")
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }

            Spacer()

            // Progress info (percentage, speed)
            VStack(alignment: .trailing, spacing: 1) {
                if let pct = file.percentage {
                    Text("\(pct)%")
                        .font(.system(size: 10, weight: .medium))
                }
                if let spd = file.speed ?? file.speedAvg, spd > 0 {
                    let speedStr = ByteCountFormatter.string(fromByteCount: Int64(spd), countStyle: .file)
                    Text("\(speedStr)/s")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHovered ? Color.primary.opacity(0.1) : Color.clear)
        .cornerRadius(4)
        .onHover { hovering in
            isHovered = hovering
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

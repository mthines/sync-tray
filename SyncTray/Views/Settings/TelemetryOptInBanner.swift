import SwiftUI

/// A dismissable banner encouraging users to opt in to anonymous telemetry.
/// Shown at the top of the profile detail view until the user either opts in or dismisses it.
struct TelemetryOptInBanner: View {
    @State private var telemetryEnabled = SyncTraySettings.telemetryEnabled
    @State private var dismissed = SyncTraySettings.telemetryBannerDismissed

    /// Whether the banner should be visible
    var isVisible: Bool {
        !telemetryEnabled && !dismissed
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis.ascending")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Help improve SyncTray")
                        .font(.subheadline.weight(.medium))
                    Text("Share anonymous usage data to help development. No file names or sensitive data — just usage patterns. Completely optional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button("Enable") {
                    SyncTraySettings.telemetryEnabled = true
                    TelemetryService.shared.configure()
                    withAnimation(.easeOut(duration: 0.2)) {
                        telemetryEnabled = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    SyncTraySettings.telemetryBannerDismissed = true
                    withAnimation(.easeOut(duration: 0.2)) {
                        dismissed = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.blue.opacity(0.2), lineWidth: 0.5)
                    )
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

#Preview {
    VStack {
        TelemetryOptInBanner()
        Spacer()
    }
    .padding()
    .frame(width: 500, height: 300)
}

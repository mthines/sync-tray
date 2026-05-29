import SwiftUI

/// A dismissable banner encouraging users to opt in to anonymous telemetry.
/// Shown at the top of the profile detail view until the user either opts in or dismisses it.
/// Uses a consent version so the banner can be re-surfaced by bumping
/// `SyncTraySettings.currentTelemetryConsentVersion`.
struct TelemetryOptInBanner: View {
    @State private var telemetryEnabled = SyncTraySettings.telemetryEnabled
    @State private var dismissed = SyncTraySettings.telemetryBannerDismissed
    @State private var showingTelemetryDetails: Bool = false

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
                    Text("Help shape SyncTray")
                        .font(.subheadline.weight(.medium))
                    Text("Anonymous usage data — sync results, error types, feature usage. No file names or credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Learn more") {
                        showingTelemetryDetails = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                Spacer()

                Button("Enable") {
                    SyncTraySettings.telemetryEnabled = true
                    SyncTraySettings.telemetryBannerDismissedVersion = SyncTraySettings.currentTelemetryConsentVersion
                    TelemetryService.shared.configure()
                    withAnimation(.easeOut(duration: 0.2)) {
                        telemetryEnabled = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Not now") {
                    SyncTraySettings.telemetryBannerDismissedVersion = SyncTraySettings.currentTelemetryConsentVersion
                    withAnimation(.easeOut(duration: 0.2)) {
                        dismissed = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
            .sheet(isPresented: $showingTelemetryDetails) {
                TelemetryDetailsSheet()
            }
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

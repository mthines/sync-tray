import SwiftUI

/// Full disclosure sheet for SyncTray's anonymous telemetry.
/// Reachable from the first-profile wizard step, the opt-in banner, and App Settings.
struct TelemetryDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Privacy & Telemetry")
                    .font(.title2.bold())

                section(
                    title: "What we collect",
                    items: [
                        "Whether a sync succeeded or failed, and how long it took",
                        "Error categories — e.g. \"network error\", \"timeout\" (never the raw message)",
                        "Which sync mode you use — two-way, one-way, or stream",
                        "How often syncs are triggered and whether they were skipped",
                        "App launch count and number of active profiles",
                    ]
                )

                section(
                    title: "What we never collect",
                    items: [
                        "File names, folder names, or file contents",
                        "Remote names, hostnames, server addresses, or credentials",
                        "Your IP address",
                        "Any data that could identify you personally",
                    ]
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("How we identify your installation")
                        .font(.headline)
                    Text("Two anonymous identifiers are included with every event:")
                        .foregroundStyle(.secondary)
                    Text("• A random ID generated when you first install SyncTray. It changes if you reinstall.")
                        .foregroundStyle(.secondary)
                    Text("• A one-way hash of your Mac's hardware ID. It survives reinstalls so we can tell when the same machine is reporting — but it cannot be reversed to identify you or your machine.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Where it goes")
                        .font(.headline)
                    Text("Telemetry is sent to Dash0 — an observability platform. The endpoint is configurable via environment variables if you run your own collector.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("How to turn it off")
                        .font(.headline)
                    Text("Open App Settings (gear icon in the sidebar) and toggle off \"Share anonymous usage data\". Takes effect immediately.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(width: 480, height: 520)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func section(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

#Preview {
    TelemetryDetailsSheet()
}

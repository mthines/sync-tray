import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject var syncManager: SyncManager

    @State private var debugLogging = SyncTraySettings.debugLoggingEnabled
    @State private var telemetryEnabled = SyncTraySettings.telemetryEnabled
    @State private var autoFixSyncIssues = SyncTraySettings.autoFixSyncIssues
    @State private var showingTelemetryDetails: Bool = false
    @State private var rcloneVersion: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                GroupBox("General") {
                    VStack(alignment: .leading, spacing: 12) {
                        launchAtLoginToggle
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Privacy") {
                    VStack(alignment: .leading, spacing: 12) {
                        telemetryToggle
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Sync") {
                    VStack(alignment: .leading, spacing: 12) {
                        autoFixToggle
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Advanced") {
                    VStack(alignment: .leading, spacing: 12) {
                        debugLoggingToggle
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                helpFeedbackSection

                aboutSection
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            rcloneVersion = await detectRcloneVersion()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("App Settings")
                    .font(.title2.bold())
                Text("Global settings that apply to all profiles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - General

    private var launchAtLoginToggle: some View {
        Toggle(isOn: Binding(
            get: { syncManager.isLoginItemEnabled },
            set: { enabled in
                if enabled {
                    syncManager.enableLoginItem()
                } else {
                    syncManager.disableLoginItem()
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch at Login")
                Text("Automatically start SyncTray when you log in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Privacy

    private var telemetryToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $telemetryEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share anonymous usage data")
                    Text("Sync results, error types, and feature usage. No file names, paths, or credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: telemetryEnabled) { newValue in
                SyncTraySettings.telemetryEnabled = newValue
                if newValue {
                    TelemetryService.shared.configure()
                }
            }

            Button("Learn more") {
                showingTelemetryDetails = true
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.leading, 20) // Align with toggle label
        }
        .sheet(isPresented: $showingTelemetryDetails) {
            TelemetryDetailsSheet()
        }
    }

    // MARK: - Sync

    private var autoFixToggle: some View {
        Toggle(isOn: $autoFixSyncIssues) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatically recover from sync conflicts")
                Text("Runs --resync when bisync detects out-of-sync state. Recommended.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: autoFixSyncIssues) { newValue in
            SyncTraySettings.autoFixSyncIssues = newValue
        }
    }

    // MARK: - Advanced

    private var debugLoggingToggle: some View {
        Toggle(isOn: $debugLogging) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Debug Logging")
                Text("Enable verbose logging for file watchers and sync triggers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: debugLogging) { newValue in
            SyncTraySettings.debugLoggingEnabled = newValue
        }
    }

    // MARK: - Help & Feedback

    private var helpFeedbackSection: some View {
        GroupBox("Help & Feedback") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Join the SyncTray community on Discord")
                            .font(.body)
                        Text("Ask for help, share feedback, or suggest features.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("Open Discord", destination: URL(string: "https://discord.gg/KBp8kb3EwP")!)
                            .font(.caption)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        GroupBox("About") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("Version", value: appVersion)
                infoRow("rclone", value: rcloneVersion ?? "Detecting...")
                infoRow("Config", value: "~/.config/synctray/")
                infoRow("Logs", value: "~/.local/log/")
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .monospaced()
        }
        .font(.caption)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func detectRcloneVersion() async -> String {
        // RcloneConfigService.getRcloneVersion() resolves rclone via a list of
        // candidate absolute paths (/opt/homebrew/bin, /usr/local/bin, /usr/bin)
        // so it works correctly in macOS GUI apps that inherit a minimal PATH.
        await Task.detached(priority: .utility) {
            guard let raw = RcloneConfigService.shared.getRcloneVersion() else {
                return "Not found"
            }
            // raw is the first line from `rclone version`, e.g. "rclone v1.65.0"
            let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "rclone ", with: "")
            return version.isEmpty ? "Not found" : version
        }.value
    }
}

#Preview {
    AppSettingsView()
        .environmentObject(SyncManager())
        .frame(width: 500, height: 650)
}

import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject var syncManager: SyncManager

    @State private var debugLogging = SyncTraySettings.debugLoggingEnabled
    @State private var telemetryEnabled = SyncTraySettings.telemetryEnabled
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

                GroupBox("Advanced") {
                    VStack(alignment: .leading, spacing: 12) {
                        debugLoggingToggle
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

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
        Toggle(isOn: $telemetryEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Anonymous Usage Data")
                Text("Help improve SyncTray by sharing anonymous crash and usage statistics")
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
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["rclone", "version", "--check"]
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // Extract version from first line like "rclone v1.65.0"
                    let firstLine = output.components(separatedBy: "\n").first ?? output
                    let version = firstLine.replacingOccurrences(of: "rclone ", with: "")
                    continuation.resume(returning: version.isEmpty ? "Not found" : version)
                } catch {
                    continuation.resume(returning: "Not found")
                }
            }
        }
    }
}

#Preview {
    AppSettingsView()
        .environmentObject(SyncManager())
        .frame(width: 500, height: 650)
}

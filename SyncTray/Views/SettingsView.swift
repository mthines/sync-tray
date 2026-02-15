import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var syncManager: SyncManager

    @State private var logFilePath: String = SyncTraySettings.logFilePath
    @State private var syncScriptPath: String = SyncTraySettings.syncScriptPath
    @State private var syncDirectoryPath: String = SyncTraySettings.syncDirectoryPath
    @State private var drivePathToMonitor: String = SyncTraySettings.drivePathToMonitor

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    // Log File Path
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Log File Path")
                            .font(.headline)
                        Text("Path to the rclone sync log file (supports JSON logs with --use-json-log)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            TextField("~/.local/log/rclone-sync.log", text: $logFilePath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                browseForFile(title: "Select Log File", extensions: ["log", "txt"]) { path in
                                    logFilePath = path
                                }
                            }
                        }
                    }

                    Divider()

                    // Sync Script Path
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sync Script Path")
                            .font(.headline)
                        Text("Path to your rclone sync script (for manual sync trigger)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            TextField("~/.local/bin/rclone-sync.sh", text: $syncScriptPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                browseForFile(title: "Select Sync Script", extensions: ["sh"]) { path in
                                    syncScriptPath = path
                                }
                            }
                        }
                    }

                    Divider()

                    // Sync Directory Path
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sync Directory")
                            .font(.headline)
                        Text("Local directory being synced (for 'Open Directory' and file navigation)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            TextField("/Volumes/MyDrive/Sync", text: $syncDirectoryPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                browseForFolder(title: "Select Sync Directory") { path in
                                    syncDirectoryPath = path
                                }
                            }
                        }
                    }

                    Divider()

                    // Drive Path to Monitor
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drive Path to Monitor")
                            .font(.headline)
                        Text("External drive path to monitor for mount/unmount (optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            TextField("/Volumes/MyDrive", text: $drivePathToMonitor)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                browseForFolder(title: "Select Drive to Monitor") { path in
                                    drivePathToMonitor = path
                                }
                            }
                        }
                    }
                }
                .padding()
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        resetToDefaults()
                    }
                    Button("Save") {
                        saveSettings()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 480)
        .onAppear {
            loadSettings()
        }
    }

    private func loadSettings() {
        logFilePath = SyncTraySettings.logFilePath
        syncScriptPath = SyncTraySettings.syncScriptPath
        syncDirectoryPath = SyncTraySettings.syncDirectoryPath
        drivePathToMonitor = SyncTraySettings.drivePathToMonitor
    }

    private func saveSettings() {
        SyncTraySettings.logFilePath = logFilePath
        SyncTraySettings.syncScriptPath = syncScriptPath
        SyncTraySettings.syncDirectoryPath = syncDirectoryPath
        SyncTraySettings.drivePathToMonitor = drivePathToMonitor
        SyncTraySettings.hasCompletedSetup = true

        syncManager.refreshSettings()
    }

    private func resetToDefaults() {
        logFilePath = SyncTraySettings.defaultLogFilePath
        syncScriptPath = SyncTraySettings.defaultSyncScriptPath
        syncDirectoryPath = ""
        drivePathToMonitor = ""
    }

    private func browseForFile(title: String, extensions: [String], completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = extensions.compactMap { ext in
            UTType(filenameExtension: ext)
        }

        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }

    private func browseForFolder(title: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SyncManager())
}

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.dismiss) private var dismiss

    // Sync Configuration
    @State private var rcloneRemote: String = SyncTraySettings.rcloneRemote
    @State private var localSyncPath: String = SyncTraySettings.localSyncPath
    @State private var isExternalDrive: Bool = !SyncTraySettings.drivePathToMonitor.isEmpty
    @State private var syncIntervalMinutes: Int = SyncTraySettings.syncIntervalMinutes
    @State private var additionalRcloneFlags: String = SyncTraySettings.additionalRcloneFlags

    // Manual Configuration (advanced)
    @State private var logFilePath: String = SyncTraySettings.logFilePath
    @State private var syncScriptPath: String = SyncTraySettings.syncScriptPath

    // UI State
    @State private var showAdvanced: Bool = false
    @State private var isInstalling: Bool = false
    @State private var installError: String?
    @State private var showingUninstallConfirm: Bool = false
    @State private var availableRemotes: [String] = []
    @State private var isLoadingRemotes: Bool = false
    @State private var remotesError: String?
    @State private var availableFolders: [String] = []
    @State private var isLoadingFolders: Bool = false
    @State private var foldersError: String?

    private let setupService = SyncSetupService.shared

    // MARK: - Computed Properties

    /// Computed drive path based on local sync path (extracts /Volumes/DriveName)
    private var computedDrivePath: String {
        guard isExternalDrive, localSyncPath.hasPrefix("/Volumes/") else { return "" }
        let components = localSyncPath.split(separator: "/")
        if components.count >= 2 {
            return "/Volumes/\(components[1])"
        }
        return ""
    }

    private var hasChanges: Bool {
        rcloneRemote != SyncTraySettings.rcloneRemote ||
        localSyncPath != SyncTraySettings.localSyncPath ||
        computedDrivePath != SyncTraySettings.drivePathToMonitor ||
        syncIntervalMinutes != SyncTraySettings.syncIntervalMinutes ||
        additionalRcloneFlags != SyncTraySettings.additionalRcloneFlags ||
        logFilePath != SyncTraySettings.logFilePath ||
        syncScriptPath != SyncTraySettings.syncScriptPath
    }

    private var canInstall: Bool {
        !rcloneRemote.isEmpty && !localSyncPath.isEmpty && !isRemoteFolderEmpty
    }

    private var isInstalled: Bool {
        setupService.isInstalled()
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section 1: Sync Configuration
                sectionHeader("Sync Configuration", icon: "arrow.triangle.2.circlepath")
                syncConfigurationSection

                Divider().padding(.vertical, 8)

                // Section 2: Schedule
                sectionHeader("Schedule", icon: "clock")
                scheduleSection

                Divider().padding(.vertical, 8)

                // Section 3: Scheduled Sync Management
                sectionHeader("Automatic Sync", icon: "calendar.badge.clock")
                scheduledSyncSection

                Divider().padding(.vertical, 8)

                // Section 4: Advanced / Manual Configuration
                advancedSection

                // Action Buttons
                Divider().padding(.vertical, 8)
                actionButtons
            }
            .padding(20)
        }
        .frame(width: 550, height: 650)
        .onAppear {
            loadSettings()
            loadRcloneRemotes()
        }
        .alert("Uninstall Scheduled Sync?", isPresented: $showingUninstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { uninstallSync() }
        } message: {
            Text("This will remove the sync script and stop automatic syncing.")
        }
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundColor(.primary)
    }

    /// Extract the folder name from the remote path
    private var remoteFolderPath: String {
        rcloneRemote.components(separatedBy: ":").dropFirst().joined(separator: ":")
    }

    /// Check if remote has a folder path specified
    private var isRemoteFolderEmpty: Bool {
        let remote = rcloneRemote.components(separatedBy: ":").first ?? ""
        return !remote.isEmpty && remoteFolderPath.isEmpty
    }

    // MARK: - Sync Configuration Section

    private var syncConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Rclone Remote
            VStack(alignment: .leading, spacing: 4) {
                Text("Rclone Remote")
                    .font(.subheadline.weight(.medium))
                Text("Select a remote and enter the folder path to sync")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    // Remote picker
                    if isLoadingRemotes {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 150)
                    } else if !availableRemotes.isEmpty {
                        Picker("", selection: Binding(
                            get: { rcloneRemote.components(separatedBy: ":").first ?? "" },
                            set: { newRemote in
                                let folder = rcloneRemote.components(separatedBy: ":").dropFirst().joined(separator: ":")
                                rcloneRemote = folder.isEmpty ? "\(newRemote):" : "\(newRemote):\(folder)"
                            }
                        )) {
                            Text("Select...").tag("")
                            ForEach(availableRemotes, id: \.self) { remote in
                                Text(remote).tag(remote)
                            }
                        }
                        .frame(width: 150)

                        Text(":")
                            .foregroundColor(.secondary)

                        // Folder picker or text field
                        if isLoadingFolders {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if !availableFolders.isEmpty {
                            Picker("", selection: Binding(
                                get: { remoteFolderPath },
                                set: { newFolder in
                                    let remote = rcloneRemote.components(separatedBy: ":").first ?? ""
                                    rcloneRemote = "\(remote):\(newFolder)"
                                }
                            )) {
                                Text("Select folder...").tag("")
                                ForEach(availableFolders, id: \.self) { folder in
                                    Text(folder).tag(folder)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            TextField("Folder on remote", text: Binding(
                                get: { remoteFolderPath },
                                set: { newFolder in
                                    let remote = rcloneRemote.components(separatedBy: ":").first ?? ""
                                    rcloneRemote = remote.isEmpty ? newFolder : "\(remote):\(newFolder)"
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        // Refresh folders button
                        Button(action: loadRemoteFolders) {
                            if isLoadingFolders {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Image(systemName: "folder.badge.questionmark")
                            }
                        }
                        .help("Load folders from remote")
                        .disabled(rcloneRemote.components(separatedBy: ":").first?.isEmpty ?? true)
                    } else {
                        TextField("remote:folder", text: $rcloneRemote)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(action: loadRcloneRemotes) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh remotes list")
                }

                // Warning if folder path is empty
                if isRemoteFolderEmpty && availableFolders.isEmpty {
                    Label("Click the folder icon to browse, or type the folder name", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Folder validation error
                if let error = foldersError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if let error = remotesError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if availableRemotes.isEmpty && !isLoadingRemotes {
                    Text("Run `rclone listremotes` in Terminal to see configured remotes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                validationMessage(for: rcloneRemoteValidation)
            }

            // Local Sync Path
            VStack(alignment: .leading, spacing: 4) {
                Text("Local Folder")
                    .font(.subheadline.weight(.medium))
                Text("The folder on your Mac that will be synced with the remote")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    TextField("/Volumes/MyDrive/MyFolder", text: $localSyncPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        browseForFolder(title: "Select Local Sync Directory") { path in
                            localSyncPath = path
                        }
                    }
                }
                validationMessage(for: localSyncPathValidation)

                // External drive toggle - only show if path is on /Volumes/
                if localSyncPath.hasPrefix("/Volumes/") {
                    Toggle(isOn: $isExternalDrive) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("External drive")
                                .font(.subheadline)
                            Text("Skip sync when drive is disconnected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.top, 8)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Schedule Section

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sync Interval")
                    .font(.subheadline.weight(.medium))
                Text("How often to run the sync (in minutes)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Picker("", selection: $syncIntervalMinutes) {
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Scheduled Sync Section

    private var scheduledSyncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status
            HStack {
                if isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Label("Not Installed", systemImage: "circle.dashed")
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Info about generated files
            if isInstalled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Generated files:")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    Text("• Script: ~/.local/bin/synctray-sync.sh")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("• Schedule: ~/Library/LaunchAgents/com.synctray.sync.plist")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("• Log: ~/.local/log/synctray-sync.log")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Error message
            if let error = installError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Buttons
            HStack {
                if isInstalled {
                    Button(action: { showingUninstallConfirm = true }) {
                        Label("Uninstall", systemImage: "trash")
                    }

                    Button(action: reinstallSync) {
                        Label("Reinstall", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canInstall || isInstalling)
                } else {
                    Button(action: {
                        print("Install button pressed - canInstall: \(canInstall), rcloneRemote: '\(rcloneRemote)', localSyncPath: '\(localSyncPath)'")
                        installSync()
                    }) {
                        if isInstalling {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                            Text("Installing...")
                        } else {
                            Label("Install Scheduled Sync", systemImage: "plus.circle")
                        }
                    }
                    .disabled(!canInstall || isInstalling)
                    .buttonStyle(.borderedProminent)
                    .opacity(canInstall ? 1.0 : 0.5)
                }
                Spacer()
            }

            // Show why install is disabled
            if !canInstall && !isInstalled {
                VStack(alignment: .leading, spacing: 2) {
                    if rcloneRemote.components(separatedBy: ":").first?.isEmpty ?? true {
                        Label("Select an rclone remote", systemImage: "exclamationmark.circle")
                    } else if isRemoteFolderEmpty {
                        Label("Enter the folder path on the remote", systemImage: "exclamationmark.circle")
                    }
                    if localSyncPath.isEmpty {
                        Label("Select a local folder", systemImage: "exclamationmark.circle")
                    }
                }
                .font(.caption)
                .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { withAnimation { showAdvanced.toggle() } }) {
                HStack {
                    Label("Advanced Options", systemImage: "gearshape.2")
                        .font(.headline)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 12) {
                    // Additional rclone flags
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Additional rclone Flags")
                            .font(.subheadline.weight(.medium))
                        Text("Extra flags to pass to rclone bisync command")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("--dry-run --verbose", text: $additionalRcloneFlags)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    Text("Manual Configuration")
                        .font(.subheadline.weight(.medium))
                    Text("Override auto-generated paths (for existing setups)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Log File Path
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Log File Path")
                            .font(.caption.weight(.medium))
                        HStack {
                            TextField("~/.local/log/rclone-sync.log", text: $logFilePath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                browseForFile(title: "Select Log File", extensions: ["log", "txt"]) { path in
                                    logFilePath = path
                                }
                            }
                        }
                        validationMessage(for: logFileValidation)
                    }

                    // Sync Script Path
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sync Script Path")
                            .font(.caption.weight(.medium))
                        HStack {
                            TextField("~/.local/bin/rclone-sync.sh", text: $syncScriptPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                browseForFile(title: "Select Sync Script", extensions: ["sh"]) { path in
                                    syncScriptPath = path
                                }
                            }
                        }
                        validationMessage(for: syncScriptValidation)
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            if hasChanges {
                Text("You have unsaved changes")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Spacer()

            Button("Cancel") {
                dismiss()
            }

            Button("Save") {
                saveSettings()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Validation

    private enum ValidationStatus {
        case valid, warning(String), error(String), none

        var message: String? {
            switch self {
            case .warning(let msg), .error(let msg): return msg
            default: return nil
            }
        }

        var color: Color {
            switch self {
            case .valid: return .green
            case .warning: return .orange
            case .error: return .red
            case .none: return .clear
            }
        }

        var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    private var rcloneRemoteValidation: ValidationStatus {
        if rcloneRemote.isEmpty { return .none }
        if !rcloneRemote.contains(":") {
            return .warning("Should be in format 'remote:path' (e.g., mydrive:Backup)")
        }
        return .valid
    }

    private var localSyncPathValidation: ValidationStatus {
        if localSyncPath.isEmpty { return .none }
        let expanded = (localSyncPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
            return isDir.boolValue ? .valid : .error("Path is not a directory")
        }
        if expanded.hasPrefix("/Volumes/") {
            return .warning("Directory not found - drive may not be mounted")
        }
        return .error("Directory does not exist")
    }

    private var logFileValidation: ValidationStatus {
        if logFilePath.isEmpty { return .error("Log file path is required") }
        let expanded = (logFilePath as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return .valid }
        let parent = (expanded as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: parent) {
            return .warning("Log file will be created when sync runs")
        }
        return .error("Parent directory does not exist")
    }

    private var syncScriptValidation: ValidationStatus {
        if syncScriptPath.isEmpty { return .warning("No sync script - 'Sync Now' disabled") }
        let expanded = (syncScriptPath as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: expanded) {
            return .error("Script not found")
        }
        if !FileManager.default.isExecutableFile(atPath: expanded) {
            return .error("Script not executable (chmod +x)")
        }
        return .valid
    }

    @ViewBuilder
    private func validationMessage(for status: ValidationStatus) -> some View {
        if let message = status.message {
            Label(message, systemImage: status.isError ? "xmark.circle" : "info.circle")
                .font(.caption)
                .foregroundColor(status.color)
        }
    }

    // MARK: - Actions

    private func loadSettings() {
        rcloneRemote = SyncTraySettings.rcloneRemote
        localSyncPath = SyncTraySettings.localSyncPath
        isExternalDrive = !SyncTraySettings.drivePathToMonitor.isEmpty
        syncIntervalMinutes = SyncTraySettings.syncIntervalMinutes
        additionalRcloneFlags = SyncTraySettings.additionalRcloneFlags
        logFilePath = SyncTraySettings.logFilePath
        syncScriptPath = SyncTraySettings.syncScriptPath
    }

    private func loadRcloneRemotes() {
        isLoadingRemotes = true
        remotesError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            // Try common rclone paths
            let rclonePaths = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
            var rclonePath: String?

            for path in rclonePaths {
                if FileManager.default.fileExists(atPath: path) {
                    rclonePath = path
                    break
                }
            }

            guard let path = rclonePath else {
                DispatchQueue.main.async {
                    isLoadingRemotes = false
                    remotesError = "rclone not found. Install with: brew install rclone"
                }
                return
            }

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["listremotes"]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                let remotes = output
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { $0.hasSuffix(":") ? String($0.dropLast()) : $0 }

                DispatchQueue.main.async {
                    availableRemotes = remotes
                    isLoadingRemotes = false
                    if remotes.isEmpty {
                        remotesError = "No remotes configured. Run: rclone config"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isLoadingRemotes = false
                    remotesError = "Failed to list remotes: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadRemoteFolders() {
        let remoteName = rcloneRemote.components(separatedBy: ":").first ?? ""
        guard !remoteName.isEmpty else { return }

        isLoadingFolders = true
        foldersError = nil
        availableFolders = []

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            let rclonePaths = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
            var rclonePath: String?

            for path in rclonePaths {
                if FileManager.default.fileExists(atPath: path) {
                    rclonePath = path
                    break
                }
            }

            guard let path = rclonePath else {
                DispatchQueue.main.async {
                    isLoadingFolders = false
                    foldersError = "rclone not found"
                }
                return
            }

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["lsd", "\(remoteName):"]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                // Parse lsd output - format: "          -1 2024-01-01 00:00:00        -1 FolderName"
                let folders = output
                    .components(separatedBy: .newlines)
                    .compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return nil }
                        // The folder name is the last component after the date/time
                        let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        return components.last
                    }

                DispatchQueue.main.async {
                    availableFolders = folders.sorted()
                    isLoadingFolders = false
                    if folders.isEmpty {
                        foldersError = "No folders found on remote (or remote is empty)"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isLoadingFolders = false
                    foldersError = "Failed to list folders: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveSettings() {
        SyncTraySettings.rcloneRemote = rcloneRemote
        SyncTraySettings.localSyncPath = localSyncPath
        SyncTraySettings.drivePathToMonitor = computedDrivePath
        SyncTraySettings.syncIntervalMinutes = syncIntervalMinutes
        SyncTraySettings.additionalRcloneFlags = additionalRcloneFlags
        SyncTraySettings.logFilePath = logFilePath
        SyncTraySettings.syncScriptPath = syncScriptPath
        SyncTraySettings.syncDirectoryPath = localSyncPath
        SyncTraySettings.hasCompletedSetup = true

        syncManager.refreshSettings()
    }

    private func installSync() {
        print("installSync called")
        isInstalling = true
        installError = nil

        // Save sync configuration (but not script/log paths - those will be set by install)
        SyncTraySettings.rcloneRemote = rcloneRemote
        SyncTraySettings.localSyncPath = localSyncPath
        SyncTraySettings.drivePathToMonitor = computedDrivePath
        SyncTraySettings.syncIntervalMinutes = syncIntervalMinutes
        SyncTraySettings.additionalRcloneFlags = additionalRcloneFlags
        SyncTraySettings.syncDirectoryPath = localSyncPath

        print("Settings saved, starting install...")
        print("  rcloneRemote: \(SyncTraySettings.rcloneRemote)")
        print("  localSyncPath: \(SyncTraySettings.localSyncPath)")
        print("  drivePathToMonitor: \(SyncTraySettings.drivePathToMonitor)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try setupService.install()
                print("Install succeeded!")
                print("  syncScriptPath: \(SyncTraySettings.syncScriptPath)")
                print("  logFilePath: \(SyncTraySettings.logFilePath)")
                DispatchQueue.main.async {
                    isInstalling = false
                    // Update UI state with generated paths
                    logFilePath = SyncTraySettings.logFilePath
                    syncScriptPath = SyncTraySettings.syncScriptPath
                    // Refresh manager
                    syncManager.refreshSettings()
                }
            } catch {
                print("Install failed: \(error)")
                DispatchQueue.main.async {
                    isInstalling = false
                    installError = error.localizedDescription
                }
            }
        }
    }

    private func uninstallSync() {
        do {
            try setupService.uninstall()
            syncManager.refreshSettings()
        } catch {
            installError = error.localizedDescription
        }
    }

    private func reinstallSync() {
        do {
            try setupService.uninstall()
        } catch {
            // Ignore uninstall errors
        }
        installSync()
    }

    // MARK: - File Dialogs

    private func browseForFile(title: String, extensions: [String], completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }

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

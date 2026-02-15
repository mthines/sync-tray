import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProfileId: UUID?

    var body: some View {
        NavigationSplitView {
            ProfileListView(
                profileStore: syncManager.profileStore,
                selection: $selectedProfileId
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            if let profileId = selectedProfileId,
               let profile = syncManager.profileStore.profile(for: profileId) {
                ProfileDetailView(
                    profile: profile,
                    profileStore: syncManager.profileStore,
                    syncManager: syncManager
                )
                .id(profile.id)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Profile Selected")
                        .font(.title2)
                    Text("Select a profile from the sidebar or create a new one.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 700, height: 650)
        .onAppear {
            // Check if there's a pending profile selection from notification tap
            if let pendingId = AppDelegate.pendingProfileSelection {
                selectedProfileId = pendingId
                AppDelegate.pendingProfileSelection = nil
            } else if selectedProfileId == nil {
                // Select first profile if none selected
                selectedProfileId = syncManager.profileStore.profiles.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectProfile)) { notification in
            if let profileId = notification.userInfo?["profileId"] as? UUID {
                selectedProfileId = profileId
            }
        }
    }
}

// MARK: - Profile Detail View

struct ProfileDetailView: View {
    let profile: SyncProfile
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var syncManager: SyncManager

    // Editable fields (local state)
    @State private var name: String = ""
    @State private var rcloneRemote: String = ""
    @State private var remotePath: String = ""
    @State private var localSyncPath: String = ""
    @State private var isExternalDrive: Bool = false
    @State private var syncIntervalMinutes: Int = 15
    @State private var additionalRcloneFlags: String = ""

    // UI State
    @State private var showAdvanced: Bool = false
    @State private var isInstalling: Bool = false
    @State private var installError: String?
    @State private var showingUninstallConfirm: Bool = false
    @State private var availableRemotes: [String] = []
    @State private var isLoadingRemotes: Bool = false
    @State private var isRunningResync: Bool = false
    @State private var resyncOutput: String = ""
    @State private var showResyncOutput: Bool = false
    @State private var useTextInputForFolder: Bool = false
    @State private var remotesError: String?
    @State private var availableFolders: [String] = []
    @State private var isLoadingFolders: Bool = false
    @State private var foldersError: String?

    private let setupService = SyncSetupService.shared

    // MARK: - Computed Properties

    private var computedDrivePath: String {
        guard isExternalDrive, localSyncPath.hasPrefix("/Volumes/") else { return "" }
        let components = localSyncPath.split(separator: "/")
        if components.count >= 2 {
            return "/Volumes/\(components[1])"
        }
        return ""
    }

    private var hasChanges: Bool {
        name != profile.name ||
        rcloneRemote != profile.rcloneRemote ||
        remotePath != profile.remotePath ||
        localSyncPath != profile.localSyncPath ||
        computedDrivePath != profile.drivePathToMonitor ||
        syncIntervalMinutes != profile.syncIntervalMinutes ||
        additionalRcloneFlags != profile.additionalRcloneFlags
    }

    private var canInstall: Bool {
        !rcloneRemote.isEmpty && !localSyncPath.isEmpty && !remotePath.isEmpty
    }

    private var isInstalled: Bool {
        setupService.isInstalled(profile: profile)
    }

    /// Returns true if paths have changed and the new path combination needs initial sync
    private var pathsNeedInitialSync: Bool {
        // Check if paths have changed
        let pathsChanged = rcloneRemote != profile.rcloneRemote ||
                          remotePath != profile.remotePath ||
                          localSyncPath != profile.localSyncPath

        guard pathsChanged && canInstall else { return false }

        // Check if listings exist for the NEW path combination
        // Create a temporary profile with the new paths to check
        var tempProfile = profile
        tempProfile.rcloneRemote = rcloneRemote
        tempProfile.remotePath = remotePath
        tempProfile.localSyncPath = localSyncPath

        return !setupService.hasExistingListings(for: tempProfile)
    }

    /// Returns the number of items in the local directory (excluding hidden .synctray folder)
    private var localDirectoryItemCount: Int {
        guard !localSyncPath.isEmpty else { return 0 }
        let fm = FileManager.default
        guard fm.fileExists(atPath: localSyncPath) else { return 0 }

        do {
            let contents = try fm.contentsOfDirectory(atPath: localSyncPath)
            // Exclude .synctray directory from count
            return contents.filter { !$0.hasPrefix(".synctray") }.count
        } catch {
            return 0
        }
    }

    /// Returns true if local directory exists and has files that will be uploaded
    private var localDirectoryHasContent: Bool {
        localDirectoryItemCount > 0
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Profile Name
                    profileNameSection

                    Divider().padding(.vertical, 4)

                    // Sync Configuration
                    sectionHeader("Sync Configuration", icon: "arrow.triangle.2.circlepath")
                    syncConfigurationSection

                    Divider().padding(.vertical, 4)

                    // Scheduled Sync Management
                    sectionHeader("Automatic Sync", icon: "calendar.badge.clock")
                    scheduledSyncSection

                    Divider().padding(.vertical, 4)

                    // Advanced Options
                    Button(action: { withAnimation { showAdvanced.toggle() } }) {
                        HStack {
                            sectionHeader("Advanced Options", icon: "gearshape.2")
                            Spacer()
                            Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if showAdvanced {
                        advancedSectionContent
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .padding(.top, 12)
            }

            // Fixed footer with Save/Revert buttons
            Divider()
            actionButtons
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear {
            loadProfileValues()
            loadRcloneRemotes()
        }
        .onChange(of: profile.id) { _ in
            loadProfileValues()
        }
        .alert("Uninstall Scheduled Sync?", isPresented: $showingUninstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { uninstallSync() }
        } message: {
            Text("This will remove the sync script and stop automatic syncing for \"\(profile.name)\".")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundColor(.primary)
    }

    private var profileNameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Profile Name")
                .font(.subheadline.weight(.medium))
            TextField("e.g., Work, Personal, Photos", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
        }
    }

    private var syncConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Remote Name
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Name")
                    .font(.subheadline.weight(.medium))
                Text("The rclone remote to sync with")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if isLoadingRemotes {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 150)
                    } else if !availableRemotes.isEmpty {
                        Picker("", selection: $rcloneRemote) {
                            Text("Select...").tag("")
                            ForEach(availableRemotes, id: \.self) { remote in
                                Text(remote).tag(remote)
                            }
                        }
                        .labelsHidden()
                    } else {
                        TextField("e.g., synology", text: $rcloneRemote)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                    }

                    Button(action: loadRcloneRemotes) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh remotes list")
                    Spacer()
                }

                if let error = remotesError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if availableRemotes.isEmpty && !isLoadingRemotes {
                    Text("Run `rclone listremotes` in Terminal to see configured remotes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Remote Folder
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Folder")
                    .font(.subheadline.weight(.medium))
                Text("The folder path on the remote to sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if isLoadingFolders {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !availableFolders.isEmpty && !useTextInputForFolder {
                        Picker("", selection: $remotePath) {
                            Text("Select folder...").tag("")
                            ForEach(availableFolders, id: \.self) { folder in
                                Text(folder).tag(folder)
                            }
                        }
                        .labelsHidden()
                    } else {
                        TextField("e.g., home/Documents", text: $remotePath)
                            .textFieldStyle(.roundedBorder)
                    }

                    if !availableFolders.isEmpty {
                        Button(action: { useTextInputForFolder.toggle() }) {
                            Image(systemName: useTextInputForFolder ? "list.bullet" : "pencil")
                        }
                        .help(useTextInputForFolder ? "Switch to folder picker" : "Switch to text input")
                    }

                    Button(action: {
                        useTextInputForFolder = false
                        loadRemoteFolders()
                    }) {
                        if isLoadingFolders {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "folder.badge.questionmark")
                        }
                    }
                    .help("Load folders from remote")
                    .disabled(rcloneRemote.isEmpty)
                    Spacer()
                }

                if remotePath.isEmpty && !rcloneRemote.isEmpty && availableFolders.isEmpty {
                    Label("Click the folder icon to browse, or type the folder name", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = foldersError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Local Folder
            VStack(alignment: .leading, spacing: 4) {
                Text("Local Folder")
                    .font(.subheadline.weight(.medium))
                Text("The folder on your Mac that will be synced with the remote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("/Volumes/MyDrive/MyFolder", text: $localSyncPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        browseForFolder(title: "Select Local Sync Directory") { path in
                            localSyncPath = path
                        }
                    }
                }

                // External drive toggle
                if localSyncPath.hasPrefix("/Volumes/") {
                    Toggle(isOn: $isExternalDrive) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("External drive")
                                .font(.subheadline)
                            Text("Skip sync when drive is disconnected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.top, 8)
                }
            }

            // Warning when paths changed and need initial sync
            if pathsNeedInitialSync {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Initial sync required")
                                .font(.subheadline.weight(.medium))
                            Text("These paths haven't been synced before. Saving will run an initial sync to establish the baseline.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if localDirectoryHasContent {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Local folder contains \(localDirectoryItemCount) item\(localDirectoryItemCount == 1 ? "" : "s")")
                                    .font(.subheadline.weight(.medium))
                                Text("These files will be uploaded to the remote during initial sync.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .clipShape(.rect(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.15), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

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

    private var scheduledSyncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status
            HStack {
                if isInstalled {
                    let state = syncManager.state(for: profile.id)
                    switch state {
                    case .error:
                        Label("Error", systemImage: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                    case .syncing:
                        Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundColor(.blue)
                    default:
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                } else {
                    Label("Not Installed", systemImage: "circle.dashed")
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Last sync error from rclone
            if isInstalled, let lastError = syncManager.lastError(for: profile.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Last sync error:", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.red)
                    Text(lastError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)

                    // Action buttons for common errors
                    if let errorAction = detectErrorAction(from: lastError) {
                        HStack(spacing: 8) {
                            Button(action: { handleErrorAction(errorAction) }) {
                                if isRunningResync {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 14, height: 14)
                                    Text(errorAction.progressText)
                                } else {
                                    Label(errorAction.buttonText, systemImage: errorAction.icon)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isRunningResync)
                            .help(errorAction.helpText)
                        }
                    }

                    // Show resync output if available
                    if showResyncOutput && !resyncOutput.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Resync output:")
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Button(action: { showResyncOutput = false }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            ScrollView {
                                Text(resyncOutput)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 150)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(4)
                        }
                    }
                }
            }

            // Info about generated files
            if isInstalled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Generated files:")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    filePathLink(label: "Script", path: SyncProfile.sharedScriptPath)
                    filePathLink(label: "Config", path: profile.configPath)
                    filePathLink(label: "Schedule", path: profile.plistPath)
                    filePathLink(label: "Log", path: profile.logPath)
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
                    Button(action: { syncManager.triggerManualSync(for: profile) }) {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { showingUninstallConfirm = true }) {
                        Label("Uninstall", systemImage: "trash")
                    }

                    Button(action: reinstallSync) {
                        Label("Reinstall", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canInstall || isInstalling)
                } else {
                    Button(action: installSync) {
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
                    if rcloneRemote.isEmpty {
                        Label("Select an rclone remote", systemImage: "exclamationmark.circle")
                    }
                    if remotePath.isEmpty {
                        Label("Enter the folder path on the remote", systemImage: "exclamationmark.circle")
                    }
                    if localSyncPath.isEmpty {
                        Label("Select a local folder", systemImage: "exclamationmark.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.15), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var advancedSectionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Sync Interval
            VStack(alignment: .leading, spacing: 4) {
                Text("Sync Interval")
                    .font(.subheadline.weight(.medium))
                Text("How often to run the sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $syncIntervalMinutes) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
                .pickerStyle(.menu)
                .frame(width: 150, alignment: .leading)
            }

            Divider()

            // Additional rclone flags
            VStack(alignment: .leading, spacing: 4) {
                Text("Additional rclone Flags")
                    .font(.subheadline.weight(.medium))
                Text("Extra flags to pass to rclone bisync command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("--dry-run --verbose", text: $additionalRcloneFlags)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.15), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        HStack {
            if hasChanges {
                Text("You have unsaved changes")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Spacer()

            Button("Revert") {
                loadProfileValues()
            }
            .disabled(!hasChanges)

            Button("Save") {
                saveProfile()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func loadProfileValues() {
        name = profile.name
        rcloneRemote = profile.rcloneRemote
        remotePath = profile.remotePath
        localSyncPath = profile.localSyncPath
        isExternalDrive = !profile.drivePathToMonitor.isEmpty
        syncIntervalMinutes = profile.syncIntervalMinutes
        additionalRcloneFlags = profile.additionalRcloneFlags
    }

    private func saveProfile() {
        var updatedProfile = profile
        updatedProfile.name = name
        updatedProfile.rcloneRemote = rcloneRemote
        updatedProfile.remotePath = remotePath
        updatedProfile.localSyncPath = localSyncPath
        updatedProfile.drivePathToMonitor = computedDrivePath
        updatedProfile.syncIntervalMinutes = syncIntervalMinutes
        updatedProfile.additionalRcloneFlags = additionalRcloneFlags

        profileStore.update(updatedProfile)

        // If installed, reinstall to apply changes
        if isInstalled {
            reinstallSync()
        }
    }

    private func loadRcloneRemotes() {
        isLoadingRemotes = true
        remotesError = nil

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
        guard !rcloneRemote.isEmpty else { return }

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
            process.arguments = ["lsd", "\(rcloneRemote):"]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                let folders = output
                    .components(separatedBy: .newlines)
                    .compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return nil }
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

    private func installSync() {
        isInstalling = true
        installError = nil

        // Save profile first
        saveProfile()

        // Get updated profile
        guard let currentProfile = profileStore.profile(for: profile.id) else {
            isInstalling = false
            installError = "Profile not found"
            return
        }

        // Check if this needs initial sync before we start
        let needsResync = !setupService.hasExistingListings(for: currentProfile)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. Install script, config, and launchd plist
                // Defer loading the agent if we need to run resync first (to avoid race condition)
                try setupService.install(profile: currentProfile, loadAgent: !needsResync)

                // 2. Initialize paths (create dir and check files)
                if let error = setupService.initializeSyncPaths(for: currentProfile) {
                    DispatchQueue.main.async {
                        isInstalling = false
                        installError = error
                    }
                    return
                }

                DispatchQueue.main.async {
                    isInstalling = false

                    // Update profile to mark as enabled
                    var enabledProfile = currentProfile
                    enabledProfile.isEnabled = true
                    profileStore.update(enabledProfile)
                    syncManager.refreshSettings()

                    // 3. Run initial resync if this is a new path combination
                    // The agent will be loaded after resync completes
                    if needsResync {
                        runResync(loadAgentOnCompletion: true)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isInstalling = false
                    installError = error.localizedDescription
                }
            }
        }
    }

    private func uninstallSync() {
        guard let currentProfile = profileStore.profile(for: profile.id) else { return }

        do {
            try setupService.uninstall(profile: currentProfile)

            // Update profile to mark as disabled
            var disabledProfile = currentProfile
            disabledProfile.isEnabled = false
            profileStore.update(disabledProfile)
            syncManager.refreshSettings()
        } catch {
            installError = error.localizedDescription
        }
    }

    private func reinstallSync() {
        guard let currentProfile = profileStore.profile(for: profile.id) else { return }

        do {
            try setupService.uninstall(profile: currentProfile)
        } catch {
            // Ignore uninstall errors
        }
        installSync()
    }

    private func runResync(loadAgentOnCompletion: Bool = false) {
        isRunningResync = true
        resyncOutput = ""
        showResyncOutput = true

        // Capture profile for loading agent after completion
        let currentProfile = profile

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()

            // Find rclone
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
                    isRunningResync = false
                    resyncOutput = "Error: rclone not found. Install with: brew install rclone"
                }
                return
            }

            // Build the resync command
            let remotePath = "\(rcloneRemote):\(self.remotePath)"
            var arguments = ["bisync", remotePath, localSyncPath, "--resync", "--verbose"]

            // Add any additional flags from profile
            if !additionalRcloneFlags.isEmpty {
                let extraFlags = additionalRcloneFlags.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                arguments.append(contentsOf: extraFlags)
            }

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = errorPipe

            DispatchQueue.main.async {
                resyncOutput = "Running: rclone \(arguments.joined(separator: " "))\n\n"
            }

            do {
                try process.run()

                // Read output in real-time
                let outputHandle = pipe.fileHandleForReading
                let errorHandle = errorPipe.fileHandleForReading

                outputHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        DispatchQueue.main.async {
                            resyncOutput += str
                        }
                    }
                }

                errorHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        DispatchQueue.main.async {
                            resyncOutput += str
                        }
                    }
                }

                process.waitUntilExit()

                outputHandle.readabilityHandler = nil
                errorHandle.readabilityHandler = nil

                // Read any remaining data
                let remainingOutput = outputHandle.readDataToEndOfFile()
                let remainingError = errorHandle.readDataToEndOfFile()

                DispatchQueue.main.async {
                    if let str = String(data: remainingOutput, encoding: .utf8), !str.isEmpty {
                        resyncOutput += str
                    }
                    if let str = String(data: remainingError, encoding: .utf8), !str.isEmpty {
                        resyncOutput += str
                    }

                    let exitCode = process.terminationStatus
                    if exitCode == 0 {
                        resyncOutput += "\n✓ Resync completed successfully!"

                        // Load the launchd agent now that resync is complete
                        if loadAgentOnCompletion {
                            setupService.loadAgent(for: currentProfile)
                            resyncOutput += "\n✓ Scheduled sync is now active."
                        }

                        // Clear the error state
                        syncManager.refreshSettings()
                    } else {
                        resyncOutput += "\n✗ Resync failed with exit code \(exitCode)"

                        // Still load the agent even on failure so scheduled syncs can retry
                        if loadAgentOnCompletion {
                            setupService.loadAgent(for: currentProfile)
                        }
                    }

                    isRunningResync = false
                }
            } catch {
                DispatchQueue.main.async {
                    resyncOutput += "Error running rclone: \(error.localizedDescription)"
                    isRunningResync = false
                }
            }
        }
    }

    // MARK: - File Dialogs

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

    @ViewBuilder
    private func filePathLink(label: String, path: String) -> some View {
        let displayPath = path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        HStack(spacing: 4) {
            Text("• \(label):")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(displayPath)
                .font(.caption)
                .foregroundColor(.gray)
                .textSelection(.enabled)
                .onTapGesture {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .help("Click to open, or select to copy path")
        }
    }

    // MARK: - Error Action Handling

    enum ErrorAction {
        case resync
        case unlockAndResync
        case unlock
        case retrySync
        case createCheckFiles

        var buttonText: String {
            switch self {
            case .resync:
                return "Run Initial Sync (--resync)"
            case .unlockAndResync:
                return "Unlock & Resync"
            case .unlock:
                return "Remove Lock File"
            case .retrySync:
                return "Retry Sync"
            case .createCheckFiles:
                return "Create Check Files & Sync"
            }
        }

        var progressText: String {
            switch self {
            case .resync:
                return "Running resync..."
            case .unlockAndResync:
                return "Unlocking & resyncing..."
            case .unlock:
                return "Removing lock..."
            case .retrySync:
                return "Syncing..."
            case .createCheckFiles:
                return "Creating check files..."
            }
        }

        var icon: String {
            switch self {
            case .resync:
                return "arrow.triangle.2.circlepath"
            case .unlockAndResync:
                return "lock.open"
            case .unlock:
                return "lock.slash"
            case .retrySync:
                return "arrow.clockwise"
            case .createCheckFiles:
                return "checkmark.circle"
            }
        }

        var helpText: String {
            switch self {
            case .resync:
                return "Establish initial baseline for bidirectional sync"
            case .unlockAndResync:
                return "Remove stale lock file and run resync"
            case .unlock:
                return "Remove the lock file blocking sync"
            case .retrySync:
                return "Try running the sync again"
            case .createCheckFiles:
                return "Create .synctray-check files required for access check"
            }
        }
    }

    private func detectErrorAction(from error: String) -> ErrorAction? {
        // Lock file error - needs unlock first
        if error.contains("lock file found") || error.contains("prior lock file") {
            return .unlockAndResync
        }

        // Missing baseline - needs resync
        if error.contains("cannot find prior") || error.contains("--resync") {
            return .resync
        }

        // Check access failed - need to create check files
        if error.contains("RCLONE_TEST") || error.contains(".synctray-check") || error.contains("check file") || error.contains("Access test failed") {
            return .createCheckFiles
        }

        // Generic errors - offer retry
        if error.contains("bisync aborted") || error.contains("Failed to bisync") || error.contains("failed") {
            return .retrySync
        }

        return nil
    }

    private func handleErrorAction(_ action: ErrorAction) {
        switch action {
        case .resync:
            runResync()
        case .unlockAndResync:
            unlockAndResync()
        case .unlock:
            removeLockFile()
        case .retrySync:
            syncManager.triggerManualSync(for: profile)
        case .createCheckFiles:
            createCheckFilesAndSync()
        }
    }

    private func removeLockFile() {
        let lockPattern = "\(rcloneRemote)_\(remotePath.replacingOccurrences(of: "/", with: "_"))..\(localSyncPath.replacingOccurrences(of: "/", with: "_")).lck"
        let bisyncDir = "\(NSHomeDirectory())/Library/Caches/rclone/bisync"

        // Remove all matching lock files
        if let files = try? FileManager.default.contentsOfDirectory(atPath: bisyncDir) {
            for file in files where file.hasSuffix(".lck") {
                let fullPath = "\(bisyncDir)/\(file)"
                try? FileManager.default.removeItem(atPath: fullPath)
            }
        }
    }

    private func unlockAndResync() {
        isRunningResync = true
        resyncOutput = "Removing lock files...\n"
        showResyncOutput = true

        // Remove lock files first
        let bisyncDir = "\(NSHomeDirectory())/Library/Caches/rclone/bisync"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: bisyncDir) {
            for file in files where file.hasSuffix(".lck") {
                let fullPath = "\(bisyncDir)/\(file)"
                if (try? FileManager.default.removeItem(atPath: fullPath)) != nil {
                    resyncOutput += "Removed: \(file)\n"
                }
            }
        }

        resyncOutput += "\nStarting resync...\n\n"

        // Small delay then run resync
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isRunningResync = false
            self.runResync()
        }
    }

    private func createCheckFilesAndSync() {
        isRunningResync = true
        resyncOutput = "Creating check files (.synctray-check)...\n"
        showResyncOutput = true

        // Capture values from main thread before going to background
        let localPath = profile.localSyncPath
        let remote = profile.rcloneRemote
        let remoteFolder = profile.remotePath
        let checkFileName = SyncSetupService.checkFileName

        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default

            // Create local check file (.synctray-check)
            let localCheckFile = (localPath as NSString).appendingPathComponent(checkFileName)

            DispatchQueue.main.async {
                resyncOutput += "Local path: \(localCheckFile)\n"
            }

            // Create check file
            if !fileManager.fileExists(atPath: localCheckFile) {
                if !fileManager.createFile(atPath: localCheckFile, contents: nil) {
                    DispatchQueue.main.async {
                        resyncOutput += "✗ Failed to create local check file\n"
                        isRunningResync = false
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                resyncOutput += "✓ Created local .synctray-check file\n"
            }

            // Create remote check file using rclone
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
                    resyncOutput += "✗ rclone not found\n"
                    isRunningResync = false
                }
                return
            }

            // Create remote check file using rclone touch
            let remoteDest = "\(remote):\(remoteFolder)/\(checkFileName)"
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["touch", remoteDest]
            process.standardOutput = pipe
            process.standardError = pipe

            DispatchQueue.main.async {
                resyncOutput += "Running: rclone touch \"\(remoteDest)\"\n"
            }

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    if !output.isEmpty {
                        resyncOutput += output + "\n"
                    }

                    if process.terminationStatus == 0 {
                        resyncOutput += "✓ Created remote .synctray-check file\n\n"
                        resyncOutput += "Now running initial sync (--resync)...\n"

                        // Run resync after creating files (needed because check-access failure corrupts listing files)
                        DispatchQueue.main.async {
                            runResync()
                        }
                    } else {
                        resyncOutput += "✗ Failed to create remote file (exit code \(process.terminationStatus))\n"
                        isRunningResync = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    resyncOutput += "✗ Error: \(error.localizedDescription)\n"
                    isRunningResync = false
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SyncManager())
}

import SwiftUI
import AppKit

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
    @State private var resyncOutputLines: [String] = []  // Circular buffer for output
    @State private var showResyncOutput: Bool = false

    // Maximum lines to keep in output buffer (prevents memory issues with large syncs)
    private let maxOutputLines = 100
    @State private var useTextInputForFolder: Bool = false
    @State private var remotesError: String?
    @State private var availableFolders: [String] = []
    @State private var isLoadingFolders: Bool = false
    @State private var foldersError: String?

    // File monitoring for resumed syncs
    @State private var logFileMonitor: DispatchSourceFileSystemObject?
    @State private var logFileDescriptor: Int32 = -1

    // Alert for sync already in progress
    @State private var showingSyncInProgressAlert: Bool = false

    private let setupService = SyncSetupService.shared

    // MARK: - Computed Properties

    /// Check if a sync is currently running for this profile (via any method)
    private var isSyncRunningForProfile: Bool {
        // Local resync started by this view
        if isRunningResync { return true }

        // SyncManager detected sync (includes external monitoring via lock file)
        if syncManager.state(for: profile.id) == .syncing { return true }

        return false
    }

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
            checkForRunningInitialSync()
        }
        .onDisappear {
            stopLogFileMonitor()
        }
        .onChange(of: profile.id) { _ in
            loadProfileValues()
        }
        .onChange(of: rcloneRemote) { newRemote in
            // Auto-fetch folders when a remote is selected
            if !newRemote.isEmpty {
                loadRemoteFolders()
            } else {
                availableFolders = []
            }
        }
        .alert("Uninstall Scheduled Sync?", isPresented: $showingUninstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { uninstallSync() }
        } message: {
            Text("This will remove the sync script and stop automatic syncing for \"\(profile.name)\".")
        }
        .alert("Sync Already Running", isPresented: $showingSyncInProgressAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A sync is already in progress for this profile. Please wait for it to complete before starting another sync.")
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
                            .controlSize(.small)
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
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if useTextInputForFolder {
                        // Custom text input mode
                        TextField("e.g., home/Documents", text: $remotePath)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        // Folder picker mode (default)
                        Picker("", selection: $remotePath) {
                            Text("Select folder...").tag("")
                            ForEach(availableFolders, id: \.self) { folder in
                                Text(folder).tag(folder)
                            }
                        }
                        .labelsHidden()
                        .disabled(availableFolders.isEmpty)
                    }

                    // Toggle between picker and text input
                    Button(action: { useTextInputForFolder.toggle() }) {
                        Image(systemName: useTextInputForFolder ? "list.bullet" : "pencil")
                    }
                    .help(useTextInputForFolder ? "Switch to folder picker" : "Enter custom path")
                    Spacer()
                }

                if let error = foldersError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if availableFolders.isEmpty && !isLoadingFolders && !rcloneRemote.isEmpty && !useTextInputForFolder {
                    Label("No folders found. Use custom path if needed.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            // Status - check local resync state first, then syncManager state
            HStack {
                if isRunningResync {
                    // Local resync in progress (runs directly, not via launchd)
                    Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundColor(.blue)
                } else if isInstalled {
                    let state = syncManager.state(for: profile.id)
                    switch state {
                    case .paused:
                        Label("Paused", systemImage: "pause.circle.fill")
                            .foregroundColor(.gray)
                    case .error:
                        Label("Error", systemImage: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                    case .syncing:
                        // Distinguish between external (detected on app open) vs active syncs
                        if syncManager.isMonitoringExternalSync(for: profile.id) {
                            Label("Sync in Progress", systemImage: "eye.circle.fill")
                                .foregroundColor(.blue)
                        } else {
                            Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundColor(.blue)
                        }
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

            // Sync progress indicator
            if isRunningResync || syncManager.state(for: profile.id) == .syncing {
                HStack {
                    if let progress = syncManager.profileProgress[profile.id] {
                        SyncProgressDetailView(progress: progress)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(isRunningResync ? "Starting initial sync..." : "Starting sync...")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }

                    Spacer()

                    // Mute notifications button
                    Button(action: {
                        if syncManager.isNotificationsMuted(for: profile.id) {
                            syncManager.unmuteNotifications(for: profile.id)
                        } else {
                            syncManager.muteNotifications(for: profile.id)
                        }
                    }) {
                        Image(systemName: syncManager.isNotificationsMuted(for: profile.id)
                              ? "bell.slash.fill"
                              : "bell.fill")
                            .foregroundColor(syncManager.isNotificationsMuted(for: profile.id)
                                             ? .orange
                                             : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(syncManager.isNotificationsMuted(for: profile.id)
                          ? "Unmute notifications"
                          : "Mute notifications for this sync")
                }
            }

            // Last sync error from rclone (hide during active resync operations)
            if isInstalled, !isRunningResync, let lastError = syncManager.lastError(for: profile.id) {
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
                        VStack(alignment: .leading, spacing: 6) {
                            // Show additional context for "too many deletes" error
                            if errorAction == .forceSync {
                                Text("More than 50% of files would be deleted. This safety feature prevents accidental data loss.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack(spacing: 8) {
                                    // Force Sync - proceed with deletions
                                    Button(action: {
                                        if isSyncRunningForProfile {
                                            showingSyncInProgressAlert = true
                                            return
                                        }
                                        handleErrorAction(.forceSync)
                                    }) {
                                        if isSyncRunningForProfile {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Force syncing...")
                                        } else {
                                            Label("Delete from Remote", systemImage: "trash")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.orange)
                                    .disabled(isSyncRunningForProfile)
                                    .help("Proceed with deletions - remove files from remote")

                                    // Restore - resync to get files back from remote
                                    Button(action: {
                                        if isSyncRunningForProfile {
                                            showingSyncInProgressAlert = true
                                            return
                                        }
                                        handleErrorAction(.resync)
                                    }) {
                                        if isSyncRunningForProfile {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Restoring...")
                                        } else {
                                            Label("Restore from Remote", systemImage: "arrow.down.circle")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isSyncRunningForProfile)
                                    .help("Restore deleted files from remote using --resync")
                                }
                            } else {
                                // Standard error action button
                                HStack(spacing: 8) {
                                    Button(action: {
                                        if isSyncRunningForProfile {
                                            showingSyncInProgressAlert = true
                                            return
                                        }
                                        handleErrorAction(errorAction)
                                    }) {
                                        if isSyncRunningForProfile {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text(errorAction.progressText)
                                        } else {
                                            Label(errorAction.buttonText, systemImage: errorAction.icon)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(isSyncRunningForProfile)
                                    .help(errorAction.helpText)
                                }
                            }
                        }
                    }

                }
            }

            // Show resync output if available (hide when detailed progress is shown)
            if showResyncOutput && !resyncOutputLines.isEmpty && syncManager.profileProgress[profile.id] == nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sync output:")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(resyncOutputLines.count) lines")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // Open log file button
                        Button(action: {
                            let logPath = profile.logPath
                            if FileManager.default.fileExists(atPath: logPath) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                            } else {
                                // Fallback to regular log if initial log was cleaned up
                                NSWorkspace.shared.open(URL(fileURLWithPath: profile.logPath))
                            }
                        }) {
                            Image(systemName: "doc.text")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open log file")
                        Button(action: { showResyncOutput = false }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Close output panel")
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(resyncOutputLines.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                }
                            }
                            .padding(8)
                            .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                        .onChange(of: resyncOutputLines.count) { _ in
                            // Auto-scroll to bottom when new content arrives
                            if let lastIndex = resyncOutputLines.indices.last {
                                withAnimation(.easeOut(duration: 0.1)) {
                                    proxy.scrollTo(lastIndex, anchor: .bottom)
                                }
                            }
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
                    filePathLink(label: "Exclude Filter", path: profile.filterFilePath)
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
                    Button(action: {
                        // Double-check at action time in case state changed
                        if isSyncRunningForProfile {
                            showingSyncInProgressAlert = true
                            return
                        }
                        // Don't sync if paused
                        if syncManager.isPaused(for: profile.id) {
                            return
                        }
                        // Clean up stale lock file if exists but process not running
                        let lockPath = profile.lockFilePath
                        if FileManager.default.fileExists(atPath: lockPath) {
                            try? FileManager.default.removeItem(atPath: lockPath)
                        }
                        syncManager.triggerManualSync(for: profile)
                    }) {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSyncRunningForProfile || syncManager.isPaused(for: profile.id))

                    // Pause/Resume button
                    Button(action: {
                        syncManager.togglePause(for: profile.id)
                    }) {
                        Label(
                            syncManager.isPaused(for: profile.id) ? "Resume" : "Pause",
                            systemImage: syncManager.isPaused(for: profile.id) ? "play.fill" : "pause.fill"
                        )
                    }
                    .disabled(isSyncRunningForProfile)

                    Button(action: { showingUninstallConfirm = true }) {
                        Label("Uninstall", systemImage: "trash")
                    }
                    .disabled(isSyncRunningForProfile)

                    Button(action: reinstallSync) {
                        Label("Reinstall", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canInstall || isInstalling || isSyncRunningForProfile)
                } else {
                    Button(action: installSync) {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
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

            Divider()

            // Debug Logging
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(
                    get: { SyncTraySettings.debugLoggingEnabled },
                    set: { SyncTraySettings.debugLoggingEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Debug Logging")
                            .font(.subheadline.weight(.medium))
                        Text("Log file watcher events and sync triggers to Console")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
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

        // Show text input if the path contains "/" (nested path) or is a custom path
        // that won't be in the folder picker dropdown
        useTextInputForFolder = profile.remotePath.contains("/")
    }

    /// Build a profile from the current form state
    private func buildProfileFromForm() -> SyncProfile {
        var updatedProfile = profile
        updatedProfile.name = name
        updatedProfile.rcloneRemote = rcloneRemote
        updatedProfile.remotePath = remotePath
        updatedProfile.localSyncPath = localSyncPath
        updatedProfile.drivePathToMonitor = computedDrivePath
        updatedProfile.syncIntervalMinutes = syncIntervalMinutes
        updatedProfile.additionalRcloneFlags = additionalRcloneFlags
        return updatedProfile
    }

    private func saveProfile() {
        let updatedProfile = buildProfileFromForm()
        let currentProfile = profile

        // Check if sync-related settings changed (require reinstall)
        let needsReinstall = isInstalled && (
            currentProfile.rcloneRemote != updatedProfile.rcloneRemote ||
            currentProfile.remotePath != updatedProfile.remotePath ||
            currentProfile.localSyncPath != updatedProfile.localSyncPath ||
            currentProfile.syncIntervalMinutes != updatedProfile.syncIntervalMinutes ||
            currentProfile.additionalRcloneFlags != updatedProfile.additionalRcloneFlags
        )

        profileStore.update(updatedProfile)

        // Clear any cached error since config changed
        syncManager.clearError(for: profile.id)

        // Only reinstall if sync-related settings changed
        if needsReinstall {
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

                    // If current path doesn't match any folder, switch to text input
                    if !self.remotePath.isEmpty && !folders.contains(self.remotePath) {
                        self.useTextInputForFolder = true
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

        // Build profile from current form state (no need to save first)
        let currentProfile = buildProfileFromForm()

        // Check if this needs initial sync before we start
        let needsResync = !setupService.hasExistingListings(for: currentProfile)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. Install script, config, and launchd plist (DO NOT load agent yet)
                // We always defer loading so LogWatcher is set up first
                try setupService.install(profile: currentProfile, loadAgent: false)

                // 2. Initialize paths (create dir and check files)
                if let error = setupService.initializeSyncPaths(for: currentProfile) {
                    DispatchQueue.main.async {
                        isInstalling = false
                        installError = error
                    }
                    return
                }

                DispatchQueue.main.async {
                    // 3. Update profile and refresh settings FIRST (creates LogWatcher)
                    // This ensures LogWatcher is watching BEFORE the agent starts
                    var enabledProfile = currentProfile
                    enabledProfile.isEnabled = true
                    profileStore.update(enabledProfile)
                    syncManager.refreshSettings()  // LogWatcher now ready

                    // 4. NOW load the agent (after LogWatcher is watching)
                    if needsResync {
                        // runResync will handle clearing isInstalling state and load agent on completion
                        runResync(loadAgentOnCompletion: true)
                    } else {
                        // Load the agent now that LogWatcher is ready
                        if !setupService.loadAgent(for: currentProfile) {
                            installError = "Failed to start sync agent"
                        }
                        isInstalling = false
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
        // Clear installing state so resync output panel is visible
        isInstalling = false
        isRunningResync = true
        resyncOutputLines = ["Starting initial sync..."]  // Clear and start fresh
        showResyncOutput = true

        // Clear any cached error and set syncing state (updates menu bar icon)
        syncManager.clearError(for: profile.id)
        syncManager.setSyncing(for: profile.id, isSyncing: true)

        // Automatically mute notifications for initial sync (resync)
        // This prevents notification spam when many files are being synced for the first time
        syncManager.muteNotifications(for: profile.id)

        // Capture all values from main thread before going to background
        let currentProfile = profile
        let capturedRcloneRemote = rcloneRemote
        let capturedRemotePath = remotePath
        let capturedLocalSyncPath = localSyncPath
        let capturedAdditionalFlags = additionalRcloneFlags
        let capturedFilterPath = profile.filterFilePath  // Exclude filter file
        let capturedLockPath = profile.lockFilePath  // Lock file to prevent concurrent scheduled syncs
        let bisyncDir = "\(NSHomeDirectory())/Library/Caches/rclone/bisync"
        let capturedMaxLines = maxOutputLines
        let syncLogPath = profile.logPath  // Use main log file (same as scheduled syncs)

        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default

            // Ensure log directory exists (append to existing log, don't truncate)
            let logDir = (syncLogPath as NSString).deletingLastPathComponent
            try? fileManager.createDirectory(atPath: logDir, withIntermediateDirectories: true)

            // Create file if it doesn't exist
            if !fileManager.fileExists(atPath: syncLogPath) {
                fileManager.createFile(atPath: syncLogPath, contents: nil)
            }

            // Helper to write to log file (appends)
            let writeToLog: (String) -> Void = { content in
                if let data = (content + "\n").data(using: .utf8),
                   let handle = FileHandle(forWritingAtPath: syncLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            }

            // Track bytes written for periodic truncation
            var bytesWritten: Int64 = 0
            var lastTruncateTime = Date()
            let maxLogSize: Int64 = 10_000_000  // ~10MB (increased to reduce truncation frequency)
            let truncateInterval: TimeInterval = 30

            // Remove any existing lock files first (prevents "prior lock file found" errors)
            if let files = try? fileManager.contentsOfDirectory(atPath: bisyncDir) {
                for file in files where file.hasSuffix(".lck") {
                    let fullPath = "\(bisyncDir)/\(file)"
                    if (try? fileManager.removeItem(atPath: fullPath)) != nil {
                        let msg = "Removed lock file: \(file)"
                        writeToLog(msg)
                        DispatchQueue.main.async {
                            self.appendOutputLine(msg)
                        }
                    }
                }
            }

            let process = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()

            // Find rclone
            let rclonePaths = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
            var rclonePath: String?

            for path in rclonePaths {
                if fileManager.fileExists(atPath: path) {
                    rclonePath = path
                    break
                }
            }

            guard let path = rclonePath else {
                let errMsg = "Error: rclone not found. Install with: brew install rclone"
                writeToLog(errMsg)
                try? fileManager.removeItem(atPath: syncLogPath)
                DispatchQueue.main.async {
                    self.isRunningResync = false
                    self.resyncOutputLines = [errMsg]
                    self.syncManager.setSyncing(for: currentProfile.id, isSyncing: false)
                }
                return
            }

            // Build the resync command with JSON logging and frequent stats updates
            let fullRemotePath = "\(capturedRcloneRemote):\(capturedRemotePath)"
            var arguments = ["bisync", fullRemotePath, capturedLocalSyncPath, "--resync", "--verbose", "--use-json-log", "--stats", "2s"]

            // Add filter file if it exists (excludes ._* files, .DS_Store, etc.)
            if fileManager.fileExists(atPath: capturedFilterPath) {
                arguments.append(contentsOf: ["--filter-from", capturedFilterPath])
            }

            // Add any additional flags from profile
            if !capturedAdditionalFlags.isEmpty {
                let extraFlags = capturedAdditionalFlags.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                arguments.append(contentsOf: extraFlags)
            }

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = errorPipe

            let cmdLine = "Running: rclone \(arguments.joined(separator: " "))"
            writeToLog(cmdLine)
            DispatchQueue.main.async {
                self.resyncOutputLines = [cmdLine, ""]
            }

            do {
                try process.run()

                // Create lock file with process PID to prevent concurrent scheduled syncs
                let pid = process.processIdentifier
                try? "\(pid)".write(toFile: capturedLockPath, atomically: true, encoding: .utf8)

                // Read output in batches to reduce UI updates and lag
                let outputHandle = pipe.fileHandleForReading
                let errorHandle = errorPipe.fileHandleForReading
                var outputBuffer = ""
                var lastUpdateTime = Date()
                let updateInterval: TimeInterval = 2.0  // Update UI every 2 seconds (reduced from 0.5s)
                let bufferLock = NSLock()

                let flushBuffer = {
                    bufferLock.lock()
                    let lines = outputBuffer.components(separatedBy: "\n").filter { !$0.isEmpty }
                    let rawContent = outputBuffer
                    outputBuffer = ""
                    bufferLock.unlock()

                    if !lines.isEmpty {
                        // Write to log file (append raw content)
                        if let data = rawContent.data(using: .utf8),
                           let handle = FileHandle(forWritingAtPath: syncLogPath) {
                            handle.seekToEndOfFile()
                            handle.write(data)
                            bytesWritten += Int64(data.count)
                            handle.closeFile()
                        }

                        // Periodically truncate log file if it's getting too large
                        let now = Date()
                        if bytesWritten > maxLogSize && now.timeIntervalSince(lastTruncateTime) > truncateInterval {
                            if let content = try? String(contentsOfFile: syncLogPath, encoding: .utf8) {
                                let logLines = content.components(separatedBy: "\n")
                                let truncated = logLines.suffix(100000).joined(separator: "\n")
                                // Use non-atomic write to preserve inode (prevents LogWatcher from losing track)
                                try? truncated.write(toFile: syncLogPath, atomically: false, encoding: .utf8)
                            }
                            bytesWritten = 0
                            lastTruncateTime = now
                        }

                        DispatchQueue.main.async {
                            // Circular buffer: append new lines, keep only last maxOutputLines
                            self.resyncOutputLines.append(contentsOf: lines)
                            if self.resyncOutputLines.count > capturedMaxLines {
                                self.resyncOutputLines.removeFirst(self.resyncOutputLines.count - capturedMaxLines)
                            }
                        }
                    }
                }

                outputHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        bufferLock.lock()
                        outputBuffer += str
                        let now = Date()
                        let shouldFlush = now.timeIntervalSince(lastUpdateTime) >= updateInterval
                        if shouldFlush { lastUpdateTime = now }
                        bufferLock.unlock()

                        if shouldFlush { flushBuffer() }
                    }
                }

                errorHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        bufferLock.lock()
                        outputBuffer += str
                        let now = Date()
                        let shouldFlush = now.timeIntervalSince(lastUpdateTime) >= updateInterval
                        if shouldFlush { lastUpdateTime = now }
                        bufferLock.unlock()

                        if shouldFlush { flushBuffer() }
                    }
                }

                process.waitUntilExit()

                // Remove lock file now that process has finished
                try? fileManager.removeItem(atPath: capturedLockPath)

                outputHandle.readabilityHandler = nil
                errorHandle.readabilityHandler = nil

                // Flush any remaining buffered output
                flushBuffer()

                // Read any remaining data
                let remainingOutput = outputHandle.readDataToEndOfFile()
                let remainingError = errorHandle.readDataToEndOfFile()

                DispatchQueue.main.async {
                    if let str = String(data: remainingOutput, encoding: .utf8), !str.isEmpty {
                        let lines = str.components(separatedBy: "\n").filter { !$0.isEmpty }
                        self.resyncOutputLines.append(contentsOf: lines)
                        if self.resyncOutputLines.count > capturedMaxLines {
                            self.resyncOutputLines.removeFirst(self.resyncOutputLines.count - capturedMaxLines)
                        }
                    }
                    if let str = String(data: remainingError, encoding: .utf8), !str.isEmpty {
                        let lines = str.components(separatedBy: "\n").filter { !$0.isEmpty }
                        self.resyncOutputLines.append(contentsOf: lines)
                        if self.resyncOutputLines.count > capturedMaxLines {
                            self.resyncOutputLines.removeFirst(self.resyncOutputLines.count - capturedMaxLines)
                        }
                    }

                    let exitCode = process.terminationStatus
                    if exitCode == 0 {
                        self.appendOutputLine("")
                        self.appendOutputLine("✓ Resync completed successfully!")

                        // Load the launchd agent now that resync is complete
                        // Note: We don't trigger a follow-up sync here because rclone's
                        // "all files changed" safety check will fail it anyway. The scheduled
                        // sync will handle this naturally - the first few syncs may fail with
                        // this transient error, but subsequent syncs will work once the
                        // listing files stabilize.
                        if loadAgentOnCompletion {
                            self.setupService.loadAgent(for: currentProfile)
                            self.appendOutputLine("✓ Scheduled sync is now active.")
                        }

                        // Clear any errors and set to idle - resync was successful
                        self.syncManager.clearError(for: currentProfile.id)
                        self.syncManager.setSyncing(for: currentProfile.id, isSyncing: false)
                        self.syncManager.refreshSettings()
                    } else {
                        self.appendOutputLine("")
                        self.appendOutputLine("✗ Resync failed with exit code \(exitCode)")

                        // Still load the agent even on failure so scheduled syncs can retry
                        if loadAgentOnCompletion {
                            self.setupService.loadAgent(for: currentProfile)
                        }

                        // Clear syncing state (will show error from log if any)
                        self.syncManager.setSyncing(for: currentProfile.id, isSyncing: false)
                    }

                    self.isRunningResync = false
                }
            } catch {
                let errMsg = "Error running rclone: \(error.localizedDescription)"
                writeToLog(errMsg)
                DispatchQueue.main.async {
                    self.appendOutputLine(errMsg)
                    self.syncManager.setSyncing(for: currentProfile.id, isSyncing: false)
                    self.isRunningResync = false
                }
            }
        }
    }

    /// Helper to append a single line to the output buffer with circular buffer logic
    private func appendOutputLine(_ line: String) {
        resyncOutputLines.append(line)
        if resyncOutputLines.count > maxOutputLines {
            resyncOutputLines.removeFirst(resyncOutputLines.count - maxOutputLines)
        }
    }

    /// Helper to append multiple lines to the output buffer with circular buffer logic
    private func appendOutputLines(_ lines: [String]) {
        resyncOutputLines.append(contentsOf: lines)
        if resyncOutputLines.count > maxOutputLines {
            resyncOutputLines.removeFirst(resyncOutputLines.count - maxOutputLines)
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
        case smartFix       // Unified fix: unlock → check files → resync
        case resync
        case unlockAndResync
        case unlockAndRetry // Just remove locks and retry normal sync (no resync)
        case unlock
        case retrySync
        case createCheckFiles
        case forceSync      // Override "too many deletes" safety check

        var buttonText: String {
            switch self {
            case .smartFix:
                return "Fix Sync Issues"
            case .resync:
                return "Run Initial Sync (--resync)"
            case .unlockAndResync:
                return "Unlock & Resync"
            case .unlockAndRetry:
                return "Remove Lock & Continue"
            case .unlock:
                return "Remove Lock File"
            case .retrySync:
                return "Retry Sync"
            case .createCheckFiles:
                return "Create Check Files & Sync"
            case .forceSync:
                return "Force Sync (Override Safety)"
            }
        }

        var progressText: String {
            switch self {
            case .smartFix:
                return "Fixing sync issues..."
            case .resync:
                return "Running resync..."
            case .unlockAndResync:
                return "Unlocking & resyncing..."
            case .unlockAndRetry:
                return "Removing lock & syncing..."
            case .unlock:
                return "Removing lock..."
            case .retrySync:
                return "Syncing..."
            case .createCheckFiles:
                return "Creating check files..."
            case .forceSync:
                return "Force syncing..."
            }
        }

        var icon: String {
            switch self {
            case .smartFix:
                return "wrench.and.screwdriver"
            case .resync:
                return "arrow.triangle.2.circlepath"
            case .unlockAndResync:
                return "lock.open"
            case .unlockAndRetry:
                return "lock.open"
            case .unlock:
                return "lock.slash"
            case .retrySync:
                return "arrow.clockwise"
            case .createCheckFiles:
                return "checkmark.circle"
            case .forceSync:
                return "exclamationmark.triangle"
            }
        }

        var helpText: String {
            switch self {
            case .smartFix:
                return "Automatically fix common sync issues: remove locks, verify check files, and resync"
            case .resync:
                return "Establish initial baseline for bidirectional sync"
            case .unlockAndResync:
                return "Remove stale lock file and run resync"
            case .unlockAndRetry:
                return "Remove stale lock file and continue sync from where it left off"
            case .unlock:
                return "Remove the lock file blocking sync"
            case .retrySync:
                return "Try running the sync again"
            case .createCheckFiles:
                return "Create .synctray-check files required for access check"
            case .forceSync:
                return "Override the 50% deletion safety limit and proceed with sync"
            }
        }
    }

    private func detectErrorAction(from error: String) -> ErrorAction? {
        // Use Smart Fix for most common bisync errors that need orchestrated recovery
        // These errors typically require: unlock → check files → resync

        // Lock file error - just remove lock and retry (no resync needed)
        if error.contains("lock file found") || error.contains("prior lock file") {
            return .unlockAndRetry
        }

        // Missing baseline or out of sync - needs resync
        if error.contains("cannot find prior") || error.contains("--resync") ||
           error.contains("out of sync") || error.contains("resync to recover") {
            return .smartFix
        }

        // File mismatch errors - needs resync
        if error.contains("Path1 file not found") || error.contains("Path2 file not found") ||
           error.contains("not found in Path") {
            return .smartFix
        }

        // Check access failed - need to create check files
        if error.contains("RCLONE_TEST") || error.contains(".synctray-check") ||
           error.contains("check file") || error.contains("Access test failed") {
            return .smartFix
        }

        // Too many deletes - offer force sync to override safety limit
        if error.contains("too many deletes") {
            return .forceSync
        }

        // Generic bisync errors - offer smart fix
        if error.contains("bisync aborted") || error.contains("Failed to bisync") ||
           error.contains("Bisync critical error") {
            return .smartFix
        }

        // Network/transient errors - just retry
        if error.contains("connection") || error.contains("timeout") || error.contains("network") {
            return .retrySync
        }

        // Safety abort after resync - just needs a normal sync to establish baseline
        if error.contains("all files were changed") || error.contains("Safety abort") {
            return .retrySync
        }

        return nil
    }

    private func handleErrorAction(_ action: ErrorAction) {
        switch action {
        case .smartFix:
            runSmartFix()
        case .resync:
            runResync()
        case .unlockAndResync:
            unlockAndResync()
        case .unlockAndRetry:
            unlockAndRetrySync()
        case .unlock:
            removeLockFile()
        case .retrySync:
            syncManager.triggerManualSync(for: profile)
        case .createCheckFiles:
            createCheckFilesAndSync()
        case .forceSync:
            runForceSync()
        }
    }

    private func removeLockFile() {
        let bisyncDir = "\(NSHomeDirectory())/Library/Caches/rclone/bisync"

        // Remove all matching lock files
        if let files = try? FileManager.default.contentsOfDirectory(atPath: bisyncDir) {
            for file in files where file.hasSuffix(".lck") {
                let fullPath = "\(bisyncDir)/\(file)"
                try? FileManager.default.removeItem(atPath: fullPath)
            }
        }
    }

    /// Remove lock files and retry normal sync (no resync needed)
    /// This is used when a previous sync was interrupted and left a stale lock file
    private func unlockAndRetrySync() {
        let fm = FileManager.default

        // Remove SyncTray lock file
        let tmpLockPath = profile.lockFilePath
        if fm.fileExists(atPath: tmpLockPath) {
            try? fm.removeItem(atPath: tmpLockPath)
        }

        // Remove rclone bisync lock files
        let bisyncDir = "\(NSHomeDirectory())/Library/Caches/rclone/bisync"
        if let files = try? fm.contentsOfDirectory(atPath: bisyncDir) {
            for file in files where file.hasSuffix(".lck") {
                let fullPath = "\(bisyncDir)/\(file)"
                try? fm.removeItem(atPath: fullPath)
            }
        }

        // Clear the error and trigger normal sync
        syncManager.clearError(for: profile.id)
        syncManager.triggerManualSync(for: profile)
    }

    /// Run sync with --force flag to override "too many deletes" safety limit
    /// This is used when more than 50% of files would be deleted in a single sync
    private func runForceSync() {
        isRunningResync = true
        resyncOutputLines = []
        showResyncOutput = true

        // Clear any cached error and set syncing state
        syncManager.clearError(for: profile.id)
        syncManager.setSyncing(for: profile.id, isSyncing: true)

        // Capture values from main thread
        let currentProfile = profile
        let capturedRcloneRemote = rcloneRemote
        let capturedRemotePath = remotePath
        let capturedLocalSyncPath = localSyncPath
        let capturedAdditionalFlags = additionalRcloneFlags
        let capturedFilterPath = profile.filterFilePath
        let syncLogPath = profile.logPath
        let capturedMaxLines = maxOutputLines

        appendOutputLine("⚠️ Force Sync: Overriding deletion safety limit...")
        appendOutputLine("This will proceed even though >50% of files would be deleted.")
        appendOutputLine("")

        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default

            // Ensure log directory exists
            let logDir = (syncLogPath as NSString).deletingLastPathComponent
            try? fileManager.createDirectory(atPath: logDir, withIntermediateDirectories: true)

            if !fileManager.fileExists(atPath: syncLogPath) {
                fileManager.createFile(atPath: syncLogPath, contents: nil)
            }

            // Helper to write to log file
            let writeToLog: (String) -> Void = { content in
                if let data = (content + "\n").data(using: .utf8),
                   let handle = FileHandle(forWritingAtPath: syncLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            }

            let process = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()

            // Find rclone
            let rclonePaths = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
            var rclonePath: String?

            for path in rclonePaths {
                if fileManager.fileExists(atPath: path) {
                    rclonePath = path
                    break
                }
            }

            guard let path = rclonePath else {
                let errMsg = "Error: rclone not found. Install with: brew install rclone"
                writeToLog(errMsg)
                DispatchQueue.main.async {
                    self.isRunningResync = false
                    self.resyncOutputLines = [errMsg]
                    self.syncManager.setSyncing(for: currentProfile.id, isSyncing: false)
                }
                return
            }

            // Build sync command with --force flag to override deletion safety
            let fullRemotePath = "\(capturedRcloneRemote):\(capturedRemotePath)"
            var arguments = ["bisync", fullRemotePath, capturedLocalSyncPath, "--force", "--verbose", "--use-json-log", "--stats", "2s"]

            // Add filter file
            if fileManager.fileExists(atPath: capturedFilterPath) {
                arguments.append(contentsOf: ["--filter-from", capturedFilterPath])
            }

            // Add check access
            arguments.append(contentsOf: ["--check-access", "--check-filename", ".synctray-check"])

            // Add resilient recovery options
            arguments.append(contentsOf: ["--resilient", "--recover", "--conflict-resolve", "newer", "--conflict-loser", "num", "--conflict-suffix", "sync-conflict-{DateOnly}-"])

            // Add any user-specified additional flags
            if !capturedAdditionalFlags.isEmpty {
                arguments.append(contentsOf: capturedAdditionalFlags.split(separator: " ").map(String.init))
            }

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = errorPipe

            let startMsg = "Running: \(path) \(arguments.joined(separator: " "))"
            writeToLog(startMsg)
            DispatchQueue.main.async {
                self.appendOutputLine(startMsg)
            }

            // Track output lines
            var outputLineCount = 0

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                for line in output.components(separatedBy: "\n") where !line.isEmpty {
                    writeToLog(line)
                    outputLineCount += 1

                    DispatchQueue.main.async {
                        // Parse JSON for meaningful messages
                        if line.hasPrefix("{"),
                           let jsonData = line.data(using: .utf8),
                           let entry = try? JSONDecoder().decode(RcloneLogEntry.self, from: jsonData) {
                            // Show meaningful messages (not stats)
                            let msg = entry.msg
                            if !msg.contains("stats") && !msg.isEmpty {
                                let cleanMsg = msg.replacingOccurrences(of: #"\u001B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
                                if self.resyncOutputLines.count < capturedMaxLines {
                                    self.resyncOutputLines.append(cleanMsg)
                                }
                            }
                        } else if self.resyncOutputLines.count < capturedMaxLines {
                            self.resyncOutputLines.append(line)
                        }
                    }
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                for line in output.components(separatedBy: "\n") where !line.isEmpty {
                    writeToLog("ERROR: \(line)")
                    DispatchQueue.main.async {
                        if self.resyncOutputLines.count < capturedMaxLines {
                            self.resyncOutputLines.append("⚠️ \(line)")
                        }
                    }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                let errMsg = "Failed to run rclone: \(error.localizedDescription)"
                writeToLog(errMsg)
                DispatchQueue.main.async {
                    self.appendOutputLine(errMsg)
                }
            }

            // Cleanup handlers
            pipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            let exitCode = process.terminationStatus
            let completionMsg = exitCode == 0
                ? "✅ Force sync completed successfully"
                : "❌ Force sync failed with exit code \(exitCode)"
            writeToLog(completionMsg)

            DispatchQueue.main.async {
                self.appendOutputLine("")
                self.appendOutputLine(completionMsg)
                self.isRunningResync = false
                self.syncManager.setSyncing(for: currentProfile.id, isSyncing: false)

                if exitCode == 0 {
                    self.syncManager.clearError(for: currentProfile.id)
                }
            }
        }
    }

    /// Unified smart fix that orchestrates: unlock → verify check files → resync
    private func runSmartFix() {
        isRunningResync = true
        resyncOutputLines = []  // Clear previous output
        showResyncOutput = true

        // Clear any cached error and set syncing state (updates menu bar icon)
        syncManager.clearError(for: profile.id)
        syncManager.setSyncing(for: profile.id, isSyncing: true)

        // Capture values from main thread before going to background
        let localPath = profile.localSyncPath
        let remote = profile.rcloneRemote
        let remoteFolder = profile.remotePath
        let checkFileName = SyncSetupService.checkFileName
        let bisyncDir = "\(NSHomeDirectory())/Library/Caches/rclone/bisync"

        appendOutputLine("🔧 Smart Fix: Resolving sync issues...")
        appendOutputLine("")

        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default

            // Step 1: Remove ALL lock files (both /tmp script lock and rclone bisync .lck files)
            DispatchQueue.main.async {
                self.appendOutputLine("Step 1/3: Removing lock files...")
            }

            var locksRemoved = 0

            // First, remove /tmp script lock file
            let tmpLockPath = self.profile.lockFilePath
            if fileManager.fileExists(atPath: tmpLockPath) {
                if (try? fileManager.removeItem(atPath: tmpLockPath)) != nil {
                    locksRemoved += 1
                    DispatchQueue.main.async {
                        self.appendOutputLine("  ✓ Removed: synctray lock file")
                    }
                }
            }

            // Then remove rclone bisync .lck files
            if let files = try? fileManager.contentsOfDirectory(atPath: bisyncDir) {
                for file in files where file.hasSuffix(".lck") {
                    let fullPath = "\(bisyncDir)/\(file)"
                    if (try? fileManager.removeItem(atPath: fullPath)) != nil {
                        locksRemoved += 1
                        DispatchQueue.main.async {
                            self.appendOutputLine("  ✓ Removed: \(file)")
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                if locksRemoved == 0 {
                    self.appendOutputLine("  ✓ No lock files found")
                }
                self.appendOutputLine("")
            }

            // Step 2: Ensure check files exist
            DispatchQueue.main.async {
                self.appendOutputLine("Step 2/3: Verifying check files...")
            }

            // Check local check file
            let localCheckFile = (localPath as NSString).appendingPathComponent(checkFileName)
            var localCheckExists = fileManager.fileExists(atPath: localCheckFile)

            if !localCheckExists {
                // Try to create it
                if fileManager.createFile(atPath: localCheckFile, contents: nil) {
                    localCheckExists = true
                    DispatchQueue.main.async {
                        self.appendOutputLine("  ✓ Created local .synctray-check file")
                    }
                } else {
                    DispatchQueue.main.async {
                        self.appendOutputLine("  ⚠ Could not create local .synctray-check file")
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.appendOutputLine("  ✓ Local .synctray-check file exists")
                }
            }

            // Find rclone
            let rclonePaths = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
            var rclonePath: String?

            for path in rclonePaths {
                if fileManager.fileExists(atPath: path) {
                    rclonePath = path
                    break
                }
            }

            guard let rclone = rclonePath else {
                DispatchQueue.main.async {
                    self.appendOutputLine("  ✗ rclone not found. Install with: brew install rclone")
                    self.isRunningResync = false
                    self.syncManager.setSyncing(for: self.profile.id, isSyncing: false)
                }
                return
            }

            // Check if remote check file exists using rclone ls
            let remoteCheckPath = "\(remote):\(remoteFolder)/\(checkFileName)"
            let checkProcess = Process()
            let checkPipe = Pipe()

            checkProcess.executableURL = URL(fileURLWithPath: rclone)
            checkProcess.arguments = ["ls", remoteCheckPath]
            checkProcess.standardOutput = checkPipe
            checkProcess.standardError = checkPipe

            var remoteCheckExists = false
            do {
                try checkProcess.run()
                checkProcess.waitUntilExit()
                remoteCheckExists = checkProcess.terminationStatus == 0
            } catch {
                // Assume it doesn't exist
            }

            if !remoteCheckExists {
                // Create remote check file
                let touchProcess = Process()
                let touchPipe = Pipe()

                touchProcess.executableURL = URL(fileURLWithPath: rclone)
                touchProcess.arguments = ["touch", remoteCheckPath]
                touchProcess.standardOutput = touchPipe
                touchProcess.standardError = touchPipe

                do {
                    try touchProcess.run()
                    touchProcess.waitUntilExit()

                    if touchProcess.terminationStatus == 0 {
                        DispatchQueue.main.async {
                            self.appendOutputLine("  ✓ Created remote .synctray-check file")
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.appendOutputLine("  ⚠ Could not create remote .synctray-check file")
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.appendOutputLine("  ⚠ Error creating remote check file: \(error.localizedDescription)")
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.appendOutputLine("  ✓ Remote .synctray-check file exists")
                }
            }

            DispatchQueue.main.async {
                self.appendOutputLine("")
                self.appendOutputLine("Step 3/3: Running resync...")
                self.appendOutputLine("")
            }

            // Small delay to let UI update
            Thread.sleep(forTimeInterval: 0.3)

            // Step 3: Run resync on main thread (uses the existing runResync function)
            DispatchQueue.main.async {
                // Reset the running flag so runResync can set it again
                self.isRunningResync = false
                self.runResync()
            }
        }
    }

    private func unlockAndResync() {
        isRunningResync = true
        resyncOutputLines = ["Removing lock files..."]
        showResyncOutput = true

        // Clear error and set syncing state
        syncManager.clearError(for: profile.id)
        syncManager.setSyncing(for: profile.id, isSyncing: true)

        // Remove lock files first
        let bisyncDir = "\(NSHomeDirectory())/Library/Caches/rclone/bisync"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: bisyncDir) {
            for file in files where file.hasSuffix(".lck") {
                let fullPath = "\(bisyncDir)/\(file)"
                if (try? FileManager.default.removeItem(atPath: fullPath)) != nil {
                    appendOutputLine("Removed: \(file)")
                }
            }
        }

        appendOutputLine("")
        appendOutputLine("Starting resync...")
        appendOutputLine("")

        // Small delay then run resync
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isRunningResync = false
            self.runResync()
        }
    }

    private func createCheckFilesAndSync() {
        isRunningResync = true
        resyncOutputLines = ["Creating check files (.synctray-check)..."]
        showResyncOutput = true

        // Clear error and set syncing state
        syncManager.clearError(for: profile.id)
        syncManager.setSyncing(for: profile.id, isSyncing: true)

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
                self.appendOutputLine("Local path: \(localCheckFile)")
            }

            // Create check file
            if !fileManager.fileExists(atPath: localCheckFile) {
                if !fileManager.createFile(atPath: localCheckFile, contents: nil) {
                    DispatchQueue.main.async {
                        self.appendOutputLine("✗ Failed to create local check file")
                        self.isRunningResync = false
                        self.syncManager.setSyncing(for: self.profile.id, isSyncing: false)
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                self.appendOutputLine("✓ Created local .synctray-check file")
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
                    self.appendOutputLine("✗ rclone not found")
                    self.isRunningResync = false
                    self.syncManager.setSyncing(for: self.profile.id, isSyncing: false)
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
                self.appendOutputLine("Running: rclone touch \"\(remoteDest)\"")
            }

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    if !output.isEmpty {
                        self.appendOutputLine(output)
                    }

                    if process.terminationStatus == 0 {
                        self.appendOutputLine("✓ Created remote .synctray-check file")
                        self.appendOutputLine("")
                        self.appendOutputLine("Now running initial sync (--resync)...")

                        // Run resync after creating files (needed because check-access failure corrupts listing files)
                        self.runResync()
                    } else {
                        self.appendOutputLine("✗ Failed to create remote file (exit code \(process.terminationStatus))")
                        self.isRunningResync = false
                        self.syncManager.setSyncing(for: self.profile.id, isSyncing: false)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.appendOutputLine("✗ Error: \(error.localizedDescription)")
                    self.isRunningResync = false
                    self.syncManager.setSyncing(for: self.profile.id, isSyncing: false)
                }
            }
        }
    }

    // MARK: - Initial Sync Resume Support

    /// Check if there's a running initial sync that we should resume monitoring
    /// Note: SyncManager handles detection and state management via lock file.
    /// This method handles the log tailing UI for initial syncs started by this view.
    private func checkForRunningInitialSync() {
        let syncLogPath = profile.logPath

        // Check if initial log exists (indicates an initial sync was started by this view)
        guard FileManager.default.fileExists(atPath: syncLogPath) else { return }

        // Check if SyncManager detected a running sync for this profile
        // SyncManager uses lock file detection which is more reliable than pgrep
        guard syncManager.state(for: profile.id) == .syncing else {
            // No running sync - clean up stale log file
            try? FileManager.default.removeItem(atPath: syncLogPath)
            return
        }

        // Resume showing the output panel for the initial sync
        isRunningResync = true
        showResyncOutput = true

        // Load existing content and start tailing
        startTailingLogFile(at: syncLogPath)
    }

    /// Start tailing a log file for resumed sync monitoring
    private func startTailingLogFile(at path: String) {
        // Read existing content
        if let existingContent = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = existingContent.components(separatedBy: "\n").filter { !$0.isEmpty }
            resyncOutputLines = Array(lines.suffix(maxOutputLines))
        }

        // Open file for monitoring
        logFileDescriptor = open(path, O_RDONLY)
        guard logFileDescriptor >= 0 else { return }

        // Seek to end of file so we only get new content
        lseek(logFileDescriptor, 0, SEEK_END)

        // Create dispatch source for file changes
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: logFileDescriptor,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global(qos: .userInitiated)
        )

        // Capture the file descriptor for the closures
        let fd = logFileDescriptor

        source.setEventHandler {
            // Read new content
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(fd, &buffer, buffer.count)

            if bytesRead > 0 {
                if let newContent = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                    let lines = newContent.components(separatedBy: "\n").filter { !$0.isEmpty }
                    if !lines.isEmpty {
                        DispatchQueue.main.async { [self] in
                            self.appendOutputLines(lines)
                        }
                    }
                }
            }
        }

        source.setCancelHandler {
            if fd >= 0 {
                close(fd)
            }
        }

        logFileMonitor = source
        source.resume()

        // Also start a timer to check if rclone is still running
        startSyncCompletionMonitor()
    }

    /// Monitor for sync completion (when sync process exits)
    /// Uses lock file check which is more reliable than pgrep
    private func startSyncCompletionMonitor() {
        // Capture needed values for background check
        let lockPath = profile.lockFilePath

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) { [self] in
            // Check if sync is still running via lock file
            let isRunning = self.checkSyncRunningViaLockFile(at: lockPath)

            if !isRunning {
                DispatchQueue.main.async {
                    self.handleResumedSyncCompletion()
                }
            } else {
                // Keep checking
                self.startSyncCompletionMonitor()
            }
        }
    }

    /// Check if sync is running via lock file (can be called from background)
    private func checkSyncRunningViaLockFile(at lockPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: lockPath),
              let pidStr = try? String(contentsOfFile: lockPath, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr) else {
            return false
        }
        // Check if process is still running
        return kill(pid, 0) == 0
    }

    /// Handle completion of a resumed sync
    private func handleResumedSyncCompletion() {
        stopLogFileMonitor()

        // Update state
        appendOutputLine("")
        appendOutputLine("✓ Sync completed")

        isRunningResync = false
        syncManager.setSyncing(for: profile.id, isSyncing: false)
        syncManager.refreshSettings()
    }

    /// Stop the log file monitor
    private func stopLogFileMonitor() {
        logFileMonitor?.cancel()
        logFileMonitor = nil
    }

    /// Write content to the initial sync log file
    private func writeToInitialLog(_ content: String) {
        let logPath = profile.logPath
        let fileManager = FileManager.default

        // Create log directory if needed
        let logDir = (logPath as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: logDir) {
            try? fileManager.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        // Append to log file
        if let data = content.data(using: .utf8) {
            if fileManager.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                fileManager.createFile(atPath: logPath, contents: data)
            }
        }
    }

    /// Truncate log file to keep only the last N lines (prevents unbounded growth)
    private func truncateInitialLogIfNeeded() {
        let logPath = profile.logPath
        let maxLogLines = 100000  // ~10MB of text (increased to reduce truncation frequency)

        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")

        if lines.count > maxLogLines {
            let truncated = lines.suffix(maxLogLines).joined(separator: "\n")
            // Use non-atomic write to preserve inode (prevents LogWatcher from losing track)
            try? truncated.write(toFile: logPath, atomically: false, encoding: .utf8)
        }
    }
}

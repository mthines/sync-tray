import SwiftUI

/// Main setup wizard view for creating new sync profiles or editing existing ones
struct SetupWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profileStore: ProfileStore

    /// Optional profile to edit. If nil, creates a new profile.
    let editingProfile: SyncProfile?

    /// Whether we're in edit mode (reconfiguring an existing profile)
    var isEditMode: Bool { editingProfile != nil }

    // Wizard state
    @State private var currentStep: WizardStep = .welcome
    // Onboarding-funnel bookkeeping (new-profile flow only, not edit mode).
    @State private var didLogWizardStart = false
    @State private var wizardCompleted = false
    @State private var remoteConfig = RemoteConfiguration(name: "", provider: .googleDrive)
    @State private var selectedRemote: String = ""
    @State private var remotePath: String = ""
    @State private var localPath: String = ""
    @State private var profileName: String = ""
    @State private var syncMode: SyncMode = .bisync
    @State private var syncDirection: SyncDirection = .localToRemote
    @State private var syncInterval: Int = 5
    @State private var isExternalDrive: Bool = false

    // UI state
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var isOAuthInProgress: Bool = false
    @State private var wasFirstProfile: Bool = false
    @State private var showingTelemetryDetails: Bool = false

    // Non-empty local folder confirmation (warns about local/remote merge on first sync)
    @State private var showingNonEmptyDirConfirm: Bool = false
    @State private var pendingLocalPath: String = ""
    @State private var pendingLocalItemCount: Int = 0

    // Services
    private let configService = RcloneConfigService.shared

    // MARK: - Initializers

    /// Create wizard for a new profile
    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
        self.editingProfile = nil
    }

    /// Create wizard to edit an existing profile
    init(profileStore: ProfileStore, editing profile: SyncProfile) {
        self.profileStore = profileStore
        self.editingProfile = profile
    }

    enum WizardStep: Int, CaseIterable {
        case welcome = 0
        case provider = 1
        case credentials = 2
        case remotePath = 3
        case localPath = 4
        case syncSettings = 5
        case confirmation = 6
        case helpImprove = 7

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .provider: return "Choose Provider"
            case .credentials: return "Configure Remote"
            case .remotePath: return "Remote Path"
            case .localPath: return "Local Path"
            case .syncSettings: return "Sync Settings"
            case .confirmation: return "Confirm"
            case .helpImprove: return "Help shape SyncTray"
            }
        }

        /// Bounded, low-cardinality id for telemetry (`wizard.abandoned_at_step`).
        var telemetryName: String {
            switch self {
            case .welcome: return "welcome"
            case .provider: return "provider"
            case .credentials: return "credentials"
            case .remotePath: return "remote_path"
            case .localPath: return "local_path"
            case .syncSettings: return "sync_settings"
            case .confirmation: return "confirmation"
            case .helpImprove: return "help_improve"
            }
        }

        var next: WizardStep? {
            WizardStep(rawValue: rawValue + 1)
        }

        var previous: WizardStep? {
            WizardStep(rawValue: rawValue - 1)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            progressIndicator
                .padding(.horizontal)
                .padding(.top)

            Divider()
                .padding(.top, 12)

            // Main content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stepContent
                }
                .padding()
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Navigation buttons
            navigationButtons
                .padding()
        }
        .frame(width: 600, height: 500)
        .onAppear {
            checkRcloneInstallation()
            loadEditingProfile()
            // Onboarding funnel: entry event (new-profile flow only, once per presentation).
            if !isEditMode && !didLogWizardStart {
                didLogWizardStart = true
                TelemetryService.shared.recordWizardStep(outcome: "started")
            }
        }
        .alert("This Folder Is Not Empty", isPresented: $showingNonEmptyDirConfirm) {
            Button("Cancel", role: .cancel) {
                pendingLocalPath = ""
                pendingLocalItemCount = 0
            }
            Button("Use This Folder", role: .destructive) {
                applyLocalPath(pendingLocalPath)
                pendingLocalPath = ""
                pendingLocalItemCount = 0
            }
        } message: {
            Text(nonEmptyDirWarningMessage)
        }
    }

    /// Load values from an existing profile when in edit mode
    private func loadEditingProfile() {
        guard let profile = editingProfile else { return }

        // Pre-populate fields from existing profile
        profileName = profile.name
        selectedRemote = profile.rcloneRemote.hasSuffix(":") ? profile.rcloneRemote : "\(profile.rcloneRemote):"
        remotePath = profile.remotePath
        localPath = profile.localSyncPath
        syncMode = profile.syncMode
        syncDirection = profile.syncDirection
        syncInterval = profile.syncIntervalMinutes
        isExternalDrive = !profile.drivePathToMonitor.isEmpty

        // Skip to remote path step (user already has a remote)
        currentStep = .remotePath
    }

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: 4) {
            ForEach(WizardStep.allCases.filter { $0 != .helpImprove }, id: \.rawValue) { step in
                Circle()
                    .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
        case .provider:
            providerStep
        case .credentials:
            credentialsStep
        case .remotePath:
            remotePathStep
        case .localPath:
            localPathStep
        case .syncSettings:
            syncSettingsStep
        case .confirmation:
            confirmationStep
        case .helpImprove:
            helpImproveStep
        }
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup Wizard")
                .font(.title)
                .fontWeight(.bold)

            Text("This wizard will help you configure a new sync profile. You'll be able to:")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label("Configure a new cloud storage remote", systemImage: "cloud")
                Label("Choose folders to synchronize", systemImage: "folder")
                Label("Set up automatic sync schedules", systemImage: "clock")
            }
            .padding(.vertical)

            if !configService.isRcloneInstalled() {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("rclone not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)

                        Text("Please install rclone to continue:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("brew install rclone")
                            .font(.system(.caption, design: .monospaced))
                            .padding(6)
                            .background(Color.black.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
            } else if let version = configService.getRcloneVersion() {
                Label(version, systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }

            // Option to use existing remote
            if !configService.listRemotes().isEmpty {
                Divider()
                    .padding(.vertical, 8)

                Text("Or use an existing remote:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Existing Remote", selection: $selectedRemote) {
                    Text("Configure new remote").tag("")
                    ForEach(configService.listRemotes(), id: \.self) { remote in
                        Text(remote).tag(remote)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Provider Step

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Storage Provider")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select where you want to sync your files:")
                .foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                ForEach(RemoteProvider.allCases, id: \.id) { provider in
                    ProviderCard(
                        provider: provider,
                        isSelected: remoteConfig.provider == provider
                    ) {
                        remoteConfig = RemoteConfiguration(name: remoteConfig.name, provider: provider)
                    }
                }
            }
        }
    }

    // MARK: - Credentials Step

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure \(remoteConfig.provider.displayName)")
                .font(.title2)
                .fontWeight(.semibold)

            // Remote name
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Name")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("e.g., my-gdrive", text: $remoteConfig.name)
                    .textFieldStyle(.roundedBorder)

                Text("A unique name for this remote (no spaces or colons)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Provider-specific fields
            ProviderFieldsView(config: $remoteConfig)

            // OAuth button for OAuth providers
            if remoteConfig.provider.usesOAuth {
                Divider()

                HStack {
                    if remoteConfig.oauthToken != nil {
                        Label("Authenticated", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button(action: startOAuth) {
                            HStack {
                                if isOAuthInProgress {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "person.badge.key")
                                }
                                Text("Authenticate with \(remoteConfig.provider.displayName)")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isOAuthInProgress)
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Remote Path Step

    private var remotePathStep: some View {
        RemotePathStepView(
            remoteName: selectedRemote.isEmpty ? remoteConfig.name : selectedRemote,
            remotePath: $remotePath,
            configService: configService,
            initialUseCustomPath: isEditMode && !remotePath.isEmpty
        )
    }

    // MARK: - Local Path Step

    private var localPathStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Local Folder")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select the local folder to sync with the remote:")
                .foregroundColor(.secondary)

            HStack {
                TextField("Local folder path", text: $localPath)
                    .textFieldStyle(.roundedBorder)

                Button("Browse...") {
                    browseForFolder()
                }
            }

            Toggle("This is on an external drive", isOn: $isExternalDrive)
                .toggleStyle(.checkbox)

            if isExternalDrive {
                Text("Sync will be skipped when the drive is not mounted")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Profile name
            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Profile Name")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("e.g., Work Documents", text: $profileName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Sync Settings Step

    private var syncSettingsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync Settings")
                .font(.title2)
                .fontWeight(.semibold)

            // Sync mode
            VStack(alignment: .leading, spacing: 8) {
                Text("Sync Mode")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Mode", selection: $syncMode) {
                    ForEach(SyncMode.allCases) { mode in
                        HStack {
                            Image(systemName: mode.iconName)
                            Text(mode.displayName)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(syncMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Direction (only for one-way sync)
            if syncMode == .sync {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sync Direction")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Picker("Direction", selection: $syncDirection) {
                        ForEach(SyncDirection.allCases) { direction in
                            HStack {
                                Image(systemName: direction.iconName)
                                Text(direction.displayName)
                            }
                            .tag(direction)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(syncDirection.description)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if syncDirection == .localToRemote {
                        Label("Remote files not in local will be deleted", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Label("Local files not in remote will be deleted", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            Divider()

            // Sync interval
            VStack(alignment: .leading, spacing: 8) {
                Text("Sync Interval")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("", selection: $syncInterval) {
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Confirmation Step

    private var confirmationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Configuration")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Profile") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Name", value: profileName.isEmpty ? "New Profile" : profileName)
                    LabeledContent("Sync Mode", value: syncMode.displayName)
                    if syncMode == .sync {
                        LabeledContent("Direction", value: syncDirection.displayName)
                    }
                    LabeledContent("Interval", value: "\(syncInterval) minutes")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Remote") {
                VStack(alignment: .leading, spacing: 8) {
                    let remote = selectedRemote.isEmpty ? "\(remoteConfig.name):" : selectedRemote
                    LabeledContent("Remote", value: remote)
                    LabeledContent("Path", value: remotePath.isEmpty ? "/" : remotePath)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Local") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Folder", value: localPath)
                    if isExternalDrive {
                        Label("External drive", systemImage: "externaldrive")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Edit Mode Start Step

    /// The step where edit mode begins. Back navigation is blocked at this step
    /// because the provider/credentials steps are uninitialized in edit mode.
    private var editModeStartStep: WizardStep? {
        isEditMode ? .remotePath : nil
    }

    // MARK: - Help Improve Step

    private var helpImproveStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Help shape SyncTray")
                .font(.title2)
                .fontWeight(.semibold)

            Text("SyncTray is built by one person in his spare time. Anonymous usage data tells me which sync modes people actually use, when syncs fail, and where the app gets stuck — so I can fix real problems instead of guessing.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                // What's sent
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's sent")
                            .font(.subheadline.weight(.medium))
                            .padding(.bottom, 2)
                        Label("Sync mode, success/failure, and duration", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.primary)
                            .labelStyle(ColoredIconLabelStyle(iconColor: .green))
                        Label("Error categories (e.g. \"timeout\", \"network\")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.primary)
                            .labelStyle(ColoredIconLabelStyle(iconColor: .green))
                        Label("Anonymous machine ID — not reversible to you", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.primary)
                            .labelStyle(ColoredIconLabelStyle(iconColor: .green))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)

                // What's never sent
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's never sent")
                            .font(.subheadline.weight(.medium))
                            .padding(.bottom, 2)
                        Label("File names, folder names, or file contents", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.primary)
                            .labelStyle(ColoredIconLabelStyle(iconColor: .red))
                        Label("Remote names, hostnames, or credentials", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.primary)
                            .labelStyle(ColoredIconLabelStyle(iconColor: .red))
                        Label("Your IP address or personal identifiers", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.primary)
                            .labelStyle(ColoredIconLabelStyle(iconColor: .red))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            }

            HStack {
                Button("Learn more") {
                    showingTelemetryDetails = true
                }
                .buttonStyle(.link)

                Spacer()

                Text("— Mads, SyncTray maintainer")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
            }

            Text("You can change this any time in App Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Action buttons — two equal-weight buttons, only tint differs
            HStack(spacing: 12) {
                Button("Share anonymous data") {
                    SyncTraySettings.telemetryEnabled = true
                    SyncTraySettings.telemetryBannerDismissedVersion = SyncTraySettings.currentTelemetryConsentVersion
                    TelemetryService.shared.configure()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button("Not now") {
                    SyncTraySettings.telemetryBannerDismissedVersion = SyncTraySettings.currentTelemetryConsentVersion
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.secondary)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingTelemetryDetails) {
            TelemetryDetailsSheet()
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            Button("Cancel") {
                if currentStep == .helpImprove {
                    SyncTraySettings.telemetryBannerDismissedVersion = SyncTraySettings.currentTelemetryConsentVersion
                }
                // Onboarding funnel: abandonment, tagged with the step they quit on.
                if !isEditMode && !wizardCompleted && currentStep != .helpImprove {
                    TelemetryService.shared.recordWizardStep(
                        outcome: "abandoned",
                        abandonedAtStep: currentStep.telemetryName
                    )
                }
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            // Hide Back when at the starting step in edit mode (provider/credentials uninitialized)
            // Also hide Back on the .helpImprove epilogue step
            if currentStep.previous != nil && currentStep != editModeStartStep && currentStep != .helpImprove {
                Button("Back") {
                    withAnimation {
                        currentStep = currentStep.previous!
                    }
                }
            }

            if currentStep != .helpImprove {
                if currentStep == .confirmation {
                    Button(isEditMode ? "Save Changes" : "Create Profile") {
                        saveProfile()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)
                } else if let nextStep = currentStep.next {
                    Button("Next") {
                        advanceToNextStep(nextStep)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
                }
            }
        }
    }

    // MARK: - Validation

    private var canAdvance: Bool {
        switch currentStep {
        case .welcome:
            return configService.isRcloneInstalled()
        case .provider:
            return true
        case .credentials:
            if selectedRemote.isEmpty {
                let errors = remoteConfig.validate()
                return errors.isEmpty
            }
            return true
        case .remotePath:
            return !remotePath.isEmpty || selectedRemote.isEmpty == false
        case .localPath:
            return !localPath.isEmpty
        case .syncSettings:
            return true
        case .confirmation:
            return true
        case .helpImprove:
            return true
        }
    }

    // MARK: - Actions

    private func checkRcloneInstallation() {
        // Already handled in welcome step view
    }

    private func advanceToNextStep(_ nextStep: WizardStep) {
        errorMessage = nil

        // Onboarding funnel: capture the chosen provider as the user leaves the provider step.
        if currentStep == .provider && !isEditMode {
            TelemetryService.shared.recordWizardStep(
                outcome: "provider_selected",
                providerType: remoteConfig.provider.rcloneType
            )
        }

        // Skip credentials step if using existing remote
        if currentStep == .welcome && !selectedRemote.isEmpty {
            withAnimation {
                currentStep = .remotePath
            }
            return
        }

        // Create remote if on credentials step
        if currentStep == .credentials && selectedRemote.isEmpty {
            createRemote {
                withAnimation {
                    currentStep = nextStep
                }
            }
            return
        }

        withAnimation {
            currentStep = nextStep
        }
    }

    private func startOAuth() {
        isOAuthInProgress = true
        errorMessage = nil

        let providerType = remoteConfig.provider.rcloneType
        configService.startOAuthFlow(for: remoteConfig.provider) { result in
            isOAuthInProgress = false
            switch result {
            case .success(let token):
                remoteConfig.oauthToken = token
                TelemetryService.shared.recordOAuthOutcome(result: "success", providerType: providerType)
            case .failure(let error):
                errorMessage = error.localizedDescription
                TelemetryService.shared.recordOAuthOutcome(result: "failure", providerType: providerType)
            }
        }
    }

    private func createRemote(completion: @escaping () -> Void) {
        isLoading = true
        errorMessage = nil

        do {
            try configService.addRemote(remoteConfig)
            selectedRemote = "\(remoteConfig.name):"
            isLoading = false
            TelemetryService.shared.recordRemoteConfigOperation(
                operation: "create",
                providerType: remoteConfig.provider.rcloneType,
                result: "success"
            )
            completion()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            TelemetryService.shared.recordRemoteConfigOperation(
                operation: "create",
                providerType: remoteConfig.provider.rcloneType,
                result: "failure",
                errorMessage: error.localizedDescription
            )
        }
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            let count = SyncProfile.meaningfulItemCount(at: path)
            // Re-selecting the folder that's already configured (edit mode) is expected to
            // hold synced files — only warn when pointing at a *different* non-empty folder.
            if count > 0 && path != editingProfile?.localSyncPath {
                pendingLocalPath = path
                pendingLocalItemCount = count
                showingNonEmptyDirConfirm = true
            } else {
                applyLocalPath(path)
            }
        }
    }

    /// Gate: wasFirstProfile must be set as the FIRST statement, before profileStore.add() changes the count.
    private var shouldShowHelpImproveStep: Bool {
        wasFirstProfile
            && !isEditMode
            && !SyncTraySettings.telemetryEnabled
            && !SyncTraySettings.telemetryBannerDismissed
    }

    /// Applies a chosen local folder path along with its derived side effects
    /// (external-drive detection, default profile name).
    private func applyLocalPath(_ path: String) {
        localPath = path
        // Auto-detect external drive
        if path.hasPrefix("/Volumes/") {
            isExternalDrive = true
        }
        // Auto-generate profile name from folder
        if profileName.isEmpty {
            profileName = URL(fileURLWithPath: path).lastPathComponent
        }
    }

    /// Detailed warning shown when a user points the sync at a folder that already
    /// contains files. The sync mode/direction is chosen on a later step, so the copy
    /// stays mode-agnostic and names the folder rather than assuming a specific behaviour.
    private var nonEmptyDirWarningMessage: String {
        let count = pendingLocalItemCount
        let itemWord = count == 1 ? "item" : "items"
        let folderName = URL(fileURLWithPath: pendingLocalPath).lastPathComponent
        return """
        \"\(folderName)\" already contains \(count) \(itemWord).

        On the first sync, these files are combined with the remote. Depending on the sync mode and direction you choose next, files can be uploaded, overwritten, or deleted on either side — which can be hard to undo.

        Only continue if that's what you intend.
        """
    }

    private func saveProfile() {
        // Capture BEFORE profileStore.add() changes the count
        wasFirstProfile = profileStore.profiles.isEmpty

        isLoading = true
        errorMessage = nil

        let remoteName = selectedRemote.isEmpty ? remoteConfig.name : selectedRemote.replacingOccurrences(of: ":", with: "")

        // Detect drive path for external drives
        var drivePath = ""
        if isExternalDrive {
            let pathComponents = localPath.split(separator: "/")
            if pathComponents.count >= 2 && pathComponents[0] == "Volumes" {
                drivePath = "/Volumes/\(pathComponents[1])"
            }
        }

        var profileToInstall: SyncProfile

        if let existingProfile = editingProfile {
            // Update existing profile
            var updatedProfile = existingProfile
            updatedProfile.name = profileName.isEmpty ? existingProfile.name : profileName
            updatedProfile.rcloneRemote = remoteName
            updatedProfile.remotePath = remotePath
            updatedProfile.localSyncPath = localPath
            updatedProfile.drivePathToMonitor = drivePath
            updatedProfile.syncIntervalMinutes = syncInterval
            updatedProfile.syncMode = syncMode
            updatedProfile.syncDirection = syncDirection

            profileStore.update(updatedProfile)
            profileToInstall = updatedProfile
        } else {
            // Create new profile
            let profile = SyncProfile(
                name: profileName.isEmpty ? "New Profile" : profileName,
                rcloneRemote: remoteName,
                remotePath: remotePath,
                localSyncPath: localPath,
                drivePathToMonitor: drivePath,
                syncIntervalMinutes: syncInterval,
                syncMode: syncMode,
                syncDirection: syncDirection
            )

            profileStore.add(profile)
            profileToInstall = profile

            // Onboarding funnel: completion (new-profile flow only).
            wizardCompleted = true
            TelemetryService.shared.recordWizardStep(
                outcome: "created",
                providerType: remoteConfig.provider.rcloneType
            )
        }

        // Automatically install the scheduled sync
        do {
            try SyncSetupService.shared.install(profile: profileToInstall)
        } catch {
            print("Failed to install scheduled sync: \(error)")
            // Don't block - the user can manually install from settings
        }

        isLoading = false
        if shouldShowHelpImproveStep {
            withAnimation {
                currentStep = .helpImprove
            }
        } else {
            dismiss()
        }
    }
}

// MARK: - Colored Icon Label Style

private struct ColoredIconLabelStyle: LabelStyle {
    let iconColor: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .foregroundStyle(iconColor)
            configuration.title
                .font(.caption)
        }
    }
}

// MARK: - Provider Card

struct ProviderCard: View {
    let provider: RemoteProvider
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: provider.iconName)
                    .font(.title)
                    .frame(height: 30)

                Text(provider.displayName)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    SetupWizardView(profileStore: ProfileStore())
}

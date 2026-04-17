import SwiftUI

/// A sheet for creating or editing a rclone remote with connection testing.
/// Reuses the provider grid, credential fields, and connection test from the setup wizard.
struct AddRemoteSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called with the new remote name (with trailing colon) after successful creation.
    var onRemoteCreated: (String) -> Void

    /// When non-nil, the sheet is in edit mode for this remote name.
    var editingRemoteName: String?

    /// Called after a successful edit (passes the remote name).
    var onRemoteUpdated: ((String) -> Void)?

    /// Whether we are editing an existing remote.
    private var isEditMode: Bool { editingRemoteName != nil }

    // Wizard state
    @State private var step: Step = .provider
    @State private var remoteConfig = RemoteConfiguration(name: "", provider: .googleDrive)
    @State private var remotePath: String = ""
    @State private var isLoading: Bool = false
    @State private var isOAuthInProgress: Bool = false
    @State private var errorMessage: String?

    private let configService = RcloneConfigService.shared

    // MARK: - Initializers

    /// Create sheet for adding a new remote.
    init(onRemoteCreated: @escaping (String) -> Void) {
        self.onRemoteCreated = onRemoteCreated
        self.editingRemoteName = nil
        self.onRemoteUpdated = nil
    }

    /// Create sheet for editing an existing remote.
    init(editing remoteName: String, onRemoteUpdated: @escaping (String) -> Void) {
        self.editingRemoteName = remoteName
        self.onRemoteUpdated = onRemoteUpdated
        self.onRemoteCreated = { _ in }
    }

    enum Step: Int, CaseIterable {
        case provider = 0
        case credentials = 1
        case connectionTest = 2

        var title: String {
            switch self {
            case .provider: return "Provider"
            case .credentials: return "Configure"
            case .connectionTest: return "Test"
            }
        }
    }

    /// Steps shown in the progress indicator (edit mode skips provider)
    private var visibleSteps: [Step] {
        isEditMode ? [.credentials, .connectionTest] : Step.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 4) {
                ForEach(visibleSteps, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)

            // Header
            HStack {
                Text(headerTitle)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .provider:
                        providerContent
                    case .credentials:
                        credentialsContent
                    case .connectionTest:
                        connectionTestContent
                    }
                }
                .padding()
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Buttons
            navigationButtons
                .padding()
        }
        .frame(width: 550, height: 480)
        .onAppear {
            if isEditMode {
                loadExistingRemote()
            }
        }
    }

    private var headerTitle: String {
        switch step {
        case .provider:
            return "Choose Provider"
        case .credentials:
            if isEditMode {
                return "Edit Remote"
            }
            return "Configure \(remoteConfig.provider.displayName)"
        case .connectionTest:
            return "Test Connection"
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            // Back button
            if step == .credentials && !isEditMode {
                Button("Back") {
                    withAnimation { step = .provider }
                }
            } else if step == .connectionTest {
                Button("Back") {
                    withAnimation { step = .credentials }
                }
            }

            // Forward button
            Button(actionButtonLabel) {
                handleActionButton()
            }
            .buttonStyle(.borderedProminent)
            .disabled(actionButtonDisabled)
        }
    }

    private var actionButtonLabel: String {
        switch step {
        case .provider:
            return "Next"
        case .credentials:
            return "Next"
        case .connectionTest:
            return "Done"
        }
    }

    private var actionButtonDisabled: Bool {
        if step == .credentials && !canSave { return true }
        if isLoading { return true }
        return false
    }

    private func handleActionButton() {
        switch step {
        case .provider:
            withAnimation { step = .credentials }
        case .credentials:
            if isEditMode {
                updateRemote {
                    withAnimation { step = .connectionTest }
                }
            } else {
                createRemote {
                    withAnimation { step = .connectionTest }
                }
            }
        case .connectionTest:
            dismiss()
        }
    }

    // MARK: - Provider Step

    private var providerContent: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 12) {
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

    // MARK: - Credentials Step

    private var credentialsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Name")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if isEditMode {
                    Text(remoteConfig.name)
                        .font(.body)
                        .padding(.vertical, 4)
                    Text("Remote name cannot be changed. Delete and re-create to rename.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    TextField("e.g., my-nas", text: $remoteConfig.name)
                        .textFieldStyle(.roundedBorder)
                    Text("A unique name for this remote (no spaces or colons)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            ProviderFieldsView(config: $remoteConfig)

            if remoteConfig.provider.usesOAuth {
                Divider()
                HStack {
                    if remoteConfig.oauthToken != nil {
                        Label("Authenticated", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Button("Re-authenticate") {
                            remoteConfig.oauthToken = nil
                        }
                        .font(.caption)
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

    // MARK: - Connection Test Step

    private var connectionTestContent: some View {
        RemotePathStepView(
            remoteName: "\(remoteConfig.name):",
            remotePath: $remotePath,
            configService: configService
        )
    }

    // MARK: - Validation

    private var canSave: Bool {
        if isEditMode {
            guard !remoteConfig.name.isEmpty else { return false }
            return remoteConfig.validate().filter { !$0.localizedCaseInsensitiveContains("name") }.isEmpty
        }
        return remoteConfig.validate().isEmpty
    }

    // MARK: - Actions

    private func loadExistingRemote() {
        step = .credentials
        guard let remoteName = editingRemoteName,
              let existing = configService.readRemoteConfig(name: remoteName) else {
            errorMessage = "Could not load remote configuration for \"\(editingRemoteName ?? "unknown")\""
            return
        }
        remoteConfig = existing
    }

    private func startOAuth() {
        isOAuthInProgress = true
        errorMessage = nil

        configService.startOAuthFlow(for: remoteConfig.provider) { result in
            isOAuthInProgress = false
            switch result {
            case .success(let token):
                remoteConfig.oauthToken = token
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createRemote(onSuccess: @escaping () -> Void) {
        isLoading = true
        errorMessage = nil

        let capturedConfig = remoteConfig
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try configService.addRemote(capturedConfig)
                let remoteName = "\(capturedConfig.name):"
                DispatchQueue.main.async {
                    isLoading = false
                    TelemetryService.shared.recordRemoteConfigOperation(
                        operation: "create",
                        providerType: capturedConfig.provider.rcloneType,
                        result: "success"
                    )
                    onRemoteCreated(remoteName)
                    onSuccess()
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    TelemetryService.shared.recordRemoteConfigOperation(
                        operation: "create",
                        providerType: capturedConfig.provider.rcloneType,
                        result: "failure",
                        errorMessage: error.localizedDescription
                    )
                }
            }
        }
    }

    private func updateRemote(onSuccess: @escaping () -> Void) {
        isLoading = true
        errorMessage = nil

        let capturedConfig = remoteConfig
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try configService.updateRemote(capturedConfig)
                DispatchQueue.main.async {
                    isLoading = false
                    TelemetryService.shared.recordRemoteConfigOperation(
                        operation: "update",
                        providerType: capturedConfig.provider.rcloneType,
                        result: "success"
                    )
                    onRemoteUpdated?(capturedConfig.name)
                    onSuccess()
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    TelemetryService.shared.recordRemoteConfigOperation(
                        operation: "update",
                        providerType: capturedConfig.provider.rcloneType,
                        result: "failure",
                        errorMessage: error.localizedDescription
                    )
                }
            }
        }
    }
}

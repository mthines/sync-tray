import SwiftUI

/// A lightweight sheet for creating or editing a rclone remote.
/// Reuses the provider grid and credential fields from the full setup wizard.
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

    enum Step {
        case provider
        case credentials
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if isEditMode {
                    Text("Edit Remote")
                        .font(.headline)
                } else {
                    Text(step == .provider ? "Choose Provider" : "Configure \(remoteConfig.provider.displayName)")
                        .font(.headline)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if step == .provider {
                        providerContent
                    } else {
                        credentialsContent
                    }
                }
                .padding()
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                // Show Back only in create mode (edit mode starts at credentials)
                if step == .credentials && !isEditMode {
                    Button("Back") {
                        withAnimation { step = .provider }
                    }
                }

                Button(actionButtonLabel) {
                    if step == .provider {
                        withAnimation { step = .credentials }
                    } else if isEditMode {
                        updateRemote()
                    } else {
                        createRemote()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(step == .credentials && !canSave)
            }
            .padding()
        }
        .frame(width: 500, height: 420)
        .onAppear {
            if isEditMode {
                loadExistingRemote()
            }
        }
    }

    private var actionButtonLabel: String {
        if step == .provider { return "Next" }
        if isEditMode { return "Save Changes" }
        return "Create Remote"
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
                    // Name is immutable in edit mode — rename requires delete + recreate
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

    // MARK: - Validation

    private var canSave: Bool {
        if isEditMode {
            // In edit mode the remote name is fixed and already populated, so we
            // validate only the credential fields (not the name field). Any
            // validation error that is solely about a missing/invalid name is
            // irrelevant here because the name cannot be changed.
            guard !remoteConfig.name.isEmpty else { return false }
            return remoteConfig.validate().filter { !$0.localizedCaseInsensitiveContains("name") }.isEmpty
        }
        return remoteConfig.validate().isEmpty
    }

    // MARK: - Actions

    private func loadExistingRemote() {
        // Always advance to credentials step so the error message is visible to the user.
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

    private func createRemote() {
        isLoading = true
        errorMessage = nil

        let capturedConfig = remoteConfig
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try configService.addRemote(capturedConfig)
                let remoteName = "\(capturedConfig.name):"
                DispatchQueue.main.async {
                    isLoading = false
                    onRemoteCreated(remoteName)
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func updateRemote() {
        isLoading = true
        errorMessage = nil

        let capturedConfig = remoteConfig
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try configService.updateRemote(capturedConfig)
                DispatchQueue.main.async {
                    isLoading = false
                    onRemoteUpdated?(capturedConfig.name)
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

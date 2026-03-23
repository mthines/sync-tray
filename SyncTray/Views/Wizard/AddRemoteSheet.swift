import SwiftUI

/// A lightweight sheet for creating a new rclone remote.
/// Reuses the provider grid and credential fields from the full setup wizard.
struct AddRemoteSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called with the new remote name (with trailing colon) after successful creation.
    var onRemoteCreated: (String) -> Void

    // Wizard state
    @State private var step: Step = .provider
    @State private var remoteConfig = RemoteConfiguration(name: "", provider: .googleDrive)
    @State private var isLoading: Bool = false
    @State private var isOAuthInProgress: Bool = false
    @State private var errorMessage: String?

    private let configService = RcloneConfigService.shared

    enum Step {
        case provider
        case credentials
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(step == .provider ? "Choose Provider" : "Configure \(remoteConfig.provider.displayName)")
                    .font(.headline)
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

                if step == .credentials {
                    Button("Back") {
                        withAnimation { step = .provider }
                    }
                }

                Button(step == .provider ? "Next" : "Create Remote") {
                    if step == .provider {
                        withAnimation { step = .credentials }
                    } else {
                        createRemote()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(step == .credentials && !canCreate)
            }
            .padding()
        }
        .frame(width: 500, height: 420)
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
                TextField("e.g., my-nas", text: $remoteConfig.name)
                    .textFieldStyle(.roundedBorder)
                Text("A unique name for this remote (no spaces or colons)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            ProviderFieldsView(config: $remoteConfig)

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

    // MARK: - Validation

    private var canCreate: Bool {
        remoteConfig.validate().isEmpty
    }

    // MARK: - Actions

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

        do {
            try configService.addRemote(remoteConfig)
            let remoteName = "\(remoteConfig.name):"
            isLoading = false
            onRemoteCreated(remoteName)
            dismiss()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

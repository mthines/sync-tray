import SwiftUI

/// Dynamic form fields for provider-specific configuration
struct ProviderFieldsView: View {
    @Binding var config: RemoteConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Required fields
            ForEach(config.provider.requiredFields) { field in
                if field.type != .hidden {
                    fieldView(for: field)
                }
            }

            // Optional fields (collapsible)
            if !config.provider.optionalFields.isEmpty {
                DisclosureGroup("Advanced Options") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(config.provider.optionalFields) { field in
                            fieldView(for: field)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldView(for field: ProviderField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            switch field.type {
            case .text:
                TextField(field.placeholder ?? "", text: binding(for: field.key))
                    .textFieldStyle(.roundedBorder)

            case .password:
                SecureField(field.placeholder ?? "", text: binding(for: field.key))
                    .textFieldStyle(.roundedBorder)

            case .number:
                TextField(field.placeholder ?? "", text: binding(for: field.key))
                    .textFieldStyle(.roundedBorder)

            case .dropdown:
                if let options = field.options {
                    Picker(field.label, selection: binding(for: field.key)) {
                        ForEach(options) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

            case .file:
                HStack {
                    TextField(field.placeholder ?? "", text: binding(for: field.key))
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        browseForFile(field: field)
                    }
                }

            case .hidden:
                EmptyView()
            }

            if let helpText = field.helpText {
                Text(helpText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { config.values[key] ?? "" },
            set: { config.values[key] = $0 }
        )
    }

    private func browseForFile(field: ProviderField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"

        // For SSH keys, start in ~/.ssh
        if field.key == "key_file" {
            panel.directoryURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.ssh")
        }

        if panel.runModal() == .OK, let url = panel.url {
            config.values[field.key] = url.path
        }
    }
}

// MARK: - Remote Path Step View

struct RemotePathStepView: View {
    let remoteName: String
    @Binding var remotePath: String
    let configService: RcloneConfigService

    @State private var availableFolders: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var useTextInput: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Remote Folder")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select a folder on \(remoteName) to sync:")
                .foregroundColor(.secondary)

            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading folders...")
                        .foregroundColor(.secondary)
                }
            } else if let error = errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)

                    Button("Retry") {
                        loadFolders()
                    }
                }
            } else if useTextInput || availableFolders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("e.g., Documents/Sync", text: $remotePath)
                        .textFieldStyle(.roundedBorder)

                    if !availableFolders.isEmpty {
                        Button("Show folder list") {
                            useTextInput = false
                        }
                        .font(.caption)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Folder", selection: $remotePath) {
                        Text("Root (/)").tag("")
                        ForEach(availableFolders, id: \.self) { folder in
                            Text(folder).tag(folder)
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Enter custom path") {
                        useTextInput = true
                    }
                    .font(.caption)
                }
            }

            // Test connection button
            if !remotePath.isEmpty {
                Divider()

                Button(action: testConnection) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle")
                        }
                        Text("Test Connection")
                    }
                }
                .disabled(isLoading)
            }
        }
        .onAppear {
            loadFolders()
        }
    }

    private func loadFolders() {
        isLoading = true
        errorMessage = nil

        Task {
            let result = await configService.listFolders(remote: remoteName)
            await MainActor.run {
                isLoading = false
                switch result {
                case .success(let folders):
                    availableFolders = folders
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func testConnection() {
        isLoading = true
        errorMessage = nil

        let fullPath = remotePath.isEmpty ? remoteName : "\(remoteName.replacingOccurrences(of: ":", with: "")):\(remotePath)"

        Task {
            let result = await configService.testConnection(fullPath)
            await MainActor.run {
                isLoading = false
                switch result {
                case .success:
                    errorMessage = nil
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ProviderFieldsView(config: .constant(RemoteConfiguration(name: "test", provider: .synology)))
        .padding()
        .frame(width: 400)
}

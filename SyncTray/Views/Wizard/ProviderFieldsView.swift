import SwiftUI

/// Dynamic form fields for provider-specific configuration
struct ProviderFieldsView: View {
    @Binding var config: RemoteConfiguration
    @State private var advancedExpanded: Bool = false

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
                DisclosureGroup(isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(config.provider.optionalFields) { field in
                            fieldView(for: field)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced Options")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { advancedExpanded.toggle() }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldView(for field: ProviderField) -> some View {
        if field.type == .boolean {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(field.label, isOn: boolBinding(for: field.key))
                    .toggleStyle(.checkbox)

                if let helpText = field.helpText {
                    Text(helpText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } else {
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

                case .hidden, .boolean:
                    EmptyView()
                }

                if let helpText = field.helpText {
                    Text(helpText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { config.values[key] ?? "" },
            set: { config.values[key] = $0 }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { config.values[key] == "true" },
            set: { config.values[key] = $0 ? "true" : "" }
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

    /// When true, start in custom text input mode instead of folder picker.
    /// Use this in edit mode when the existing path may not match any folder from lsd.
    var initialUseCustomPath: Bool = false

    @State private var availableFolders: [String] = []
    @State private var isLoading: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var errorMessage: String?
    @State private var connectionTestSuccess: Bool = false
    @State private var useTextInput: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Remote Folder")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select a folder on \(remoteName) to sync:")
                .foregroundColor(.secondary)

            // Path input - always visible
            pathInputSection

            // Connection test button and status
            connectionTestSection

            // Error/success messages shown inline
            statusMessageSection
        }
        .onAppear {
            if initialUseCustomPath {
                useTextInput = true
            }
            loadFolders()
        }
    }

    @ViewBuilder
    private var pathInputSection: some View {
        if isLoading {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading folders...")
                    .foregroundColor(.secondary)
            }
        } else if useTextInput || availableFolders.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                TextField("e.g., Documents/Sync", text: $remotePath)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: remotePath) { _ in
                        // Clear status when path changes
                        connectionTestSuccess = false
                        if errorMessage?.contains("Connection") == true {
                            errorMessage = nil
                        }
                    }

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
                .onChange(of: remotePath) { _ in
                    connectionTestSuccess = false
                    if errorMessage?.contains("Connection") == true {
                        errorMessage = nil
                    }
                }

                Button("Enter custom path") {
                    useTextInput = true
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var connectionTestSection: some View {
        HStack(spacing: 12) {
            Button(action: testConnection) {
                HStack {
                    if isTestingConnection {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle")
                    }
                    Text("Test Connection")
                }
            }
            .disabled(isTestingConnection)

            if let error = errorMessage, error.contains("Connection") || error.contains("ERROR") {
                Button("Retry") {
                    testConnection()
                }
            }
        }
    }

    @ViewBuilder
    private var statusMessageSection: some View {
        if connectionTestSuccess {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Connection successful")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        } else if let error = errorMessage {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(cleanErrorMessage(error))
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Clean up rclone error messages for display
    private func cleanErrorMessage(_ message: String) -> String {
        // Remove timestamps like "2026/03/08 08:22:40"
        var cleaned = message
            .replacingOccurrences(of: #"\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} "#, with: "", options: .regularExpression)

        // Remove "ERROR :" prefix
        cleaned = cleaned.replacingOccurrences(of: "ERROR : ", with: "")
        cleaned = cleaned.replacingOccurrences(of: "NOTICE: ", with: "")

        // Take just the first meaningful line if there are duplicates
        let lines = cleaned.components(separatedBy: "\n")
        if let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return firstLine.trimmingCharacters(in: .whitespaces)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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
        isTestingConnection = true
        errorMessage = nil
        connectionTestSuccess = false

        let fullPath = remotePath.isEmpty ? remoteName : "\(remoteName.replacingOccurrences(of: ":", with: "")):\(remotePath)"
        let remoteNameClean = remoteName.replacingOccurrences(of: ":", with: "")

        Task {
            let result = await configService.testConnection(fullPath)
            // Resolve provider type for telemetry (low-cardinality, no PII)
            let providerType = configService.readRemoteConfig(name: remoteNameClean)?.provider.rcloneType ?? "unknown"

            await MainActor.run {
                isTestingConnection = false
                switch result {
                case .success:
                    connectionTestSuccess = true
                    errorMessage = nil
                    TelemetryService.shared.recordRemoteConfigOperation(
                        operation: "connection_test",
                        providerType: providerType,
                        result: "success"
                    )
                case .failure(let error):
                    connectionTestSuccess = false
                    errorMessage = "Connection failed: \(error.localizedDescription)"
                    TelemetryService.shared.recordRemoteConfigOperation(
                        operation: "connection_test",
                        providerType: providerType,
                        result: "failure",
                        errorMessage: error.localizedDescription
                    )
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

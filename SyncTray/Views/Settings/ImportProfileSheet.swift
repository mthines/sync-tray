import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sheet that drives the import flow for a `.synctrayprofile` file.
///
/// Stages:
/// 1. Show summary of what's in the file
/// 2. Resolve remote name conflicts (reuse existing or create with new name)
/// 3. Collect required credentials + local sync path
/// 4. Optionally test connection, then create the profile
struct ImportProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profileStore: ProfileStore

    /// Called with the new profile id after successful import. Allows the caller to navigate to it.
    var onImported: ((UUID) -> Void)?

    let shared: SharedProfile

    // MARK: - State

    /// Editable copy of the primary remote (with credentials filled in).
    @State private var primaryRemote: RemoteConfiguration?
    /// User-chosen action for the primary remote (create vs reuse existing).
    @State private var primaryRemoteAction: RemoteActionChoice = .createNew

    /// Editable copy of the fallback remote, if present.
    @State private var fallbackRemote: RemoteConfiguration?
    @State private var fallbackRemoteAction: RemoteActionChoice = .createNew

    /// Local sync path (recipient's machine).
    @State private var localSyncPath: String = ""
    @State private var isExternalDrive: Bool = false

    @State private var errorMessage: String?
    @State private var isTestingPrimary: Bool = false
    @State private var primaryTestPassed: Bool = false
    @State private var isImporting: Bool = false
    @State private var isOAuthInProgress: Bool = false

    /// User-chosen new profile name (defaults to a unique variant of the imported name).
    @State private var profileName: String = ""

    // Cached at init
    @State private var existingRemoteNames: [String] = []

    private let configService = RcloneConfigService.shared
    private let shareService = ProfileShareService.shared

    enum RemoteActionChoice: Hashable {
        case createNew
        case reuseExisting
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summarySection
                    if shared.profile != nil {
                        Divider()
                        profileNameSection
                    }
                    if shared.remote != nil {
                        Divider()
                        remoteSection(
                            label: "Primary Remote",
                            config: $primaryRemote,
                            action: $primaryRemoteAction,
                            existingNames: existingRemoteNames,
                            isPrimary: true,
                            testInProgress: $isTestingPrimary,
                            testPassed: $primaryTestPassed
                        )
                    }
                    if shared.fallbackRemote != nil {
                        Divider()
                        remoteSection(
                            label: "Fallback Remote",
                            config: $fallbackRemote,
                            action: $fallbackRemoteAction,
                            existingNames: existingRemoteNames,
                            isPrimary: false,
                            testInProgress: .constant(false),
                            testPassed: .constant(false)
                        )
                    }
                    Divider()
                    localPathSection
                    if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer.padding()
        }
        .frame(width: 620, height: 640)
        .onAppear(perform: load)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Shared Configuration")
                    .font(.headline)
                Text(shared.profile?.name ?? "New Profile")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Summary

    private var summarySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let body = shared.profile {
                    summaryRow("Sync Mode", value: body.syncMode.displayName)
                    if body.syncMode == .sync {
                        summaryRow("Direction", value: body.syncDirection.displayName)
                    }
                    summaryRow("Schedule", value: "Every \(body.syncIntervalMinutes) min")
                    summaryRow("Remote Folder", value: body.remotePath.isEmpty ? "/" : body.remotePath)
                }
                if let r = shared.remote {
                    summaryRow("Primary Remote", value: "\(r.name) (\(r.provider.displayName))")
                }
                if let r = shared.fallbackRemote {
                    summaryRow("Fallback Remote", value: "\(r.name) (\(r.provider.displayName))")
                }
                if shared.excludeFilter != nil {
                    summaryRow("Exclude Filter", value: "Included")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Contents", systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    // MARK: - Profile name

    private var profileNameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Profile Name", systemImage: "tag")
                .font(.subheadline.weight(.semibold))
            TextField("Profile name", text: $profileName)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Remote section

    @ViewBuilder
    private func remoteSection(
        label: String,
        config: Binding<RemoteConfiguration?>,
        action: Binding<RemoteActionChoice>,
        existingNames: [String],
        isPrimary: Bool,
        testInProgress: Binding<Bool>,
        testPassed: Binding<Bool>
    ) -> some View {
        if let cfgValue = config.wrappedValue {
            VStack(alignment: .leading, spacing: 10) {
                Label(label, systemImage: "server.rack")
                    .font(.subheadline.weight(.semibold))

                let nameClashes = existingNames.contains(cfgValue.name)

                if nameClashes {
                    Picker("", selection: action) {
                        Text("Use my existing remote \"\(cfgValue.name)\"").tag(RemoteActionChoice.reuseExisting)
                        Text("Import as a new remote").tag(RemoteActionChoice.createNew)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                if !nameClashes || action.wrappedValue == .createNew {
                    importableRemoteEditor(
                        config: config,
                        existingNames: existingNames,
                        isPrimary: isPrimary,
                        testInProgress: testInProgress,
                        testPassed: testPassed,
                        nameClashes: nameClashes
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func importableRemoteEditor(
        config: Binding<RemoteConfiguration?>,
        existingNames: [String],
        isPrimary: Bool,
        testInProgress: Binding<Bool>,
        testPassed: Binding<Bool>,
        nameClashes: Bool
    ) -> some View {
        if let cfgValue = config.wrappedValue {
            VStack(alignment: .leading, spacing: 10) {
                // Editable name (only matters when creating)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g., my-nas", text: nameBinding(for: config))
                        .textFieldStyle(.roundedBorder)
                    if nameClashes {
                        Text("\"\(cfgValue.name)\" already exists locally — pick a unique name.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // Provider field editor (required + optional). Reuses the wizard's logic.
                ProviderFieldsView(config: configBinding(config))

                if cfgValue.provider.usesOAuth, isPrimary {
                    HStack {
                        if cfgValue.oauthToken != nil {
                            Label("Authenticated", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Re-authenticate") {
                                config.wrappedValue?.oauthToken = nil
                            }
                            .font(.caption)
                        } else {
                            Button(action: { startOAuth(for: config) }) {
                                HStack {
                                    if isOAuthInProgress {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "person.badge.key")
                                    }
                                    Text("Authenticate with \(cfgValue.provider.displayName)")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isOAuthInProgress)
                        }
                    }
                }

                // Test connection (primary only — keeps the UI simpler).
                if isPrimary {
                    HStack(spacing: 8) {
                        Button(action: testPrimaryConnection) {
                            HStack {
                                if testInProgress.wrappedValue {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "checkmark.circle")
                                }
                                Text("Test Connection")
                            }
                        }
                        .disabled(testInProgress.wrappedValue || !canTestPrimary)

                        if testPassed.wrappedValue {
                            Label("Connection successful", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private var canTestPrimary: Bool {
        guard let cfg = primaryRemote else { return false }
        return cfg.validate().isEmpty
    }

    /// Binding that unwraps the optional remote name for editing.
    private func nameBinding(for config: Binding<RemoteConfiguration?>) -> Binding<String> {
        Binding(
            get: { config.wrappedValue?.name ?? "" },
            set: { config.wrappedValue?.name = $0 }
        )
    }

    /// Helper to give ProviderFieldsView a non-optional binding.
    private func configBinding(_ config: Binding<RemoteConfiguration?>) -> Binding<RemoteConfiguration> {
        Binding(
            get: { config.wrappedValue ?? RemoteConfiguration(name: "", provider: .webdav) },
            set: { config.wrappedValue = $0 }
        )
    }

    // MARK: - Local path

    private var localPathSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local Folder", systemImage: "folder")
                .font(.subheadline.weight(.semibold))
            Text("Where should this remote sync to on your machine?")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Local folder path", text: $localSyncPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { browseForFolder() }
            }
            Toggle("This folder is on an external drive", isOn: $isExternalDrive)
                .toggleStyle(.checkbox)
                .font(.caption)
            if isExternalDrive {
                Text("Sync will be skipped when the drive isn't mounted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(action: performImport) {
                if isImporting {
                    ProgressView().controlSize(.small)
                }
                Text("Import")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canImport)
        }
    }

    private var canImport: Bool {
        if isImporting { return false }
        if localSyncPath.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if shared.profile == nil { return false }

        if shared.remote != nil {
            switch primaryRemoteAction {
            case .reuseExisting:
                break
            case .createNew:
                guard let cfg = primaryRemote else { return false }
                if existingRemoteNames.contains(cfg.name) { return false }
                if !cfg.validate().isEmpty { return false }
            }
        }

        if shared.fallbackRemote != nil {
            switch fallbackRemoteAction {
            case .reuseExisting:
                break
            case .createNew:
                guard let cfg = fallbackRemote else { return false }
                if existingRemoteNames.contains(cfg.name) { return false }
                if !cfg.validate().isEmpty { return false }
            }
        }

        return true
    }

    // MARK: - Lifecycle

    private func load() {
        existingRemoteNames = configService.listRemotes().map {
            $0.hasSuffix(":") ? String($0.dropLast()) : $0
        }

        if let r = shared.remote {
            primaryRemote = shareService.makeEditableRemote(from: r)
            primaryRemoteAction = existingRemoteNames.contains(r.name) ? .reuseExisting : .createNew
        }
        if let r = shared.fallbackRemote {
            fallbackRemote = shareService.makeEditableRemote(from: r)
            fallbackRemoteAction = existingRemoteNames.contains(r.name) ? .reuseExisting : .createNew
        }

        if let body = shared.profile {
            profileName = profileStore.uniqueName(basedOn: body.name)
        }
    }

    // MARK: - Actions

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"
        if panel.runModal() == .OK, let url = panel.url {
            localSyncPath = url.path
            if localSyncPath.hasPrefix("/Volumes/") {
                isExternalDrive = true
            }
        }
    }

    private func startOAuth(for config: Binding<RemoteConfiguration?>) {
        guard let cfg = config.wrappedValue else { return }
        isOAuthInProgress = true
        errorMessage = nil
        configService.startOAuthFlow(for: cfg.provider) { result in
            isOAuthInProgress = false
            switch result {
            case .success(let token):
                config.wrappedValue?.oauthToken = token
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func testPrimaryConnection() {
        guard let cfg = primaryRemote else { return }
        isTestingPrimary = true
        primaryTestPassed = false
        errorMessage = nil

        // Save first under a temporary unique name? No — easier and safer to write the
        // remote, test, and let the import flow handle dedup. If the name clashes the user
        // already chose a non-clashing name above.
        let captured = cfg
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try configService.addRemote(captured)
                Task {
                    let result = await configService.testConnection("\(captured.name):")
                    await MainActor.run {
                        isTestingPrimary = false
                        switch result {
                        case .success:
                            primaryTestPassed = true
                            // Adopt this remote: switch to "reuse existing" so we don't try
                            // to add it again on import.
                            primaryRemoteAction = .reuseExisting
                            if !existingRemoteNames.contains(captured.name) {
                                existingRemoteNames.append(captured.name)
                            }
                        case .failure(let error):
                            errorMessage = error.localizedDescription
                            // Roll back — we don't want to leave a half-broken remote behind.
                            try? configService.deleteRemote(captured.name)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isTestingPrimary = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func performImport() {
        isImporting = true
        errorMessage = nil

        // Disambiguate name if user changed it
        var sharedCopy = shared
        if var body = sharedCopy.profile {
            body.name = profileName
            sharedCopy.profile = body
        }

        let primaryAction: ProfileShareService.RemoteAction = {
            guard let cfg = primaryRemote else { return .create }
            switch primaryRemoteAction {
            case .reuseExisting: return .reuse(cfg.name)
            case .createNew: return .create
            }
        }()
        let fallbackAction: ProfileShareService.RemoteAction = {
            guard let cfg = fallbackRemote else { return .create }
            switch fallbackRemoteAction {
            case .reuseExisting: return .reuse(cfg.name)
            case .createNew: return .create
            }
        }()

        let drivePath: String = {
            guard isExternalDrive, localSyncPath.hasPrefix("/Volumes/") else { return "" }
            let parts = localSyncPath.split(separator: "/")
            return parts.count >= 2 ? "/Volumes/\(parts[1])" : ""
        }()

        do {
            let result = try shareService.installImport(
                shared: sharedCopy,
                localSyncPath: localSyncPath,
                drivePathToMonitor: drivePath,
                primaryRemoteOverride: primaryRemote,
                primaryRemoteAction: primaryAction,
                fallbackRemoteOverride: fallbackRemote,
                fallbackRemoteAction: fallbackAction,
                profileStore: profileStore
            )

            recordImport(
                providerType: shared.remote?.provider.rcloneType ?? "unknown",
                reusedRemote: primaryRemoteAction == .reuseExisting,
                hadFallback: shared.fallbackRemote != nil,
                hadFilter: shared.excludeFilter != nil,
                result: "success"
            )

            isImporting = false
            onImported?(result.profile.id)
            dismiss()
        } catch {
            isImporting = false
            errorMessage = error.localizedDescription
            recordImport(
                providerType: shared.remote?.provider.rcloneType ?? "unknown",
                reusedRemote: primaryRemoteAction == .reuseExisting,
                hadFallback: shared.fallbackRemote != nil,
                hadFilter: shared.excludeFilter != nil,
                result: "failure",
                error: error
            )
        }
    }

    private func recordImport(
        providerType: String,
        reusedRemote: Bool,
        hadFallback: Bool,
        hadFilter: Bool,
        result: String,
        error: Error? = nil
    ) {
        TelemetryService.shared.recordProfileImport(
            providerType: providerType,
            reusedRemote: reusedRemote,
            hadFallback: hadFallback,
            hadFilter: hadFilter,
            result: result,
            errorMessage: error?.localizedDescription
        )
    }
}

// MARK: - Static helper for opening a file → sheet

enum ProfileImportLauncher {
    /// Show an open panel for `.synctrayprofile` files. Returns the decoded
    /// `SharedProfile` ready to feed into `ImportProfileSheet`.
    static func pickFile() -> Result<SharedProfile, Error>? {
        let panel = NSOpenPanel()
        panel.title = "Import Shared Configuration"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var allowed: [UTType] = [.json]
        if let custom = UTType(filenameExtension: SharedProfile.fileExtension) {
            allowed.insert(custom, at: 0)
        }
        panel.allowedContentTypes = allowed
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        do {
            let shared = try ProfileShareService.shared.decode(fileURL: url)
            return .success(shared)
        } catch {
            return .failure(error)
        }
    }
}

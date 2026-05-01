import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sheet that lets the user export a profile (and its remotes) as a `.synctrayprofile` file
/// or copy the JSON to the clipboard. Credentials and machine-specific paths are stripped.
struct ExportProfileSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profile: SyncProfile

    // Toggle state — defaults reflect what makes sense for the typical use case.
    @State private var includeProfile: Bool = true
    @State private var includePrimaryRemote: Bool = true
    @State private var includeFallbackRemote: Bool = true
    @State private var includeExcludeFilter: Bool = true

    @State private var showPreview: Bool = false
    @State private var didCopy: Bool = false
    @State private var errorMessage: String?

    private let shareService = ProfileShareService.shared

    // MARK: - Derived state

    /// Whether the source profile actually has a fallback remote (controls toggle visibility).
    private var profileHasFallback: Bool {
        !profile.fallbackRemote.isEmpty
    }

    /// Whether the source profile has a non-empty exclude filter file.
    private var profileHasExcludeFilter: Bool {
        guard FileManager.default.fileExists(atPath: profile.filterFilePath),
              let contents = try? String(contentsOfFile: profile.filterFilePath, encoding: .utf8)
        else { return false }
        return !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentOptions: ProfileShareService.ExportOptions {
        ProfileShareService.ExportOptions(
            includeProfile: includeProfile,
            includePrimaryRemote: includePrimaryRemote,
            includeFallbackRemote: profileHasFallback && includeFallbackRemote,
            includeExcludeFilter: profileHasExcludeFilter && includeExcludeFilter
        )
    }

    private var sharedProfile: SharedProfile {
        shareService.makeSharedProfile(from: profile, options: currentOptions)
    }

    private var canExport: Bool {
        includeProfile || includePrimaryRemote
            || (profileHasFallback && includeFallbackRemote)
            || (profileHasExcludeFilter && includeExcludeFilter)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    privacyBanner
                    contentsSection
                    previewDisclosure
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
            footer
                .padding()
        }
        .frame(width: 560, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Share Profile Configuration")
                    .font(.headline)
                Text(profile.name.isEmpty ? "Untitled Profile" : profile.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Privacy banner

    private var privacyBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Credentials are excluded")
                    .font(.subheadline.weight(.semibold))
                Text("Passwords, OAuth tokens, and usernames are stripped before sharing. The recipient enters their own credentials when importing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Contents toggles

    private var contentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Include")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $includeProfile) {
                    contentsRow(
                        title: "Profile settings",
                        detail: "Sync mode, schedule, remote folder path, and other settings"
                    )
                }

                Toggle(isOn: $includePrimaryRemote) {
                    contentsRow(
                        title: "Primary remote",
                        detail: "Provider type, host/URL, and non-credential settings"
                    )
                }

                if profileHasFallback {
                    Toggle(isOn: $includeFallbackRemote) {
                        contentsRow(
                            title: "Fallback remote",
                            detail: "Backup remote configuration (no credentials)"
                        )
                    }
                }

                if profileHasExcludeFilter {
                    Toggle(isOn: $includeExcludeFilter) {
                        contentsRow(
                            title: "Exclude filter",
                            detail: "Patterns of files/folders to skip during sync"
                        )
                    }
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private func contentsRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.body)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Preview

    private var previewDisclosure: some View {
        DisclosureGroup(isExpanded: $showPreview) {
            previewContent
                .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                Text("Show what will be exported")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        let preview = (try? shareService.encodeAsString(sharedProfile)) ?? "Could not generate preview."
        ScrollView {
            Text(preview)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 220)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()

            Button(action: copyToClipboard) {
                Label(didCopy ? "Copied!" : "Copy JSON", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .disabled(!canExport)

            Button(action: saveToFile) {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canExport)
        }
    }

    // MARK: - Actions

    private func copyToClipboard() {
        do {
            let json = try shareService.encodeAsString(sharedProfile)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(json, forType: .string)
            didCopy = true
            recordExport(result: "success", method: "clipboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
        } catch {
            errorMessage = error.localizedDescription
            recordExport(result: "failure", method: "clipboard", error: error)
        }
    }

    private func saveToFile() {
        do {
            let data = try shareService.encode(sharedProfile)
            let panel = NSSavePanel()
            panel.title = "Save Profile Configuration"
            panel.nameFieldStringValue = "\(safeFilename(profile.name)).\(SharedProfile.fileExtension)"
            panel.canCreateDirectories = true
            if let utType = UTType(filenameExtension: SharedProfile.fileExtension) {
                panel.allowedContentTypes = [utType, .json]
            } else {
                panel.allowedContentTypes = [.json]
            }
            panel.allowsOtherFileTypes = true

            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }

            try data.write(to: url, options: .atomic)
            recordExport(result: "success", method: "file")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            recordExport(result: "failure", method: "file", error: error)
        }
    }

    private func recordExport(result: String, method: String, error: Error? = nil) {
        let providerType: String = {
            let name = profile.rcloneRemote.hasSuffix(":")
                ? String(profile.rcloneRemote.dropLast())
                : profile.rcloneRemote
            return RcloneConfigService.shared.readRemoteConfig(name: name)?.provider.rcloneType ?? "unknown"
        }()
        TelemetryService.shared.recordProfileExport(
            providerType: providerType,
            includedFallback: profileHasFallback && includeFallbackRemote,
            includedFilter: profileHasExcludeFilter && includeExcludeFilter,
            result: result,
            errorMessage: error?.localizedDescription
        )
        _ = method  // currently informational; kept here for future per-method telemetry
    }

    /// Sanitize profile name for use as a filename.
    private func safeFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "SyncTray Profile" }
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return trimmed.components(separatedBy: invalid).joined(separator: "-")
    }
}

#Preview {
    ExportProfileSheet(profile: SyncProfile(name: "DS223 Music", rcloneRemote: "synology-ds223", remotePath: "Music"))
}

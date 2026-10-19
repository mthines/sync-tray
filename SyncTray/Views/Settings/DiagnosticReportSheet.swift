import SwiftUI
import AppKit

/// "Send Diagnostic Report" — the user explicitly chooses to send a report that CAN contain
/// paths, file names and full error text (they're told so by `DiagnosticReportCopy.disclosure`)
/// and gets a short code to hand the developer. Independent of the usage-data toggle: it works
/// with telemetry off. Opened from a profile's "Last sync error" banner and footer (scoped to
/// that profile, with an "All profiles" option) and from App Settings → Help & Feedback.
///
/// Building and sending run off the main thread (Critical Rule 1); every state change lands
/// back on the main actor.
struct DiagnosticReportSheet: View {
    enum Scope: Hashable {
        case profile
        case all
    }

    enum Phase: Equatable {
        case idle
        case building
        case sending
        case sent(code: String)
        case failed(message: String)
    }

    /// Result of writing the report file off the main thread.
    private enum SaveOutcome {
        case saved(URL)
        case failed(String)
    }

    /// A report and its rendered text, both produced off the main thread.
    private struct BuiltReport {
        let report: DiagnosticReport
        let text: String
    }

    let allProfiles: [SyncProfile]
    let focusProfile: SyncProfile?

    @Environment(\.dismiss) private var dismiss

    @State private var scope: Scope
    @State private var phase: Phase = .idle
    @State private var report: DiagnosticReport?
    @State private var reportScope: Scope?
    @State private var previewText: String?
    @State private var showingPreview: Bool = false
    @State private var saveMessage: String?
    @State private var copied: Bool = false

    init(allProfiles: [SyncProfile], focusProfile: SyncProfile? = nil) {
        self.allProfiles = allProfiles
        self.focusProfile = focusProfile
        _scope = State(initialValue: focusProfile == nil ? .all : .profile)
    }

    private var isWorking: Bool {
        phase == .building || phase == .sending
    }

    private var selectedProfiles: [SyncProfile] {
        if scope == .profile, let focusProfile {
            return [focusProfile]
        }
        return allProfiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send Diagnostic Report")
                .font(.title2.bold())

            if case .sent(let code) = phase {
                sentView(code: code)
            } else {
                composeView
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    // MARK: - Compose

    private var composeView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let focusProfile {
                Picker("Include:", selection: $scope) {
                    Text("This profile (\(focusProfile.name))").tag(Scope.profile)
                    Text("All profiles").tag(Scope.all)
                }
                .pickerStyle(.radioGroup)
                .disabled(isWorking)
                .onChange(of: scope) { _ in
                    // A different scope means a different report — drop the stale one.
                    report = nil
                    reportScope = nil
                    previewText = nil
                    showingPreview = false
                    saveMessage = nil
                    if case .failed = phase { phase = .idle }
                }
            }

            Text(DiagnosticReportCopy.disclosure)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showingPreview, let previewText {
                DiagnosticReportTextView(text: previewText)
                    .frame(height: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            if case .failed(let message) = phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button(showingPreview ? "Hide Preview" : "Preview") {
                    togglePreview()
                }
                .disabled(isWorking)

                Button("Save to Desktop") {
                    saveToDesktop()
                }
                .disabled(isWorking)

                Spacer()

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(phase == .sending ? "Sending…" : "Collecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                // Dismissing mid-send would leave the upload running, and a retry would
                // upload the same report again under the same code.
                .disabled(phase == .sending)

                Button("Send") {
                    send()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
    }

    // MARK: - Sent

    private func sentView(code: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Report sent", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundColor(.green)

            Text("Your report code")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text(code)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)

                Button {
                    copyToPasteboard(code)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            }

            Text(DiagnosticReportCopy.shareCode)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    /// Run `action` with a report for the current scope, building (and rendering) one off the
    /// main thread first if needed.
    private func withReport(_ action: @escaping (DiagnosticReport) -> Void) {
        if let report, reportScope == scope {
            action(report)
            return
        }
        // Capture everything the background work needs on the main thread first.
        let profiles = selectedProfiles
        let requestedScope = scope
        phase = .building
        saveMessage = nil
        Task { @MainActor in
            let built = await Task.detached(priority: .userInitiated) { () -> BuiltReport in
                let fresh = DiagnosticReportBuilder.build(profiles: profiles, environment: .production())
                return BuiltReport(report: fresh, text: fresh.render())
            }.value
            report = built.report
            reportScope = requestedScope
            previewText = built.text
            phase = .idle
            action(built.report)
        }
    }

    private func togglePreview() {
        if showingPreview {
            showingPreview = false
            return
        }
        // `withReport` sets `previewText` together with the report (rendered off main).
        withReport { _ in
            showingPreview = true
        }
    }

    private func saveToDesktop() {
        withReport { built in
            let fileName = DiagnosticReportFile.defaultFileName(for: built.code)
            Task { @MainActor in
                let outcome = await Task.detached(priority: .userInitiated) { () -> SaveOutcome in
                    do {
                        let url = try DiagnosticReportFile.write(built.render(), named: fileName)
                        return .saved(url)
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }.value
                switch outcome {
                case .saved(let url):
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    saveMessage = "Saved to \(url.path). Nothing was sent."
                case .failed(let message):
                    saveMessage = "Couldn't save the report: \(message)"
                }
            }
        }
    }

    private func send() {
        saveMessage = nil
        withReport { built in
            phase = .sending
            Task { @MainActor in
                do {
                    try await DiagnosticReportUploader.send(built)
                    TelemetryService.shared.recordDiagnosticReport(
                        reportId: built.code, sourceUI: "app", succeeded: true, lineCount: built.lineCount)
                    phase = .sent(code: built.code)
                } catch {
                    TelemetryService.shared.recordDiagnosticReport(
                        reportId: built.code, sourceUI: "app", succeeded: false, lineCount: built.lineCount)
                    phase = .failed(message: DiagnosticReportUploader.message(for: error))
                }
            }
        }
    }

    private func copyToPasteboard(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
    }
}

/// Read-only, selectable, monospaced text in a scroll view. An `NSTextView` rather than a
/// SwiftUI `Text`, which lays out a multi-megabyte string far too slowly.
private struct DiagnosticReportTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.textContainerInset = NSSize(width: 6, height: 6)
            // Lay out only what's visible — a report can run to megabytes.
            textView.layoutManager?.allowsNonContiguousLayout = true
            textView.string = text
            textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    }
}

#Preview {
    DiagnosticReportSheet(allProfiles: [])
}

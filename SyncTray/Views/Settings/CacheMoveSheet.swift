import SwiftUI
import AppKit

/// Cache-directory move sheet. Serves BOTH entry points so cancel, progress,
/// resume and rollback behave identically everywhere a move can start:
///
/// - A (R16): the Save-time prompt — `.pendingSave` — destination and any
///   overlap/same-root siblings are already resolved by
///   `SyncManager.cachePathChangeIntent`; offers exactly three actions
///   ("Move existing cached files" / "Leave them behind" / "Start fresh").
/// - B (R17): the standalone "Move Cache…" action in Offline Files —
///   `.pickDestination` — starts with a folder picker instead.
struct CacheMoveSheet: View {
    enum Mode {
        case pendingSave(prompt: CacheMovePrompt)
        case pickDestination(profile: SyncProfile)
    }

    let mode: Mode
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var syncManager: SyncManager

    /// Save should persist the NEW `vfsCachePath` with no move — every other
    /// edited field was already saved by the caller before this sheet opened.
    /// `nil` for `.pickDestination`, where there is no pending profile save.
    var onLeaveBehind: (() -> Void)?
    /// Save should delete the OLD cache subtree, then persist the NEW `vfsCachePath`.
    var onStartFresh: (() -> Void)?
    /// Called the instant a move actually starts (`startMove()`), regardless
    /// of entry point — tells the Save-time caller that the deferred
    /// other-field changes are about to be applied by the move's own
    /// uninstall→…→install cycle, so its `onDismiss` reinstall backstop
    /// must not also fire for those same fields (finding 12). `nil` is a
    /// legitimate no-op for `.pickDestination`, which has no deferred fields.
    var onMoveStarted: (() -> Void)?
    var onDismiss: () -> Void

    private enum Step: Equatable {
        case choosing            // pendingSave: 3-button offer; pickDestination (with overlap found): move-only offer
        case pickingDestination  // pickDestination only: folder picker
        case moving
        case done(String)
        case cancelledChoice     // resume vs roll back
    }

    @State private var step: Step
    @State private var destination: String
    @State private var coMigrateSameRoot: Set<UUID> = []
    @State private var sourceRoot: String
    @State private var overlappingIds: [UUID]
    @State private var sameRootIds: [UUID]
    @State private var movingProfileId: UUID
    @State private var errorMessage: String?

    init(
        mode: Mode,
        profileStore: ProfileStore,
        syncManager: SyncManager,
        onLeaveBehind: (() -> Void)? = nil,
        onStartFresh: (() -> Void)? = nil,
        onMoveStarted: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.mode = mode
        self.profileStore = profileStore
        self.syncManager = syncManager
        self.onLeaveBehind = onLeaveBehind
        self.onStartFresh = onStartFresh
        self.onMoveStarted = onMoveStarted
        self.onDismiss = onDismiss

        switch mode {
        case .pendingSave(let prompt):
            _step = State(initialValue: .choosing)
            _destination = State(initialValue: prompt.destinationRoot)
            _sourceRoot = State(initialValue: prompt.sourceRoot)
            _overlappingIds = State(initialValue: prompt.overlappingProfileIds)
            _sameRootIds = State(initialValue: prompt.sameRootProfileIds)
            _movingProfileId = State(initialValue: prompt.profileId)
        case .pickDestination(let profile):
            _step = State(initialValue: .pickingDestination)
            _destination = State(initialValue: "")
            _sourceRoot = State(initialValue: CacheMigrationPlanner.normalizeRoot(profile.vfsCachePath))
            _overlappingIds = State(initialValue: [])
            _sameRootIds = State(initialValue: [])
            _movingProfileId = State(initialValue: profile.id)
        }
    }

    /// Only the Save-time entry point has an underlying profile save to
    /// finalize with "leave behind"/"start fresh" — the standalone picker has
    /// no pending form edit, so those two options don't apply there.
    private var isPendingSaveMode: Bool {
        if case .pendingSave = mode { return true }
        return false
    }

    private var movingProfile: SyncProfile? { profileStore.profile(for: movingProfileId) }
    private var progress: CacheMigrationProgress? { syncManager.cacheMigrationProgress[movingProfileId] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
            Text("Cache Directory")
                .font(.headline)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .choosing:
            choosingContent
        case .pickingDestination:
            pickingDestinationContent
        case .moving:
            movingContent
        case .done(let summary):
            doneContent(summary)
        case .cancelledChoice:
            cancelledChoiceContent
        }
    }

    // MARK: - Step: choosing

    private var choosingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should happen to the files already cached at the old location?")
                .font(.callout)

            VStack(alignment: .leading, spacing: 2) {
                Text("From: \(displayPath(sourceRoot))").font(.caption).foregroundStyle(.secondary)
                Text("To: \(displayPath(destination))").font(.caption).foregroundStyle(.secondary)
            }

            if !overlappingIds.isEmpty {
                Label(
                    "Also moves cached files for \(names(overlappingIds)) — they share the exact same cached bytes on disk.",
                    systemImage: "link"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !sameRootIds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("These profiles also use the old cache directory. Move their caches too?")
                        .font(.caption.weight(.medium))
                    ForEach(sameRootIds, id: \.self) { id in
                        Toggle(profileStore.profile(for: id)?.name ?? "Profile", isOn: Binding(
                            get: { coMigrateSameRoot.contains(id) },
                            set: { on in
                                if on { coMigrateSameRoot.insert(id) } else { coMigrateSameRoot.remove(id) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            VStack(spacing: 8) {
                Button {
                    startMove()
                } label: {
                    Label("Move existing cached files", systemImage: "arrow.right.doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if isPendingSaveMode {
                    Button {
                        onLeaveBehind?()
                    } label: {
                        Text("Leave them behind").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onStartFresh?()
                    } label: {
                        Text("Start fresh (clear the old cache)").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Step: pickingDestination (Offline Files entry point)

    private var pickingDestinationContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a new location for this profile's cached files. Everything already downloaded moves — nothing re-downloads.")
                .font(.callout)
            HStack {
                TextField("/Volumes/Big/rclone-cache", text: $destination)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { browseForDestination() }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Button {
                resolveOverlapThenMove()
            } label: {
                Label("Move existing cached files", systemImage: "arrow.right.doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func browseForDestination() {
        let panel = NSOpenPanel()
        panel.title = "Select New Cache Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.path
        }
    }

    /// Re-runs the SAME classification `cachePathChangeIntent` uses so the
    /// overlap/same-root prompt can be shown before starting the move.
    private func resolveOverlapThenMove() {
        guard let profile = movingProfile else { return }
        let normalizedDestination = CacheMigrationPlanner.normalizeRoot(destination)
        let (overlapping, sameRoot) = CacheMigrationPlanner.classifySiblings(
            of: profile, sourceRoot: sourceRoot, allProfiles: profileStore.profiles
        )
        destination = normalizedDestination
        overlappingIds = overlapping.map { $0.id }
        sameRootIds = sameRoot.map { $0.id }
        if overlappingIds.isEmpty && sameRootIds.isEmpty {
            startMove()
        } else {
            errorMessage = nil
            step = .choosing
        }
    }

    // MARK: - Step: moving

    private func startMove() {
        errorMessage = nil
        step = .moving
        onMoveStarted?()
        let coMigrate = Set(overlappingIds)
        let task = syncManager.startCacheMigration(for: movingProfileId, destination: destination, coMigrate: coMigrate)
        Task {
            let outcome = await task.value
            await MainActor.run {
                handle(outcome: outcome)
            }
        }
    }

    private func handle(outcome: CacheMigrationOutcome) {
        switch outcome.result {
        case .completed:
            let extraTargets = sameRootIds.filter { coMigrateSameRoot.contains($0) }
            guard !extraTargets.isEmpty else {
                step = .done(summary(for: outcome))
                return
            }
            moveSameRootProfiles(extraTargets, thenSummarize: summary(for: outcome))
        case .cancelled:
            step = .cancelledChoice
        case .failed(let reason, let rolledBack):
            errorMessage = "Move failed (\(reason.rawValue))" + (rolledBack ? " — already-moved files were rolled back." : ".")
            step = .choosing
        case .preflightRejected(.nothingToMove):
            // Nothing was cached at the source — SyncManager already treats
            // this as a persist-worthy success (finding 11), so the sheet
            // must not present it as an error the user has to retry.
            step = .done("Nothing was cached yet — the new location is saved.")
        case .preflightRejected(let rejection):
            // Route back to a step where `destination` is actually editable.
            // `.choosing` (pendingSave) has no destination field at all, so
            // routing a rejection there for the standalone picker flow was a
            // dead end — the user could only retry the SAME rejected
            // destination (finding 11).
            errorMessage = "Can't move: \(rejection)"
            step = isPendingSaveMode ? .choosing : .pickingDestination
        }
    }

    /// Sequentially migrate each accepted same-root sibling to the same
    /// destination — a SEPARATE plan/run per profile (R14): these are
    /// disjoint bytes on disk, not part of the primary plan.
    private func moveSameRootProfiles(_ ids: [UUID], thenSummarize summary: String) {
        guard let id = ids.first else {
            step = .done(summary)
            return
        }
        let task = syncManager.startCacheMigration(for: id, destination: destination, coMigrate: [])
        Task {
            _ = await task.value
            await MainActor.run {
                moveSameRootProfiles(Array(ids.dropFirst()), thenSummarize: summary)
            }
        }
    }

    private func summary(for outcome: CacheMigrationOutcome) -> String {
        let size = TransferFormat.bytes(outcome.bytesMoved)
        return "Moved \(outcome.filesMoved) file\(outcome.filesMoved == 1 ? "" : "s"), \(size)."
    }

    private var movingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress {
                if let fraction = progress.fractionComplete {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text("\(progress.formattedBytesProgress) · \(progress.formattedElapsed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !progress.currentFile.isEmpty {
                    Text(progress.currentFile)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ProgressView("Preparing…")
            }
            Button("Cancel") {
                syncManager.cancelCacheMigration(for: movingProfileId)
            }
        }
    }

    // MARK: - Step: cancelled — resume vs roll back

    private var cancelledChoiceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move cancelled. Files already relocated are still at the new location; nothing was left half-copied.")
                .font(.callout)
            HStack {
                Button("Resume") { startMove() }
                    .buttonStyle(.borderedProminent)
                Button("Roll Back", role: .destructive) {
                    step = .moving
                    let task = syncManager.rollbackCacheMigration(
                        for: movingProfileId, sourceRoot: sourceRoot, destinationRoot: destination, coMigrate: Set(overlappingIds)
                    )
                    Task {
                        _ = await task.value
                        await MainActor.run {
                            step = .done("Rolled back — cache is back at the original location.")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Step: done

    private func doneContent(_ summary: String) -> some View {
        Label(summary, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch step {
            case .done:
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            case .moving:
                EmptyView()
            default:
                Button("Cancel") { onDismiss() }
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func names(_ ids: [UUID]) -> String {
        ids.compactMap { profileStore.profile(for: $0)?.name }.joined(separator: ", ")
    }
}

import SwiftUI

struct ProfileListView: View {
    @ObservedObject var profileStore: ProfileStore
    @EnvironmentObject var syncManager: SyncManager
    @Binding var selection: UUID?

    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 16)

            // Profile list
            List(selection: $selection) {
                ForEach(profileStore.profiles) { profile in
                    ProfileRow(
                        profile: profile,
                        state: syncManager.state(for: profile.id),
                        isInstalled: SyncSetupService.shared.isInstalled(profile: profile),
                        isPaused: syncManager.isPaused(for: profile.id),
                        progress: syncManager.profileProgress[profile.id]
                    )
                    .tag(profile.id)
                    .contextMenu {
                        Button(syncManager.isPaused(for: profile.id) ? "Resume Syncing" : "Pause Syncing") {
                            syncManager.togglePause(for: profile.id)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            deleteProfile(profile)
                        }
                    }
                }
                .onDelete(perform: deleteProfiles)
            }
            .listStyle(.sidebar)

            Divider()

            // Action buttons bar at bottom
            HStack(spacing: 12) {
                Button(action: addProfile) {
                    Image(systemName: "plus")
                        .foregroundColor(.primary)
                }
                .buttonStyle(.borderless)
                .help("Add Profile")

                Button(action: { showingDeleteConfirmation = true }) {
                    Image(systemName: "trash")
                        .foregroundColor(selection == nil ? .secondary : .primary)
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .help("Delete Profile")

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .alert("Delete Profile?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSelectedProfile() }
        } message: {
            if let selectedId = selection,
               let profile = profileStore.profile(for: selectedId) {
                Text("Are you sure you want to delete \"\(profile.name.isEmpty ? "Untitled Profile" : profile.name)\"? This will also uninstall its scheduled sync.")
            } else {
                Text("Are you sure you want to delete this profile?")
            }
        }
    }

    private func addProfile() {
        let profile = profileStore.createNewProfile()
        selection = profile.id
    }

    private func deleteSelectedProfile() {
        guard let selectedId = selection,
              let profile = profileStore.profile(for: selectedId) else { return }
        deleteProfile(profile)
    }

    private func deleteProfile(_ profile: SyncProfile) {
        // Uninstall if installed
        if SyncSetupService.shared.isInstalled(profile: profile) {
            try? SyncSetupService.shared.uninstall(profile: profile)
        }
        profileStore.delete(id: profile.id)
    }

    private func deleteProfiles(at offsets: IndexSet) {
        for index in offsets {
            let profile = profileStore.profiles[index]
            deleteProfile(profile)
        }
    }
}

struct ProfileRow: View {
    let profile: SyncProfile
    let state: SyncState
    let isInstalled: Bool
    var isPaused: Bool = false
    var progress: SyncProgress? = nil

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator - show pause icon when paused
            if isPaused {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name.isEmpty ? "Untitled Profile" : profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isPaused ? .secondary : .primary)
                    .lineLimit(1)

                if isPaused {
                    Text("Paused")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .italic()
                } else if isInstalled {
                    Text(profile.fullRemotePath)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Not configured")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .italic()
                }
            }

            Spacer()

            // Sync indicator
            if state == .syncing {
                if let progress = progress, progress.totalBytes > 0 {
                    // Show progress percentage when available
                    Text("\(Int(progress.percentage))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                } else {
                    // Show spinner when syncing but no progress yet
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        if !isInstalled {
            return .gray
        }

        switch state {
        case .idle:
            return .green
        case .syncing:
            return .blue
        case .paused:
            return .gray
        case .error:
            return .red
        case .driveNotMounted:
            return .orange
        case .notConfigured:
            return .yellow
        }
    }
}

#Preview {
    ProfileListView(
        profileStore: ProfileStore(),
        selection: .constant(nil)
    )
    .environmentObject(SyncManager())
    .frame(width: 200)
}

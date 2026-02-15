import SwiftUI

struct ProfileListView: View {
    @ObservedObject var profileStore: ProfileStore
    @EnvironmentObject var syncManager: SyncManager
    @Binding var selection: UUID?

    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Profile list
            List(selection: $selection) {
                ForEach(profileStore.profiles) { profile in
                    ProfileRow(
                        profile: profile,
                        state: syncManager.state(for: profile.id),
                        isInstalled: SyncSetupService.shared.isInstalled(profile: profile)
                    )
                    .tag(profile.id)
                    .contextMenu {
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

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name.isEmpty ? "Untitled Profile" : profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if isInstalled {
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
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
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

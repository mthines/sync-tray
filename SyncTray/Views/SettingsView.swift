import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProfileId: UUID?

    var body: some View {
        NavigationSplitView {
            ProfileListView(
                profileStore: syncManager.profileStore,
                selection: $selectedProfileId
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            if let profileId = selectedProfileId,
               let profile = syncManager.profileStore.profile(for: profileId) {
                ProfileDetailView(
                    profile: profile,
                    profileStore: syncManager.profileStore,
                    syncManager: syncManager
                )
                .id(profile.id)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Profile Selected")
                        .font(.title2)
                    Text("Select a profile from the sidebar or create a new one.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar(.hidden)
        .frame(width: 700, height: 650)
        .onAppear {
            // Check if there's a pending profile selection from notification tap
            if let pendingId = AppDelegate.pendingProfileSelection {
                selectedProfileId = pendingId
                AppDelegate.pendingProfileSelection = nil
            } else if selectedProfileId == nil {
                // Select first profile if none selected
                selectedProfileId = syncManager.profileStore.profiles.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectProfile)) { notification in
            if let profileId = notification.userInfo?["profileId"] as? UUID {
                selectedProfileId = profileId
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SyncManager())
}

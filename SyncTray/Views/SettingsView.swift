import SwiftUI
import UniformTypeIdentifiers

/// Represents what's selected in the settings sidebar
enum SidebarSelection: Hashable {
    case profile(UUID)
    case appSettings
}

struct SettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.dismiss) private var dismiss

    @State private var selection: SidebarSelection?
    @State private var showingSetupWizard: Bool = false

    var body: some View {
        NavigationSplitView {
            ProfileListView(
                profileStore: syncManager.profileStore,
                selection: $selection
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            switch selection {
            case .profile(let profileId):
                if let profile = syncManager.profileStore.profile(for: profileId) {
                    ProfileDetailView(
                        profile: profile,
                        profileStore: syncManager.profileStore,
                        syncManager: syncManager
                    )
                    .id(profile.id)
                } else {
                    noSelectionPlaceholder
                }
            case .appSettings:
                AppSettingsView()
            case nil:
                noSelectionPlaceholder
            }
        }
        .toolbar(.hidden)
        .frame(width: 700, height: 650)
        .onAppear {
            // Check if there's a pending profile selection from notification tap
            if let pendingId = AppDelegate.pendingProfileSelection {
                selection = .profile(pendingId)
                AppDelegate.pendingProfileSelection = nil
            } else if selection == nil {
                // Select first profile if none selected
                if let firstId = syncManager.profileStore.profiles.first?.id {
                    selection = .profile(firstId)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectProfile)) { notification in
            if let profileId = notification.userInfo?["profileId"] as? UUID {
                selection = .profile(profileId)
            }
        }
        .sheet(isPresented: $showingSetupWizard) {
            SetupWizardView(profileStore: syncManager.profileStore)
        }
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Profile Selected")
                .font(.title2)
            Text("Select a profile from the sidebar or create a new one.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Show the setup wizard
    func showWizard() {
        showingSetupWizard = true
    }
}

#Preview {
    SettingsView()
        .environmentObject(SyncManager())
}

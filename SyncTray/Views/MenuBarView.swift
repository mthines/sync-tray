import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusHeaderView()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Profile status section (if multiple profiles)
            if syncManager.profileStore.enabledProfiles.count > 1 {
                Divider()
                    .padding(.horizontal, 8)

                profileStatusSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            Divider()
                .padding(.horizontal, 8)

            RecentChangesView()
                .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 8)

            actionButtons
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .frame(width: 320)
    }

    private var profileStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Profiles")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(syncManager.profileStore.enabledProfiles) { profile in
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor(for: profile))
                        .frame(width: 6, height: 6)

                    Text(profile.name)
                        .font(.system(size: 12))
                        .lineLimit(1)

                    Spacer()

                    if syncManager.state(for: profile.id) == .syncing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }
            }
        }
    }

    private func statusColor(for profile: SyncProfile) -> Color {
        switch syncManager.state(for: profile.id) {
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

    private var actionButtons: some View {
        VStack(spacing: 4) {
            // Sync Now button
            Button(action: { syncManager.triggerManualSync() }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Sync Now")
                    Spacer()
                    if syncManager.isManualSyncRunning {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(6)
            .disabled(syncManager.isManualSyncRunning || syncManager.currentState == .driveNotMounted || syncManager.currentState == .notConfigured)

            // Open Sync Directory button (shows first enabled profile's directory)
            if let firstProfile = syncManager.profileStore.enabledProfiles.first,
               !firstProfile.localSyncPath.isEmpty {
                Button(action: { syncManager.openSyncDirectory() }) {
                    HStack {
                        Image(systemName: "folder")
                        Text("Open Sync Directory")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(6)
            }

            // View Log button
            Button(action: { syncManager.openLogFile() }) {
                HStack {
                    Image(systemName: "doc.text")
                    Text("View Log")
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(6)

            Divider()
                .padding(.vertical, 4)

            // Launch at Login toggle
            HStack {
                Toggle(isOn: Binding(
                    get: { syncManager.isLoginItemEnabled },
                    set: { enabled in
                        if enabled {
                            syncManager.enableLoginItem()
                        } else {
                            syncManager.disableLoginItem()
                        }
                    }
                )) {
                    Text("Launch at Login")
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Settings button
            if #available(macOS 14.0, *) {
                SettingsLink {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Settings...")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .simultaneousGesture(TapGesture().onEnded {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                })
            } else {
                Button(action: { openSettings() }) {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Settings...")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Divider()
                .padding(.vertical, 4)

            // Quit button
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Image(systemName: "power")
                    Text("Quit SyncTray")
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(SyncManager())
}

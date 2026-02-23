import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusHeaderView()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Profile status section
            if syncManager.profileStore.enabledProfiles.count >= 1 {
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
        .frame(width: 390)
    }

    private var profileStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Profiles")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(syncManager.profileStore.enabledProfiles) { profile in
                HStack(spacing: 8) {
                    // Status indicator - show pause icon when paused
                    if syncManager.isPaused(for: profile.id) {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    } else {
                        Circle()
                            .fill(statusColor(for: profile))
                            .frame(width: 6, height: 6)
                    }

                    Text(profile.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundColor(syncManager.isPaused(for: profile.id) ? .secondary : .primary)

                    Spacer()

                    // Sync progress indicator
                    if syncManager.state(for: profile.id) == .syncing {
                        if let progress = syncManager.profileProgress[profile.id],
                           progress.totalBytes > 0 {
                            Text("\(Int(progress.percentage))%")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        } else {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        }
                    }

                    // Action buttons (order: settings, mute, folder, pause/play)
                    HStack(spacing: 4) {
                        // Settings button - opens profile settings
                        Button(action: { openSettingsForProfile(profile.id) }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open settings for this profile")

                        // Mute/unmute notifications button
                        Button(action: { toggleNotifications(for: profile.id) }) {
                            Image(systemName: syncManager.isNotificationsMuted(for: profile.id) ? "bell.slash.fill" : "bell")
                                .font(.system(size: 10))
                                .foregroundColor(syncManager.isNotificationsMuted(for: profile.id) ? .orange : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(syncManager.isNotificationsMuted(for: profile.id) ? "Unmute notifications" : "Mute notifications")

                        // Open folder button
                        if !profile.localSyncPath.isEmpty {
                            Button(action: { syncManager.openSyncDirectory(for: profile) }) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Open sync directory")
                        }

                        // Sync now button for this profile
                        Button(action: { syncManager.triggerManualSync(for: profile) }) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Sync this profile now")
                        .disabled(syncManager.isPaused(for: profile.id) || syncManager.state(for: profile.id) == .syncing)

                        // Pause/resume sync button (shows action: pause when running, play when paused)
                        Button(action: { syncManager.togglePause(for: profile.id) }) {
                            Image(systemName: syncManager.isPaused(for: profile.id) ? "play.fill" : "pause.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(syncManager.isPaused(for: profile.id) ? "Resume syncing" : "Pause syncing")
                    }
                }
            }
        }
    }

    private func toggleNotifications(for profileId: UUID) {
        if syncManager.isNotificationsMuted(for: profileId) {
            syncManager.unmuteNotifications(for: profileId)
        } else {
            syncManager.muteNotifications(for: profileId)
        }
    }

    private func openSettingsForProfile(_ profileId: UUID) {
        AppDelegate.pendingProfileSelection = profileId
        openSettingsWindow()
        // Post notification to select profile (handles case when window is already open)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: .selectProfile,
                object: nil,
                userInfo: ["profileId": profileId]
            )
        }
    }

    private func statusColor(for profile: SyncProfile) -> Color {
        switch syncManager.state(for: profile.id) {
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
            .disabled(syncManager.isManualSyncRunning || syncManager.currentState == .driveNotMounted || syncManager.currentState == .notConfigured || syncManager.isAllPaused)

            // Pause All / Resume All button
            Button(action: { syncManager.togglePauseAll() }) {
                HStack {
                    Image(systemName: syncManager.isAllPaused ? "play.fill" : "pause.fill")
                    Text(syncManager.isAllPaused ? "Resume All" : "Pause All")
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
            .disabled(syncManager.currentState == .notConfigured)

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
            Button(action: { openSettingsWindow() }) {
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

    private func openSettingsWindow() {
        AppDelegate.shared?.openSettingsWindow()
    }
}

#Preview {
    MenuBarView()
        .environmentObject(SyncManager())
}

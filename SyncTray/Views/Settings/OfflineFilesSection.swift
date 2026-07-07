import SwiftUI
import AppKit
import Combine

/// Collapsible section for managing offline/cached files in mount mode profiles
struct OfflineFilesSection: View {
    let profile: SyncProfile
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var syncManager: SyncManager

    @State private var isExpanded: Bool = false
    @State private var cachedItems: [CachedItem] = []
    @State private var cacheStats: CacheStats?
    @State private var currentPath: String = ""
    @State private var pathHistory: [String] = []
    @State private var isLoading: Bool = false
    @State private var isClearing: Bool = false
    @State private var showClearConfirm: Bool = false
    @State private var rcAvailable: Bool = false
    // Default true so the "enable me" card doesn't flash before the async check runs.
    @State private var extensionEnabled: Bool = true

    // Pinned directories editing
    @State private var newPinnedDir: String = ""
    @State private var browseWarning: String?
    @State private var isRefreshingPins: Bool = false
    @State private var pinnedDirs: [String] = []

    private let cacheService = VFSCacheService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsible header
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Text("Offline Files")
                        .font(.subheadline.weight(.medium))

                    if let stats = cacheStats, stats.fileCount > 0 {
                        Text("\(stats.fileCount) files, \(stats.formattedSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Surfaced even when the section is collapsed: enabling the Finder
            // extension is the one manual step a fresh install requires (macOS
            // ships extensions disabled), so it must be impossible to miss.
            if !extensionEnabled {
                enableExtensionCard
                    .padding(.top, 10)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    // Cache overview
                    cacheOverview

                    Divider()

                    // Pinned directories
                    pinnedDirectoriesSection

                    Divider()

                    // Cached files browser
                    cachedFilesBrowser
                }
                .padding(.top, 12)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.15), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .onAppear {
            // Seed from the LIVE store, not the passed-in `profile` snapshot, which can
            // lag ProfileStore (e.g. a folder pinned via Finder in a prior session would
            // otherwise show as "none" until the store next changes).
            pinnedDirs = liveProfile.pinnedDirectories
            refreshCacheStats()
            checkExtensionEnabled()
        }
        .onChange(of: isExpanded) { expanded in
            if expanded {
                refreshCacheInfo()
                checkExtensionEnabled()
            }
        }
        .onChange(of: profile.id) { _ in
            pinnedDirs = liveProfile.pinnedDirectories
            currentPath = ""
            pathHistory = []
            refreshCacheStats()
        }
        // Reflect pins made outside this view (e.g. via the Finder right-click menu)
        // live — the profile store is the source of truth, so mirror its pinned list
        // whenever it changes for this profile.
        .onReceive(profileStore.$profiles) { profiles in
            guard let updated = profiles.first(where: { $0.id == profile.id }),
                  updated.pinnedDirectories != pinnedDirs else { return }
            pinnedDirs = updated.pinnedDirectories
            refreshCacheStats()
        }
        .alert("Clear cached files?", isPresented: $showClearConfirm) {
            Button("Free Up Space") { clearCache(preservePinned: true) }
                .keyboardShortcut(.defaultAction)
            Button("Clear Everything", role: .destructive) { clearCache(preservePinned: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees up space by removing downloaded copies of files you've opened. "
                + "Folders you've made available offline stay — choose Clear Everything to remove those too.")
        }
        .alert("Can't pin that folder", isPresented: Binding(
            get: { browseWarning != nil },
            set: { if !$0 { browseWarning = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(browseWarning ?? "")
        }
    }

    // MARK: - Enable-extension prompt

    /// Shown only when the Finder extension is registered but not enabled. Guides the
    /// user to turn it on and self-dismisses once they do (re-checked on appear/expand).
    private var enableExtensionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(.orange)
                Text("Enable the Finder integration")
                    .font(.subheadline.weight(.semibold))
            }
            Text("To right-click folders in Finder and mark them Available Offline, turn on the "
                + "“SyncTray Offline” extension under System Settings → General → Login Items & "
                + "Extensions → Extensions. After enabling it, reopen your Finder windows "
                + "(or restart Finder) so the menu appears.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Open System Settings") { openExtensionSettings() }
                Button("Re-check") { checkExtensionEnabled() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 6))
    }

    /// Ask pluginkit whether the extension is enabled. A leading "+" in its output means
    /// registered AND enabled. Runs off the main thread; the host app isn't sandboxed.
    private func checkExtensionEnabled() {
        Task { extensionEnabled = await Self.finderExtensionEnabled() }
    }

    /// FinderSync extension bundle id. Debug builds use a `.dev`-suffixed id (see
    /// Config/Signing.xcconfig) so a dev build doesn't collide with an installed
    /// release, so the enabled-check must query the matching id per build config.
    private static var finderExtensionBundleID: String {
        #if DEBUG
        return "com.synctray.app.dev.findersync"
        #else
        return "com.synctray.app.findersync"
        #endif
    }

    private static func finderExtensionEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                proc.arguments = ["-m", "-i", finderExtensionBundleID]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .newlines)
                    continuation.resume(returning: out.hasPrefix("+"))
                } catch {
                    continuation.resume(returning: true)  // can't tell → don't nag
                }
            }
        }
    }

    private func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Cache Overview

    private var cacheOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text("Cached files are stored locally for faster access. Folders available offline stay cached automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let stats = cacheStats {
                HStack(spacing: 16) {
                    statBadge(label: "Files", value: "\(stats.fileCount)")
                    statBadge(label: "Folders", value: "\(stats.directoryCount)")
                    statBadge(label: "Size", value: stats.formattedSize)
                    Spacer()

                    if rcAvailable {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("RC Active")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button(action: { refreshCacheInfo() }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .controlSize(.small)

                    if stats.fileCount > 0 {
                        Button(action: { showClearConfirm = true }) {
                            Label(isClearing ? "Clearing..." : "Clear Cache…", systemImage: "trash")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .disabled(isClearing)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning cache...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statBadge(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.medium).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .clipShape(.rect(cornerRadius: 4))
    }

    // MARK: - Pinned Directories

    private var pinnedDirectoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Available Offline")
                    .font(.caption.weight(.medium))
                Spacer()
                if !pinnedDirs.isEmpty && rcAvailable {
                    Button(action: { refreshPinnedDirs() }) {
                        Label(isRefreshingPins ? "Syncing..." : "Sync All", systemImage: "arrow.clockwise.icloud")
                            .font(.caption)
                    }
                    .controlSize(.mini)
                    .disabled(isRefreshingPins)
                }
            }

            Text("Folders you make available offline are downloaded and kept up to date so they open instantly without a connection.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // List of pinned directories
            if pinnedDirs.isEmpty {
                Text("No folders available offline yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(pinnedDirs, id: \.self) { dir in
                    HStack(spacing: 8) {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text(dir)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(action: { removePinnedDir(dir) }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(Color.orange.opacity(0.05))
                    .clipShape(.rect(cornerRadius: 4))
                }
            }

            // Add new pinned directory
            HStack(spacing: 4) {
                TextField("Directory path (e.g., Documents/Work)", text: $newPinnedDir)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { addPinnedDir() }
                Button(action: { browsePinnedDir() }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Browse for a folder inside the mount")
                Button(action: { addPinnedDir() }) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(newPinnedDir.isEmpty)
            }
        }
    }

    // MARK: - Cached Files Browser

    private var cachedFilesBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cached Files")
                    .font(.caption.weight(.medium))
                Spacer()
            }

            // Breadcrumb navigation
            if !currentPath.isEmpty {
                HStack(spacing: 4) {
                    Button(action: { navigateToRoot() }) {
                        Text("Root")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)

                    let components = currentPath.components(separatedBy: "/")
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        Text("/")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if index == components.count - 1 {
                            Text(component)
                                .font(.caption.weight(.medium))
                        } else {
                            Button(action: {
                                let path = components[0...index].joined(separator: "/")
                                navigateTo(path)
                            }) {
                                Text(component)
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                }
            }

            if isLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else if cachedItems.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "tray")
                        .foregroundStyle(.tertiary)
                        .font(.title3)
                    Text("No cached files")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else {
                // File list
                VStack(spacing: 1) {
                    ForEach(cachedItems) { item in
                        cachedItemRow(item)
                    }
                }
                .background(Color.black.opacity(0.1))
                .clipShape(.rect(cornerRadius: 6))
            }
        }
    }

    private func cachedItemRow(_ item: CachedItem) -> some View {
        HStack(spacing: 8) {
            if item.isDirectory {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
            } else {
                Image(systemName: fileIcon(for: item.name))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if !item.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Pin button (for directories)
            if item.isDirectory {
                let isPinned = pinnedDirs.contains(item.relativePath)
                Button(action: { togglePin(item) }) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(isPinned ? .orange : .secondary)
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Remove from offline" : "Make available offline")
            }

            // Delete button
            Button(action: { deleteCachedItem(item) }) {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Remove from cache")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isDirectory {
                navigateTo(item.relativePath)
            }
        }
    }

    // MARK: - Actions

    private func refreshCacheInfo() {
        refreshCacheStats()
        loadCachedItems()
        checkRCAvailability()
    }

    private func refreshCacheStats() {
        DispatchQueue.global(qos: .utility).async {
            let stats = cacheService.cacheStats(for: profile)
            DispatchQueue.main.async {
                self.cacheStats = stats
            }
        }
    }

    private func loadCachedItems() {
        isLoading = true
        let path = currentPath
        DispatchQueue.global(qos: .userInitiated).async {
            let items = cacheService.listCachedItems(for: profile, at: path)
            DispatchQueue.main.async {
                self.cachedItems = items
                self.isLoading = false
            }
        }
    }

    private func checkRCAvailability() {
        Task {
            let available = await cacheService.isRCAvailable(port: profile.rcPort)
            await MainActor.run {
                rcAvailable = available
            }
        }
    }

    private func navigateTo(_ path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        loadCachedItems()
    }

    private func navigateToRoot() {
        pathHistory = []
        currentPath = ""
        loadCachedItems()
    }

    private func deleteCachedItem(_ item: CachedItem) {
        Task {
            do {
                try await cacheService.deleteCachedItem(item, rcPort: profile.rcPort)
            } catch {
                // Fallback: try sync delete if async failed
                try? cacheService.deleteCachedItemSync(item)
            }
            await MainActor.run {
                cachedItems.removeAll { $0.id == item.id }
                refreshCacheStats()
            }
        }
    }

    private func clearCache(preservePinned: Bool) {
        isClearing = true
        Task {
            try? await cacheService.clearCache(for: profile, preservePinned: preservePinned)
            await MainActor.run {
                isClearing = false
                cachedItems = []
                refreshCacheStats()
            }
        }
    }

    /// Open a folder picker rooted at the mount and fill the field with the chosen
    /// folder as a path relative to the mount (pinned dirs are mount-relative). Folders
    /// outside the mount can't be expressed as a relative pin, so they're rejected.
    private func browsePinnedDir() {
        let mount = profile.localSyncPath
        let panel = NSOpenPanel()
        panel.title = "Choose a folder inside the mount to keep offline"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !mount.isEmpty, FileManager.default.fileExists(atPath: mount) {
            panel.directoryURL = URL(fileURLWithPath: mount)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let mountPath = (mount as NSString).standardizingPath
        let chosen = (url.path as NSString).standardizingPath
        guard chosen == mountPath || chosen.hasPrefix(mountPath + "/") else {
            browseWarning = "Pick a folder inside this profile's mount:\n\(mountPath)"
            return
        }
        var rel = String(chosen.dropFirst(mountPath.count))
        while rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        guard !rel.isEmpty else {
            browseWarning = "Choose a subfolder to pin — not the mount root."
            return
        }
        newPinnedDir = rel
    }

    private func addPinnedDir() {
        var dir = newPinnedDir.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading/trailing slashes (rclone paths are relative)
        while dir.hasPrefix("/") { dir = String(dir.dropFirst()) }
        while dir.hasSuffix("/") { dir = String(dir.dropLast()) }
        guard !dir.isEmpty, !pinnedDirs.contains(dir) else { return }
        pinnedDirs.append(dir)
        newPinnedDir = ""
        savePinnedDirs()
    }

    private func removePinnedDir(_ dir: String) {
        pinnedDirs.removeAll { $0 == dir }
        savePinnedDirs()
    }

    private func togglePin(_ item: CachedItem) {
        if pinnedDirs.contains(item.relativePath) {
            pinnedDirs.removeAll { $0 == item.relativePath }
        } else {
            pinnedDirs.append(item.relativePath)
        }
        savePinnedDirs()
    }

    /// The current profile from the store (source of truth), falling back to the passed-in
    /// snapshot only if it's somehow absent. Used so display and saves reflect live state.
    private var liveProfile: SyncProfile {
        profileStore.profile(for: profile.id) ?? profile
    }

    private func savePinnedDirs() {
        // Base the save on the LIVE profile so we only change pinnedDirectories and never
        // clobber other fields with values from a stale `profile` snapshot.
        var updatedProfile = liveProfile
        updatedProfile.pinnedDirectories = pinnedDirs
        profileStore.update(updatedProfile)
    }

    private func refreshPinnedDirs() {
        isRefreshingPins = true
        Task {
            await cacheService.refreshPinnedDirectories(for: profile)
            await MainActor.run {
                isRefreshingPins = false
                refreshCacheInfo()
            }
        }
    }

    // MARK: - Helpers

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "mp3", "wav", "aac", "flac": return "music.note"
        case "zip", "tar", "gz", "rar", "7z": return "archivebox"
        case "doc", "docx", "txt", "rtf": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.stack"
        case "swift", "py", "js", "ts", "html", "css": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

import SwiftUI

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

    // Pinned directories editing
    @State private var newPinnedDir: String = ""
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
            pinnedDirs = profile.pinnedDirectories
            refreshCacheStats()
        }
        .onChange(of: isExpanded) { expanded in
            if expanded {
                refreshCacheInfo()
            }
        }
        .onChange(of: profile.id) { _ in
            pinnedDirs = profile.pinnedDirectories
            currentPath = ""
            pathHistory = []
            refreshCacheStats()
        }
        .alert("Clear All Cached Files?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) { clearAllCache() }
        } message: {
            Text("This will remove all locally cached files for \"\(profile.name)\". Files will be re-downloaded from the cloud when accessed.")
        }
    }

    // MARK: - Cache Overview

    private var cacheOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text("Cached files are stored locally for faster access. Pinned directories stay cached automatically.")
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
                        Button(role: .destructive, action: { showClearConfirm = true }) {
                            Label(isClearing ? "Clearing..." : "Clear All Cache", systemImage: "trash")
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
                Text("Pinned Directories")
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

            Text("Pinned directories are automatically downloaded and kept up to date for offline access.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // List of pinned directories
            if pinnedDirs.isEmpty {
                Text("No pinned directories")
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

            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            // Pin button (for directories)
            if item.isDirectory {
                let isPinned = pinnedDirs.contains(item.relativePath)
                Button(action: { togglePin(item) }) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(isPinned ? .orange : .secondary)
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin directory" : "Pin for offline access")
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
        do {
            try cacheService.deleteCachedItem(item)
            cachedItems.removeAll { $0.id == item.id }
            refreshCacheStats()
        } catch {
            // Item may already be gone
        }
    }

    private func clearAllCache() {
        isClearing = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? cacheService.clearCache(for: profile)
            DispatchQueue.main.async {
                isClearing = false
                cachedItems = []
                refreshCacheStats()
            }
        }
    }

    private func addPinnedDir() {
        let dir = newPinnedDir.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func savePinnedDirs() {
        var updatedProfile = profile
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

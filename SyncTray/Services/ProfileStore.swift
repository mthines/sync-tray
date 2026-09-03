import Foundation
import Combine

/// Manages the storage and retrieval of sync profiles.
///
/// File-authoritative: reads come from per-profile `{shortId}.profile.json`
/// files under `profilesDirectory` when any exist; the legacy `syncProfiles`
/// UserDefaults blob is read only as a fallback (pre-migration, or a fresh
/// install before migration v3 has run). Writes always go to both — the file
/// (authoritative) and the blob (write-only mirror, kept one release for
/// rollback safety; see `MigrationV3BlobToPerProfileFiles`). The blob is never
/// read back once a per-profile file exists, so the dual-write can never
/// create a split-brain.
@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [SyncProfile] = []
    @Published var selectedProfileId: UUID?

    /// Not private — `ConfigSelfTest` reads/writes this key directly against an
    /// isolated `UserDefaults` suite to verify the write-only blob mirror
    /// without touching a real profile's data.
    static let profilesKey = "syncProfiles"

    private let defaults: UserDefaults

    /// Directory holding `{shortId}.profile.json` files. Overridable for
    /// self-test isolation; defaults to the real `~/.config/synctray/profiles`.
    private let profilesDirectory: String

    init(
        profilesDirectory: String = SyncProfile.configDirectory,
        defaults: UserDefaults = .standard
    ) {
        self.profilesDirectory = profilesDirectory
        self.defaults = defaults
        load()
    }

    // MARK: - Persistence

    /// Load profiles. File-authoritative: reads every `{shortId}.profile.json`
    /// in `profilesDirectory` via `SyncProfile`'s forgiving decoder. Falls back
    /// to the legacy `syncProfiles` UserDefaults blob only when no per-profile
    /// files exist yet.
    func load() {
        let fromFiles = loadFromProfileFiles()
        if !fromFiles.isEmpty {
            profiles = fromFiles
            return
        }

        guard let data = defaults.data(forKey: Self.profilesKey) else {
            profiles = []
            return
        }

        do {
            profiles = try JSONDecoder().decode([SyncProfile].self, from: data)
        } catch {
            print("Failed to decode profiles: \(error)")
            profiles = []
        }
    }

    /// Read every `*.profile.json` file in `profilesDirectory`.
    private func loadFromProfileFiles() -> [SyncProfile] {
        Self.profilesOnDisk(in: profilesDirectory)
    }

    /// Read every `*.profile.json` file in `directory`. `nonisolated` and
    /// callable off `@MainActor` so the headless CLI (`SyncTrayCLI`) can read
    /// profiles directly without constructing an `@MainActor` `ProfileStore`
    /// or touching the `ObservableObject`/watcher graph. Single source of
    /// truth for the file read — `loadFromProfileFiles` delegates here too.
    nonisolated static func profilesOnDisk(in directory: String) -> [SyncProfile] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        var result: [SyncProfile] = []
        for file in files.sorted() where file.hasSuffix(".profile.json") {
            let path = (directory as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let profile = try? JSONDecoder().decode(SyncProfile.self, from: data) else {
                continue
            }
            result.append(profile)
        }
        return result
    }

    /// Save profiles: writes `.profile.json` file(s) (authoritative, with a
    /// `$schema` reference) AND dual-writes the legacy `syncProfiles` blob
    /// (write-only mirror; never read back once any `.profile.json` exists).
    ///
    /// - Parameter only: when set, only this single profile's file is written
    ///   (no full directory listing/prune) — the common case for `add`/`update`,
    ///   where exactly one profile changed. `nil` (the default) falls back to
    ///   rewriting every profile's file and pruning orphans, which is required
    ///   whenever the on-disk set of profiles may have shrunk (e.g. `delete`).
    func save(only profile: SyncProfile? = nil) {
        if let profile {
            writeProfileFile(profile)
        } else {
            writeProfileFiles()
        }

        do {
            let data = try JSONEncoder().encode(profiles)
            defaults.set(data, forKey: Self.profilesKey)
        } catch {
            print("Failed to encode profiles: \(error)")
        }
    }

    /// Write every profile to its `{shortId}.profile.json`, noting the content
    /// hash of each write in `ConfigSelfWriteRegistry` so `ConfigFileWatcher`
    /// suppresses the FSEvent this write produces. After writing the in-memory
    /// profiles, PRUNES any orphaned `*.profile.json` (a shortId no longer in
    /// `profiles`) so the file-authoritative `load()` can never resurrect a
    /// deleted profile. The prune only touches the `*.profile.json` suffix —
    /// never the derived `{shortId}.json`, the exclude filter, or `schema/`.
    /// A pruned file generates an FSEvent, but `ConfigFileWatcher.shouldReconcile`
    /// returns false for a missing file and `classify` only reacts to existing
    /// `.profile.json` changes, so pruning is safe with the watcher.
    private func writeProfileFiles() {
        guard (try? FileManager.default.createDirectory(
            atPath: profilesDirectory, withIntermediateDirectories: true)) != nil else { return }

        var writtenFilenames: Set<String> = []
        for profile in profiles {
            if let filename = writeProfileFile(profile) {
                writtenFilenames.insert(filename)
            }
        }

        pruneOrphanProfileFiles(keeping: writtenFilenames)
    }

    /// Write a single profile's `{shortId}.profile.json`, noting the content
    /// hash in `ConfigSelfWriteRegistry` so `ConfigFileWatcher` suppresses the
    /// FSEvent this write produces. Returns the written filename on success,
    /// or `nil` if encoding/writing failed. Does NOT prune orphans — callers
    /// that may have removed a profile must use `writeProfileFiles()` instead.
    @discardableResult
    private func writeProfileFile(_ profile: SyncProfile) -> String? {
        let fm = FileManager.default
        guard (try? fm.createDirectory(
            atPath: profilesDirectory, withIntermediateDirectories: true)) != nil else { return nil }

        guard var dict = try? encodeProfileDict(profile) else { return nil }
        // Relative to profilesDirectory (".../profiles"), the schema lives
        // one level up, under "schema/" (see ConfigSchemaInstaller).
        dict["$schema"] = "../schema/profile.schema.json"

        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return nil }

        let filename = "\(profile.shortId).profile.json"
        let path = "\(profilesDirectory)/\(filename)"
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            ConfigSelfWriteRegistry.shared.noteSelfWrite(contentHash: ConfigSelfWriteRegistry.hash(data))
            return filename
        } catch {
            print("Failed to write profile file for \(profile.shortId): \(error)")
            return nil
        }
    }

    /// Remove any `*.profile.json` in `profilesDirectory` not in `keep`
    /// (self-healing against orphans left by an interrupted delete or an
    /// externally-dropped file). Only files matching the `.profile.json`
    /// suffix are ever removed.
    private func pruneOrphanProfileFiles(keeping keep: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: profilesDirectory) else { return }
        for file in files where file.hasSuffix(".profile.json") && !keep.contains(file) {
            try? fm.removeItem(atPath: "\(profilesDirectory)/\(file)")
        }
    }

    /// Encode a profile to a plain dictionary (round-tripping through JSON) so
    /// `$schema` can be merged in alongside the CodingKeys-driven fields.
    private func encodeProfileDict(_ profile: SyncProfile) throws -> [String: Any] {
        let data = try JSONEncoder().encode(profile)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dict
    }

    // MARK: - CRUD Operations

    /// Add a new profile. Only the new profile's `.profile.json` is written
    /// (existing profiles' files are untouched — see `save(only:)`).
    func add(_ profile: SyncProfile) {
        profiles.append(profile)
        save(only: profile)
    }

    /// Update an existing profile. Only the edited profile's `.profile.json`
    /// is written (existing profiles' files are untouched — see `save(only:)`).
    func update(_ profile: SyncProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        profiles[index] = profile
        save(only: profile)
        TelemetryService.shared.recordProfileConfiguration(profile)
    }

    /// Delete a profile by ID. Removes the profile from memory, rewrites the
    /// blob, AND deletes its `{shortId}.profile.json` so the file-authoritative
    /// `load()` cannot resurrect it on the next launch. The file path is built
    /// from the injected `profilesDirectory` (not `SyncProfile.configDirectory`)
    /// so test isolation holds — matching `writeProfileFiles()`.
    func delete(id: UUID) {
        // Capture BEFORE removal so we still know the shortId to delete.
        let removed = profiles.first { $0.id == id }
        profiles.removeAll { $0.id == id }
        if selectedProfileId == id {
            selectedProfileId = profiles.first?.id
        }
        save()

        if let removed {
            let path = "\(profilesDirectory)/\(removed.shortId).profile.json"
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Get a profile by ID
    func profile(for id: UUID) -> SyncProfile? {
        profiles.first { $0.id == id }
    }

    // MARK: - Convenience

    /// Selected profile based on selectedProfileId
    var selectedProfile: SyncProfile? {
        get {
            guard let id = selectedProfileId else { return nil }
            return profile(for: id)
        }
        set {
            selectedProfileId = newValue?.id
            if let profile = newValue {
                update(profile)
            }
        }
    }

    /// All enabled profiles
    var enabledProfiles: [SyncProfile] {
        profiles.filter { $0.isEnabled }
    }

    /// Create a new profile and add it to the store
    @discardableResult
    func createNewProfile() -> SyncProfile {
        let profile = SyncProfile.newProfile()
        add(profile)
        selectedProfileId = profile.id
        return profile
    }
}

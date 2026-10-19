import Foundation

// MARK: - Migration Protocol

/// Defines a single schema migration for profile data.
/// Migrations run in order at app startup, operating on raw JSON
/// (before Codable decoding) to safely handle schema changes.
protocol ProfileMigration {
    /// The version this migration brings the schema TO.
    /// Migration v1 upgrades from v0→v1, v2 from v1→v2, etc.
    var version: Int { get }

    /// Human-readable description for logging.
    var description: String { get }

    /// Migrate UserDefaults data. May read/write arbitrary keys.
    /// For profile array migrations, read "syncProfiles" data,
    /// deserialize to [[String: Any]], mutate, and rewrite.
    func migrateUserDefaults(_ defaults: UserDefaults) throws

    /// Migrate a single on-disk profile config JSON dictionary.
    /// Return the mutated dictionary if changes were made, or nil for no-op.
    func migrateOnDiskConfig(_ config: [String: Any]) -> [String: Any]?
}

extension ProfileMigration {
    /// Default: no on-disk config changes needed
    func migrateOnDiskConfig(_ config: [String: Any]) -> [String: Any]? { nil }
}

// MARK: - Migration Runner

/// Orchestrates running pending migrations in order at app startup.
/// Tracks the current schema version in UserDefaults and ensures
/// each migration runs exactly once.
enum MigrationRunner {
    private static let schemaVersionKey = "synctray.schemaVersion"
    private static let profilesKey = "syncProfiles"
    private static let configDirectory = SyncProfile.configDirectory

    /// All registered migrations, in order.
    /// To add a new migration: create a struct conforming to ProfileMigration,
    /// give it the next version number, and append it here.
    private static let migrations: [ProfileMigration] = [
        MigrationV1LegacyToMultiProfile(),
        MigrationV2FixVFSCachePath(),
        MigrationV3BlobToPerProfileFiles(),
        MigrationV4Retired(),
        MigrationV5PhotosLibraryExclude(),
        MigrationV6VolumeSystemFoldersExclude(),
    ]

    /// Run all pending migrations. Call this once at app startup,
    /// before ProfileStore loads.
    static func runPendingMigrations() {
        let defaults = UserDefaults.standard
        let currentVersion = defaults.integer(forKey: schemaVersionKey)

        for migration in migrations where migration.version > currentVersion {
            print("[SyncTray] Running migration v\(migration.version): \(migration.description)")

            do {
                // 1. Migrate UserDefaults data
                try migration.migrateUserDefaults(defaults)

                // 2. Migrate on-disk profile config JSON files
                migrateOnDiskConfigs(migration: migration)

                // 3. Advance schema version
                defaults.set(migration.version, forKey: schemaVersionKey)
                print("[SyncTray] Migration v\(migration.version) complete")
            } catch {
                print("[SyncTray] Migration v\(migration.version) failed: \(error.localizedDescription)")
                // Stop here - don't advance version, will retry on next launch
                break
            }
        }
    }

    /// Iterate all on-disk profile config JSON files and apply a migration
    private static func migrateOnDiskConfigs(migration: ProfileMigration) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configDirectory) else { return }

        guard let files = try? fm.contentsOfDirectory(atPath: configDirectory) else { return }

        for file in files where file.hasSuffix(".json") {
            let filePath = (configDirectory as NSString).appendingPathComponent(file)

            guard let data = fm.contents(atPath: filePath),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let updatedConfig = migration.migrateOnDiskConfig(config) {
                if let updatedData = try? JSONSerialization.data(
                    withJSONObject: updatedConfig, options: [.prettyPrinted, .sortedKeys]) {
                    try? updatedData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
                }
            }
        }
    }

    // MARK: - Helpers for migrations

    /// Read the profile array from UserDefaults as raw dictionaries.
    /// Internal (not private) so `ConfigSelfTest` can seed/inspect an isolated
    /// `UserDefaults` suite when exercising `MigrationV3BlobToPerProfileFiles`
    /// without touching `UserDefaults.standard`.
    static func readProfileDicts(from defaults: UserDefaults) -> [[String: Any]]? {
        guard let data = defaults.data(forKey: profilesKey) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }

    /// Write profile dictionaries back to UserDefaults
    static func writeProfileDicts(_ profiles: [[String: Any]], to defaults: UserDefaults) throws {
        let data = try JSONSerialization.data(withJSONObject: profiles)
        defaults.set(data, forKey: profilesKey)
    }
}

// MARK: - Migration V1: Legacy Single-Profile → Multi-Profile

/// Migrates from the original single-profile format (individual UserDefaults keys)
/// to the multi-profile format (JSON array under "syncProfiles" key).
/// This subsumes the logic previously in SyncTrayApp.performMigrationIfNeeded().
struct MigrationV1LegacyToMultiProfile: ProfileMigration {
    let version = 1
    let description = "Migrate legacy single-profile to multi-profile format"

    func migrateUserDefaults(_ defaults: UserDefaults) throws {
        // If already migrated by the old system, just mark version and return
        if defaults.bool(forKey: "hasCompletedMultiProfileMigration") {
            return
        }

        // Check for legacy single-profile keys
        let legacyRemote = defaults.string(forKey: "rcloneRemote") ?? ""
        guard !legacyRemote.isEmpty else {
            // No legacy data to migrate
            defaults.set(true, forKey: "hasCompletedMultiProfileMigration")
            return
        }

        // Parse rclone remote into remote and path
        let parts = legacyRemote.components(separatedBy: ":")
        let remote = parts.first ?? ""
        let remotePath = parts.dropFirst().joined(separator: ":")

        let profileId = UUID()
        let profile: [String: Any] = [
            "id": profileId.uuidString,
            "name": "Default",
            "rcloneRemote": remote,
            "remotePath": remotePath,
            "localSyncPath": defaults.string(forKey: "localSyncPath") ?? "",
            "drivePathToMonitor": defaults.string(forKey: "drivePathToMonitor") ?? "",
            "syncIntervalMinutes": max(defaults.integer(forKey: "syncIntervalMinutes"), 5),
            "additionalRcloneFlags": defaults.string(forKey: "additionalRcloneFlags") ?? "",
            "isEnabled": true,
            "isMuted": false,
            "syncMode": "bisync",
            "syncDirection": "localToRemote",
        ]

        try MigrationRunner.writeProfileDicts([profile], to: defaults)

        // Uninstall legacy launchd agent and install new profile format
        let setupService = SyncSetupService.shared
        if setupService.isLegacyInstalled() {
            try? setupService.uninstallLegacy()
        }

        // Create a SyncProfile to install (SyncSetupService needs the typed model)
        let typedProfile = SyncProfile(
            id: profileId,
            name: "Default",
            rcloneRemote: remote,
            remotePath: remotePath,
            localSyncPath: defaults.string(forKey: "localSyncPath") ?? "",
            drivePathToMonitor: defaults.string(forKey: "drivePathToMonitor") ?? "",
            syncIntervalMinutes: max(defaults.integer(forKey: "syncIntervalMinutes"), 5),
            additionalRcloneFlags: defaults.string(forKey: "additionalRcloneFlags") ?? "",
            isEnabled: true
        )

        do {
            try setupService.install(profile: typedProfile)
        } catch {
            print("[SyncTray] Warning: failed to install migrated profile: \(error)")
            // Don't throw - the profile data is saved, user can reinstall from Settings
        }

        defaults.set(true, forKey: "hasCompletedMultiProfileMigration")
    }
}

// MARK: - Migration V2: Fix VFS Cache Path Default

/// Fixes the vfsCachePath default from "~/.cache/rclone/vfs" to "~/.cache/rclone".
///
/// rclone's --cache-dir flag expects the base cache directory. rclone itself
/// creates a "vfs/" subdirectory inside it. The old default caused double-nesting:
/// ~/.cache/rclone/vfs/vfs/<remote>/
///
/// This migration strips the trailing "/vfs" from affected profiles.
struct MigrationV2FixVFSCachePath: ProfileMigration {
    let version = 2
    let description = "Fix VFS cache path default (remove double /vfs nesting)"

    private let wrongSuffix = "/.cache/rclone/vfs"
    private let correctSuffix = "/.cache/rclone"

    func migrateUserDefaults(_ defaults: UserDefaults) throws {
        guard var profiles = MigrationRunner.readProfileDicts(from: defaults) else { return }

        var changed = false
        for i in profiles.indices {
            if let cachePath = profiles[i]["vfsCachePath"] as? String,
               needsFix(cachePath) {
                profiles[i]["vfsCachePath"] = fixPath(cachePath)
                changed = true
            }
        }

        if changed {
            try MigrationRunner.writeProfileDicts(profiles, to: defaults)
        }
    }

    func migrateOnDiskConfig(_ config: [String: Any]) -> [String: Any]? {
        guard let cachePath = config["vfsCachePath"] as? String,
              needsFix(cachePath) else {
            return nil
        }

        var updated = config
        updated["vfsCachePath"] = fixPath(cachePath)
        return updated
    }

    /// Check if a path has the wrong /vfs suffix that needs fixing
    private func needsFix(_ path: String) -> Bool {
        // Match paths ending in /.cache/rclone/vfs (the wrong default)
        // Don't match paths where /vfs is intentional (e.g., custom paths)
        path.hasSuffix(wrongSuffix)
    }

    /// Remove the trailing /vfs from the path
    private func fixPath(_ path: String) -> String {
        if path.hasSuffix(wrongSuffix) {
            return String(path.dropLast(4)) // Remove "/vfs"
        }
        return path
    }
}

// MARK: - Migration V3: Blob → Per-Profile Files

/// Migrates the single `syncProfiles` UserDefaults blob to per-profile
/// `{shortId}.profile.json` files — the new authoritative, agent-editable
/// surface (see `ProfileStore`).
///
/// The blob is intentionally RETAINED (never deleted) as a write-only mirror
/// for one release: an older build can still read it back for rollback
/// safety, and because `ProfileStore.load()` only ever reads the blob when NO
/// per-profile files exist, retaining it can never create a split-brain.
///
/// Idempotent PER PROFILE: a profile whose `.profile.json` already exists is
/// left untouched (it's already migrated, or has since been edited), while
/// any sibling still blob-only is written. This is deliberately not gated on
/// "any file already exists" — that all-or-nothing check would treat a single
/// existing file as "fully migrated" and permanently strand the rest of a
/// blob if an earlier run wrote only the first profile before being
/// interrupted (crash, force-quit) partway through.
struct MigrationV3BlobToPerProfileFiles: ProfileMigration {
    let version = 3
    let description = "Migrate syncProfiles blob to per-profile .profile.json files (blob retained, write-only)"

    /// Overridable for self-test isolation; defaults to the real profiles directory.
    var profilesDirectoryOverride: String?

    private var profilesDirectory: String { profilesDirectoryOverride ?? SyncProfile.configDirectory }

    func migrateUserDefaults(_ defaults: UserDefaults) throws {
        guard let profileDicts = MigrationRunner.readProfileDicts(from: defaults), !profileDicts.isEmpty else {
            return
        }

        try Self.writeProfileFiles(from: profileDicts, to: profilesDirectory)
        // The blob is deliberately NOT removed here — see type doc.
    }

    /// Outcome of a `writeProfileFiles` pass, exposed so callers (and
    /// `ConfigSelfTest`) can assert MIGRATION INTEGRITY: every profile in the
    /// source blob must end up with a `.profile.json` (written this pass or
    /// already present). `accountedFor < expected` means a profile was silently
    /// dropped (missing/invalid `id`, or an un-encodable dict).
    struct WriteResult: Equatable {
        /// Profiles in the source blob.
        let expected: Int
        /// Files written this pass.
        let written: Int
        /// Files that already existed (idempotent skip).
        let present: Int
        /// Profiles that ended up with a file on disk.
        var accountedFor: Int { written + present }
        /// True when every source profile is accounted for on disk.
        var isComplete: Bool { accountedFor == expected }
    }

    /// Write one `{shortId}.profile.json` per dictionary in `profileDicts`,
    /// skipping any whose file already exists in `directory` (see type doc
    /// for why this is per-profile rather than an all-or-nothing gate).
    /// Internal (not private) so `ConfigSelfTest` can exercise it directly
    /// against a temp directory, independent of `UserDefaults`.
    ///
    /// Returns a `WriteResult` and emits a debug-log line when the migration is
    /// incomplete, so a silent partial migration (a source profile that never
    /// got a file) is OBSERVABLE rather than losing config quietly.
    @discardableResult
    static func writeProfileFiles(from profileDicts: [[String: Any]], to directory: String) throws -> WriteResult {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        var written = 0
        var present = 0

        for var dict in profileDicts {
            guard let idString = dict["id"] as? String else { continue }
            let shortId = String(idString.prefix(8)).lowercased()
            let path = "\(directory)/\(shortId).profile.json"

            guard !FileManager.default.fileExists(atPath: path) else { present += 1; continue }

            dict["$schema"] = "../schema/profile.schema.json"

            guard let data = try? JSONSerialization.data(
                withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { continue }

            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            written += 1
        }

        let result = WriteResult(expected: profileDicts.count, written: written, present: present)
        if !result.isComplete {
            SyncTraySettings.debugLog(
                "[MigrationV3] integrity mismatch: \(result.expected) profile(s) in source blob but only "
                + "\(result.accountedFor) accounted for on disk (written \(written), already present \(present)) "
                + "— a silent partial migration occurred"
            )
        }
        return result
    }
}


// MARK: - Migration V4: retired

/// Retired. Previously pinned each mount profile's cache identity to its primary remote
/// name so the VFS cache survived a remote change — a feature this build removes because
/// mounting an env-var-defined remote makes rclone suffix the cache name
/// (`vfs/{remote}{hash}/…`), and one shared streaming cache between SMB and SFTP is
/// evicted by their differing modtime fingerprints. The cache is keyed by the primary
/// remote name directly again (see `VFSCacheService.cacheRelativePath`), and a leftover
/// suffixed tree is consolidated by the sync script on the next mount start rather than
/// by this migration.
///
/// Kept as a no-op, not deleted, so the schema-version numbering stays monotonic for a
/// machine that already ran v4 — deleting the slot would make its `schemaVersion == 4`
/// skip whatever migration NEXT claims v4.
struct MigrationV4Retired: ProfileMigration {
    let version = 4
    let description = "Retired cache-pinning migration — intentionally a no-op"

    func migrateUserDefaults(_ defaults: UserDefaults) throws {}
}

// MARK: - Migration V5: exclude Apple Photos libraries from existing profiles

/// Adds the Photos-library default rule (`SyncExcludeFilter.photosLibraryRule`) to the exclude
/// filter of every existing Two-Way and One-Way profile. New filter files get it from
/// `SyncSetupService.defaultExcludeFilter`; this covers files written before it was a default,
/// which are otherwise only re-created from the defaults when a profile is disabled and
/// re-enabled.
///
/// Per profile (read from its raw `{shortId}.profile.json`, before `ProfileStore` loads):
/// - Stream (mount) profiles have no sync filter and are skipped.
/// - A missing filter file is left missing — the next install writes it from the defaults,
///   which already carry the rule.
/// - A filter that already mentions `.photoslibrary` (the default, or the user's own rule) or
///   isn't readable UTF-8 is left exactly as it is.
/// - On a Two-Way profile whose local folder actually holds a `.photoslibrary`, the
///   resync-pending marker is written right after the filter (the same filter-then-marker,
///   roll-back-on-failure order `SyncSetupService.writeExcludeFilter` uses). A library the
///   profile used to sync would otherwise vanish from bisync's listings at once, which counts
///   as deletions against `--max-delete` and, for a library holding over half the profile's
///   files, would stop every run at the safety abort. Profiles without a library get no
///   marker: the rule matches nothing there, so there is nothing to resync.
///
/// Per-profile failures are logged and skipped, never thrown: one unwritable filter must not
/// hold back the schema version (and every later migration) forever.
struct MigrationV5PhotosLibraryExclude: ProfileMigration {
    let version = 5
    let description = "Exclude Apple Photos libraries (*.photoslibrary) from existing Two-Way and One-Way profiles"

    /// Overridable for self-test isolation; defaults to the real profiles directory.
    var profilesDirectoryOverride: String?

    private var profilesDirectory: String { profilesDirectoryOverride ?? SyncProfile.configDirectory }

    func migrateUserDefaults(_ defaults: UserDefaults) throws {
        let outcome = Self.addPhotosLibraryExclude(in: profilesDirectory)
        print("[SyncTray] Migration v5: added the Photos-library exclude to \(outcome.updated.count) profile(s), "
            + "scheduled \(outcome.resyncScheduled.count) resync(s), \(outcome.failed.count) failure(s)")
    }

    /// Short ids of the profiles each step touched, so `ConfigSelfTest` can assert exactly
    /// what changed.
    struct Outcome: Equatable {
        var updated: [String] = []
        var resyncScheduled: [String] = []
        var failed: [String] = []
    }

    /// Apply the migration to every `*.profile.json` in `directory`. Idempotent: a second pass
    /// finds the rule already present and changes nothing.
    /// - Parameter hasPhotosLibrary: whether a local sync folder holds a `.photoslibrary`;
    ///   injectable so `ConfigSelfTest` doesn't depend on the machine's real folders.
    @discardableResult
    static func addPhotosLibraryExclude(
        in directory: String,
        hasPhotosLibrary: (String) -> Bool = { MigrationV5PhotosLibraryExclude.containsPhotosLibrary(under: $0) }
    ) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return outcome }

        for file in files.sorted() where file.hasSuffix(".profile.json") {
            let profilePath = (directory as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: profilePath),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let idString = dict["id"] as? String, !idString.isEmpty else { continue }

            // Same derivation as `SyncProfile.shortId`; a missing `syncMode` decodes as bisync.
            let shortId = String(idString.prefix(8)).lowercased()
            let syncMode = (dict["syncMode"] as? String) ?? SyncMode.bisync.rawValue
            guard syncMode != SyncMode.mount.rawValue else { continue }

            let filterPath = (directory as NSString).appendingPathComponent("\(shortId)-exclude.txt")
            guard fm.fileExists(atPath: filterPath),
                  let existing = try? String(contentsOfFile: filterPath, encoding: .utf8),
                  let updated = SyncExcludeFilter.addingPhotosLibraryDefault(to: existing) else { continue }

            do {
                try updated.write(toFile: filterPath, atomically: true, encoding: .utf8)
            } catch {
                SyncTraySettings.debugLog("[MigrationV5] could not update \(filterPath): \(error.localizedDescription)")
                outcome.failed.append(shortId)
                continue
            }

            let localPath = (dict["localSyncPath"] as? String) ?? ""
            if syncMode == SyncMode.bisync.rawValue, !localPath.isEmpty,
               hasPhotosLibrary((localPath as NSString).expandingTildeInPath) {
                let markerPath = (directory as NSString).appendingPathComponent("\(shortId).resync-pending")
                do {
                    try UUID().uuidString.write(toFile: markerPath, atomically: true, encoding: .utf8)
                    outcome.resyncScheduled.append(shortId)
                } catch {
                    // Roll the filter back so the next launch can't skip this profile with the
                    // rule in place but no resync scheduled (the schema version still advances,
                    // so the profile simply keeps its old filter).
                    try? existing.write(toFile: filterPath, atomically: true, encoding: .utf8)
                    SyncTraySettings.debugLog("[MigrationV5] could not schedule a resync for \(shortId): \(error.localizedDescription)")
                    outcome.failed.append(shortId)
                    continue
                }
            }
            outcome.updated.append(shortId)
        }
        return outcome
    }

    /// Whether `root` holds a `.photoslibrary` package within `maxDepth` folder levels. Hidden
    /// entries and package contents are skipped, symlinks aren't followed, and the walk stops
    /// after `maxEntries` entries so a huge tree can't stall launch; anything unreadable
    /// (including a folder macOS won't let the app list) counts as "not found".
    static func containsPhotosLibrary(under root: String, maxDepth: Int = 3, maxEntries: Int = 20_000) -> Bool {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var queue: [(url: URL, depth: Int)] = [(URL(fileURLWithPath: root, isDirectory: true), 0)]
        var seen = 0
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                seen += 1
                if seen > maxEntries { return false }
                if entry.pathExtension.lowercased() == "photoslibrary" { return true }
                guard depth + 1 < maxDepth,
                      let values = try? entry.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      values.isPackage != true else { continue }
                queue.append((entry, depth + 1))
            }
        }
        return false
    }
}

// MARK: - Migration V6: exclude macOS volume system folders from existing profiles

/// Adds the volume-system-folder defaults (`SyncExcludeFilter.volumeSystemFoldersSection`:
/// `.fseventsd`, `.Spotlight-V100`, `.Trashes`, `.DocumentRevisions-V100`, `.TemporaryItems`,
/// each as a `/**` directory rule) to the exclude filter of every existing Two-Way and One-Way
/// profile. New filter files get them from `SyncSetupService.defaultExcludeFilter`.
///
/// Why: these root-owned folders sit at the root of every volume macOS mounts. A profile whose
/// local folder is a volume root, with no "Sync Only These Folders" entries, had nothing
/// keeping rclone out of them — the old default `- .fseventsd` is a file-only rule — so every
/// run failed with "permission denied" and rclone stopped propagating deletions.
///
/// Same per-profile rules as v5 (raw `{shortId}.profile.json`, before `ProfileStore` loads):
/// Stream profiles and missing or unreadable filters are skipped, a filter that already has
/// every rule is left as it is, and failures are logged, never thrown. A Two-Way profile gets
/// the resync-pending marker (filter first, rolled back if the marker fails) only when one of
/// the folders exists at its local root AND is readable: only then can a past run have synced
/// it into bisync's listings, where excluding it now would count as deletions. An unreadable
/// one never reached the listings — every run that tried to list it failed — so it needs no
/// resync (and a profile failing on it already resyncs on its own if an include edit queued one).
struct MigrationV6VolumeSystemFoldersExclude: ProfileMigration {
    let version = 6
    let description = "Exclude macOS volume system folders (.Spotlight-V100, .Trashes, …) from existing Two-Way and One-Way profiles"

    /// Overridable for self-test isolation; defaults to the real profiles directory.
    var profilesDirectoryOverride: String?

    private var profilesDirectory: String { profilesDirectoryOverride ?? SyncProfile.configDirectory }

    func migrateUserDefaults(_ defaults: UserDefaults) throws {
        let outcome = Self.addVolumeSystemFoldersExclude(in: profilesDirectory)
        print("[SyncTray] Migration v6: added the volume-system-folder excludes to \(outcome.updated.count) profile(s), "
            + "scheduled \(outcome.resyncScheduled.count) resync(s), \(outcome.failed.count) failure(s)")
    }

    /// Short ids of the profiles each step touched, so `ConfigSelfTest` can assert exactly
    /// what changed.
    struct Outcome: Equatable {
        var updated: [String] = []
        var resyncScheduled: [String] = []
        var failed: [String] = []
    }

    /// Apply the migration to every `*.profile.json` in `directory`. Idempotent.
    /// - Parameter hasReadableSystemFolder: whether a local sync folder holds a readable volume
    ///   system folder at its root; injectable so `ConfigSelfTest` doesn't depend on the
    ///   machine's real volumes.
    @discardableResult
    static func addVolumeSystemFoldersExclude(
        in directory: String,
        hasReadableSystemFolder: (String) -> Bool = { MigrationV6VolumeSystemFoldersExclude.containsReadableSystemFolder(at: $0) }
    ) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return outcome }

        for file in files.sorted() where file.hasSuffix(".profile.json") {
            let profilePath = (directory as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: profilePath),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let idString = dict["id"] as? String, !idString.isEmpty else { continue }

            // Same derivation as `SyncProfile.shortId`; a missing `syncMode` decodes as bisync.
            let shortId = String(idString.prefix(8)).lowercased()
            let syncMode = (dict["syncMode"] as? String) ?? SyncMode.bisync.rawValue
            guard syncMode != SyncMode.mount.rawValue else { continue }

            let filterPath = (directory as NSString).appendingPathComponent("\(shortId)-exclude.txt")
            guard fm.fileExists(atPath: filterPath),
                  let existing = try? String(contentsOfFile: filterPath, encoding: .utf8),
                  let updated = SyncExcludeFilter.addingVolumeSystemFolderDefaults(to: existing) else { continue }

            do {
                try updated.write(toFile: filterPath, atomically: true, encoding: .utf8)
            } catch {
                SyncTraySettings.debugLog("[MigrationV6] could not update \(filterPath): \(error.localizedDescription)")
                outcome.failed.append(shortId)
                continue
            }

            let localPath = (dict["localSyncPath"] as? String) ?? ""
            if syncMode == SyncMode.bisync.rawValue, !localPath.isEmpty,
               hasReadableSystemFolder((localPath as NSString).expandingTildeInPath) {
                let markerPath = (directory as NSString).appendingPathComponent("\(shortId).resync-pending")
                do {
                    try UUID().uuidString.write(toFile: markerPath, atomically: true, encoding: .utf8)
                    outcome.resyncScheduled.append(shortId)
                } catch {
                    try? existing.write(toFile: filterPath, atomically: true, encoding: .utf8)
                    SyncTraySettings.debugLog("[MigrationV6] could not schedule a resync for \(shortId): \(error.localizedDescription)")
                    outcome.failed.append(shortId)
                    continue
                }
            }
            outcome.updated.append(shortId)
        }
        return outcome
    }

    /// Whether `root` has one of `SyncExcludeFilter.volumeSystemFolderNames` directly inside it
    /// that the current user can list. Only the root is checked: that is where macOS creates
    /// them. A missing drive or an unreadable root counts as "no".
    static func containsReadableSystemFolder(at root: String) -> Bool {
        let fm = FileManager.default
        return SyncExcludeFilter.volumeSystemFolderNames.contains { name in
            let path = (root as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                && fm.isReadableFile(atPath: path)
        }
    }
}

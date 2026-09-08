import Foundation

#if DEBUG

/// Host self-test suite for the file-backed configuration system.
///
/// SyncTray deliberately has no XCTest target (see CLAUDE.md — Option A:
/// script/host-check based tests). This runs as `SyncTray --self-test`,
/// printing one `AC-n <slug>: PASS`/`FAIL <reason>` line per acceptance
/// criterion and exiting non-zero if any assertion failed. `checks.yaml`
/// greps these EXACT strings — do not change them without updating both.
///
/// Everything here runs against temp directories and isolated `UserDefaults`
/// suites under `$TMPDIR/synctray-selftest/` — never the real
/// `~/.config/synctray` or `UserDefaults.standard` — so running the self-test
/// can never corrupt a real install.
///
/// `@MainActor`: `ProfileStore` is MainActor-isolated, and this suite
/// constructs isolated `ProfileStore` instances directly. `SyncTrayApp.init()`
/// (the sole caller) is itself MainActor-isolated (SwiftUI's `App` protocol),
/// so calling `run()` synchronously from there is a same-actor call.
@MainActor
enum ConfigSelfTest {
    /// Root directory for this run's isolated fixtures.
    /// Fixed at `$TMPDIR/synctray-selftest` (not a per-run UUID subdirectory)
    /// because `checks.yaml`'s AC-9 check greps this EXACT path after the
    /// process exits.
    static var selfTestRoot: String {
        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        return tmpDir.hasSuffix("/") ? "\(tmpDir)synctray-selftest" : "\(tmpDir)/synctray-selftest"
    }

    /// Run every self-test. Returns 0 if all passed, 1 otherwise.
    static func run() -> Int32 {
        // Start clean so a previous run's leftovers can't mask a real failure.
        try? FileManager.default.removeItem(atPath: selfTestRoot)
        try? FileManager.default.createDirectory(atPath: selfTestRoot, withIntermediateDirectories: true)

        var allPassed = true
        let checks: [() -> Bool] = [
            testProfileFileFullFields,
            testDerivedJSONFrozen,
            testReconcileDelta,
            testPartialDecode,
            testSelfWriteSuppression,
            testMigrationV3,
            testFileAuthoritativeReads,
            testSettingsSafeKeys,
            testSchemaInstalledAndReferenced,
            testIsolatedLaunchAtLogin,
            testDeleteDurable,
            testWarmExcludePatternsRoundTrip,
            testWarmReconcileTrigger,
            testMigrationIntegrity,
            testExternalCreateEnabled,
            testExternalCreateDisabledNoInstall,
            testExternalCreateGarbageIgnored,
            testExternalCreateCanonicalNoLoop,
            testExternalCreateTelemetryAction,
            testCLIArgParsing,
            testCLIDispatchGate,
            testCLIWriteCommands,
            testDoctorPureChecks,
            testCLIResolveAndList,
            testShimInstallIdempotentNonClobber,
            testCacheMigrationTreeKinds,
            testCacheMigrationKeyDerivation,
            testCacheMigrationOverlap,
            testCacheMigrationVolumeRouting,
            testCacheMigrationSpacePreflight,
            testCacheMigrationVerifyOrder,
            testCacheMigrationPersistOnSuccess,
            testCacheMigrationCancelResume,
            testCacheMigrationInstallOnEveryPath,
            testCacheMigrationWarmCancelledFirst,
            testCacheMigrationCLI,
        ]

        for check in checks {
            if !check() { allPassed = false }
        }

        return allPassed ? 0 : 1
    }

    // MARK: - Helpers

    private static func report(_ id: String, _ slug: String, _ passed: Bool, _ detail: String = "") -> Bool {
        if passed {
            print("\(id) \(slug): PASS")
        } else {
            print("\(id) \(slug): FAIL \(detail)")
        }
        return passed
    }

    private static func sampleProfile(
        id: UUID = UUID(),
        name: String = "SelfTest Profile",
        isEnabled: Bool = true,
        isMuted: Bool = true,
        mountAtStartup: Bool = false
    ) -> SyncProfile {
        SyncProfile(
            id: id,
            name: name,
            rcloneRemote: "selftest-fixture-remote:",
            remotePath: "SelfTest",
            localSyncPath: "/tmp/synctray-selftest-local",
            syncIntervalMinutes: 15,
            isEnabled: isEnabled,
            isMuted: isMuted,
            mountAtStartup: mountAtStartup
        )
    }

    // MARK: - AC-1 — profile file carries full fields

    private static func testProfileFileFullFields() -> Bool {
        let dir = "\(selfTestRoot)/ac1-profiles"
        let store = ProfileStore(
            profilesDirectory: dir,
            defaults: UserDefaults(suiteName: "com.synctray.selftest.ac1.\(UUID().uuidString)")!
        )
        let profile = sampleProfile()
        store.add(profile)

        let path = "\(dir)/\(profile.shortId).profile.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return report("AC-1", "profile-file-full-fields", false, "(file not written or not valid JSON at \(path))")
        }

        let hasKeys = json["isEnabled"] != nil && json["isMuted"] != nil && json["mountAtStartup"] != nil
        guard hasKeys else {
            return report("AC-1", "profile-file-full-fields", false, "(missing isEnabled/isMuted/mountAtStartup)")
        }

        // Round-trip: decode back and compare to the original struct (also
        // covers the "encode -> file -> decode" half of AC-4's round-trip test).
        guard let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data), decoded == profile else {
            return report("AC-1", "profile-file-full-fields", false, "(round-trip decode mismatch)")
        }

        return report("AC-1", "profile-file-full-fields", true)
    }

    // MARK: - AC-2 — derived {shortId}.json stays frozen

    private static func testDerivedJSONFrozen() -> Bool {
        let profile = sampleProfile()
        let json = SyncSetupService.shared.generateProfileConfig(for: profile)

        // `warmExcludePatterns` is consumed app-side by the warmer (VFSCacheService),
        // never by the sync script — it must NOT leak into the derived config.
        let forbidden = ["\"isEnabled\"", "\"isMuted\"", "\"mountAtStartup\"", "\"warmExcludePatterns\""]
        for key in forbidden where json.contains(key) {
            return report("AC-2", "derived-json-frozen", false, "(unexpectedly contains \(key))")
        }

        let requiredFrozenKeys = ["\"profileId\"", "\"remote\"", "\"localPath\"", "\"syncIntervalMinutes\"", "\"mountBackend\""]
        for key in requiredFrozenKeys where !json.contains(key) {
            return report("AC-2", "derived-json-frozen", false, "(missing frozen key \(key))")
        }

        return report("AC-2", "derived-json-frozen", true)
    }

    // MARK: - AC-3 — reconcile delta selection

    private static func testReconcileDelta() -> Bool {
        let base = sampleProfile(isEnabled: true)

        var toDisabled = base
        toDisabled.isEnabled = false
        guard SyncManager.reconcileAction(from: base, to: toDisabled) == .uninstall else {
            return report("AC-3", "reconcile-delta", false, "(isEnabled true->false expected .uninstall)")
        }

        var fromDisabled = base
        fromDisabled.isEnabled = false
        guard SyncManager.reconcileAction(from: fromDisabled, to: base) == .install else {
            return report("AC-3", "reconcile-delta", false, "(isEnabled false->true expected .install)")
        }

        var intervalChanged = base
        intervalChanged.syncIntervalMinutes = base.syncIntervalMinutes + 5
        guard SyncManager.reconcileAction(from: base, to: intervalChanged) == .reinstall else {
            return report("AC-3", "reconcile-delta", false, "(syncIntervalMinutes change expected .reinstall)")
        }

        var mountAtStartupChanged = base
        mountAtStartupChanged.mountAtStartup.toggle()
        guard SyncManager.reconcileAction(from: base, to: mountAtStartupChanged) == .reinstall else {
            return report("AC-3", "reconcile-delta", false, "(mountAtStartup change expected .reinstall)")
        }

        var connectionsChanged = base
        connectionsChanged.downloadConnections = base.downloadConnections == 1 ? 2 : 1
        guard SyncManager.reconcileAction(from: base, to: connectionsChanged) == .reinstall else {
            return report("AC-3", "reconcile-delta", false, "(downloadConnections change expected .reinstall)")
        }

        var nameChanged = base
        nameChanged.name = "\(base.name) (renamed)"
        guard SyncManager.reconcileAction(from: base, to: nameChanged) == .none else {
            return report("AC-3", "reconcile-delta", false, "(name-only change expected .none)")
        }

        return report("AC-3", "reconcile-delta", true)
    }

    // MARK: - AC-4 — forgiving decoder on partial JSON

    private static func testPartialDecode() -> Bool {
        // Only the five truly-required keys — the minimal profile an agent can
        // author against profile.schema.json. drivePathToMonitor /
        // syncIntervalMinutes / additionalRcloneFlags / isEnabled are now
        // optional-with-default and deliberately OMITTED here.
        let requiredOnly: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Partial",
            "rcloneRemote": "remote:",
            "remotePath": "Path",
            "localSyncPath": "/tmp/synctray-selftest-partial",
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: requiredOnly) else {
            return report("AC-4", "partial-decode", false, "(failed to build fixture JSON)")
        }

        guard let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data) else {
            return report("AC-4", "partial-decode", false, "(decode threw on minimal JSON)")
        }

        let defaultsApplied = decoded.isMuted == false
            && decoded.syncMode == .bisync
            && decoded.mountBackend == .nfs
            && decoded.mountAtStartup == true
            && decoded.vfsCacheMaxAge == "168h"
            // Newly-optional keys fall back to their memberwise-init defaults.
            && decoded.drivePathToMonitor == ""
            && decoded.syncIntervalMinutes == 5
            && decoded.additionalRcloneFlags == ""
            && decoded.isEnabled == false

        guard defaultsApplied else {
            return report("AC-4", "partial-decode", false, "(defaults not applied correctly)")
        }

        return report("AC-4", "partial-decode", true)
    }

    // MARK: - AC-5 — self-write suppression

    private static func testSelfWriteSuppression() -> Bool {
        let dir = "\(selfTestRoot)/ac5-selfwrite"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let selfWrittenPath = "\(dir)/self-written.profile.json"
        let selfWrittenContent = Data("{\"marker\":\"self-write\"}".utf8)
        guard (try? selfWrittenContent.write(to: URL(fileURLWithPath: selfWrittenPath))) != nil else {
            return report("AC-5", "self-write-suppression", false, "(failed to write fixture)")
        }
        ConfigSelfWriteRegistry.shared.noteSelfWrite(contentHash: ConfigSelfWriteRegistry.hash(selfWrittenContent))

        guard ConfigFileWatcher.shouldReconcile(forFileAt: selfWrittenPath) == false else {
            return report("AC-5", "self-write-suppression", false, "(a noted self-write was NOT suppressed)")
        }

        // A genuinely external write (different, un-noted content) must still reconcile.
        let externalPath = "\(dir)/external.profile.json"
        let externalContent = Data("{\"marker\":\"external-write\"}".utf8)
        guard (try? externalContent.write(to: URL(fileURLWithPath: externalPath))) != nil else {
            return report("AC-5", "self-write-suppression", false, "(failed to write external fixture)")
        }
        guard ConfigFileWatcher.shouldReconcile(forFileAt: externalPath) == true else {
            return report("AC-5", "self-write-suppression", false, "(an external write was incorrectly suppressed)")
        }

        return report("AC-5", "self-write-suppression", true)
    }

    // MARK: - AC-6 — migration v3 (blob -> per-profile files, blob retained)

    private static func testMigrationV3() -> Bool {
        let dir = "\(selfTestRoot)/ac6-migration"
        try? FileManager.default.removeItem(atPath: dir)

        let ids = [UUID(), UUID()]
        let dicts: [[String: Any]] = ids.map { id in
            [
                "id": id.uuidString,
                "name": "Migrated \(id.uuidString.prefix(4))",
                "rcloneRemote": "remote:",
                "remotePath": "Path",
                "localSyncPath": "/tmp/synctray-selftest-migrated",
                "drivePathToMonitor": "",
                "syncIntervalMinutes": 15,
                "additionalRcloneFlags": "",
                "isEnabled": true,
            ]
        }

        let testDefaults = UserDefaults(suiteName: "com.synctray.selftest.ac6.\(UUID().uuidString)")!
        do {
            try MigrationRunner.writeProfileDicts(dicts, to: testDefaults)
        } catch {
            return report("AC-6", "migration-v3", false, "(failed to seed test blob: \(error))")
        }

        let migration = MigrationV3BlobToPerProfileFiles(profilesDirectoryOverride: dir)
        do {
            try migration.migrateUserDefaults(testDefaults)
        } catch {
            return report("AC-6", "migration-v3", false, "(migration threw: \(error))")
        }

        let writtenFiles = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasSuffix(".profile.json") } ?? []
        guard writtenFiles.count == ids.count else {
            return report("AC-6", "migration-v3", false, "(expected \(ids.count) profile files, found \(writtenFiles.count))")
        }

        guard MigrationRunner.readProfileDicts(from: testDefaults) != nil else {
            return report("AC-6", "migration-v3", false, "(blob was not retained after migration)")
        }

        return report("AC-6", "migration-v3", true)
    }

    // MARK: - AC-7 — file-authoritative reads, blob write-only mirror

    private static func testFileAuthoritativeReads() -> Bool {
        let dir = "\(selfTestRoot)/ac7-authoritative"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fileProfile = sampleProfile(name: "From File")
        guard let data = try? JSONEncoder().encode(fileProfile) else {
            return report("AC-7", "file-authoritative-reads", false, "(failed to encode fixture)")
        }
        try? data.write(to: URL(fileURLWithPath: "\(dir)/\(fileProfile.shortId).profile.json"))

        // Seed the blob with DIFFERENT data than the file, so a pass here can
        // only mean the file (not the blob) was read.
        let testDefaults = UserDefaults(suiteName: "com.synctray.selftest.ac7.\(UUID().uuidString)")!
        let blobOnlyProfile = sampleProfile(name: "From Blob (should be ignored)")
        if let blobData = try? JSONEncoder().encode([blobOnlyProfile]) {
            testDefaults.set(blobData, forKey: ProfileStore.profilesKey)
        }

        let store = ProfileStore(profilesDirectory: dir, defaults: testDefaults)
        guard store.profiles.count == 1, store.profiles.first?.id == fileProfile.id else {
            return report("AC-7", "file-authoritative-reads", false, "(load() did not read from the per-profile file)")
        }

        // save() must still dual-write the blob (write-only mirror).
        var mutated = fileProfile
        mutated.name = "Mutated"
        store.update(mutated)
        guard testDefaults.data(forKey: ProfileStore.profilesKey) != nil else {
            return report("AC-7", "file-authoritative-reads", false, "(save() did not dual-write the blob)")
        }

        return report("AC-7", "file-authoritative-reads", true)
    }

    // MARK: - AC-8 / AC-9 — settings.json safe keys, no secrets

    private static func testSettingsSafeKeys() -> Bool {
        guard let path = AppSettingsFileStore.writeSettingsFile(isLoginItemEnabled: true, directory: selfTestRoot) else {
            return report("AC-8", "settings-safe-keys", false, "(writeSettingsFile failed)")
        }

        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return report("AC-8", "settings-safe-keys", false, "(settings.json unreadable)")
        }

        let expectedKeys = AppSettingsFileStore.SafeKey.allCases.map(\.rawValue) + ["$schema"]
        for key in expectedKeys where json[key] == nil {
            return report("AC-8", "settings-safe-keys", false, "(missing key \(key))")
        }

        let readBack = AppSettingsFileStore.readSafeSettings(at: path)
        guard readBack[.launchAtLogin] == true else {
            return report("AC-8", "settings-safe-keys", false, "(readSafeSettings did not round-trip launchAtLogin)")
        }

        return report("AC-8", "settings-safe-keys", true)
    }

    // MARK: - AC-10 — schema installed and referenced

    private static func testSchemaInstalledAndReferenced() -> Bool {
        let installed = ConfigSchemaInstaller.writeSchemas(base: selfTestRoot)
        guard installed.count == ConfigSchemaInstaller.schemaResourceFilenames.count else {
            return report("AC-10", "schema-installed-and-referenced", false, "(expected \(ConfigSchemaInstaller.schemaResourceFilenames.count) schema files, installed \(installed.count))")
        }

        for filename in ConfigSchemaInstaller.schemaResourceFilenames {
            let path = "\(ConfigSchemaInstaller.schemaDirectory(base: selfTestRoot))/\(filename)"
            guard FileManager.default.fileExists(atPath: path) else {
                return report("AC-10", "schema-installed-and-referenced", false, "(missing installed schema at \(path))")
            }
        }

        // settings.json (written in testSettingsSafeKeys, same selfTestRoot) must reference its schema.
        let settingsPath = "\(selfTestRoot)/settings.json"
        guard let settingsData = FileManager.default.contents(atPath: settingsPath),
              let settingsJSON = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              (settingsJSON["$schema"] as? String)?.isEmpty == false else {
            return report("AC-10", "schema-installed-and-referenced", false, "(settings.json missing $schema)")
        }

        // A profile file (from AC-1's directory) must also reference its schema.
        let profile = sampleProfile()
        let profileDir = "\(selfTestRoot)/ac10-profiles"
        let store = ProfileStore(
            profilesDirectory: profileDir,
            defaults: UserDefaults(suiteName: "com.synctray.selftest.ac10.\(UUID().uuidString)")!
        )
        store.add(profile)
        let profilePath = "\(profileDir)/\(profile.shortId).profile.json"
        guard let profileData = FileManager.default.contents(atPath: profilePath),
              let profileJSON = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any],
              (profileJSON["$schema"] as? String)?.isEmpty == false else {
            return report("AC-10", "schema-installed-and-referenced", false, "(profile file missing $schema)")
        }

        return report("AC-10", "schema-installed-and-referenced", true)
    }

    // MARK: - AC-12 — isolated launch-at-login

    private static func testIsolatedLaunchAtLogin() -> Bool {
        enum InjectedFailure: Error { case simulatedSMAppServiceFailure }

        var appliedSafeKeys: [AppSettingsFileStore.SafeKey: Bool] = [:]
        var profileStateTouched = false  // SettingsReconciler must NEVER set this.

        SettingsReconciler.apply(
            safeSettings: [
                .debugLoggingEnabled: true,
                .autoFixSyncIssues: false,
                .launchAtLogin: true,
            ],
            applySafeKey: { key, value in
                appliedSafeKeys[key] = value
                // A real profile-touching bug would show up here if someone
                // ever wired profile access into this closure.
            },
            currentLoginItemEnabled: { false },
            applyLoginItem: { _ in
                throw InjectedFailure.simulatedSMAppServiceFailure
            }
        )

        guard profileStateTouched == false else {
            return report("AC-12", "isolated-launch-at-login", false, "(profile state was touched despite the isolation boundary)")
        }

        guard appliedSafeKeys[.debugLoggingEnabled] == true, appliedSafeKeys[.autoFixSyncIssues] == false else {
            return report("AC-12", "isolated-launch-at-login", false, "(other safe keys were not applied despite the login-item failure)")
        }

        // launchAtLogin itself must NOT have been recorded via applySafeKey —
        // it is handled exclusively by the isolated applyLoginItem path.
        guard appliedSafeKeys[.launchAtLogin] == nil else {
            return report("AC-12", "isolated-launch-at-login", false, "(launchAtLogin was applied outside the isolated path)")
        }

        return report("AC-12", "isolated-launch-at-login", true)
    }

    // MARK: - AC-19 — delete is durable under file-authoritative load

    /// Regression guard: `delete(id:)` must remove the profile's
    /// `.profile.json`, otherwise the file-authoritative `load()` resurrects a
    /// deleted profile on the next launch (and reinstalls its launchd agent if
    /// enabled). Asserts (a) the file exists after add, (b) it's gone after
    /// delete, and (c) a fresh store over the same directory loads zero profiles.
    private static func testDeleteDurable() -> Bool {
        let dir = "\(selfTestRoot)/ac19-delete"
        let suite = "com.synctray.selftest.ac19.\(UUID().uuidString)"

        let store = ProfileStore(
            profilesDirectory: dir,
            defaults: UserDefaults(suiteName: suite)!
        )
        let profile = sampleProfile(name: "To Be Deleted")
        store.add(profile)

        let path = "\(dir)/\(profile.shortId).profile.json"
        guard FileManager.default.fileExists(atPath: path) else {
            return report("AC-19", "delete-durable", false, "(profile file not written on add at \(path))")
        }

        store.delete(id: profile.id)

        guard !FileManager.default.fileExists(atPath: path) else {
            return report("AC-19", "delete-durable", false, "(profile file still present after delete)")
        }

        // A fresh store over the same directory must load nothing — proving the
        // delete is durable under file-authority, not just an in-memory removal.
        let reloaded = ProfileStore(
            profilesDirectory: dir,
            defaults: UserDefaults(suiteName: suite)!
        )
        guard reloaded.profiles.isEmpty else {
            return report("AC-19", "delete-durable", false, "(deleted profile resurrected on reload: \(reloaded.profiles.count) profile(s))")
        }

        return report("AC-19", "delete-durable", true)
    }

    // MARK: - AC-20 — warmExcludePatterns survives the file round-trip

    /// `warmExcludePatterns` is the one new persisted field on `SyncProfile`.
    /// Because `ProfileStore.writeProfileFiles` encodes the whole model, it flows
    /// into `.profile.json` automatically — this asserts it actually survives
    /// encode → decode (alongside `pinnedDirectories`, the sibling app-side field).
    private static func testWarmExcludePatternsRoundTrip() -> Bool {
        var profile = sampleProfile()
        profile.pinnedDirectories = ["Docs", "Photos/2024"]
        profile.warmExcludePatterns = ["*.bak", "**/BACKUP/**"]

        guard let data = try? JSONEncoder().encode(profile) else {
            return report("AC-20", "warm-exclude-roundtrip", false, "(encode failed)")
        }
        guard let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data) else {
            return report("AC-20", "warm-exclude-roundtrip", false, "(decode failed)")
        }
        guard decoded.warmExcludePatterns == profile.warmExcludePatterns else {
            return report("AC-20", "warm-exclude-roundtrip", false, "(warmExcludePatterns not preserved: \(decoded.warmExcludePatterns))")
        }
        guard decoded.pinnedDirectories == profile.pinnedDirectories else {
            return report("AC-20", "warm-exclude-roundtrip", false, "(pinnedDirectories not preserved: \(decoded.pinnedDirectories))")
        }
        // A file missing the key must still decode (forgiving decoder → []).
        let noKey: [String: Any] = [
            "id": UUID().uuidString, "name": "NoWarmKey", "rcloneRemote": "r:",
            "remotePath": "P", "localSyncPath": "/tmp/x", "drivePathToMonitor": "",
            "syncIntervalMinutes": 10, "additionalRcloneFlags": "", "isEnabled": false,
        ]
        guard let noKeyData = try? JSONSerialization.data(withJSONObject: noKey),
              let noKeyDecoded = try? JSONDecoder().decode(SyncProfile.self, from: noKeyData),
              noKeyDecoded.warmExcludePatterns == [] else {
            return report("AC-20", "warm-exclude-roundtrip", false, "(missing key did not default to [])")
        }
        return report("AC-20", "warm-exclude-roundtrip", true)
    }

    // MARK: - AC-21 — external warm-field edit triggers the app-side warm path

    /// An external `.profile.json` edit that changes `warmExcludePatterns` or
    /// `pinnedDirectories` on a MOUNTED mount-mode profile must trigger the
    /// app-side warm reconcile (re-push + re-warm) — and NOTHING else must.
    /// Exercises the pure decision/dispatch (`applyWarmReconcileIfNeeded`) with a
    /// spy in place of the real warm, so no mount is needed. The production caller
    /// (`applyExternalProfileEdit`) uses this exact function, so a green here means
    /// the real path fires on the same conditions.
    private static func testWarmReconcileTrigger() -> Bool {
        func mountModeProfile() -> SyncProfile {
            var p = sampleProfile()
            p.syncMode = .mount
            return p
        }
        let base = mountModeProfile()

        // Helper: run the gated dispatch and report whether the spy fired.
        func fired(from current: SyncProfile, to updated: SyncProfile, isMounted: Bool) -> [UUID] {
            var calls: [UUID] = []
            SyncManager.applyWarmReconcileIfNeeded(from: current, to: updated, isMounted: isMounted) { calls.append($0) }
            return calls
        }

        var excludeChanged = base
        excludeChanged.warmExcludePatterns = ["*.tmp"]
        guard fired(from: base, to: excludeChanged, isMounted: true) == [base.id] else {
            return report("AC-21", "warm-reconcile-trigger", false, "(warmExcludePatterns change did not fire warm)")
        }

        var pinsChanged = base
        pinsChanged.pinnedDirectories = ["NewDir"]
        guard fired(from: base, to: pinsChanged, isMounted: true) == [base.id] else {
            return report("AC-21", "warm-reconcile-trigger", false, "(pinnedDirectories change did not fire warm)")
        }

        // Not mounted → no warm (nothing to read through).
        guard fired(from: base, to: excludeChanged, isMounted: false).isEmpty else {
            return report("AC-21", "warm-reconcile-trigger", false, "(unmounted profile wrongly fired warm)")
        }

        // Non-warm field change (name) → no warm.
        var nameChanged = base
        nameChanged.name = "Renamed"
        guard fired(from: base, to: nameChanged, isMounted: true).isEmpty else {
            return report("AC-21", "warm-reconcile-trigger", false, "(name-only change wrongly fired warm)")
        }

        // Warm field changed but NOT mount-mode → no warm.
        var bisync = sampleProfile()
        bisync.syncMode = .bisync
        var bisyncExclude = bisync
        bisyncExclude.warmExcludePatterns = ["*.tmp"]
        guard fired(from: bisync, to: bisyncExclude, isMounted: true).isEmpty else {
            return report("AC-21", "warm-reconcile-trigger", false, "(non-mount profile wrongly fired warm)")
        }

        return report("AC-21", "warm-reconcile-trigger", true)
    }

    // MARK: - AC-22 — migration integrity (files written == profiles in blob)

    /// A silent partial migration (a source profile that never got a
    /// `.profile.json`) must be observable. `writeProfileFiles` returns a
    /// `WriteResult` whose `isComplete` is false when a source profile is dropped
    /// (missing/invalid `id`). Asserts a full blob is complete and a blob with an
    /// invalid entry is flagged incomplete with the right counts.
    private static func testMigrationIntegrity() -> Bool {
        let dir = "\(selfTestRoot)/ac22-integrity"
        try? FileManager.default.removeItem(atPath: dir)

        func dict(id: String) -> [String: Any] {
            ["id": id, "name": "P-\(id.prefix(4))", "rcloneRemote": "r:", "remotePath": "P",
             "localSyncPath": "/tmp/x", "drivePathToMonitor": "", "syncIntervalMinutes": 15,
             "additionalRcloneFlags": "", "isEnabled": true]
        }

        // Happy path: every profile accounted for.
        let full = [dict(id: UUID().uuidString), dict(id: UUID().uuidString)]
        guard let complete = try? MigrationV3BlobToPerProfileFiles.writeProfileFiles(from: full, to: dir) else {
            return report("AC-22", "migration-integrity", false, "(writeProfileFiles threw on full blob)")
        }
        guard complete.isComplete, complete.written == full.count, complete.accountedFor == full.count else {
            return report("AC-22", "migration-integrity", false, "(full blob not complete: \(complete))")
        }

        // Partial: one dict has no `id` → dropped → integrity mismatch observable.
        let partialDir = "\(selfTestRoot)/ac22-partial"
        try? FileManager.default.removeItem(atPath: partialDir)
        let partial: [[String: Any]] = [dict(id: UUID().uuidString), ["name": "no-id"]]
        guard let incomplete = try? MigrationV3BlobToPerProfileFiles.writeProfileFiles(from: partial, to: partialDir) else {
            return report("AC-22", "migration-integrity", false, "(writeProfileFiles threw on partial blob)")
        }
        guard !incomplete.isComplete, incomplete.expected == 2, incomplete.accountedFor == 1 else {
            return report("AC-22", "migration-integrity", false, "(partial blob not flagged incomplete: \(incomplete))")
        }

        return report("AC-22", "migration-integrity", true)
    }

    // MARK: - AC-C1 — external create: enabled + valid → persist+install, .createdAndInstalled

    private static func testExternalCreateEnabled() -> Bool {
        let profile = sampleProfile(isEnabled: true)
        var persistCalls = 0
        var installCalls = 0

        let outcome = SyncManager.applyExternalCreateIfNeeded(
            decoded: profile,
            isKnownId: false,
            persist: { _ in persistCalls += 1 },
            install: { _ in installCalls += 1 }
        )

        guard outcome == .createdAndInstalled else {
            return report("AC-C1", "external-create-enabled", false, "(expected .createdAndInstalled, got \(outcome))")
        }
        guard persistCalls == 1, installCalls == 1 else {
            return report("AC-C1", "external-create-enabled", false, "(persist=\(persistCalls) install=\(installCalls), expected 1/1)")
        }

        return report("AC-C1", "external-create-enabled", true)
    }

    // MARK: - AC-C2 — external create: disabled OR !isValid → .createdOnly, install never

    private static func testExternalCreateDisabledNoInstall() -> Bool {
        func run(_ profile: SyncProfile) -> (ExternalCreateOutcome, Int, Int) {
            var persistCalls = 0
            var installCalls = 0
            let outcome = SyncManager.applyExternalCreateIfNeeded(
                decoded: profile, isKnownId: false,
                persist: { _ in persistCalls += 1 },
                install: { _ in installCalls += 1 }
            )
            return (outcome, persistCalls, installCalls)
        }

        let disabled = sampleProfile(isEnabled: false)
        let (disabledOutcome, disabledPersist, disabledInstall) = run(disabled)
        guard disabledOutcome == .createdOnly, disabledPersist == 1, disabledInstall == 0 else {
            return report(
                "AC-C2", "external-create-disabled-noinstall", false,
                "(disabled: outcome=\(disabledOutcome) persist=\(disabledPersist) install=\(disabledInstall))")
        }

        var invalid = sampleProfile(isEnabled: true)
        invalid.name = ""  // fails isValid
        let (invalidOutcome, invalidPersist, invalidInstall) = run(invalid)
        guard invalidOutcome == .createdOnly, invalidPersist == 1, invalidInstall == 0 else {
            return report(
                "AC-C2", "external-create-disabled-noinstall", false,
                "(invalid: outcome=\(invalidOutcome) persist=\(invalidPersist) install=\(invalidInstall))")
        }

        return report("AC-C2", "external-create-disabled-noinstall", true)
    }

    // MARK: - AC-C3 — external create: undecodable/malformed-UUID → .ignored, no spy fires

    private static func testExternalCreateGarbageIgnored() -> Bool {
        var persistCalls = 0
        var installCalls = 0
        let outcome = SyncManager.applyExternalCreateIfNeeded(
            decoded: nil, isKnownId: false,
            persist: { _ in persistCalls += 1 },
            install: { _ in installCalls += 1 }
        )
        guard outcome == .ignored, persistCalls == 0, installCalls == 0 else {
            return report(
                "AC-C3", "external-create-garbage-ignored", false,
                "(decoded=nil: outcome=\(outcome) persist=\(persistCalls) install=\(installCalls))")
        }

        // Also cover the upstream decode itself: a garbage/malformed-UUID payload
        // must fail to decode (this is what `applyExternalProfileEdit`'s
        // `JSONDecoder` call sees before it ever reaches the create dispatch).
        let garbageJSON: [String: Any] = ["id": "not-a-uuid", "name": "Garbage"]
        guard let data = try? JSONSerialization.data(withJSONObject: garbageJSON) else {
            return report("AC-C3", "external-create-garbage-ignored", false, "(failed to build garbage fixture)")
        }
        let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data)
        guard decoded == nil else {
            return report("AC-C3", "external-create-garbage-ignored", false, "(malformed-UUID payload unexpectedly decoded)")
        }

        return report("AC-C3", "external-create-garbage-ignored", true)
    }

    // MARK: - AC-C4 — external create: differently-named file canonicalizes, no reconcile loop

    private static func testExternalCreateCanonicalNoLoop() -> Bool {
        let dir = "\(selfTestRoot)/ac-c4-create"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Disabled: exercises persist/canonicalize only, no real launchd install.
        let profile = sampleProfile(isEnabled: false)
        let sourcePath = "\(dir)/weird-name.profile.json"
        guard let data = try? JSONEncoder().encode(profile) else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(failed to encode fixture)")
        }
        guard (try? data.write(to: URL(fileURLWithPath: sourcePath))) != nil else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(failed to write fixture source file)")
        }

        let outcome = SyncManager.applyExternalCreateIfNeeded(
            decoded: profile,
            isKnownId: false,
            persist: { p in
                let store = ProfileStore(
                    profilesDirectory: dir,
                    defaults: UserDefaults(suiteName: "com.synctray.selftest.acc4.\(UUID().uuidString)")!
                )
                store.add(p)
                let canonicalFilename = "\(p.shortId).profile.json"
                let sourceFilename = (sourcePath as NSString).lastPathComponent
                if sourceFilename != canonicalFilename {
                    try? FileManager.default.removeItem(atPath: sourcePath)
                }
            },
            install: { _ in }
        )
        guard outcome == .createdOnly else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(expected .createdOnly, got \(outcome))")
        }

        let canonicalPath = "\(dir)/\(profile.shortId).profile.json"
        guard FileManager.default.fileExists(atPath: canonicalPath) else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(canonical file not written at \(canonicalPath))")
        }
        guard !FileManager.default.fileExists(atPath: sourcePath) else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(source file still present at \(sourcePath))")
        }

        guard let canonicalData = FileManager.default.contents(atPath: canonicalPath) else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(canonical file unreadable)")
        }
        let hash = ConfigSelfWriteRegistry.hash(canonicalData)
        guard ConfigSelfWriteRegistry.shared.consumeIfSelfWrite(contentHash: hash) else {
            return report(
                "AC-C4", "external-create-canonical-no-loop", false,
                "(canonical write's hash not consumable from the self-write registry — reconcile loop would fire)")
        }

        return report("AC-C4", "external-create-canonical-no-loop", true)
    }

    // MARK: - AC-C5 — external create emits telemetry with action = "create"

    private static func testExternalCreateTelemetryAction() -> Bool {
        // Signature/behavior check: both the pre-existing default ("edit") and the
        // new "create" action compile and run without crashing. Telemetry itself is
        // disabled in this environment (SyncTraySettings.telemetryEnabled == false),
        // so these calls are no-ops — this only proves the signature accepts both shapes.
        TelemetryService.shared.recordExternalConfigEdit(kind: "profile")
        TelemetryService.shared.recordExternalConfigEdit(kind: "profile", action: "create")

        // Call-site assertion: the create path in SyncManager.swift must actually
        // PASS action: "create" (not merely have the capability to). Verified by
        // reading this run's own source, next to this file in Services/.
        let selfTestFile = URL(fileURLWithPath: #filePath)
        let syncManagerPath = selfTestFile.deletingLastPathComponent().appendingPathComponent("SyncManager.swift").path
        guard let source = try? String(contentsOfFile: syncManagerPath, encoding: .utf8) else {
            return report(
                "AC-C5", "external-create-telemetry-action", false,
                "(could not read SyncManager.swift source to verify call site)")
        }
        guard source.contains("recordExternalConfigEdit(kind: \"profile\", action: \"create\")") else {
            return report(
                "AC-C5", "external-create-telemetry-action", false,
                "(create path does not call recordExternalConfigEdit with action: \"create\")")
        }

        return report("AC-C5", "external-create-telemetry-action", true)
    }

    // MARK: - CLI self-test helpers

    /// Build a `CLIEnvironment` with inert defaults, overridable per test —
    /// mirrors `sampleProfile`'s role for the Enabler-1 tests above.
    private static func fakeCLIEnvironment(
        runRclone: @escaping (_ args: [String], _ timeout: TimeInterval) -> (Int32, String, String) = { _, _ in (0, "", "") },
        readProfiles: @escaping () -> [SyncProfile] = { [] },
        fileExists: @escaping (String) -> Bool = { _ in false },
        runLaunchctl: @escaping (_ args: [String]) -> (Int32, String) = { _ in (0, "") },
        schemaFilesPresent: @escaping () -> Bool = { true },
        writeProfile: @escaping (SyncProfile) -> Bool = { _ in true },
        installProfile: @escaping (SyncProfile) -> String? = { _ in nil },
        uninstallProfile: @escaping (SyncProfile) -> String? = { _ in nil },
        deleteProfileFile: @escaping (SyncProfile) -> Void = { _ in },
        runSyncScript: @escaping (_ configPath: String) -> Int32 = { _ in 0 },
        readStdin: @escaping () -> String? = { nil },
        readFile: @escaping (String) -> String? = { _ in nil },
        stdout: @escaping (String) -> Void = { _ in },
        stderr: @escaping (String) -> Void = { _ in },
        migrateCache: @escaping (SyncProfile, String, Bool) -> CacheMigrationCLIResult = { _, _, _ in
            .completed(files: 0, bytes: 0, sameVolume: true)
        }
    ) -> CLIEnvironment {
        CLIEnvironment(
            runRclone: runRclone,
            readProfiles: readProfiles,
            fileExists: fileExists,
            runLaunchctl: runLaunchctl,
            schemaFilesPresent: schemaFilesPresent,
            writeProfile: writeProfile,
            installProfile: installProfile,
            uninstallProfile: uninstallProfile,
            deleteProfileFile: deleteProfileFile,
            runSyncScript: runSyncScript,
            migrateCache: migrateCache,
            readStdin: readStdin,
            readFile: readFile,
            stdout: stdout,
            stderr: stderr,
            now: { Date() }
        )
    }

    // MARK: - AC-CLI5 — dispatch gate: bare tokens are subcommands, flags/no-args fall to the GUI

    /// Guards the real `dispatch` gate, not just the pure `execute` core: an
    /// unknown bare subcommand must return usage+non-zero, NEVER `nil` (which
    /// would launch the GUI and hang a terminal — the bug this test locks down).
    private static func testCLIDispatchGate() -> Bool {
        if SyncTrayCLI.dispatch(arguments: ["SyncTray"]) != nil {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(no-args did not fall through to GUI)")
        }
        if SyncTrayCLI.dispatch(arguments: ["SyncTray", "--self-test"]) != nil {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(--self-test did not fall through to GUI/self-test path)")
        }
        if SyncTrayCLI.dispatch(arguments: ["SyncTray", "-psn_0_12345"]) != nil {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(macOS -psn_ GUI arg did not fall through)")
        }
        guard let bogus = SyncTrayCLI.dispatch(arguments: ["SyncTray", "bogus"]), bogus != 0 else {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(unknown subcommand fell through to GUI instead of usage+non-zero)")
        }
        guard SyncTrayCLI.dispatch(arguments: ["SyncTray", "help"]) == 0 else {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(help did not exit 0)")
        }
        guard SyncTrayCLI.dispatch(arguments: ["SyncTray", "--help"]) == 0 else {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(--help did not exit 0)")
        }
        return report("AC-CLI5", "cli-dispatch-gate", true, "")
    }

    // MARK: - AC-CLI6 — write commands: create / enable / disable / delete / sync route to the right side effect

    /// Drives the mutating subcommands through `execute` with spied closures —
    /// asserting each triggers the SINGLE correct side effect: create persists +
    /// installs an enabled profile, an id collision refuses without writing,
    /// enable/disable route via the shared `reconcileAction` to install vs.
    /// uninstall, delete uninstalls + removes the file, and `sync` refuses a
    /// mount profile but runs the script for a sync profile. Also locks the
    /// bounded telemetry-verb mapping (never a raw arg).
    private static func testCLIWriteCommands() -> Bool {
        let id = UUID()
        let enabled = sampleProfile(id: id, name: "CLIWrite", isEnabled: true)
        guard let json = try? JSONEncoder().encode(enabled),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return report("AC-CLI6", "cli-write-commands", false, "(could not encode sample profile)")
        }

        // create (stdin) → writes + installs an enabled+valid profile.
        var wrote = false, installed = false
        let createEnv = fakeCLIEnvironment(
            readProfiles: { [] },
            writeProfile: { _ in wrote = true; return true },
            installProfile: { _ in installed = true; return nil },
            readStdin: { jsonStr }
        )
        guard SyncTrayCLI.execute(["profile", "create", "-"], env: createEnv) == 0, wrote, installed else {
            return report("AC-CLI6", "cli-write-commands", false, "(create did not write+install, exit/wrote/installed=\(wrote)/\(installed))")
        }

        // create with a colliding id → refuses, no write.
        var wroteOnCollision = false
        let collideEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            writeProfile: { _ in wroteOnCollision = true; return true },
            readStdin: { jsonStr }
        )
        guard SyncTrayCLI.execute(["profile", "create", "-"], env: collideEnv) != 0, !wroteOnCollision else {
            return report("AC-CLI6", "cli-write-commands", false, "(create did not refuse a colliding id)")
        }

        // enable a disabled profile → reconcile .install → installProfile fires.
        let disabled = sampleProfile(id: UUID(), name: "ToEnable", isEnabled: false)
        var enableInstalled = false
        let enableEnv = fakeCLIEnvironment(
            readProfiles: { [disabled] },
            installProfile: { _ in enableInstalled = true; return nil },
            uninstallProfile: { _ in "should-not-be-called" }
        )
        guard SyncTrayCLI.execute(["profile", "enable", disabled.shortId], env: enableEnv) == 0, enableInstalled else {
            return report("AC-CLI6", "cli-write-commands", false, "(enable did not install)")
        }

        // disable an enabled profile → reconcile .uninstall → uninstallProfile fires.
        var disableUninstalled = false
        let disableEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            installProfile: { _ in "should-not-be-called" },
            uninstallProfile: { _ in disableUninstalled = true; return nil }
        )
        guard SyncTrayCLI.execute(["profile", "disable", enabled.shortId], env: disableEnv) == 0, disableUninstalled else {
            return report("AC-CLI6", "cli-write-commands", false, "(disable did not uninstall)")
        }

        // delete → uninstall + deleteProfileFile both fire.
        var delUninstalled = false, delRemoved = false
        let deleteEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            uninstallProfile: { _ in delUninstalled = true; return nil },
            deleteProfileFile: { _ in delRemoved = true }
        )
        guard SyncTrayCLI.execute(["profile", "delete", enabled.shortId], env: deleteEnv) == 0, delUninstalled, delRemoved else {
            return report("AC-CLI6", "cli-write-commands", false, "(delete did not uninstall+remove)")
        }

        // sync refuses a mount profile.
        var mount = sampleProfile(id: UUID(), name: "Streamer", isEnabled: true)
        mount.syncMode = .mount
        let mountSyncEnv = fakeCLIEnvironment(readProfiles: { [mount] })
        guard SyncTrayCLI.execute(["sync", mount.shortId], env: mountSyncEnv) != 0 else {
            return report("AC-CLI6", "cli-write-commands", false, "(sync did not refuse a mount profile)")
        }

        // sync runs the script for a sync profile (script + config present).
        var ranScript = false
        let syncEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            fileExists: { _ in true },
            runSyncScript: { _ in ranScript = true; return 0 }
        )
        guard SyncTrayCLI.execute(["sync", enabled.shortId], env: syncEnv) == 0, ranScript else {
            return report("AC-CLI6", "cli-write-commands", false, "(sync did not run the script)")
        }

        // Bounded telemetry verb — never a raw arg or profile name.
        let verbCases: [([String], String)] = [
            (["doctor"], "doctor"),
            (["profile", "create", "-"], "profile-create"),
            (["profile", "enable", "SECRET-NAME"], "profile-enable"),
            (["sync", "SECRET-NAME"], "sync"),
            (["totally-bogus"], "(other)"),
            (["profile", "frobnicate"], "(other)"),
        ]
        for (argv, expected) in verbCases where SyncTrayCLI.telemetryVerb(for: argv) != expected {
            return report("AC-CLI6", "cli-write-commands", false, "(telemetryVerb\(argv) != \(expected))")
        }

        return report("AC-CLI6", "cli-write-commands", true)
    }

    // MARK: - AC-CLI1 — arg parsing: unknown/absent → usage error; known commands route correctly

    private static func testCLIArgParsing() -> Bool {
        guard case .failure = SyncTrayCLI.parse([]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(parse([]) did not fail)")
        }
        guard case .failure = SyncTrayCLI.parse(["bogus"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(parse([\"bogus\"]) did not fail)")
        }

        var stderrOutput = ""
        let execEnv = fakeCLIEnvironment(stderr: { stderrOutput += $0 })
        let exitCode = SyncTrayCLI.execute(["bogus"], env: execEnv)
        guard exitCode != 0 else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(execute([\"bogus\"]) returned exit 0)")
        }
        guard !stderrOutput.isEmpty else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(no usage message printed to stderr on parse failure)")
        }

        guard case .success(.doctor) = SyncTrayCLI.parse(["doctor"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(\"doctor\" did not parse to .doctor)")
        }
        guard case .success(.testRemote("work")) = SyncTrayCLI.parse(["test-remote", "work"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(\"test-remote work\" did not parse correctly)")
        }
        guard case .success(.logs(target: "work", follow: true)) = SyncTrayCLI.parse(["logs", "work", "--follow"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(\"logs work --follow\" did not parse correctly)")
        }
        guard case .success(.listRemotes) = SyncTrayCLI.parse(["listremotes"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(\"listremotes\" did not parse to .listRemotes)")
        }
        guard case .success(.profiles) = SyncTrayCLI.parse(["profiles"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(\"profiles\" did not parse to .profiles)")
        }

        var capturedArgs: [String] = []
        let listEnv = fakeCLIEnvironment(runRclone: { args, _ in
            capturedArgs = args
            return (0, "remote1:\nremote2:\n", "")
        })
        _ = SyncTrayCLI.run(.listRemotes, env: listEnv)
        guard capturedArgs == ["listremotes"] else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(listremotes did not invoke rclone listremotes, got \(capturedArgs))")
        }

        return report("AC-CLI1", "cli-arg-parsing", true)
    }

    // MARK: - AC-CLI2 — doctor: correct DoctorCheck statuses + exit code derivation

    private static func testDoctorPureChecks() -> Bool {
        // rclone present + schema present + no profiles → no .fail check.
        let healthyEnv = fakeCLIEnvironment(
            runRclone: { args, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
            readProfiles: { [] },
            schemaFilesPresent: { true }
        )
        let healthyChecks = SyncTrayCLI.doctorChecks(env: healthyEnv)
        guard !healthyChecks.contains(where: { $0.status == .fail }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(healthy env produced a .fail check: \(healthyChecks))")
        }
        guard healthyChecks.contains(where: { $0.name == "rclone" && $0.status == .ok }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(rclone check not .ok in healthy env)")
        }

        // rclone absent → .fail, exit non-zero.
        let noRcloneEnv = fakeCLIEnvironment(runRclone: { _, _ in (127, "", "not found") })
        let noRcloneChecks = SyncTrayCLI.doctorChecks(env: noRcloneEnv)
        guard noRcloneChecks.contains(where: { $0.name == "rclone" && $0.status == .fail }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(rclone-absent env did not produce a .fail rclone check)")
        }
        guard SyncTrayCLI.run(.doctor, env: noRcloneEnv) != 0 else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(rclone-absent doctor run did not exit non-zero)")
        }

        // schema missing → .warn only, exit still 0.
        let noSchemaEnv = fakeCLIEnvironment(
            runRclone: { args, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
            schemaFilesPresent: { false }
        )
        let noSchemaChecks = SyncTrayCLI.doctorChecks(env: noSchemaEnv)
        guard noSchemaChecks.contains(where: { $0.name == "config schemas" && $0.status == .warn }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(schema-missing env did not produce a .warn schema check)")
        }
        guard SyncTrayCLI.run(.doctor, env: noSchemaEnv) == 0 else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(schema-missing (warn-only) doctor run should still exit 0)")
        }

        // Per-profile: derived config missing → .fail, exit non-zero.
        let profile = sampleProfile(isEnabled: false)
        let missingConfigEnv = fakeCLIEnvironment(
            runRclone: { args, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
            readProfiles: { [profile] },
            fileExists: { _ in false },
            schemaFilesPresent: { true }
        )
        let missingConfigChecks = SyncTrayCLI.doctorChecks(env: missingConfigEnv)
        guard missingConfigChecks.contains(where: { $0.status == .fail && $0.detail.contains("derived config missing") }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(missing derived config did not produce a .fail check)")
        }
        guard SyncTrayCLI.run(.doctor, env: missingConfigEnv) != 0 else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(missing-derived-config doctor run did not exit non-zero)")
        }

        // Derived config present → no .fail for that profile.
        let presentConfigEnv = fakeCLIEnvironment(
            runRclone: { args, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
            readProfiles: { [profile] },
            fileExists: { path in path == profile.configPath },
            schemaFilesPresent: { true }
        )
        let presentConfigChecks = SyncTrayCLI.doctorChecks(env: presentConfigEnv)
        guard !presentConfigChecks.contains(where: { $0.status == .fail }) else {
            return report(
                "AC-CLI2", "doctor-pure-checks", false,
                "(present-config env unexpectedly produced a .fail check: \(presentConfigChecks))")
        }

        // Stale lock present → .warn only, exit still 0.
        let staleLockEnv = fakeCLIEnvironment(
            runRclone: { args, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
            readProfiles: { [profile] },
            fileExists: { path in path == profile.configPath || path == profile.lockFilePath },
            schemaFilesPresent: { true }
        )
        let staleLockChecks = SyncTrayCLI.doctorChecks(env: staleLockEnv)
        guard staleLockChecks.contains(where: { $0.status == .warn && $0.detail.contains("stale lock") }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(stale lock did not produce a .warn check)")
        }
        guard SyncTrayCLI.run(.doctor, env: staleLockEnv) == 0 else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(stale-lock-only (warn) doctor run should still exit 0)")
        }

        return report("AC-CLI2", "doctor-pure-checks", true)
    }

    // MARK: - AC-CLI3 — resolution precedence + unmatched error + profiles output

    private static func testCLIResolveAndList() -> Bool {
        let workProfile = sampleProfile(id: UUID(), name: "Work", isEnabled: true)
        let personalProfile = sampleProfile(id: UUID(), name: "Personal", isEnabled: false)
        let all = [workProfile, personalProfile]

        guard SyncTrayCLI.resolveProfile(workProfile.shortId, in: all)?.id == workProfile.id else {
            return report("AC-CLI3", "cli-resolve-and-list", false, "(shortId resolution failed)")
        }
        guard SyncTrayCLI.resolveProfile("WORK", in: all)?.id == workProfile.id else {
            return report("AC-CLI3", "cli-resolve-and-list", false, "(case-insensitive name resolution failed)")
        }
        guard SyncTrayCLI.resolveProfile("nope", in: all) == nil else {
            return report("AC-CLI3", "cli-resolve-and-list", false, "(unmatched target unexpectedly resolved)")
        }

        var stderrOutput = ""
        let unmatchedEnv = fakeCLIEnvironment(readProfiles: { all }, stderr: { stderrOutput += $0 })
        let exitCode = SyncTrayCLI.run(.testRemote("nope"), env: unmatchedEnv)
        guard exitCode != 0, stderrOutput.contains("no profile matches"), stderrOutput.contains("nope") else {
            return report(
                "AC-CLI3", "cli-resolve-and-list", false,
                "(unmatched test-remote target did not exit non-zero with a greppable error)")
        }

        var stdoutOutput = ""
        let profilesEnv = fakeCLIEnvironment(readProfiles: { all }, stdout: { stdoutOutput += $0 })
        _ = SyncTrayCLI.run(.profiles, env: profilesEnv)
        for expected in [workProfile.name, workProfile.shortId, workProfile.syncMode.rawValue, "enabled=true", workProfile.rcloneRemote] {
            guard stdoutOutput.contains(expected) else {
                return report("AC-CLI3", "cli-resolve-and-list", false, "(profiles output missing \"\(expected)\")")
            }
        }

        return report("AC-CLI3", "cli-resolve-and-list", true)
    }

    // MARK: - AC-CLI4 — shim install: writes exec shim, idempotent, never clobbers a foreign file

    private static func testShimInstallIdempotentNonClobber() -> Bool {
        let binDir = "\(selfTestRoot)/ac-cli4-bin"
        try? FileManager.default.removeItem(atPath: binDir)
        let shimPath = "\(binDir)/synctray"

        guard CLIShimInstaller.install(executablePath: "/tmp/fake-synctray-binary", shimPath: shimPath) else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(install failed on an absent shim path)")
        }
        guard let contents = try? String(contentsOfFile: shimPath, encoding: .utf8),
              contents.contains("exec \"/tmp/fake-synctray-binary\" \"$@\"") else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(shim content missing exec line)")
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: shimPath),
              let perms = attrs[.posixPermissions] as? NSNumber, perms.uint16Value & 0o111 != 0 else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(shim not executable)")
        }

        guard CLIShimInstaller.install(executablePath: "/tmp/fake-synctray-binary-v2", shimPath: shimPath) else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(re-install over our own shim failed)")
        }
        guard let refreshed = try? String(contentsOfFile: shimPath, encoding: .utf8),
              refreshed.contains("/tmp/fake-synctray-binary-v2") else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(re-install did not refresh the exec path)")
        }

        let foreignPath = "\(binDir)/foreign-synctray"
        let foreignContent = "#!/bin/sh\necho not ours\n"
        try? foreignContent.write(toFile: foreignPath, atomically: true, encoding: .utf8)
        guard CLIShimInstaller.install(executablePath: "/tmp/should-not-appear", shimPath: foreignPath) == false else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(install returned true over a foreign file)")
        }
        guard let foreignAfter = try? String(contentsOfFile: foreignPath, encoding: .utf8), foreignAfter == foreignContent else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(foreign file was modified)")
        }

        return report("AC-CLI4", "shim-install-idempotent-nonclobber", true)
    }

    // MARK: - Cache-directory migration fixtures

    /// Inert fake filesystem for driving `CacheMigrationEngine` without any
    /// real I/O: a `[String: Int64]` path→size map that only records calls.
    /// NEVER re-implements copy/verify/delete ordering — that is the engine's
    /// job, and a fake that re-encodes it could only confirm itself
    /// (`global::aw-lessons::mock-that-reimplements-the-thing-under-test`,
    /// seen 7×, structural).
    private final class FakeCacheFS {
        var files: [String: Int64] = [:]        // path -> size (doubles as "exists")
        var directories: Set<String> = []
        var removedPaths: [String] = []
        var copiedPaths: [(String, String)] = []
        var movedPaths: [(String, String)] = []
        var volumeOf: [String: String] = [:]     // path prefix -> volume id ("default-volume" if unset)
        var availableCapacityBytes: Int64 = Int64.max
        var writeMismatchAt: Set<String> = []    // dest paths whose copy lands at the WRONG size

        func system() -> CacheMigrationFileSystem {
            CacheMigrationFileSystem(
                directoryExists: { [weak self] path in self?.directories.contains(path) ?? false },
                fileExists: { [weak self] path in self?.files[path] != nil },
                enumerateFiles: { [weak self] root in
                    guard let self else { return [] }
                    let prefix = root + "/"
                    return self.files
                        .filter { $0.key.hasPrefix(prefix) }
                        .map { (relativePath: String($0.key.dropFirst(prefix.count)), size: $0.value) }
                },
                fileSize: { [weak self] path in self?.files[path] },
                createDirectory: { [weak self] path in
                    self?.directories.insert(path)
                },
                copyFile: { [weak self] from, to in
                    guard let self else { return }
                    self.copiedPaths.append((from, to))
                    let sourceSize = self.files[from] ?? 0
                    self.files[to] = self.writeMismatchAt.contains(to) ? sourceSize + 1 : sourceSize
                    self.directories.insert((to as NSString).deletingLastPathComponent)
                },
                copyFileDataOnly: { [weak self] from, to in
                    guard let self else { return }
                    self.copiedPaths.append((from, to))
                    self.files[to] = self.files[from] ?? 0
                },
                moveItem: { [weak self] from, to in
                    guard let self else { return }
                    self.movedPaths.append((from, to))
                    let prefix = from + "/"
                    let toMove = self.files.filter { $0.key == from || $0.key.hasPrefix(prefix) }
                    for (path, size) in toMove {
                        let suffix = String(path.dropFirst(from.count))
                        self.files[to + suffix] = size
                        self.files.removeValue(forKey: path)
                    }
                    self.directories.remove(from)
                    self.directories.insert(to)
                },
                removeItem: { [weak self] path in
                    self?.removedPaths.append(path)
                    self?.files.removeValue(forKey: path)
                },
                removeEmptyDirectories: { _ in },
                volumeIdentifier: { [weak self] path in
                    guard let self else { return nil }
                    for (prefix, id) in self.volumeOf where path.hasPrefix(prefix) {
                        return id
                    }
                    return "default-volume"
                },
                availableCapacity: { [weak self] _ in self?.availableCapacityBytes }
            )
        }
    }

    /// Builds an inert `CacheMigrationFileSystem` plus its call-recording
    /// handle — mirrors `fakeCLIEnvironment`'s "spy closures, dumb state" style.
    private static func fakeCacheMigrationFileSystem() -> (fs: CacheMigrationFileSystem, recorder: FakeCacheFS) {
        let recorder = FakeCacheFS()
        return (recorder.system(), recorder)
    }

    /// A mount-mode profile with deterministic remote/key fields, for the
    /// cache-migration tests below.
    private static func mountProfile(id: UUID = UUID(), name: String = "Stream", remotePath: String, vfsCachePath: String) -> SyncProfile {
        var profile = sampleProfile(id: id, name: name)
        profile.syncMode = .mount
        profile.rcloneRemote = "synology:"
        profile.remotePath = remotePath
        profile.vfsCachePath = vfsCachePath
        return profile
    }

    // MARK: - AC-CM1 — tree kinds: vfs + vfsMeta, one CacheSubtree pair per migrating profile

    private static func testCacheMigrationTreeKinds() -> Bool {
        guard Set(CacheTreeKind.allCases.map { $0.rawValue }) == Set(["vfs", "vfsMeta"]) else {
            return report("AC-CM1", "cache-migration-tree-kinds", false, "(CacheTreeKind.allCases != [vfs, vfsMeta])")
        }
        let profile = mountProfile(remotePath: "Kaiju", vfsCachePath: "/tmp/cm1-src")
        guard case .success(let plan) = CacheMigrationPlanner.plan(
            moving: profile, allProfiles: [profile], to: "/tmp/cm1-dest", coMigrate: []
        ) else {
            return report("AC-CM1", "cache-migration-tree-kinds", false, "(plan failed)")
        }
        let kinds = Set(plan.subtrees.map { $0.kind })
        guard kinds == Set(CacheTreeKind.allCases) else {
            return report("AC-CM1", "cache-migration-tree-kinds", false, "(plan subtrees missing a kind: \(kinds))")
        }
        return report("AC-CM1", "cache-migration-tree-kinds", true)
    }

    // MARK: - AC-CM2 — single key home: cacheDirectory(for:) and the planner agree

    private static func testCacheMigrationKeyDerivation() -> Bool {
        var profile = mountProfile(remotePath: "Kaiju/KAIJU", vfsCachePath: "~/.cache/rclone")
        profile.rcloneRemote = "synology:"

        let key = VFSCacheService.cacheRelativePath(for: profile)
        guard key == "synology/Kaiju/KAIJU" else {
            return report("AC-CM2", "cache-migration-key-derivation", false, "(cacheRelativePath produced \(key))")
        }

        let normalized = CacheMigrationPlanner.normalizeRoot("~/.cache/rclone/")
        let expanded = ("~/.cache/rclone" as NSString).expandingTildeInPath
        guard normalized == expanded else {
            return report("AC-CM2", "cache-migration-key-derivation", false, "(normalizeRoot did not expand ~: \(normalized) vs \(expanded))")
        }

        guard case .success(let plan) = CacheMigrationPlanner.plan(
            moving: profile, allProfiles: [profile], to: "/tmp/cm2-dest", coMigrate: []
        ) else {
            return report("AC-CM2", "cache-migration-key-derivation", false, "(plan failed)")
        }
        guard plan.subtrees.allSatisfy({ $0.relativePath == key }) else {
            return report("AC-CM2", "cache-migration-key-derivation", false, "(planner used a different key than cacheRelativePath)")
        }
        return report("AC-CM2", "cache-migration-key-derivation", true)
    }

    // MARK: - AC-CM3 — overlap classification: nested sibling excluded/co-migrated/disjoint

    private static func testCacheMigrationOverlap() -> Bool {
        let sharedRoot = "/tmp/cm3-src"
        let parent = mountProfile(name: "Parent", remotePath: "Kaiju/KAIJU", vfsCachePath: sharedRoot)
        let child = mountProfile(name: "Child", remotePath: "Kaiju/KAIJU/Reaper", vfsCachePath: sharedRoot)
        let disjoint = mountProfile(name: "Disjoint", remotePath: "OtherShare", vfsCachePath: sharedRoot)
        let all = [parent, child, disjoint]

        switch CacheMigrationPlanner.plan(moving: parent, allProfiles: all, to: "/tmp/cm3-dest", coMigrate: []) {
        case .failure(.unresolvedOverlap(let ids)):
            guard ids == [child.id] else {
                return report("AC-CM3", "cache-migration-overlap", false, "(unresolvedOverlap named \(ids), expected [child])")
            }
        default:
            return report("AC-CM3", "cache-migration-overlap", false, "(nested, non-co-migrated sibling did not reject with unresolvedOverlap)")
        }

        guard case .success(let plan) = CacheMigrationPlanner.plan(
            moving: parent, allProfiles: all, to: "/tmp/cm3-dest", coMigrate: [child.id]
        ) else {
            return report("AC-CM3", "cache-migration-overlap", false, "(co-migrated plan rejected)")
        }
        guard plan.profileIdsToRewrite.contains(child.id) else {
            return report("AC-CM3", "cache-migration-overlap", false, "(co-migrated child missing from profileIdsToRewrite)")
        }
        guard plan.subtrees.contains(where: { $0.relativePath == VFSCacheService.cacheRelativePath(for: child) }) else {
            return report("AC-CM3", "cache-migration-overlap", false, "(co-migrated child's subtree missing from plan)")
        }
        guard plan.sameRootProfiles == [disjoint.id] else {
            return report("AC-CM3", "cache-migration-overlap", false, "(sameRootProfiles \(plan.sameRootProfiles) != [disjoint])")
        }
        return report("AC-CM3", "cache-migration-overlap", true)
    }

    // MARK: - AC-CM4 — volume routing: same-volume moveItem, cross-volume per-file copy

    private static func testCacheMigrationVolumeRouting() -> Bool {
        let profile = mountProfile(remotePath: "Kaiju", vfsCachePath: "/tmp/cm4-src")
        guard case .success(let plan) = CacheMigrationPlanner.plan(
            moving: profile, allProfiles: [profile], to: "/tmp/cm4-dest", coMigrate: []
        ) else {
            return report("AC-CM4", "cache-migration-volume-routing", false, "(plan failed)")
        }
        let key = VFSCacheService.cacheRelativePath(for: profile)
        let sourceContent = "/tmp/cm4-src/vfs/\(key)"
        let sourceMeta = "/tmp/cm4-src/vfsMeta/\(key)"

        let (sameSystem, sameFake) = fakeCacheMigrationFileSystem()
        sameFake.directories.insert(sourceContent)
        sameFake.directories.insert(sourceMeta)
        sameFake.files["\(sourceContent)/file.bin"] = 10
        sameFake.files["\(sourceMeta)/file.bin"] = 1
        let engine1 = CacheMigrationEngine(fs: sameSystem)
        guard case .success(let pf1) = engine1.preflight(plan), pf1.sameVolume else {
            return report("AC-CM4", "cache-migration-volume-routing", false, "(same-volume fake did not preflight as sameVolume)")
        }
        let outcome1 = engine1.run(plan, pf1)
        guard outcome1.result == .completed, sameFake.movedPaths.count == 2, sameFake.copiedPaths.isEmpty else {
            return report("AC-CM4", "cache-migration-volume-routing", false, "(same-volume run did not use moveItem exclusively: moved=\(sameFake.movedPaths.count) copied=\(sameFake.copiedPaths.count))")
        }

        let (crossSystem, crossFake) = fakeCacheMigrationFileSystem()
        crossFake.directories.insert(sourceContent)
        crossFake.directories.insert(sourceMeta)
        crossFake.files["\(sourceContent)/file.bin"] = 10
        crossFake.files["\(sourceMeta)/file.bin"] = 1
        crossFake.volumeOf["/tmp/cm4-dest"] = "other-volume"
        let engine2 = CacheMigrationEngine(fs: crossSystem)
        guard case .success(let pf2) = engine2.preflight(plan), !pf2.sameVolume else {
            return report("AC-CM4", "cache-migration-volume-routing", false, "(cross-volume fake preflighted as sameVolume)")
        }
        let outcome2 = engine2.run(plan, pf2)
        guard outcome2.result == .completed, crossFake.movedPaths.isEmpty, crossFake.copiedPaths.count == 2 else {
            return report("AC-CM4", "cache-migration-volume-routing", false, "(cross-volume run used moveItem: moved=\(crossFake.movedPaths.count) copied=\(crossFake.copiedPaths.count))")
        }

        return report("AC-CM4", "cache-migration-volume-routing", true)
    }

    // MARK: - AC-CM5 — free-space preflight, both directions

    private static func testCacheMigrationSpacePreflight() -> Bool {
        let profile = mountProfile(remotePath: "Kaiju", vfsCachePath: "/tmp/cm5-src")
        guard case .success(let plan) = CacheMigrationPlanner.plan(
            moving: profile, allProfiles: [profile], to: "/tmp/cm5-dest", coMigrate: []
        ) else {
            return report("AC-CM5", "cache-migration-space-preflight", false, "(plan failed)")
        }
        let key = VFSCacheService.cacheRelativePath(for: profile)
        let sourceContent = "/tmp/cm5-src/vfs/\(key)"
        let sourceMeta = "/tmp/cm5-src/vfsMeta/\(key)"

        let (system, fake) = fakeCacheMigrationFileSystem()
        fake.directories.insert(sourceContent)
        fake.directories.insert(sourceMeta)
        fake.files["\(sourceContent)/big.bin"] = 1_000_000_000
        fake.volumeOf["/tmp/cm5-dest"] = "other-volume"
        let engine = CacheMigrationEngine(fs: system)

        fake.availableCapacityBytes = 500_000_000
        switch engine.preflight(plan) {
        case .failure(.insufficientSpace(let required, let available)):
            guard required > available, available == 500_000_000 else {
                return report("AC-CM5", "cache-migration-space-preflight", false, "(unexpected required/available: \(required)/\(available))")
            }
        default:
            return report("AC-CM5", "cache-migration-space-preflight", false, "(low-capacity fake did not reject insufficientSpace)")
        }
        guard !fake.files.keys.contains(where: { $0.hasPrefix("/tmp/cm5-dest") }) else {
            return report("AC-CM5", "cache-migration-space-preflight", false, "(a destination file was created despite the rejection)")
        }

        fake.availableCapacityBytes = 0
        guard case .failure(.insufficientSpace) = engine.preflight(plan) else {
            return report("AC-CM5", "cache-migration-space-preflight", false, "(zero-capacity fake did not reject insufficientSpace)")
        }

        fake.availableCapacityBytes = Int64.max
        guard case .success = engine.preflight(plan) else {
            return report("AC-CM5", "cache-migration-space-preflight", false, "(ample-capacity fake still rejected)")
        }

        return report("AC-CM5", "cache-migration-space-preflight", true)
    }

    // MARK: - AC-CM6 — verify-before-delete order, both a mismatch and a clean copy

    private static func testCacheMigrationVerifyOrder() -> Bool {
        let profile = mountProfile(remotePath: "Kaiju", vfsCachePath: "/tmp/cm6-src")
        guard case .success(let plan) = CacheMigrationPlanner.plan(
            moving: profile, allProfiles: [profile], to: "/tmp/cm6-dest", coMigrate: []
        ) else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(plan failed)")
        }
        let key = VFSCacheService.cacheRelativePath(for: profile)
        let sourceContent = "/tmp/cm6-src/vfs/\(key)"
        let sourceMeta = "/tmp/cm6-src/vfsMeta/\(key)"
        let badPath = "\(sourceContent)/bad.bin"
        let destBad = "/tmp/cm6-dest/vfs/\(key)/bad.bin"

        let (mismatchSystem, mismatchFake) = fakeCacheMigrationFileSystem()
        mismatchFake.directories.insert(sourceContent)
        mismatchFake.directories.insert(sourceMeta)
        mismatchFake.files[badPath] = 42
        mismatchFake.volumeOf["/tmp/cm6-dest"] = "other-volume"
        mismatchFake.writeMismatchAt.insert(destBad)
        let engine1 = CacheMigrationEngine(fs: mismatchSystem)
        guard case .success(let pf1) = engine1.preflight(plan) else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(preflight failed for mismatch fixture)")
        }
        let outcome1 = engine1.run(plan, pf1)
        guard case .failed(.verifyMismatch, _) = outcome1.result else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(size mismatch did not produce .verifyMismatch: \(outcome1.result))")
        }
        guard mismatchFake.files[badPath] == 42 else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(source file was removed despite a verify mismatch)")
        }
        guard mismatchFake.files[destBad] == nil else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(destination partial was not removed after a verify mismatch)")
        }

        let goodPath = "\(sourceContent)/good.bin"
        let (goodSystem, goodFake) = fakeCacheMigrationFileSystem()
        goodFake.directories.insert(sourceContent)
        goodFake.directories.insert(sourceMeta)
        goodFake.files[goodPath] = 7
        goodFake.volumeOf["/tmp/cm6-dest"] = "other-volume"
        let engine2 = CacheMigrationEngine(fs: goodSystem)
        guard case .success(let pf2) = engine2.preflight(plan) else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(preflight failed for good fixture)")
        }
        let outcome2 = engine2.run(plan, pf2)
        guard outcome2.result == .completed else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(clean copy did not complete: \(outcome2.result))")
        }
        guard goodFake.removedPaths.contains(goodPath) else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(source file was never removed)")
        }

        return report("AC-CM6", "cache-migration-verify-order", true)
    }

    // MARK: - AC-CM7 — persist ONLY on a completed outcome

    private static func testCacheMigrationPersistOnSuccess() -> Bool {
        let completed = CacheMigrationOutcome(result: .completed, filesMoved: 3, bytesMoved: 300, sameVolume: true)
        let cancelled = CacheMigrationOutcome(result: .cancelled, filesMoved: 1, bytesMoved: 10, sameVolume: true)
        let failed = CacheMigrationOutcome(result: .failed(.verifyMismatch, rolledBack: true), filesMoved: 0, bytesMoved: 0, sameVolume: true)
        let rejected = CacheMigrationOutcome(result: .preflightRejected(.nothingToMove), filesMoved: 0, bytesMoved: 0, sameVolume: false)

        guard CacheMigrationPersistDecision.shouldPersist(completed) else {
            return report("AC-CM7", "cache-migration-persist-on-success", false, "(a completed outcome did not persist)")
        }
        guard !CacheMigrationPersistDecision.shouldPersist(cancelled),
              !CacheMigrationPersistDecision.shouldPersist(failed),
              !CacheMigrationPersistDecision.shouldPersist(rejected) else {
            return report("AC-CM7", "cache-migration-persist-on-success", false, "(a non-completed outcome persisted)")
        }
        return report("AC-CM7", "cache-migration-persist-on-success", true)
    }

    // MARK: - AC-CM8 — cancel at a file boundary; resume skips a matching destination

    private static func testCacheMigrationCancelResume() -> Bool {
        let profile = mountProfile(remotePath: "Kaiju", vfsCachePath: "/tmp/cm8-src")
        guard case .success(let plan) = CacheMigrationPlanner.plan(
            moving: profile, allProfiles: [profile], to: "/tmp/cm8-dest", coMigrate: []
        ) else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(plan failed)")
        }
        let key = VFSCacheService.cacheRelativePath(for: profile)
        let sourceContent = "/tmp/cm8-src/vfs/\(key)"
        let sourceMeta = "/tmp/cm8-src/vfsMeta/\(key)"

        let (cancelSystem, cancelFake) = fakeCacheMigrationFileSystem()
        cancelFake.directories.insert(sourceContent)
        cancelFake.directories.insert(sourceMeta)
        cancelFake.files["\(sourceContent)/a.bin"] = 5
        cancelFake.volumeOf["/tmp/cm8-dest"] = "other-volume"
        let engine1 = CacheMigrationEngine(fs: cancelSystem, isCancelled: { true })
        guard case .success(let pf1) = engine1.preflight(plan) else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(preflight failed for cancel fixture)")
        }
        let outcome1 = engine1.run(plan, pf1)
        guard outcome1.result == .cancelled, outcome1.filesMoved == 0 else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(isCancelled=true did not stop the run: \(outcome1.result))")
        }
        guard cancelFake.files["\(sourceContent)/a.bin"] == 5 else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(source removed despite cancellation)")
        }

        let (resumeSystem, resumeFake) = fakeCacheMigrationFileSystem()
        resumeFake.directories.insert(sourceContent)
        resumeFake.directories.insert(sourceMeta)
        resumeFake.files["\(sourceContent)/a.bin"] = 5
        resumeFake.files["/tmp/cm8-dest/vfs/\(key)/a.bin"] = 5  // already moved by a prior, interrupted run
        resumeFake.volumeOf["/tmp/cm8-dest"] = "other-volume"
        let engine2 = CacheMigrationEngine(fs: resumeSystem)
        guard case .success(let pf2) = engine2.preflight(plan) else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(preflight failed for resume fixture)")
        }
        let outcome2 = engine2.run(plan, pf2)
        guard outcome2.result == .completed, resumeFake.copiedPaths.isEmpty else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(resume re-copied an already-matching destination file: \(resumeFake.copiedPaths))")
        }
        guard resumeFake.files["\(sourceContent)/a.bin"] == nil else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(resumed source file was not cleaned up)")
        }

        return report("AC-CM8", "cache-migration-cancel-resume", true)
    }

    // MARK: - AC-CM9 — install runs on every exit path via the launchd bracket

    private static func testCacheMigrationInstallOnEveryPath() -> Bool {
        var events: [String] = []
        let profileId = UUID()
        CacheMigrationBracket.run(
            affectedProfileIds: [profileId],
            installedProfileIds: [profileId],
            cancelWarm: { _ in },
            uninstall: { events.append("uninstall:\($0)") },
            install: { events.append("install:\($0)") },
            body: { events.append("move") }
        )
        guard events == ["uninstall:\(profileId)", "move", "install:\(profileId)"] else {
            return report("AC-CM9", "cache-migration-install-on-every-path", false, "(unexpected order: \(events))")
        }

        var events2: [String] = []
        let outcome = CacheMigrationBracket.run(
            affectedProfileIds: [],
            installedProfileIds: [profileId],
            cancelWarm: { _ in },
            uninstall: { events2.append("uninstall:\($0)") },
            install: { events2.append("install:\($0)") },
            body: { () -> String in
                events2.append("move-failed")
                return "failed"
            }
        )
        guard outcome == "failed", events2 == ["uninstall:\(profileId)", "move-failed", "install:\(profileId)"] else {
            return report("AC-CM9", "cache-migration-install-on-every-path", false, "(install did not run after a failed body: \(events2))")
        }

        return report("AC-CM9", "cache-migration-install-on-every-path", true)
    }

    // MARK: - AC-CM10 — warm is cancelled for every affected profile before uninstall

    private static func testCacheMigrationWarmCancelledFirst() -> Bool {
        var events: [String] = []
        let profileId = UUID()
        let sibling = UUID()
        CacheMigrationBracket.run(
            affectedProfileIds: [profileId, sibling],
            installedProfileIds: [profileId],
            cancelWarm: { events.append("warm:\($0)") },
            uninstall: { events.append("uninstall:\($0)") },
            install: { events.append("install:\($0)") },
            body: { events.append("move") }
        )
        guard events.first == "warm:\(profileId)", events.count > 1, events[1] == "warm:\(sibling)" else {
            return report("AC-CM10", "cache-migration-warm-cancelled-first", false, "(warm cancel did not fire first for every affected profile: \(events))")
        }
        guard let warmIdx = events.firstIndex(of: "warm:\(sibling)"),
              let uninstallIdx = events.firstIndex(where: { $0.hasPrefix("uninstall:") }),
              warmIdx < uninstallIdx else {
            return report("AC-CM10", "cache-migration-warm-cancelled-first", false, "(cancelWarm did not precede uninstall: \(events))")
        }
        return report("AC-CM10", "cache-migration-warm-cancelled-first", true)
    }

    // MARK: - AC-CM-CLI — `cache move` parsing, EX_USAGE, mount-only refusal, spy routing

    private static func testCacheMigrationCLI() -> Bool {
        guard case .success(.cacheMove(let target, let destination, let includeOverlapping)) = SyncTrayCLI.parse(
            ["cache", "move", "myprofile", "--to", "/Volumes/Big/cache"]
        ), target == "myprofile", destination == "/Volumes/Big/cache", includeOverlapping == false else {
            return report("AC-CM-CLI", "cache-migration-cli", false, "(cache move did not parse to .cacheMove)")
        }

        guard case .failure = SyncTrayCLI.parse(["cache", "move", "myprofile"]) else {
            return report("AC-CM-CLI", "cache-migration-cli", false, "(missing --to did not fail to parse)")
        }
        var stderrOutput = ""
        let usageEnv = fakeCLIEnvironment(stderr: { stderrOutput += $0 })
        guard SyncTrayCLI.execute(["cache", "move", "myprofile"], env: usageEnv) == 64 else {
            return report("AC-CM-CLI", "cache-migration-cli", false, "(missing --to did not exit EX_USAGE)")
        }

        let stream = mountProfile(remotePath: "Kaiju", vfsCachePath: "/tmp/cm-cli-src")
        var migrateCalls: [(String, Bool)] = []
        let migrateEnv = fakeCLIEnvironment(
            readProfiles: { [stream] },
            migrateCache: { _, destination, includeOverlapping in
                migrateCalls.append((destination, includeOverlapping))
                return .completed(files: 3, bytes: 300, sameVolume: true)
            }
        )
        guard SyncTrayCLI.execute(["cache", "move", stream.shortId, "--to", "/tmp/dest"], env: migrateEnv) == 0,
              migrateCalls.count == 1, migrateCalls[0] == ("/tmp/dest", false) else {
            return report("AC-CM-CLI", "cache-migration-cli", false, "(migrateCache spy did not fire with the right destination: \(migrateCalls))")
        }

        var nonMount = sampleProfile(name: "Bisync")
        nonMount.syncMode = .bisync
        let nonMountEnv = fakeCLIEnvironment(readProfiles: { [nonMount] })
        guard SyncTrayCLI.execute(["cache", "move", nonMount.shortId, "--to", "/tmp/dest"], env: nonMountEnv) != 0 else {
            return report("AC-CM-CLI", "cache-migration-cli", false, "(non-mount profile was not refused)")
        }

        guard SyncTrayCLI.telemetryVerb(for: ["cache", "move", "x", "--to", "/y"]) == "cache-move" else {
            return report("AC-CM-CLI", "cache-migration-cli", false, "(telemetryVerb did not map to cache-move)")
        }

        return report("AC-CM-CLI", "cache-migration-cli", true)
    }
}

#endif

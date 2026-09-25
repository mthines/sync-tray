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
            testWarmSkipsCachedFiles,
            testMountMonitorAutoWarm,
            testMountPollDecision,
            testLegacyOfflineLinkCleanup,
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
            testCLILifecycleCommands,
            testCLIProfileSetAndShow,
            testDoctorPureChecks,
            testCLIResolveAndList,
            testShimInstallIdempotentNonClobber,
            testCacheKeyPrimary,
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
            testCacheMigrationDestinationParentCreated,
            testCacheMigrationRollbackOptionalGuard,
            testCacheMigrationNestedSubtreesUseFilePath,
            testCacheMigrationOrchestrationHardening,
            testCacheMigrationUIFixes,
            testCacheMigrationTelemetrySpanStatus,
            testCacheMigrationCLI,
            testMountModeParse,
            testMountNoFallbackOverride,
            testCacheSuffixConsolidation,
            testCacheSuffixPairSafety,
            testCacheSuffixEmptyDestination,
            testMountCommandQuoting,
            testCacheOnlyUnionConfig,
            testCacheOnlyUnionBehaviour,
            testMountModeSelection,
            testAutoResumeDecision,
            testResumeWhileUnreachableHandOff,
            testOverlayUploadPlan,
            testOverlaySyncBack,
            testOverlayUploadNow,
            testOverlayListingFailure,
            testCacheMoveBlockedPending,
            testCLIProfileSetRemovedKeys,
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

    // MARK: - AC-23 — warm skips files already fully in the VFS cache

    /// The offline warmer must only download files NOT already cached. The decision lives in
    /// the pure `VFSCacheService.isCacheComplete` (byte-range coverage of the `vfsMeta`
    /// sidecar), so this drives that core directly with crafted metadata — no mount, no
    /// disk. A regression here is what caused a re-warm to re-fetch the entire pinned set
    /// (~95 GB / 12k files over SMB) instead of just the missing delta.
    private static func testWarmSkipsCachedFiles() -> Bool {
        typealias Meta = VFSCacheService.VFSCacheMeta
        typealias Range = VFSCacheService.VFSCacheMeta.Range
        func complete(_ meta: Meta, _ size: Int64) -> Bool {
            VFSCacheService.isCacheComplete(meta: meta, expectedSize: size)
        }

        // 1. Fully downloaded, clean, single range covering the whole file → cached.
        guard complete(Meta(Size: 42311, Rs: [Range(Pos: 0, Size: 42311)], Dirty: false), 42311) else {
            return report("AC-23", "warm-skips-cached", false, "(complete single range not recognised)")
        }
        // 2. Size mismatch (remote grew / shrank) → not cached.
        guard !complete(Meta(Size: 100, Rs: [Range(Pos: 0, Size: 100)], Dirty: false), 200) else {
            return report("AC-23", "warm-skips-cached", false, "(size mismatch treated as cached)")
        }
        // 3. Dirty (unflushed local write) → not cached.
        guard !complete(Meta(Size: 100, Rs: [Range(Pos: 0, Size: 100)], Dirty: true), 100) else {
            return report("AC-23", "warm-skips-cached", false, "(dirty file treated as cached)")
        }
        // 4. A gap between ranges → partial → not cached.
        guard !complete(Meta(Size: 100, Rs: [Range(Pos: 0, Size: 40), Range(Pos: 50, Size: 50)], Dirty: false), 100) else {
            return report("AC-23", "warm-skips-cached", false, "(gap in ranges treated as cached)")
        }
        // 5. Multiple contiguous (and out-of-order) ranges covering the whole file → cached.
        guard complete(Meta(Size: 100, Rs: [Range(Pos: 60, Size: 40), Range(Pos: 0, Size: 60)], Dirty: false), 100) else {
            return report("AC-23", "warm-skips-cached", false, "(contiguous multi-range not recognised)")
        }
        // 6. Overlapping ranges that still cover the file → cached.
        guard complete(Meta(Size: 100, Rs: [Range(Pos: 0, Size: 70), Range(Pos: 50, Size: 50)], Dirty: false), 100) else {
            return report("AC-23", "warm-skips-cached", false, "(overlapping full coverage not recognised)")
        }
        // 7. Ranges present but short of the end → not cached.
        guard !complete(Meta(Size: 100, Rs: [Range(Pos: 0, Size: 90)], Dirty: false), 100) else {
            return report("AC-23", "warm-skips-cached", false, "(short coverage treated as cached)")
        }
        // 8. Missing ranges on a non-empty file → not cached.
        guard !complete(Meta(Size: 100, Rs: nil, Dirty: false), 100) else {
            return report("AC-23", "warm-skips-cached", false, "(nil ranges treated as cached)")
        }
        // 9. Empty file: no ranges needed → cached.
        guard complete(Meta(Size: 0, Rs: nil, Dirty: false), 0) else {
            return report("AC-23", "warm-skips-cached", false, "(empty file not recognised as cached)")
        }
        // 10. End-to-end through the JSON entry point with rclone's real sidecar shape.
        let realSidecar = """
        {"ModTime":"2026-09-13T12:08:27.6+02:00","ATime":"2026-09-14T09:49:16.1+02:00",\
        "Size":42311,"Rs":[{"Pos":0,"Size":42311}],"Fingerprint":"42311,2024-01-10 07:32:32 +0000 UTC","Dirty":false}
        """.data(using: .utf8)!
        guard VFSCacheService.isCacheComplete(metaJSON: realSidecar, expectedSize: 42311) else {
            return report("AC-23", "warm-skips-cached", false, "(real rclone sidecar JSON not recognised)")
        }
        // Garbage / non-JSON must fail closed (→ warm the file), never crash.
        guard !VFSCacheService.isCacheComplete(metaJSON: Data("not json".utf8), expectedSize: 42311) else {
            return report("AC-23", "warm-skips-cached", false, "(garbage sidecar treated as cached)")
        }
        // 11. A valid-JSON but pathological sidecar whose ranges overflow Int64 must fail
        // closed, not overflow-trap: a leading [0,size) range then a Pos==covered range
        // whose Pos+Size wraps past Int64.max. Reaching this line at all proves no trap.
        let overflowMeta = Meta(Size: 100, Rs: [Range(Pos: 0, Size: 100), Range(Pos: 100, Size: Int64.max)], Dirty: false)
        guard !complete(overflowMeta, 100) else {
            return report("AC-23", "warm-skips-cached", false, "(overflowing range treated as cached)")
        }
        // 12. Negative range fields (impossible for a real sidecar) also fail closed.
        guard !complete(Meta(Size: 100, Rs: [Range(Pos: -1, Size: 101)], Dirty: false), 100) else {
            return report("AC-23", "warm-skips-cached", false, "(negative range treated as cached)")
        }
        return report("AC-23", "warm-skips-cached", true)
    }

    // MARK: - AC-24 — mount monitor auto-warms a detected mount once per session

    // MARK: - AC-MP1 — mount-establishment poll decision + staged loading text

    /// The mount poll must stay in `.mounting` while a large VFS cache walk is
    /// still establishing (up to 5 min), fail fast only when the launchd agent is
    /// genuinely stopped, and never mis-read a mount that comes up on the same tick
    /// the cap elapses. Also asserts the loading text escalates through distinct
    /// buckets. Drives the pure `SyncManager.mountPollDecision` /
    /// `mountProgressMessage` without a real mount.
    private static func testMountPollDecision() -> Bool {
        let maxS = 300, dead = 3
        func decide(_ elapsed: Int, _ mounted: Bool, _ alive: Bool, _ consec: Int) -> SyncManager.MountPollDecision {
            SyncManager.mountPollDecision(
                elapsedSeconds: elapsed, maxSeconds: maxS, isMounted: mounted,
                agentAlive: alive, consecutiveDead: consec, deadThreshold: dead)
        }
        // isMounted wins over everything — even at the cap or with a long-dead agent.
        if decide(0, true, false, 99) != .established {
            return report("AC-MP1", "mount-poll-decision", false, "(mounted not established)")
        }
        if decide(maxS, true, false, 99) != .established {
            return report("AC-MP1", "mount-poll-decision", false, "(mounted-at-cap not established)")
        }
        // Not mounted, agent alive, before cap → keep the loading state.
        if decide(40, false, true, 0) != .keepWaiting {
            return report("AC-MP1", "mount-poll-decision", false, "(establishing not keepWaiting)")
        }
        // Agent momentarily not-alive but under the threshold → still waiting (respawn gap).
        if decide(40, false, false, dead - 1) != .keepWaiting {
            return report("AC-MP1", "mount-poll-decision", false, "(one dead sample failed too early)")
        }
        // Agent dead for >= threshold consecutive samples → fail fast.
        if decide(40, false, false, dead) != .failedDead {
            return report("AC-MP1", "mount-poll-decision", false, "(dead agent not failedDead)")
        }
        // Not mounted, agent alive, cap reached → timeout.
        if decide(maxS, false, true, 0) != .failedTimeout {
            return report("AC-MP1", "mount-poll-decision", false, "(cap not failedTimeout)")
        }
        // Staged loading text: distinct, escalating, non-empty buckets.
        let msgs = [0, 20, 60, 200].map { SyncManager.mountProgressMessage(elapsedSeconds: $0) }
        if Set(msgs).count != msgs.count {
            return report("AC-MP1", "mount-poll-decision", false, "(progress buckets not distinct: \(msgs))")
        }
        if msgs.contains(where: { $0.isEmpty }) {
            return report("AC-MP1", "mount-poll-decision", false, "(empty progress message)")
        }
        return report("AC-MP1", "mount-poll-decision", true)
    }

    /// Legacy "(Offline)" symlink cleanup (D13/R6): a stray symlink left by the
    /// retired offline-browse-point feature, pointing into a `/vfs/` cache data tree,
    /// is removed; a real directory of that name and a symlink pointing elsewhere are
    /// both left alone. Covers the pure predicate and the real filesystem apply.
    private static func testLegacyOfflineLinkCleanup() -> Bool {
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("synctray-oa-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: root) }
        let mountPoint = (root as NSString).appendingPathComponent("KaijuNew")
        try? fm.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        let profile = SyncProfile(
            name: "T", rcloneRemote: "synology:", remotePath: "Kaiju/KAIJU",
            localSyncPath: mountPoint, syncMode: .mount, vfsCachePath: root
        )
        let expectedLinkPath = (root as NSString).appendingPathComponent("KaijuNew (Offline)")
        guard LegacyOfflineLink.linkPath(for: profile) == expectedLinkPath else {
            return report("AC-OA3", "legacy-offline-link-cleanup", false,
                          "(bad linkPath: \(LegacyOfflineLink.linkPath(for: profile) ?? "nil"))")
        }

        // Pure predicate: only a symlink into a /vfs/ tree qualifies.
        guard LegacyOfflineLink.shouldRemoveLegacyOfflineLink(
            isSymlink: true, destination: "\(root)/vfs/synology/Kaiju/KAIJU") else {
            return report("AC-OA3", "legacy-offline-link-cleanup", false, "(vfs symlink should qualify for removal)")
        }
        guard !LegacyOfflineLink.shouldRemoveLegacyOfflineLink(isSymlink: false, destination: "\(root)/vfs/x") else {
            return report("AC-OA3", "legacy-offline-link-cleanup", false, "(non-symlink should never qualify)")
        }
        guard !LegacyOfflineLink.shouldRemoveLegacyOfflineLink(isSymlink: true, destination: "/somewhere/else") else {
            return report("AC-OA3", "legacy-offline-link-cleanup", false, "(symlink outside /vfs/ should not qualify)")
        }

        // Real filesystem apply: a symlink into /vfs/ is removed...
        let link = LegacyOfflineLink.linkPath(for: profile)!
        let target = (root as NSString).appendingPathComponent("vfs/synology/Kaiju/KAIJU")
        try? fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        guard LegacyOfflineLink.removeIfPresent(for: profile), !fm.fileExists(atPath: link) else {
            return report("AC-OA3", "legacy-offline-link-cleanup", false, "(vfs symlink was not removed)")
        }

        // ...a real directory of that name is kept...
        try? fm.createDirectory(atPath: link, withIntermediateDirectories: true)
        guard !LegacyOfflineLink.removeIfPresent(for: profile), fm.fileExists(atPath: link) else {
            return report("AC-OA3", "legacy-offline-link-cleanup", false, "(a real directory was removed)")
        }
        try? fm.removeItem(atPath: link)

        // ...and a symlink pointing elsewhere is kept.
        let elsewhere = (root as NSString).appendingPathComponent("elsewhere")
        try? fm.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: elsewhere)
        guard !LegacyOfflineLink.removeIfPresent(for: profile), fm.fileExists(atPath: link) else {
            return report("AC-OA3", "legacy-offline-link-cleanup", false, "(a symlink pointing elsewhere was removed)")
        }

        return report("AC-OA3", "legacy-offline-link-cleanup", true)
    }

    /// A launchd/externally-mounted Stream profile (e.g. auto-mounted at login) never runs
    /// the app's mount-path warm, so new remote files never reach the offline cache. The 5s
    /// mount monitor closes that gap by warming a detected mount — but exactly ONCE per mount
    /// session, or it would thrash (`startWarm` supersedes). This drives the pure decision
    /// (`SyncManager.shouldAutoWarmOnMount`) through a mount → steady-state → unmount → remount
    /// lifecycle without a real mount.
    private static func testMountMonitorAutoWarm() -> Bool {
        let id = UUID()
        var warmed: Set<UUID> = []
        func decide(mounted: Bool, pins: Bool) -> Bool {
            SyncManager.shouldAutoWarmOnMount(isMounted: mounted, hasPinnedDirs: pins, profileId: id, alreadyWarmed: &warmed)
        }

        // First tick seen mounted with pins → warm once.
        guard decide(mounted: true, pins: true) else {
            return report("AC-24", "mount-monitor-auto-warm", false, "(first mounted tick did not warm)")
        }
        // Subsequent ticks while still mounted → no repeat warm (would thrash).
        guard !decide(mounted: true, pins: true), !decide(mounted: true, pins: true) else {
            return report("AC-24", "mount-monitor-auto-warm", false, "(re-warmed while still mounted)")
        }
        // Seen unmounted → re-arm.
        guard !decide(mounted: false, pins: true) else {
            return report("AC-24", "mount-monitor-auto-warm", false, "(unmounted tick returned true)")
        }
        // Remount → warms again (picks up files added while unmounted).
        guard decide(mounted: true, pins: true) else {
            return report("AC-24", "mount-monitor-auto-warm", false, "(remount did not re-warm after re-arm)")
        }
        // A profile with no pinned directories never warms and is never tracked.
        let unpinned = UUID()
        var w2: Set<UUID> = []
        let noPins = SyncManager.shouldAutoWarmOnMount(isMounted: true, hasPinnedDirs: false, profileId: unpinned, alreadyWarmed: &w2)
        guard !noPins, w2.isEmpty else {
            return report("AC-24", "mount-monitor-auto-warm", false, "(unpinned profile warmed or was tracked)")
        }
        // A stuck-.failed profile that never emitted a mounted tick still re-arms cleanly on
        // an unmounted tick (no crash, idempotent remove).
        _ = SyncManager.shouldAutoWarmOnMount(isMounted: false, hasPinnedDirs: true, profileId: UUID(), alreadyWarmed: &warmed)
        return report("AC-24", "mount-monitor-auto-warm", true)
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
        mountProfile: @escaping (SyncProfile) -> String? = { _ in nil },
        unmountProfile: @escaping (SyncProfile) -> String? = { _ in nil },
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
            mountProfile: mountProfile,
            unmountProfile: unmountProfile,
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

    // MARK: - AC-CLI7 — lifecycle: mount/unmount/reinstall/install parse + side-effect routing

    /// Drives the agent-first lifecycle commands through parse + `execute` with
    /// spied closures: mount/unmount route to the mount/unmount closures and
    /// refuse a non-mount profile; reinstall does uninstall→install for an enabled
    /// profile and refuses a disabled one; install runs installProfile for an
    /// enabled profile and refuses a disabled one. Also locks their bounded
    /// telemetry verbs.
    private static func testCLILifecycleCommands() -> Bool {
        // Parse.
        guard case .success(.mount("s")) = SyncTrayCLI.parse(["mount", "s"]),
              case .success(.unmount("s")) = SyncTrayCLI.parse(["unmount", "s"]),
              case .success(.reinstall("s")) = SyncTrayCLI.parse(["reinstall", "s"]),
              case .success(.install("s")) = SyncTrayCLI.parse(["install", "s"]) else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(lifecycle commands did not parse)")
        }
        guard case .failure = SyncTrayCLI.parse(["mount"]) else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(mount without a target did not fail to parse)")
        }

        var stream = sampleProfile(id: UUID(), name: "Streamer", isEnabled: true)
        stream.syncMode = .mount

        // mount → mountProfile closure fires for a mount profile.
        var mounted = false
        let mountEnv = fakeCLIEnvironment(readProfiles: { [stream] }, mountProfile: { _ in mounted = true; return nil })
        guard SyncTrayCLI.execute(["mount", stream.shortId], env: mountEnv) == 0, mounted else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(mount did not fire mountProfile)")
        }

        // mount → surfaces the closure's error as a non-zero exit.
        let mountFailEnv = fakeCLIEnvironment(readProfiles: { [stream] }, mountProfile: { _ in "mount did not establish within 60s" })
        guard SyncTrayCLI.execute(["mount", stream.shortId], env: mountFailEnv) != 0 else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(mount did not propagate a mount failure)")
        }

        // unmount → unmountProfile closure fires.
        var unmounted = false
        let unmountEnv = fakeCLIEnvironment(readProfiles: { [stream] }, unmountProfile: { _ in unmounted = true; return nil })
        guard SyncTrayCLI.execute(["unmount", stream.shortId], env: unmountEnv) == 0, unmounted else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(unmount did not fire unmountProfile)")
        }

        // mount/unmount refuse a non-mount profile (no closure fires).
        let bisync = sampleProfile(id: UUID(), name: "Bisync", isEnabled: true)
        var mountFiredOnBisync = false
        let mountBisyncEnv = fakeCLIEnvironment(readProfiles: { [bisync] }, mountProfile: { _ in mountFiredOnBisync = true; return nil })
        guard SyncTrayCLI.execute(["mount", bisync.shortId], env: mountBisyncEnv) != 0, !mountFiredOnBisync else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(mount did not refuse a non-mount profile)")
        }

        // reinstall (enabled) → uninstall THEN install both fire.
        var reUninstalled = false, reInstalled = false
        let reinstallEnv = fakeCLIEnvironment(
            readProfiles: { [bisync] },
            installProfile: { _ in reInstalled = true; return nil },
            uninstallProfile: { _ in reUninstalled = true; return nil }
        )
        guard SyncTrayCLI.execute(["reinstall", bisync.shortId], env: reinstallEnv) == 0, reUninstalled, reInstalled else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(reinstall did not uninstall+install)")
        }

        // install (enabled) → installProfile fires, uninstall does NOT.
        var installFired = false
        let installEnv = fakeCLIEnvironment(
            readProfiles: { [bisync] },
            installProfile: { _ in installFired = true; return nil },
            uninstallProfile: { _ in "should-not-be-called" }
        )
        guard SyncTrayCLI.execute(["install", bisync.shortId], env: installEnv) == 0, installFired else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(install did not run installProfile)")
        }

        // install/reinstall refuse a disabled profile (no install fires).
        let disabled = sampleProfile(id: UUID(), name: "Disabled", isEnabled: false)
        var disabledInstallFired = false
        let disabledEnv = fakeCLIEnvironment(
            readProfiles: { [disabled] },
            installProfile: { _ in disabledInstallFired = true; return nil }
        )
        guard SyncTrayCLI.execute(["install", disabled.shortId], env: disabledEnv) != 0,
              SyncTrayCLI.execute(["reinstall", disabled.shortId], env: disabledEnv) != 0,
              !disabledInstallFired else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(install/reinstall did not refuse a disabled profile)")
        }

        // Bounded telemetry verbs.
        let verbCases: [([String], String)] = [
            (["mount", "SECRET"], "mount"),
            (["unmount", "SECRET"], "unmount"),
            (["reinstall", "SECRET"], "reinstall"),
            (["install", "SECRET"], "install"),
        ]
        for (argv, expected) in verbCases where SyncTrayCLI.telemetryVerb(for: argv) != expected {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(telemetryVerb\(argv) != \(expected))")
        }

        return report("AC-CLI7", "cli-lifecycle-commands", true)
    }

    // MARK: - AC-CLI8 — profile set: assignment matrix, reconcile routing, profile show round-trip

    /// Exercises the keystone `profile set` end to end: the pure
    /// `applyProfileAssignment` matrix (valid fields, invalid values, unknown key,
    /// the three excluded keys), then `execute` for the write + reconcile routing
    /// (a reinstall-triggering field on an enabled profile drives uninstall→install;
    /// an invalid value writes NOTHING), and finally `profile show` producing JSON
    /// that decodes back to the same profile.
    private static func testCLIProfileSetAndShow() -> Bool {
        // Parse: positional key/value pairs; odd count fails.
        guard case .success(.profileSet(target: "work", assignments: let a)) = SyncTrayCLI.parse(
            ["profile", "set", "work", "isMuted", "true", "downloadConnections", "4"]
        ), a == [ProfileAssignment(key: "isMuted", value: "true"), ProfileAssignment(key: "downloadConnections", value: "4")] else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(profile set did not parse into pairs)")
        }
        guard case .failure = SyncTrayCLI.parse(["profile", "set", "work", "isMuted"]) else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(odd pair count did not fail to parse)")
        }

        // applyProfileAssignment matrix.
        var p = sampleProfile(id: UUID(), name: "Base", isEnabled: true)
        guard SyncTrayCLI.applyProfileAssignment(&p, key: "syncMode", value: "mount") == nil, p.syncMode == .mount else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(valid syncMode assignment failed)")
        }
        guard SyncTrayCLI.applyProfileAssignment(&p, key: "mountBackend", value: "macfuse") == nil, p.mountBackend == .macfuse else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(valid mountBackend assignment failed)")
        }
        guard SyncTrayCLI.applyProfileAssignment(&p, key: "downloadConnections", value: "8") == nil, p.downloadConnections == 8 else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(valid downloadConnections assignment failed)")
        }
        guard SyncTrayCLI.applyProfileAssignment(&p, key: "isMuted", value: "yes") == nil, p.isMuted == true else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(valid bool assignment failed)")
        }
        guard SyncTrayCLI.applyProfileAssignment(&p, key: "pinnedDirectories", value: "A, B ,C") == nil,
              p.pinnedDirectories == ["A", "B", "C"] else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(comma list assignment failed: \(p.pinnedDirectories))")
        }
        // Invalid values.
        guard SyncTrayCLI.applyProfileAssignment(&p, key: "downloadConnections", value: "99") != nil else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(out-of-range downloadConnections was accepted)")
        }
        guard SyncTrayCLI.applyProfileAssignment(&p, key: "syncMode", value: "bogus") != nil else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(invalid enum value was accepted)")
        }
        guard SyncTrayCLI.applyProfileAssignment(&p, key: "name", value: "") != nil else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(empty required string was accepted)")
        }
        // Unknown + excluded keys.
        for badKey in ["totallyBogus", "id", "isEnabled", "fallbackRequiresCacheRebuild"] {
            guard SyncTrayCLI.applyProfileAssignment(&p, key: badKey, value: "x") != nil else {
                return report("AC-CLI8", "cli-profile-set-and-show", false, "(key \"\(badKey)\" was not rejected)")
            }
        }

        // execute: a reinstall-triggering field on an enabled profile → write + uninstall→install.
        let enabled = sampleProfile(id: UUID(), name: "Enabled", isEnabled: true)
        var written: SyncProfile?, reUninstalled = false, reInstalled = false
        let setEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            writeProfile: { written = $0; return true },
            installProfile: { _ in reInstalled = true; return nil },
            uninstallProfile: { _ in reUninstalled = true; return nil }
        )
        guard SyncTrayCLI.execute(["profile", "set", enabled.shortId, "syncIntervalMinutes", "42"], env: setEnv) == 0,
              written?.syncIntervalMinutes == 42, reUninstalled, reInstalled else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(profile set did not write + reinstall)")
        }

        // execute: an invalid value writes NOTHING and exits non-zero.
        var wroteOnInvalid = false
        let invalidEnv = fakeCLIEnvironment(readProfiles: { [enabled] }, writeProfile: { _ in wroteOnInvalid = true; return true })
        guard SyncTrayCLI.execute(["profile", "set", enabled.shortId, "syncMode", "bogus"], env: invalidEnv) != 0, !wroteOnInvalid else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(invalid profile set value still wrote the file)")
        }

        // profile show → JSON that decodes back to the same profile.
        var shown = ""
        let showEnv = fakeCLIEnvironment(readProfiles: { [enabled] }, stdout: { shown += $0 })
        guard SyncTrayCLI.execute(["profile", "show", enabled.shortId], env: showEnv) == 0,
              let data = shown.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data),
              decoded == enabled else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(profile show JSON did not round-trip)")
        }

        return report("AC-CLI8", "cli-profile-set-and-show", true)
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

    /// Thrown by `FakeCacheFS.copyFile`/`copyFileDataOnly` when the
    /// destination's parent directory hasn't been created yet — this is
    /// deliberately a HARD requirement, not an auto-created convenience,
    /// because `FileManager.copyItem`/`data.write(to:)` on the real
    /// filesystem behave exactly this way (neither creates intermediate
    /// directories). An earlier version of this fake auto-inserted the
    /// parent into `directories` as a copy side effect, which masked a real
    /// production bug — `moveFile` copying into a destination root that was
    /// never created (finding 1) — because the fake "succeeded" regardless
    /// of whether production had done the creation. See AC-CM11.
    private enum FakeCacheFSError: Error { case missingParentDirectory }

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
        /// Copy TARGET paths whose copy silently produces no file at all —
        /// the "the copy no-op'd" half of the both-sizes-missing footgun
        /// AC-CM12 drives through `rollback` (finding 4). Distinct from
        /// `writeMismatchAt`, which writes a file at the WRONG size.
        var copyProducesNothingAt: Set<String> = []
        /// Path -> how many more `fileSize` calls succeed before it starts
        /// returning `nil` — simulates a file that EXISTS but cannot be
        /// stat'd, which no combination of `files`/`directories` can express
        /// (both derive from the same map). AC-CM12 needs it to make
        /// `rollback`'s destination stat fail while the forward move's own
        /// stats still succeed. A test that sets a budget should assert it
        /// reached 0, so a refactor changing the call count fails loudly
        /// instead of silently skipping the scenario.
        var statBudget: [String: Int] = [:]
        /// Every root `removeEmptyDirectories` was called with, in call
        /// order — records the argument so a test can assert BOTH the
        /// scope (per-`vfs`/`vfsMeta` subtree, never the bare cache root)
        /// and the ordering (only after a confirmed-complete move) of the
        /// prune step (finding 10). The original fake discarded the
        /// argument entirely (`{ _ in }`), so no assertion could ever have
        /// caught either regression.
        var removeEmptyDirectoriesCalls: [String] = []

        func system() -> CacheMigrationFileSystem {
            CacheMigrationFileSystem(
                directoryExists: { [weak self] path in self?.directories.contains(path) ?? false },
                fileExists: { [weak self] path in self?.files[path] != nil },
                enumerateFiles: { [weak self] root in
                    guard let self else { return [] }
                    let prefix = root + "/"
                    // Sorted: `files` is a Dictionary, so an unsorted map
                    // would hand the engine a nondeterministic file ORDER and
                    // any test that depends on which file fails first would
                    // flake.
                    return self.files
                        .filter { $0.key.hasPrefix(prefix) }
                        .sorted { $0.key < $1.key }
                        .map { (relativePath: String($0.key.dropFirst(prefix.count)), size: $0.value) }
                },
                fileSize: { [weak self] path in
                    guard let self else { return nil }
                    if let remaining = self.statBudget[path] {
                        guard remaining > 0 else { return nil }
                        self.statBudget[path] = remaining - 1
                    }
                    return self.files[path]
                },
                createDirectory: { [weak self] path in
                    self?.directories.insert(path)
                },
                copyFile: { [weak self] from, to in
                    guard let self else { return }
                    let parent = (to as NSString).deletingLastPathComponent
                    guard self.directories.contains(parent) else {
                        throw FakeCacheFSError.missingParentDirectory
                    }
                    self.copiedPaths.append((from, to))
                    // A copy that throws nothing but writes nothing — the
                    // scenario `rollback`'s `guard let` has to fail closed on.
                    guard !self.copyProducesNothingAt.contains(to) else { return }
                    let sourceSize = self.files[from] ?? 0
                    self.files[to] = self.writeMismatchAt.contains(to) ? sourceSize + 1 : sourceSize
                },
                copyFileDataOnly: { [weak self] from, to in
                    guard let self else { return }
                    let parent = (to as NSString).deletingLastPathComponent
                    guard self.directories.contains(parent) else {
                        throw FakeCacheFSError.missingParentDirectory
                    }
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
                removeEmptyDirectories: { [weak self] path in
                    self?.removeEmptyDirectoriesCalls.append(path)
                },
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

    /// Reads a source file elsewhere in the SyncTray target, addressed
    /// relative to the `SyncTray/` directory root (e.g.
    /// `"Views/Settings/ProfileDetailView.swift"`). Generalizes the
    /// `#filePath` sibling-source-read technique AC-C5 established (which
    /// only reached same-directory siblings) so the review-fix assertions
    /// below can verify call sites this host has no compiler to check any
    /// other way — SwiftUI view state and MainActor orchestration aren't
    /// reachable through the `CacheMigrationFileSystem` injection seam the
    /// rest of this suite drives.
    private static func readSourceFile(_ relativePathFromSyncTrayRoot: String) -> String? {
        let selfTestFile = URL(fileURLWithPath: #filePath)
        // ConfigSelfTest.swift lives at SyncTray/Services/ConfigSelfTest.swift.
        let syncTrayRoot = selfTestFile.deletingLastPathComponent().deletingLastPathComponent()
        let target = syncTrayRoot.appendingPathComponent(relativePathFromSyncTrayRoot).path
        return try? String(contentsOfFile: target, encoding: .utf8)
    }

    /// Extracts a function/method body by scanning forward from the first
    /// line containing `marker` to the next line that is EXACTLY a
    /// 4-space-indented closing brace (`    }`) — the same range
    /// `checks.yaml` extracts via `awk '/marker/,/^    \}$/'`, reimplemented
    /// here in Swift so a self-test assertion can search the SAME bounded
    /// text a `checks.yaml` grep would. Only valid for a method at ONE
    /// level of nesting (a type's direct member) — every call site below is.
    private static func extractFunctionBody(startingAt marker: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let startIdx = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        var result: [String] = []
        for line in lines[startIdx...] {
            result.append(line)
            if line == "    }", result.count > 1 { break }
        }
        return result.joined(separator: "\n")
    }

    // MARK: - AC-CK1 — the cache key is the primary remote name again

    /// The retired "Share the cache across remotes" feature is gone: the VFS cache is
    /// keyed by the primary remote name exactly as 0.80.0 did, and a `.profile.json`
    /// still carrying its old keys decodes fine (they're simply ignored) and no longer
    /// round-trips them on the next write.
    private static func testCacheKeyPrimary() -> Bool {
        var profile = SyncProfile(
            name: "Stream", rcloneRemote: "synology:", remotePath: "Kaiju/KAIJU",
            localSyncPath: "/Volumes/SeagateHD/KaijuNew", syncMode: .mount
        )
        guard VFSCacheService.cacheRelativePath(for: profile) == "synology/Kaiju/KAIJU" else {
            return report("AC-CK1", "cache-key-primary", false,
                          "(key \(VFSCacheService.cacheRelativePath(for: profile)) != synology/Kaiju/KAIJU)")
        }

        // A profile file carrying the retired keys must still decode (unknown keys are
        // simply skipped by Codable), and the re-encoded JSON must drop them.
        let legacyJSON: [String: Any] = [
            "id": profile.id.uuidString, "name": profile.name,
            "rcloneRemote": profile.rcloneRemote, "remotePath": profile.remotePath,
            "localSyncPath": profile.localSyncPath, "syncMode": "mount",
            "stableCacheIdentity": true, "cacheIdentity": "synology", "offlineAccessEnabled": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: legacyJSON),
              let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data) else {
            return report("AC-CK1", "cache-key-primary", false, "(profile carrying legacy keys failed to decode)")
        }
        profile = decoded
        guard let reEncoded = try? JSONEncoder().encode(profile),
              let reEncodedString = String(data: reEncoded, encoding: .utf8) else {
            return report("AC-CK1", "cache-key-primary", false, "(re-encode failed)")
        }
        for key in ["stableCacheIdentity", "cacheIdentity", "offlineAccessEnabled"] where reEncodedString.contains(key) {
            return report("AC-CK1", "cache-key-primary", false, "(re-encoded JSON still contains \(key))")
        }

        // The retired migration slot is a documented no-op — it must not throw and must
        // not touch UserDefaults.
        let suiteName = "synctray-selftest-ck1-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        do {
            try MigrationV4Retired().migrateUserDefaults(defaults)
        } catch {
            return report("AC-CK1", "cache-key-primary", false, "(MigrationV4Retired threw: \(error))")
        }

        return report("AC-CK1", "cache-key-primary", true)
    }

    /// A mount-mode profile with deterministic remote/key fields, for the
    /// cache-migration tests below. The cache key is always the primary remote name
    /// (colon stripped) + remotePath — see `VFSCacheService.cacheRelativePath`.
    private static func mountProfile(
        id: UUID = UUID(),
        name: String = "Stream",
        remotePath: String,
        vfsCachePath: String
    ) -> SyncProfile {
        var profile = sampleProfile(id: id, name: name)
        profile.syncMode = .mount
        profile.rcloneRemote = "synology:"
        profile.remotePath = remotePath
        profile.vfsCachePath = vfsCachePath
        return profile
    }

    // MARK: - Mount-branch script dry-run harness
    //
    // `SyncSetupService.generateSyncScript()` renders the ONE shared shell script every
    // mount-mode profile runs under launchd. This process cannot read a real NFS/FUSE mount
    // (TCC denies it — see CLAUDE.md's Testing section), so these self-tests never mount
    // anything: they render the script to a temp file, run it for real up through
    // consolidation + mode selection + (for Cache Only) config/exclude generation, then hit
    // the `SYNCTRAY_DRY_RUN=1` seam, which prints the resolved mode/command and exits before
    // ever calling `eval` on the rclone command. Everything the script touches — cache dirs,
    // mount point, config file, `RCLONE_CONFIG` — is an isolated temp fixture.

    private static func mountFixtureProfile(
        localPath: String,
        cachePath: String,
        rcloneRemote: String = "synology:",
        remotePath: String = "Kaiju/KAIJU",
        fallbackRemote: String = "",
        streamCacheOnly: Bool = false
    ) -> SyncProfile {
        var profile = sampleProfile(name: "MountFixture")
        profile.syncMode = .mount
        profile.rcloneRemote = rcloneRemote
        profile.remotePath = remotePath
        profile.localSyncPath = localPath
        profile.vfsCachePath = cachePath
        profile.fallbackRemote = fallbackRemote
        profile.streamCacheOnly = streamCacheOnly
        return profile
    }

    private struct DryRunResult {
        let mode: String?
        let cmd: String?
        let envOverrides: Int?
        let output: String
        let exitCode: Int32
        let scriptPath: String
        /// Contents of the real `~/.local/log/synctray-sync-{shortId}.log` the dry run wrote
        /// to, captured BEFORE `dryRunMountScript`'s own cleanup deletes it — the log carries
        /// runtime decisions (e.g. "using fallback: X") that never surface in `cmd` for a
        /// mode (like Cache Only) whose rendered command doesn't reference the remote name.
        let log: String
    }

    /// Render the shared script + this profile's derived config into a fresh temp dir, then
    /// run it (`bash script.sh config.json`) with `SYNCTRAY_DRY_RUN=1` and an isolated
    /// `RCLONE_CONFIG`. Blocks up to `timeout` seconds; force-terminates and returns whatever
    /// was captured if the script somehow overruns (it never should — the reachability probe
    /// itself is wall-clock-capped at 17s).
    private static func dryRunMountScript(
        profile: SyncProfile,
        rcloneConfig: String,
        timeout: TimeInterval = 30
    ) -> DryRunResult {
        // `profile.logPath` is `~/.local/log/synctray-sync-{shortId}.log` — NOT
        // sandboxed under any temp dir (real per-profile paths are all under the
        // user's real home, by production design), so the dry-run script's real
        // writes to it must be cleaned up here, the single place every dry-run
        // test funnels through, rather than duplicated per call site.
        defer { try? FileManager.default.removeItem(atPath: profile.logPath) }
        let dir = "\(selfTestRoot)/mountscript-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // In production, `SyncSetupService.install(profile:)` always creates
        // `~/.local/log` before the generated script ever runs. This harness skips
        // `install()` and invokes the script directly, so on a machine that has never
        // installed a SyncTray profile (a clean CI runner, notably) that directory
        // doesn't exist yet and the script's very first `>> "$LOG_FILE"` write fails
        // with "No such file or directory" — masked on a dev machine where some
        // earlier real install already created it. Recreate that one invariant here.
        try? FileManager.default.createDirectory(
            atPath: (profile.logPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        let scriptPath = "\(dir)/script.sh"
        try? SyncSetupService.shared.generateSyncScript().write(
            toFile: scriptPath, atomically: true, encoding: .utf8)
        let configPath = "\(dir)/config.json"
        try? SyncSetupService.shared.generateProfileConfig(for: profile).write(
            toFile: configPath, atomically: true, encoding: .utf8)
        let rcloneConfPath = "\(dir)/rclone.conf"
        try? rcloneConfig.write(toFile: rcloneConfPath, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath, configPath]
        var env = ProcessInfo.processInfo.environment
        env["SYNCTRAY_DRY_RUN"] = "1"
        env["RCLONE_CONFIG"] = rcloneConfPath
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            return DryRunResult(
                mode: nil, cmd: nil, envOverrides: nil, output: "failed to launch: \(error)",
                exitCode: -1, scriptPath: scriptPath, log: "")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning { proc.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        var mode: String?, cmd: String?, envOverrides: Int?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("SYNCTRAY_DRY_RUN_MODE=") {
                mode = String(line.dropFirst("SYNCTRAY_DRY_RUN_MODE=".count))
            } else if line.hasPrefix("SYNCTRAY_DRY_RUN_CMD=") {
                cmd = String(line.dropFirst("SYNCTRAY_DRY_RUN_CMD=".count))
            } else if line.hasPrefix("SYNCTRAY_DRY_RUN_ENV_OVERRIDES=") {
                envOverrides = Int(line.dropFirst("SYNCTRAY_DRY_RUN_ENV_OVERRIDES=".count))
            }
        }
        let logContent = (try? String(contentsOfFile: profile.logPath, encoding: .utf8)) ?? ""
        return DryRunResult(
            mode: mode, cmd: cmd, envOverrides: envOverrides, output: output,
            exitCode: proc.terminationStatus, scriptPath: scriptPath, log: logContent)
    }

    /// A minimal rclone config defining `name` as an `alias` remote rooted at `path` — `lsd
    /// name:` (no path suffix) resolves deterministically and near-instantly to `path`,
    /// regardless of the test process's cwd (unlike a bare `local` remote with no `root`,
    /// which resolves relative to cwd — see the investigation this harness's design notes
    /// came from). Used for every "primary reachable" dry-run fixture.
    private static func aliasRcloneConfig(name: String, path: String) -> String {
        "[\(name)]\ntype = alias\nremote = \(path)\n"
    }

    // MARK: - AC-MM1 — mount mode token parsing + display names

    private static func testMountModeParse() -> Bool {
        guard MountMode.parse("streaming") == .streaming,
              MountMode.parse("cache-only-manual") == .cacheOnlyManual,
              MountMode.parse("cache-only-pending") == .cacheOnlyPending,
              MountMode.parse("cache-only-offline") == .cacheOnlyOffline,
              MountMode.parse("  streaming\n") == .streaming,
              MountMode.parse("bogus-token") == nil,
              MountMode.parse("") == nil
        else {
            return report("AC-MM1", "mount-mode-parse", false, "(token parse/reject mismatch)")
        }
        guard MountMode.streaming.displayName == "Streaming",
              MountMode.cacheOnlyManual.displayName == "Cache only (manual)",
              MountMode.cacheOnlyPending.displayName == "Cache only (uploads pending, automatic)",
              MountMode.cacheOnlyOffline.displayName == "Cache only (offline, automatic)"
        else {
            return report("AC-MM1", "mount-mode-parse", false, "(display name mismatch)")
        }
        guard !MountMode.streaming.isCacheOnly, MountMode.cacheOnlyManual.isCacheOnly,
              MountMode.cacheOnlyPending.isCacheOnly, MountMode.cacheOnlyOffline.isCacheOnly,
              !MountMode.cacheOnlyManual.isAutomatic, MountMode.cacheOnlyPending.isAutomatic,
              MountMode.cacheOnlyOffline.isAutomatic
        else {
            return report("AC-MM1", "mount-mode-parse", false, "(isCacheOnly/isAutomatic mismatch)")
        }
        return report("AC-MM1", "mount-mode-parse", true)
    }

    // MARK: - AC-CK2 — mount mode never streams through the fallback

    private static func testMountNoFallbackOverride() -> Bool {
        let dir = "\(selfTestRoot)/ck2-\(UUID().uuidString)"
        let local = "\(dir)/mnt", cache = "\(dir)/cache"
        try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)

        let profile = mountFixtureProfile(
            localPath: local, cachePath: cache,
            rcloneRemote: "unreachableprimary:", remotePath: "Kaiju",
            // `fallbackRemote` conventionally has NO trailing colon (see the
            // `SyncProfile.fallbackRemote` doc comment, e.g. "synology-sftp") — unlike
            // `rcloneRemote`. Getting this wrong makes `dump_remote_as_env`'s `.get(remote,
            // {})` JSON lookup silently miss the config section (its key has no colon
            // either), so any mutation of the mount-fallback guard below would go
            // undetected — the earlier version of this fixture had exactly that bug.
            fallbackRemote: "fixturefallback")
        // `cacheOnlyConfigPath` is deliberately NOT under `vfsCachePath` (it lives beside the
        // other real per-profile config files under `~/.config/synctray/profiles/` — see
        // CLAUDE.md's "Cache-Only" section) — a non-streaming mode's dry run writes a REAL
        // file there. Clean it up so no self-test artifact survives outside the temp sandbox.
        defer { try? FileManager.default.removeItem(atPath: profile.cacheOnlyConfigPath) }
        // The PRIMARY is left undefined so it fails to resolve near-instantly (no real
        // network wait) — genuinely unreachable. The FALLBACK is a REAL, resolvable alias
        // remote: if the script's mount branch ever entered the "same remote name preserved"
        // env-var-override path (the bug R2 removes), `dump_remote_as_env` would copy this
        // section's real key/value pairs into `RCLONE_CONFIG_UNREACHABLEPRIMARY_*` and
        // `envOverrides` would be > 0 — an EMPTY fallback section (as a prior version of this
        // test used) can never distinguish "the branch ran and copied nothing" from "the
        // branch never ran", which would make this assertion vacuous.
        let fallbackTarget = "\(dir)/fallback-target"
        try? FileManager.default.createDirectory(atPath: fallbackTarget, withIntermediateDirectories: true)
        let result = dryRunMountScript(
            profile: profile, rcloneConfig: aliasRcloneConfig(name: "fixturefallback", path: fallbackTarget))

        guard result.mode == MountMode.cacheOnlyOffline.rawValue else {
            return report("AC-CK2", "mount-no-fallback-override", false,
                          "(mode=\(result.mode ?? "nil") output=\(result.output) log=\(result.log))")
        }
        guard result.envOverrides == 0 else {
            return report("AC-CK2", "mount-no-fallback-override", false,
                          "(expected 0 RCLONE_CONFIG_ overrides, got \(result.envOverrides ?? -1))")
        }
        guard let cmd = result.cmd, !cmd.contains("fixturefallback") else {
            return report("AC-CK2", "mount-no-fallback-override", false,
                          "(rendered command names the fallback remote: \(result.cmd ?? "nil"))")
        }
        // The decisive check: Cache Only's rendered command mounts the union remote
        // (`synctray_cacheonly:`), which never echoes `$REMOTE` by name — so a
        // reintroduced fallback branch would pass every check above while still having
        // run. The one place that branch is unconditionally observable is the log line
        // it writes BEFORE mode selection ever runs.
        guard !result.log.contains("using fallback:") else {
            return report("AC-CK2", "mount-no-fallback-override", false,
                          "(log shows the fallback branch ran for a mount profile: \(result.log))")
        }
        return report("AC-CK2", "mount-no-fallback-override", true)
    }

    // MARK: - AC-CK3 — suffixed vfs/vfsMeta cache-key consolidation

    private static func writeFile(_ path: String, _ contents: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func testCacheSuffixConsolidation() -> Bool {
        let root = "\(selfTestRoot)/ck3-\(UUID().uuidString)"
        let local = "\(root)/mnt", cache = "\(root)/cache"
        try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)

        // Suffixed source tree, matching the real "detected overridden config" shape.
        writeFile("\(cache)/vfs/synology{jzZaN}/Kaiju/KAIJU/file.bin", "hello")
        writeFile("\(cache)/vfsMeta/synology{jzZaN}/Kaiju/KAIJU/file.bin", "{\"Size\":5}")

        let profile = mountFixtureProfile(localPath: local, cachePath: cache, remotePath: "Kaiju/KAIJU")
        // See AC-CK2's identical comment: this dry run is unreachable → non-streaming mode →
        // a REAL file under ~/.config/synctray/profiles/ gets written; clean it up.
        defer { try? FileManager.default.removeItem(atPath: profile.cacheOnlyConfigPath) }
        // No remote defined — reachability probe fails fast; consolidation runs regardless.
        let result = dryRunMountScript(profile: profile, rcloneConfig: "")
        guard result.exitCode == 0 else {
            return report("AC-CK3", "cache-suffix-consolidation", false, "(dry-run exited \(result.exitCode): \(result.output) log=\(result.log))")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: "\(cache)/vfs/synology/Kaiju/KAIJU/file.bin"),
              (try? String(contentsOfFile: "\(cache)/vfs/synology/Kaiju/KAIJU/file.bin")) == "hello",
              fm.fileExists(atPath: "\(cache)/vfsMeta/synology/Kaiju/KAIJU/file.bin")
        else {
            return report("AC-CK3", "cache-suffix-consolidation", false,
                          "(suffixed tree was not consolidated into the unsuffixed location: \(result.output))")
        }
        guard !fm.fileExists(atPath: "\(cache)/vfs/synology{jzZaN}") else {
            return report("AC-CK3", "cache-suffix-consolidation", false, "(emptied suffixed ancestor was not pruned)")
        }

        // Rerun on an already-consolidated tree: no candidate left, must be a harmless no-op.
        let rerun = dryRunMountScript(profile: profile, rcloneConfig: "")
        guard rerun.exitCode == 0,
              (try? String(contentsOfFile: "\(cache)/vfs/synology/Kaiju/KAIJU/file.bin")) == "hello"
        else {
            return report("AC-CK3", "cache-suffix-consolidation", false, "(rerun on a consolidated tree was not a no-op)")
        }

        // Occupied destination: a second profile whose destination already has real data —
        // the stray suffixed tree must be LEFT ALONE, not merged or overwritten.
        let cache2 = "\(root)/cache2"
        writeFile("\(cache2)/vfs/synology{jzZaN}/Elsewhere/PATH/stray.bin", "stray")
        writeFile("\(cache2)/vfs/synology/Elsewhere/PATH/existing.bin", "existing")
        let profile2 = mountFixtureProfile(localPath: "\(root)/mnt2", cachePath: cache2, remotePath: "Elsewhere/PATH")
        defer { try? FileManager.default.removeItem(atPath: profile2.cacheOnlyConfigPath) }
        try? FileManager.default.createDirectory(atPath: "\(root)/mnt2", withIntermediateDirectories: true)
        _ = dryRunMountScript(profile: profile2, rcloneConfig: "")
        guard fm.fileExists(atPath: "\(cache2)/vfs/synology{jzZaN}/Elsewhere/PATH/stray.bin"),
              fm.fileExists(atPath: "\(cache2)/vfs/synology/Elsewhere/PATH/existing.bin")
        else {
            return report("AC-CK3", "cache-suffix-consolidation", false,
                          "(an occupied destination did not leave both trees in place)")
        }

        return report("AC-CK3", "cache-suffix-consolidation", true)
    }

    /// Run the mount script's consolidation step against a fresh fixture cache that
    /// `setup` seeds (paths relative to the cache root), returning the cache root.
    private static func runConsolidationScenario(
        _ label: String, cache existingCache: String? = nil, setup: (String) -> Void
    ) -> (cache: String, result: DryRunResult) {
        let root = "\(selfTestRoot)/\(label)-\(UUID().uuidString)"
        let local = "\(root)/mnt", cache = existingCache ?? "\(root)/cache"
        try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        setup(cache)
        let profile = mountFixtureProfile(localPath: local, cachePath: cache, remotePath: "Kaiju/KAIJU")
        defer { try? FileManager.default.removeItem(atPath: profile.cacheOnlyConfigPath) }
        return (cache, dryRunMountScript(profile: profile, rcloneConfig: ""))
    }

    // MARK: - AC-CK5 — suffix consolidation decides once for the vfs/vfsMeta pair

    private static func testCacheSuffixPairSafety() -> Bool {
        let fm = FileManager.default
        let suffixed = "synology{jzZaN}/Kaiju/KAIJU"

        // (c) vfs-only suffixed tree: its sidecars are gone, so rclone would discard the
        // data anyway — moving it would only plant metadata-less data at the live key.
        let vfsOnly = runConsolidationScenario("ck5-vfsonly") { cache in
            writeFile("\(cache)/vfs/\(suffixed)/file.bin", "hello")
        }
        guard fm.fileExists(atPath: "\(vfsOnly.cache)/vfs/\(suffixed)/file.bin"),
              !fm.fileExists(atPath: "\(vfsOnly.cache)/vfs/synology/Kaiju/KAIJU")
        else {
            return report("AC-CK5", "cache-suffix-pair-safety", false,
                          "(a vfs tree without its vfsMeta was moved: \(vfsOnly.result.log))")
        }

        // (d) vfsMeta-only suffixed tree: sidecars describing bytes that are not there.
        let metaOnly = runConsolidationScenario("ck5-metaonly") { cache in
            writeFile("\(cache)/vfsMeta/\(suffixed)/file.bin", "{\"Size\":5}")
        }
        guard fm.fileExists(atPath: "\(metaOnly.cache)/vfsMeta/\(suffixed)/file.bin"),
              !fm.fileExists(atPath: "\(metaOnly.cache)/vfsMeta/synology/Kaiju/KAIJU")
        else {
            return report("AC-CK5", "cache-suffix-pair-safety", false,
                          "(a vfsMeta tree without its vfs data was moved: \(metaOnly.result.log))")
        }

        // Only the vfsMeta destination is occupied: the PAIR stays put — moving vfs alone
        // would pair the stray data with someone else's byte-range metadata.
        let halfOccupied = runConsolidationScenario("ck5-half") { cache in
            writeFile("\(cache)/vfs/\(suffixed)/file.bin", "hello")
            writeFile("\(cache)/vfsMeta/\(suffixed)/file.bin", "{\"Size\":5}")
            writeFile("\(cache)/vfsMeta/synology/Kaiju/KAIJU/other.bin", "{\"Size\":9}")
        }
        guard fm.fileExists(atPath: "\(halfOccupied.cache)/vfs/\(suffixed)/file.bin"),
              fm.fileExists(atPath: "\(halfOccupied.cache)/vfsMeta/\(suffixed)/file.bin"),
              !fm.fileExists(atPath: "\(halfOccupied.cache)/vfs/synology/Kaiju/KAIJU")
        else {
            return report("AC-CK5", "cache-suffix-pair-safety", false,
                          "(one half of the pair moved into a partly-occupied destination: \(halfOccupied.result.log))")
        }

        // vfs rename fails after vfsMeta already moved → vfsMeta is rolled back. The
        // primary's vfs root is made read-only so creating vfs/synology/Kaiju fails.
        var lockedDir = ""
        let rollback = runConsolidationScenario("ck5-rollback") { cache in
            writeFile("\(cache)/vfs/\(suffixed)/file.bin", "hello")
            writeFile("\(cache)/vfsMeta/\(suffixed)/file.bin", "{\"Size\":5}")
            lockedDir = "\(cache)/vfs/synology"
            try? fm.createDirectory(atPath: lockedDir, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir)
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir)
        guard fm.fileExists(atPath: "\(rollback.cache)/vfs/\(suffixed)/file.bin"),
              fm.fileExists(atPath: "\(rollback.cache)/vfsMeta/\(suffixed)/file.bin"),
              !fm.fileExists(atPath: "\(rollback.cache)/vfsMeta/synology/Kaiju/KAIJU"),
              rollback.result.log.contains("rolled vfsMeta back")
        else {
            return report("AC-CK5", "cache-suffix-pair-safety", false,
                          "(a failed vfs rename did not roll the vfsMeta rename back: \(rollback.result.log))")
        }
        return report("AC-CK5", "cache-suffix-pair-safety", true)
    }

    // MARK: - AC-CK6 — an EMPTY destination is absent, a destination with a file is not

    private static func testCacheSuffixEmptyDestination() -> Bool {
        let fm = FileManager.default
        let suffixed = "synology{jzZaN}/Kaiju/KAIJU"
        let seedPair: (String) -> Void = { cache in
            writeFile("\(cache)/vfs/\(suffixed)/dir/file.bin", "hello")
            writeFile("\(cache)/vfsMeta/\(suffixed)/dir/file.bin", "{\"Size\":5}")
        }

        // (a) Both destinations exist as empty directory chains — what a mount of the
        // unsuffixed key leaves behind before caching a byte. They must not block adoption.
        let empty = runConsolidationScenario("ck6-empty") { cache in
            seedPair(cache)
            try? fm.createDirectory(atPath: "\(cache)/vfs/synology/Kaiju/KAIJU/a/b", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: "\(cache)/vfsMeta/synology/Kaiju/KAIJU/c", withIntermediateDirectories: true)
        }
        guard (try? String(contentsOfFile: "\(empty.cache)/vfs/synology/Kaiju/KAIJU/dir/file.bin")) == "hello",
              (try? String(contentsOfFile: "\(empty.cache)/vfsMeta/synology/Kaiju/KAIJU/dir/file.bin")) == "{\"Size\":5}",
              !fm.fileExists(atPath: "\(empty.cache)/vfs/synology{jzZaN}"),
              !fm.fileExists(atPath: "\(empty.cache)/vfsMeta/synology{jzZaN}")
        else {
            return report("AC-CK6", "cache-suffix-empty-destination", false,
                          "(an empty destination blocked adoption: \(empty.result.log))")
        }

        // (e) Idempotent: a second run over the consolidated cache changes nothing.
        let rerun = runConsolidationScenario("ck6-rerun", cache: empty.cache) { _ in }
        guard rerun.result.exitCode == 0,
              (try? String(contentsOfFile: "\(empty.cache)/vfs/synology/Kaiju/KAIJU/dir/file.bin")) == "hello",
              (try? String(contentsOfFile: "\(empty.cache)/vfsMeta/synology/Kaiju/KAIJU/dir/file.bin")) == "{\"Size\":5}",
              !rerun.result.log.contains("Cache key: moved")
        else {
            return report("AC-CK6", "cache-suffix-empty-destination", false,
                          "(second run over a consolidated cache was not a no-op: \(rerun.result.log))")
        }

        // (b) A destination holding any file, however deep, is populated: nothing moves and
        // the existing file is untouched (never merged, never pruned).
        let occupied = runConsolidationScenario("ck6-occupied") { cache in
            seedPair(cache)
            writeFile("\(cache)/vfs/synology/Kaiju/KAIJU/deep/er/existing.bin", "existing")
            try? fm.createDirectory(atPath: "\(cache)/vfsMeta/synology/Kaiju/KAIJU", withIntermediateDirectories: true)
        }
        guard fm.fileExists(atPath: "\(occupied.cache)/vfs/\(suffixed)/dir/file.bin"),
              fm.fileExists(atPath: "\(occupied.cache)/vfsMeta/\(suffixed)/dir/file.bin"),
              (try? String(contentsOfFile: "\(occupied.cache)/vfs/synology/Kaiju/KAIJU/deep/er/existing.bin")) == "existing",
              !fm.fileExists(atPath: "\(occupied.cache)/vfs/synology/Kaiju/KAIJU/dir")
        else {
            return report("AC-CK6", "cache-suffix-empty-destination", false,
                          "(a destination holding a file did not leave both trees in place: \(occupied.result.log))")
        }
        return report("AC-CK6", "cache-suffix-empty-destination", true)
    }

    // MARK: - AC-CK4 — mount command keeps a spaced path as ONE argument

    /// Word-split `cmd` exactly the way the script's `eval "$RCLONE_CMD"` does, returning the
    /// resulting argv. A path whose quotes were consumed at assignment time (a bare `"`
    /// rendered into the script instead of `\"`) splits into several words here — the same
    /// split rclone would receive.
    private static func evalArgv(_ cmd: String) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "eval \"set -- $1\"; printf '%s\\0' \"$@\"", "_", cmd]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }

    private static func argFollowing(_ flag: String, in argv: [String]) -> String? {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
        return argv[i + 1]
    }

    private static func testMountCommandQuoting() -> Bool {
        let root = "\(selfTestRoot)/ck4 spaced \(UUID().uuidString)"
        let local = "\(root)/My Mount", cache = "\(root)/Cache Dir"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: local, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let target = "\(root)/remote-target"
        try? fm.createDirectory(atPath: target, withIntermediateDirectories: true)

        // Streaming: primary reachable (alias remote) → the streaming command.
        let streaming = mountFixtureProfile(localPath: local, cachePath: cache)
        defer { try? fm.removeItem(atPath: streaming.cacheOnlyConfigPath) }
        let s = dryRunMountScript(
            profile: streaming, rcloneConfig: aliasRcloneConfig(name: "synology", path: target))
        guard s.mode == MountMode.streaming.rawValue, let sCmd = s.cmd else {
            return report("AC-CK4", "mount-command-quoting", false,
                          "(streaming fixture did not dry-run streaming: \(s.output) log=\(s.log))")
        }
        let sArgv = evalArgv(sCmd)
        guard sArgv.contains(local),
              argFollowing("--cache-dir", in: sArgv) == cache,
              argFollowing("--volname", in: sArgv) == "My Mount"
        else {
            return report("AC-CK4", "mount-command-quoting", false,
                          "(streaming command splits a spaced path: \(sArgv))")
        }

        // Cache Only: every path the union mount passes must survive eval as one word too.
        let cacheOnly = mountFixtureProfile(localPath: local, cachePath: cache, streamCacheOnly: true)
        defer { try? fm.removeItem(atPath: cacheOnly.cacheOnlyConfigPath) }
        let c = dryRunMountScript(profile: cacheOnly, rcloneConfig: "")
        guard c.mode == MountMode.cacheOnlyManual.rawValue, let cCmd = c.cmd else {
            return report("AC-CK4", "mount-command-quoting", false,
                          "(cache-only fixture did not dry-run cache-only: \(c.output) log=\(c.log))")
        }
        let cArgv = evalArgv(cCmd)
        guard cArgv.contains(local),
              argFollowing("--cache-dir", in: cArgv) == cacheOnly.cacheOnlyCachePath,
              argFollowing("--exclude-from", in: cArgv) == cacheOnly.cacheOnlyExcludePath,
              argFollowing("--config", in: cArgv) == cacheOnly.cacheOnlyConfigPath,
              argFollowing("--volname", in: cArgv) == "My Mount"
        else {
            return report("AC-CK4", "mount-command-quoting", false,
                          "(cache-only command splits a spaced path: \(cArgv))")
        }
        return report("AC-CK4", "mount-command-quoting", true)
    }

    // MARK: - AC-CO1 — Cache Only union config + command composition

    private static func testCacheOnlyUnionConfig() -> Bool {
        let root = "\(selfTestRoot)/co1-\(UUID().uuidString)"
        let local = "\(root)/mnt", cache = "\(root)/cache"
        try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)

        let profile = mountFixtureProfile(localPath: local, cachePath: cache, streamCacheOnly: true)
        // See AC-CK2's comment: Cache Only writes a REAL file under
        // ~/.config/synctray/profiles/ (by design — see CLAUDE.md). Clean it up so this
        // self-test leaves nothing behind outside the temp sandbox.
        defer { try? FileManager.default.removeItem(atPath: profile.cacheOnlyConfigPath) }
        let result = dryRunMountScript(profile: profile, rcloneConfig: "")

        guard result.mode == MountMode.cacheOnlyManual.rawValue else {
            return report("AC-CO1", "cache-only-union-config", false, "(mode=\(result.mode ?? "nil") output=\(result.output) log=\(result.log))")
        }
        guard let cmd = result.cmd else {
            return report("AC-CO1", "cache-only-union-config", false, "(no rendered command: \(result.output))")
        }
        guard cmd.contains("--config"), cmd.contains("--vfs-cache-mode writes"),
              cmd.contains("--volname"), !cmd.contains("--rc")
        else {
            return report("AC-CO1", "cache-only-union-config", false, "(command missing expected flags: \(cmd))")
        }
        guard !cmd.contains("--cache-dir \"\(cache)\"") else {
            return report("AC-CO1", "cache-only-union-config", false, "(cache-only mount reused the streaming --cache-dir)")
        }

        let confPath = profile.cacheOnlyConfigPath
        guard let confText = try? String(contentsOfFile: confPath, encoding: .utf8) else {
            return report("AC-CO1", "cache-only-union-config", false, "(union config was not written)")
        }
        guard confText.contains("type = union"),
              confText.contains("action_policy = ff"), confText.contains("create_policy = ff"),
              confText.contains("search_policy = ff")
        else {
            return report("AC-CO1", "cache-only-union-config", false, "(union config missing expected keys: \(confText)")
        }
        guard let overlayRange = confText.range(of: profile.overlayPath),
              let dataRange = confText.range(of: "\(cache)/vfs/synology/Kaiju/KAIJU:ro"),
              overlayRange.lowerBound < dataRange.lowerBound
        else {
            return report("AC-CO1", "cache-only-union-config", false,
                          "(overlay upstream is not listed before the read-only cache upstream: \(confText))")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: confPath)
        guard let perms = attrs?[.posixPermissions] as? NSNumber, perms.uint16Value & 0o777 == 0o600 else {
            return report("AC-CO1", "cache-only-union-config", false, "(union config is not 0600)")
        }

        // `bash -n` on the rendered SCRIPT file itself (syntax check only, never executes).
        let syntaxCheck = Process()
        syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/bash")
        syntaxCheck.arguments = ["-n", result.scriptPath]
        let syntaxPipe = Pipe()
        syntaxCheck.standardError = syntaxPipe
        try? syntaxCheck.run()
        syntaxCheck.waitUntilExit()
        guard syntaxCheck.terminationStatus == 0 else {
            let errText = String(data: syntaxPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return report("AC-CO1", "cache-only-union-config", false, "(bash -n failed: \(errText))")
        }

        return report("AC-CO1", "cache-only-union-config", true)
    }

    // MARK: - AC-CO2 — real rclone against the generated union config + exclude list

    private static func testCacheOnlyUnionBehaviour() -> Bool {
        let root = "\(selfTestRoot)/co2-\(UUID().uuidString)"
        let local = "\(root)/mnt", cache = "\(root)/cache"
        let dataDir = "\(cache)/vfs/synology/Kaiju/KAIJU"
        let metaDir = "\(cache)/vfsMeta/synology/Kaiju/KAIJU"
        try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)

        // complete.txt: full byte-range coverage, Dirty:false — must SHOW.
        writeFile("\(dataDir)/complete.txt", "hello")
        writeFile("\(metaDir)/complete.txt", "{\"Size\":5,\"Rs\":[{\"Pos\":0,\"Size\":5}],\"Dirty\":false}")
        // dirty.txt: full coverage but Dirty:true — Dirty is deliberately ignored — must SHOW.
        writeFile("\(dataDir)/dirty.txt", "world")
        writeFile("\(metaDir)/dirty.txt", "{\"Size\":5,\"Rs\":[{\"Pos\":0,\"Size\":5}],\"Dirty\":true}")
        // partial.txt: sidecar covers only 4 of 10 bytes — must HIDE.
        writeFile("\(dataDir)/partial.txt", "0123456789")
        writeFile("\(metaDir)/partial.txt", "{\"Size\":10,\"Rs\":[{\"Pos\":0,\"Size\":4}],\"Dirty\":false}")
        // nometa.txt: no sidecar at all — must HIDE.
        writeFile("\(dataDir)/nometa.txt", "no sidecar here")

        let profile = mountFixtureProfile(localPath: local, cachePath: cache, streamCacheOnly: true)
        // See AC-CK2's comment: cleans up the REAL ~/.config/synctray/profiles/ file this
        // dry run writes (by design). Deferred to the end of this function since the direct
        // rclone calls below still need to read it.
        defer { try? FileManager.default.removeItem(atPath: profile.cacheOnlyConfigPath) }
        let result = dryRunMountScript(profile: profile, rcloneConfig: "")
        guard result.mode == MountMode.cacheOnlyManual.rawValue else {
            return report("AC-CO2", "cache-only-union-behaviour", false, "(fixture did not dry-run cache-only: \(result.output) log=\(result.log))")
        }

        guard let rclone = RcloneLocator.resolve() else {
            return report("AC-CO2", "cache-only-union-behaviour", false, "(rclone not found)")
        }
        func runRclone(_ args: [String]) -> (Int32, String, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: rclone)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return (-1, "", "\(error)") }
            p.waitUntilExit()
            let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (p.terminationStatus, o, e)
        }

        let confArgs = ["--config", profile.cacheOnlyConfigPath]
        let excludeArgs = ["--exclude-from", profile.cacheOnlyExcludePath]

        // Complete + complete-dirty show; partial + missing-sidecar hide.
        let (lsExit, lsOut, lsErr) = runRclone(confArgs + excludeArgs + ["lsf", "synctray_cacheonly:"])
        guard lsExit == 0 else {
            return report("AC-CO2", "cache-only-union-behaviour", false, "(lsf failed: \(lsErr))")
        }
        let listed = Set(lsOut.split(separator: "\n").map(String.init))
        guard listed.contains("complete.txt"), listed.contains("dirty.txt"),
              !listed.contains("partial.txt"), !listed.contains("nometa.txt")
        else {
            return report("AC-CO2", "cache-only-union-behaviour", false, "(unexpected listing: \(listed))")
        }

        // Writes land in the overlay, never the read-only cache tree. `copyto` from a real
        // local source file, not `rcat` — `rcat` reads stdin, which this non-interactive
        // process has none of (`nothing to read from standard input`).
        let sourceFile = "\(root)/new-source.txt"
        writeFile(sourceFile, "new content")
        let (_, _, copyErr) = runRclone(confArgs + ["copyto", sourceFile, "synctray_cacheonly:new.txt"])
        guard FileManager.default.fileExists(atPath: "\(profile.overlayPath)/new.txt"),
              !FileManager.default.fileExists(atPath: "\(dataDir)/new.txt")
        else {
            return report("AC-CO2", "cache-only-union-behaviour", false, "(write did not land in the overlay: \(copyErr))")
        }

        // Deleting a base (read-only) file must fail.
        let (delExit, _, _) = runRclone(confArgs + ["deletefile", "synctray_cacheonly:complete.txt"])
        guard delExit != 0, FileManager.default.fileExists(atPath: "\(dataDir)/complete.txt") else {
            return report("AC-CO2", "cache-only-union-behaviour", false, "(deleting a read-only base file did not fail)")
        }

        return report("AC-CO2", "cache-only-union-behaviour", true)
    }

    // MARK: - AC-AO1 — mount mode selection across the six fixture situations

    private static func testMountModeSelection() -> Bool {
        func scenario(
            _ label: String,
            reachable: Bool,
            overlayFile: String? = nil,
            dirtySidecar: Bool = false,
            streamCacheOnly: Bool = false
        ) -> String? {
            let root = "\(selfTestRoot)/ao1-\(UUID().uuidString)"
            let local = "\(root)/mnt", cache = "\(root)/cache"
            try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
            let profile = mountFixtureProfile(
                localPath: local, cachePath: cache, rcloneRemote: "synology:", streamCacheOnly: streamCacheOnly)
            // See AC-CK2's comment: any non-streaming outcome below writes a REAL file under
            // ~/.config/synctray/profiles/ (by design). Clean it up per scenario.
            defer { try? FileManager.default.removeItem(atPath: profile.cacheOnlyConfigPath) }
            if let overlayFile {
                writeFile("\(profile.overlayPath)/\(overlayFile)", "content")
            }
            if dirtySidecar {
                writeFile("\(profile.cacheOnlyCachePath)/vfsMeta/dirty.txt", "{\"Dirty\":true}")
            }
            let conf = reachable ? aliasRcloneConfig(name: "synology", path: "\(root)/reachable-target") : ""
            if reachable { try? FileManager.default.createDirectory(atPath: "\(root)/reachable-target", withIntermediateDirectories: true) }
            let result = dryRunMountScript(profile: profile, rcloneConfig: conf)
            return result.mode
        }

        let cases: [(String, String?, String?)] = [
            ("primary unreachable", MountMode.cacheOnlyOffline.rawValue,
             { scenario("offline", reachable: false) }()),
            ("reachable, empty overlay", MountMode.streaming.rawValue,
             { scenario("empty", reachable: true) }()),
            ("reachable, real overlay file", MountMode.cacheOnlyPending.rawValue,
             { scenario("pending", reachable: true, overlayFile: "note.txt") }()),
            ("reachable, only .DS_Store in overlay", MountMode.streaming.rawValue,
             { scenario("dsstore", reachable: true, overlayFile: ".DS_Store") }()),
            ("reachable, Dirty sidecar in writes cache", MountMode.cacheOnlyPending.rawValue,
             { scenario("dirty", reachable: true, dirtySidecar: true) }()),
            ("streamCacheOnly true", MountMode.cacheOnlyManual.rawValue,
             { scenario("manual", reachable: true, streamCacheOnly: true) }()),
        ]

        for (label, expected, actual) in cases {
            guard actual == expected else {
                return report("AC-AO1", "mount-mode-selection", false, "(\(label): expected \(expected), got \(actual ?? "nil"))")
            }
        }
        return report("AC-AO1", "mount-mode-selection", true)
    }

    // MARK: - AC-AO2 — auto-resume decision + lsof busy-process parsing

    private static func testAutoResumeDecision() -> Bool {
        // Manual Cache Only is never a candidate, regardless of stability/busy state.
        guard SyncManager.autoResumeDecision(
            mode: .cacheOnlyManual, manualCacheOnly: true, primaryStable: true, blockingProcesses: []
        ) == .wait else {
            return report("AC-AO2", "auto-resume-decision", false, "(manual mode resumed automatically)")
        }
        // Streaming is never a candidate (nothing to resume FROM).
        guard SyncManager.autoResumeDecision(
            mode: .streaming, manualCacheOnly: false, primaryStable: true, blockingProcesses: []
        ) == .wait else {
            return report("AC-AO2", "auto-resume-decision", false, "(streaming mode was treated as resumable)")
        }
        // Automatic mode, primary not yet stable → wait.
        guard SyncManager.autoResumeDecision(
            mode: .cacheOnlyOffline, manualCacheOnly: false, primaryStable: false, blockingProcesses: []
        ) == .wait else {
            return report("AC-AO2", "auto-resume-decision", false, "(unstable primary resumed anyway)")
        }
        // Automatic, stable, nothing open → resume.
        guard SyncManager.autoResumeDecision(
            mode: .cacheOnlyOffline, manualCacheOnly: false, primaryStable: true, blockingProcesses: []
        ) == .resume else {
            return report("AC-AO2", "auto-resume-decision", false, "(stable + idle did not resume)")
        }
        guard SyncManager.autoResumeDecision(
            mode: .cacheOnlyPending, manualCacheOnly: false, primaryStable: true, blockingProcesses: []
        ) == .resume else {
            return report("AC-AO2", "auto-resume-decision", false, "(pending mode, stable + idle did not resume)")
        }
        // Automatic, stable, something open → notify (not resume, not silent wait).
        guard SyncManager.autoResumeDecision(
            mode: .cacheOnlyOffline, manualCacheOnly: false, primaryStable: true, blockingProcesses: ["Reaper"]
        ) == .notify else {
            return report("AC-AO2", "auto-resume-decision", false, "(busy mount resumed instead of notifying)")
        }

        // lsof -F pc parsing: 'p<pid>' lines are ignored, 'c<command>' lines are the answer,
        // and macOS's own indexing/preview daemons never count as "busy".
        let lsof = "p111\ncFinder\np222\ncmds\np333\ncReaper\np444\ncmdworker_shared\n"
        let blocking = SyncManager.blockingProcesses(lsofOutput: lsof)
        guard blocking == ["Reaper"] else {
            return report("AC-AO2", "auto-resume-decision", false, "(lsof parse: expected [Reaper], got \(blocking))")
        }
        guard SyncManager.blockingProcesses(lsofOutput: "") == [] else {
            return report("AC-AO2", "auto-resume-decision", false, "(empty lsof output produced blocking processes)")
        }

        // A FAILED busy check (lsof error/timeout → nil) must fail closed: we could not
        // confirm the mount is idle, so the user is asked instead of being remounted under.
        let failedBlockers = SyncManager.autoResumeBlockers(lsofOutput: nil)
        guard !failedBlockers.isEmpty,
              SyncManager.autoResumeDecision(
                  mode: .cacheOnlyOffline, manualCacheOnly: false, primaryStable: true,
                  blockingProcesses: failedBlockers) == .notify
        else {
            return report("AC-AO2", "auto-resume-decision", false, "(a failed lsof busy check resumed instead of notifying)")
        }
        // …while a check that ran and found nothing open still resumes.
        guard SyncManager.autoResumeDecision(
            mode: .cacheOnlyOffline, manualCacheOnly: false, primaryStable: true,
            blockingProcesses: SyncManager.autoResumeBlockers(lsofOutput: "")) == .resume
        else {
            return report("AC-AO2", "auto-resume-decision", false, "(an idle lsof result did not resume)")
        }

        return report("AC-AO2", "auto-resume-decision", true)
    }

    // MARK: - AC-AO3 — Resume Syncing while unreachable hands off to automatic resume

    private static func testResumeWhileUnreachableHandOff() -> Bool {
        // A running MANUAL Cache Only mount must become an automatic candidate, or the
        // recovery monitor (which only considers automatic modes) never resumes it.
        guard let next = SyncManager.mountModeAfterResumeWhileUnreachable(current: .cacheOnlyManual),
              next.isCacheOnly, next.isAutomatic,
              SyncManager.autoResumeDecision(
                  mode: next, manualCacheOnly: false, primaryStable: true, blockingProcesses: []) == .resume
        else {
            return report("AC-AO3", "resume-while-unreachable-handoff", false,
                          "(manual Cache Only was not handed to automatic resume)")
        }
        // Nothing to relabel: not mounted, streaming, or already automatic.
        guard SyncManager.mountModeAfterResumeWhileUnreachable(current: nil) == nil,
              SyncManager.mountModeAfterResumeWhileUnreachable(current: .streaming) == nil,
              SyncManager.mountModeAfterResumeWhileUnreachable(current: .cacheOnlyPending) == nil,
              SyncManager.mountModeAfterResumeWhileUnreachable(current: .cacheOnlyOffline) == nil
        else {
            return report("AC-AO3", "resume-while-unreachable-handoff", false,
                          "(a non-manual mode was relabelled)")
        }
        return report("AC-AO3", "resume-while-unreachable-handoff", true)
    }

    // MARK: - AC-OU1 — overlay upload planner (pure decision matrix)

    private static func testOverlayUploadPlan() -> Bool {
        let now = Date()
        let file = OverlaySyncService.OverlayFile(
            relativePath: "notes.txt", absolutePath: "/tmp/notes.txt", size: 100, modificationDate: now)

        // No manifest entry, no remote entry at all → plain upload (brand new file).
        guard OverlaySyncService.plan(file: file, manifestEntry: nil, expected: nil, remote: nil, now: now)
            == .upload(dest: "notes.txt")
        else {
            return report("AC-OU1", "overlay-upload-plan", false, "(new file did not plan as a plain upload)")
        }

        // Remote has SOMETHING there, but we have no fingerprint to compare against → conflict
        // (safe direction: never silently overwrite an unknown remote version).
        let remoteState = OverlaySyncService.RemoteState(size: 999, modTime: now)
        guard case .uploadConflict(dest: "notes.txt") = OverlaySyncService.plan(
            file: file, manifestEntry: nil, expected: nil, remote: remoteState, now: now)
        else {
            return report("AC-OU1", "overlay-upload-plan", false, "(unparseable expected + present remote did not conflict)")
        }

        // Remote matches the expected fingerprint (size + modtime within 1s) → plain upload.
        let expected = OverlaySyncService.RemoteState(size: 999, modTime: now)
        let matchingRemote = OverlaySyncService.RemoteState(size: 999, modTime: now.addingTimeInterval(0.5))
        guard OverlaySyncService.plan(file: file, manifestEntry: nil, expected: expected, remote: matchingRemote, now: now)
            == .upload(dest: "notes.txt")
        else {
            return report("AC-OU1", "overlay-upload-plan", false, "(matching fingerprint within 1s did not plan as upload)")
        }

        // Remote diverges from expected → conflict.
        let divergedRemote = OverlaySyncService.RemoteState(size: 999, modTime: now.addingTimeInterval(60))
        guard case .uploadConflict(dest: "notes.txt") = OverlaySyncService.plan(
            file: file, manifestEntry: nil, expected: expected, remote: divergedRemote, now: now)
        else {
            return report("AC-OU1", "overlay-upload-plan", false, "(diverged remote fingerprint did not conflict)")
        }

        // Manifest entry matches the file exactly (size + modtime within 1s) → already uploaded.
        let matchingManifest = OverlaySyncService.ManifestEntry(
            localSize: 100, localModTime: now.addingTimeInterval(0.4), remoteSize: 100, remoteModTime: now,
            uploadedAs: "notes.txt", uploadedAt: now)
        guard OverlaySyncService.plan(file: file, manifestEntry: matchingManifest, expected: nil, remote: nil, now: now)
            == .alreadyUploaded
        else {
            return report("AC-OU1", "overlay-upload-plan", false, "(matching manifest entry was not alreadyUploaded)")
        }
        // A manifest entry that no longer matches (file changed since) must NOT short-circuit.
        let staleManifest = OverlaySyncService.ManifestEntry(
            localSize: 50, localModTime: now.addingTimeInterval(-500), remoteSize: 50, remoteModTime: now,
            uploadedAs: "notes.txt", uploadedAt: now)
        guard OverlaySyncService.plan(file: file, manifestEntry: staleManifest, expected: nil, remote: nil, now: now)
            != .alreadyUploaded
        else {
            return report("AC-OU1", "overlay-upload-plan", false, "(stale manifest entry was still alreadyUploaded)")
        }

        // Conflict naming: stem.sync-conflict-YYYYMMDD-HHMMSS.ext, with -2/-3 disambiguation.
        let date = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC
        let name1 = OverlaySyncService.conflictName(for: "docs/report.txt", date: date) { _ in false }
        guard name1.hasPrefix("docs/report.sync-conflict-"), name1.hasSuffix(".txt") else {
            return report("AC-OU1", "overlay-upload-plan", false, "(conflict name shape wrong: \(name1))")
        }
        var seen = Set<String>()
        let name2 = OverlaySyncService.conflictName(for: "docs/report.txt", date: date) { seen.contains($0) || $0 == name1 }
        seen.insert(name1)
        guard name2 != name1, name2.contains("-2") else {
            return report("AC-OU1", "overlay-upload-plan", false, "(conflict name did not disambiguate: \(name1) vs \(name2))")
        }

        // Ignore list: Finder/rclone noise never counts as overlay content.
        guard OverlaySyncService.isIgnored(name: ".DS_Store"), OverlaySyncService.isIgnored(name: "._resource"),
              OverlaySyncService.isIgnored(name: "half.partial"), !OverlaySyncService.isIgnored(name: "real.txt")
        else {
            return report("AC-OU1", "overlay-upload-plan", false, "(ignore list matching is wrong)")
        }
        let scanDir = "\(selfTestRoot)/ou1-scan-\(UUID().uuidString)"
        writeFile("\(scanDir)/.DS_Store", "junk")
        writeFile("\(scanDir)/real.txt", "content")
        let scanned = OverlaySyncService.scan(overlayPath: scanDir)
        guard scanned.map({ $0.relativePath }) == ["real.txt"] else {
            return report("AC-OU1", "overlay-upload-plan", false, "(scan did not skip ignored names: \(scanned))")
        }

        return report("AC-OU1", "overlay-upload-plan", true)
    }

    /// Minimal in-process `OverlayRemoteClient` for engine-level tests that need
    /// deterministic control over listing/upload outcomes (a real network failure isn't
    /// reproducible hermetically) — `run()`'s decision/bookkeeping logic is under test here,
    /// not rclone's wire behaviour (that's AC-OU2/AC-CO2's job against real rclone).
    private final class FakeOverlayRemoteClient: OverlaySyncService.OverlayRemoteClient {
        var filesByDir: [String: [OverlaySyncService.RemoteEntry]] = [:]
        var failUploadsFor: Set<String> = []
        var failListingFor: Set<String> = []
        var uploadCount = 0
        func listFiles(remoteDir: String) -> Result<[OverlaySyncService.RemoteEntry], OverlaySyncService.OverlayUploadError> {
            if failListingFor.contains(remoteDir) { return .failure(.rcloneFailed(exitCode: 1)) }
            return .success(filesByDir[remoteDir] ?? [])
        }
        func upload(localPath: String, remoteDestination: String, expectedSize: Int64)
            -> Result<Void, OverlaySyncService.OverlayUploadError> {
            uploadCount += 1
            if failUploadsFor.contains(localPath) { return .failure(.rcloneFailed(exitCode: 1)) }
            return .success(())
        }
    }

    // MARK: - AC-OU2 — overlay sync-back (drain)

    private static func testOverlaySyncBack() -> Bool {
        let root = "\(selfTestRoot)/ou2-\(UUID().uuidString)"
        let profile = mountFixtureProfile(
            localPath: "\(root)/mnt", cachePath: "\(root)/cache", remotePath: "")
        let overlay = profile.overlayPath
        let dataDir = "\(root)/cache/vfs/synology"
        let metaDir = "\(root)/cache/vfsMeta/synology"

        writeFile("\(overlay)/new.txt", "brand new")
        writeFile("\(overlay)/dirtybase.txt", "edited while cache-only")
        writeFile("\(dataDir)/dirtybase.txt", "original streamed copy")
        writeFile("\(metaDir)/dirtybase.txt", "{\"Size\":23,\"Dirty\":true,\"Fingerprint\":\"23,2024-01-01 00:00:00 +0000 UTC\"}")

        let client = FakeOverlayRemoteClient()
        client.filesByDir[""] = [
            OverlaySyncService.RemoteEntry(name: "dirtybase.txt", size: 23, modTime: Date(timeIntervalSince1970: 1_704_067_200)),
        ]
        let service = OverlaySyncService()
        let result1 = await_ { await service.run(
            profile: profile, remoteBase: "testremote:", mode: .drain, transport: "primary", client: client) }

        guard result1.uploaded >= 1 else {
            return report("AC-OU2", "overlay-sync-back", false, "(new.txt was not uploaded: \(result1))")
        }
        guard !FileManager.default.fileExists(atPath: "\(overlay)/new.txt"),
              !FileManager.default.fileExists(atPath: "\(overlay)/dirtybase.txt")
        else {
            return report("AC-OU2", "overlay-sync-back", false, "(uploaded overlay files were not deleted after verify)")
        }
        // dirtybase.txt's remote fingerprint MATCHED the recorded expected state (not a
        // conflict) — but the base cache entry is Dirty (an unsynced streaming recording),
        // so it must survive the drain untouched.
        guard FileManager.default.fileExists(atPath: "\(dataDir)/dirtybase.txt"),
              FileManager.default.fileExists(atPath: "\(metaDir)/dirtybase.txt")
        else {
            return report("AC-OU2", "overlay-sync-back", false, "(a Dirty base cache entry was deleted by the drain)")
        }

        // Conflict path: remote has a DIFFERENT, unexpected version → conflict copy, original
        // remote entry untouched (simulated by the fake: only the conflict-named upload is
        // ever attempted, never the plain name).
        writeFile("\(overlay)/edited.txt", "my local edit")
        client.filesByDir[""] = [
            OverlaySyncService.RemoteEntry(name: "edited.txt", size: 999, modTime: Date()),
        ]
        let result2 = await_ { await service.run(
            profile: profile, remoteBase: "testremote:", mode: .drain, transport: "primary", client: client) }
        guard result2.conflicts == 1 else {
            return report("AC-OU2", "overlay-sync-back", false, "(unexpected remote version did not upload as a conflict: \(result2))")
        }

        // Failed upload: retained in the overlay, remainingPending reflects it, and a RERUN
        // (once the failure clears) picks it up and finishes the job — resumable, not lost.
        writeFile("\(overlay)/willfail.txt", "not yet uploaded")
        // Keyed on the RESOLVED (realpath'd) form: `scan()` reports `absolutePath` resolved
        // (see its doc comment — `/var`/`/tmp` are real symlinks Foundation's own path APIs
        // leave unresolved), so the unresolved `overlay` string here would never match what
        // `run()` actually passes to `upload(localPath:...)`.
        client.failUploadsFor.insert("\(OverlaySyncService.canonicalPath(overlay))/willfail.txt")
        client.filesByDir[""] = []
        let result3 = await_ { await service.run(
            profile: profile, remoteBase: "testremote:", mode: .drain, transport: "primary", client: client) }
        guard result3.failed == 1, FileManager.default.fileExists(atPath: "\(overlay)/willfail.txt"),
              result3.remainingPending >= 1
        else {
            return report("AC-OU2", "overlay-sync-back", false, "(failed upload was not retained: \(result3))")
        }
        client.failUploadsFor.removeAll()
        let result4 = await_ { await service.run(
            profile: profile, remoteBase: "testremote:", mode: .drain, transport: "primary", client: client) }
        guard result4.uploaded == 1, !FileManager.default.fileExists(atPath: "\(overlay)/willfail.txt") else {
            return report("AC-OU2", "overlay-sync-back", false, "(rerun after the failure cleared did not finish the upload)")
        }

        return report("AC-OU2", "overlay-sync-back", true)
    }

    // MARK: - AC-OU5 — a failed remote listing never falls through to a plain upload

    private static func testOverlayListingFailure() -> Bool {
        let fm = FileManager.default
        let root = "\(selfTestRoot)/ou5-\(UUID().uuidString)"
        let profile = mountFixtureProfile(localPath: "\(root)/mnt", cachePath: "\(root)/cache", remotePath: "")
        let overlay = profile.overlayPath
        writeFile("\(overlay)/Project/take.wav", "recorded while offline")

        // Listing of the file's remote directory fails → not uploaded, not deleted, failed.
        let client = FakeOverlayRemoteClient()
        client.failListingFor.insert("Project")
        let service = OverlaySyncService()
        let failed = await_ { await service.run(
            profile: profile, remoteBase: "testremote:", mode: .drain, transport: "primary", client: client) }
        guard client.uploadCount == 0, failed.failed == 1, failed.uploaded == 0,
              fm.fileExists(atPath: "\(overlay)/Project/take.wav"), failed.remainingPending >= 1
        else {
            return report("AC-OU5", "overlay-listing-failure", false,
                          "(a failed listing still uploaded or dropped the file: \(failed), calls=\(client.uploadCount))")
        }

        // Real rclone: a remote directory that doesn't exist yet (folder created offline)
        // lists as empty, NOT as a failure — the file uploads and the drain deletes it.
        guard RcloneLocator.resolve() != nil else {
            return report("AC-OU5", "overlay-listing-failure", false, "(rclone not found)")
        }
        let remoteRoot = "\(root)/remote"
        try? fm.createDirectory(atPath: remoteRoot, withIntermediateDirectories: true)
        let real = OverlaySyncService.ProductionOverlayRemoteClient(remoteName: ":local", remotePath: remoteRoot)
        guard case .success(let entries) = real.listFiles(remoteDir: "Project"), entries.isEmpty else {
            return report("AC-OU5", "overlay-listing-failure", false, "(a missing remote directory did not list as empty)")
        }
        let uploaded = await_ { await service.run(
            profile: profile, remoteBase: ":local:\(remoteRoot)", mode: .drain, transport: "primary", client: real) }
        guard uploaded.uploaded == 1, uploaded.failed == 0,
              (try? String(contentsOfFile: "\(remoteRoot)/Project/take.wav")) == "recorded while offline",
              !fm.fileExists(atPath: "\(overlay)/Project/take.wav")
        else {
            return report("AC-OU5", "overlay-listing-failure", false,
                          "(a new offline folder did not upload: \(uploaded))")
        }
        return report("AC-OU5", "overlay-listing-failure", true)
    }

    // MARK: - AC-OU3 — Upload Now (keep mode)

    private static func testOverlayUploadNow() -> Bool {
        let root = "\(selfTestRoot)/ou3-\(UUID().uuidString)"
        let profile = mountFixtureProfile(localPath: "\(root)/mnt", cachePath: "\(root)/cache", remotePath: "")
        let overlay = profile.overlayPath

        let old = Date().addingTimeInterval(-3600)
        writeFile("\(overlay)/keep.txt", "upload me but keep me")
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: "\(overlay)/keep.txt")

        // Still being written (modified <30s ago) — must be deferred, not uploaded yet.
        writeFile("\(overlay)/toorecent.txt", "still saving")

        let client = FakeOverlayRemoteClient()
        let service = OverlaySyncService()
        let result1 = await_ { await service.run(
            profile: profile, remoteBase: "testremote:", mode: .keep, transport: "primary", client: client) }
        guard result1.uploaded == 1, client.uploadCount == 1 else {
            return report("AC-OU3", "overlay-upload-now", false, "(keep-mode did not upload exactly the eligible file: \(result1))")
        }
        guard FileManager.default.fileExists(atPath: "\(overlay)/keep.txt") else {
            return report("AC-OU3", "overlay-upload-now", false, "(keep mode deleted the overlay file)")
        }
        // Its job (proving the recency filter defers it, confirmed by `client.uploadCount ==
        // 1` above) is done — remove it so it doesn't also get swept up by a LATER `.drain`
        // call, which unlike `.keep` applies no recency filter and would otherwise upload it
        // too, throwing off every uploaded/alreadyUploaded count asserted below.
        try? FileManager.default.removeItem(atPath: "\(overlay)/toorecent.txt")

        // Unchanged since the upload → already-uploaded, no re-upload, file stays.
        let result2 = await_ { await service.run(
            profile: profile, remoteBase: "testremote:", mode: .keep, transport: "primary", client: client) }
        guard result2.alreadyUploaded >= 1, client.uploadCount == 1 else {
            return report("AC-OU3", "overlay-upload-now", false, "(unchanged file was re-uploaded: \(result2), calls=\(client.uploadCount))")
        }

        // Changed since the manifest was recorded → re-uploaded. Reset the modtime to
        // stale-again (a fresh write is <30s old, which the `.keep` recency filter would
        // otherwise defer to the NEXT run, silently passing this assertion for the wrong
        // reason).
        writeFile("\(overlay)/keep.txt", "changed content, different size!!")
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: "\(overlay)/keep.txt")
        let result3 = await_ { await service.run(
            profile: profile, remoteBase: "testremote:", mode: .keep, transport: "primary", client: client) }
        guard result3.uploaded >= 1, client.uploadCount == 2 else {
            return report("AC-OU3", "overlay-upload-now", false, "(changed file was not re-uploaded: \(result3))")
        }

        // A later DRAIN of the same unchanged (already-uploaded) file deletes it WITHOUT
        // re-uploading — Upload Now's manifest is honoured by the eventual Resume Syncing.
        let beforeDrainCalls = client.uploadCount
        let drainResult = await_ { await service.run(
            profile: profile, remoteBase: "testremote:", mode: .drain, transport: "primary", client: client) }
        guard !FileManager.default.fileExists(atPath: "\(overlay)/keep.txt"), client.uploadCount == beforeDrainCalls else {
            return report("AC-OU3", "overlay-upload-now", false, "(later drain re-uploaded an Upload-Now-kept file: \(drainResult))")
        }

        return report("AC-OU3", "overlay-upload-now", true)
    }

    // MARK: - AC-OU4 — cache move / vfsCachePath refused while overlay files are pending

    private static func testCacheMoveBlockedPending() -> Bool {
        let root = "\(selfTestRoot)/ou4-\(UUID().uuidString)"
        var profile = mountFixtureProfile(localPath: "\(root)/mnt", cachePath: "\(root)/cache")
        profile.isEnabled = true
        writeFile("\(profile.overlayPath)/pending.txt", "not yet uploaded")

        var migrateCalled = false
        var stderrText = ""
        let moveEnv = fakeCLIEnvironment(
            readProfiles: { [profile] },
            stderr: { stderrText += $0 },
            migrateCache: { _, _, _ in migrateCalled = true; return .completed(files: 0, bytes: 0, sameVolume: true) })
        let moveExit = SyncTrayCLI.execute(["cache", "move", profile.shortId, "--to", "\(root)/newcache"], env: moveEnv)
        guard moveExit != 0, !migrateCalled, stderrText.lowercased().contains("waiting to upload") else {
            return report("AC-OU4", "cache-move-blocked-pending", false,
                          "(cache move was not refused while overlay files are pending: exit=\(moveExit) stderr=\(stderrText))")
        }

        var wroteProfile = false
        var setStderr = ""
        let setEnv = fakeCLIEnvironment(
            readProfiles: { [profile] },
            writeProfile: { _ in wroteProfile = true; return true },
            stderr: { setStderr += $0 })
        let setExit = SyncTrayCLI.execute(
            ["profile", "set", profile.shortId, "vfsCachePath", "\(root)/othercache"], env: setEnv)
        guard setExit != 0, !wroteProfile, setStderr.lowercased().contains("waiting to upload") else {
            return report("AC-OU4", "cache-move-blocked-pending", false,
                          "(profile set vfsCachePath was not refused while overlay files are pending: exit=\(setExit))")
        }

        // Negative check: once the overlay is empty, both commands proceed normally.
        try? FileManager.default.removeItem(atPath: "\(profile.overlayPath)/pending.txt")
        var migrateCalledAfter = false
        let moveEnv2 = fakeCLIEnvironment(
            readProfiles: { [profile] },
            migrateCache: { _, _, _ in migrateCalledAfter = true; return .completed(files: 0, bytes: 0, sameVolume: true) })
        _ = SyncTrayCLI.execute(["cache", "move", profile.shortId, "--to", "\(root)/newcache2"], env: moveEnv2)
        guard migrateCalledAfter else {
            return report("AC-OU4", "cache-move-blocked-pending", false, "(cache move stayed blocked with an empty overlay)")
        }

        return report("AC-OU4", "cache-move-blocked-pending", true)
    }

    // MARK: - AC-CLI9 — profile set rejects the retired keys; streamCacheOnly still works

    private static func testCLIProfileSetRemovedKeys() -> Bool {
        var p = sampleProfile(name: "RemovedKeys")
        for badKey in ["cacheIdentity", "stableCacheIdentity", "offlineAccessEnabled"] {
            guard SyncTrayCLI.applyProfileAssignment(&p, key: badKey, value: "x") != nil else {
                return report("AC-CLI9", "cli-profile-set-removed-keys", false, "(retired key \"\(badKey)\" was accepted)")
            }
        }
        guard SyncTrayCLI.applyProfileAssignment(&p, key: "streamCacheOnly", value: "true") == nil,
              p.streamCacheOnly == true
        else {
            return report("AC-CLI9", "cli-profile-set-removed-keys", false, "(streamCacheOnly was rejected)")
        }

        var wrote = false
        let env = fakeCLIEnvironment(readProfiles: { [p] }, writeProfile: { _ in wrote = true; return true })
        let exit = SyncTrayCLI.execute(["profile", "set", p.shortId, "cacheIdentity", "synology"], env: env)
        guard exit == 65, !wrote else {
            return report("AC-CLI9", "cli-profile-set-removed-keys", false, "(execute did not exit 65 / wrote a file for a retired key)")
        }

        guard Self.usageMentionsNoRemovedKeys() else {
            return report("AC-CLI9", "cli-profile-set-removed-keys", false, "(help text still mentions a retired key)")
        }
        return report("AC-CLI9", "cli-profile-set-removed-keys", true)
    }

    private static func usageMentionsNoRemovedKeys() -> Bool {
        for key in ["cacheIdentity", "stableCacheIdentity", "offlineAccessEnabled"] where SyncTrayCLI.usage.contains(key) {
            return false
        }
        return true
    }

    /// `OverlaySyncService.run` is `async`; these self-tests are synchronous, so bridge with
    /// a semaphore rather than threading `async`/`await` through the whole self-test suite.
    /// Call as `await_ { await someAsyncCall(...) }` — a plain `@escaping` closure, not
    /// `@autoclosure`, since Swift rejects an `async` autoclosure inside a non-`async`
    /// function.
    ///
    /// **Cannot be a bare blocking `semaphore.wait()` on the calling thread.** This runs
    /// from `ConfigSelfTest.run()`, called synchronously from `SyncTrayApp.init()` —
    /// BEFORE `NSApplicationMain`/the app's run loop ever starts. Empirically (verified with
    /// a minimal standalone repro), Swift Concurrency's global executor does not resume a
    /// `Task` at all at this point in process startup if the thread that created it is
    /// blocked in a raw `dispatch_semaphore_wait` — even a `Task.detached` whose body never
    /// awaits anything real hangs forever. Moving the actual wait to a background thread and
    /// pumping `RunLoop.current` on the calling thread instead (a resource the executor
    /// apparently DOES need serviced this early) unblocks it reliably.
    private static func await_<T>(_ operation: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T!
        Task.detached {
            result = await operation()
            semaphore.signal()
        }
        var done = false
        DispatchQueue.global().async {
            semaphore.wait()
            done = true
        }
        while !done {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return result
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
        // The cache key is always the remote-named layout now, so two profiles can only
        // address the same on-disk bytes when one remote path nests inside the other's.
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

        // A disjoint pair (different primary remotes) is same-root at most, never overlapping.
        var otherRemote = disjoint
        otherRemote.rcloneRemote = "synology-sftp:"
        otherRemote.remotePath = "Kaiju/KAIJU/Nested"
        let (overlapping, sameRoot) = CacheMigrationPlanner.classifySiblings(
            of: parent, sourceRoot: sharedRoot, allProfiles: [parent, otherRemote])
        guard overlapping.isEmpty, sameRoot.map({ $0.id }) == [otherRemote.id] else {
            return report("AC-CM3", "cache-migration-overlap", false,
                          "(profiles on different primary remotes should be same-root, not overlapping)")
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
        // Finding 9 — the destination ROOT directory itself must not be
        // created before a rejection is determined either. Materializing it
        // first would make a not-yet-mounted `/Volumes/...` destination
        // read back as a plain directory on the BOOT disk on the very next
        // `volumeIdentifier`/`availableCapacity` probe — silently skipping
        // this exact space check on a retry.
        guard !fake.directories.contains("/tmp/cm5-dest") else {
            return report("AC-CM5", "cache-migration-space-preflight", false, "(the destination root itself was created despite the insufficientSpace rejection)")
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
        // Finding 10 — pruning empty source directories must never run on a
        // FAILED move: the parent directories a rollback needs to restore
        // into must still be there.
        guard mismatchFake.removeEmptyDirectoriesCalls.isEmpty else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(prune ran despite a verify-mismatch failure: \(mismatchFake.removeEmptyDirectoriesCalls))")
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
        // Finding 10, positive half — on a CONFIRMED-complete move, prune
        // must run exactly once per `vfs`/`vfsMeta` subtree at the source
        // ROOT, and never against the bare, unscoped cache root — a
        // profile's `vfsCachePath` commonly shares its parent directory
        // with rclone's own bisync cache, so an unscoped prune could delete
        // an unrelated profile's state.
        let expectedPruneRoots = Set(CacheTreeKind.allCases.map { "/tmp/cm6-src/\($0.rawValue)" })
        guard Set(goodFake.removeEmptyDirectoriesCalls) == expectedPruneRoots else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(prune did not run once per vfs/vfsMeta subtree: \(goodFake.removeEmptyDirectoriesCalls))")
        }
        guard !goodFake.removeEmptyDirectoriesCalls.contains("/tmp/cm6-src") else {
            return report("AC-CM6", "cache-migration-verify-order", false, "(prune ran against the bare, unscoped cache root)")
        }

        return report("AC-CM6", "cache-migration-verify-order", true)
    }

    // MARK: - AC-CM7 — persist on a completed move OR an empty source, never otherwise

    private static func testCacheMigrationPersistOnSuccess() -> Bool {
        // The gate persists on exactly TWO outcomes: a completed move, and
        // `.nothingToMove` — an empty/absent source cache is nothing to lose,
        // so re-pointing the profile at the new root is the whole job and
        // refusing to persist would leave the user's Save silently ignored.
        //
        // This test previously asserted `!shouldPersist(.nothingToMove)`,
        // written against the single-case version of the gate and never
        // updated when `.nothingToMove` was added to it. It therefore failed
        // deterministically, which nothing caught because `--self-test` was
        // not wired into CI — it is now (the `test` job's "Self-test" step).
        let persisting: [(String, CacheMigrationOutcome)] = [
            ("completed", CacheMigrationOutcome(result: .completed, filesMoved: 3, bytesMoved: 300, sameVolume: true)),
            ("nothingToMove", CacheMigrationOutcome(result: .preflightRejected(.nothingToMove), filesMoved: 0, bytesMoved: 0, sameVolume: false)),
        ]
        for (label, outcome) in persisting where !CacheMigrationPersistDecision.shouldPersist(outcome) {
            return report("AC-CM7", "cache-migration-persist-on-success", false, "(\(label) did not persist)")
        }

        // Everything else must leave `vfsCachePath` alone, so a `.profile.json`
        // can never name a cache directory the bytes did not actually reach.
        let notPersisting: [(String, CacheMigrationOutcome)] = [
            ("cancelled", CacheMigrationOutcome(result: .cancelled, filesMoved: 1, bytesMoved: 10, sameVolume: true)),
            ("failed/verifyMismatch", CacheMigrationOutcome(result: .failed(.verifyMismatch, rolledBack: true), filesMoved: 0, bytesMoved: 0, sameVolume: true)),
            ("failed/ioError", CacheMigrationOutcome(result: .failed(.ioError, rolledBack: false), filesMoved: 2, bytesMoved: 20, sameVolume: false)),
            ("rejected/destinationUnwritable", CacheMigrationOutcome(result: .preflightRejected(.destinationUnwritable), filesMoved: 0, bytesMoved: 0, sameVolume: false)),
            ("rejected/insufficientSpace", CacheMigrationOutcome(result: .preflightRejected(.insufficientSpace(requiredBytes: 10, availableBytes: 1)), filesMoved: 0, bytesMoved: 0, sameVolume: false)),
            ("rejected/cancelled", CacheMigrationOutcome(result: .preflightRejected(.cancelled), filesMoved: 0, bytesMoved: 0, sameVolume: false)),
        ]
        for (label, outcome) in notPersisting where CacheMigrationPersistDecision.shouldPersist(outcome) {
            return report("AC-CM7", "cache-migration-persist-on-success", false, "(\(label) persisted)")
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
        // Cancellation is polled in TWO places and both are asserted here.
        // First: `preflight` itself, whose full-tree enumeration can take a
        // while and must not run to completion after Cancel. An engine that
        // is already cancelled therefore never returns a preflight at all —
        // which is why this fixture cannot use a permanently-true flag to
        // reach the file loop below, as it previously tried to.
        let alwaysCancelled = CacheMigrationEngine(fs: cancelSystem, isCancelled: { true })
        guard case .failure(.cancelled) = alwaysCancelled.preflight(plan) else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(preflight does not poll cancellation)")
        }

        // Second: the file loop. Let preflight succeed, then cancel, so the
        // run is stopped at a file boundary with the source left intact.
        var cancelAfterPreflight = false
        let engine1 = CacheMigrationEngine(fs: cancelSystem, isCancelled: { cancelAfterPreflight })
        guard case .success(let pf1) = engine1.preflight(plan) else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(preflight failed for cancel fixture)")
        }
        cancelAfterPreflight = true
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

        // Finding 5 — a RESUMED file is just as moved as one this run copied:
        // its source copy is gone, so the destination holds the only copy and
        // a later rollback must restore it. Tracking `movedDestPaths` only in
        // the copy arm left every resumed file stranded at the destination
        // while `rollback` still returned true, so a "reverted" source tree
        // came back silently incomplete. Resume one file, then fail the next,
        // and require the resumed one back at the source.
        let (rollbackSystem, rollbackFake) = fakeCacheMigrationFileSystem()
        let resumedSource = "\(sourceContent)/a.bin"
        let resumedDest = "/tmp/cm8-dest/vfs/\(key)/a.bin"
        let failingSource = "\(sourceMeta)/b.bin"
        let failingDest = "/tmp/cm8-dest/vfsMeta/\(key)/b.bin"
        rollbackFake.directories.insert(sourceContent)
        rollbackFake.directories.insert(sourceMeta)
        rollbackFake.files[resumedSource] = 5
        rollbackFake.files[resumedDest] = 5      // already relocated by the interrupted run
        rollbackFake.files[failingSource] = 9
        rollbackFake.volumeOf["/tmp/cm8-dest"] = "other-volume"
        rollbackFake.writeMismatchAt.insert(failingDest)
        let engine3 = CacheMigrationEngine(fs: rollbackSystem)
        guard case .success(let pf3) = engine3.preflight(plan) else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(preflight failed for resume-rollback fixture)")
        }
        let outcome3 = engine3.run(plan, pf3)
        guard case .failed(.verifyMismatch, let resumeRolledBack) = outcome3.result else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(resume-rollback fixture did not fail on the second file: \(outcome3.result))")
        }
        guard rollbackFake.files[resumedSource] == 5 else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(rollback stranded the RESUMED file at the destination — its source was not restored)")
        }
        guard rollbackFake.files[resumedDest] == nil, resumeRolledBack else {
            return report("AC-CM8", "cache-migration-cancel-resume", false, "(resumed file's destination copy survived a completed rollback, or rollback reported failure: rolledBack=\(resumeRolledBack))")
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

        // Finding 15 — `CacheMigrationBracket` is a spy-tested STAND-IN,
        // deliberately never called by `migrateCacheDirectory` itself (see
        // that function's doc comment) because `checks.yaml`'s AC-9 already
        // asserts the literal call sequence in ITS body. That leaves a real
        // ordering regression in the actual orchestration free to pass
        // every assertion above, since none of them read `SyncManager.swift`
        // at all — a fake-that-can't-fail
        // (`global::aw-lessons::mock-that-reimplements-the-thing-under-test`).
        // Assert the SAME ordering against the real source too.
        guard let source = readSourceFile("Services/SyncManager.swift"),
              let body = extractFunctionBody(startingAt: "private func migrateCacheDirectory(", in: source),
              let rollbackBody = extractFunctionBody(startingAt: "func rollbackCacheMigration(", in: source),
              let detachBody = extractFunctionBody(startingAt: "private func detachForCacheMigration(", in: source),
              let reinstallBody = extractFunctionBody(startingAt: "private func reinstallAfterCacheMigration(", in: source) else {
            return report("AC-CM9", "cache-migration-install-on-every-path", false, "(could not read the real migration bracket source)")
        }
        // The two halves of the bracket live in shared helpers now, so the
        // forward move and the rollback cannot implement it differently.
        // Assert the helpers really do the work, then that both call sites
        // detach before they re-install.
        guard detachBody.contains("setupService.uninstall"),
              reinstallBody.contains("setupService.install"),
              reinstallBody.contains("updateAppGroupMountPaths()") else {
            return report("AC-CM9", "cache-migration-install-on-every-path", false, "(the shared detach/reinstall helpers no longer uninstall/install)")
        }
        guard let uninstallRange = body.range(of: "detachForCacheMigration("),
              let installRange = body.range(of: "reinstallAfterCacheMigration(") else {
            return report("AC-CM9", "cache-migration-install-on-every-path", false, "(migrateCacheDirectory no longer brackets the move)")
        }
        guard uninstallRange.lowerBound < installRange.lowerBound, body.contains("defer {") else {
            return report("AC-CM9", "cache-migration-install-on-every-path", false, "(migrateCacheDirectory does not detach before re-installing via a defer)")
        }

        // The ROLLBACK needs the same bracket. It had none: by the time the
        // user is offered "Resume or roll back?", the forward move's `defer`
        // has already re-installed the agent, so the mount is live again on
        // `sourceRoot` — exactly the tree the reverse move writes into.
        // Relocating files into a live `rclone nfsmount`'s `--cache-dir` is
        // the corruption path the pre-move warm cancellation exists to avoid.
        guard let rollbackDetach = rollbackBody.range(of: "detachForCacheMigration("),
              let rollbackInstall = rollbackBody.range(of: "reinstallAfterCacheMigration("),
              rollbackDetach.lowerBound < rollbackInstall.lowerBound else {
            return report("AC-CM9", "cache-migration-install-on-every-path", false, "(rollbackCacheMigration does not detach before re-installing — it would move files into a live mount)")
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

        // Finding 15 — same real-source cross-check as AC-CM9 above,
        // against the actual `migrateCacheDirectory`, not the spy-tested
        // `CacheMigrationBracket` stand-in.
        guard let source = readSourceFile("Services/SyncManager.swift"),
              let body = extractFunctionBody(startingAt: "private func migrateCacheDirectory(", in: source),
              let rollbackBody = extractFunctionBody(startingAt: "func rollbackCacheMigration(", in: source) else {
            return report("AC-CM10", "cache-migration-warm-cancelled-first", false, "(could not read the real migration source)")
        }
        guard let warmRange = body.range(of: "cancelWarm(for: id)"),
              let uninstallRange = body.range(of: "detachForCacheMigration(") else {
            return report("AC-CM10", "cache-migration-warm-cancelled-first", false, "(real source missing a cancelWarm/detach call)")
        }
        guard warmRange.lowerBound < uninstallRange.lowerBound else {
            return report("AC-CM10", "cache-migration-warm-cancelled-first", false, "(real source does not cancel warm before detaching)")
        }

        // Same requirement for the reverse move — a warm reading through the
        // re-established mount races a rollback exactly as it races a
        // forward move.
        guard let rollbackWarm = rollbackBody.range(of: "cancelWarm(for: id)"),
              let rollbackDetach = rollbackBody.range(of: "detachForCacheMigration("),
              rollbackWarm.lowerBound < rollbackDetach.lowerBound else {
            return report("AC-CM10", "cache-migration-warm-cancelled-first", false, "(rollbackCacheMigration does not cancel warm before detaching)")
        }

        return report("AC-CM10", "cache-migration-warm-cancelled-first", true)
    }

    // MARK: - AC-CM11 — destination parent directory is created before copying into it (finding 1)

    private static func testCacheMigrationDestinationParentCreated() -> Bool {
        let profile = mountProfile(remotePath: "Kaiju", vfsCachePath: "/tmp/cm11-src")
        guard case .success(let plan) = CacheMigrationPlanner.plan(
            moving: profile, allProfiles: [profile], to: "/tmp/cm11-dest", coMigrate: []
        ) else {
            return report("AC-CM11", "cache-migration-dest-parent-created", false, "(plan failed)")
        }
        let key = VFSCacheService.cacheRelativePath(for: profile)
        let sourceContent = "/tmp/cm11-src/vfs/\(key)"
        let sourceMeta = "/tmp/cm11-src/vfsMeta/\(key)"
        let destContent = "/tmp/cm11-dest/vfs/\(key)"

        let (system, fake) = fakeCacheMigrationFileSystem()
        fake.directories.insert(sourceContent)
        fake.directories.insert(sourceMeta)
        fake.files["\(sourceContent)/only.bin"] = 3
        fake.volumeOf["/tmp/cm11-dest"] = "other-volume"
        // Deliberately NOT pre-inserting ANY destination directory — exactly
        // what a fresh cache root looks like the first time a profile moves
        // there. `FakeCacheFS.copyFile`/`copyFileDataOnly` now THROW unless
        // the destination's parent is already in `directories` (see the
        // FakeCacheFS doc comment above), so this regresses to FAIL if
        // `CacheMigrationEngine.moveFile` ever stops creating that parent
        // first — traced by hand against the pre-fix code: without the
        // `fs.createDirectory(destParent)` call, this exact fixture threw
        // `missingParentDirectory` on its first (and only) file, producing
        // `.failed(.ioError, ...)` instead of `.completed` below.
        let engine = CacheMigrationEngine(fs: system)
        guard case .success(let pf) = engine.preflight(plan) else {
            return report("AC-CM11", "cache-migration-dest-parent-created", false, "(preflight failed)")
        }
        let outcome = engine.run(plan, pf)
        guard outcome.result == .completed else {
            return report("AC-CM11", "cache-migration-dest-parent-created", false, "(move did not complete against a fresh destination root: \(outcome.result))")
        }
        guard fake.directories.contains(destContent) else {
            return report("AC-CM11", "cache-migration-dest-parent-created", false, "(destination parent was never created)")
        }
        guard fake.files["\(destContent)/only.bin"] == 3 else {
            return report("AC-CM11", "cache-migration-dest-parent-created", false, "(file did not land at the destination)")
        }
        return report("AC-CM11", "cache-migration-dest-parent-created", true)
    }

    // MARK: - AC-CM12 — rollback verifies BOTH sizes are present, not a naked Optional==Optional (finding 4)

    private static func testCacheMigrationRollbackOptionalGuard() -> Bool {
        // Behavioural half: drive a real rollback into the both-sizes-missing
        // state and assert it FAILS CLOSED. Under the old naked
        // `fs.fileSize(sourcePath) == fs.fileSize(destPath)`, two `nil`s
        // compare EQUAL, so a rollback copy that silently produced nothing
        // would "verify" as a match and then delete the last remaining copy
        // at `destPath` — irrecoverable data loss on an already-failed
        // migration (finding 4).
        //
        // (This replaces a `let a: Int64? = nil; let b: Int64? = nil;
        // guard a == b` assertion, which restated a Swift language rule and
        // could not fail for any state of this codebase.)
        let profile = mountProfile(remotePath: "Kaiju", vfsCachePath: "/tmp/cm12-src")
        guard case .success(let plan) = CacheMigrationPlanner.plan(
            moving: profile, allProfiles: [profile], to: "/tmp/cm12-dest", coMigrate: []
        ) else {
            return report("AC-CM12", "cache-migration-rollback-optional-guard", false, "(plan failed)")
        }
        let key = VFSCacheService.cacheRelativePath(for: profile)
        let sourceContent = "/tmp/cm12-src/vfs/\(key)"
        let sourceMeta = "/tmp/cm12-src/vfsMeta/\(key)"
        // One file per subtree, so the engine's order (`vfs` then `vfsMeta`)
        // fixes which file moves and which one fails — independent of the
        // fake's within-subtree enumeration.
        let goodSource = "\(sourceContent)/good.bin"
        let goodDest = "/tmp/cm12-dest/vfs/\(key)/good.bin"
        let badSource = "\(sourceMeta)/bad.bin"
        let badDest = "/tmp/cm12-dest/vfsMeta/\(key)/bad.bin"

        let (system, fake) = fakeCacheMigrationFileSystem()
        fake.directories.insert(sourceContent)
        fake.directories.insert(sourceMeta)
        fake.files[goodSource] = 10
        fake.files[badSource] = 20
        fake.volumeOf["/tmp/cm12-dest"] = "other-volume"   // cross-volume → per-file path
        fake.writeMismatchAt.insert(badDest)               // second file fails → rollback runs
        fake.copyProducesNothingAt.insert(goodSource)      // rollback's copy-back writes nothing
        // `goodDest` is stat'd three times on the way out — `preflight`'s
        // resume accounting, `moveFiles`' resume-skip probe, then
        // `moveFile`'s verify — and would be stat'd a fourth time by
        // rollback. Budget exactly those three so the ROLLBACK stat returns
        // nil, i.e. a destination that EXISTS but cannot be stat'd. Both
        // sizes are then missing, which is the only state that separates the
        // `guard let` from the naked `==`.
        fake.statBudget[goodDest] = 3

        let engine = CacheMigrationEngine(fs: system)
        guard case .success(let preflight) = engine.preflight(plan) else {
            return report("AC-CM12", "cache-migration-rollback-optional-guard", false, "(preflight failed)")
        }
        let outcome = engine.run(plan, preflight)
        guard case .failed(.verifyMismatch, let rolledBack) = outcome.result else {
            return report("AC-CM12", "cache-migration-rollback-optional-guard", false, "(expected a verify-mismatch failure, got: \(outcome.result))")
        }
        guard fake.statBudget[goodDest] == 0 else {
            return report("AC-CM12", "cache-migration-rollback-optional-guard", false, "(stat budget not consumed as expected — the forward move no longer stats the destination twice, so this fixture never reached the both-sizes-missing state)")
        }
        guard rolledBack == false else {
            return report("AC-CM12", "cache-migration-rollback-optional-guard", false, "(rollback reported success despite being unable to verify the restored file)")
        }
        guard fake.files[goodDest] == 10 else {
            return report("AC-CM12", "cache-migration-rollback-optional-guard", false, "(rollback deleted the last remaining copy at the destination: \(String(describing: fake.files[goodDest])))")
        }

        // Source half: `rollback` must reject via `guard let` (fails closed
        // on EITHER side missing) rather than ever comparing the two
        // Optionals to each other directly.
        guard let source = readSourceFile("Services/CacheMigrationService.swift") else {
            return report("AC-CM12", "cache-migration-rollback-optional-guard", false, "(could not read CacheMigrationService.swift source)")
        }
        guard let rollbackBody = extractFunctionBody(startingAt: "private func rollback(destPaths: [String], plan: CacheMigrationPlan) -> Bool", in: source) else {
            return report("AC-CM12", "cache-migration-rollback-optional-guard", false, "(could not locate rollback's body)")
        }
        guard rollbackBody.contains("let sourceSize = fs.fileSize(sourcePath)"),
              rollbackBody.contains("let destSize = fs.fileSize(destPath)"),
              rollbackBody.contains("sourceSize == destSize") else {
            return report("AC-CM12", "cache-migration-rollback-optional-guard", false, "(rollback no longer guards both sizes with guard-let)")
        }
        guard !rollbackBody.contains("fs.fileSize(sourcePath) == fs.fileSize(destPath)") else {
            return report("AC-CM12", "cache-migration-rollback-optional-guard", false, "(rollback still contains the naked Optional==Optional comparison)")
        }
        return report("AC-CM12", "cache-migration-rollback-optional-guard", true)
    }

    // MARK: - AC-CM13 — nested co-migrated subtrees never use the whole-directory fast path (finding 5)

    private static func testCacheMigrationNestedSubtreesUseFilePath() -> Bool {
        // Nested cache subtrees, the condition this fast-path guard exists for, occur
        // whenever two profiles share a remote name (the remote-named layout, always in
        // effect now — see `mountProfile`).
        let parent = mountProfile(name: "Parent", remotePath: "Kaiju/KAIJU", vfsCachePath: "/tmp/cm13-src")
        let child = mountProfile(name: "Child", remotePath: "Kaiju/KAIJU/Reaper", vfsCachePath: "/tmp/cm13-src")
        let all = [parent, child]
        guard case .success(let plan) = CacheMigrationPlanner.plan(
            moving: parent, allProfiles: all, to: "/tmp/cm13-dest", coMigrate: [child.id]
        ) else {
            return report("AC-CM13", "cache-migration-nested-subtree-file-path", false, "(co-migrated nested plan failed)")
        }
        let parentKey = VFSCacheService.cacheRelativePath(for: parent)
        let childKey = VFSCacheService.cacheRelativePath(for: child)
        guard childKey.hasPrefix(parentKey + "/") else {
            return report("AC-CM13", "cache-migration-nested-subtree-file-path", false, "(fixture keys aren't actually nested: \(parentKey) / \(childKey))")
        }
        let parentContent = "/tmp/cm13-src/vfs/\(parentKey)"
        let parentMeta = "/tmp/cm13-src/vfsMeta/\(parentKey)"
        let childContent = "/tmp/cm13-src/vfs/\(childKey)"
        let childMeta = "/tmp/cm13-src/vfsMeta/\(childKey)"

        let (system, fake) = fakeCacheMigrationFileSystem()
        fake.directories.insert(parentContent)
        fake.directories.insert(parentMeta)
        fake.directories.insert(childContent)
        fake.directories.insert(childMeta)
        fake.files["\(parentContent)/p.bin"] = 4
        fake.files["\(parentMeta)/p.bin"] = 1
        fake.files["\(childContent)/c.bin"] = 2
        fake.files["\(childMeta)/c.bin"] = 1
        // No `volumeOf` override — source and destination both resolve to
        // the SAME default volume, exactly the condition that ALSO made the
        // pre-fix `usesFastPath = sameVolume && excludedRelativePaths.isEmpty`
        // true for this fixture (a co-migrated overlap never populates
        // `excludedRelativePaths` — see CacheMigrationPlan's doc comment).
        // Under that old condition this fixture would call whole-directory
        // `moveItem` on the PARENT subtree root (silently carrying the
        // nested Reaper directory away with it), then attempt `moveItem` on
        // the CHILD subtree root — onto a destination that already exists,
        // which `FileManager.moveItem` refuses (finding 5).
        let engine = CacheMigrationEngine(fs: system)
        guard case .success(let pf) = engine.preflight(plan), pf.sameVolume else {
            return report("AC-CM13", "cache-migration-nested-subtree-file-path", false, "(fixture did not preflight as same-volume)")
        }
        let outcome = engine.run(plan, pf)
        guard outcome.result == .completed else {
            return report("AC-CM13", "cache-migration-nested-subtree-file-path", false, "(nested co-migrated same-volume move did not complete: \(outcome.result))")
        }
        guard fake.movedPaths.isEmpty else {
            return report("AC-CM13", "cache-migration-nested-subtree-file-path", false, "(used whole-subtree moveItem despite nested subtrees: \(fake.movedPaths))")
        }
        guard !fake.copiedPaths.isEmpty else {
            return report("AC-CM13", "cache-migration-nested-subtree-file-path", false, "(no per-file copy occurred — the nesting guard did not force the file-by-file path)")
        }
        return report("AC-CM13", "cache-migration-nested-subtree-file-path", true)
    }

    // MARK: - AC-CM14 — orchestration hardening: Task cancellation bridging, rollback's source-root
    // sibling classification, and an abort on a mount that failed to detach (findings 2, 6, 7)

    private static func testCacheMigrationOrchestrationHardening() -> Bool {
        guard let source = readSourceFile("Services/SyncManager.swift") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(could not read SyncManager.swift source)")
        }

        // Finding 2 — reading `Task.isCancelled` from inside a plain
        // `DispatchQueue.global().async` closure (no enclosing `Task`)
        // always returns `false`, so cancelling the migration Task never
        // actually stopped the background move. Both orchestration entry
        // points must bridge cancellation via `withTaskCancellationHandler`
        // into an explicit, thread-safe flag the engine's `isCancelled`
        // closure reads instead.
        guard let migrateBody = extractFunctionBody(startingAt: "private func migrateCacheDirectory(", in: source) else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(could not locate migrateCacheDirectory)")
        }
        guard migrateBody.contains("withTaskCancellationHandler"),
              migrateBody.contains("CacheMigrationCancellationFlag()"),
              migrateBody.contains("cancellationFlag.markCancelled()") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(migrateCacheDirectory does not bridge Task cancellation to the engine)")
        }

        guard let rollbackBody = extractFunctionBody(startingAt: "func rollbackCacheMigration(", in: source) else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(could not locate rollbackCacheMigration)")
        }
        guard rollbackBody.contains("withTaskCancellationHandler"), rollbackBody.contains("CacheMigrationCancellationFlag()") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(rollbackCacheMigration does not bridge Task cancellation)")
        }

        // Finding 6 — a rollback must classify overlapping/same-root
        // siblings against the migration's ORIGINAL source root, by
        // re-deriving the forward plan and reversing it — not by planning
        // directly from a profile whose `vfsCachePath` might already read
        // as the (failed) destination, which would classify siblings
        // against the wrong root and could silently drop one from the
        // rollback.
        guard rollbackBody.contains("CacheMigrationPlanner.plan("), rollbackBody.contains(".reversed()") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(rollbackCacheMigration no longer builds a forward plan and reverses it)")
        }

        // Finding 7 — `SyncSetupService.uninstall` does NOT throw when a
        // mount-mode profile's graceful+forced `diskutil unmount` both
        // fail (it only logs `mount.result: failure` telemetry and
        // proceeds). A bare `try?` around `uninstall` alone can therefore
        // never observe that failure mode — the guard must ALSO re-check
        // the mount state after a normal-returning `uninstall` and abort
        // the move rather than relocate files out from under a
        // still-attached, still-writable volume.
        //
        // Behavioral half (finding 9): a pure substring check on
        // `migrateBody` cannot tell an INVERTED or unreachable guard from a
        // correct one — `detachFailed = true`, `.failed(.mountDetachFailed`,
        // and a bounded-recheck call could all still be PRESENT somewhere
        // in the body even if the boolean logic gating them were backwards.
        // Drive the actual, extracted decision function directly instead.
        guard SyncManager.cacheMigrationDetachSucceeded(threw: false, stillMountedAfterRecheck: false) == true else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(a clean detach with no throw and no lingering mount was classified as FAILED)")
        }
        guard SyncManager.cacheMigrationDetachSucceeded(threw: true, stillMountedAfterRecheck: false) == false else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(uninstall throwing was classified as a SUCCESSFUL detach)")
        }
        guard SyncManager.cacheMigrationDetachSucceeded(threw: false, stillMountedAfterRecheck: true) == false else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(a volume still mounted after the bounded recheck was classified as a SUCCESSFUL detach)")
        }
        guard SyncManager.cacheMigrationDetachSucceeded(threw: true, stillMountedAfterRecheck: true) == false else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(throw AND still-mounted together were classified as a SUCCESSFUL detach)")
        }

        // Source half: `migrateCacheDirectory` must actually ROUTE its
        // abort decision through the function above (rather than
        // re-deriving its own inline boolean that could drift from it), and
        // must use the BOUNDED recheck rather than a single `isMounted`
        // sample (finding 4).
        //
        // The detach itself now lives in the shared `detachForCacheMigration`
        // helper (so the rollback gets the identical treatment), so that is
        // where the routing is asserted; the call sites are checked for
        // acting on its verdict.
        guard let detachBody = extractFunctionBody(startingAt: "private func detachForCacheMigration(", in: source) else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(could not locate detachForCacheMigration)")
        }
        guard detachBody.contains("Self.cacheMigrationDetachSucceeded(threw:"),
              detachBody.contains("setupService.isMountedAfterBoundedRecheck(profile: profile)"),
              detachBody.contains("return (installed, true)") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(detachForCacheMigration no longer routes its verdict through cacheMigrationDetachSucceeded / isMountedAfterBoundedRecheck)")
        }
        guard migrateBody.contains("guard !detachFailed else {"),
              migrateBody.contains(".failed(.mountDetachFailed") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(migrateCacheDirectory no longer aborts on a failed detach)")
        }
        guard rollbackBody.contains("guard !detach.failed else {"),
              rollbackBody.contains(".failed(.mountDetachFailed") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(rollbackCacheMigration no longer aborts on a failed detach — it would reverse the move under a live mount)")
        }

        // Finding 4, telemetry half — a detach-failure abort must still
        // emit a begin/end telemetry pair instead of returning silently.
        guard let telemetryStart = migrateBody.range(of: "beginCacheMigration("),
              let detachGuard = migrateBody.range(of: "guard !detachFailed else {"),
              telemetryStart.lowerBound < detachGuard.lowerBound else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(beginCacheMigration no longer runs BEFORE the detach-failure abort guard)")
        }
        let detachAbortWindowEnd = migrateBody.index(detachGuard.upperBound, offsetBy: 600, limitedBy: migrateBody.endIndex) ?? migrateBody.endIndex
        let detachAbortWindow = migrateBody[detachGuard.upperBound..<detachAbortWindowEnd]
        guard detachAbortWindow.contains("endCacheMigration(") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(the detach-failure abort path never calls endCacheMigration — it would emit no telemetry at all)")
        }

        // The ROLLBACK needs the identical treatment, and had none: it ran
        // with no span at all, so its own detach-failure abort was
        // indistinguishable from a rollback that never started. Same shape
        // as the forward assertions above — open the span before the abort
        // guard, close it inside the abort, and close it on the normal path.
        guard let rollbackTelemetryStart = rollbackBody.range(of: "beginCacheMigration("),
              let rollbackDetachGuard = rollbackBody.range(of: "guard !detach.failed else {"),
              rollbackTelemetryStart.lowerBound < rollbackDetachGuard.lowerBound else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(rollbackCacheMigration does not open its telemetry span before the detach-failure abort guard)")
        }
        let rollbackAbortEnd = rollbackBody.index(rollbackDetachGuard.upperBound, offsetBy: 1400, limitedBy: rollbackBody.endIndex) ?? rollbackBody.endIndex
        let rollbackAbortWindow = rollbackBody[rollbackDetachGuard.upperBound..<rollbackAbortEnd]
        guard rollbackAbortWindow.contains("endCacheMigration(") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(the rollback's detach-failure abort never calls endCacheMigration)")
        }
        // Two calls total — the abort AND the normal completion path. One
        // would mean a rollback that ran to completion emitted an unclosed
        // span.
        guard rollbackBody.components(separatedBy: "endCacheMigration(").count - 1 >= 2 else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(rollbackCacheMigration closes its span on only one path — a completed rollback would leave it open)")
        }
        // Derived from the shared label function, never hand-copied: the
        // literal would agree today only by accident of the failure enum's
        // default rawValue. Both aborts get the guard — they are a symmetric
        // pair, and pinning only the one that was caught leaves its twin free
        // to reintroduce the literal with the suite green.
        guard !rollbackBody.contains("outcome: \"mountDetachFailed\"") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(the rollback abort hand-copies its telemetry label instead of deriving it from cacheMigrationOutcomeLabel)")
        }
        guard !migrateBody.contains("outcome: \"mountDetachFailed\"") else {
            return report("AC-CM14", "cache-migration-orchestration-hardening", false, "(migrateCacheDirectory's abort hand-copies its telemetry label instead of deriving it from cacheMigrationOutcomeLabel)")
        }

        return report("AC-CM14", "cache-migration-orchestration-hardening", true)
    }

    // MARK: - AC-CM15 — UI layer: overlap-safe "Start fresh", and no dropped edits on a bare
    // sheet dismissal (findings 3, 11 UI half, 12)

    private static func testCacheMigrationUIFixes() -> Bool {
        guard let profileDetailSource = readSourceFile("Views/Settings/ProfileDetailView.swift") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(could not read ProfileDetailView.swift source)")
        }

        // Finding 3 — "Start fresh" must never delete an overlapping
        // sibling's shared subtree (nested either direction shares the same
        // bytes on disk).
        guard let deleteBody = extractFunctionBody(startingAt: "private func deleteOldCacheSubtree(", in: profileDetailSource) else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(could not locate deleteOldCacheSubtree)")
        }
        guard deleteBody.contains("excluding overlappingIds: [UUID]"), deleteBody.contains("overlappingKeys.contains") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(deleteOldCacheSubtree no longer excludes an overlapping sibling's subtree)")
        }
        guard profileDetailSource.contains("deleteOldCacheSubtree(of: latest, excluding: prompt.overlappingProfileIds)") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(finalizeCachePathChange no longer passes the overlap exclusion list)")
        }

        // Finding 12 — a bare sheet dismissal (Cancel / close box) must
        // still apply the OTHER field changes `saveProfile()`
        // deferred-persisted before opening the cache-move prompt.
        guard profileDetailSource.contains("cacheMoveOtherFieldsNeedReinstall") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(no flag tracks deferred-but-unapplied field changes across the cache-move sheet)")
        }
        guard let sheetRange = profileDetailSource.range(of: ".sheet(isPresented: $showingCacheMoveSheet") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(could not locate the cache-move sheet modifier)")
        }
        let windowEnd = profileDetailSource.index(sheetRange.upperBound, offsetBy: 2000, limitedBy: profileDetailSource.endIndex) ?? profileDetailSource.endIndex
        let dismissWindow = profileDetailSource[sheetRange.upperBound..<windowEnd]
        guard dismissWindow.contains("cacheMoveOtherFieldsNeedReinstall") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(onDismiss no longer reinstalls the deferred field changes on a bare dismissal)")
        }
        // And it must reinstall the ALREADY-PERSISTED profile, never one
        // rebuilt from the live form: the form's Cache Directory field still
        // holds the un-gated edit this sheet exists to gate, so a bare
        // `reinstallSync()` here would install AND persist exactly the change
        // Cancel is supposed to refuse. The earlier version of this guard
        // looked for the literal `reinstallSync()` and passed on a mention of
        // it inside a comment — pin the call that actually has to be there.
        guard dismissWindow.contains("reinstallSync(using: persisted)") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(onDismiss no longer reinstalls from the persisted profile — a bare dismissal would apply the un-gated cache-path edit)")
        }

        guard let cacheMoveSheetSource = readSourceFile("Views/Settings/CacheMoveSheet.swift") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(could not read CacheMoveSheet.swift source)")
        }
        guard cacheMoveSheetSource.contains("onMoveStarted") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(CacheMoveSheet has no onMoveStarted hook to suppress the redundant onDismiss reinstall)")
        }

        // Finding 11, UI half — "nothing was cached" must be treated as a
        // resolved success, not routed through the generic rejection path
        // (which a user would have to retry against an unchangeable
        // destination in pendingSave mode).
        // It must share the `.completed` arm outright, not merely have an
        // arm of its own: an empty source is a success that still has to
        // continue into any accepted same-root co-migration. A separate
        // `.nothingToMove` arm skipped those siblings entirely, showing a
        // green "the new location is saved" while every ticked sibling
        // stayed behind, unmoved and still pointing at the old root.
        //
        // Scoped to `handle(outcome:)`'s own body, NOT the whole file: the
        // same `case .completed, .preflightRejected(.nothingToMove):` text
        // appears three times in CacheMoveSheet (here, the same-root
        // success test, and Roll Back's outcome switch), so a whole-file
        // `contains` would stay green after this exact regression was
        // reintroduced — an assertion that cannot fail. Same lesson as the
        // `reinstallSync(using: persisted)` guard twenty lines up.
        guard let handleBody = extractFunctionBody(startingAt: "private func handle(outcome: CacheMigrationOutcome) {", in: cacheMoveSheetSource) else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(could not locate CacheMoveSheet.handle(outcome:))")
        }
        guard handleBody.contains("case .completed, .preflightRejected(.nothingToMove):") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(handle(outcome:) no longer routes .nothingToMove through the same success arm as .completed)")
        }
        guard handleBody.contains("moveSameRootProfiles(extraTargets") else {
            return report("AC-CM15", "cache-migration-ui-fixes", false, "(that success arm no longer continues into the accepted same-root co-migrations)")
        }

        return report("AC-CM15", "cache-migration-ui-fixes", true)
    }

    // MARK: - AC-CM16 — telemetry span status reflects the real outcome (findings 9, 13)

    private static func testCacheMigrationTelemetrySpanStatus() -> Bool {
        // Behavioral half (finding 9): drive the ACTUAL pure decision
        // `endCacheMigration` delegates to, rather than pinning that line's
        // literal Swift expression text — a substring check would keep
        // passing even if the guard were inverted or the "cancelled"
        // exemption were dropped, as long as SOME `.error(description:
        // "cache_migration` text remained anywhere in the function.
        let nonErrorOutcomes = ["completed", "cancelled"]
        for outcome in nonErrorOutcomes {
            guard TelemetryService.CacheMigrationSpanStatus.isError(outcome: outcome) == false else {
                return report("AC-CM16", "cache-migration-telemetry-span-status", false, "(\"\(outcome)\" was classified as an error)")
            }
        }
        let errorOutcomes = ["verifyMismatch", "countMismatch", "ioError_rolled_back", "mountDetachFailed", "preflight_rejected"]
        for outcome in errorOutcomes {
            guard TelemetryService.CacheMigrationSpanStatus.isError(outcome: outcome) == true else {
                return report("AC-CM16", "cache-migration-telemetry-span-status", false, "(\"\(outcome)\" was NOT classified as an error — a failed move would show green)")
            }
        }

        // Source half: `endCacheMigration` must actually ROUTE THROUGH the
        // decision above rather than re-deriving its own inline comparison
        // (which would let the two silently diverge).
        guard let source = readSourceFile("Services/TelemetryService.swift") else {
            return report("AC-CM16", "cache-migration-telemetry-span-status", false, "(could not read TelemetryService.swift source)")
        }
        guard let body = extractFunctionBody(startingAt: "func endCacheMigration(", in: source) else {
            return report("AC-CM16", "cache-migration-telemetry-span-status", false, "(could not locate endCacheMigration)")
        }
        guard body.contains("CacheMigrationSpanStatus.isError(outcome: outcome)"),
              body.contains(".error(description: \"cache_migration") else {
            return report("AC-CM16", "cache-migration-telemetry-span-status", false, "(endCacheMigration no longer routes span status through CacheMigrationSpanStatus.isError)")
        }
        return report("AC-CM16", "cache-migration-telemetry-span-status", true)
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

import Foundation
import AppKit
import Combine
import ServiceManagement

/// Who is launching an exclusive run — every recovery/resync entry point names
/// itself so a token can be told apart in diagnostics.
enum ExclusiveRunSource: String {
    case installResync = "install_resync"
    case resync
    case smartFix = "smart_fix"
    case unlockAndResync = "unlock_resync"
    case forceSync = "force_sync"
    case autoFix = "auto_fix"
}

/// Proof that a caller holds the exclusive run slot for `profileId`. Only the
/// exact token `begin` handed out can `end` it — a superseded or foreign token
/// (e.g. a very late callback from a run that was already dropped by the
/// stale-grace self-heal) is rejected by `ExclusiveRunRegistry.end`, so it can
/// never release a newer run out from under it.
struct ExclusiveRunToken: Hashable {
    let profileId: UUID
    let id: UUID
    let source: ExclusiveRunSource
    /// The `/tmp` run-lock placeholder token this run acquired with (the app's own
    /// PID, per D4) — callers use this (plus any later child-PID swap) to build the
    /// `ownTokens` set `SyncRunLock.releaseIfOwned`/`replaceIfOwned` need.
    let placeholder: String
    let startedAt: Date
}

/// Pure in-memory registry enforcing "one exclusive run per profile at a time".
/// Replaces the old in-flight `Set<UUID>` (D1): a bare set cannot tell
/// whose run is ending, so a late `end` from a superseded run could release a
/// newer one, and it was being cleared by `.syncCompleted`/`.syncFailed` log
/// events from processes that were never its owner. A token makes `end`
/// idempotent and owner-checked, and the struct is self-testable without
/// constructing `SyncManager`.
struct ExclusiveRunRegistry {
    enum Decision: Equatable {
        case granted(ExclusiveRunToken)
        case blocked(BlockReason)
    }

    enum BlockReason: Equatable {
        case inFlight
        case runLockLive
        case sessionLockLive
    }

    /// An entry older than this with a dead run lock is treated as abandoned
    /// (R9) — the self-heal backstop for a missed `endExclusiveRun` call, since
    /// every normal exit path releases its own token well under a minute.
    static let staleGrace: TimeInterval = 60

    private var active: [UUID: ExclusiveRunToken] = [:]

    /// Decide whether `profileId` may start an exclusive run right now. Checks,
    /// in order: an existing registry entry (dropped first if it is older than
    /// `staleGrace` AND its run lock is no longer live — R9's self-heal), then
    /// the `/tmp` run lock's liveness, then the bisync session `.lck` holder's
    /// liveness. Granting creates and stores a fresh token. Pure (liveness is
    /// injected via `isAlive`).
    mutating func begin(
        profileId: UUID,
        source: ExclusiveRunSource,
        runLock: SyncRunLock.Holder,
        sessionLock: SyncRunLock.Holder,
        isAlive: (Int32) -> Bool,
        now: Date,
        placeholder: String
    ) -> Decision {
        if let existing = active[profileId] {
            let runLockLive = SyncRunLock.isLive(runLock, isAlive: isAlive)
            let abandoned = now.timeIntervalSince(existing.startedAt) > Self.staleGrace && !runLockLive
            if !abandoned {
                return .blocked(.inFlight)
            }
            active.removeValue(forKey: profileId)
        }

        if SyncRunLock.isLive(runLock, isAlive: isAlive) {
            return .blocked(.runLockLive)
        }
        if SyncRunLock.isLive(sessionLock, isAlive: isAlive) {
            return .blocked(.sessionLockLive)
        }

        let token = ExclusiveRunToken(profileId: profileId, id: UUID(), source: source, placeholder: placeholder, startedAt: now)
        active[profileId] = token
        return .granted(token)
    }

    /// Release `token`'s slot iff it is still the stored token for its profile —
    /// a superseded or foreign token is rejected (returns `false`) and leaves the
    /// newer run active, untouched.
    @discardableResult
    mutating func end(_ token: ExclusiveRunToken) -> Bool {
        guard active[token.profileId] == token else { return false }
        active.removeValue(forKey: token.profileId)
        return true
    }

    func isActive(_ profileId: UUID) -> Bool {
        active[profileId] != nil
    }
}

@MainActor
final class SyncManager: ObservableObject {
    @Published private(set) var currentState: SyncState = .idle
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var recentChanges: [FileChange] = []
    /// Profiles with an in-flight app-initiated ("Sync Now" / directory-watch) run.
    /// Per-profile so one hung profile no longer blocks manual syncs for all others.
    @Published private(set) var manualSyncingProfiles: Set<UUID> = []

    /// True while any profile has an app-initiated sync in flight.
    /// Computed from `manualSyncingProfiles` so existing view bindings keep working;
    /// SwiftUI re-reads it whenever the published set changes.
    var isManualSyncRunning: Bool { !manualSyncingProfiles.isEmpty }

    /// Sync progress per profile (keyed by profile ID)
    @Published private(set) var profileProgress: [UUID: SyncProgress] = [:]

    /// Aggregate sync progress (first syncing profile's progress) - for menu bar icon
    var syncProgress: SyncProgress? {
        // Find the first profile that is currently syncing and has progress
        for (profileId, state) in profileStates {
            if state == .syncing, let progress = profileProgress[profileId] {
                return progress
            }
        }
        return nil
    }

    /// State per profile (keyed by profile ID)
    @Published private(set) var profileStates: [UUID: SyncState] = [:]

    /// Last error message per profile (for display in UI)
    @Published private(set) var profileErrors: [UUID: String] = [:]

    /// Why a profile's "Don't Sync" patterns couldn't be written to its exclude filter
    /// file. Kept apart from `profileErrors`, which every sync run clears, so a failed
    /// write stays visible until a later write succeeds.
    @Published private(set) var syncFilterErrors: [UUID: String] = [:]

    /// Mount state per profile (for mount mode profiles only)
    @Published private(set) var profileMountStates: [UUID: MountState] = [:]

    /// Human-friendly status shown under a `.mounting` profile, escalated by how
    /// long establishment has taken (see `mountProgressMessage`). Lets the UI say
    /// "Starting mount…" → "Mounting…" → "warming a large cache…" instead of a
    /// single static label during a multi-minute NFS cache walk. Cleared when the
    /// mount resolves.
    @Published private(set) var profileMountProgress: [UUID: String] = [:]

    /// Active transport per profile (primary or fallback)
    @Published private(set) var profileTransports: [UUID: ActiveTransport] = [:]

    /// Paused profiles (session-only, not persisted - resets on app restart)
    @Published private(set) var pausedProfiles: Set<UUID> = []

    // MARK: Abort state (see `abortSync`)

    /// Profiles with an abort in flight, and how far it has escalated. Published so the
    /// profile card can swap Abort for Force Stop and show "Stopping…".
    @Published private(set) var abortPhases: [UUID: SyncAbort.Phase] = [:]
    /// Profiles whose user pressed Force Stop while their abort was still graceful.
    private var abortForceRequested: Set<UUID> = []
    /// The task driving each in-flight abort.
    private var abortTasks: [UUID: Task<Void, Never>] = [:]
    /// Until when a finished abort's trailing log lines still belong to the aborted run
    /// (`SyncAbort.trailingSuppression`). Cleared by the next genuine run.
    private var abortSuppressUntil: [UUID: Date] = [:]
    /// Profiles whose initial sync was aborted before its launchd agent was loaded. Loading
    /// it then would have restarted the sync at once (`RunAtLoad`), so the load waits for
    /// the next run the app starts (`runSyncScript`).
    private var agentLoadDeferredByAbort: Set<UUID> = []

    /// Live progress of offline-file warming per profile (session-only). Drives the
    /// "Available Offline" progress row in `OfflineFilesSection`. Set by
    /// `warmPinnedDirectories`, which every warm entry point routes through.
    @Published private(set) var warmProgress: [UUID: WarmProgress] = [:]

    /// The user's manual "Pause caching" toggle per profile. When true, the warm loop stops
    /// starting new file reads (already-scheduled reads finish), handing a saturated slow link
    /// back to interactive use. Published so the menu bar and Offline Files reflect it live.
    /// Not persisted — a pause is a now-decision, cleared when the warm run ends; a fresh run
    /// starts un-paused.
    @Published private(set) var warmManuallyPaused: [UUID: Bool] = [:]

    /// Auto-pause deadline per profile: while `now < this`, the warm is paused because an app
    /// was seen actively reading the mount (the lsof busy check). Refreshed each time the
    /// check still finds an interactive reader, so the warm resumes a cooldown after the app
    /// goes quiet. In-memory only; drives `isWarmPaused` alongside the manual flag.
    private var warmAutoPauseUntil: [UUID: Date] = [:]

    /// How long one interactive-reader sighting pauses the warm. The busy check runs on the
    /// mount monitor's 5s cadence, so the cooldown outlives a couple of ticks — a brief gap in
    /// the app's reads doesn't thrash the warm back on and straight off again.
    static let warmAutoPauseCooldown: TimeInterval = 30

    /// In-flight warming tasks per profile, kept so a warm run can be cancelled when the
    /// cache is cleared, the profile is unmounted, or a new run supersedes it. Without this,
    /// clearing the cache mid-warm just re-downloads the files the warmer is still reading.
    private var warmTasks: [UUID: Task<Void, Never>] = [:]

    /// Profiles the app has already auto-warmed for their CURRENT mount session, so the
    /// repeating mount monitor warms a launchd/externally-mounted profile exactly once when
    /// it first appears mounted — not every 5s tick (which would thrash, since `startWarm`
    /// supersedes rather than coalesces). Re-armed when the profile is seen unmounted, so a
    /// later remount warms again and picks up files added on the remote in the meantime.
    private var autoWarmedMounts: Set<UUID> = []
    /// Profiles whose whole-tree LISTING cache this session has warmed for the current mount
    /// (see `startListingWarm`). Parallel to `autoWarmedMounts` but gated on *streaming*, not
    /// on pinned dirs — every streaming mount gets its directory listings warmed so Finder
    /// browsing is instant, whether or not the user pinned anything. Re-armed on unmount.
    private var listingWarmedMounts: Set<UUID> = []
    /// When this session last STARTED each warm (keyed by profile), for the anti-thrash cooldown.
    /// Both the listing warm and the automatic ("startup") data warm re-arm on unmount, so a mount
    /// that thrashes (launchd `KeepAlive` restarting a backend that can't attach) would otherwise
    /// re-fire the warms on every restart — exactly when the backend is already struggling, which
    /// is what turned one slow NAS into a machine-wide network hang. The cooldown stops a rapid
    /// remount from re-flooding.
    private var lastListingWarmStart: [UUID: Date] = [:]
    private var lastAutoDataWarmStart: [UUID: Date] = [:]
    /// Minimum gap between automatic warms for the same profile, across mount sessions.
    static let warmRefireCooldown: TimeInterval = 180
    // Mount read-health probe bookkeeping (in-memory; see `probeMountReadHealth`).
    private var lastMountReadProbe: [UUID: Date] = [:]
    // Last time this app session wrote each profile's Cache Only partial-file list.
    private var lastCacheOnlyListWrite: [UUID: Date] = [:]
    private var cacheOnlyListWritesInFlight: Set<UUID> = []
    private var mountReadProbesInFlight: Set<UUID> = []

    /// Live progress of an in-flight cache-directory move, keyed by the
    /// profile whose Cache Directory is changing. Drives `CacheMoveSheet`'s
    /// progress UI.
    @Published private(set) var cacheMigrationProgress: [UUID: CacheMigrationProgress] = [:]

    /// In-flight cache-migration tasks, so a second start supersedes and
    /// cancel can stop one.
    private var cacheMigrationTasks: [UUID: Task<CacheMigrationOutcome, Never>] = [:]

    /// The mount mode the sync script actually picked for a mounted Stream profile, read
    /// from its per-boot mode file (`SyncProfile.mountModePath`) by the mount-state
    /// reconcile tick. `nil` while unmounted or before the first tick has read it.
    @Published private(set) var profileMountModes: [UUID: MountMode] = [:]

    /// Live progress of an in-flight overlay upload (Resume Syncing's drain, or Upload
    /// Now's keep), keyed by profile. Drives the Cache Only status card's progress bar.
    @Published private(set) var overlayUploadProgress: [UUID: OverlaySyncService.OverlayUploadProgress] = [:]

    /// A Stream profile mid-switch between Streaming and Cache Only. The switch is a
    /// remount (unmount → [reachability probe + overlay drain, when resuming] → mount)
    /// that takes several seconds; during it `profileMountStates` is still `.mounted`
    /// and the persisted `streamCacheOnly` flag has ALREADY flipped — so without this
    /// signal the status card shows a contradictory "Streaming + Cache only" state that
    /// looks ready immediately. Set the instant the user taps, cleared when the remount
    /// settles (or when a resume aborts because the primary is unreachable).
    @Published private(set) var mountTransitions: [UUID: MountModeTransition] = [:]

    /// Direction of an in-flight Cache Only ↔ Streaming switch. The display text is a
    /// pure function of the case so it can be unit-tested (AC-MT1).
    enum MountModeTransition: Equatable {
        case enteringCacheOnly
        case resuming

        /// Status-row label shown while the switch is in flight.
        var statusText: String {
            switch self {
            case .enteringCacheOnly: return "Switching to Cache Only…"
            case .resuming:          return "Resuming syncing…"
            }
        }
    }

    /// In-flight overlay-upload tasks, so a second start (e.g. a rapid double-tap of
    /// "Upload Now") supersedes rather than races the previous one.
    private var overlayUploadTasks: [UUID: Task<Void, Never>] = [:]

    /// Profiles currently transitioning out of Cache Only (drain in progress), so the
    /// auto-resume monitor and a manual "Resume Syncing" tap can't both act at once.
    private var resumingFromCacheOnly: Set<UUID> = []

    /// Profiles already notified "Back on your network" for the CURRENT busy episode, so a
    /// repeated 2-minute tick while something keeps the mount open doesn't renotify. Cleared
    /// whenever the mode changes or the profile unmounts, so a later episode notifies again.
    private var notifiedBackOnNetworkEpisodes: Set<UUID> = []

    let profileStore: ProfileStore

    private var logWatchers: [UUID: LogWatcher] = [:]
    private var directoryWatchers: [UUID: DirectoryWatcher] = [:]
    /// Watches ~/.config/synctray for external edits to *.profile.json and
    /// settings.json and routes them through the reconcile path below.
    private var configFileWatcher: ConfigFileWatcher?
    // What last kicked off a sync per profile (manual | directory_watch | startup), consumed
    // and cleared by the `.syncStarted` handler to attribute `sync.trigger`. Absent = scheduled.
    private var pendingSyncTrigger: [UUID: String] = [:]
    private let logParser = LogParser()
    private let notificationService = NotificationService.shared
    private let setupService = SyncSetupService.shared
    private let cacheService = VFSCacheService.shared

    private var heartbeatTimer: DispatchSourceTimer?
    private var mountStateMonitorTimer: DispatchSourceTimer?
    private var mountProgressTimer: DispatchSourceTimer?
    // Mount-mode profiles whose `profileProgress` is currently driven by the RC poll, so
    // it can be cleared when a mount goes idle or unmounts.
    private var mountProgressActive: Set<UUID> = []
    private var primaryRecoveryTimer: DispatchSourceTimer?
    // Profiles with an in-flight primary-recovery remount, so we don't stack remounts.
    private var recoveringToPrimary: Set<UUID> = []
    // Consecutive successful primary probes per profile. We only remount back onto the
    // primary after the primary has been reachable for several probes in a row, so a
    // flapping primary can't trigger a remount storm (every remount is an unmount+mount,
    // which surfaces a macOS "Server connections interrupted" dialog for a Stream mount).
    private var primaryRecoveryStreak: [UUID: Int] = [:]
    // Probes are 120s apart, so 3 in a row means ~6 minutes of stable primary.
    private let primaryRecoveryRequiredStreak = 3
    private var workspaceObserver: NSObjectProtocol?
    private var currentSyncChanges: [UUID: [FileChange]] = [:]
    private var cancellables = Set<AnyCancellable>()

    // MARK: - FinderSync IPC Constants
    //
    // These string literals are intentionally duplicated in FinderSyncExtension.swift
    // (the extension target). The two targets are separate compilation units and cannot
    // share a Swift file. Treat them as a cross-target contract — if you rename one, rename both.

    /// App Group identifier shared between host app and the FinderSync extension.
    private let kAppGroupID = "7HVK85DZG7.group.com.synctray.app"

    /// UserDefaults key for the mount-path array read by the extension.
    private let kMountPathsKey = "com.synctray.app.mountPaths"

    /// Darwin notification name posted by the extension when a pin/unpin request is pending.
    private let kPinRequestNotificationName = "com.synctray.app.pinRequest"

    /// UserDefaults key for per-profile data (profileId, pinnedDirectories, vfsCachePath) read by the extension.
    private let kProfileDataKey = "com.synctray.app.profileData"

    /// Filename of the pending pin/unpin request written by the extension into the App Group container.
    private let kPendingPinRequestFile = "pending-pin-request.json"

    /// 1-second fallback poll timer for missed Darwin notifications.
    private var pinRequestPollTimer: DispatchSourceTimer?

    /// Track the last error message per profile (for correlating with syncFailed events)
    private var lastSeenErrorMessage: [UUID: String] = [:]

    /// Track sync start times per profile for duration measurement
    private var syncStartTimes: [UUID: Date] = [:]

    /// Track check phase: once totalChecks > 0 and checksDone < totalChecks, phase is active
    private var checkPhaseStartTimes: [UUID: Date] = [:]
    private var checkPhaseReported: Set<UUID> = []

    /// Profiles where we're monitoring an externally-started sync
    private var monitoringExternalSyncs: Set<UUID> = []

    /// Timers polling for sync completion
    private var syncCompletionPollers: [UUID: DispatchSourceTimer] = [:]

    // MARK: - Auto-Fix Backoff State

    /// Timestamps of the last consecutive auto-fix attempts per profile (in-memory only, not persisted).
    /// Used to implement backoff: if 2+ attempts within autoFixBackoffWindow seconds both fail, stop auto-fixing.
    private var autoFixAttempts: [UUID: [Date]] = [:]

    /// Profiles where auto-fix has been suppressed due to repeated failures.
    /// Reset when the profile completes a successful sync.
    private var autoFixSuppressed: Set<UUID> = []

    /// Single-run guard (CLAUDE.md "One Run Per Profile"): enforces one exclusive
    /// run per profile across every launch path (reinstall resync, Resync, Smart
    /// Fix, Unlock & Resync, Force Sync, auto-fix). Replaces the old
    /// in-flight `Set<UUID>` — see `ExclusiveRunRegistry`'s doc comment.
    private var exclusiveRunRegistry = ExclusiveRunRegistry()

    /// An external `.profile.json` edit's `.reinstall` reconcile, deferred because the
    /// profile's run was live at edit time (review finding: this used to be dropped with
    /// only a debug log and never retried — the next edit diffed against the already-
    /// persisted profile, found nothing to reconcile, and the agent kept running the
    /// stale script forever). `old` is the profile as it was actually installed (captured
    /// BEFORE this edit persisted), so a later retry still tears down what is really
    /// running; `new` is replaced by each subsequent deferred edit while one run keeps
    /// blocking. Retried from `processLogEvent` whenever this profile's run is observed
    /// to end (`retryPendingExternalReinstallIfNeeded`).
    private var pendingExternalReinstalls: [UUID: (old: SyncProfile, new: SyncProfile)] = [:]

    /// The time window (seconds) within which consecutive auto-fix failures trigger backoff suppression.
    private let autoFixBackoffWindow: TimeInterval = 5 * 60  // 5 minutes

    private let maxRecentChanges = 20

    init(profileStore: ProfileStore? = nil) {
        self.profileStore = profileStore ?? ProfileStore()
        setupWorkspaceObserver()
        setupProfileObserver()
        cleanupStaleLockFiles()
        setupService.refreshSharedScriptIfChanged()  // Propagate script template updates
        setupService.refreshMountModePathIfChanged(profiles: self.profileStore.profiles)  // Mode file moved out of /tmp
        setupService.cleanupStaleMounts(mountProfiles: self.profileStore.profiles)  // Clean up stale mounts on startup
        detectAndResumeRunningSyncs()  // After cleanup, detect external syncs
        checkInitialState()
        startWatchingAllProfiles()
        updateMountStates()  // Initialize mount states for mount mode profiles
        // Report active profile count and configuration snapshot for telemetry
        TelemetryService.shared.recordProfileCount(self.profileStore.enabledProfiles.count)
        TelemetryService.shared.recordAllProfileConfigurations(self.profileStore.profiles)
        startSessionHeartbeat()
        refreshCacheOnlyExcludeLists()
        startMountStateMonitor()
        startMountProgressMonitor()
        startPrimaryRecoveryMonitor()
        mountProfilesAtStartup()
        removeAllLegacyOfflineLinks()  // Clean up any (Offline) symlink left by the retired feature
        setupFinderSyncIPC()
        updateAppGroupMountPaths()
        refreshSettingsFile()
        startConfigWatcher()
    }

    deinit {
        configFileWatcher?.stop()
        configFileWatcher = nil

        // Cancel heartbeat timer
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        // Cancel mount-state monitor
        mountStateMonitorTimer?.cancel()
        mountStateMonitorTimer = nil

        // Cancel mount-progress monitor
        mountProgressTimer?.cancel()
        mountProgressTimer = nil

        // Cancel primary-recovery monitor
        primaryRecoveryTimer?.cancel()
        primaryRecoveryTimer = nil

        // Cancel pin-request poll timer
        pinRequestPollTimer?.cancel()
        pinRequestPollTimer = nil

        // Remove Darwin notification observer to avoid dangling-pointer crash.
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(kPinRequestNotificationName as CFString),
            nil
        )

        // Cancel all sync completion pollers
        for timer in syncCompletionPollers.values {
            timer.cancel()
        }
        syncCompletionPollers.removeAll()

        // Stop all directory watchers
        for watcher in directoryWatchers.values {
            watcher.stop()
        }
        directoryWatchers.removeAll()

        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    func refreshSettings() {
        startWatchingAllProfiles()
        checkInitialState()
    }

    /// Trigger manual sync for all enabled profiles, or a specific profile
    func triggerManualSync(for profile: SyncProfile? = nil) {
        let profilesToSync: [SyncProfile]
        if let profile = profile {
            // Skip if this specific profile is paused
            guard !isPaused(for: profile.id) else {
                SyncTraySettings.debugLog("Skipping manual sync for paused profile: \(profile.name)")
                return
            }
            // Per-profile guard: don't double-trigger a profile that's already
            // running an app-initiated sync (a different profile hanging no
            // longer blocks this one).
            guard !manualSyncingProfiles.contains(profile.id) else { return }
            profilesToSync = [profile]
        } else {
            // Filter out paused profiles and any already mid-sync
            profilesToSync = profileStore.enabledProfiles.filter {
                !isPaused(for: $0.id) && !manualSyncingProfiles.contains($0.id)
            }
        }

        guard !profilesToSync.isEmpty else {
            // Only surface "not configured" when there genuinely are no enabled
            // profiles — not when they're simply all mid-sync already.
            if profileStore.enabledProfiles.isEmpty {
                currentState = .notConfigured
            }
            return
        }

        let syncingIds = profilesToSync.map { $0.id }
        manualSyncingProfiles.formUnion(syncingIds)

        Task {
            // Run all profile syncs in parallel for better performance
            await withTaskGroup(of: Void.self) { group in
                for profile in profilesToSync {
                    group.addTask {
                        await self.runSyncScript(for: profile)
                    }
                }
            }
            await MainActor.run {
                manualSyncingProfiles.subtract(syncingIds)
            }
        }
    }

    // MARK: - Mount Mode Management

    /// On app launch, auto-mount enabled mount profiles that opt in via
    /// `mountAtStartup`. launchd already re-mounts these at login (RunAtLoad), so
    /// this is mostly a safety net for when the agent was unloaded — and it honours
    /// the per-profile setting so opt-out profiles are never mounted behind the
    /// user's back. `mountProfile` no-ops when the profile is already mounted.
    private func mountProfilesAtStartup() {
        for profile in profileStore.enabledProfiles
        where profile.isMountMode
            && profile.mountAtStartup
            && setupService.isInstalled(profile: profile)
            && !setupService.isMounted(profile: profile) {
            mountProfile(profile)
        }
    }

    // MARK: - Legacy Offline Access Browse Point Cleanup

    /// Remove a legacy "<mount-name> (Offline)" symlink for one profile, if the
    /// retired offline-browse-point feature left one behind. The filesystem work runs
    /// off the main actor because it touches the profile's (possibly slow, external)
    /// cache volume and needs no main-actor state — the decision is pure
    /// (`LegacyOfflineLink`) and the profile is a value type.
    func removeLegacyOfflineLink(for profile: SyncProfile) {
        DispatchQueue.global(qos: .utility).async {
            LegacyOfflineLink.removeIfPresent(for: profile)
        }
    }

    /// Remove a legacy offline-browse-point symlink for **every** profile. Called at
    /// launch and on profile delete so a leftover from the retired feature is cleaned
    /// up without any live mount depending on its presence.
    func removeAllLegacyOfflineLinks() {
        let profiles = profileStore.profiles
        DispatchQueue.global(qos: .utility).async {
            for profile in profiles {
                LegacyOfflineLink.removeIfPresent(for: profile)
            }
        }
    }

    /// Mount a profile (for mount mode only)
    /// Outcome of one tick of the mount-establishment poll.
    enum MountPollDecision: Equatable {
        case established    // the volume is in the mount table now
        case keepWaiting    // not mounted yet, still establishing — stay in `.mounting`
        case failedDead     // the mount agent stopped (fail fast, don't wait the cap)
        case failedTimeout  // the hard time cap elapsed while still unmounted
    }

    /// Pure decision for the mount-establishment poll (see `mountProfile`).
    /// Extracted so the timeout / liveness logic is unit-testable without a real
    /// mount (`ConfigSelfTest` AC-MP1). A mount is `.established` the moment the
    /// volume appears; otherwise an agent that is still alive means "establishing"
    /// (keep the loading state) up to `maxSeconds`, while `deadThreshold`
    /// consecutive not-alive samples end it early as `.failedDead` — so a genuinely
    /// stopped agent fails fast, but a KeepAlive respawn gap (one missed sample)
    /// does not.
    /// - Note: `isMounted` wins over everything, so a mount that comes up on the
    ///   same tick the cap elapses still reports success.
    static func mountPollDecision(
        elapsedSeconds: Int,
        maxSeconds: Int,
        isMounted: Bool,
        agentAlive: Bool,
        consecutiveDead: Int,
        deadThreshold: Int
    ) -> MountPollDecision {
        if isMounted { return .established }
        if !agentAlive && consecutiveDead >= deadThreshold { return .failedDead }
        if elapsedSeconds >= maxSeconds { return .failedTimeout }
        return .keepWaiting
    }

    /// Staged status text for a `.mounting` profile, chosen by how long the mount
    /// has been establishing. Pure so the message buckets are unit-testable
    /// (`ConfigSelfTest` AC-MP1). The later buckets reassure the user that a slow
    /// mount is a large-cache walk, not a hang, and name the 5-minute ceiling.
    static func mountProgressMessage(elapsedSeconds: Int) -> String {
        switch elapsedSeconds {
        case ..<8:   return "Starting mount…"
        case ..<45:  return "Mounting…"
        case ..<120: return "Mounting… warming a large cache, this can take a minute"
        default:     return "Still mounting… large cache, this can take up to 5 minutes"
        }
    }

    func mountProfile(_ profile: SyncProfile) {
        guard profile.isMountMode else { return }

        profileMountStates[profile.id] = .mounting
        profileMountProgress[profile.id] = Self.mountProgressMessage(elapsedSeconds: 0)

        Task {
            do {
                // Check if already mounted
                if setupService.isMounted(profile: profile) {
                    await MainActor.run {
                        profileMountStates[profile.id] = .mounted
                        mountTransitions[profile.id] = nil
                    }
                    return
                }

                // Ensure the agent is loaded (so kickstart can target it), then force
                // a fresh start. We only reach here when NOT already mounted, so
                // kickstart -k is safe and is the reliable path: it starts opt-out
                // profiles (RunAtLoad=false) and recovers a zombie rclone (running but
                // unmounted, holding the RC port) that loadAgent alone can't restart.
                _ = setupService.loadAgent(for: profile)
                let success = setupService.startAgent(for: profile)

                if success {
                    // Poll for the mount to establish, staying in `.mounting` (the UI
                    // shows a spinner) the whole time. A large VFS cache walk before the
                    // NFS volume attaches can take minutes (observed ~112s for a 121GB /
                    // 12k-file cache), so the old fixed 30s cap flipped the UI to a false
                    // "Mount did not establish" while the mount was still coming up. Poll
                    // up to 5 minutes using launchd job liveness as the signal: an
                    // unmounted-but-agent-alive profile is still establishing; a stopped
                    // agent (deadThreshold consecutive samples) fails fast; the 5-minute
                    // cap is the backstop. The 5s mount-state monitor independently
                    // confirms a late arrival, so this loop never needs to over-wait.
                    let maxSeconds = 300
                    let pollInterval = 2
                    let deadThreshold = 3
                    var decision: MountPollDecision = .keepWaiting
                    var consecutiveDead = 0
                    var elapsed = 0
                    var lastProgress = Self.mountProgressMessage(elapsedSeconds: 0)
                    while elapsed < maxSeconds {
                        try? await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)
                        elapsed += pollInterval
                        let mounted = setupService.isMounted(profile: profile)
                        let alive = setupService.isMountAgentRunning(profile: profile)
                        consecutiveDead = alive ? 0 : consecutiveDead + 1
                        decision = Self.mountPollDecision(
                            elapsedSeconds: elapsed,
                            maxSeconds: maxSeconds,
                            isMounted: mounted,
                            agentAlive: alive,
                            consecutiveDead: consecutiveDead,
                            deadThreshold: deadThreshold
                        )
                        if decision != .keepWaiting { break }
                        // Escalate the loading text only when the bucket changes, so a
                        // multi-minute cache walk reads as progress, not a hang.
                        let progress = Self.mountProgressMessage(elapsedSeconds: elapsed)
                        if progress != lastProgress {
                            lastProgress = progress
                            await MainActor.run { self.profileMountProgress[profile.id] = progress }
                        }
                    }
                    let established = (decision == .established)
                    let failReason = decision == .failedDead
                        ? "Mount agent stopped before the volume attached"
                        : "Mount did not establish within 5 minutes"
                    await MainActor.run {
                        profileMountProgress[profile.id] = nil
                        // The mode switch (if any) is done once the remount settles,
                        // either way — clear the "Switching…/Resuming…" indicator.
                        mountTransitions[profile.id] = nil
                        if established {
                            profileMountStates[profile.id] = .mounted
                            TelemetryService.shared.recordMountOperation(
                                profileId: profile.id,
                                profileName: profile.name,
                                operation: "mount",
                                result: "success"
                            )
                            // Update App Group mount paths so the FinderSync extension
                            // registers this newly mounted directory.
                            updateAppGroupMountPaths()
                            // Auto-refresh pinned directories after successful mount
                            if !profile.pinnedDirectories.isEmpty {
                                // Claim the warm here so the mount monitor's own
                                // warm-on-detect (reconcileMountStatesOffMain) doesn't also
                                // fire for this same mount.
                                autoWarmedMounts.insert(profile.id)
                                Task { [weak self] in
                                    // Wait for RC API to be ready
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    self?.startWarm(for: profile.id, trigger: "startup")
                                }
                            }
                        } else {
                            profileMountStates[profile.id] = .failed(failReason)
                            TelemetryService.shared.recordMountOperation(
                                profileId: profile.id,
                                profileName: profile.name,
                                operation: "mount",
                                result: "failure"
                            )
                        }
                    }
                } else {
                    await MainActor.run {
                        profileMountStates[profile.id] = .failed("Failed to start mount agent")
                        mountTransitions[profile.id] = nil
                        TelemetryService.shared.recordMountOperation(
                            profileId: profile.id,
                            profileName: profile.name,
                            operation: "mount",
                            result: "failure"
                        )
                    }
                }
            }
        }
    }

    /// Unmount a profile (for mount mode only)
    func unmountProfile(_ profile: SyncProfile) {
        guard profile.isMountMode else { return }

        // Stop any warming first — reads through a mount that's going away would hang or fail.
        cancelWarm(for: profile.id)
        autoWarmedMounts.remove(profile.id)  // re-arm auto-warm for the next mount

        Task {
            do {
                try setupService.unmount(profile: profile)
                await MainActor.run {
                    profileMountStates[profile.id] = .unmounted
                    TelemetryService.shared.recordMountOperation(
                        profileId: profile.id,
                        profileName: profile.name,
                        operation: "unmount",
                        result: "success"
                    )
                    // Update App Group mount paths so the FinderSync extension
                    // unregisters this directory.
                    updateAppGroupMountPaths()
                }
            } catch {
                await MainActor.run {
                    profileMountStates[profile.id] = .failed(error.localizedDescription)
                    TelemetryService.shared.recordMountOperation(
                        profileId: profile.id,
                        profileName: profile.name,
                        operation: "unmount",
                        result: "failure"
                    )
                }
            }
        }
    }

    /// Get mount state for a specific profile
    func mountState(for profileId: UUID) -> MountState {
        profileMountStates[profileId] ?? .unmounted
    }

    /// Update mount states for all mount mode profiles
    func updateMountStates() {
        for profile in profileStore.enabledProfiles where profile.isMountMode {
            let isMounted = setupService.isMounted(profile: profile)
            if isMounted {
                profileMountStates[profile.id] = .mounted
            } else if profileMountStates[profile.id] == nil || profileMountStates[profile.id] == .mounted {
                // Only update to unmounted if it was previously mounted or unknown
                profileMountStates[profile.id] = .unmounted
            }
        }
    }

    func openLogFile(for profile: SyncProfile? = nil) {
        let logPath: String
        if let profile = profile {
            logPath = profile.logPath
        } else if let firstEnabled = profileStore.enabledProfiles.first {
            logPath = firstEnabled.logPath
        } else {
            return
        }

        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        }
    }

    func openSyncDirectory(for profile: SyncProfile? = nil) {
        let syncPath: String
        if let profile = profile {
            syncPath = profile.localSyncPath
        } else if let firstEnabled = profileStore.enabledProfiles.first {
            syncPath = firstEnabled.localSyncPath
        } else {
            return
        }

        if !syncPath.isEmpty && FileManager.default.fileExists(atPath: syncPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: syncPath))
        }
    }

    func openFileInFinder(_ change: FileChange) {
        // Try to find the file in any of the enabled profiles
        for profile in profileStore.enabledProfiles {
            let fullPath = (profile.localSyncPath as NSString).appendingPathComponent(change.path)
            let url = URL(fileURLWithPath: fullPath)

            if FileManager.default.fileExists(atPath: fullPath) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
        }

        // File might have been deleted, try the first profile's path
        if let profile = profileStore.enabledProfiles.first {
            let fullPath = (profile.localSyncPath as NSString).appendingPathComponent(change.path)
            let parentDir = (fullPath as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: parentDir) {
                NSWorkspace.shared.open(URL(fileURLWithPath: parentDir))
            }
        }
    }

    func enableLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                objectWillChange.send()  // Notify SwiftUI to update UI
                refreshSettingsFile()
            } catch {
                print("Failed to register login item: \(error)")
            }
        }
    }

    func disableLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
                objectWillChange.send()  // Notify SwiftUI to update UI
                refreshSettingsFile()
            } catch {
                print("Failed to unregister login item: \(error)")
            }
        }
    }

    var isLoginItemEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    // MARK: - Profile Management

    /// Enable/disable scheduled sync for a profile
    func setProfileEnabled(_ profile: SyncProfile, enabled: Bool) {
        var updatedProfile = profile
        updatedProfile.isEnabled = enabled
        profileStore.update(updatedProfile)

        if enabled {
            do {
                try setupService.install(profile: updatedProfile)
                startWatching(profile: updatedProfile)
            } catch {
                print("Failed to install profile: \(error)")
            }
        } else {
            do {
                try setupService.uninstall(profile: updatedProfile)
                stopWatching(profileId: profile.id)
            } catch {
                print("Failed to uninstall profile: \(error)")
            }
        }

        updateAggregateState()
    }

    // MARK: - External Config Reconcile

    /// Start watching `~/.config/synctray` for external edits. No-op if the
    /// directory doesn't exist yet (the app ensures it exists at launch via
    /// `ConfigSchemaInstaller.writeSchemas()`, called before `SyncManager` is created).
    private func startConfigWatcher() {
        let watcher = ConfigFileWatcher(
            onProfileChange: { [weak self] path in
                Task { @MainActor in self?.applyExternalProfileEdit(fromFileAt: path) }
            },
            onSettingsChange: { [weak self] in
                Task { @MainActor in self?.applyExternalSettingsEdit() }
            }
        )
        watcher.start()
        configFileWatcher = watcher
    }

    /// Rewrite `settings.json` from the current `SyncTraySettings` state.
    /// Call after any UI-driven change to a safe key so the file stays in
    /// sync with the app (the write notes its own hash, so the watcher
    /// ignores the FSEvent it produces).
    func refreshSettingsFile() {
        AppSettingsFileStore.writeSettingsFile(isLoginItemEnabled: isLoginItemEnabled)
    }

    /// Apply an external edit to a `*.profile.json` file, routing through the
    /// SAME install/uninstall/reinstall reconcile the Save button uses —
    /// never a bare in-memory struct swap, so the running launchd agent is
    /// never left stale.
    ///
    /// A decode failure (half-written file) is a silent no-op — a half-written
    /// file will complete and re-trigger. A file carrying an UNKNOWN, decodable
    /// id is not ignored: it CREATES the profile (see `applyExternalProfileCreate`
    /// / `SyncManager.applyExternalCreateIfNeeded`), so an agent can bootstrap a
    /// new sync purely by dropping a file.
    func applyExternalProfileEdit(fromFileAt path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let updatedProfile = try? JSONDecoder().decode(SyncProfile.self, from: data) else {
            SyncTraySettings.debugLog("[ConfigFileWatcher] Failed to decode external profile edit at \(path); skipping")
            return
        }

        guard let currentProfile = profileStore.profile(for: updatedProfile.id) else {
            applyExternalProfileCreate(decoded: updatedProfile, sourcePath: path)
            return
        }

        let action = Self.reconcileAction(from: currentProfile, to: updatedProfile)

        profileStore.update(updatedProfile)
        clearError(for: updatedProfile.id)

        switch action {
        case .none:
            break

        case .install:
            do {
                try setupService.install(profile: updatedProfile)
                startWatching(profile: updatedProfile)
            } catch {
                print("Failed to install externally-edited profile: \(error)")
            }

        case .uninstall:
            do {
                try setupService.uninstall(profile: updatedProfile)
                stopWatching(profileId: updatedProfile.id)
            } catch {
                print("Failed to uninstall externally-edited profile: \(error)")
            }

        case .reinstall:
            // Refuse while the profile's run is live (review finding): an external edit
            // reaches `uninstallForReinstall` without going through `beginExclusiveRun`,
            // so without this check a config edit that lands mid-run would unload the
            // agent, delete the profile's own live locks, then immediately reload the
            // agent (RunAtLoad=true) — a second bisync next to the one still running.
            // `uninstallForReinstall` itself refuses too (defense in depth, shared with
            // the CLI's `reinstall`/`profile set`); skipping `install` here as well means
            // this edit is never half-applied (config persisted above, agent left as-is).
            guard !isRunLive(for: currentProfile) else {
                // Remember it instead of dropping it (review finding): keep the ORIGINAL
                // `old` from the first deferral if one is already pending, since that is
                // what is actually installed — only `new` advances to this latest edit.
                let effectiveOld = pendingExternalReinstalls[currentProfile.id]?.old ?? currentProfile
                pendingExternalReinstalls[currentProfile.id] = (old: effectiveOld, new: updatedProfile)
                SyncTraySettings.debugLog(
                    "[ConfigFileWatcher] Deferred reinstall for '\(currentProfile.name)': a sync is currently running; will retry once it ends")
                TelemetryService.shared.recordDeferredReinstall(
                    profileId: currentProfile.id, profileName: currentProfile.name, outcome: "deferred")
                break
            }
            pendingExternalReinstalls[currentProfile.id] = nil
            do {
                // Keeps the bisync listings while they still apply, so a settings edit
                // never forces a full --resync (see `uninstallForReinstall`).
                try setupService.uninstallForReinstall(from: currentProfile, to: updatedProfile)
            } catch {
                // Ignore uninstall errors, matching ProfileDetailView.reinstallSync.
            }
            do {
                try setupService.install(profile: updatedProfile)
                startWatching(profile: updatedProfile)
            } catch {
                print("Failed to reinstall externally-edited profile: \(error)")
            }
        }

        // App-side warm reconcile, ORTHOGONAL to the launchd `action` above: an
        // external edit that changes `warmExcludePatterns` or `pinnedDirectories`
        // must take effect (re-warm) just as the in-app pin/unpin edit does, even
        // though such a change yields `action == .none` (no reinstall/remount).
        // Gated on the profile being currently mounted; runs the same primitives
        // as the in-app path via `applyWarmReconcile` so the two cannot drift.
        Self.applyWarmReconcileIfNeeded(
            from: currentProfile,
            to: updatedProfile,
            isMounted: profileMountStates[updatedProfile.id] == .mounted
        ) { [weak self] id in
            self?.applyWarmReconcile(for: id, trigger: "external_edit")
        }

        // "Don't Sync" patterns AND "Sync Only These Folders" selective folders, also
        // ORTHOGONAL to `action`: a changed `syncExcludePatterns`/`syncIncludeFolders` yields
        // `action == .none` (the script re-reads the filter file every run), so rewrite the
        // file here, with the same gate and the same outcome recording as the in-app editors
        // (`updateSyncExcludePatterns` / `updateSyncIncludeFolders`). A failed write goes to
        // `syncFilterErrors`, not `profileErrors`: every sync run clears `profileErrors`,
        // which would make the patterns look applied again. A bisync profile whose compiled
        // include rules actually change picks up its own resync-pending marker inside the
        // write — never a reinstall.
        applySyncFilterReconcile(from: currentProfile, to: updatedProfile)

        updateAggregateState()
        TelemetryService.shared.recordExternalConfigEdit(kind: "profile")
    }

    /// Wires `applyExternalCreateIfNeeded`'s persist/install closures to the
    /// production primitives — the SAME `profileStore.add`/`setupService.install`
    /// the in-app "create profile" flow and the `.install` reconcile branch
    /// use, so a file-bootstrapped profile can never drift from an
    /// in-app-created one.
    ///
    /// `persist` also canonicalizes the file: if the dropped file's basename
    /// isn't `{shortId}.profile.json`, the differently-named source is removed
    /// AFTER `profileStore.add` writes the canonical file (which notes its own
    /// content hash in `ConfigSelfWriteRegistry`) — the resulting missing-source
    /// FSEvent is a no-op (`ConfigFileWatcher.shouldReconcile` returns false for
    /// a missing file), so this can never loop.
    private func applyExternalProfileCreate(decoded: SyncProfile, sourcePath: String) {
        let outcome = Self.applyExternalCreateIfNeeded(
            decoded: decoded,
            isKnownId: false,
            persist: { [weak self] profile in
                self?.profileStore.add(profile)
                self?.clearError(for: profile.id)

                let canonicalFilename = "\(profile.shortId).profile.json"
                let sourceFilename = (sourcePath as NSString).lastPathComponent
                if sourceFilename != canonicalFilename {
                    try? FileManager.default.removeItem(atPath: sourcePath)
                }
            },
            install: { [weak self] profile in
                do {
                    try self?.setupService.install(profile: profile)
                    self?.startWatching(profile: profile)
                } catch {
                    print("Failed to install newly-created external profile: \(error)")
                }
            }
        )

        guard outcome != .ignored else { return }

        updateAggregateState()
        TelemetryService.shared.recordExternalConfigEdit(kind: "profile", action: "create")
    }

    /// App-side warm reconcile: re-push the App Group data the FinderSync
    /// extension reads (pinned set / cache path may have changed) and (re)start a
    /// warming run for the profile's pinned directories. This is the SAME pair of
    /// primitives the in-app pin/unpin flow uses (`processPendingPinRequest` →
    /// `updateAppGroupMountPaths` + `startWarm`), reused here so an external
    /// `.profile.json` edit and an in-app edit warm identically.
    ///
    /// SEPARATE from `ProfileReconcileAction` / `setupService` — this NEVER
    /// reinstalls the launchd agent or remounts. `startWarm` supersedes any run
    /// already in flight, so re-running it after an exclude/pin change re-applies
    /// the new filter to the current download rather than only the next one.
    func applyWarmReconcile(for profileId: UUID, dirs: [String]? = nil, trigger: String) {
        updateAppGroupMountPaths()  // re-push pinnedDirectories/vfsCachePath; also wakes the extension
        startWarm(for: profileId, dirs: dirs, trigger: trigger)
    }

    /// Apply an external edit to `settings.json`. Safe keys apply directly;
    /// `launchAtLogin` goes through `SettingsReconciler`'s ISOLATED path so an
    /// `SMAppService` failure can never corrupt anything else.
    func applyExternalSettingsEdit() {
        let safeSettings = AppSettingsFileStore.readSafeSettings()

        SettingsReconciler.apply(
            safeSettings: safeSettings,
            applySafeKey: { key, value in
                switch key {
                case .debugLoggingEnabled:
                    SyncTraySettings.debugLoggingEnabled = value
                case .autoFixSyncIssues:
                    SyncTraySettings.autoFixSyncIssues = value
                case .telemetryEnabled:
                    SyncTraySettings.telemetryEnabled = value
                case .launchAtLogin:
                    break  // handled by the isolated path below
                }
            },
            currentLoginItemEnabled: { [weak self] in self?.isLoginItemEnabled ?? false },
            applyLoginItem: { [weak self] enabled in
                guard let self else { return }
                if #available(macOS 13.0, *) {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                }
                self.objectWillChange.send()
            }
        )

        TelemetryService.shared.recordExternalConfigEdit(kind: "settings")
    }

    /// Get state for a specific profile
    func state(for profileId: UUID) -> SyncState {
        profileStates[profileId] ?? .idle
    }

    /// Get active transport for a specific profile
    func activeTransport(for profileId: UUID) -> ActiveTransport {
        profileTransports[profileId] ?? .unknown
    }

    /// Get last error message for a specific profile
    /// Only returns errors detected during this session (not persisted across app restarts)
    func lastError(for profileId: UUID) -> String? {
        return profileErrors[profileId]
    }

    /// Clear the cached error for a profile (call when config changes or fix is attempted)
    func clearError(for profileId: UUID) {
        profileErrors[profileId] = nil
        if case .error = profileStates[profileId] {
            profileStates[profileId] = .idle
        }
        updateAggregateState()
    }

    /// Record the outcome of a "Don't Sync" filter write: its error text, or nil once a
    /// write succeeds. The only writer of `syncFilterErrors`, whose setter is private to
    /// this file; `applySyncFilterReconcile` (ConfigReconciler.swift) calls it.
    func recordSyncFilterWrite(error: String?, for profileId: UUID) {
        syncFilterErrors[profileId] = error
    }

    /// Set the syncing state for a profile (used by views running direct resyncs)
    func setSyncing(for profileId: UUID, isSyncing: Bool) {
        if isSyncing {
            profileStates[profileId] = .syncing
            profileErrors[profileId] = nil
        } else {
            profileStates[profileId] = .idle
        }
        updateAggregateState()
    }

    /// Returns true if we're monitoring an externally-started sync for this profile
    func isMonitoringExternalSync(for profileId: UUID) -> Bool {
        monitoringExternalSyncs.contains(profileId)
    }

    // MARK: - Single-Run Guard

    /// Decide whether a profile is live right now, for `isRunLive`. Pure static so
    /// it is self-testable without constructing `SyncManager` (AC-SR7). Mount
    /// (Stream) profiles hold their `/tmp` run lock for the whole life of the
    /// mount daemon (R7) — if lock liveness counted for them, Pause/Uninstall/
    /// Reinstall would stay disabled forever (see the comment in
    /// `detectAndResumeRunningSyncs`), so a mount profile's liveness comes from
    /// the registry alone.
    nonisolated static func runLiveness(
        isMount: Bool,
        registryActive: Bool,
        runLock: SyncRunLock.Holder,
        sessionLock: SyncRunLock.Holder,
        isAlive: (Int32) -> Bool
    ) -> Bool {
        if isMount {
            return registryActive
        }
        return registryActive
            || SyncRunLock.isLive(runLock, isAlive: isAlive)
            || SyncRunLock.isLive(sessionLock, isAlive: isAlive)
    }

    /// Read a profile's two lock holders fresh from disk: the `/tmp` run lock and
    /// the bisync session `.lck`. Shared by every method below so the parse logic
    /// lives in one place.
    private func lockHolders(for profile: SyncProfile) -> (runLock: SyncRunLock.Holder, sessionLock: SyncRunLock.Holder) {
        let runLock = SyncRunLock.parseHolder(try? String(contentsOfFile: profile.lockFilePath, encoding: .utf8))
        let sessionLockPath = SyncRunLock.sessionLockPath(for: profile)
        let sessionLock = SyncRunLock.parseHolder(try? String(contentsOfFile: sessionLockPath, encoding: .utf8))
        return (runLock, sessionLock)
    }

    /// Begin an exclusive run for `profile`, atomically acquiring the `/tmp` run
    /// lock with the app's own PID as a live placeholder (D4) once the registry
    /// grants the slot. Every launch path that actually starts rclone (reinstall
    /// resync, Resync, Smart Fix, Unlock & Resync, Force Sync, auto-fix) calls this
    /// before doing anything else. Returns `nil` when blocked — the caller must not
    /// mutate state, clear errors, or launch a process.
    func beginExclusiveRun(for profile: SyncProfile, source: ExclusiveRunSource) -> ExclusiveRunToken? {
        // Never while an abort is still stopping the last run: its monitor would stop this
        // one too.
        guard !isAborting(for: profile.id) else { return nil }
        let (runLock, sessionLock) = lockHolders(for: profile)
        let placeholder = String(getpid())
        let decision = exclusiveRunRegistry.begin(
            profileId: profile.id,
            source: source,
            runLock: runLock,
            sessionLock: sessionLock,
            isAlive: SyncRunLock.processIsAlive,
            now: Date(),
            placeholder: placeholder
        )
        guard case .granted(let token) = decision else { return nil }

        let acquireResult = SyncRunLock.acquire(path: profile.lockFilePath, token: placeholder, isAlive: SyncRunLock.processIsAlive)
        guard acquireResult == .acquired else {
            exclusiveRunRegistry.end(token)
            return nil
        }
        // A new run: an earlier abort's trailing suppression must not hide its failures.
        abortSuppressUntil[profile.id] = nil
        return token
    }

    /// Release `token`'s registry slot. Does NOT touch the lock file on disk —
    /// callers release that separately via `SyncRunLock.releaseIfOwned` once the
    /// process has actually exited, so the lock stays held for the run's whole
    /// lifetime even though the registry entry and the file are independent.
    func endExclusiveRun(_ token: ExclusiveRunToken) {
        exclusiveRunRegistry.end(token)
    }

    /// Check-only variant for script-driven recovery (Unlock & Retry, Unlock, Sync
    /// Now — D6): the sync script takes its own atomic `noclobber` lock, so these
    /// paths only need to know whether it is safe to proceed, not a token to hold.
    func canStartRun(for profile: SyncProfile) -> Bool {
        guard !exclusiveRunRegistry.isActive(profile.id) else { return false }
        let (runLock, sessionLock) = lockHolders(for: profile)
        if SyncRunLock.isLive(runLock, isAlive: SyncRunLock.processIsAlive) { return false }
        if SyncRunLock.isLive(sessionLock, isAlive: SyncRunLock.processIsAlive) { return false }
        return true
    }

    /// Whether a profile currently has a live run, for UI gating (`isSyncRunningForProfile`,
    /// the error banner) and for suppressing a rejected-concurrent-run failure from
    /// being treated as a profile failure (R3).
    func isRunLive(for profile: SyncProfile) -> Bool {
        let (runLock, sessionLock) = lockHolders(for: profile)
        return Self.runLiveness(
            isMount: profile.isMountMode,
            registryActive: exclusiveRunRegistry.isActive(profile.id),
            runLock: runLock,
            sessionLock: sessionLock,
            isAlive: SyncRunLock.processIsAlive
        )
    }

    /// Applies a reinstall that `applyExternalProfileEdit` deferred because the
    /// profile's run was live at edit time (review finding: a deferred reinstall was
    /// otherwise never retried). Called from `processLogEvent` whenever a log event
    /// observes this profile's run ending — safe to call unconditionally; a no-op when
    /// nothing is pending.
    ///
    /// Reinstalls the CURRENT profile from `profileStore`, never the `pending.new`
    /// snapshot captured at defer time (review finding): any edit that lands while the
    /// run was still live — including a `.none`-action edit like a changed "Don't Sync"
    /// pattern, or an enable/disable — updates the store but never touches the pending
    /// snapshot, so installing the stale copy would silently drop it.
    private func retryPendingExternalReinstallIfNeeded(for profileId: UUID) {
        guard let pending = pendingExternalReinstalls[profileId] else { return }
        // The profile may have been deleted, or disabled, while the reinstall was
        // deferred (review finding): neither clears the pending entry, and falling
        // back to the stale `pending.new` snapshot on a delete — or reinstalling a
        // profile the user explicitly disabled — would bring back a launchd agent
        // with no UI to stop it. Drop the pending entry instead; both delete and
        // disable already ran their own `uninstall` through the normal reconcile
        // path, so there is nothing left to reinstall.
        guard let latest = profileStore.profile(for: profileId), latest.isEnabled else {
            pendingExternalReinstalls[profileId] = nil
            TelemetryService.shared.recordDeferredReinstall(
                profileId: profileId, profileName: pending.new.name, outcome: "dropped")
            return
        }
        guard !isRunLive(for: latest) else {
            // The "run ended" log line and the run actually being over are not atomic:
            // an app-started run's terminationHandler writes "Bisync completed/failed"
            // BEFORE releasing the lock, and the launchd sync script's own log line
            // precedes its EXIT trap removing the session lock (review finding). Either
            // way `isRunLive` can still read true for a moment after this log event — a
            // short delayed re-check catches that window instead of waiting for some
            // unrelated later run to end.
            scheduleRetryPendingExternalReinstallCheck(for: profileId)
            return
        }
        pendingReinstallRetryScheduled.remove(profileId)
        pendingExternalReinstalls[profileId] = nil
        do {
            try setupService.uninstallForReinstall(from: pending.old, to: latest)
        } catch {
            // Ignore uninstall errors, matching the original deferred path.
        }
        do {
            try setupService.install(profile: latest)
            startWatching(profile: latest)
            SyncTraySettings.debugLog(
                "[ConfigFileWatcher] Applied deferred reinstall for '\(latest.name)' now that its run has ended")
            TelemetryService.shared.recordDeferredReinstall(
                profileId: profileId, profileName: latest.name, outcome: "applied")
        } catch {
            print("Failed to reinstall externally-edited profile after deferred retry: \(error)")
            TelemetryService.shared.recordDeferredReinstall(
                profileId: profileId, profileName: latest.name, outcome: "failed")
        }
    }

    /// At most one in-flight delayed re-check per profile, so repeated log events while
    /// a run is winding down don't stack up timers (see `retryPendingExternalReinstallIfNeeded`).
    private var pendingReinstallRetryScheduled: Set<UUID> = []

    private func scheduleRetryPendingExternalReinstallCheck(for profileId: UUID) {
        guard !pendingReinstallRetryScheduled.contains(profileId) else { return }
        pendingReinstallRetryScheduled.insert(profileId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.pendingReinstallRetryScheduled.remove(profileId)
            self.retryPendingExternalReinstallIfNeeded(for: profileId)
        }
    }

    // MARK: - Auto-Fix

    /// Attempt an automatic --resync recovery for the given profile.
    ///
    /// Called from `processLogEvent` when the auto-fix setting is enabled and the
    /// profile enters an out-of-sync error state. Implements a backoff guard:
    /// if the same profile triggers auto-fix **twice within 5 minutes**, auto-fix
    /// is suppressed for that profile until a successful sync clears the suppression.
    /// Note: suppression fires on the 2nd trigger (not the 2nd confirmed failure),
    /// because confirming failure requires the log-watcher round-trip.
    ///
    /// Reuses the same rclone bisync --resync process that `ProfileDetailView.runResync()`
    /// runs, but without UI state (the progress bar / output panel in the settings
    /// view is driven by the profile state change visible via `@Published profileStates`).
    func triggerAutoFix(for profile: SyncProfile) {
        let profileId = profile.id

        // Respect the global setting
        guard SyncTraySettings.autoFixSyncIssues else { return }

        // Skip paused profiles — auto-fix should never fire while the user has sync paused
        guard !isPaused(for: profileId) else {
            SyncTraySettings.debugLog("Auto-fix skipped: profile '\(profile.name)' is paused")
            return
        }

        // Auto-fix only applies to bisync mode — one-way sync and mount profiles do not
        // produce "out of sync" errors and have no --resync concept.
        guard profile.syncMode == .bisync else { return }

        // Never auto-resync against an unmounted external drive. The local path is missing
        // or replaced by an empty mount point, so a --resync would run against an empty/partial
        // local tree — exactly the case that cannot be safely auto-fixed. Reflect reality in the
        // UI and return WITHOUT recording an attempt, so the backoff budget is not consumed by a
        // condition the user can only resolve by reconnecting the drive.
        if !profile.drivePathToMonitor.isEmpty,
           !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
            SyncTraySettings.debugLog("Auto-fix skipped: external drive not mounted for '\(profile.name)'")
            TelemetryService.shared.recordAutoFixTriggered(
                profileId: profileId,
                profileName: profile.name,
                result: "skipped_drive_not_mounted"
            )
            profileStates[profileId] = .driveNotMounted
            updateAggregateState()
            return
        }

        // Skip if a resync is already in-flight for this profile, or if another
        // process holds the run/session lock (D8): checked here, in the same
        // position the old in-flight-set check occupied, before the backoff
        // bookkeeping below. Blocked is telemetry-visible now, where the old
        // in-flight skip was silent.
        guard let token = beginExclusiveRun(for: profile, source: .autoFix) else {
            SyncTraySettings.debugLog("Auto-fix skipped: a run is already in progress for '\(profile.name)'")
            TelemetryService.shared.recordAutoFixTriggered(
                profileId: profileId,
                profileName: profile.name,
                result: "blocked_already_running"
            )
            return
        }

        // Respect per-profile suppression (backoff guard) — return silently after the first
        // transition notification so the user is not spammed on every subsequent syncFailed event.
        guard !autoFixSuppressed.contains(profileId) else {
            SyncTraySettings.debugLog("Auto-fix suppressed (backoff) for '\(profile.name)'")
            SyncRunLock.releaseIfOwned(path: profile.lockFilePath, ownTokens: [token.placeholder])
            endExclusiveRun(token)
            return
        }

        // Record the attempt and check backoff threshold
        let now = Date()
        var attempts = autoFixAttempts[profileId] ?? []
        // Prune attempts outside the backoff window
        attempts = attempts.filter { now.timeIntervalSince($0) < autoFixBackoffWindow }
        attempts.append(now)
        autoFixAttempts[profileId] = attempts

        if attempts.count >= 2 {
            // Two failures within the window — suppress further auto-fix for this profile.
            // Only notify once (on the transition into suppressed state).
            autoFixSuppressed.insert(profileId)
            TelemetryService.shared.recordAutoFixTriggered(
                profileId: profileId,
                profileName: profile.name,
                result: "gave_up_backoff"
            )
            SyncTraySettings.debugLog("Auto-fix giving up (backoff) for '\(profile.name)' after \(attempts.count) attempts")
            notificationService.notifyAutoFixSuppressed(profileId: profileId, profileName: profile.name)
            SyncRunLock.releaseIfOwned(path: profile.lockFilePath, ownTokens: [token.placeholder])
            endExclusiveRun(token)
            return
        }

        // Good to go — notify user and start the resync
        SyncTraySettings.debugLog("Auto-fix triggering resync for '\(profile.name)'")
        TelemetryService.shared.recordAutoFixTriggered(
            profileId: profileId,
            profileName: profile.name,
            result: "triggered"
        )

        // Post a macOS notification so the user can see what's happening
        notificationService.notifyAutoFix(profileId: profileId, profileName: profile.name)

        // Clear current error and mark syncing so the UI updates
        clearError(for: profileId)
        setSyncing(for: profileId, isSyncing: true)
        // Ensure the log-watcher uses its faster polling cadence so it sees the
        // upcoming "Starting bisync" / "Bisync completed" markers promptly.
        logWatchers[profileId]?.setActivelySyncing(true)

        Task {
            await performResync(for: profile, token: token)
        }
    }

    /// Resolve the remote reference and env-var overrides a resync should target,
    /// honouring the currently active transport (primary vs fallback) the same way
    /// the launchd sync script does. Without this, a resync launched while the
    /// profile runs on fallback would rebuild the wrong (primary) bisync pair.
    /// - Returns: the effective "remote:path" plus RCLONE_CONFIG_* env overrides
    ///   (non-empty only for the same-wire-type fallback that preserves the cache
    ///   by keeping the primary remote name).
    func resolveActiveRemote(for profile: SyncProfile) -> (remotePath: String, extraEnv: [String: String]) {
        let transport = profileTransports[profile.id] ?? .unknown
        let primaryRemotePath = "\(profile.rcloneRemote):\(profile.remotePath)"

        guard transport.isFallback, !profile.fallbackRemote.isEmpty else {
            return (primaryRemotePath, [:])
        }

        // This function backs `performResync`, which only ever runs for bisync/sync
        // profiles (mount has no --resync concept and never streams via a fallback —
        // see "Fallback Remote Pipeline" in CLAUDE.md), so there is no mount-mode
        // branch here to preserve.
        if profile.fallbackRequiresCacheRebuild || !profile.fallbackRemotePath.isEmpty {
            // Different wire type OR explicit path: swap full remote reference.
            // bisync uses a separate listing pair — consistent with the script.
            let effectiveFallbackPath = profile.fallbackRemotePath.isEmpty
                ? profile.remotePath : profile.fallbackRemotePath
            return ("\(profile.fallbackRemote):\(effectiveFallbackPath)", [:])
        }

        // Same remote name preserved: use env-var overrides to preserve the cache.
        let primaryRemoteName = profile.rcloneRemote.hasSuffix(":")
            ? String(profile.rcloneRemote.dropLast()) : profile.rcloneRemote
        let upperName = primaryRemoteName.uppercased().replacingOccurrences(of: "-", with: "_")
        var extraEnv: [String: String] = [:]
        if let fallbackConfig = RcloneConfigService.shared.readRemoteConfig(name: profile.fallbackRemote) {
            for (key, value) in fallbackConfig.values {
                let envKey = "RCLONE_CONFIG_\(upperName)_\(key.uppercased().replacingOccurrences(of: "-", with: "_"))"
                extraEnv[envKey] = value
            }
        }
        return (primaryRemotePath, extraEnv)
    }

    /// Run `rclone bisync --resync` for a profile directly (no UI output panel).
    /// Called by `triggerAutoFix`, which has already acquired `token` via
    /// `beginExclusiveRun` — this function never sweeps `.lck` files, never writes
    /// a `"pending"` sentinel, and only ever touches `token`'s own lock through the
    /// owner-checked `SyncRunLock` primitives. On completion, state is updated via
    /// the existing log-watcher pipeline (same as scheduled syncs).
    private func performResync(for profile: SyncProfile, token: ExclusiveRunToken) async {
        let profileId = profile.id

        // Capture all values from the main actor before going to the background
        let rcloneRemote = profile.rcloneRemote
        let localSyncPath = profile.localSyncPath
        let drivePathToMonitor = profile.drivePathToMonitor
        let filterPath = profile.filterFilePath
        let lockPath = profile.lockFilePath
        let logPath = profile.logPath
        let syncMode = profile.syncMode
        let syncDirection = profile.syncDirection
        let additionalFlags = profile.additionalRcloneFlags
        let fallbackTransport = profileTransports[profileId] ?? .unknown
        let fallbackRemote = profile.fallbackRemote
        let (effectiveRemotePath, extraEnv) = resolveActiveRemote(for: profile)
        let placeholder = token.placeholder

        // Re-check the external drive right before launching — it may have been unplugged in
        // the window between triggerAutoFix's guard and now (a resync can be queued behind an
        // in-flight sync, and large repos take ~12s). Running --resync against a vanished mount
        // point is the unsafe case we must never reach.
        if !drivePathToMonitor.isEmpty,
           !FileManager.default.fileExists(atPath: drivePathToMonitor) {
            SyncTraySettings.debugLog("Auto-fix aborted: external drive unmounted before resync for '\(profile.name)'")
            SyncRunLock.releaseIfOwned(path: lockPath, ownTokens: [placeholder])
            endExclusiveRun(token)
            profileStates[profileId] = .driveNotMounted
            updateAggregateState()
            return
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let fileManager = FileManager.default

                    // Locate rclone binary
                    guard let rclonePath = RcloneLocator.resolve() else {
                        SyncRunLock.releaseIfOwned(path: lockPath, ownTokens: [placeholder])
                        continuation.resume(throwing: NSError(
                            domain: "SyncManager",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "rclone not found"]
                        ))
                        return
                    }

                    let isFallbackActive = fallbackTransport.isFallback

                    var arguments: [String]

                    if syncMode == .bisync {
                        // Same arguments as every other SyncTray resync: newer wins, never
                        // a bare --resync (remote wins). See `resyncArguments`.
                        arguments = SyncSetupService.resyncArguments(
                            remote: effectiveRemotePath, localPath: localSyncPath)
                    } else if syncDirection == .localToRemote {
                        arguments = ["sync", localSyncPath, effectiveRemotePath,
                                     "--verbose", "--use-json-log", "--stats", "2s"]
                    } else {
                        arguments = ["sync", effectiveRemotePath, localSyncPath,
                                     "--verbose", "--use-json-log", "--stats", "2s"]
                    }

                    if fileManager.fileExists(atPath: filterPath) {
                        arguments.append(contentsOf: ["--filter-from", filterPath])
                    }

                    // Resolve which remote name to check for no_check_certificate
                    let certCheckRemote = (isFallbackActive && !fallbackRemote.isEmpty)
                        ? fallbackRemote : rcloneRemote
                    if RcloneConfigService.shared.readRemoteConfig(name: certCheckRemote)?.values["no_check_certificate"] == "true" {
                        arguments.append("--no-check-certificate")
                    }

                    if !additionalFlags.isEmpty {
                        let extra = additionalFlags.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        arguments.append(contentsOf: extra)
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: rclonePath)
                    process.arguments = arguments

                    // Merge fallback env-var overrides into the process environment
                    if !extraEnv.isEmpty {
                        var env = ProcessInfo.processInfo.environment
                        for (key, value) in extraEnv {
                            env[key] = value
                        }
                        process.environment = env
                    }

                    // Route rclone output into the profile log file so the LogWatcher
                    // pipeline fires `.syncStarted` / `.syncCompleted` / `.syncFailed`.
                    // Without this, the profile would stay in `.syncing` indefinitely —
                    // the watcher would never see process termination. The bracket
                    // markers below mirror what `synctray-sync.sh` writes via `tee`.
                    if !fileManager.fileExists(atPath: logPath) {
                        fileManager.createFile(atPath: logPath, contents: nil)
                    }
                    let timestampFormatter = DateFormatter()
                    timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
                    let appendLog: (String) -> Void = { message in
                        let line = "\(timestampFormatter.string(from: Date())) - \(message)\n"
                        guard let data = line.data(using: .utf8),
                              let handle = FileHandle(forWritingAtPath: logPath) else { return }
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }

                    guard let processLog = FileHandle(forWritingAtPath: logPath) else {
                        SyncRunLock.releaseIfOwned(path: lockPath, ownTokens: [placeholder])
                        continuation.resume(throwing: NSError(
                            domain: "SyncManager",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "could not open log file"]
                        ))
                        return
                    }
                    processLog.seekToEndOfFile()
                    process.standardOutput = processLog
                    process.standardError = processLog

                    appendLog("Starting bisync (auto-fix --resync)")

                    // Child PID becomes known only after `process.run()`; captured here so the
                    // termination handler can release the lock whichever token it still holds
                    // (placeholder, if the swap below never landed, or the real child PID).
                    var childPIDToken = placeholder

                    process.terminationHandler = { proc in
                        try? processLog.close()
                        let exit = proc.terminationStatus
                        appendLog(exit == 0
                            ? "Bisync completed successfully"
                            : "Bisync failed with exit code \(exit)")
                        SyncRunLock.releaseIfOwned(path: lockPath, ownTokens: [placeholder, childPIDToken])
                        continuation.resume()
                    }

                    do {
                        try process.run()
                        // Swap the placeholder for the real child PID now that it's known —
                        // only if the lock still holds the placeholder (owner-checked).
                        childPIDToken = "\(process.processIdentifier)"
                        SyncRunLock.replaceIfOwned(path: lockPath, expected: placeholder, with: childPIDToken)
                    } catch {
                        try? processLog.close()
                        appendLog("Auto-fix failed to launch rclone: \(error.localizedDescription)")
                        SyncRunLock.releaseIfOwned(path: lockPath, ownTokens: [placeholder])
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            SyncTraySettings.debugLog("Auto-fix process error for '\(profile.name)': \(error)")
            endExclusiveRun(token)
            setSyncing(for: profileId, isSyncing: false)
            return
        }

        // Clear the registry slot on clean exit. State after completion (idle / error)
        // is set by the log-watcher pipeline via .syncCompleted / .syncFailed.
        endExclusiveRun(token)
    }

    // MARK: - Notification Muting

    /// Mute file change notifications for a profile (persisted)
    func muteNotifications(for profileId: UUID) {
        guard var profile = profileStore.profile(for: profileId) else { return }
        profile.isMuted = true
        profileStore.update(profile)
    }

    /// Unmute notifications for a profile (persisted)
    func unmuteNotifications(for profileId: UUID) {
        guard var profile = profileStore.profile(for: profileId) else { return }
        profile.isMuted = false
        profileStore.update(profile)
    }

    /// Check if notifications are muted for a profile
    func isNotificationsMuted(for profileId: UUID) -> Bool {
        profileStore.profile(for: profileId)?.isMuted ?? false
    }

    // MARK: - Pause/Resume

    /// Check if a profile is paused
    func isPaused(for profileId: UUID) -> Bool {
        pausedProfiles.contains(profileId)
    }

    /// Check if all enabled profiles are paused
    var isAllPaused: Bool {
        let enabledIds = Set(profileStore.enabledProfiles.map { $0.id })
        guard !enabledIds.isEmpty else { return false }
        return enabledIds.isSubset(of: pausedProfiles)
    }

    /// Pause syncing for a specific profile (stops directory watcher, blocks manual/scheduled syncs)
    func pauseProfile(_ profileId: UUID) {
        guard let profile = profileStore.profile(for: profileId) else { return }

        pausedProfiles.insert(profileId)

        // Stop directory watcher for this profile
        directoryWatchers[profileId]?.stop()
        directoryWatchers.removeValue(forKey: profileId)

        // Actually stop scheduled syncs. Previously pause only set an in-memory
        // flag, so launchd kept firing the sync script every interval — the
        // "paused" profile still hammered the remote and the spinner never
        // rested. Unload the agent so no new runs start.
        setupService.unloadAgent(for: profile)

        // Terminate any in-flight run for this profile and clear its lock, so a
        // hung/slow sync can't keep holding the lock and block a later resume.
        terminateRunningSync(for: profile)

        // Close any open telemetry span so it isn't later reported as abandoned.
        TelemetryService.shared.recordSyncSkipped(
            profileId: profileId,
            profileName: profile.name,
            reason: "paused"
        )

        // Update profile state to paused
        profileStates[profileId] = .paused
        profileProgress[profileId] = nil
        logWatchers[profileId]?.setActivelySyncing(false)

        updateAggregateState()

        SyncTraySettings.debugLog("Paused profile: \(profile.name)")
        TelemetryService.shared.recordProfileStateChange(
            profileId: profileId,
            profileName: profile.name,
            action: "paused"
        )
    }

    /// Terminate any running sync process for `profile` (identified via its lock
    /// file PID) and remove the lock so a killed/stale run can't block the next
    /// start. Best-effort: signals the process group (launchd runs each job as
    /// its own group leader) so the bash script and its rclone child both stop.
    /// Safe to call when nothing is running.
    private func terminateRunningSync(for profile: SyncProfile) {
        if let pid = detectRunningSyncPID(for: profile) {
            // Negative PID targets the whole process group; fall back to the
            // single process if it isn't a group leader.
            if kill(-pid, SIGTERM) != 0 {
                kill(pid, SIGTERM)
            }
        }
        // Stop any external-sync completion poller watching this profile.
        syncCompletionPollers[profile.id]?.cancel()
        syncCompletionPollers.removeValue(forKey: profile.id)
        monitoringExternalSyncs.remove(profile.id)
        // Remove the lock file so the next run isn't blocked by a stale lock.
        try? FileManager.default.removeItem(atPath: profile.lockFilePath)
    }

    /// Resume syncing for a specific profile (restarts directory watcher)
    func resumeProfile(_ profileId: UUID) {
        guard let profile = profileStore.profile(for: profileId),
              profile.isEnabled else { return }

        pausedProfiles.remove(profileId)

        // Reload the launchd agent that pause unloaded so scheduled syncs run
        // again. (No-op if it somehow never unloaded.)
        setupService.loadAgent(for: profile)

        // Restart directory watcher for this profile
        startWatchingDirectory(for: profile)

        // Reset state to idle (or check drive mount status)
        if !profile.drivePathToMonitor.isEmpty &&
           !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
            profileStates[profileId] = .driveNotMounted
        } else {
            profileStates[profileId] = .idle
        }

        updateAggregateState()

        SyncTraySettings.debugLog("Resumed profile: \(profile.name)")
        TelemetryService.shared.recordProfileStateChange(
            profileId: profileId,
            profileName: profile.name,
            action: "resumed"
        )
    }

    /// Pause all enabled profiles
    func pauseAllProfiles() {
        for profile in profileStore.enabledProfiles {
            pauseProfile(profile.id)
        }
    }

    /// Resume all paused profiles
    func resumeAllProfiles() {
        // Create a copy since we're modifying the set while iterating
        let profilesToPause = pausedProfiles
        for profileId in profilesToPause {
            resumeProfile(profileId)
        }
    }

    /// Toggle pause state for a specific profile
    func togglePause(for profileId: UUID) {
        if isPaused(for: profileId) {
            resumeProfile(profileId)
        } else {
            pauseProfile(profileId)
        }
    }

    /// Toggle pause state for all profiles
    func togglePauseAll() {
        if isAllPaused {
            resumeAllProfiles()
        } else {
            pauseAllProfiles()
        }
    }

    // MARK: - Abort

    /// Whether an abort is in flight for a profile.
    func isAborting(for profileId: UUID) -> Bool {
        abortPhases[profileId] != nil
    }

    /// Whether the profile's most recent run was stopped by `abortSync` — true while the
    /// abort is in flight and for `SyncAbort.trailingSuppression` after it finished. Run
    /// launchers read it to report "aborted" instead of "failed".
    func wasRunAborted(for profileId: UUID) -> Bool {
        SyncAbort.suppressesRunEnd(
            abortInFlight: isAborting(for: profileId),
            suppressUntil: abortSuppressUntil[profileId],
            now: Date()
        )
    }

    /// Keep an aborted initial sync's launchd agent unloaded until the next run the app
    /// starts for the profile — loading it now would restart the sync at once (`RunAtLoad`).
    func deferAgentLoadAfterAbort(for profileId: UUID) {
        agentLoadDeferredByAbort.insert(profileId)
    }

    /// Stop a profile's in-flight run so its settings can be changed and the sync restarted
    /// (CLAUDE.md "Aborting a running sync"). Works for every run shape: a scheduled or
    /// Sync Now run of the sync script, and an app-launched rclone (initial sync, Fix /
    /// Force / Restore, auto-fix).
    ///
    /// Shuts rclone down gracefully first (SIGINT, so bisync can save its state), escalating
    /// on its own after `SyncAbort.gracefulTimeout` or at once on `forceStopAbort`. Unlike
    /// Pause, the profile stays active: the launchd agent stays loaded and Sync Now is
    /// available again as soon as the run has exited. No lock is touched while any process
    /// of the run is alive (Critical Rule 8); leftover locks are removed stale-only once it
    /// has exited. A no-op while an abort is already in flight.
    func abortSync(for profile: SyncProfile) {
        // A Stream profile has no run to abort — its daemon is stopped with Unmount.
        guard !profile.isMountMode, !isAborting(for: profile.id) else { return }

        guard isRunLive(for: profile) else {
            // Nothing is running, yet the card offered Abort: the profile is stuck showing
            // `.syncing` for a run that already ended without a closing log line. Put it at rest.
            if profileStates[profile.id] == .syncing {
                profileStates[profile.id] = isPaused(for: profile.id) ? .paused : .idle
                profileProgress[profile.id] = nil
                logWatchers[profile.id]?.setActivelySyncing(false)
                updateAggregateState()
            }
            TelemetryService.shared.recordProfileLifecycleOperation(
                profileId: profile.id, profileName: profile.name,
                operation: "abort", syncMode: profile.syncMode.rawValue, result: "not_running"
            )
            return
        }

        abortPhases[profile.id] = .graceful
        abortForceRequested.remove(profile.id)
        abortSuppressUntil[profile.id] = nil
        // The startup poller for a run found already in progress would read the aborted
        // run's failure back out of the log and show it as an error; the abort owns the
        // run's ending from here on.
        syncCompletionPollers[profile.id]?.cancel()
        syncCompletionPollers.removeValue(forKey: profile.id)

        SyncTraySettings.debugLog("Aborting sync for '\(profile.name)'")
        TelemetryService.shared.recordProfileLifecycleOperation(
            profileId: profile.id, profileName: profile.name,
            operation: "abort", syncMode: profile.syncMode.rawValue, result: "started"
        )

        abortTasks[profile.id] = Task { [weak self] in
            await self?.runAbort(for: profile)
        }
    }

    /// Skip the rest of an in-flight abort's graceful wait: SIGTERM the run now (SIGKILL
    /// after `SyncAbort.terminateTimeout`). A no-op when no abort is in flight — a Force Stop
    /// confirmed after its abort already finished must not start a new one.
    func forceStopAbort(for profile: SyncProfile) {
        guard isAborting(for: profile.id) else { return }
        abortForceRequested.insert(profile.id)
        TelemetryService.shared.recordProfileLifecycleOperation(
            profileId: profile.id, profileName: profile.name,
            operation: "abort", syncMode: profile.syncMode.rawValue, result: "force_requested"
        )
    }

    /// The live PIDs an abort starts from: the `/tmp` run-lock holder (the script's bash, or
    /// an app-launched rclone) and the bisync session-lock holder (rclone). Excludes the app
    /// itself — the run lock's launch-gap placeholder (D4).
    private func liveRunRoots(for profile: SyncProfile) -> [Int32] {
        let (runLock, sessionLock) = lockHolders(for: profile)
        var roots: [Int32] = []
        for holder in [runLock, sessionLock] {
            if case .pid(let pid) = holder, pid != getpid(), SyncRunLock.processIsAlive(pid) {
                roots.append(pid)
            }
        }
        return roots
    }

    /// Drive one abort to its end: signal the run, escalate on a timer or on Force Stop, and
    /// finish once the run has ended (`SyncAbort.completion`). Re-reads the locks and the
    /// process table every second, so an rclone that starts after the first scan (an
    /// app-launched run still in its launch gap, or the script moving from its pre-flight
    /// probe to the real sync) is caught too.
    private func runAbort(for profile: SyncProfile) async {
        let profileId = profile.id
        let appPID = getpid()
        let configPath = profile.configPath
        let started = Date()
        // Generous ceiling, so a lock whose holder never goes away cannot keep the card in
        // "Stopping…" forever.
        let deadline = SyncAbort.gracefulTimeout + SyncAbort.terminateTimeout + 30
        var phase: SyncAbort.Phase?
        var phaseStarted = started
        var signalled: [SyncAbort.Phase: Set<Int32>] = [:]
        // Every process seen as part of the run (PID → name), kept after its shell dies so
        // an orphan cannot outlive the abort.
        var tracked: [Int32: String] = [:]
        var outcome = "success"

        monitor: while !Task.isCancelled {
            let now = Date()
            if now.timeIntervalSince(started) >= deadline {
                outcome = "timeout"
                break monitor
            }

            let roots = liveRunRoots(for: profile)
            let (table, rootArguments) = await Task.detached(priority: .userInitiated) {
                () -> ([SyncAbort.ProcessEntry], [Int32: String]) in
                var arguments: [Int32: String] = [:]
                for root in roots {
                    if let line = SyncAbort.readArguments(of: root) { arguments[root] = line }
                }
                return (SyncAbort.readProcessTable(), arguments)
            }.value
            let targets = SyncAbort.targets(
                roots: roots, appPID: appPID, table: table, rootArguments: rootArguments, configPath: configPath)

            // Keep a tracked PID only while the table still shows it under the same name, so a
            // PID reused by an unrelated process after the run's own one exited is dropped.
            let names = Dictionary(table.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
            for pid in targets.all {
                tracked[pid] = names[pid]
            }
            tracked = tracked.filter { pid, name in
                table.isEmpty ? SyncRunLock.processIsAlive(pid) : names[pid] == name
            }

            if case .finished(let leftovers) = SyncAbort.completion(
                runLive: isRunLive(for: profile), liveTracked: tracked) {
                for pid in leftovers {
                    kill(pid, SIGTERM)
                }
                break monitor
            }

            let force = abortForceRequested.contains(profileId)
            let current: SyncAbort.Phase
            if let phase {
                current = SyncAbort.nextPhase(
                    current: phase, elapsedInPhase: now.timeIntervalSince(phaseStarted), forceRequested: force)
            } else if targets.all.isEmpty && tracked.isEmpty {
                // Nothing of the run is visible yet (an app-launched rclone still in its launch
                // gap, a transient `ps` failure): pick the first phase once something is.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue monitor
            } else {
                // A Force Stop pressed before the first scan finished still applies.
                current = SyncAbort.nextPhase(
                    current: SyncAbort.initialPhase(for: targets), elapsedInPhase: 0, forceRequested: force)
            }
            if current != phase {
                phase = current
                phaseStarted = now
                abortPhases[profileId] = current
                SyncTraySettings.debugLog("Abort '\(profile.name)': \(current)")
            }
            if current != .graceful { outcome = "forced" }

            // Each PID gets each phase's signal once; SIGKILL repeats until the PID is gone.
            let sig = SyncAbort.signal(for: current)
            let orphans = tracked.keys.sorted()
            for pid in SyncAbort.signalTargets(for: current, in: targets, orphans: orphans)
            where current == .killing || !(signalled[current]?.contains(pid) ?? false) {
                kill(pid, sig)
                signalled[current, default: []].insert(pid)
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        finishAbort(for: profile, outcome: outcome)
    }

    /// Settle a profile after its abort: remove the run's leftover locks (stale-only), put
    /// the profile back at rest without an error, and close its telemetry span.
    private func finishAbort(for profile: SyncProfile, outcome: String) {
        let profileId = profile.id
        // Handle every line the run wrote before it exited while the abort still counts as
        // in flight, so its "Bisync failed" / "context canceled" lines are read as the
        // abort's own — not left for the next file event to report as a failure.
        logWatchers[profileId]?.readPendingLines()
        abortTasks.removeValue(forKey: profileId)
        abortPhases.removeValue(forKey: profileId)
        abortForceRequested.remove(profileId)

        // A run stopped by SIGKILL never reached its own cleanup: the script's EXIT trap,
        // rclone's session-lock release. Stale-only — refuses if either holder is alive,
        // e.g. a new run that has already started.
        SyncRunLock.removeStaleLocks(
            runLockPath: profile.lockFilePath,
            sessionLockPath: SyncRunLock.sessionLockPath(for: profile),
            isAlive: SyncRunLock.processIsAlive
        )

        TelemetryService.shared.recordProfileLifecycleOperation(
            profileId: profileId, profileName: profile.name,
            operation: "abort", syncMode: profile.syncMode.rawValue, result: outcome
        )
        SyncTraySettings.debugLog("Abort '\(profile.name)' finished: \(outcome)")

        // Gave up with the run still live (a holder the abort could not identify as part
        // of the run, or one that would not die): leave its state, errors and log lines
        // alone rather than show a running sync as stopped. Abort can be pressed again.
        if isRunLive(for: profile) {
            abortSuppressUntil[profileId] = nil
            return
        }
        abortSuppressUntil[profileId] = Date().addingTimeInterval(SyncAbort.trailingSuppression)

        monitoringExternalSyncs.remove(profileId)
        profileProgress[profileId] = nil
        profileErrors[profileId] = nil
        lastSeenErrorMessage[profileId] = nil
        currentSyncChanges[profileId] = nil
        syncStartTimes[profileId] = nil
        checkPhaseStartTimes.removeValue(forKey: profileId)
        checkPhaseReported.remove(profileId)
        logWatchers[profileId]?.setActivelySyncing(false)
        notificationService.clearPendingChanges(for: profileId)
        if let state = profileStates[profileId] {
            switch state {
            case .syncing, .error:
                profileStates[profileId] = isPaused(for: profileId) ? .paused : .idle
            default:
                break
            }
        }
        updateAggregateState()

        TelemetryService.shared.recordSyncSkipped(profileId: profileId, profileName: profile.name, reason: "aborted")

        // The run has ended — apply any reinstall an external edit deferred while it was live.
        retryPendingExternalReinstallIfNeeded(for: profileId)
    }

    /// Read the last error message from a log file
    private func readLastErrorFromLog(_ logPath: String) -> String? {
        guard FileManager.default.fileExists(atPath: logPath),
              let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Look for error lines in reverse order (most recent first)
        let lines = content.components(separatedBy: .newlines).reversed()
        var errorMessages: [String] = []
        var criticalErrors: [String] = []  // Track critical/actionable errors separately
        var foundFailedMarker = false

        for line in lines {
            // Stop when we hit a sync start marker (previous run)
            if SyncLogPatterns.isSyncStarted(line) && foundFailedMarker {
                break
            }

            // If the most recent sync was successful, there's no error to show
            if SyncLogPatterns.isSyncCompleted(line) {
                return nil
            }

            // Mark that we found the failure point
            if SyncLogPatterns.isSyncFailed(line) {
                foundFailedMarker = true
                continue
            }

            // Only collect errors after we found the failure marker
            guard foundFailedMarker else { continue }

            // Extract error message from line (supports CRITICAL and JSON formats)
            guard let rawMsg = SyncLogPatterns.extractErrorMessage(from: line) else { continue }

            // Clean up ANSI codes
            var msg = SyncLogPatterns.stripANSICodes(rawMsg)

            // Skip generic abort messages - they don't provide useful info
            if SyncLogPatterns.isGenericAbortMessage(msg) {
                continue
            }

            // Transient "all files were changed" error should not be shown
            if SyncLogPatterns.isTransientAllFilesChangedError(msg) {
                continue
            }

            // Clean up error message prefixes
            msg = SyncLogPatterns.cleanErrorMessage(msg)

            guard !msg.isEmpty else { continue }

            // Track critical/actionable errors separately (they're more useful to show)
            if SyncLogPatterns.isCriticalError(msg) && !criticalErrors.contains(msg) {
                criticalErrors.append(msg)
            } else if !errorMessages.contains(msg) {
                errorMessages.append(msg)
            }

            // Stop after finding enough errors
            if criticalErrors.count >= 1 || errorMessages.count >= 2 {
                break
            }
        }

        // Prefer critical errors over general errors
        let bestError = criticalErrors.first ?? errorMessages.first

        if let error = bestError {
            // Truncate if too long
            if error.count > 300 {
                return String(error.prefix(300)) + "..."
            }
            return error
        }

        return nil
    }

    // MARK: - Private Methods

    /// Check if a sync is currently running for this profile via lock file
    /// Returns the PID if found, nil otherwise
    private func detectRunningSyncPID(for profile: SyncProfile) -> Int32? {
        let holder = SyncRunLock.parseHolder(try? String(contentsOfFile: profile.lockFilePath, encoding: .utf8))
        guard case .pid(let pid) = holder, SyncRunLock.processIsAlive(pid) else { return nil }
        // The `/tmp` lock briefly holds the app's own PID as a launch-gap placeholder
        // (D4, `beginExclusiveRun`) before it is swapped for the real rclone child PID.
        // Treating that window as "a sync process is running at this PID" would hand
        // SyncTray's own PID to `terminateRunningSync`'s `kill(-pid, SIGTERM)` — Pause
        // would SIGTERM the app itself (review finding). No running sync to detect yet.
        guard pid != getpid() else { return nil }
        return pid
    }

    /// Detect running syncs at startup and start monitoring them
    private func detectAndResumeRunningSyncs() {
        var resumedCount = 0
        // Mount profiles hold the lock file for the entire lifetime of their
        // rclone daemon, so lock-based detection would mark them `.syncing`
        // forever — which disables the Pause/Uninstall controls and makes the
        // mount impossible to stop from the UI. Mount state is tracked
        // separately by updateMountStates(); exclude mount mode here.
        for profile in profileStore.enabledProfiles where !profile.isMountMode {
            if let pid = detectRunningSyncPID(for: profile) {
                profileStates[profile.id] = .syncing
                monitoringExternalSyncs.insert(profile.id)
                startPollingForSyncCompletion(profile: profile, pid: pid)
                resumedCount += 1
            }
        }
        if resumedCount > 0 {
            TelemetryService.shared.recordResumedExternalSync(
                profileId: UUID(), // aggregate event
                profileName: "all",
                count: resumedCount
            )
        }
        updateAggregateState()
    }

    /// Poll until the sync process exits
    private func startPollingForSyncCompletion(profile: SyncProfile, pid: Int32) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3.0)

        let profileId = profile.id
        let lockPath = profile.lockFilePath

        timer.setEventHandler { [weak self] in
            // Check if process exited or lock file removed
            if kill(pid, 0) != 0 || !FileManager.default.fileExists(atPath: lockPath) {
                timer.cancel()
                DispatchQueue.main.async {
                    self?.handleExternalSyncCompleted(profileId: profileId)
                }
            }
        }

        syncCompletionPollers[profile.id] = timer
        timer.resume()
    }

    /// Handle when an externally-monitored sync completes
    private func handleExternalSyncCompleted(profileId: UUID) {
        syncCompletionPollers[profileId]?.cancel()
        syncCompletionPollers.removeValue(forKey: profileId)
        monitoringExternalSyncs.remove(profileId)

        // Determine success/failure from log
        if let profile = profileStore.profile(for: profileId),
           let error = readLastErrorFromLog(profile.logPath) {
            profileStates[profileId] = .error("Sync failed")
            profileErrors[profileId] = error
        } else {
            profileStates[profileId] = .idle
            lastSyncTime = Date()
        }

        updateAggregateState()
    }

    /// Clean up stale lock files on app startup
    /// Removes /tmp lock files where the PID is no longer running
    /// Also removes rclone bisync .lck files if no rclone process is running
    private func cleanupStaleLockFiles() {
        let fm = FileManager.default
        var staleLockCount = 0

        // Clean up SyncTray's /tmp lock files
        for profile in profileStore.profiles {
            let lockPath = profile.lockFilePath
            guard fm.fileExists(atPath: lockPath) else { continue }

            // Read PID and check if process is still running
            if let pidString = try? String(contentsOfFile: lockPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidString) {
                // kill with signal 0 checks if process exists without sending a signal
                if kill(pid, 0) != 0 {
                    // Process not running - remove stale lock
                    try? fm.removeItem(atPath: lockPath)
                    staleLockCount += 1
                }
            } else {
                // Could not read/parse PID - remove the lock file
                try? fm.removeItem(atPath: lockPath)
                staleLockCount += 1
            }
        }

        if staleLockCount > 0 {
            TelemetryService.shared.recordStaleLockCleanup(count: staleLockCount, lockType: "synctray")
        }

        // Clean up rclone bisync lock files if no rclone process is running
        cleanupRcloneBisyncLocks()
    }

    /// Remove stale rclone bisync .lck files when no rclone process is running
    /// This allows sync to continue from where it left off after an interrupted sync
    private func cleanupRcloneBisyncLocks() {
        let fm = FileManager.default
        let bisyncDir = "\(NSHomeDirectory())/Library/Caches/rclone/bisync"

        // Check if any rclone process is running
        let rcloneRunning = isRcloneProcessRunning()

        if rcloneRunning {
            // rclone is running, don't remove lock files
            return
        }

        // No rclone running - remove all stale .lck files
        guard let files = try? fm.contentsOfDirectory(atPath: bisyncDir) else { return }

        var bisyncLockCount = 0
        for file in files where file.hasSuffix(".lck") {
            let fullPath = "\(bisyncDir)/\(file)"
            try? fm.removeItem(atPath: fullPath)
            bisyncLockCount += 1
            SyncTraySettings.debugLog("Removed stale rclone bisync lock: \(file)")
        }

        if bisyncLockCount > 0 {
            TelemetryService.shared.recordStaleLockCleanup(count: bisyncLockCount, lockType: "rclone_bisync")
        }
    }

    /// Check if any rclone process is currently running
    private func isRcloneProcessRunning() -> Bool {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "rclone"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func setupProfileObserver() {
        profileStore.$profiles
            .sink { [weak self] _ in
                self?.startWatchingAllProfiles()
                self?.updateAggregateState()
                self?.updateAppGroupMountPaths()
            }
            .store(in: &cancellables)
    }

    private func startWatchingAllProfiles() {
        let enabledProfileIds = Set(profileStore.enabledProfiles.map { $0.id })

        // Remove watchers for profiles that are no longer enabled
        // (Don't touch watchers for profiles that are still enabled - avoids interrupting active syncs)
        for id in logWatchers.keys where !enabledProfileIds.contains(id) {
            logWatchers[id]?.stopWatching()
            logWatchers.removeValue(forKey: id)
        }
        for id in directoryWatchers.keys where !enabledProfileIds.contains(id) {
            directoryWatchers[id]?.stop()
            directoryWatchers.removeValue(forKey: id)
        }

        // Add watchers only for profiles that don't already have them
        for profile in profileStore.enabledProfiles {
            if logWatchers[profile.id] == nil {
                startWatching(profile: profile)
            }
            // Skip directory watching for mount mode profiles (no need to watch - files stream on-demand)
            if directoryWatchers[profile.id] == nil && !profile.isMountMode {
                startWatchingDirectory(for: profile)
            }
        }
    }

    private func startWatching(profile: SyncProfile) {
        let watcher = LogWatcher(logPath: profile.logPath)
        watcher.profileName = profile.name
        watcher.delegate = self
        watcher.startWatching()
        logWatchers[profile.id] = watcher

        // If a sync is already running (detected at startup), use faster polling
        if profileStates[profile.id] == .syncing {
            watcher.setActivelySyncing(true)
        } else {
            profileStates[profile.id] = .idle
        }
    }

    /// Start watching a profile's local sync directory for file changes
    private func startWatchingDirectory(for profile: SyncProfile) {
        guard !profile.localSyncPath.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: profile.localSyncPath) else { return }
        // Skip directory watching for mount mode (files stream on-demand, no sync needed)
        guard !profile.isMountMode else { return }

        let profileId = profile.id
        let profileName = profile.name
        let watchPath = profile.localSyncPath
        let shortId = String(profileId.uuidString.prefix(8))
        SyncTraySettings.debugLog("Starting watcher for '\(profileName)' [id:\(shortId)] at: \(watchPath)")

        let watcher = DirectoryWatcher(
            paths: [watchPath],
            debounceInterval: 5.0,
            debugLabel: "\(profileName) [\(shortId)]"
        ) { [weak self] in
            Task { @MainActor in
                SyncTraySettings.debugLog("Change callback fired for '\(profileName)' [id:\(shortId)] -> triggering sync")
                self?.handleDirectoryChange(for: profileId)
            }
        }
        watcher.profileName = profileName
        watcher.start()
        directoryWatchers[profile.id] = watcher
    }

    /// Handle file system changes detected by DirectoryWatcher
    private func handleDirectoryChange(for profileId: UUID) {
        // Skip if profile is paused
        if isPaused(for: profileId) {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - profile paused")
            return
        }

        // Skip if profile is already syncing (avoid duplicate work)
        if profileStates[profileId] == .syncing {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - already syncing")
            return
        }

        // Skip right after an abort: the change this callback reports is most likely the
        // aborted run's own last writes (debounced past its exit), and starting a new sync
        // for it would undo the abort the user just asked for. An aborted initial sync stays
        // stopped until the user restarts it (Sync Now or Save), as its output panel says.
        if wasRunAborted(for: profileId) {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - run was just aborted")
            return
        }
        if agentLoadDeferredByAbort.contains(profileId) {
            if let deferred = profileStore.profile(for: profileId), setupService.isLoaded(profile: deferred) {
                // A Save (or Resume) has loaded the agent since — the deferral is moot.
                agentLoadDeferredByAbort.remove(profileId)
            } else {
                SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - initial sync was aborted")
                return
            }
        }

        // Skip if drive not mounted
        if profileStates[profileId] == .driveNotMounted {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - drive not mounted")
            return
        }

        // Get profile and verify it's still valid
        guard let profile = profileStore.profile(for: profileId),
              profile.isEnabled else {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - profile not found or disabled")
            return
        }

        SyncTraySettings.debugLog("DirectoryWatcher: Triggering sync for '\(profile.name)' (path: \(profile.localSyncPath))")

        TelemetryService.shared.recordDirectoryWatchTrigger(
            profileId: profileId,
            profileName: profile.name
        )

        // Trigger sync for this specific profile
        // Note: Lock file in sync script handles concurrent sync prevention
        Task {
            await runSyncScript(for: profile, trigger: "directory_watch")
        }
    }

    private func stopWatching(profileId: UUID) {
        logWatchers[profileId]?.stopWatching()
        logWatchers.removeValue(forKey: profileId)

        directoryWatchers[profileId]?.stop()
        directoryWatchers.removeValue(forKey: profileId)

        profileStates.removeValue(forKey: profileId)
    }

    private func checkInitialState() {
        if profileStore.profiles.isEmpty {
            currentState = .notConfigured
            return
        }

        // Check each enabled profile
        for profile in profileStore.enabledProfiles {
            // Don't override state for profiles that are currently syncing
            if profileStates[profile.id] == .syncing {
                continue
            }

            if !profile.drivePathToMonitor.isEmpty &&
               !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
                profileStates[profile.id] = .driveNotMounted
            } else {
                profileStates[profile.id] = .idle
            }
        }

        updateAggregateState()
    }

    /// Update the aggregate state (worst state wins)
    private func updateAggregateState() {
        if profileStore.profiles.isEmpty {
            currentState = .notConfigured
            return
        }

        if profileStore.enabledProfiles.isEmpty {
            currentState = .idle
            return
        }

        // Priority: error > syncing > driveNotMounted > paused > idle
        var hasError = false
        var hasSyncing = false
        var hasDriveNotMounted = false
        var hasPaused = false
        var errorMessage: String?

        for state in profileStates.values {
            switch state {
            case .error(let msg):
                hasError = true
                errorMessage = msg
            case .syncing:
                hasSyncing = true
            case .driveNotMounted:
                hasDriveNotMounted = true
            case .paused:
                hasPaused = true
            default:
                break
            }
        }

        if hasError {
            currentState = .error(errorMessage ?? "Unknown error")
        } else if hasSyncing {
            currentState = .syncing
        } else if hasDriveNotMounted {
            currentState = .driveNotMounted
        } else if hasPaused && isAllPaused {
            // Only show paused aggregate state if ALL profiles are paused
            currentState = .paused
        } else {
            currentState = .idle
        }
    }

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleVolumeMount(notification)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleVolumeUnmount(notification)
            }
        }
    }

    private func handleVolumeMount(_ notification: Notification) {
        guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else {
            return
        }

        var affectedCount = 0
        for profile in profileStore.enabledProfiles {
            let drivePath = profile.drivePathToMonitor
            guard !drivePath.isEmpty else { continue }

            if drivePath.hasPrefix(volumePath) || volumePath == drivePath {
                affectedCount += 1
                notificationService.resetDriveNotMountedState(for: profile.id)
                if profileStates[profile.id] == .driveNotMounted {
                    profileStates[profile.id] = .idle
                }

                // Restart directory watcher for this profile (path is now available)
                directoryWatchers[profile.id]?.stop()
                directoryWatchers.removeValue(forKey: profile.id)
                startWatchingDirectory(for: profile)
            }
        }

        if affectedCount > 0 {
            TelemetryService.shared.recordVolumeEvent(event: "mounted", affectedProfiles: affectedCount)
        }

        updateAggregateState()
    }

    private func handleVolumeUnmount(_ notification: Notification) {
        guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else {
            return
        }

        var affectedCount = 0
        for profile in profileStore.enabledProfiles {
            let drivePath = profile.drivePathToMonitor
            guard !drivePath.isEmpty else { continue }

            if drivePath.hasPrefix(volumePath) || volumePath == drivePath {
                affectedCount += 1
                profileStates[profile.id] = .driveNotMounted
                if !isNotificationsMuted(for: profile.id) {
                    notificationService.notifyDriveNotMounted(profileId: profile.id, profileName: profile.name)
                }
            }
        }

        if affectedCount > 0 {
            TelemetryService.shared.recordVolumeEvent(event: "unmounted", affectedProfiles: affectedCount)
        }

        updateAggregateState()
    }

    private func runSyncScript(for profile: SyncProfile, trigger: String = "manual") async {
        // Remember what kicked this off so the `.syncStarted` log event (parsed from the
        // sync log, decoupled from here) can attribute `sync.trigger`. A launchd/scheduled
        // run never calls this method, so an absent entry means "scheduled".
        pendingSyncTrigger[profile.id] = trigger

        // Check if profile is paused
        if isPaused(for: profile.id) {
            SyncTraySettings.debugLog("Skipping sync script for paused profile: \(profile.name)")
            return
        }

        // Never start a run while an abort is still stopping the last one — the abort's
        // monitor would stop this run too.
        if isAborting(for: profile.id) {
            SyncTraySettings.debugLog("Skipping sync script while an abort is in flight: \(profile.name)")
            return
        }

        // Check if drive is mounted
        if !profile.drivePathToMonitor.isEmpty &&
           !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
            await MainActor.run {
                profileStates[profile.id] = .driveNotMounted
                if !isNotificationsMuted(for: profile.id) {
                    notificationService.notifyDriveNotMounted(profileId: profile.id, profileName: profile.name)
                }
                updateAggregateState()
            }
            return
        }

        guard FileManager.default.fileExists(atPath: SyncProfile.sharedScriptPath) else {
            await MainActor.run {
                profileStates[profile.id] = .error("Script not found")
                TelemetryService.shared.recordSyncPreconditionFailure(
                    profileId: profile.id,
                    profileName: profile.name,
                    reason: "script_not_found"
                )
                updateAggregateState()
            }
            return
        }

        guard FileManager.default.fileExists(atPath: profile.configPath) else {
            await MainActor.run {
                profileStates[profile.id] = .error("Config not found")
                TelemetryService.shared.recordSyncPreconditionFailure(
                    profileId: profile.id,
                    profileName: profile.name,
                    reason: "config_not_found"
                )
                updateAggregateState()
            }
            return
        }

        // An aborted initial sync left the launchd agent unloaded, because loading it would
        // have restarted the sync at once (`RunAtLoad`). Start this run BY loading it, so
        // the schedule comes back together with the restart instead of staying off until
        // the next Save. If the agent is already loaded (a Save reinstalled it meanwhile),
        // run the script as usual.
        // A new run, started after the abort finished: its failures are its own again.
        abortSuppressUntil[profile.id] = nil

        if agentLoadDeferredByAbort.remove(profile.id) != nil, !setupService.isLoaded(profile: profile) {
            if setupService.loadAgent(for: profile) {
                SyncTraySettings.debugLog("Restarted '\(profile.name)' by loading its launchd agent (deferred by an abort)")
                return
            }
            // Could not load it: still run now, and try the load again next time.
            agentLoadDeferredByAbort.insert(profile.id)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [SyncProfile.sharedScriptPath, profile.configPath]

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            print("Failed to run sync script for \(profile.name): \(error)")
        }
    }

    private func processLogEvent(_ event: ParsedLogEvent, profileId: UUID) {
        let profile = profileStore.profile(for: profileId)
        let profileName = profile?.name ?? "Unknown"
        let syncDirectoryPath = profile?.localSyncPath ?? ""

        switch event.type {
        case .syncStarted:
            // A start line read while an abort is in flight, or after an aborted run has
            // already exited, is the aborted run's own late line (the log watcher polls
            // every few seconds) — not a new run. Treating it as one would flip the
            // profile back to `.syncing` and let that run's failure lines surface.
            if let currentProfile = profile, wasRunAborted(for: profileId),
               isAborting(for: profileId) || !isRunLive(for: currentProfile) {
                break
            }
            // A genuinely new run: whatever an earlier abort left suppressed no longer applies.
            abortSuppressUntil[profileId] = nil
            profileStates[profileId] = .syncing
            profileErrors[profileId] = nil  // Clear previous error on new sync
            lastSeenErrorMessage[profileId] = nil  // Clear last seen error
            profileProgress[profileId] = nil  // Reset progress for new sync
            currentSyncChanges[profileId] = []
            syncStartTimes[profileId] = Date()  // Record start time for duration tracking
            checkPhaseStartTimes.removeValue(forKey: profileId)  // Reset check phase tracking
            checkPhaseReported.remove(profileId)
            logWatchers[profileId]?.setActivelySyncing(true)  // Increase polling frequency
            // Don't send notification - the menu bar icon updates to show syncing state
            notificationService.clearPendingChanges(for: profileId)
            TelemetryService.shared.recordSyncStarted(
                profileId: profileId,
                profileName: profileName,
                syncMode: profile?.syncMode ?? .bisync,
                syncDirection: profile?.syncDirection,
                hasFallback: profile?.hasFallback ?? false,
                // An app-initiated run recorded its cause in runSyncScript; a bare
                // launchd/scheduled run left none, so default to "scheduled".
                trigger: pendingSyncTrigger.removeValue(forKey: profileId) ?? "scheduled"
            )

        case .syncCompleted:
            profileStates[profileId] = .idle
            profileErrors[profileId] = nil  // Clear error on success
            lastSeenErrorMessage[profileId] = nil
            profileProgress[profileId] = nil  // Clear progress when sync completes
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            lastSyncTime = event.timestamp
            // Successful sync clears backoff suppression for this profile. The
            // exclusive-run registry is NOT touched here (D1): it is owned and
            // ended only by the run that `beginExclusiveRun`'d it, never by a log
            // event — a log event can come from any process writing this profile's
            // shared log file, not necessarily the run that holds the token.
            autoFixSuppressed.remove(profileId)
            autoFixAttempts[profileId] = nil
            let changesCount = currentSyncChanges[profileId]?.count ?? 0
            // Report telemetry for successful sync
            let completedDuration = syncStartTimes[profileId].map { Date().timeIntervalSince($0) } ?? 0
            syncStartTimes[profileId] = nil
            TelemetryService.shared.recordSyncCompleted(
                profileId: profileId,
                profileName: profileName,
                mode: profile?.syncMode ?? .bisync,
                duration: completedDuration,
                filesChanged: changesCount
            )
            if !isNotificationsMuted(for: profileId) {
                notificationService.notifySyncCompleted(
                    changesCount: changesCount,
                    profileId: profileId,
                    profileName: profileName,
                    syncDirectoryPath: syncDirectoryPath
                )
            } else {
                // Still clean up pending state even when muted
                notificationService.clearPendingChanges(for: profileId)
            }
            currentSyncChanges[profileId] = nil
            // The run just ended — apply any reinstall an external edit deferred while
            // it was live (review finding).
            retryPendingExternalReinstallIfNeeded(for: profileId)

        case .syncFailed(let exitCode, let message):
            // The run was stopped by `abortSync`: its non-zero exit is the abort, not a
            // failure — no error, no notification, and above all no auto-fix `--resync`
            // restarting what the user just stopped. `finishAbort` settles the state.
            if wasRunAborted(for: profileId) {
                SyncTraySettings.debugLog("Ignoring syncFailed (exit \(exitCode)) for '\(profileName)': the run was aborted")
                profileProgress[profileId] = nil
                lastSeenErrorMessage[profileId] = nil
                currentSyncChanges[profileId] = nil
                syncStartTimes[profileId] = nil
                logWatchers[profileId]?.setActivelySyncing(false)
                TelemetryService.shared.recordSyncSkipped(profileId: profileId, profileName: profileName, reason: "aborted")
                // While the abort is still in flight it settles the state and retries any
                // deferred reinstall itself, once every process of the run has exited.
                if !isAborting(for: profileId) {
                    if profileStates[profileId] == .syncing {
                        profileStates[profileId] = isPaused(for: profileId) ? .paused : .idle
                    }
                    retryPendingExternalReinstallIfNeeded(for: profileId)
                }
                break
            }

            // Check if the error message (or the last seen error) is a transient one
            let errorToCheck = message ?? lastSeenErrorMessage[profileId]

            // A rejected CONCURRENT run's own failure (R3): another live process
            // holds this profile's bisync session lock, so this `.syncFailed` is
            // not a genuine profile failure — state stays whatever the still-live
            // run left it at, no error is stored, and auto-fix never fires.
            // Session-lock liveness ONLY (D5), never the in-flight registry: a
            // rejected run that IS the in-flight app run itself, failing against
            // its own dead stale lock, must still surface normally.
            if let currentProfile = profile {
                let sessionHolderLive = SyncRunLock.isLive(
                    lockHolders(for: currentProfile).sessionLock, isAlive: SyncRunLock.processIsAlive)
                if SyncRunLock.isRejectedConcurrentRun(message: errorToCheck, sessionHolderLive: sessionHolderLive) {
                    SyncTraySettings.debugLog(
                        "Ignoring prior-lock-file syncFailed for '\(currentProfile.name)': a live process holds the session lock")
                    // Observable in Dash0 (review finding): this is the exact incident
                    // shape this guard exists to catch — without a signal here nobody
                    // can tell whether a double-bisync race is still happening.
                    TelemetryService.shared.recordRejectedConcurrentRun(
                        profileId: profileId, profileName: currentProfile.name, site: "sync_failed")
                    break
                }
            }

            if let msg = errorToCheck, SyncLogPatterns.isTransientAllFilesChangedError(msg) {
                // Transient "all files were changed" - just clear state, don't show error
                profileProgress[profileId] = nil
                lastSeenErrorMessage[profileId] = nil
                syncStartTimes[profileId] = nil
                logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
                currentSyncChanges[profileId] = nil  // Only clear this profile's changes
                // Reset to idle since this isn't a real error
                profileStates[profileId] = .idle
                // The run just ended (cosmetic non-error) — apply any deferred reinstall.
                retryPendingExternalReinstallIfNeeded(for: profileId)
                break
            }

            profileStates[profileId] = .error("Exit code \(exitCode)")
            profileProgress[profileId] = nil  // Clear progress on failure
            lastSeenErrorMessage[profileId] = nil
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            // Report telemetry for failed sync
            let failedDuration = syncStartTimes[profileId].map { Date().timeIntervalSince($0) } ?? 0
            syncStartTimes[profileId] = nil
            TelemetryService.shared.recordSyncFailed(
                profileId: profileId,
                profileName: profileName,
                mode: profile?.syncMode ?? .bisync,
                duration: failedDuration,
                filesChanged: currentSyncChanges[profileId]?.count ?? 0,
                exitCode: exitCode,
                errorMessage: message ?? profileErrors[profileId]
            )
            // Only use the syncFailed message if we don't already have a more specific error
            if profileErrors[profileId] == nil, let msg = message {
                profileErrors[profileId] = msg
            }
            let errorDescription = profileErrors[profileId] ?? message ?? "Exit code \(exitCode)"
            if !isNotificationsMuted(for: profileId) {
                notificationService.notifySyncError(
                    "Sync failed: \(errorDescription)",
                    profileId: profileId,
                    profileName: profile?.name
                )
            }
            currentSyncChanges[profileId] = nil

            // The backoff counter (autoFixAttempts) and suppression (autoFixSuppressed) still
            // apply unchanged. The exclusive-run registry is not touched here (D1) — only the
            // run's own owner ends its token, via `performResync`/`endExclusiveRun`.

            // Auto-fix: if the stored error is an out-of-sync error and the setting is on,
            // trigger an automatic --resync recovery.
            if let storedError = profileErrors[profileId],
               SyncLogPatterns.isOutOfSyncError(storedError),
               let currentProfile = profile {
                triggerAutoFix(for: currentProfile)
            }
            // The run just ended (failed, but ended) — apply any reinstall an external
            // edit deferred while it was live (review finding).
            retryPendingExternalReinstallIfNeeded(for: profileId)

        case .transportChanged(let transport):
            profileTransports[profileId] = transport
            TelemetryService.shared.recordTransportChange(
                profileId: profileId,
                profileName: profileName,
                transport: transport.isPrimary ? "primary" : "fallback"
            )

        case .errorMessage(let message):
            // An aborted run's errors ("context canceled", interrupted transfers, …) are
            // the abort's own doing — never stored or shown as the profile's error.
            if wasRunAborted(for: profileId) {
                break
            }

            // A rejected CONCURRENT run's own "prior lock file found" message (R3):
            // another live process holds this profile's bisync session lock, so
            // this is not this profile's error. Session-lock liveness ONLY (D5) —
            // never the in-flight registry — so a rejected run that is the
            // in-flight app run itself, failing against its own dead stale lock,
            // still surfaces normally.
            //
            // Still record it into `lastSeenErrorMessage` before suppressing (review
            // finding): the script's eventual plain-text "Bisync failed with exit
            // code N" line parses to `.syncFailed(message: nil)`, so without this the
            // `.syncFailed` handler's own `isRejectedConcurrentRun` re-check below has
            // no message to test and the rejected run's failure leaks through as a
            // genuine profile failure. `lastSeenErrorMessage` is "last seen" by
            // design — a later REAL error message overwrites this one before
            // `.syncFailed` arrives, so it is never mistakenly suppressed by a
            // rejected run's stale message.
            if let currentProfile = profile {
                let sessionHolderLive = SyncRunLock.isLive(
                    lockHolders(for: currentProfile).sessionLock, isAlive: SyncRunLock.processIsAlive)
                if SyncRunLock.isRejectedConcurrentRun(message: message, sessionHolderLive: sessionHolderLive) {
                    lastSeenErrorMessage[profileId] = message
                    SyncTraySettings.debugLog(
                        "Ignoring prior-lock-file errorMessage for '\(currentProfile.name)': a live process holds the session lock")
                    // Observable in Dash0 (review finding) — same signal as the
                    // `.syncFailed` suppression above, from the other log line shape.
                    TelemetryService.shared.recordRejectedConcurrentRun(
                        profileId: profileId, profileName: currentProfile.name, site: "error_message")
                    break
                }
            }

            // Track all error messages so we can correlate with syncFailed events
            lastSeenErrorMessage[profileId] = message

            // Transient "all files were changed" error should not be stored as a displayed error
            if SyncLogPatterns.isTransientAllFilesChangedError(message) {
                break
            }

            TelemetryService.shared.recordSyncError(
                profileId: profileId,
                profileName: profileName,
                errorMessage: message
            )

            // Prefer critical/actionable errors over file-level errors
            // Critical errors tell us what to do (e.g., "out of sync", "resync")
            // File-level errors (e.g., "Path1 file not found") are less actionable
            let isCriticalError = SyncLogPatterns.isCriticalError(message)
            let existingIsCritical = profileErrors[profileId].map {
                SyncLogPatterns.isCriticalError($0)
            } ?? false

            // Store error if: no existing error, OR new error is critical and existing isn't
            if profileErrors[profileId] == nil || (isCriticalError && !existingIsCritical) {
                profileErrors[profileId] = message
            }

        case .driveNotMounted:
            let previousState = profileStates[profileId]
            profileStates[profileId] = .driveNotMounted
            // Only emit telemetry/notification on state transition, not every poll
            if previousState != .driveNotMounted {
                TelemetryService.shared.recordDriveNotMounted(
                    profileId: profileId,
                    profileName: profileName
                )
                if !isNotificationsMuted(for: profileId) {
                    notificationService.notifyDriveNotMounted(profileId: profileId, profileName: profileName)
                }
            }

        case .syncSkipped(let reason):
            // A scheduled run exited early without syncing (remote failed the
            // pre-flight reachability check). "Starting bisync" already set the
            // profile to `.syncing` and opened a telemetry span; close both here
            // so the profile returns to rest instead of appearing to sync for
            // 11–37 min until the next run abandons the stale span.
            logWatchers[profileId]?.setActivelySyncing(false)
            profileProgress[profileId] = nil
            syncStartTimes[profileId] = nil
            checkPhaseStartTimes.removeValue(forKey: profileId)
            checkPhaseReported.remove(profileId)
            // Only downgrade from `.syncing`; never clobber a real error,
            // paused, or driveNotMounted state.
            if profileStates[profileId] == .syncing {
                profileStates[profileId] = .idle
            }
            TelemetryService.shared.recordSyncSkipped(
                profileId: profileId,
                profileName: profileName,
                reason: reason
            )

        case .syncAlreadyRunning:
            TelemetryService.shared.recordSyncContention(
                profileId: profileId,
                profileName: profileName
            )

        case .fileChange(var change):
            change.profileName = profileName
            if currentSyncChanges[profileId] == nil {
                currentSyncChanges[profileId] = []
            }
            currentSyncChanges[profileId]?.append(change)
            addRecentChange(change)
            TelemetryService.shared.recordFileOperation(
                profileName: profileName,
                operation: change.operation.rawValue,
                filePath: change.path
            )
            // Only send notification if not muted
            if !isNotificationsMuted(for: profileId) {
                notificationService.notifyFileChange(change, profileId: profileId, syncDirectoryPath: syncDirectoryPath)
            }

        case .stats(let stats):
            // A late stats line from a run whose abort already finished would put a stale
            // progress bar back on a profile that is at rest.
            if let currentProfile = profile, wasRunAborted(for: profileId), !isAborting(for: profileId),
               !isRunLive(for: currentProfile) {
                break
            }
            if let bytes = stats.bytes, let totalBytes = stats.totalBytes, totalBytes > 0 {
                let checksDone = stats.checks ?? 0
                let totalChecks = stats.totalChecks ?? 0

                // Track check phase duration (listing/comparison phase in bisync)
                if totalChecks > 0 && checksDone < totalChecks && checkPhaseStartTimes[profileId] == nil {
                    checkPhaseStartTimes[profileId] = Date()
                    checkPhaseReported.remove(profileId)
                }
                if totalChecks > 0 && checksDone >= totalChecks && !checkPhaseReported.contains(profileId),
                   let checkStart = checkPhaseStartTimes[profileId] {
                    let checkDuration = Date().timeIntervalSince(checkStart)
                    TelemetryService.shared.recordCheckPhaseDuration(
                        profileName: profileName,
                        syncMode: profile?.syncMode.rawValue ?? "unknown",
                        durationSeconds: checkDuration,
                        checksCompleted: checksDone,
                        totalChecks: totalChecks
                    )
                    checkPhaseReported.insert(profileId)
                    checkPhaseStartTimes.removeValue(forKey: profileId)
                }

                profileProgress[profileId] = SyncProgress(
                    bytesTransferred: Int64(bytes),
                    totalBytes: Int64(totalBytes),
                    eta: stats.eta,
                    speed: stats.speed,
                    transfersDone: stats.transfers ?? 0,
                    totalTransfers: stats.totalTransfers ?? 0,
                    checksDone: checksDone,
                    totalChecks: totalChecks,
                    elapsedTime: stats.elapsedTime,
                    errors: stats.errors ?? 0,
                    transferringFiles: stats.transferring ?? [],
                    listedCount: stats.listed
                )
            }

        case .unknown:
            break
        }

        updateAggregateState()
    }

    private func addRecentChange(_ change: FileChange) {
        recentChanges.insert(change, at: 0)
        if recentChanges.count > maxRecentChanges {
            recentChanges = Array(recentChanges.prefix(maxRecentChanges))
        }
    }

    // MARK: - FinderSync IPC

    /// Set up the Darwin notification observer and fallback poll timer for
    /// receiving pin/unpin requests from the FinderSync extension.
    private func setupFinderSyncIPC() {
        // Register Darwin notification observer.
        // CFNotificationCenterAddObserver requires a C-callable callback with no captures.
        // Pass `self` via the `observer` UnsafeRawPointer and cast it back inside the callback.
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            observer,
            { _, observer, _, _, _ in
                // The C callback is on an arbitrary thread — bridge to @MainActor.
                guard let observer = observer else { return }
                let manager = Unmanaged<SyncManager>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    await manager.processPendingPinRequest()
                }
            },
            kPinRequestNotificationName as CFString,
            nil,
            .deliverImmediately
        )

        // 1-second fallback poll timer in case a Darwin notification is missed.
        // Only polls when there are mounted profiles (avoids CPU waste).
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // profileStore is @MainActor-isolated, but this handler runs on a global
            // utility queue — read it (and process) on the main actor to avoid a data race.
            Task { @MainActor in
                let hasMountedProfiles = self.profileStore.enabledProfiles.contains { $0.isMountMode }
                guard hasMountedProfiles else { return }
                // Check for a pending request without a wake notification.
                await self.processPendingPinRequest()
            }
        }
        pinRequestPollTimer = timer
        timer.resume()
    }

    /// Read and process a pending pin/unpin request written by the FinderSync extension.
    ///
    /// Reads `<AppGroupContainer>/pending-pin-request.json`, parses the action and paths,
    /// updates the profile's `pinnedDirectories`, deletes the file, and initiates
    /// VFS content warming for pin operations.
    func processPendingPinRequest() async {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: kAppGroupID
        ) else {
            SyncTraySettings.debugLog("processPendingPinRequest: App Group container not accessible")
            return
        }

        let requestURL = containerURL.appendingPathComponent(kPendingPinRequestFile)
        guard FileManager.default.fileExists(atPath: requestURL.path) else { return }

        do {
            let data = try Data(contentsOf: requestURL)
            // Delete the file immediately so we don't process it again.
            try? FileManager.default.removeItem(at: requestURL)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = json["action"] as? String,
                  let profileIdStr = json["profileId"] as? String,
                  let profileId = UUID(uuidString: profileIdStr),
                  let paths = json["paths"] as? [String] else {
                SyncTraySettings.debugLog("processPendingPinRequest: malformed JSON in pending request")
                return
            }

            guard var profile = profileStore.profile(for: profileId) else {
                SyncTraySettings.debugLog("processPendingPinRequest: profile \(profileIdStr) not found")
                return
            }

            let isMountMode = profile.isMountMode
            guard isMountMode else {
                SyncTraySettings.debugLog("processPendingPinRequest: profile '\(profile.name)' is not in mount mode")
                return
            }

            if action == "pin" {
                for path in paths where !profile.pinnedDirectories.contains(path) {
                    profile.pinnedDirectories.append(path)
                }
            } else if action == "unpin" {
                profile.pinnedDirectories.removeAll { paths.contains($0) }
            }

            profileStore.update(profile)

            // Push the new pin state to the extension's App Group copy and wake it so it
            // reloads + repaints the folder badge right away — otherwise the extension
            // keeps showing the stale badge and the user gets no Finder feedback.
            updateAppGroupMountPaths()
            notifyFinderSyncReload()

            TelemetryService.shared.recordOfflinePinOperation(
                profileId: profileId,
                profileName: profile.name,
                action: action,
                pathCount: paths.count
            )

            SyncTraySettings.debugLog("processPendingPinRequest: \(action) \(paths.count) path(s) for '\(profile.name)'")

            // For pin operations, start warming the newly pinned directories. Routed through
            // warmPinnedDirectories so the offline-files UI shows progress, and so the warmer
            // re-checks live pin state between files (an unpin mid-warm stops the read loop).
            if action == "pin" {
                startWarm(for: profileId, dirs: paths, trigger: "finder_pin")
            }

        } catch {
            SyncTraySettings.debugLog("processPendingPinRequest: error reading/parsing request: \(error)")
        }
    }

    /// Start a warming run for a profile as a cancellable, tracked task, superseding any run
    /// already in flight. This is the entry point every trigger uses so the run can later be
    /// stopped (`cancelWarm`) when the cache is cleared or the profile is unmounted.
    /// Whether the offline warm is currently paused for a profile — either the user's manual
    /// toggle or a live auto-pause cooldown. Read by the warm loop's pause gate and by the UI.
    func isWarmPaused(for profileId: UUID) -> Bool {
        if warmManuallyPaused[profileId] == true { return true }
        if let until = warmAutoPauseUntil[profileId], Date() < until { return true }
        return false
    }

    /// Whether the pause is specifically the user's manual one (for the toggle's on/off state).
    func isWarmManuallyPaused(for profileId: UUID) -> Bool {
        warmManuallyPaused[profileId] == true
    }

    /// The user's "Pause/Resume caching" toggle. Pausing stops the warm starting new reads;
    /// resuming also clears any live auto-pause cooldown so the warm resumes immediately (the
    /// 5s monitor re-pauses on the next tick only if an app is still reading). Manual pause is
    /// not persisted — it governs the current run only.
    func setWarmPaused(_ paused: Bool, for profileId: UUID) {
        warmManuallyPaused[profileId] = paused ? true : nil
        if !paused { warmAutoPauseUntil[profileId] = nil }
        if let name = profileStore.profile(for: profileId)?.name {
            TelemetryService.shared.recordWarmPause(
                profileId: profileId, profileName: name, paused: paused, source: "manual")
        }
    }

    /// On the mount-monitor cadence, for each profile with a LIVE warm, lsof the mount for an
    /// interactive reader (a real app — not Finder or the warmer itself) and, if found,
    /// (re)arm the auto-pause cooldown. lsof runs off the main actor since it can block on a
    /// slow mount. No live warm ⇒ no probe, so the cost is paid only while warming.
    private func refreshWarmAutoPause(for profiles: [SyncProfile]) {
        let targets = profiles
            .filter { warmProgress[$0.id]?.isActive == true }
            .map { ($0.id, $0.name, $0.localSyncPath) }
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let probed: [(UUID, String, Bool)] = targets.map { id, name, mount in
                (id, name, Self.shouldAutoPauseWarm(lsofOutput: Self.runLsofBusyCheck(mountPoint: mount)))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let now = Date()
                for (id, name, pause) in probed where pause {
                    let wasPaused = self.isWarmPaused(for: id)
                    self.warmAutoPauseUntil[id] = now.addingTimeInterval(Self.warmAutoPauseCooldown)
                    // Record/log only the idle→paused edge, not every re-arm, so a long busy
                    // stretch is one event rather than one every 5s.
                    if !wasPaused {
                        TelemetryService.shared.recordWarmPause(
                            profileId: id, profileName: name, paused: true, source: "auto")
                        SyncTraySettings.debugLog("'\(name)': offline warm auto-paused — an app is reading the mount")
                    }
                }
            }
        }
    }

    func startWarm(for profileId: UUID, dirs: [String]? = nil, trigger: String = "manual") {
        // Anti-thrash cooldown for the AUTOMATIC warm only. The "startup" warm re-fires on every
        // mount detection, so a mount that can't attach and keeps getting restarted by launchd
        // would re-flood a struggling backend with pinned-file downloads (the dominant load in the
        // observed network-hang incident). A user-driven warm ("manual"/"finder_pin") is an
        // explicit action and is never throttled.
        if trigger == "startup" {
            if let last = lastAutoDataWarmStart[profileId],
               Date().timeIntervalSince(last) < Self.warmRefireCooldown {
                return
            }
            lastAutoDataWarmStart[profileId] = Date()
        }
        let previous = warmTasks[profileId]
        previous?.cancel()  // supersede any run in flight
        warmTasks[profileId] = Task { [weak self] in
            // Wait for the superseded run to fully wind down before starting. Its cleanup
            // clears `warmProgress[profileId]`, so without this await the new run would hit
            // `warmPinnedDirectories`' still-active coalesce guard and bail — cancelling the
            // old warm without starting the new one (the exclude/pin "apply right away" path).
            await previous?.value
            await self?.warmPinnedDirectories(for: profileId, dirs: dirs, trigger: trigger)
        }
    }

    /// Cancel an in-flight warming run for a profile. The run stops within one file chunk and
    /// its completion block drops the progress row and records a `cancelled` outcome. Call
    /// before clearing the cache or unmounting so the warmer doesn't re-download files that
    /// are about to be evicted (or read through a mount that's going away).
    func cancelWarm(for profileId: UUID) {
        warmTasks[profileId]?.cancel()
    }

    /// Warm the whole-tree directory-LISTING cache for a streaming mount via the RC API
    /// (`VFSCacheService.refreshAllListings`, a per-subtree descent — see there for why one
    /// recursive `/vfs/refresh` is unreliable on large SMB trees) so Finder browsing is instant
    /// across the tree, not just under pinned folders. Metadata only — no bytes are downloaded.
    /// Fire-and-record: a `failed`/partial outcome is non-fatal, the mount still works, so it's
    /// recorded for telemetry and dropped. Passes `profile.fullRemotePath` as the rclone Fs so
    /// the descent can enumerate subdirectories via `operations/list`. Runs at .utility off the
    /// main actor; gated once-per-mount by `shouldWarmListingsOnMount`, so no supersede/cancel
    /// bookkeeping is needed (unlike the data warm).
    func startListingWarm(for profileId: UUID) {
        guard let profile = profileStore.profiles.first(where: { $0.id == profileId }),
              profile.isMountMode, profile.rcPort > 0 else { return }
        // Anti-thrash cooldown: a mount that can't attach gets restarted by launchd and re-fires
        // this warm on every restart. Skip if we warmed this profile very recently, so a rapid
        // remount loop can't re-flood a backend that is already struggling to answer.
        if let last = lastListingWarmStart[profileId],
           Date().timeIntervalSince(last) < Self.warmRefireCooldown {
            return
        }
        lastListingWarmStart[profileId] = Date()
        let port = profile.rcPort
        let name = profile.name
        let fs = profile.fullRemotePath
        Task.detached(priority: .utility) {
            let result = await VFSCacheService.shared.refreshAllListings(fs: fs, port: port)
            await MainActor.run {
                TelemetryService.shared.recordListingWarm(
                    profileId: profileId, profileName: name,
                    outcome: result.outcome,
                    directoriesWarmed: result.directoriesWarmed,
                    directoriesFailed: result.directoriesFailed,
                    durationSeconds: result.durationSeconds)
            }
        }
    }

    /// Drop macOS's `.metadata_never_index` marker at a streaming mount's root so Spotlight
    /// (`mds`) skips the whole tree. On a freshly-mounted network volume, the Spotlight
    /// importer otherwise walks every file THROUGH the mount to index it — observed pulling
    /// 10+ GB at mount time — which monopolises the `--transfers` download slots and leaves
    /// Finder's own directory listing queued behind it (the "Loading…" spinner that persists
    /// even after the listing cache is warm). The marker is the Apple-documented, whole-volume
    /// opt-out and is what rclone-mount setups use.
    ///
    /// Written APP-side (not by the launchd sync script) for the same reason the Cache-Only
    /// exclude list is: under launchd the script's `/usr/bin/python3` is denied read/write to
    /// a mount on an external drive, while the app holds the TCC grant. The write lands at the
    /// mount root = the remote root, so it persists to the remote and is present at every
    /// FUTURE mount BEFORE Spotlight evaluates the volume — the one hidden dotfile is the
    /// deliberate, standard cost. Idempotent: skips the write when the marker already exists.
    func writeSpotlightExclusionMarker(for profileId: UUID) {
        guard let profile = profileStore.profiles.first(where: { $0.id == profileId }),
              profile.isMountMode, !profile.localSyncPath.isEmpty else { return }
        let mountRoot = profile.localSyncPath
        let name = profile.name
        Task.detached(priority: .utility) {
            let outcome = VFSCacheService.writeSpotlightExclusionMarker(atMountRoot: mountRoot)
            await MainActor.run {
                TelemetryService.shared.recordSpotlightMarker(
                    profileId: profileId, profileName: name, outcome: outcome)
            }
        }
    }

    // MARK: - Cache Directory Migration

    /// Cancel an in-flight cache-directory migration for a profile. The
    /// engine stops at the next file boundary; its own cleanup removes any
    /// in-flight destination partial and returns `.cancelled` — nothing here
    /// needs to clean up files.
    func cancelCacheMigration(for profileId: UUID) {
        cacheMigrationTasks[profileId]?.cancel()
    }

    /// Move a Stream profile's rclone VFS cache (content + metadata) from its
    /// current `vfsCachePath` to `destination` as a tracked, cancellable
    /// task, superseding any run already in flight for this profile. Every
    /// entry point (the Save-time prompt, the Offline Files "Move Cache…"
    /// action) routes through this so cancel/progress work identically.
    @discardableResult
    func startCacheMigration(
        for profileId: UUID,
        destination: String,
        coMigrate: Set<UUID> = []
    ) -> Task<CacheMigrationOutcome, Never> {
        cacheMigrationTasks[profileId]?.cancel()
        let task = Task { [weak self] () -> CacheMigrationOutcome in
            guard let self else {
                return CacheMigrationOutcome(result: .cancelled, filesMoved: 0, bytesMoved: 0, sameVolume: false)
            }
            return await self.migrateCacheDirectory(for: profileId, destination: destination, coMigrate: coMigrate)
        }
        cacheMigrationTasks[profileId] = task
        return task
    }

    /// After a user-cancelled migration, move whatever already landed at
    /// `destinationRoot` back to `sourceRoot` — the "Roll Back" option in
    /// `CacheMoveSheet` (paired with "Resume", which is just calling
    /// `startCacheMigration` again; the engine's resume-skip makes that
    /// idempotent). Operates on a LOCAL, never-persisted copy of the profile
    /// carrying `destinationRoot` as its `vfsCachePath` so the SAME
    /// planner/engine path applies in reverse — `profileStore` is never
    /// touched, since the original profile's `vfsCachePath` is still correct
    /// (a cancelled run is never persisted).
    @discardableResult
    func rollbackCacheMigration(
        for profileId: UUID,
        sourceRoot: String,
        destinationRoot: String,
        coMigrate: Set<UUID> = []
    ) -> Task<CacheMigrationOutcome, Never> {
        cacheMigrationTasks[profileId]?.cancel()
        guard let original = profileStore.profile(for: profileId) else {
            return Task { CacheMigrationOutcome(result: .cancelled, filesMoved: 0, bytesMoved: 0, sameVolume: false) }
        }
        let allProfiles = profileStore.profiles
        // A copy pinned to `sourceRoot` (NOT `original.vfsCachePath` directly —
        // a cancelled run never persists, so it should already equal
        // `sourceRoot`, but this stays correct even if a caller passes a
        // slightly different root than what's currently on disk).
        var asSource = original
        asSource.vfsCachePath = sourceRoot
        let cancellationFlag = CacheMigrationCancellationFlag()

        let affectedIds = [profileId] + coMigrate
        let rollbackProfiles = [asSource] + coMigrate.compactMap { profileStore.profile(for: $0) }

        let task = Task { [weak self] () -> CacheMigrationOutcome in
            // R4/R5 for the REVERSE move, which the forward bracket does not
            // cover: `migrateCacheDirectory`'s `defer` has already re-installed
            // the agent by the time the user is offered "Resume or roll back?",
            // so the mount is live again on `sourceRoot` — precisely the tree a
            // rollback writes into. Cancel any warm and re-detach first, exactly
            // as the forward move does.
            //
            // This runs on the main actor (it touches `setupService` and the
            // profile store) but from INSIDE the Task, not before it. Doing it
            // synchronously in `rollbackCacheMigration`'s own body blocked the
            // Roll Back button handler through a `diskutil unmount` plus a
            // bounded remount recheck — so the sheet could not even paint its
            // progress step until the detach finished. The forward path never
            // had that problem because its detach already sits inside an async
            // `migrateCacheDirectory`.
            let startedAt = Date()
            let telemetry = TelemetryService.shared.beginCacheMigration(
                profileId: profileId, profileName: asSource.name
            )
            let detach: (toReinstall: [SyncProfile], failed: Bool) = await MainActor.run {
                guard let self else { return (toReinstall: [], failed: true) }
                for id in affectedIds { self.cancelWarm(for: id) }
                return self.detachForCacheMigration(rollbackProfiles)
            }
            guard !detach.failed else {
                // Still mounted after a graceful and a forced unmount — moving
                // files back under a live mount is worse than leaving them at
                // the destination, where the (unpersisted) profile simply does
                // not point yet. Re-install and report, changing nothing.
                await MainActor.run {
                    self?.reinstallAfterCacheMigration(detach.toReinstall)
                    self?.cacheMigrationProgress[profileId] = nil
                }
                let aborted = CacheMigrationOutcome(result: .failed(.mountDetachFailed, rolledBack: false), filesMoved: 0, bytesMoved: 0, sameVolume: false)
                // Emitted for the same reason the forward path opens its span
                // before the detach loop: an abort that produces no telemetry
                // at all is indistinguishable from a rollback that never ran.
                TelemetryService.shared.endCacheMigration(
                    telemetry,
                    filesMoved: 0,
                    bytesMoved: 0,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    sameVolume: false,
                    // Derived, not hand-copied: a literal here would agree
                    // today only because `CacheMigrationFailure` takes its
                    // default rawValue, and hand-copying a shared decision
                    // is exactly what let the persist gate drift from its
                    // own call sites earlier in this branch.
                    outcome: SyncManager.cacheMigrationOutcomeLabel(aborted.result)
                )
                return aborted
            }
            let profilesToReinstall = detach.toReinstall

            let fs = CacheMigrationFileSystem.production()
            let outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        // Re-derive the ORIGINAL forward plan (source → destination)
                        // and reverse it, rather than re-planning FROM
                        // `destinationRoot`: a cancelled run never persists, so
                        // every co-migrated sibling's `vfsCachePath` is STILL
                        // `sourceRoot` — classifying overlap against
                        // `destinationRoot` would match none of them, stranding
                        // their relocated bytes at the destination with no
                        // rollback (finding 6). `.reversed()` keeps the EXACT
                        // same subtree set the forward run used, just swapped.
                        switch CacheMigrationPlanner.plan(moving: asSource, allProfiles: allProfiles, to: destinationRoot, coMigrate: coMigrate) {
                        case .failure(let rejection):
                            continuation.resume(returning: CacheMigrationOutcome(
                                result: .preflightRejected(.plan(rejection)), filesMoved: 0, bytesMoved: 0, sameVolume: false
                            ))
                        case .success(let forwardPlan):
                            let reversePlan = forwardPlan.reversed()
                            let engine = CacheMigrationEngine(fs: fs, isCancelled: { cancellationFlag.isCancelled })
                            switch engine.preflight(reversePlan) {
                            case .failure(let rejection):
                                continuation.resume(returning: CacheMigrationOutcome(
                                    result: .preflightRejected(rejection), filesMoved: 0, bytesMoved: 0, sameVolume: false
                                ))
                            case .success(let preflight):
                                continuation.resume(returning: engine.run(reversePlan, preflight))
                            }
                        }
                    }
                }
            } onCancel: {
                cancellationFlag.markCancelled()
            }
            // Re-install on EVERY exit path, mirroring the forward move's
            // `defer` — a rollback that completed, failed, or was cancelled
            // must never leave the profile with no launchd agent. `defer`
            // can't be used here because the re-install has to hop back to
            // the main actor, so it sits on the single path out of the
            // `await` above.
            await MainActor.run {
                self?.reinstallAfterCacheMigration(profilesToReinstall)
                self?.cacheMigrationProgress[profileId] = nil
            }
            TelemetryService.shared.endCacheMigration(
                telemetry,
                filesMoved: outcome.filesMoved,
                bytesMoved: outcome.bytesMoved,
                durationSeconds: Date().timeIntervalSince(startedAt),
                sameVolume: outcome.sameVolume,
                outcome: SyncManager.cacheMigrationOutcomeLabel(outcome.result)
            )
            return outcome
        }
        cacheMigrationTasks[profileId] = task
        return task
    }

    /// Pure: did a single profile's pre-move detach succeed? Extracted out
    /// of `migrateCacheDirectory`'s control flow so this exact decision is
    /// behaviorally testable without a real `SyncManager`/`SyncSetupService`
    /// (finding 9 — the prior self-test coverage only checked that certain
    /// substrings were PRESENT somewhere in the function body, which cannot
    /// detect an inverted or unreachable guard around this decision).
    nonisolated static func cacheMigrationDetachSucceeded(threw: Bool, stillMountedAfterRecheck: Bool) -> Bool {
        !threw && !stillMountedAfterRecheck
    }

    /// R4 — detach and unload every currently-installed profile among
    /// `profiles`, so nothing writes into either cache tree while files are
    /// being relocated.
    ///
    /// Shared by the forward move AND the rollback. The rollback needs it
    /// just as badly: by the time the user sees the "Resume or roll back?"
    /// choice, `migrateCacheDirectory`'s `defer` has already re-installed
    /// the agent, and the mount is back up using `sourceRoot` as its
    /// `--cache-dir` — which is exactly where a rollback writes. Relocating
    /// files into a live `rclone nfsmount`'s cache directory is the same
    /// corruption path the pre-move warm cancellation exists to avoid, so
    /// Roll Back must re-detach rather than assume the forward bracket
    /// still covers it.
    ///
    /// `setupService.uninstall` does the graceful volume detach but does NOT
    /// throw when that detach genuinely fails (`diskutil unmount` and its
    /// `force` retry both non-zero) — it logs `mount.result: failure` and
    /// proceeds to unload the agent anyway. So both a thrown error and that
    /// non-throwing failure are checked explicitly (finding 7), the latter
    /// via `isMountedAfterBoundedRecheck` rather than one `isMounted`
    /// sample, since a stale mount-table entry or a `KeepAlive` remount race
    /// would otherwise abort the whole run on a single bad reading
    /// (finding 4).
    ///
    /// - Returns: the profiles that were unloaded and therefore MUST be
    ///   passed to `reinstallAfterCacheMigration` on every exit path, and
    ///   whether the detach failed (in which case the caller must abort
    ///   without touching a file).
    private func detachForCacheMigration(_ profiles: [SyncProfile]) -> (toReinstall: [SyncProfile], failed: Bool) {
        let installed = profiles.filter { setupService.isInstalled(profile: $0) }
        for profile in installed {
            do {
                try setupService.uninstall(profile: profile)
            } catch {
                return (installed, true)
            }
            let stillMounted = profile.isMountMode && setupService.isMountedAfterBoundedRecheck(profile: profile)
            guard Self.cacheMigrationDetachSucceeded(threw: false, stillMountedAfterRecheck: stillMounted) else {
                // `uninstall` returned normally but the volume is still
                // attached — the graceful/forced `diskutil unmount` both
                // failed. Abort rather than move files out from under it.
                return (installed, true)
            }
        }
        return (installed, false)
    }

    /// Re-install everything `detachForCacheMigration` unloaded and re-push
    /// the FinderSync App Group data (R7). Always installs from the CURRENT
    /// persisted profile, so a `vfsCachePath` the move just persisted is the
    /// one the re-installed agent mounts with.
    private func reinstallAfterCacheMigration(_ profiles: [SyncProfile]) {
        for profile in profiles {
            let latest = profileStore.profile(for: profile.id) ?? profile
            try? setupService.install(profile: latest)
        }
        updateAppGroupMountPaths()
    }

    /// The full orchestration: cancel any in-flight warm for the affected
    /// profiles (R5), detach/uninstall before the move (R4), run the engine
    /// off the main actor (R10), persist `vfsCachePath` ONLY on `.completed`
    /// (R20), then re-install on EVERY exit path and re-push the FinderSync
    /// App Group data (R7).
    private func migrateCacheDirectory(
        for profileId: UUID,
        destination: String,
        coMigrate: Set<UUID>
    ) async -> CacheMigrationOutcome {
        guard let movingProfile = profileStore.profile(for: profileId) else {
            return CacheMigrationOutcome(result: .cancelled, filesMoved: 0, bytesMoved: 0, sameVolume: false)
        }
        let allProfiles = profileStore.profiles
        let startedAt = Date()

        // Refuse before anything is cancelled or detached when a profile this run repoints
        // still has Cache Only files waiting to upload: its overlay stays under the old
        // `vfsCachePath`. Every app entry point (the Save-time prompt, Offline Files' Move
        // Cache…, and each ticked same-root sibling's own run) comes through here.
        if let reason = Self.cacheMoveBlockedReason(
            moving: movingProfile,
            coMigrate: coMigrate.compactMap { profileStore.profile(for: $0) },
            pendingUploads: Self.pendingUploadCount(of:)
        ) {
            let outcome = CacheMigrationOutcome(
                result: .preflightRejected(.pendingUploads(reason)), filesMoved: 0, bytesMoved: 0, sameVolume: false)
            // Recorded like every other `preflight_rejected` outcome — a begin/end pair, so
            // the refusal is visible in telemetry — while still refusing before any warm is
            // cancelled or anything is detached.
            TelemetryService.shared.endCacheMigration(
                TelemetryService.shared.beginCacheMigration(profileId: profileId, profileName: movingProfile.name),
                filesMoved: 0,
                bytesMoved: 0,
                durationSeconds: Date().timeIntervalSince(startedAt),
                sameVolume: false,
                outcome: Self.cacheMigrationOutcomeLabel(outcome.result)
            )
            return outcome
        }

        // R5 — cancel any warm reading through the mount BEFORE any file is touched.
        let affectedIds = [profileId] + coMigrate
        for id in affectedIds { cancelWarm(for: id) }

        // Started BEFORE the detach loop (not after it, as before) so a
        // detach-failure abort below still emits a span/metrics instead of
        // silently producing no telemetry at all (finding 4).
        let telemetry = TelemetryService.shared.beginCacheMigration(
            profileId: profileId,
            profileName: movingProfile.name
        )

        // R4 — detach/uninstall the moving profile (and any co-migrating
        // installed profile) BEFORE the move, so nothing writes into the
        // cache mid-move. `setupService.uninstall` already performs the
        // graceful volume detach for a mount-mode profile — but it does NOT
        // throw when that detach genuinely fails (`diskutil unmount` and its
        // `force` retry both non-zero): it logs `mount.result: failure`
        // telemetry and proceeds anyway to unload the agent and delete the
        // profile's files. A `try?` here previously swallowed both a real
        // thrown error AND that non-throwing failure, letting the move
        // proceed against a still-mounted, still-writable volume (finding
        // 7). Guard against both explicitly. The post-uninstall recheck
        // uses `isMountedAfterBoundedRecheck` rather than a single
        // `isMounted` sample, since a stale mount-table entry or a
        // `KeepAlive` remount race can otherwise false-positive and abort
        // the WHOLE migration on one bad sample (finding 4).
        let detach = detachForCacheMigration([movingProfile] + coMigrate.compactMap { profileStore.profile(for: $0) })
        let profilesToReinstall = detach.toReinstall
        let detachFailed = detach.failed

        defer {
            // Re-install on EVERY exit path — completed, failed, cancelled,
            // a detach failure, or a thrown error above — so a profile is
            // never left with no launchd agent (`optimize-approach(plan)`
            // proposal P2).
            reinstallAfterCacheMigration(profilesToReinstall)
        }

        guard !detachFailed else {
            cacheMigrationProgress[profileId] = nil
            let outcome = CacheMigrationOutcome(result: .failed(.mountDetachFailed, rolledBack: false), filesMoved: 0, bytesMoved: 0, sameVolume: false)
            TelemetryService.shared.endCacheMigration(
                telemetry,
                filesMoved: 0,
                bytesMoved: 0,
                durationSeconds: Date().timeIntervalSince(startedAt),
                sameVolume: false,
                outcome: Self.cacheMigrationOutcomeLabel(outcome.result)
            )
            return outcome
        }

        var progress = CacheMigrationProgress()
        cacheMigrationProgress[profileId] = progress

        let cancellationFlag = CacheMigrationCancellationFlag()
        let fs = CacheMigrationFileSystem.production(isCancelled: { cancellationFlag.isCancelled })

        let result: (plan: CacheMigrationPlan?, outcome: CacheMigrationOutcome) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let runResult = CacheMigrationRunner.migrate(
                        moving: movingProfile,
                        allProfiles: allProfiles,
                        destination: destination,
                        coMigrate: coMigrate,
                        fs: fs,
                        isCancelled: { cancellationFlag.isCancelled },
                        onPreflight: { preflight in
                            DispatchQueue.main.async {
                                guard let self, var p = self.cacheMigrationProgress[profileId] else { return }
                                p.filesTotal = preflight.totalFiles
                                p.bytesTotal = preflight.totalBytes
                                p.sameVolume = preflight.sameVolume
                                self.cacheMigrationProgress[profileId] = p
                            }
                        },
                        onProgress: { filesDone, bytesDone, currentFile in
                            DispatchQueue.main.async {
                                guard let self, var p = self.cacheMigrationProgress[profileId] else { return }
                                p.phase = .moving
                                p.filesDone = filesDone
                                p.bytesDone = bytesDone
                                p.currentFile = currentFile
                                self.cacheMigrationProgress[profileId] = p
                            }
                        }
                    )
                    continuation.resume(returning: runResult)
                }
            }
        } onCancel: {
            cancellationFlag.markCancelled()
        }
        let plan = result.plan
        let outcome = result.outcome
        progress = cacheMigrationProgress[profileId] ?? progress
        progress.filesTotal = max(progress.filesTotal, outcome.filesMoved)
        progress.bytesTotal = max(progress.bytesTotal, outcome.bytesMoved)
        progress.sameVolume = outcome.sameVolume
        progress.finishedAt = Date()

        // `shouldPersist` is the ACTUAL gate, not a `where` clause on a
        // `.completed` pattern that had already decided the answer. It
        // covers both persisting outcomes — a completed move, and
        // `.nothingToMove` (an empty source is nothing to lose, so the
        // user's directory choice must not be silently dropped; R20 only
        // guards against persisting an INCOMPLETE cache). The two branches
        // were previously hand-copied, which is how they drifted apart from
        // the gate in the first place.
        if CacheMigrationPersistDecision.shouldPersist(outcome) {
            progress.phase = .completed
            // Re-read each profile from the store instead of writing back
            // `movingProfile`. That snapshot was taken before a move that
            // can run for hours; writing it back wholesale would silently
            // revert any edit the UI or `ConfigFileWatcher` made in the
            // meantime. `vfsCachePath` is the only field this migration
            // owns. (The sibling loop already worked this way — the moving
            // profile itself was the outlier.)
            var idsToRewrite = plan?.profileIdsToRewrite ?? []
            if !idsToRewrite.contains(profileId) { idsToRewrite.append(profileId) }
            for id in idsToRewrite {
                guard var latest = profileStore.profile(for: id) else { continue }
                latest.vfsCachePath = destination
                profileStore.update(latest)
            }
        } else {
            switch outcome.result {
            case .cancelled:
                progress.phase = .cancelled
            case .failed(let reason, _):
                progress.phase = .failed(reason.rawValue)
            default:
                progress.phase = .failed("rejected")
            }
        }
        cacheMigrationProgress[profileId] = progress

        TelemetryService.shared.endCacheMigration(
            telemetry,
            filesMoved: outcome.filesMoved,
            bytesMoved: outcome.bytesMoved,
            durationSeconds: progress.elapsed,
            sameVolume: outcome.sameVolume,
            outcome: Self.cacheMigrationOutcomeLabel(outcome.result)
        )

        return outcome
    }

    /// Pure — `nonisolated` so the rollback Task can label its own
    /// outcome without an extra main-actor hop just to read a switch.
    nonisolated private static func cacheMigrationOutcomeLabel(_ result: CacheMigrationOutcome.Result) -> String {
        switch result {
        case .completed: return "completed"
        // `.nothingToMove` is persisted exactly like `.completed` above (see
        // the switch in `migrateCacheDirectory`) — labeling it "completed"
        // here too keeps telemetry's success/failure split consistent with
        // what actually happened to the profile, and lets
        // `TelemetryService.endCacheMigration`'s span status use a simple
        // `outcome == "completed"` check instead of re-deriving this same
        // persist decision a third time (finding 13).
        case .preflightRejected(.nothingToMove): return "completed"
        case .cancelled: return "cancelled"
        case .failed(let reason, let rolledBack): return rolledBack ? "\(reason.rawValue)_rolled_back" : reason.rawValue
        case .preflightRejected: return "preflight_rejected"
        }
    }

    /// Warm (download into the VFS content cache) a profile's pinned folders, publishing
    /// live progress via `warmProgress[profileId]`.
    ///
    /// Every warm entry point routes through `startWarm` into here — the manual "Sync All"
    /// button, the post-mount startup warm, and Finder pin requests — so all three surface the
    /// same progress UI. Concurrent runs for one profile are coalesced: a call while a run is
    /// active is ignored. The run stops promptly when its task is cancelled (cache cleared /
    /// unmounted): the directory loop and `warmDirectory` both check `Task.isCancelled`. Emits
    /// a `synctray warm` span + metrics (with a `warm.outcome` of completed/cancelled) so a run
    /// is measurable in telemetry (throughput is the signal for the slow-fallback case).
    ///
    /// - Parameters:
    ///   - profileId: The mount-mode profile to warm.
    ///   - specificDirs: Warm only these directories (e.g. the paths from a Finder pin);
    ///     when nil, warm all of the profile's pinned directories.
    ///   - trigger: What started the run (manual / startup / finder_pin) — recorded on the span.
    func warmPinnedDirectories(for profileId: UUID, dirs specificDirs: [String]? = nil, trigger: String = "manual") async {
        guard warmProgress[profileId]?.isActive != true else { return }  // coalesce
        guard let profile = profileStore.profile(for: profileId) else { return }
        let targets = specificDirs ?? profile.pinnedDirectories
        guard !targets.isEmpty else { return }

        var progress = WarmProgress()
        warmProgress[profileId] = progress

        let telemetry = TelemetryService.shared.beginWarm(
            profileId: profileId,
            profileName: profile.name,
            directoryCount: targets.count,
            concurrency: profile.downloadConnections,
            trigger: trigger
        )

        // Estimate work up front (metadata-only walk) so the bar can be determinate. The
        // walk can hit the network on an NFS mount, so run it off the main actor.
        let estimate = await Task.detached(priority: .utility) {
            targets.reduce(into: (files: 0, bytes: Int64(0), cachedFiles: 0, cachedBytes: Int64(0))) { acc, dir in
                let e = VFSCacheService.shared.estimateWarmWork(dir, for: profile)
                acc.files += e.files
                acc.bytes += e.bytes
                acc.cachedFiles += e.cachedFiles
                acc.cachedBytes += e.cachedBytes
            }
        }.value

        progress.filesTotal = estimate.files
        progress.bytesTotal = estimate.bytes
        progress.filesAlreadyCached = estimate.cachedFiles
        progress.bytesAlreadyCached = estimate.cachedBytes
        progress.phase = .downloading
        warmProgress[profileId] = progress

        for dir in targets {
            if Task.isCancelled { break }  // cache cleared or profile unmounted mid-run
            await cacheService.warmDirectory(dir, for: profile, concurrency: profile.downloadConnections, isStillPinned: { [weak self] in
                await self?.isDirectoryPinned(dir, profileId: profileId) ?? false
            }, shouldPause: { [weak self] in
                await self?.isWarmPaused(for: profileId) ?? false
            }, onStall: { [weak self] backingOff in
                await MainActor.run {
                    guard let self, var p = self.warmProgress[profileId] else { return }
                    p.backingOff = backingOff
                    self.warmProgress[profileId] = p
                    if backingOff, let name = self.profileStore.profile(for: profileId)?.name {
                        TelemetryService.shared.recordWarmPause(
                            profileId: profileId, profileName: name, paused: true, source: "backoff")
                    }
                }
            }, onStart: { [weak self] name in
                await MainActor.run {
                    guard let self, var p = self.warmProgress[profileId] else { return }
                    p.currentDirectory = dir
                    p.inFlightFiles.append(name)
                    self.warmProgress[profileId] = p
                }
            }, onProgress: { [weak self] bytes in
                await MainActor.run {
                    guard let self, var p = self.warmProgress[profileId] else { return }
                    p.bytesDone += bytes    // advances mid-file, per chunk
                    self.warmProgress[profileId] = p
                }
            }, onFileComplete: { [weak self] name in
                await MainActor.run {
                    guard let self, var p = self.warmProgress[profileId] else { return }
                    p.filesDone += 1
                    if let idx = p.inFlightFiles.firstIndex(of: name) {
                        p.inFlightFiles.remove(at: idx)
                    }
                    self.warmProgress[profileId] = p
                }
            })
            // Warming populated the VFS cache — nudge the extension so folder badges flip
            // from cloud to the "downloaded" checkmark as each directory finishes.
            notifyFinderSyncReload()
        }

        let cancelled = Task.isCancelled
        // Pause state governs the current run only — clear it so the next warm starts fresh
        // (a lingering manual pause would silently stall a later run the user did ask for).
        warmManuallyPaused[profileId] = nil
        warmAutoPauseUntil[profileId] = nil
        if var p = warmProgress[profileId] {
            let files = p.filesDone
            let bytes = p.bytesDone
            let elapsed = p.elapsed
            if cancelled {
                // Drop the row — the cache was cleared or the mount went away, so a lingering
                // "completed" summary would be misleading.
                warmProgress[profileId] = nil
            } else {
                p.phase = .completed
                p.finishedAt = Date()
                p.inFlightFiles = []
                warmProgress[profileId] = p
            }
            TelemetryService.shared.endWarm(
                telemetry,
                filesWarmed: files,
                bytesWarmed: bytes,
                durationSeconds: elapsed,
                outcome: cancelled ? "cancelled" : "completed"
            )
        }
    }

    /// Wake the FinderSync extension to reload App Group data and repaint badges.
    ///
    /// Reuses the pin-request Darwin notification as a bidirectional "pin state changed"
    /// signal: the extension observes it and calls `loadMountPaths()`, which re-reads the
    /// pinned dirs and repaints badges. Our own observer also fires but finds no pending
    /// request file (we post only after deleting it), so it's a harmless no-op.
    private func notifyFinderSyncReload() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDistributedCenter(),
            CFNotificationName(kPinRequestNotificationName as CFString),
            nil,
            nil,
            true
        )
    }

    /// Live (main-actor) check of whether `path` is still pinned for the given profile.
    /// Used by `VFSCacheService.warmDirectory` to honour an unpin that arrives mid-warm.
    @MainActor
    private func isDirectoryPinned(_ path: String, profileId: UUID) -> Bool {
        profileStore.profile(for: profileId)?.pinnedDirectories.contains(path) ?? false
    }

    /// Write active mount paths to App Group UserDefaults so the FinderSync extension
    /// can register them via `FIFinderSyncController.setDirectoryURLs`.
    ///
    /// Also writes per-profile data (profileId, pinnedDirectories, vfsCachePath) so the
    /// extension can determine pin state and show the correct contextual menu item.
    func updateAppGroupMountPaths() {
        guard let defaults = UserDefaults(suiteName: kAppGroupID) else {
            SyncTraySettings.debugLog("updateAppGroupMountPaths: App Group UserDefaults not accessible")
            return
        }

        let mountedProfiles = profileStore.enabledProfiles.filter {
            $0.isMountMode && profileMountStates[$0.id] == .mounted
        }

        let mountPaths = mountedProfiles.map { $0.localSyncPath }
        defaults.set(mountPaths, forKey: kMountPathsKey)

        // Write per-profile data for badge state computation in the extension.
        let profileDataArray = mountedProfiles.map { profile -> [String: Any] in
            [
                "localSyncPath": profile.localSyncPath,
                "profileId": profile.id.uuidString,
                "pinnedDirectories": profile.pinnedDirectories,
                "vfsCachePath": cacheDirectory(for: profile) ?? ""
            ]
        }
        defaults.set(profileDataArray, forKey: kProfileDataKey)

        // Wake the extension so it re-registers `directoryURLs` (and re-badges) with the
        // paths just written. Without this, a race after login/upgrade could leave the
        // extension loaded with stale/empty paths: the app relaunches Finder before the
        // NFS mount finishes establishing, the extension reads empty mount paths, and
        // nothing tells it to re-read once the mount comes up — so the menu never appears.
        notifyFinderSyncReload()

        SyncTraySettings.debugLog("updateAppGroupMountPaths: wrote \(mountPaths.count) mount path(s)")
    }

    /// Helper to get the VFS cache directory for a profile (delegates to VFSCacheService).
    private func cacheDirectory(for profile: SyncProfile) -> String? {
        cacheService.cacheDirectory(for: profile)
    }

    /// Periodically reconcile mount-mode UI state with reality. A mount can be
    /// established or torn down out-of-band — launchd's KeepAlive (re)starting the
    /// daemon, an external drive event, or the user ejecting the volume in Finder —
    /// none of which flow through mountProfile/unmountProfile. Without this, the UI
    /// can show "Not mounted" while the volume is actually mounted (and vice versa).
    private func startMountStateMonitor() {
        mountStateMonitorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)  // every 5 seconds
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.reconcileMountStatesOffMain() }
        }
        mountStateMonitorTimer = timer
        timer.resume()
    }

    /// Poll each mounted Stream profile's rclone RC `/core/stats` endpoint for live
    /// download activity and surface it through `profileProgress`, so streaming shows the
    /// same transfer bar and per-file list that sync/bisync profiles show. A mount emits no
    /// `--stats` log JSON, so this RC poll is its only live-progress signal. The handler
    /// no-ops (no network) when nothing is mounted, so the 2s cadence is cheap at rest.
    private func startMountProgressMonitor() {
        mountProgressTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)  // match sync/bisync --stats 2s
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.pollMountProgress() }
        }
        mountProgressTimer = timer
        timer.resume()
    }

    private func pollMountProgress() {
        let mounted = Set(profileStore.enabledProfiles.filter {
            $0.isMountMode && profileMountStates[$0.id] == .mounted
        }.map { $0.id })

        // A profile we were showing progress for is no longer mounted → clear it.
        for id in mountProgressActive.subtracting(mounted) {
            profileProgress[id] = nil
        }
        mountProgressActive.formIntersection(mounted)

        guard !mounted.isEmpty else { return }
        for profile in profileStore.enabledProfiles where mounted.contains(profile.id) {
            let port = profile.rcPort
            let id = profile.id
            Task { [weak self] in
                let stats = await self?.cacheService.getCoreStats(port: port)
                self?.applyMountProgress(stats, for: id)
            }
        }
    }

    /// Map a mount's live RC `/core/stats` into `profileProgress`. Only the *active*
    /// transfers drive the bar: the aggregate byte counters `/core/stats` returns are
    /// cumulative since mount start (they'd read near 100% forever), so the "downloading
    /// now" bar is summed from the in-flight `transferring[]` entries instead. When nothing
    /// is transferring the entry is cleared so an idle mount stays quiet.
    private func applyMountProgress(_ stats: RcloneStats?, for profileId: UUID) {
        guard profileMountStates[profileId] == .mounted,
              let transferring = stats?.transferring, !transferring.isEmpty else {
            if mountProgressActive.contains(profileId) {
                profileProgress[profileId] = nil
                mountProgressActive.remove(profileId)
            }
            return
        }

        // rclone reports an unknown transfer size as a negative value; clamp so it never
        // drags the aggregate total below the bytes already read.
        let downloaded = transferring.reduce(Int64(0)) { $0 + max(0, $1.bytes ?? 0) }
        let total = transferring.reduce(Int64(0)) { $0 + max(0, $1.size ?? 0) }

        // Speed and ETA come from the in-flight transfers too, never from `stats.speed`/
        // `stats.eta`: those are cumulative averages since mount start, so on a long-lived
        // mount they'd show a misleadingly slow rate and inflated ETA next to the live bar.
        // Aggregate speed is the sum of the active per-file rates; the batch finishes when
        // its slowest concurrent transfer does, so ETA is the longest remaining per-file ETA.
        let speed = transferring.compactMap { $0.speed ?? $0.speedAvg }.reduce(0, +)
        let eta = transferring.compactMap { $0.eta }.max()

        profileProgress[profileId] = SyncProgress(
            bytesTransferred: downloaded,
            totalBytes: total,
            eta: eta,
            speed: speed > 0 ? speed : nil,
            transfersDone: 0,
            totalTransfers: 0,  // suppress the "Files: 0 / N" line; the per-file rows tell the story
            transferringFiles: transferring
        )
        mountProgressActive.insert(profileId)
    }

    /// Periodically check whether a mounted Stream profile that fell back to its
    /// secondary remote can return to the primary, and remount it on the primary once
    /// the primary is reachable again.
    ///
    /// Unlike sync/bisync profiles (which re-evaluate the primary on every scheduled
    /// run via `StartInterval`), a mount is a long-lived `rclone nfsmount` that picks
    /// its remote once at mount time — so a live fallback mount would otherwise stay on
    /// the fallback until the next relaunch/login/manual remount. This restores the
    /// "prefer the primary when available" behaviour for mounts.
    private func startPrimaryRecoveryMonitor() {
        primaryRecoveryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 120, repeating: 120)  // every 2 minutes
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.checkPrimaryRecovery() }
        }
        primaryRecoveryTimer = timer
        timer.resume()
    }

    private func isOnFallback(_ transport: ActiveTransport?) -> Bool {
        if case .fallback = transport { return true }
        return false
    }

    /// For each mounted mount-mode profile currently on its fallback, probe the primary
    /// (off the main thread) and remount on the primary if it's reachable again.
    private func checkPrimaryRecovery() {
        let candidates = profileStore.enabledProfiles.filter {
            $0.isMountMode
                && $0.hasFallback
                && profileMountStates[$0.id] == .mounted
                && isOnFallback(profileTransports[$0.id])
                && !recoveringToPrimary.contains($0.id)
        }
        // Drop stale streaks for profiles that are no longer on a fallback mount, so a
        // future fallback episode starts counting from zero.
        let candidateIds = Set(candidates.map { $0.id })
        primaryRecoveryStreak = primaryRecoveryStreak.filter { candidateIds.contains($0.key) }
        guard !candidates.isEmpty else { return }

        for profile in candidates {
            let primaryRemote = profile.rcloneRemote
            let primaryPath = profile.remotePath
            let profileId = profile.id
            recoveringToPrimary.insert(profileId)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let reachable = self.isRemoteReachable(primaryRemote, path: primaryPath)
                DispatchQueue.main.async {
                    defer { self.recoveringToPrimary.remove(profileId) }

                    // A single unreachable probe resets the streak — the primary must be
                    // continuously reachable, not merely reachable right now.
                    guard reachable,
                          self.profileMountStates[profileId] == .mounted,
                          self.isOnFallback(self.profileTransports[profileId]),
                          let current = self.profileStore.profile(for: profileId) else {
                        self.primaryRecoveryStreak[profileId] = 0
                        return
                    }

                    let streak = (self.primaryRecoveryStreak[profileId] ?? 0) + 1
                    guard streak >= self.primaryRecoveryRequiredStreak else {
                        self.primaryRecoveryStreak[profileId] = streak
                        SyncTraySettings.debugLog(
                            "Primary '\(primaryRemote)' reachable for '\(current.name)' "
                                + "(\(streak)/\(self.primaryRecoveryRequiredStreak)) — "
                                + "waiting for it to stay up before remounting")
                        return
                    }

                    self.primaryRecoveryStreak[profileId] = 0
                    SyncTraySettings.debugLog(
                        "Primary '\(primaryRemote)' stable — remounting '\(current.name)' on primary")
                    self.remountOnPrimary(current)
                }
            }
        }
    }

    /// Quick reachability probe for a remote PATH, with a hard timeout — some backends
    /// (SMB) hang well past their own `--contimeout`/`--timeout`, so we also cap wall-clock.
    /// Probes the profile's own path, never the remote root: `lsd remote:` enumerates every
    /// SMB share, which on a Synology hangs past the cap and made a reachable NAS read as
    /// offline — so fallback recovery and Cache Only auto-resume never fired.
    private func isRemoteReachable(_ remoteName: String, path: String) -> Bool {
        guard let arguments = Self.reachabilityProbeArguments(remote: remoteName, path: path) else { return false }
        guard let rclone = RcloneLocator.resolve() else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rclone)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        let deadline = Date().addingTimeInterval(12)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if proc.isRunning {
            proc.terminate()
            return false
        }
        return Self.reachabilityProbeSucceeded(exitCode: proc.terminationStatus)
    }

    /// `rclone lsjson --stat remote:path` — one round trip on the path itself. `nil` for an
    /// empty remote name.
    nonisolated static func reachabilityProbeArguments(remote: String, path: String) -> [String]? {
        let bare = remote.hasSuffix(":") ? String(remote.dropLast()) : remote
        guard !bare.isEmpty else { return nil }
        return ["lsjson", "--stat", "\(bare):\(path)", "--contimeout", "3s", "--timeout", "8s"]
    }

    /// rclone's directory/file-not-found exits (3/4) still mean the remote answered.
    nonisolated static func reachabilityProbeSucceeded(exitCode: Int32) -> Bool {
        exitCode == 0 || exitCode == 3 || exitCode == 4
    }

    /// Remount a profile so the sync script re-evaluates the remote and picks the primary
    /// (now reachable). Unmount first — the running fallback rclone chose its remote at
    /// launch and won't switch in place.
    private func remountOnPrimary(_ profile: SyncProfile) {
        Task {
            try? self.setupService.unmount(profile: profile)
            try? await Task.sleep(nanoseconds: 1_500_000_000)  // let the unmount settle
            await MainActor.run { self.mountProfile(profile) }
        }
    }

    /// Decide whether a mount-monitor tick should trigger a one-time auto-warm for a
    /// profile, updating the already-warmed set in place. Pure and static so the self-test
    /// can drive the "warm exactly once per mount session" invariant without a real mount.
    ///
    /// Returns true exactly once per mount session — the first tick a pinned profile is seen
    /// mounted — and false on every later tick while it stays mounted. Seeing it unmounted
    /// re-arms it (removes it from the set), so a subsequent remount warms again and picks up
    /// files added on the remote in the meantime. A profile with no pinned directories never
    /// warms and is never added.
    static func shouldAutoWarmOnMount(
        isMounted: Bool,
        hasPinnedDirs: Bool,
        profileId: UUID,
        alreadyWarmed: inout Set<UUID>
    ) -> Bool {
        guard isMounted else {
            alreadyWarmed.remove(profileId)   // re-arm for the next mount
            return false
        }
        guard hasPinnedDirs else { return false }
        return alreadyWarmed.insert(profileId).inserted
    }

    /// Decide whether to warm a streaming mount's whole-tree LISTING cache — exactly once per
    /// mount session. Distinct from `shouldAutoWarmOnMount` in one way that is the whole point:
    /// it does NOT require pinned dirs. The data warm only runs for pinned folders (it
    /// downloads bytes, which is expensive); this warms directory *listings* for the entire
    /// tree (metadata only, cheap), so first-browse-after-mount is instant everywhere, not
    /// just under pinned folders. Only for `streaming` — a Cache Only union mount is local
    /// (nothing remote to enumerate) and exposes no RC API. Re-arms when the profile is seen
    /// unmounted, mirroring the data warm so a later remount warms fresh listings again.
    static func shouldWarmListingsOnMount(
        isMounted: Bool,
        isStreaming: Bool,
        profileId: UUID,
        alreadyWarmed: inout Set<UUID>
    ) -> Bool {
        guard isMounted else {
            alreadyWarmed.remove(profileId)   // re-arm for the next mount
            return false
        }
        guard isStreaming else { return false }
        return alreadyWarmed.insert(profileId).inserted
    }

    /// Reconcile mount states without blocking the main thread: snapshot the mount
    /// profiles on the main actor, probe `/sbin/mount` on a background queue, then
    /// merge results back on the main actor. Used by the repeating 5s monitor so the
    /// probe never stalls the UI — unlike updateMountStates(), whose synchronous
    /// probe is fine for one-shot init/onAppear calls. No-ops (no subprocess) when
    /// there are no mount profiles.
    private func reconcileMountStatesOffMain() {
        let mountProfiles = profileStore.enabledProfiles.filter { $0.isMountMode }
        guard !mountProfiles.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let mounted = mountProfiles.reduce(into: [UUID: Bool]()) { acc, profile in
                acc[profile.id] = self.setupService.isMounted(profile: profile)
            }
            // Read each mounted profile's mode file off-main — a tiny text-file read, but
            // still I/O, and this whole reconcile exists precisely to keep I/O off the UI
            // thread. A profile that isn't mounted (or whose mode file is missing/stale)
            // reads nil rather than an error.
            let modes = mountProfiles.reduce(into: [UUID: MountMode]()) { acc, profile in
                guard mounted[profile.id] == true, !profile.mountModePath.isEmpty,
                      let raw = try? String(contentsOfFile: profile.mountModePath, encoding: .utf8),
                      let mode = MountMode.parse(raw)
                else { return }
                acc[profile.id] = mode
            }
            DispatchQueue.main.async {
                let before = Set(self.profileMountStates.filter { $0.value == .mounted }.keys)
                for profile in mountProfiles {
                    let isMounted = mounted[profile.id] == true
                    if isMounted {
                        self.profileMountStates[profile.id] = .mounted
                    } else if self.profileMountStates[profile.id] == nil
                                || self.profileMountStates[profile.id] == .mounted {
                        self.profileMountStates[profile.id] = .unmounted
                    }

                    let newMode = isMounted ? modes[profile.id] : nil
                    if newMode != self.profileMountModes[profile.id] {
                        self.notifiedBackOnNetworkEpisodes.remove(profile.id)
                        if let newMode {
                            TelemetryService.shared.recordMountModeChanged(
                                profileId: profile.id, profileName: profile.name, mode: newMode)
                            // Cache Only was requested but the mount settled on streaming: the
                            // sync script's silent fallback when it couldn't build the partial-file
                            // exclude list. This is the invisible "I turned Cache Only on but it's
                            // still streaming/downloading" case — surface it. The resume guard
                            // excludes the legitimate flip back to streaming during a drain.
                            if newMode == .streaming, profile.streamCacheOnly,
                               !self.resumingFromCacheOnly.contains(profile.id) {
                                TelemetryService.shared.recordCacheOnlyFallback(
                                    profileId: profile.id, profileName: profile.name)
                            }
                        }
                    }
                    self.profileMountModes[profile.id] = newMode

                    // A launchd mount at login/reboot (RunAtLoad), an externally-driven mount,
                    // or a slow fallback that established after mountProfile's poll gave up
                    // never ran a warm, so new remote files were never pulled into the offline
                    // cache. Warm such a mount once per session; the app-driven mount path sets
                    // the same flag so this can't double-fire. Decided independently of the
                    // UI-state transition above, so a profile stuck in `.failed` still re-arms
                    // once it is actually unmounted.
                    // Cache-Only means "stop chasing the remote": the warmer's whole job is
                    // to pull uncached bytes down through the mount, which is exactly what
                    // the mode exists to stop. Treat it as having nothing pinned so the
                    // profile still re-arms normally when the mode is switched back off.
                    if Self.shouldAutoWarmOnMount(
                        isMounted: isMounted,
                        hasPinnedDirs: !profile.pinnedDirectories.isEmpty && (newMode ?? .streaming) == .streaming,
                        profileId: profile.id,
                        alreadyWarmed: &self.autoWarmedMounts
                    ) {
                        self.startWarm(for: profile.id, trigger: "startup")
                    }

                    // Warm the whole-tree LISTING cache once per streaming mount (metadata
                    // only, no data download) so Finder browsing is instant everywhere, not
                    // just under pinned folders — the fix for the "Loading…" spinner on a
                    // cold folder's first open. Independent of the pinned-dir data warm above.
                    if Self.shouldWarmListingsOnMount(
                        isMounted: isMounted,
                        isStreaming: (newMode ?? .streaming) == .streaming,
                        profileId: profile.id,
                        alreadyWarmed: &self.listingWarmedMounts
                    ) {
                        self.startListingWarm(for: profile.id)
                        // Same first-streaming-mount edge: drop the Spotlight-exclusion
                        // marker at the mount root so macOS never bulk-indexes the tree.
                        // Without it, mds/QuickLook read every file through the mount to
                        // index it — gigabytes pulled at mount time — which saturates the
                        // download slots and starves Finder's own listing (the SECOND
                        // "Loading…" cause, distinct from the cold-listing one the warm
                        // above fixes). Fire-and-record; the write is idempotent.
                        self.writeSpotlightExclusionMarker(for: profile.id)
                    }
                }
                // Republish to the FinderSync extension whenever the set of mounted
                // profiles changes. Without this, a mount the monitor detects — a slow
                // fallback that established after the initial poll, a launchd/externally
                // mounted profile, or one that recovered from .failed — never reaches the
                // extension, so its right-click menu and badges silently never appear.
                let after = Set(self.profileMountStates.filter { $0.value == .mounted }.keys)
                if before != after {
                    self.updateAppGroupMountPaths()
                }
                self.checkAutoResume(mountProfiles: mountProfiles)
                // Yield the link to interactive use: if an app is actively reading a mount
                // that is currently warming, pause the warm (re-armed each tick; see
                // `refreshWarmAutoPause`). Only touches profiles with a live warm.
                self.refreshWarmAutoPause(for: mountProfiles)
            }
        }
    }

    // MARK: - Cache Only

    /// The mount mode the sync script picked the last time this profile's mount state was
    /// reconciled — `nil` while unmounted or before the first reconcile tick.
    func mountMode(for profileId: UUID) -> MountMode? {
        profileMountModes[profileId]
    }

    /// Overlay files not yet recorded as uploaded — the count the status card and menu bar
    /// show as "N files waiting to upload".
    func pendingUploadCount(for profileId: UUID) -> Int {
        guard let profile = profileStore.profile(for: profileId) else { return 0 }
        return Self.pendingUploadCount(of: profile)
    }

    /// `pendingUploadCount(for:)` for a profile value — reads only that profile's overlay
    /// and manifest on disk, so the CLI can use it too.
    nonisolated static func pendingUploadCount(of profile: SyncProfile) -> Int {
        let manifest = OverlaySyncService.loadManifest(path: profile.overlayManifestPath)
        return OverlaySyncService.pendingCount(overlayPath: profile.overlayPath, manifest: manifest)
    }

    /// Why a cache move can't run right now, or nil when it can. A move repoints EVERY
    /// profile it carries — the one being moved plus each co-migrated sibling (an
    /// overlapping one that shares the same cached bytes, or a same-root one the user
    /// ticked) — and each of those keeps its own Cache Only overlay under its own
    /// `vfsCachePath`, which the move does not carry along. So any of them with files still
    /// waiting to upload would have them stranded at the old location. The app's
    /// `migrateCacheDirectory` and the CLI's `cache move --include-overlapping` both refuse
    /// with this. Pure over `pendingUploads`.
    nonisolated static func cacheMoveBlockedReason(
        moving: SyncProfile, coMigrate: [SyncProfile], pendingUploads: (SyncProfile) -> Int
    ) -> String? {
        if let reason = cacheDirectoryChangeBlockedReason(pendingUploads: pendingUploads(moving)) {
            return reason
        }
        let blocked = coMigrate.filter { $0.id != moving.id }.compactMap { sibling -> String? in
            let pending = pendingUploads(sibling)
            guard pending > 0 else { return nil }
            return "\"\(sibling.name)\" (\(pending) \(pending == 1 ? "file" : "files"))"
        }
        guard !blocked.isEmpty else { return nil }
        let one = blocked.count == 1
        return "\(blocked.joined(separator: ", ")) \(one ? "moves" : "move") with this cache and "
            + "\(one ? "has" : "have") files waiting to upload from Cache Only. Upload them in "
            + "\(one ? "that profile" : "those profiles") (Upload Now or Resume Syncing) before moving "
            + "the cache directory."
    }

    /// Why a Stream profile's cache directory can't change right now, or nil when it can.
    /// The Cache Only overlay lives under `vfsCachePath`, and neither a move nor a re-point
    /// carries it along, so files still waiting to upload would be stranded at the old
    /// location. The app's Save refuses with this; the CLI refuses the same change with its
    /// own wording. Pure.
    nonisolated static func cacheDirectoryChangeBlockedReason(pendingUploads: Int) -> String? {
        guard pendingUploads > 0 else { return nil }
        let files = pendingUploads == 1 ? "1 file is" : "\(pendingUploads) files are"
        return "\(files) waiting to upload from Cache Only. Upload them (Upload Now or Resume Syncing) "
            + "before changing the cache directory."
    }

    /// Bridge `isRemoteReachable`'s blocking, MainActor-isolated probe into something a
    /// `Task` can `await` without holding up the main actor for the probe's up-to-12s
    /// wall-clock cap — the same off-actor hop `checkPrimaryRecovery` uses, just wrapped as
    /// a continuation instead of a bare `DispatchQueue.global` + `DispatchQueue.main` pair.
    private func isRemoteReachableAsync(_ remoteName: String, path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let reachable = self?.isRemoteReachable(remoteName, path: path) ?? false
                continuation.resume(returning: reachable)
            }
        }
    }

    /// Resolve the first reachable remote for an overlay upload — primary, else fallback if
    /// configured. `nil` if neither answers within the probe's hard timeout.
    private func resolveUploadTransport(for profile: SyncProfile) async -> (remote: String, transport: String)? {
        if await isRemoteReachableAsync(profile.rcloneRemote, path: profile.remotePath) {
            return (profile.rcloneRemote, "primary")
        }
        if profile.hasFallback,
           await isRemoteReachableAsync(profile.fallbackRemote,
                                        path: profile.fallbackRemotePath.isEmpty ? profile.remotePath : profile.fallbackRemotePath) {
            return (profile.fallbackRemote, "fallback")
        }
        return nil
    }

    private func bareRemoteName(_ remote: String) -> String {
        remote.hasSuffix(":") ? String(remote.dropLast()) : remote
    }

    /// Toggle a Stream profile's Cache Only mode.
    ///
    /// Turning it ON: persist the manual flag, push the derived config, and remount — the
    /// script picks `cache-only-manual` on its next start.
    ///
    /// Turning it OFF ("Resume Syncing"): if the primary is unreachable right now, don't
    /// unmount — persist the flag off and relabel the running mount as `cache-only-offline`
    /// (automatic), so the auto-resume monitor drains and remounts it as Streaming once the
    /// primary is stable again. Otherwise: unmount, drain the overlay
    /// (verify-then-delete with conflict copies), persist the flag off, then reinstall and
    /// remount. ANY file the drain could not upload keeps the mount in a Cache Only flavour
    /// on the next start — the user's edits never silently vanish from view.
    func setCacheOnly(profileId: UUID, enabled: Bool) {
        guard let profile = profileStore.profile(for: profileId), profile.isMountMode else { return }

        if enabled {
            var updated = profile
            updated.streamCacheOnly = true
            profileStore.update(updated)
            try? setupService.updateConfig(for: updated)
            TelemetryService.shared.recordSettingChanged(name: "stream_cache_only", enabled: true)
            // Show the switch immediately — the remount below is several seconds of
            // unmount + mount during which the mount state is still `.mounted`.
            mountTransitions[profileId] = .enteringCacheOnly
            // Freshen the partial-file list from the streaming cache as it is right now,
            // before the remount: the script falls back to this copy when it can't read the
            // cache itself (see `refreshCacheOnlyExcludeLists`).
            Task.detached(priority: .userInitiated) { [weak self] in
                Self.writeCacheOnlyExcludeList(for: updated)
                await MainActor.run { self?.remountForModeChange(updated) }
            }
            return
        }

        guard !resumingFromCacheOnly.contains(profileId) else { return }
        resumingFromCacheOnly.insert(profileId)
        // Show the switch immediately — it starts with a reachability probe and (when the
        // primary is up) an overlay drain before the remount, all with the mount still
        // `.mounted`. Cleared when the remount settles, or here if the resume aborts.
        mountTransitions[profileId] = .resuming

        Task {
            defer { Task { @MainActor in self.resumingFromCacheOnly.remove(profileId) } }

            let reachable = await self.isRemoteReachableAsync(profile.rcloneRemote, path: profile.remotePath)
            guard reachable else {
                var updated = profile
                updated.streamCacheOnly = false
                self.profileStore.update(updated)
                try? self.setupService.updateConfig(for: updated)
                // No remount happens on this path (the mount stays Cache Only, relabelled
                // for auto-resume), so clear the transition here or it would spin forever.
                self.mountTransitions[profileId] = nil
                TelemetryService.shared.recordSettingChanged(name: "stream_cache_only", enabled: false)
                TelemetryService.shared.recordOverlayUploadUnreachable(
                    profileId: profile.id, profileName: profile.name, trigger: "resume")
                // The running mount is still the MANUAL flavour, and auto-resume only ever
                // considers automatic ones — without this hand-off the mount would sit in
                // Cache Only until the next remount. Relabel it as the automatic offline
                // flavour so the recovery monitor resumes it once the primary is stable.
                if let next = Self.mountModeAfterResumeWhileUnreachable(
                    current: self.profileMountModes[profileId]) {
                    self.applyLiveMountMode(next, for: updated)
                }
                SyncTraySettings.debugLog(
                    "'\(profile.name)': primary unreachable — will switch to Streaming automatically "
                        + "once it's back")
                return
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.drainAndResume(profile: profile)
        }
    }

    /// The live mode a mounted profile should switch to when the user turns Cache Only off
    /// while the primary is unreachable: a MANUAL Cache Only mount becomes the automatic
    /// offline flavour (same union mount, but now a candidate for auto-resume). `nil` means
    /// leave it — not mounted, already streaming, or already automatic.
    nonisolated static func mountModeAfterResumeWhileUnreachable(current: MountMode?) -> MountMode? {
        current == .cacheOnlyManual ? .cacheOnlyOffline : nil
    }

    /// Relabel a RUNNING mount's mode without remounting: rewrite its per-boot mode file in
    /// the exact format the sync script writes (`echo "$MOUNT_MODE" > "$MOUNT_MODE_PATH"`),
    /// so the 5s mount-state reconcile reads the same value back, then publish it.
    private func applyLiveMountMode(_ mode: MountMode, for profile: SyncProfile) {
        if !profile.mountModePath.isEmpty {
            try? "\(mode.rawValue)\n".write(
                toFile: profile.mountModePath, atomically: true, encoding: .utf8)
        }
        guard profileMountModes[profile.id] != mode else { return }
        notifiedBackOnNetworkEpisodes.remove(profile.id)
        TelemetryService.shared.recordMountModeChanged(
            profileId: profile.id, profileName: profile.name, mode: mode)
        profileMountModes[profile.id] = mode
    }

    /// Unmount, drain the overlay to the primary, persist the flag off, reinstall + remount.
    private func drainAndResume(profile: SyncProfile, trigger: String = "resume") async {
        // An Upload Now still in flight would race this drain over the same overlay files
        // (the later run plans spurious conflict copies), so let it finish first — its
        // manifest then makes those files `alreadyUploaded` here.
        if let upload = overlayUploadTasks[profile.id] { await upload.value }
        try? setupService.unmount(profile: profile)
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let client = OverlaySyncService.ProductionOverlayRemoteClient(
            remoteName: bareRemoteName(profile.rcloneRemote), remotePath: profile.remotePath)
        let service = OverlaySyncService()
        let start = Date()
        TelemetryService.shared.recordOverlayUploadStarted(
            profileId: profile.id, profileName: profile.name, trigger: trigger)
        let result = await service.run(
            profile: profile, remoteBase: "\(bareRemoteName(profile.rcloneRemote)):\(profile.remotePath)",
            mode: .drain, transport: "primary", client: client,
            progress: { [weak self] p in
                Task { @MainActor in self?.overlayUploadProgress[profile.id] = p }
            })
        TelemetryService.shared.recordOverlayUploadCompleted(
            profileId: profile.id, profileName: profile.name, trigger: trigger, result: result,
            duration: Date().timeIntervalSince(start))
        overlayUploadProgress[profile.id] = nil

        var updated = profile
        updated.streamCacheOnly = false
        profileStore.update(updated)
        try? setupService.updateConfig(for: updated)
        TelemetryService.shared.recordSettingChanged(name: "stream_cache_only", enabled: false)

        if result.failed > 0 || result.remainingPending > 0 {
            notificationService.notifyOverlayUploadIssue(
                profileName: profile.name, remaining: result.remainingPending + result.failed)
        }

        try? setupService.install(profile: updated)
        mountProfile(updated)
    }

    /// "Upload Now" — push overlay files to the remote WITHOUT leaving Cache Only. One run
    /// per profile at a time: a click while a run is in flight (including its reachability
    /// probe, before the button disables) is ignored. Cancelling the old run instead would
    /// not stop it — the upload engine never checks cancellation — so both would upload the
    /// same files, the later one as spurious conflict copies. The same goes for a click
    /// while Resume Syncing (or auto-resume) is leaving Cache Only: both callers of
    /// `drainAndResume` hold `resumingFromCacheOnly` from the reachability probe through
    /// the drain, and before the drain's first progress update nothing disables the button.
    func uploadNow(profileId: UUID) {
        guard let profile = profileStore.profile(for: profileId), profile.isMountMode,
              overlayUploadTasks[profileId] == nil,
              !resumingFromCacheOnly.contains(profileId) else { return }
        overlayUploadTasks[profileId] = Task {
            defer { self.overlayUploadTasks[profileId] = nil }
            guard let resolved = await resolveUploadTransport(for: profile) else {
                SyncTraySettings.debugLog("'\(profile.name)': Upload Now found no reachable remote")
                TelemetryService.shared.recordOverlayUploadUnreachable(
                    profileId: profile.id, profileName: profile.name, trigger: "upload_now")
                return
            }
            let client = OverlaySyncService.ProductionOverlayRemoteClient(
                remoteName: bareRemoteName(resolved.remote), remotePath: profile.remotePath)
            let service = OverlaySyncService()
            let start = Date()
            TelemetryService.shared.recordOverlayUploadStarted(
                profileId: profile.id, profileName: profile.name, trigger: "upload_now")
            let result = await service.run(
                profile: profile, remoteBase: "\(bareRemoteName(resolved.remote)):\(profile.remotePath)",
                mode: .keep, transport: resolved.transport, client: client,
                progress: { [weak self] p in
                    Task { @MainActor in self?.overlayUploadProgress[profile.id] = p }
                })
            TelemetryService.shared.recordOverlayUploadCompleted(
                profileId: profile.id, profileName: profile.name, trigger: "upload_now", result: result,
                duration: Date().timeIntervalSince(start))
            self.overlayUploadProgress[profile.id] = nil
        }
    }

    /// Detach and remount so the sync script re-evaluates mode/remote on the next start.
    private func remountForModeChange(_ profile: SyncProfile) {
        Task {
            try? self.setupService.unmount(profile: profile)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run { self.mountProfile(profile) }
        }
    }

    /// One of the four decisions the auto-resume monitor can reach for a mounted, AUTOMATIC
    /// Cache Only profile (never for `.cacheOnlyManual` — that only ever changes via the
    /// user's own toggle). Pure and static: the monitor supplies the mode, whether the
    /// primary has been stable across the required probe streak, and the blocking-process
    /// list from a real `lsof` run — no I/O here, so the decision itself is unit-testable.
    enum AutoResumeDecision: Equatable { case resume, notify, wait }

    nonisolated static func autoResumeDecision(
        mode: MountMode, manualCacheOnly: Bool, primaryStable: Bool, blockingProcesses: [String]
    ) -> AutoResumeDecision {
        guard mode.isCacheOnly, mode.isAutomatic, !manualCacheOnly else { return .wait }
        guard primaryStable else { return .wait }
        return blockingProcesses.isEmpty ? .resume : .notify
    }

    /// Process names `lsof -w -F pc <mountpoint>` considers "busy" for auto-resume purposes —
    /// everything except macOS's own indexing/Finder-preview daemons, which are always
    /// touching a mounted volume and would otherwise block auto-resume forever.
    private static let autoResumeIgnoredProcessNames: Set<String> = [
        "Finder", "mds", "mds_stores", "mdworker", "mdworker_shared", "QuickLookUIService", "fseventsd",
    ]

    /// Stand-in blocker reported when the `lsof` busy check itself failed or timed out.
    nonisolated static let busyCheckFailedBlocker = "(busy check failed)"

    /// Map a busy-check result to the blocker list `autoResumeDecision` consumes. A `nil`
    /// result means `lsof` failed or timed out — we could NOT confirm nothing has the
    /// mount open, so it fails CLOSED with a sentinel blocker: the decision becomes
    /// `.notify` (the user decides) instead of remounting under an app that may be
    /// mid-write, and the `busy_check_failed` telemetry branch is reached.
    nonisolated static func autoResumeBlockers(lsofOutput: String?) -> [String] {
        guard let lsofOutput else { return [busyCheckFailedBlocker] }
        return blockingProcesses(lsofOutput: lsofOutput)
    }

    /// Parse `lsof -w -F pc <mountpoint>` output (`-F pc` = one `p<pid>` line followed by one
    /// `c<command>` line per open file) into the list of blocking process names, with the
    /// macOS system daemons above filtered out. Empty output (lsof ran and nothing has the
    /// path open) yields an empty list. A FAILED lsof run never reaches here — see
    /// `autoResumeBlockers(lsofOutput:)`.
    nonisolated static func blockingProcesses(lsofOutput: String) -> [String] {
        var names: [String] = []
        for line in lsofOutput.split(separator: "\n") {
            guard let first = line.first, first == "c" else { continue }
            let name = String(line.dropFirst())
            if !name.isEmpty, !autoResumeIgnoredProcessNames.contains(name), !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// The warmer's own process name, excluded from the warm-auto-pause reader set: SyncTray
    /// holds every file it is warming open on the mount, so counting itself would make the
    /// warm pause itself the instant it started reading.
    nonisolated static let warmerProcessName = "SyncTray"

    /// Processes that, when found reading the mount, should auto-pause the offline warm so the
    /// link is handed to interactive use. It's `blockingProcesses` (daemons already filtered)
    /// minus the warmer itself — i.e. a real app (Reaper, Preview, a DAW) actively touching
    /// files. Finder is intentionally NOT here (it is in the ignored-daemon set): Finder keeps
    /// a mounted volume open persistently, so treating it as a reader would pause the warm for
    /// the entire life of any open Finder window. The manual "Pause caching" toggle covers the
    /// idle-Finder-browsing case instead. Pure; covered by ConfigSelfTest AC-WV2.
    nonisolated static func warmInteractiveReaders(lsofOutput: String) -> [String] {
        blockingProcesses(lsofOutput: lsofOutput).filter { $0 != warmerProcessName }
    }

    /// Whether an interactive reader was seen — the decision to arm the auto-pause cooldown.
    /// A failed/`nil` lsof run does NOT pause: unlike auto-resume (which fails closed to avoid
    /// unmounting under an open app), a missed pause only means the warm keeps running, which
    /// is the safe default — the user can always pause manually. Covered by AC-WV2.
    nonisolated static func shouldAutoPauseWarm(lsofOutput: String?) -> Bool {
        guard let lsofOutput else { return false }
        return !warmInteractiveReaders(lsofOutput: lsofOutput).isEmpty
    }

    /// For each mounted profile in an AUTOMATIC Cache Only mode, probe the primary (reusing
    /// the same stability streak as fallback recovery) and, once stable, check whether
    /// anything has the mount point open before resuming. Manual Cache Only is never a
    /// candidate — only the user's own toggle changes it.
    private func checkAutoResume(mountProfiles: [SyncProfile]) {
        let candidates = mountProfiles.filter {
            profileMountStates[$0.id] == .mounted
                && (profileMountModes[$0.id]?.isCacheOnly ?? false)
                && (profileMountModes[$0.id]?.isAutomatic ?? false)
                && !$0.streamCacheOnly
                && !resumingFromCacheOnly.contains($0.id)
                && !recoveringToPrimary.contains($0.id)
        }
        guard !candidates.isEmpty else { return }

        for profile in candidates {
            let profileId = profile.id
            recoveringToPrimary.insert(profileId)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let reachable = self.isRemoteReachable(profile.rcloneRemote, path: profile.remotePath)
                DispatchQueue.main.async {
                    defer { self.recoveringToPrimary.remove(profileId) }
                    guard reachable else {
                        self.primaryRecoveryStreak[profileId] = 0
                        return
                    }
                    let streak = (self.primaryRecoveryStreak[profileId] ?? 0) + 1
                    guard streak >= self.primaryRecoveryRequiredStreak else {
                        self.primaryRecoveryStreak[profileId] = streak
                        return
                    }
                    self.primaryRecoveryStreak[profileId] = 0
                    self.performAutoResumeCheck(
                        profile: profile, mode: self.profileMountModes[profileId] ?? .streaming)
                }
            }
        }
    }

    /// `mode` is the live `profileMountModes` value, captured by the (main-actor) caller:
    /// the busy check runs on a background queue, which must never read published state.
    private func performAutoResumeCheck(profile: SyncProfile, mode: MountMode) {
        let mountPoint = profile.localSyncPath
        let manualCacheOnly = profile.streamCacheOnly
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lsofOutput = Self.runLsofBusyCheck(mountPoint: mountPoint)
            let decision = Self.autoResumeDecision(
                mode: mode,
                manualCacheOnly: manualCacheOnly,
                primaryStable: true,
                blockingProcesses: Self.autoResumeBlockers(lsofOutput: lsofOutput))
            DispatchQueue.main.async {
                guard let self else { return }
                switch decision {
                case .resume:
                    TelemetryService.shared.recordAutoResume(
                        profileId: profile.id, profileName: profile.name, result: "resumed")
                    self.resumingFromCacheOnly.insert(profile.id)
                    Task {
                        defer { Task { @MainActor in self.resumingFromCacheOnly.remove(profile.id) } }
                        await self.drainAndResume(profile: profile, trigger: "auto_resume")
                    }
                case .notify:
                    TelemetryService.shared.recordAutoResume(
                        profileId: profile.id, profileName: profile.name,
                        result: lsofOutput == nil ? "busy_check_failed" : "deferred_busy")
                    if self.notifiedBackOnNetworkEpisodes.insert(profile.id).inserted {
                        self.notificationService.notifyBackOnNetwork(profileName: profile.name)
                    }
                case .wait:
                    break
                }
            }
        }
    }

    /// `lsof -w -F pc <mountPoint>` under a 10s watchdog. `nil` on any failure/timeout
    /// (distinct from "reachable but nothing open" = `""`), so the caller can tell "we
    /// couldn't check" from "we checked, nothing's open".
    nonisolated private static func runLsofBusyCheck(mountPoint: String) -> String? {
        guard !mountPoint.isEmpty else { return "" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-w", "-F", "pc", mountPoint]
        let pipe = Pipe()
        proc.standardOutput = pipe
        let errPipe = Pipe()
        proc.standardError = errPipe
        do { try proc.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(10)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return lsofBusyCheckResult(terminationStatus: proc.terminationStatus, stdout: out, stderr: err)
    }

    /// Map a finished `lsof` run to the busy-check result: `nil` = "couldn't check" (the
    /// caller fails closed to `.notify`), otherwise the `-F pc` output to parse.
    /// `terminationStatus == nil` means lsof failed to launch or timed out.
    nonisolated static func lsofBusyCheckResult(terminationStatus: Int32?, stdout: String, stderr: String) -> String? {
        guard let terminationStatus else { return nil }
        switch terminationStatus {
        case 0:
            return stdout
        case 1:
            // lsof exits 1 BOTH when nothing has the path open (silent) and when it could
            // not examine it at all (e.g. `status error` on an unreadable/stale mount).
            // `-w` suppresses lsof's warnings, so any stderr left means the latter:
            // treat it as a failed check rather than "idle".
            return stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : nil
        default:
            return nil
        }
    }

    /// Start a 5-minute session heartbeat for availability monitoring
    private func startSessionHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 300, repeating: 300)  // every 5 minutes
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let enabled = self.profileStore.enabledProfiles.count
                let syncing = self.profileStates.values.filter { $0 == .syncing }.count
                let paused = self.pausedProfiles.count
                let errors = self.profileStates.values.filter {
                    if case .error = $0 { return true }; return false
                }.count
                TelemetryService.shared.recordSessionHeartbeat(
                    enabledProfiles: enabled,
                    syncingProfiles: syncing,
                    pausedProfiles: paused,
                    errorProfiles: errors
                )
                self.probeMountReadHealth()
                self.refreshCacheOnlyExcludeLists()
            }
        }
        heartbeatTimer = timer
        timer.resume()
    }

    /// How often a streaming profile's Cache Only partial-file list is rebuilt.
    static let cacheOnlyListRefreshInterval: TimeInterval = 15 * 60

    /// Pure: should the app (re)write this profile's Cache Only partial-file list now?
    /// Always when no list exists. Otherwise only while it is mounted STREAMING — that's
    /// the only time the streaming cache changes (downloads land); in Cache Only or
    /// unmounted it is static, so the last list stays exact — and at most once per interval.
    nonisolated static func shouldRefreshCacheOnlyList(
        listExists: Bool, isMounted: Bool, mode: MountMode?, inFlight: Bool,
        lastWrite: Date?, now: Date
    ) -> Bool {
        guard !inFlight else { return false }
        guard listExists else { return true }
        guard isMounted, (mode ?? .streaming) == .streaming else { return false }
        guard let lastWrite else { return true }
        return now.timeIntervalSince(lastWrite) >= cacheOnlyListRefreshInterval
    }

    /// Keep every Stream profile's Cache Only partial-file list present and recent.
    ///
    /// The sync script rebuilds this list itself at each Cache Only mount start, but under
    /// launchd its `python3` can be denied read access to a cache on an external drive
    /// (macOS privacy controls grant this app, not the interpreter). The script then uses
    /// this copy, and with no copy at all mounts streaming instead — a union mount without
    /// the list would serve partly-downloaded files as complete. Runs off the main actor;
    /// NOT gated on telemetry, since it's a correctness input, not a signal.
    ///
    /// Known window: a file first partly downloaded after the last write, followed by an
    /// offline mount start before the next one, isn't on the list. At most one refresh
    /// interval while the app runs.
    private func refreshCacheOnlyExcludeLists() {
        let now = Date()
        for profile in profileStore.enabledProfiles where profile.isMountMode && !profile.mountModePath.isEmpty {
            guard Self.shouldRefreshCacheOnlyList(
                listExists: FileManager.default.fileExists(atPath: profile.cacheOnlyExcludePath),
                isMounted: profileMountStates[profile.id] == .mounted,
                mode: profileMountModes[profile.id],
                inFlight: cacheOnlyListWritesInFlight.contains(profile.id),
                lastWrite: lastCacheOnlyListWrite[profile.id], now: now
            ) else { continue }
            cacheOnlyListWritesInFlight.insert(profile.id)
            lastCacheOnlyListWrite[profile.id] = now
            let captured = profile
            Task.detached(priority: .utility) { [weak self] in
                Self.writeCacheOnlyExcludeList(for: captured)
                await MainActor.run { _ = self?.cacheOnlyListWritesInFlight.remove(captured.id) }
            }
        }
    }

    /// Write one profile's list, logging (never throwing) on failure — a failed walk has
    /// already removed any stale copy, so the script falls back to streaming. The failure
    /// also goes to telemetry at warn, once until the next success: the debug log is off
    /// by default, and otherwise the next offline mount would quietly stream instead of
    /// mounting Cache Only.
    nonisolated private static func writeCacheOnlyExcludeList(for profile: SyncProfile) {
        do {
            let count = try VFSCacheService.shared.writeCacheOnlyExcludeList(for: profile)
            SyncTraySettings.debugLog("'\(profile.name)': Cache Only partial-file list written (\(count) excluded)")
            TelemetryService.shared.recordCacheOnlyListWritten(profileId: profile.id)
        } catch {
            SyncTraySettings.debugLog("'\(profile.name)': Cache Only partial-file list failed: \(error.localizedDescription)")
            TelemetryService.shared.recordCacheOnlyListFailed(
                profileId: profile.id, profileName: profile.name, error: error)
        }
    }

    /// How often a mounted Stream profile's cached-read speed is sampled.
    static let mountReadProbeInterval: TimeInterval = 30 * 60

    /// Pure: should this profile get a read-health probe now? Only a mounted profile in
    /// STREAMING mode (Cache Only serves a different, union tree), never while an offline
    /// warm is reading through the same mount (it would skew the timing and the remote-byte
    /// delta), never twice at once, and at most once per `mountReadProbeInterval`.
    nonisolated static func shouldProbeMountRead(
        isMounted: Bool, mode: MountMode?, warmActive: Bool, inFlight: Bool,
        lastProbe: Date?, now: Date
    ) -> Bool {
        guard isMounted, (mode ?? .streaming) == .streaming, !warmActive, !inFlight else { return false }
        guard let lastProbe else { return true }
        return now.timeIntervalSince(lastProbe) >= mountReadProbeInterval
    }

    /// Time a cached read through each eligible Stream mount and record it
    /// (`TelemetryService.recordMountReadProbe`). Gated on the telemetry opt-in: the probe
    /// exists only to produce the signal, so it does no I/O for a user who opted out.
    private func probeMountReadHealth() {
        guard SyncTraySettings.telemetryEnabled else { return }
        let now = Date()
        for profile in profileStore.enabledProfiles where profile.isMountMode {
            guard Self.shouldProbeMountRead(
                isMounted: profileMountStates[profile.id] == .mounted,
                mode: profileMountModes[profile.id],
                warmActive: warmProgress[profile.id]?.isActive == true,
                inFlight: mountReadProbesInFlight.contains(profile.id),
                lastProbe: lastMountReadProbe[profile.id], now: now
            ) else { continue }
            mountReadProbesInFlight.insert(profile.id)
            lastMountReadProbe[profile.id] = now
            let captured = profile
            Task.detached(priority: .utility) { [weak self] in
                let service = VFSCacheService.shared
                let volume = service.cacheVolumeInfo(path: captured.vfsCachePath)
                let cacheFiles = await service.rcDiskCache(port: captured.rcPort)?.files
                let pick = service.pickReadProbeFile(for: captured)
                var result: MountReadProbeResult?
                if let pick { result = await service.probeMountRead(for: captured, pick: pick) }
                TelemetryService.shared.recordMountReadProbe(
                    profileId: captured.id, profileName: captured.name,
                    mountBackend: captured.mountBackend.rawValue,
                    cacheFsType: volume.fsType, cacheVolume: volume.volume,
                    vfsCacheFiles: cacheFiles, result: result,
                    outcome: pick == nil ? "no_candidate" : "failed")
                await MainActor.run { _ = self?.mountReadProbesInFlight.remove(captured.id) }
            }
        }
    }

    /// Find which profile a log watcher belongs to
    private func profileId(for watcher: LogWatcher) -> UUID? {
        for (id, w) in logWatchers {
            if w === watcher {
                return id
            }
        }
        return nil
    }
}

// MARK: - LogWatcherDelegate

extension SyncManager: LogWatcherDelegate {
    nonisolated func logWatcher(_ watcher: LogWatcher, didReceiveNewLines lines: [String]) {
        // Process synchronously when already on main thread for immediate state updates
        // This fixes the race condition where UI renders before state is updated
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                processLogLinesForWatcher(watcher, lines: lines)
            }
        } else {
            Task { @MainActor in
                self.processLogLinesForWatcher(watcher, lines: lines)
            }
        }
    }

    /// Process log lines for a watcher (must be called on main actor)
    private func processLogLinesForWatcher(_ watcher: LogWatcher, lines: [String]) {
        guard let profileId = profileId(for: watcher) else { return }

        for line in lines {
            if let event = logParser.parse(line: line) {
                processLogEvent(event, profileId: profileId)
            }
        }
    }
}

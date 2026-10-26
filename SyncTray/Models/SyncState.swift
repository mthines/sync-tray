import SwiftUI

struct SyncProgress: Equatable {
    let bytesTransferred: Int64
    let totalBytes: Int64
    let eta: Int?          // seconds
    let speed: Double?     // bytes/sec
    let transfersDone: Int
    let totalTransfers: Int

    // New fields for detailed progress
    let checksDone: Int
    let totalChecks: Int
    let elapsedTime: Double?
    let errors: Int
    let transferringFiles: [TransferringFile]
    let listedCount: Int?

    var percentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes) * 100
    }

    var checksPercentage: Double {
        guard totalChecks > 0 else { return 0 }
        return Double(checksDone) / Double(totalChecks) * 100
    }

    var transfersPercentage: Double {
        guard totalTransfers > 0 else { return 0 }
        return Double(transfersDone) / Double(totalTransfers) * 100
    }

    var formattedProgress: String {
        let transferred = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let pct = Int(percentage)

        if let eta = eta, eta > 0 {
            let etaStr = SyncFormatters.formatETA(eta)
            return "Syncing: \(transferred) / \(total) (\(pct)%) - ETA \(etaStr)"
        }
        return "Syncing: \(transferred) / \(total) (\(pct)%)"
    }

    /// Formatted line for bytes transfer: "19.9 GiB / 253.7 GiB, 8%, 35.5 MiB/s, ETA 1h52m"
    var formattedTransferLine: String {
        let transferred = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let pct = Int(percentage)

        var parts = ["\(transferred) / \(total)", "\(pct)%"]

        if let spd = speed, spd > 0 {
            let speedStr = ByteCountFormatter.string(fromByteCount: Int64(spd), countStyle: .file)
            parts.append("\(speedStr)/s")
        }

        if let eta = eta, eta > 0 {
            parts.append("ETA \(SyncFormatters.formatETA(eta))")
        }

        return parts.joined(separator: ", ")
    }

    /// Formatted line for checks: "3 / 3, 100%"
    var formattedChecksLine: String? {
        guard totalChecks > 0 else { return nil }
        return "\(checksDone) / \(totalChecks), \(Int(checksPercentage))%"
    }

    /// Formatted line for file transfers: "116 / 10128, 1%"
    var formattedTransfersLine: String? {
        guard totalTransfers > 0 else { return nil }
        return "\(transfersDone) / \(totalTransfers), \(Int(transfersPercentage))%"
    }

    /// Formatted elapsed time: "9m59.9s"
    var formattedElapsedTime: String? {
        guard let elapsed = elapsedTime, elapsed > 0 else { return nil }
        let totalSeconds = Int(elapsed)
        let fraction = elapsed - Double(totalSeconds)
        let tenths = Int(fraction * 10)

        if totalSeconds < 60 {
            return "\(totalSeconds).\(tenths)s"
        }
        if totalSeconds < 3600 {
            let mins = totalSeconds / 60
            let secs = totalSeconds % 60
            return "\(mins)m\(secs).\(tenths)s"
        }
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return "\(hours)h\(mins)m\(secs)s"
    }

    /// Create with default values for optional fields (for backward compatibility)
    init(
        bytesTransferred: Int64,
        totalBytes: Int64,
        eta: Int?,
        speed: Double?,
        transfersDone: Int,
        totalTransfers: Int,
        checksDone: Int = 0,
        totalChecks: Int = 0,
        elapsedTime: Double? = nil,
        errors: Int = 0,
        transferringFiles: [TransferringFile] = [],
        listedCount: Int? = nil
    ) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.eta = eta
        self.speed = speed
        self.transfersDone = transfersDone
        self.totalTransfers = totalTransfers
        self.checksDone = checksDone
        self.totalChecks = totalChecks
        self.elapsedTime = elapsedTime
        self.errors = errors
        self.transferringFiles = transferringFiles
        self.listedCount = listedCount
    }
}

enum SyncState: Equatable {
    case idle
    case syncing
    case paused
    case error(String)
    case driveNotMounted
    case notConfigured

    var iconName: String {
        switch self {
        case .idle:
            return "arrow.triangle.2.circlepath"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .paused:
            return "pause.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .driveNotMounted:
            return "externaldrive.badge.xmark"
        case .notConfigured:
            return "gearshape.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .idle:
            return .secondary
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

    var statusText: String {
        switch self {
        case .idle:
            return "Idle"
        case .syncing:
            return "Syncing..."
        case .paused:
            return "Paused"
        case .error(let message):
            return "Error: \(message)"
        case .driveNotMounted:
            return "Drive not mounted"
        case .notConfigured:
            return "Setup required"
        }
    }
}

/// Mount state for mount mode profiles
enum MountState: Equatable {
    case unmounted
    case mounting
    case mounted
    case failed(String)

    var iconName: String {
        switch self {
        case .unmounted:
            return "externaldrive.badge.icloud"
        case .mounting:
            return "externaldrive.badge.icloud"
        case .mounted:
            return "externaldrive.fill.badge.checkmark"
        case .failed:
            return "externaldrive.badge.xmark"
        }
    }

    var iconColor: Color {
        switch self {
        case .unmounted:
            return .secondary
        case .mounting:
            return .blue
        case .mounted:
            return .green
        case .failed:
            return .red
        }
    }

    var statusText: String {
        switch self {
        case .unmounted:
            return "Not mounted"
        case .mounting:
            return "Mounting..."
        case .mounted:
            return "Mounted"
        case .failed(let message):
            return "Mount failed: \(message)"
        }
    }
}

// MARK: - Mount interruption tracking

/// Pure state machine behind the mount STALL telemetry (CLAUDE.md "Mount interruption
/// telemetry", AC-MI1). The mount monitor sends one `statfs(2)` at a time to a mounted
/// Stream profile's mount root: an NFS FSSTAT round trip to rclone's local NFS server
/// (or a FUSE statfs on macFUSE). A probe that has not returned after `stallThreshold`
/// is a stall: filesystem calls on the mount are not being answered, which is the
/// condition macOS reports as "Server connections interrupted" and Finder shows as a
/// hang. The volume stays in the mount table throughout, so the mount-table check
/// (`SyncSetupService.isMounted`) cannot see it.
///
/// No I/O here: the monitor supplies the clock and reports when the probe returns, so
/// every transition is unit-testable.
struct MountStallProbe: Equatable {
    /// A probe still outstanding after this long counts as a stall. Long enough that a
    /// cold FSSTAT over a slow backend doesn't trip it, short enough to catch the hangs
    /// a user notices.
    static let stallThreshold: TimeInterval = 15
    /// Minimum gap between one probe returning and the next starting: one cheap
    /// round trip every 30 s per mounted profile.
    static let probeInterval: TimeInterval = 30

    /// When the outstanding probe started, or nil when none is outstanding.
    private(set) var inFlightSince: Date?
    /// When the last probe returned.
    private(set) var lastFinishedAt: Date?
    /// The outstanding probe's stall has been reported and not yet closed.
    private(set) var stallOpen = false
    /// The outstanding probe may no longer report: its stall was closed by the volume
    /// going away, or it was already outstanding when the volume went away.
    private(set) var probeSettled = false

    enum Event: Equatable {
        case none
        case stallStarted(since: Date)
        case stallEnded(duration: TimeInterval)
    }

    /// Whether a new probe should start now: none outstanding (at most one blocked
    /// thread per profile, however long the mount hangs) and the interval has passed.
    func shouldStartProbe(now: Date) -> Bool {
        guard inFlightSince == nil else { return false }
        guard let last = lastFinishedAt else { return true }
        return now.timeIntervalSince(last) >= Self.probeInterval
    }

    mutating func probeStarted(at date: Date) {
        inFlightSince = date
        stallOpen = false
        probeSettled = false
    }

    /// Evaluate the outstanding probe on a monitor tick. Returns `.stallStarted` exactly
    /// once per probe, the first time it has been outstanding for `stallThreshold`.
    mutating func evaluate(now: Date) -> Event {
        guard let since = inFlightSince, !stallOpen, !probeSettled,
              now.timeIntervalSince(since) >= Self.stallThreshold else { return .none }
        stallOpen = true
        return .stallStarted(since: since)
    }

    /// The probe returned, with success or an error: either way the filesystem answered.
    /// Closes an open stall; the duration runs from the probe's start, so it is a lower
    /// bound on how long the mount was unresponsive.
    mutating func probeFinished(at date: Date) -> Event {
        guard let since = inFlightSince else { return .none }
        let wasOpen = stallOpen
        inFlightSince = nil
        stallOpen = false
        probeSettled = false
        lastFinishedAt = date
        return wasOpen ? .stallEnded(duration: max(0, date.timeIntervalSince(since))) : .none
    }

    /// The volume left the mount table. Closes an open stall (the caller reports it once the
    /// drop classification has decided between `dropped` and `unmounted`) and settles the
    /// outstanding probe so it can't report again when its blocked call finally returns.
    mutating func volumeWentAway(at date: Date) -> Event {
        guard let since = inFlightSince else { return .none }
        probeSettled = true
        guard stallOpen else { return .none }
        stallOpen = false
        return .stallEnded(duration: max(0, date.timeIntervalSince(since)))
    }
}

/// Decides which mount-table disappearances are DROPS for the mount telemetry
/// (CLAUDE.md "Mount interruption telemetry", AC-MI2): the volume vanished and nobody
/// asked for it. Two signals rule out a deliberate unmount:
/// - **The deliberate-unmount marker.** Every detach SyncTray performs, from the app or
///   the CLI, goes through `SyncSetupService` (`unmount`, `uninstall` and therefore every
///   reinstall and Cache Only switch, `unloadAgent` for pause, the orphan cleanup), which
///   touches `SyncProfile.deliberateUnmountMarkerPath` first. A disappearance within
///   `deliberateWindow` of that touch is deliberate, even when the agent is loaded again by
///   the time we look (a reinstall reloads it within seconds).
/// - **The launchd agent is unloaded** (checked `confirmDelay` after the disappearance,
///   since `unmount` unloads it only after detaching): someone stopped the profile.
/// What remains is a volume that vanished under a loaded agent with no marker: rclone
/// exited, or macOS detached it (for example the "Disconnect" button in the "Server
/// connections interrupted" dialog).
enum MountDropClassifier {
    /// How long after the volume disappears to wait before reading the agent's state.
    static let confirmDelay: TimeInterval = 10
    /// How long a deliberate-unmount marker explains a disappearance. Covers a slow
    /// graceful `diskutil unmount` falling back to a forced one.
    static let deliberateWindow: TimeInterval = 120

    static func isUnexpectedDrop(
        agentLoaded: Bool,
        isEnabledMountProfile: Bool,
        isPaused: Bool,
        lastDeliberateUnmount: Date?,
        disappearedAt: Date
    ) -> Bool {
        guard agentLoaded, isEnabledMountProfile, !isPaused else { return false }
        if let marker = lastDeliberateUnmount {
            // The marker is written before the detach, so a deliberate disappearance is
            // seen after it; 1 s of slack absorbs timestamp granularity.
            let age = disappearedAt.timeIntervalSince(marker)
            if age >= -1 && age <= deliberateWindow { return false }
        }
        return true
    }
}

/// The actual mode a Stream (mount) profile's rclone process is running in RIGHT NOW,
/// read from the per-boot state file (`SyncProfile.mountModePath`) the sync script
/// writes right before starting rclone. Distinct from `SyncProfile.streamCacheOnly`,
/// which only tracks the user's MANUAL choice — this is the source of truth for the
/// mode actually active, including the two AUTOMATIC ones the script can pick on its
/// own (offline / pending) that the persisted flag knows nothing about.
enum MountMode: String, Equatable, CaseIterable {
    case streaming = "streaming"
    case cacheOnlyManual = "cache-only-manual"
    case cacheOnlyPending = "cache-only-pending"
    case cacheOnlyOffline = "cache-only-offline"

    /// Parse a mode-file token, trimming surrounding whitespace/newlines (the script
    /// writes it with `echo`, which appends a trailing newline). Anything that isn't
    /// one of the four known tokens is rejected (`nil`), which callers treat as
    /// "mode unknown" rather than guessing.
    static func parse(_ text: String) -> MountMode? {
        MountMode(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether this mode is any flavour of Cache Only (manual or automatic).
    var isCacheOnly: Bool {
        self != .streaming
    }

    /// Whether this mode was entered BY THE SCRIPT on its own (the primary was
    /// unreachable, or the overlay had pending files at mount time) rather than by the
    /// user clicking "Cache Only". Only `.cacheOnlyManual` is a manual choice.
    var isAutomatic: Bool {
        switch self {
        case .cacheOnlyOffline, .cacheOnlyPending: return true
        case .streaming, .cacheOnlyManual: return false
        }
    }

    /// User-facing label for the Stream status card and menu bar.
    var displayName: String {
        switch self {
        case .streaming: return "Streaming"
        case .cacheOnlyManual: return "Cache only (manual)"
        case .cacheOnlyPending: return "Cache only (uploads pending, automatic)"
        case .cacheOnlyOffline: return "Cache only (offline, automatic)"
        }
    }

    /// Low-cardinality telemetry value — same spelling as `rawValue` today, called out
    /// separately so a future UI-only rename of `displayName` can never leak into
    /// telemetry attributes.
    var telemetryValue: String { rawValue }
}

/// Which transport is currently active for a profile's sync
enum ActiveTransport: Equatable {
    case primary
    case fallback(remoteName: String)
    case unknown

    var isPrimary: Bool {
        if case .primary = self { return true }
        return false
    }

    var isFallback: Bool {
        if case .fallback = self { return true }
        return false
    }

    var iconName: String {
        switch self {
        case .primary: return "wifi"
        case .fallback: return "antenna.radiowaves.left.and.right"
        case .unknown: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .primary: return "Primary"
        case .fallback(let name): return "Fallback (\(name))"
        case .unknown: return "Unknown"
        }
    }
}

struct FileChange: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let path: String
    let operation: Operation
    var profileName: String = ""

    enum Operation: String {
        case copied = "Copied"
        case deleted = "Deleted"
        case updated = "Updated"
        case renamed = "Renamed"
        case unknown = "Changed"

        var icon: String {
            switch self {
            case .copied:
                return "plus.circle.fill"
            case .deleted:
                return "minus.circle.fill"
            case .updated:
                return "arrow.clockwise.circle.fill"
            case .renamed:
                return "pencil.circle.fill"
            case .unknown:
                return "circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .copied:
                return .green
            case .deleted:
                return .red
            case .updated:
                return .blue
            case .renamed:
                return .purple
            case .unknown:
                return .secondary
            }
        }
    }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }

    static func == (lhs: FileChange, rhs: FileChange) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Sync Log Pattern Matching

/// Centralized patterns for parsing and categorizing sync log messages.
/// Used by both LogParser and SyncManager for consistent behavior.
enum SyncLogPatterns {
    // MARK: - Sync State Detection

    /// Patterns indicating sync has started
    static func isSyncStarted(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("starting bisync") || lower.contains("starting sync")
    }

    /// The start line `SyncManager.performResync` writes for an auto-fix `--resync`. It still
    /// matches `isSyncStarted`; `isAutoFixResyncStart` lets the log pipeline tell that run's
    /// success apart from a normal bisync's (#123).
    static let autoFixResyncStartLine = "Starting bisync (auto-fix --resync)"

    static func isAutoFixResyncStart(_ line: String) -> Bool {
        line.contains(autoFixResyncStartLine)
    }

    /// bisync's final check-sync listing comparison found a file on one side only ("Path1 file
    /// not found in Path2", "Path2 file not found in Path1"). rclone names the file only in the
    /// JSON line's `object`.
    static func isCheckSyncMismatch(_ message: String) -> Bool {
        message.contains("file not found in Path")
    }

    /// Patterns indicating sync completed successfully
    static func isSyncCompleted(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("bisync successful") ||
               lower.contains("completed successfully") ||
               lower.contains("sync complete")
    }

    static func isScheduleCheckFailed(_ message: String) -> Bool {
        message.lowercased().contains("schedule check failed:")
    }

    /// Patterns indicating sync failed
    static func isSyncFailed(_ message: String) -> Bool {
        let lower = message.lowercased()
        return isScheduleCheckFailed(message) || lower.contains("bisync failed") ||
               lower.contains("failed with exit code") ||
               lower.contains("failed to bisync")
    }

    /// Patterns indicating drive not mounted
    static func isDriveNotMounted(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("drive not mounted") || lower.contains("not mounted")
    }

    /// Patterns indicating sync already running
    static func isSyncAlreadyRunning(_ message: String) -> Bool {
        message.lowercased().contains("already running")
    }

    /// Patterns indicating a scheduled run exited early WITHOUT syncing because
    /// the remote failed the read-only pre-flight reachability check.
    /// Matches "Remote unreachable, skipping sync ..." but deliberately NOT the
    /// fallback message "Primary remote unreachable, using fallback: ..." (which
    /// is a transport change, handled separately) — the discriminator is the
    /// ", skipping" clause.
    static func isSyncSkipped(_ message: String) -> Bool {
        message.lowercased().contains("unreachable, skipping")
    }

    /// Error pattern that triggers automatic recovery via --resync.
    /// Matches the canonical bisync "out of sync" messages that require --resync.
    /// NOTE: Do NOT match bare "--resync" as a substring — rclone error output from a
    /// *failed* resync can itself contain "--resync" at critical level, which would
    /// re-trigger auto-fix and create a feedback loop.
    /// NOTE: "cannot find prior listing" is the full rclone phrase; matching only the
    /// "cannot find prior" prefix would also catch unrelated rclone warnings.
    static func isOutOfSyncError(_ message: String) -> Bool {
        message.contains("out of sync") ||
        message.contains("resync to recover") ||
        message.contains("cannot find prior listing")
    }

    /// Matches rclone's "prior lock file found" failure, which fires when a rejected
    /// concurrent bisync run tries to start while another run already holds the
    /// profile's session `.lck`. ANSI color codes (e.g. `\u{1b}[31m`, `\u{1b}[93m`)
    /// wrap the phrase but never split it, so a lowercased substring match is
    /// sufficient. Single source for this match — see `SyncRunLock.isRejectedConcurrentRun`,
    /// which combines it with session-lock liveness to decide whether the failure is
    /// a rejected concurrent run (suppressed) or a genuine stale-lock failure (surfaced).
    static func isPriorLockFileError(_ message: String) -> Bool {
        message.lowercased().contains("prior lock file found")
    }

    // MARK: - Error Categorization

    /// Transient "all files changed" error that should be ignored.
    /// This is expected after a `--resync` and resolves on the next sync.
    static func isTransientAllFilesChangedError(_ message: String) -> Bool {
        message.contains("all files were changed") || message.contains("Safety abort")
    }

    /// rclone's NFS server (go-nfs, behind `rclone nfsmount`, the default Stream backend)
    /// logs "failing create to indicate lack of support for 'exclusive' mode." at ERROR
    /// level every time the NFS client asks for an NFSv3 EXCLUSIVE create, i.e. whenever
    /// an app on the Mac opens a new file on the mount with `O_CREAT|O_EXCL`.
    ///
    /// It is not a failure. go-nfs answers NFS3ERR_NOTSUPP on purpose, and the macOS NFS
    /// client reacts by dropping `O_EXCL` and retrying the create (`nfs3_vnop_create`), so
    /// the file is created and the app never sees an error. Treating the line as an error
    /// put a red "Last sync error" banner on healthy Stream profiles that nothing ever
    /// cleared (a mount never starts or completes a sync, which is what clears it) and
    /// emitted one "Sync error" ERROR telemetry record per create.
    ///
    /// Single source for this match: `LogParser` drops the line, and
    /// `TelemetryService.categorizeError` buckets it as `exclusive_mode_unsupported`.
    static func isBenignNFSExclusiveCreateNotice(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("lack of support for") && lower.contains("exclusive")
    }

    /// EPERM, which Go prints as "operation not permitted". From rclone's local backend this
    /// is almost always macOS privacy controls (TCC) refusing access to a protected location —
    /// e.g. `failed to open directory "Photos Library.photoslibrary": open
    /// /Users/me/Pictures/Photos Library.photoslibrary: operation not permitted`. It is not
    /// POSIX file permissions ("permission denied", EACCES): chmod can't fix it; only
    /// excluding the path or granting access in System Settings can.
    ///
    /// `TelemetryService.categorizeError` buckets it as `permission_denied`.
    static func isOperationNotPermitted(_ message: String) -> Bool {
        message.lowercased().contains("operation not permitted")
    }

    /// EACCES, which Go prints as "permission denied": POSIX ownership or mode bits refusing a
    /// path — e.g. the root-owned folders macOS keeps at a volume root:
    /// `failed to open directory ".Spotlight-V100": open /Volumes/Drive/.Spotlight-V100:
    /// permission denied`. Full Disk Access can't fix it; excluding the path (or changing its
    /// permissions, when the user owns it) can.
    static func isPermissionDenied(_ message: String) -> Bool {
        message.lowercased().contains("permission denied")
    }

    /// Why the operating system refused a local path rclone tried to read. The raw values are
    /// the bounded `error.access_denial` telemetry values.
    enum BlockedAccessKind: String {
        /// EPERM ("operation not permitted"): macOS privacy controls (TCC). Granting Full Disk
        /// Access can fix it.
        case macOSPrivacy = "operation_not_permitted"
        /// EACCES ("permission denied"): POSIX ownership or permissions. Privacy settings can't.
        case filePermissions = "permission_denied"
    }

    /// The absolute path an "operation not permitted" or "permission denied" error names (the
    /// path after Go's `open`/`lstat`/… prefix) and which of the two it is, or nil when the
    /// message names no absolute path — e.g. a remote backend's error. Paths may contain spaces.
    ///
    /// Single source for the "blocked access" case: `LogParser` keeps such messages whole (the
    /// path is what the recovery actions act on), the sync-failure notification summarizes them
    /// (`macOSBlockedAccessSummary`), `ProfileDetailView` offers Exclude (and, for a privacy
    /// denial, Open Privacy Settings), and telemetry records the kind, never the path.
    static func blockedAccess(in message: String) -> (path: String, kind: BlockedAccessKind)? {
        let pattern = #"(?:^|[\s:])(?:open|lstat|stat|opendir|readlink|mkdir|remove|rename|chmod|chtimes) (/.+?): (operation not permitted|permission denied)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let pathRange = Range(match.range(at: 1), in: message),
              let reasonRange = Range(match.range(at: 2), in: message) else {
            return nil
        }
        let kind: BlockedAccessKind = message[reasonRange].lowercased() == "permission denied"
            ? .filePermissions : .macOSPrivacy
        return (String(message[pathRange]), kind)
    }

    /// The path of `blockedAccess(in:)`, whichever kind it is.
    static func blockedAccessPath(in message: String) -> String? {
        blockedAccess(in: message)?.path
    }

    /// The absolute path an "operation not permitted" (EPERM) error names, or nil — including
    /// for a "permission denied" error (see `blockedAccess(in:)` for both).
    static func operationNotPermittedPath(in message: String) -> String? {
        guard let blocked = blockedAccess(in: message), blocked.kind == .macOSPrivacy else { return nil }
        return blocked.path
    }

    /// The path of a local access denial in `message` — EPERM or EACCES — that is the profile's
    /// local folder or inside it. nil otherwise, including a remote server's error, whose
    /// absolute path is on the remote, where nothing on this Mac can help.
    static func macOSBlockedPath(in message: String, localSyncPath: String) -> String? {
        macOSBlockedAccess(in: message, localSyncPath: localSyncPath)?.path
    }

    /// `blockedAccess(in:)`, but only for a path that is the profile's local folder or inside it.
    static func macOSBlockedAccess(in message: String, localSyncPath: String) -> (path: String, kind: BlockedAccessKind)? {
        guard let blocked = blockedAccess(in: message),
              SyncExcludeFilter.isWithinSyncFolder(blocked.path, localSyncPath: localSyncPath) else {
            return nil
        }
        return blocked
    }

    /// One-line user-facing summary of a local access denial — "macOS blocked access to
    /// “Photos Library.photoslibrary”." for a privacy denial, "SyncTray doesn't have permission
    /// to access “.Spotlight-V100”." for a permissions one — or nil when `message` isn't one (see
    /// `macOSBlockedPath`). Names only the last path component, which is what the user
    /// recognizes.
    static func macOSBlockedAccessSummary(for message: String, localSyncPath: String) -> String? {
        guard let blocked = macOSBlockedAccess(in: message, localSyncPath: localSyncPath) else { return nil }
        let name = (blocked.path as NSString).lastPathComponent
        let shown = name.isEmpty ? blocked.path : name
        switch blocked.kind {
        case .macOSPrivacy: return "macOS blocked access to “\(shown)”."
        case .filePermissions: return "SyncTray doesn't have permission to access “\(shown)”."
        }
    }

    /// True when rclone failed to open a DIRECTORY (the local backend's listing error), as
    /// opposed to a single file — so an exclude for it ends in `/` (folder and contents).
    static func isDirectoryOpenFailure(_ message: String) -> Bool {
        message.lowercased().contains("failed to open directory")
    }

    /// rclone `sync`/`bisync` refuses to propagate deletions after ANY read error during the
    /// run ("not deleting files as there were IO errors", "…directories…"), so the
    /// destination keeps files that were deleted at the source. It is a consequence, not a
    /// cause — the run's first error says why. `TelemetryService.categorizeError` buckets it
    /// as `io_errors_blocked_deletes` when that's all a failure has to go on.
    static func isIOErrorsBlockedDeletes(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not deleting files as there were io errors")
            || lower.contains("not deleting directories as there were io errors")
    }

    /// An error that says the run was stopped rather than that it failed, in the two wordings
    /// that reach `TelemetryService.categorizeError`, which buckets it as `interrupted`:
    /// - Go's `context.Canceled` text ("context canceled"), which rclone's transfers fail with
    ///   at ERROR when a signal cancels the sync, so `LogParser` surfaces it.
    /// - bisync's "Bisync interrupted. Must run --resync to recover." (`cmd/bisync/operations.go`),
    ///   matched ahead of the critical check whose "resync" it would otherwise hit. bisync logs
    ///   it at NOTICE, which `LogParser` never surfaces; it arrives through
    ///   `SyncManager.readLastErrorFromLog` (a run the app picked up from its lock), which admits
    ///   NOTICE lines and keeps it as the profile's stored error, the one `Profile status`
    ///   categorizes.
    ///
    /// Not matched, because no path brings them here: rclone's "Signal received: …" (INFO,
    /// `lib/atexit`) and bisync's "Graceful shutdown failed." (NOTICE, always logged just before
    /// the interrupted line, which that backwards scan reaches first and stops at). A stop that
    /// logs neither is told by its exit code (`isStopSignalExitCode`). Log levels as of rclone
    /// v1.73.2. Matched case-insensitively. Caveat: rclone also logs "context canceled" for the
    /// transfers it cancels after some other error, and for Stream reads the NFS client
    /// abandons, so a single `Sync error` line can read `interrupted` without a stop; a failed
    /// run is still categorized from its first error, which comes before those.
    static func isInterruptedError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("context canceled")
            || lower.contains("bisync interrupted")
    }

    /// Whether a sync's exit code says a stop signal ended it rather than an error. The script
    /// logs rclone's exit code (`${PIPESTATUS[0]}` of `rclone … 2>&1 | tee -a $LOG_FILE`), and
    /// rclone's own codes are 0–10. A stop shows up as:
    /// - 129 / 130 / 143 — rclone itself got SIGHUP / SIGINT / SIGTERM: it runs its exit
    ///   handlers (bisync's graceful shutdown) and exits 128 + the signal (`lib/atexit`).
    /// - 137 — rclone was SIGKILLed (bash reports 128 + 9).
    /// - 141 — rclone died of SIGPIPE writing its log: the `tee` it writes through was killed,
    ///   which happens when the stop signal hits the run's whole process group (Ctrl-C on
    ///   `synctray sync`). A group SIGTERM or SIGHUP kills the script's bash too, so no exit
    ///   line is written at all.
    /// Crash signals (134 SIGABRT, 139 SIGSEGV, …) are not a stop and are categorized from the
    /// message as before.
    static func isStopSignalExitCode(_ exitCode: Int) -> Bool {
        [129, 130, 137, 141, 143].contains(exitCode)
    }

    /// Generic messages that don't provide useful error info
    static func isGenericAbortMessage(_ message: String) -> Bool {
        message.contains("Bisync aborted") || message.contains("Failed to bisync")
    }

    /// Critical/actionable errors that tell the user what to do
    static func isCriticalError(_ message: String) -> Bool {
        message.contains("out of sync") ||
        message.contains("resync") ||
        message.contains("critical") ||
        message.contains("lock file") ||
        message.contains("check file") ||
        message.contains("Access test failed") ||
        message.contains("Failed to initialise") ||
        message.contains("malformed rule") ||
        message.contains("not empty") ||
        message.contains("FUSE") ||
        message.contains("failed to mount")
    }

    // MARK: - Error Message Cleanup

    /// Prefixes to strip from error messages for cleaner display
    static func cleanErrorMessage(_ message: String) -> String {
        var cleaned = message

        // Strip common prefixes
        let prefixes = [
            "Bisync critical error: ",
            "Bisync aborted. ",
            "Fatal error: failed to mount FUSE fs: "
        ]

        for prefix in prefixes {
            if let range = cleaned.range(of: prefix) {
                cleaned = String(cleaned[range.upperBound...])
                break
            }
        }

        // Provide user-friendly mount error messages
        if cleaned.contains("is not empty") {
            return "Mount point folder is not empty. Choose an empty folder or clear its contents first."
        }
        if cleaned.contains("not supported on MacOS when rclone is installed via Homebrew") {
            return "The macFUSE backend requires the official rclone binary from rclone.org "
                + "(Homebrew's rclone can't mount). Switch this profile's Mount Backend to "
                + "NFS to stream without macFUSE."
        }
        if cleaned.contains("macfuse") || cleaned.contains("FUSE") || cleaned.contains("fuse") {
            if cleaned.contains("not found") || cleaned.contains("not installed") {
                return "macFUSE is required for the macFUSE backend. Install via "
                    + "`brew install --cask macfuse`, or switch this profile's Mount Backend "
                    + "to NFS to stream without it."
            }
        }

        return cleaned
    }

    // MARK: - Transport Detection

    /// Check if message indicates fallback transport was activated
    static func isFallbackActivated(_ message: String) -> Bool {
        message.contains("using fallback:")
    }

    /// Check if message indicates primary transport is in use
    static func isPrimaryTransport(_ message: String) -> Bool {
        message.contains("Using primary remote:")
    }

    /// Extract the fallback remote name from a fallback log message
    static func extractFallbackRemoteName(from message: String) -> String? {
        // Format: "Primary remote unreachable, using fallback: synology-sftp"
        guard let range = message.range(of: "using fallback: ") else { return nil }
        return String(message[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Exit Code Extraction

    /// Extract exit code from a failure message like "Bisync failed with exit code 1"
    static func extractExitCode(from message: String) -> Int? {
        let pattern = #"exit code (\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let codeRange = Range(match.range(at: 1), in: message),
              let code = Int(message[codeRange]) else {
            return nil
        }
        return code
    }

    // MARK: - Log Line Error Extraction

    /// Check if a log line contains a plain text CRITICAL error
    static func isCriticalLogLine(_ line: String) -> Bool {
        line.contains("CRITICAL:")
    }

    /// Check if a log line contains a JSON error, notice, or critical level message
    static func isJSONErrorLine(_ line: String) -> Bool {
        line.contains("\"level\":\"error\"") || line.contains("\"level\":\"notice\"") || line.contains("\"level\":\"critical\"")
    }

    /// Extract error message from a log line (supports both CRITICAL and JSON formats)
    /// Returns nil if no error message can be extracted
    static func extractErrorMessage(from line: String) -> String? {
        // Check for plain text CRITICAL errors (format: "2026/02/16 06:42:11 CRITICAL: ...")
        if isCriticalLogLine(line) {
            if let range = line.range(of: "CRITICAL: ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        // Check for rclone JSON error/notice messages
        else if isJSONErrorLine(line) {
            // Parse the error message from JSON
            if let msgRange = line.range(of: "\"msg\":\""),
               let endRange = line[msgRange.upperBound...].range(of: "\"") {
                return String(line[msgRange.upperBound..<endRange.lowerBound])
            }
        }
        return nil
    }

    /// Strip ANSI escape codes from a message
    static func stripANSICodes(_ message: String) -> String {
        var result = message
        result = result.replacingOccurrences(of: "\\u001b[", with: "")
        result = result.replacingOccurrences(of: #"\[\d+m"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "[0m", with: "")
        result = result.replacingOccurrences(of: "[31m", with: "")
        result = result.replacingOccurrences(of: "[33m", with: "")
        result = result.replacingOccurrences(of: "[35m", with: "")
        result = result.replacingOccurrences(of: "[36m", with: "")
        return result
    }
}

// MARK: - Legacy Alias

/// Alias for backward compatibility
typealias SyncErrorCategory = SyncLogPatterns

import Foundation

/// Where `profile create` reads the profile JSON from.
enum CreateSource: Equatable {
    case file(String)
    case stdin
}

/// Parsed CLI subcommand — the pure, testable result of `SyncTrayCLI.parse`.
enum CLICommand: Equatable {
    case doctor
    case testRemote(String)
    case logs(target: String, follow: Bool)
    case listRemotes
    case profiles
    case status(target: String?)
    case sync(String)
    case profileCreate(CreateSource)
    case profileDelete(String)
    case profileSetEnabled(target: String, enabled: Bool)
    case help
}

/// A `parse` failure — carries the usage message printed to stderr.
struct CLIUsageError: Error, Equatable {
    let message: String
}

/// One line of a `doctor` health report. A typed result (rather than parallel
/// status strings) so `run`/the self-test can derive the exit code by asking
/// "does any check have status `.fail`" instead of re-parsing printed text.
struct DoctorCheck: Equatable {
    enum Status: String { case ok, warn, fail }

    let name: String
    let status: Status
    let detail: String

    /// Greppable single-line rendering, e.g. `[ok] rclone: /opt/homebrew/bin/rclone (v1.66.0)`.
    var line: String { "[\(status.rawValue)] \(name): \(detail)" }
}

/// Every impure operation the CLI touches, injected so `execute`/`doctorChecks`
/// are pure over `env` and fully exercisable by `ConfigSelfTest` with fakes —
/// no real `Process`, `FileManager`, or stdio needed to test dispatch logic.
struct CLIEnvironment {
    /// Run rclone with `args`, hard-killed after `timeout` seconds if still
    /// running. Returns `(exitCode, stdout, stderr)`.
    var runRclone: (_ args: [String], _ timeout: TimeInterval) -> (Int32, String, String)
    /// Read every profile from the file-authoritative profiles directory.
    var readProfiles: () -> [SyncProfile]
    var fileExists: (String) -> Bool
    /// Run `launchctl` with `args`. Returns `(exitCode, stdout)`.
    var runLaunchctl: (_ args: [String]) -> (Int32, String)
    /// Whether the JSON schema files are installed under the config directory.
    var schemaFilesPresent: () -> Bool
    /// Persist a profile's authoritative `{shortId}.profile.json`. Returns
    /// `true` on success. Same byte format the app writes (`ProfileStore`).
    var writeProfile: (SyncProfile) -> Bool
    /// Install (generate script/plist/derived-config and load the launchd
    /// agent). Returns an error message on failure, or `nil` on success.
    var installProfile: (SyncProfile) -> String?
    /// Uninstall (detach a mounted volume, unload the agent, remove the
    /// derived files). Returns an error message on failure, or `nil`.
    var uninstallProfile: (SyncProfile) -> String?
    /// Delete the authoritative `{shortId}.profile.json`.
    var deleteProfileFile: (SyncProfile) -> Void
    /// Run the shared sync script against a profile's derived config path,
    /// blocking until it exits. Returns the script's exit code.
    var runSyncScript: (_ configPath: String) -> Int32
    /// Read all of stdin (for `profile create -`). `nil` on read failure.
    var readStdin: () -> String?
    /// Read a file's contents as UTF-8 text. `nil` if missing/unreadable.
    var readFile: (String) -> String?
    var stdout: (String) -> Void
    var stderr: (String) -> Void
    var now: () -> Date
}

/// Headless `synctray` CLI, dispatched from `SyncTrayApp.init` exactly like
/// the existing `--self-test` intercept: parsed early, run, and `exit()`ed
/// before the SwiftUI app, `SyncManager`, watchers, or timers ever start. It
/// NEVER opens a window and NEVER launches background work — see `dispatch`.
/// It DOES record exactly one telemetry event per run (the bounded command
/// verb + result, gated on the user's opt-in) and flush before exit, so agent
/// operation of SyncTray is itself measurable — see `runMeasured`.
///
/// Pure core / impure shell: `parse`, `execute`, `run`, `doctorChecks`, and
/// `resolveProfile` operate entirely over their arguments/injected `env`, so
/// `ConfigSelfTest` drives the full dispatch + doctor-aggregation logic with
/// fakes. Only `CLIEnvironment.production()`, `dispatch`, and `runMeasured`
/// touch real process/filesystem/telemetry state.
enum SyncTrayCLI {
    static let usage = """
    usage: synctray <command> [args]

    Inspect:
      doctor                       Run a health check and print a report
      status [name|id]             Show live state for one or all profiles
      profiles                     List configured SyncTray profiles
      logs <name|id> [--follow]    Print or tail a profile's sync log
      test-remote <name|id>        Probe a profile's remote reachability
      listremotes                  List configured rclone remotes

    Configure:
      profile create --from <file> Create a profile from a .profile.json file
      profile create -             Create a profile from JSON on stdin
      profile enable <name|id>     Enable a profile (install its launchd agent)
      profile disable <name|id>    Disable a profile (unload its agent)
      profile delete <name|id>     Delete a profile and its launchd agent

    Operate:
      sync <name|id>               Run a sync now and wait for it to finish

    Profiles author JSON against schema/profile.schema.json under the config
    directory; the same file an agent can drop in or edit directly.
    """

    // MARK: - Entry point

    /// Returns the process exit code when `arguments` names a CLI invocation, or
    /// `nil` to fall through to the GUI. A bare first token (not `-`-prefixed) is
    /// ALWAYS treated as a subcommand and routed through `execute` — an unknown
    /// one prints usage and exits non-zero (EX_USAGE) rather than silently
    /// launching the GUI and hanging the terminal (the bug this guards against).
    /// `nil` is returned only for a no-argument launch and for `-`-prefixed args
    /// (`--self-test`, and macOS's own `-psn_…`/`-NS…` GUI arguments), which the
    /// GUI/self-test path handles — except `-h`/`--help`, routed to `execute`.
    static func dispatch(arguments: [String]) -> Int32? {
        let argv = Array(arguments.dropFirst())
        guard let first = argv.first else { return nil }        // no args → normal GUI launch
        if first.hasPrefix("-"), first != "-h", first != "--help" {
            return nil                                          // other flags → GUI/self-test path
        }
        // `-`-prefixed `-h`/`--help`, or any bare token, IS a subcommand.
        return runMeasured(argv, env: .production())
    }

    /// Real-entry wrapper that times `execute`, records ONE
    /// `synctray.cli.invoked` telemetry event, flushes, and returns the code.
    /// Lives here (not in `execute`) so the fake-`env` self-test path never
    /// touches `TelemetryService`. Telemetry is gated on the user's opt-in, so
    /// this is a no-op — no setup, no network, no stdout — when disabled.
    private static func runMeasured(_ argv: [String], env: CLIEnvironment) -> Int32 {
        let start = env.now()
        let code = execute(argv, env: env)
        let elapsed = env.now().timeIntervalSince(start)
        TelemetryService.shared.recordCLIInvocation(
            command: telemetryVerb(for: argv),
            exitCode: code,
            durationSeconds: elapsed
        )
        TelemetryService.shared.flushForExit()
        return code
    }

    /// Map an argv to a BOUNDED command verb for telemetry — never args, paths,
    /// profile names, or remotes. An unrecognised first token (or a bad
    /// `profile <sub>`) collapses to `(other)` so cardinality stays fixed.
    static func telemetryVerb(for argv: [String]) -> String {
        guard let first = argv.first else { return "(none)" }
        let known: Set<String> = [
            "doctor", "status", "profiles", "logs", "test-remote",
            "listremotes", "sync", "help", "-h", "--help",
        ]
        if first == "profile" {
            let sub = argv.dropFirst().first(where: { !$0.hasPrefix("-") }) ?? ""
            let knownSubs: Set<String> = ["create", "delete", "enable", "disable", "list"]
            return knownSubs.contains(sub) ? "profile-\(sub)" : "(other)"
        }
        return known.contains(first) ? first : "(other)"
    }

    // MARK: - Pure core

    /// Parse `argv` (program name already stripped) into a `CLICommand`.
    static func parse(_ argv: [String]) -> Result<CLICommand, CLIUsageError> {
        guard let command = argv.first else {
            return .failure(CLIUsageError(message: usage))
        }
        let rest = Array(argv.dropFirst())

        switch command {
        case "doctor":
            return .success(.doctor)

        case "test-remote":
            guard let target = rest.first else {
                return .failure(CLIUsageError(message: "usage: synctray test-remote <name|shortId>"))
            }
            return .success(.testRemote(target))

        case "logs":
            guard let target = rest.first(where: { !$0.hasPrefix("--") }) else {
                return .failure(CLIUsageError(message: "usage: synctray logs <name|shortId> [--follow]"))
            }
            return .success(.logs(target: target, follow: rest.contains("--follow")))

        case "listremotes":
            return .success(.listRemotes)

        case "profiles":
            return .success(.profiles)

        case "status":
            return .success(.status(target: rest.first(where: { !$0.hasPrefix("-") })))

        case "sync":
            guard let target = rest.first(where: { !$0.hasPrefix("-") }) else {
                return .failure(CLIUsageError(message: "usage: synctray sync <name|shortId>"))
            }
            return .success(.sync(target))

        case "profile":
            return parseProfile(rest)

        case "help", "-h", "--help":
            return .success(.help)

        default:
            return .failure(CLIUsageError(message: usage))
        }
    }

    /// Parse the `profile <subcommand>` group.
    private static func parseProfile(_ rest: [String]) -> Result<CLICommand, CLIUsageError> {
        guard let sub = rest.first else {
            return .failure(CLIUsageError(message: "usage: synctray profile <create|enable|disable|delete|list> ..."))
        }
        let args = Array(rest.dropFirst())

        switch sub {
        case "list":
            return .success(.profiles)

        case "create":
            // `--from <file>` reads a file; a bare `-` reads stdin.
            if let idx = args.firstIndex(of: "--from"), idx + 1 < args.count {
                return .success(.profileCreate(.file(args[idx + 1])))
            }
            if args.contains("-") {
                return .success(.profileCreate(.stdin))
            }
            return .failure(CLIUsageError(message: "usage: synctray profile create --from <file.profile.json> | -  (stdin)"))

        case "enable", "disable":
            guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
                return .failure(CLIUsageError(message: "usage: synctray profile \(sub) <name|shortId>"))
            }
            return .success(.profileSetEnabled(target: target, enabled: sub == "enable"))

        case "delete":
            guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
                return .failure(CLIUsageError(message: "usage: synctray profile delete <name|shortId>"))
            }
            return .success(.profileDelete(target))

        default:
            return .failure(CLIUsageError(message: "unknown 'profile' subcommand: \(sub)\n" + usage))
        }
    }

    /// Parse + dispatch, printing usage via `env.stderr` on a parse failure.
    /// The single entry point both `dispatch` (real env) and the self-test
    /// (fake env) exercise for the unknown/absent-subcommand case.
    static func execute(_ argv: [String], env: CLIEnvironment) -> Int32 {
        switch parse(argv) {
        case .success(let command):
            return run(command, env: env)
        case .failure(let error):
            env.stderr(error.message + "\n")
            return 64  // EX_USAGE
        }
    }

    static func run(_ command: CLICommand, env: CLIEnvironment) -> Int32 {
        switch command {
        case .doctor:
            return runDoctor(env: env)
        case .testRemote(let target):
            return runTestRemote(target, env: env)
        case .logs(let target, let follow):
            return runLogs(target, follow: follow, env: env)
        case .listRemotes:
            return runListRemotes(env: env)
        case .profiles:
            return runProfiles(env: env)
        case .status(let target):
            return runStatus(target, env: env)
        case .sync(let target):
            return runSync(target, env: env)
        case .profileCreate(let source):
            return runProfileCreate(source, env: env)
        case .profileDelete(let target):
            return runProfileDelete(target, env: env)
        case .profileSetEnabled(let target, let enabled):
            return runProfileSetEnabled(target, enabled: enabled, env: env)
        case .help:
            env.stdout(Self.usage + "\n")
            return 0
        }
    }

    /// Resolve `target` against `profiles`: exact `shortId` match first, then a
    /// case-insensitive `name` match. Returns `nil` when nothing matches AND when
    /// the name is ambiguous (matches >1 profile) — callers treat both as "no
    /// profile matches". An ambiguous name is therefore indistinguishable from an
    /// absent one; disambiguate with the profile's shortId.
    static func resolveProfile(_ target: String, in profiles: [SyncProfile]) -> SyncProfile? {
        if let byShortId = profiles.first(where: { $0.shortId == target }) {
            return byShortId
        }
        let byName = profiles.filter { $0.name.caseInsensitiveCompare(target) == .orderedSame }
        return byName.count == 1 ? byName.first : nil
    }

    // MARK: - doctor

    private static func runDoctor(env: CLIEnvironment) -> Int32 {
        let checks = doctorChecks(env: env)
        for check in checks { env.stdout(check.line + "\n") }
        return checks.contains { $0.status == .fail } ? 1 : 0
    }

    /// Build the full doctor report against `env`. Exposed (not `private`) so
    /// `ConfigSelfTest` can assert the exact status matrix against fakes.
    static func doctorChecks(env: CLIEnvironment) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        let (rcloneExit, rcloneOut, _) = env.runRclone(["version"], 5)
        if rcloneExit == 0 {
            let version = rcloneOut.split(separator: "\n").first.map(String.init) ?? "unknown"
            checks.append(DoctorCheck(name: "rclone", status: .ok, detail: version))
        } else {
            checks.append(DoctorCheck(name: "rclone", status: .fail, detail: "not found"))
        }

        checks.append(
            env.schemaFilesPresent()
                ? DoctorCheck(name: "config schemas", status: .ok, detail: "installed")
                : DoctorCheck(name: "config schemas", status: .warn, detail: "not installed")
        )

        let profiles = env.readProfiles()
        if profiles.isEmpty {
            checks.append(DoctorCheck(name: "profiles", status: .warn, detail: "none configured"))
        }
        for profile in profiles {
            checks.append(contentsOf: doctorChecks(for: profile, env: env))
        }

        return checks
    }

    private static func doctorChecks(for profile: SyncProfile, env: CLIEnvironment) -> [DoctorCheck] {
        let label = "profile \"\(profile.name)\" (\(profile.shortId))"
        var checks: [DoctorCheck] = []

        checks.append(
            env.fileExists(profile.configPath)
                ? DoctorCheck(name: label, status: .ok, detail: "derived config present")
                : DoctorCheck(name: label, status: .fail, detail: "derived config missing")
        )

        if profile.isEnabled {
            let (_, launchctlOut) = env.runLaunchctl(["print", "gui/\(getuid())/\(profile.launchdLabel)"])
            checks.append(
                launchctlOut.isEmpty
                    ? DoctorCheck(name: label, status: .fail, detail: "launchd agent not loaded")
                    : DoctorCheck(name: label, status: .ok, detail: "launchd agent loaded")
            )
        }

        checks.append(
            env.fileExists(profile.lockFilePath)
                ? DoctorCheck(name: label, status: .warn, detail: "stale lock file present")
                : DoctorCheck(name: label, status: .ok, detail: "no stale lock")
        )

        let (remoteExit, _, remoteErr) = env.runRclone(["lsd", profile.fullRemotePath], 5)
        checks.append(
            remoteExit == 0
                ? DoctorCheck(name: label, status: .ok, detail: "remote reachable")
                : DoctorCheck(name: label, status: .fail, detail: "remote unreachable: \(remoteErr)")
        )

        return checks
    }

    // MARK: - test-remote

    private static func runTestRemote(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }

        // Prints the remote name to the user's own terminal — fine. It is NEVER
        // a telemetry attribute: the CLI records only the bounded command verb
        // (see `runMeasured`), never a remote name, path, or profile name.
        let (exit, _, err) = env.runRclone(["lsd", profile.fullRemotePath], 10)
        if exit == 0 {
            env.stdout("reachable: \(profile.fullRemotePath)\n")
            return 0
        } else {
            env.stderr("unreachable: \(err.isEmpty ? "rclone exited \(exit)" : err)\n")
            return 1
        }
    }

    // MARK: - logs

    private static func runLogs(_ target: String, follow: Bool, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        guard env.fileExists(profile.logPath) else {
            env.stderr("error: no log file at \(profile.logPath)\n")
            return 1
        }

        if follow {
            // Spawns a real, non-terminating `tail -f` — not fake-injectable via
            // `CLIEnvironment`, so the self-test only exercises resolve +
            // exists-check above for this command.
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            proc.arguments = ["-f", profile.logPath]
            try? proc.run()
            proc.waitUntilExit()
            return 0
        }

        if let contents = try? String(contentsOfFile: profile.logPath, encoding: .utf8) {
            env.stdout(contents)
        }
        return 0
    }

    // MARK: - listremotes

    private static func runListRemotes(env: CLIEnvironment) -> Int32 {
        let (exit, out, err) = env.runRclone(["listremotes"], 10)
        if exit == 0 {
            env.stdout(out)
            return 0
        } else {
            env.stderr(err.isEmpty ? "error: rclone listremotes failed\n" : err)
            return 1
        }
    }

    // MARK: - profiles

    private static func runProfiles(env: CLIEnvironment) -> Int32 {
        let profiles = env.readProfiles()
        guard !profiles.isEmpty else {
            env.stdout("no profiles configured\n")
            return 0
        }
        for profile in profiles {
            env.stdout(
                "\(profile.name)\t\(profile.shortId)\t\(profile.syncMode.rawValue)"
                    + "\tenabled=\(profile.isEnabled)\tremote=\(profile.rcloneRemote)\n"
            )
        }
        return 0
    }

    // MARK: - status

    private static func runStatus(_ target: String?, env: CLIEnvironment) -> Int32 {
        let all = env.readProfiles()
        let profiles: [SyncProfile]
        if let target {
            guard let match = resolveProfile(target, in: all) else {
                env.stderr("error: no profile matches \"\(target)\"\n")
                return 1
            }
            profiles = [match]
        } else {
            profiles = all
        }

        guard !profiles.isEmpty else {
            env.stdout(target == nil ? "no profiles configured\n" : "")
            return 0
        }

        for profile in profiles {
            let agent: String
            if !profile.isEnabled {
                agent = "n/a"
            } else {
                let (_, out) = env.runLaunchctl(["print", "gui/\(getuid())/\(profile.launchdLabel)"])
                agent = out.isEmpty ? "unloaded" : "loaded"
            }
            let running = env.fileExists(profile.lockFilePath)
            let last = env.fileExists(profile.logPath)
                ? lastLogEvent(inFileAt: profile.logPath, read: env.readFile)
                : "none"
            env.stdout(
                "\(profile.name)\t\(profile.shortId)"
                    + "\tenabled=\(profile.isEnabled)\tagent=\(agent)"
                    + "\trunning=\(running)\tlast=\(last)\n"
            )
        }
        return 0
    }

    /// Derive the last sync outcome from a log file's tail using the shared
    /// `SyncLogPatterns` — the SAME matchers `LogParser`/`SyncManager` use, so
    /// the CLI can never disagree with the app on what a log line means. Returns
    /// `started` / `completed` / `failed` / `none`.
    static func lastLogEvent(inFileAt path: String, read: (String) -> String?) -> String {
        guard let contents = read(path) else { return "none" }
        // Scan bottom-up for the most recent recognised lifecycle line.
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let message = String(line)
            if SyncLogPatterns.isSyncCompleted(message) { return "completed" }
            if SyncLogPatterns.isSyncFailed(message) { return "failed" }
            if SyncLogPatterns.isSyncStarted(message) { return "started" }
        }
        return "none"
    }

    // MARK: - sync

    private static func runSync(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        guard !profile.isMountMode else {
            env.stderr("error: \"\(profile.name)\" is a Stream (mount) profile; use 'profile enable' to mount it\n")
            return 1
        }
        guard env.fileExists(SyncProfile.sharedScriptPath) else {
            env.stderr("error: sync script not installed (\(SyncProfile.sharedScriptPath))\n")
            return 1
        }
        guard env.fileExists(profile.configPath) else {
            env.stderr("error: derived config missing (\(profile.configPath)); enable the profile first\n")
            return 1
        }

        env.stdout("syncing \"\(profile.name)\" (\(profile.shortId))…\n")
        let code = env.runSyncScript(profile.configPath)
        if code == 0 {
            env.stdout("sync completed\n")
        } else {
            env.stderr("sync exited \(code) — see: synctray logs \(profile.shortId)\n")
        }
        return code
    }

    // MARK: - profile create

    private static func runProfileCreate(_ source: CreateSource, env: CLIEnvironment) -> Int32 {
        let raw: String?
        switch source {
        case .file(let path):
            raw = env.readFile(path)
            if raw == nil { env.stderr("error: cannot read \(path)\n"); return 66 }  // EX_NOINPUT
        case .stdin:
            raw = env.readStdin()
            if raw == nil { env.stderr("error: cannot read profile JSON from stdin\n"); return 66 }
        }

        guard let data = raw?.data(using: .utf8) else {
            env.stderr("error: profile JSON is not valid UTF-8\n")
            return 65  // EX_DATAERR
        }
        let profile: SyncProfile
        do {
            profile = try JSONDecoder().decode(SyncProfile.self, from: data)
        } catch {
            env.stderr("error: invalid profile JSON: \(error)\n")
            return 65
        }

        let existing = env.readProfiles()
        if existing.contains(where: { $0.id == profile.id || $0.shortId == profile.shortId }) {
            env.stderr("error: profile \(profile.shortId) already exists; edit its file or use 'profile enable/disable'\n")
            return 1
        }

        guard env.writeProfile(profile) else {
            env.stderr("error: failed to write profile file\n")
            return 1
        }

        // Persist-always, install-iff-ready — the SAME rule the file-watcher
        // create path applies (`SyncManager.applyExternalCreateIfNeeded`).
        guard profile.isEnabled, profile.isValid else {
            env.stdout("created \(profile.name) (\(profile.shortId)) — not installed (disabled or incomplete)\n")
            return 0
        }
        if let err = env.installProfile(profile) {
            env.stderr("created \(profile.shortId) but install failed: \(err)\n")
            return 1
        }
        env.stdout("created \(profile.name) (\(profile.shortId)) — installed\n")
        return 0
    }

    // MARK: - profile delete

    private static func runProfileDelete(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        if let err = env.uninstallProfile(profile) {
            env.stderr("warning: uninstall reported: \(err)\n")
        }
        env.deleteProfileFile(profile)
        env.stdout("deleted \(profile.name) (\(profile.shortId))\n")
        return 0
    }

    // MARK: - profile enable / disable

    private static func runProfileSetEnabled(_ target: String, enabled: Bool, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        guard profile.isEnabled != enabled else {
            env.stdout("\(profile.shortId) already \(enabled ? "enabled" : "disabled")\n")
            return 0
        }

        var updated = profile
        updated.isEnabled = enabled
        guard env.writeProfile(updated) else {
            env.stderr("error: failed to write profile file\n")
            return 1
        }

        // Reuse the single source of truth for the launchd delta.
        let action = SyncManager.reconcileAction(from: profile, to: updated)
        let err: String?
        switch action {
        case .install, .reinstall:
            err = env.installProfile(updated)
        case .uninstall:
            err = env.uninstallProfile(profile)
        case .none:
            err = nil
        }
        if let err {
            env.stderr("\(enabled ? "enabled" : "disabled") \(profile.shortId) but launchd step failed: \(err)\n")
            return 1
        }
        env.stdout("\(enabled ? "enabled" : "disabled") \(profile.name) (\(profile.shortId))\n")
        return 0
    }
}

// MARK: - Production environment

extension CLIEnvironment {
    /// The real `CLIEnvironment`: actual `Process` invocations, actual
    /// filesystem reads, actual stdio. Built off `@MainActor` — the CLI never
    /// touches `ProfileStore`/`SyncManager`, only the `nonisolated`
    /// `ProfileStore.profilesOnDisk(in:)` file read.
    static func production() -> CLIEnvironment {
        CLIEnvironment(
            runRclone: { args, timeout in CLIEnvironment.runRcloneProcess(args: args, timeout: timeout) },
            readProfiles: { ProfileStore.profilesOnDisk(in: SyncProfile.configDirectory) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            runLaunchctl: { args in CLIEnvironment.runProcess(launchPath: "/bin/launchctl", args: args) },
            schemaFilesPresent: {
                ConfigSchemaInstaller.schemaResourceFilenames.allSatisfy {
                    FileManager.default.fileExists(atPath: "\(ConfigSchemaInstaller.schemaDirectory())/\($0)")
                }
            },
            writeProfile: { ProfileStore.writeProfileFile($0, in: SyncProfile.configDirectory) != nil },
            installProfile: { profile in
                do { try SyncSetupService.shared.install(profile: profile); return nil }
                catch { return "\(error)" }
            },
            uninstallProfile: { profile in
                do { try SyncSetupService.shared.uninstall(profile: profile); return nil }
                catch { return "\(error)" }
            },
            deleteProfileFile: { profile in
                let path = "\(SyncProfile.configDirectory)/\(profile.shortId).profile.json"
                try? FileManager.default.removeItem(atPath: path)
            },
            runSyncScript: { configPath in
                let (exit, _) = CLIEnvironment.runProcess(
                    launchPath: "/bin/bash",
                    args: [SyncProfile.sharedScriptPath, configPath],
                    timeout: 3600  // a large repo's first bisync can run for minutes
                )
                return exit
            },
            readStdin: {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)
            },
            readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
            stdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
            stderr: { FileHandle.standardError.write(Data($0.utf8)) },
            now: { Date() }
        )
    }

    /// Run rclone at its located path with a hard process-level watchdog —
    /// mirrors `RcloneLocator.resolveViaLoginShell`'s timeout pattern, since
    /// SMB/WebDAV remotes can hang past rclone's own `--timeout`.
    fileprivate static func runRcloneProcess(args: [String], timeout: TimeInterval) -> (Int32, String, String) {
        guard let rclonePath = RcloneLocator.resolve() else {
            return (127, "", "rclone not found")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rclonePath)
        proc.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            return (-1, "", "\(error)")
        }

        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain stdout and stderr CONCURRENTLY. Reading one to EOF before the
        // other deadlocks when the child fills the still-unread pipe's ~64 KB
        // buffer — exactly what an unreachable remote does to stderr, the very
        // buffer test-remote/doctor need. (RcloneLocator sidesteps this by
        // nulling stderr; here we need it, so we drain both at once.)
        var errData = Data()
        let errGroup = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: errGroup) {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        errGroup.wait()
        proc.waitUntilExit()
        watchdog.cancel()

        return (
            proc.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    fileprivate static func runProcess(launchPath: String, args: [String], timeout: TimeInterval = 10) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        // stderr → /dev/null: callers use only stdout + the exit code, and an
        // unread stderr Pipe can deadlock if the child fills its buffer.
        // nullDevice removes both the unread read and the deadlock.
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return (-1, "")
        }
        // Watchdog so a wedged child (e.g. a hung launchctl) can't block forever.
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

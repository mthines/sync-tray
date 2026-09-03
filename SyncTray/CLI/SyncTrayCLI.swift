import Foundation

/// Parsed CLI subcommand — the pure, testable result of `SyncTrayCLI.parse`.
enum CLICommand: Equatable {
    case doctor
    case testRemote(String)
    case logs(target: String, follow: Bool)
    case listRemotes
    case profiles
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
    var stdout: (String) -> Void
    var stderr: (String) -> Void
    var now: () -> Date
}

/// Headless `synctray` CLI, dispatched from `SyncTrayApp.init` exactly like
/// the existing `--self-test` intercept: parsed early, run, and `exit()`ed
/// before SwiftUI/telemetry/`SyncManager` ever start. NEVER opens a window,
/// NEVER launches background watchers/timers — see `dispatch`.
///
/// Pure core / impure shell: `parse`, `execute`, `doctorChecks`, and
/// `resolveProfile` operate entirely over their arguments/injected `env`, so
/// `ConfigSelfTest` drives the full dispatch + doctor-aggregation logic with
/// fakes. Only `CLIEnvironment.production()` and `dispatch` touch real
/// process/filesystem state.
enum SyncTrayCLI {
    private static let knownCommands: Set<String> = ["doctor", "test-remote", "logs", "listremotes", "profiles"]

    static let usage = """
    usage: synctray <command> [args]

    Commands:
      doctor                     Run a health check and print a report
      test-remote <name|id>      Probe a profile's remote reachability
      logs <name|id> [--follow]  Print or tail a profile's sync log
      listremotes                List configured rclone remotes
      profiles                   List configured SyncTray profiles
    """

    // MARK: - Entry point

    /// Returns the process exit code if `arguments` names a recognized CLI
    /// subcommand, or `nil` if not — leaving `--self-test` and a normal
    /// (no-argument) launch untouched. `arguments` is `CommandLine.arguments`
    /// (program name included).
    static func dispatch(arguments: [String]) -> Int32? {
        let argv = Array(arguments.dropFirst())
        guard let first = argv.first, knownCommands.contains(first) else { return nil }
        return execute(argv, env: .production())
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

        default:
            return .failure(CLIUsageError(message: usage))
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
        }
    }

    /// Resolve `target` against `profiles`: exact `shortId` match first, then
    /// a case-insensitive `name` match. Returns `nil` when nothing matches, or
    /// when the name matches more than one profile (ambiguous — caller reports
    /// the collision rather than guessing).
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

        // Prints the remote name to the user's own terminal — fine. This is
        // NEVER sent to telemetry (CLI mode never configures TelemetryService).
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

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()

        return (
            proc.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    fileprivate static func runProcess(launchPath: String, args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

import Foundation

/// Locates the `rclone` binary across the many places macOS package managers install it.
///
/// A macOS GUI app inherits a minimal `PATH` (roughly `/usr/bin:/bin:/usr/sbin:/sbin`),
/// not the user's interactive shell `PATH`, so a bare `which rclone` from inside the
/// process misses most installs. SyncTray therefore probes a fixed list of known absolute
/// locations first, then falls back to asking the user's login shell where `rclone` lives.
///
/// The hardcoded list used to cover only Homebrew (`/opt/homebrew`, `/usr/local`) and
/// `/usr/bin`, which missed nix-darwin installs — those live under
/// `/run/current-system/sw/bin` and the username-dependent `/etc/profiles/per-user/<user>/bin`
/// (issue #53). Both are now in `candidatePaths`, and the login-shell fallback catches any
/// other layout the user configured.
///
/// This is a plain, actor-agnostic enum so any caller (including background threads and
/// `@MainActor` types) can resolve the path without a hop. Resolution touches the filesystem
/// and may spawn a shell, so a successful result is cached; a `nil` result is not cached, so a
/// later call re-resolves once rclone is installed.
enum RcloneLocator {
    /// How the binary was found. Low-cardinality — safe to attach to telemetry.
    enum Source: String {
        case candidatePath = "candidate_path"
        case loginShell = "login_shell"
        case notFound = "not_found"
    }

    /// Absolute paths probed, in priority order. Homebrew first preserves the historical
    /// preference; the nix paths and the `~/.nix-profile` single-user profile were added for
    /// issue #53.
    static var candidatePaths: [String] {
        let user = NSUserName()
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/rclone",                       // Homebrew (Apple Silicon)
            "/usr/local/bin/rclone",                          // Homebrew (Intel) / manual install
            "/run/current-system/sw/bin/rclone",              // nix-darwin system profile
            "/etc/profiles/per-user/\(user)/bin/rclone",      // nix-darwin per-user profile
            "\(home)/.nix-profile/bin/rclone",                // nix single-user profile
            "/usr/bin/rclone",                                // system / MDM-managed
        ]
    }

    private static let lock = NSLock()
    private static var cachedPath: String?

    /// Resolve the rclone binary path, caching a successful result.
    ///
    /// Returns `nil` when rclone can't be found anywhere. A `nil` is deliberately not cached
    /// so installing rclone while the app runs is picked up on the next call.
    static func resolve() -> String? {
        if let cached = cachedResult() { return cached }
        // Resolve outside the lock: locate() may spawn a login shell, and holding the lock
        // across it would serialize every concurrent caller behind one (up-to-5s) spawn.
        let result = locate()
        if let path = result.path { storeResult(path) }
        return result.path
    }

    private static func cachedResult() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedPath
    }

    private static func storeResult(_ path: String) {
        lock.lock()
        cachedPath = path
        lock.unlock()
    }

    /// Whether rclone is installed and locatable.
    static func isInstalled() -> Bool {
        resolve() != nil
    }

    /// Uncached resolution that also reports *how* the binary was found and a low-cardinality
    /// location bucket. Used for telemetry at launch. Populates the cache on success so a
    /// following `resolve()` doesn't repeat the (possibly shell-spawning) work.
    static func resolveDetailed() -> (path: String?, source: Source, location: String) {
        let result = locate()
        if let path = result.path { storeResult(path) }
        return (result.path, result.source, locationBucket(for: result.path))
    }

    // MARK: - Private

    private static func locate() -> (path: String?, source: Source) {
        let fm = FileManager.default
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            return (path, .candidatePath)
        }
        if let shellPath = resolveViaLoginShell() {
            return (shellPath, .loginShell)
        }
        return (nil, .notFound)
    }

    /// Ask the user's login shell for rclone's path. A login shell (`-l`) sources the profile
    /// files that add Homebrew / nix / custom dirs to `PATH`, so this finds installs the fixed
    /// candidate list doesn't know about — the robust equivalent of `which rclone` for a GUI app.
    private static func resolveViaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `command -v rclone` prints the resolved path (or nothing) and is a shell builtin,
        // so it needs no external binary on PATH to run.
        process.arguments = ["-lc", "command -v rclone"]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr rather than pipe it: a login profile that writes a lot to stderr
        // would fill an undrained pipe buffer and hang the shell until the watchdog fires.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Guard against a pathological shell rc that hangs: kill the probe after 5s so a
        // background caller never blocks indefinitely.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }

        // Take the last non-empty line: a login shell (`-lc`) sources profile files
        // that may print their own output (an `echo` in `.zprofile`, a banner) before
        // `command -v`'s result, so trimming the whole output would keep that noise.
        guard let path = output
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty })
        else { return nil }
        // `command -v` can also print a builtin/alias/function name; only trust an absolute
        // path to a real executable.
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// Map a resolved path to a low-cardinality bucket for telemetry. Never emits the raw path,
    /// so no username or custom directory leaks; an unrecognised location collapses to `other`.
    private static func locationBucket(for path: String?) -> String {
        guard let path else { return "none" }
        if path.hasPrefix("/opt/homebrew/") { return "homebrew" }
        if path.hasPrefix("/usr/local/") { return "usr_local" }
        if path.hasPrefix("/run/current-system/") { return "nix_system" }
        if path.hasPrefix("/etc/profiles/per-user/") { return "nix_per_user" }
        if path.contains("/.nix-profile/") { return "nix_profile" }
        if path.hasPrefix("/usr/bin/") { return "usr_bin" }
        return "other"
    }
}

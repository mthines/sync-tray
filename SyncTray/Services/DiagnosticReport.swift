import Foundation

// MARK: - Model

/// A diagnostic report the user explicitly chose to send to the SyncTray developer.
///
/// Unlike usage telemetry (`TelemetryService`), a report CAN contain personal paths, file
/// and folder names, remote names and full error text — the user is told so in plain words
/// (`DiagnosticReportCopy.disclosure`) and consents per send. Recognized secrets are stripped:
/// every line of every section goes through `DiagnosticRedactor.redact` before it is stored,
/// and the builder never reads a credential file (`DiagnosticReportBuilder.isNeverRead`).
/// See CLAUDE.md "Diagnostic reports".
struct DiagnosticReport: Equatable {
    /// Where a section's lines came from — also the `diagnostics.source` log attribute.
    enum Source: String, CaseIterable, Equatable {
        case log, status, doctor, config, filter, locks, processes, launchd, system
    }

    /// One titled block of the report. `profileId`/`profileName` are set for the
    /// per-profile sections (log, config, filter, locks) and nil for the global ones.
    struct Section: Equatable {
        let source: Source
        let profileId: UUID?
        let profileName: String?
        var lines: [String]

        init(source: Source, profileId: UUID? = nil, profileName: String? = nil, lines: [String]) {
            self.source = source
            self.profileId = profileId
            self.profileName = profileName
            self.lines = lines
        }

        /// Heading used by `render()`.
        var heading: String {
            let title: String
            switch source {
            case .system: title = "System"
            case .status: title = "Status (synctray status --json)"
            case .doctor: title = "Health check (synctray doctor)"
            case .processes: title = "Running sync processes"
            case .launchd: title = "launchd agents"
            case .config: title = "Profile settings (.profile.json)"
            case .filter: title = "Filter file (-exclude.txt)"
            case .locks: title = "Locks"
            case .log: title = "Sync log"
            }
            guard let profileName else { return title }
            let shortId = profileId.map { String($0.uuidString.prefix(8)).lowercased() } ?? "?"
            return "\(title) — \(profileName) (\(shortId))"
        }
    }

    /// The short code the user hands the developer (`ST-XXXXXX`), also the
    /// `diagnostics.report_id` attribute on every uploaded record.
    let code: String
    let createdAt: Date
    var sections: [Section]
    var appVersion: String
    var rcloneVersion: String
    var macOSVersion: String
    var telemetryEnabled: Bool
    /// True when any line was shortened (8 KB cap) or old log lines were dropped (5 MB cap).
    var truncated: Bool
    /// Human-readable notes about what was shortened or left out.
    var notes: [String]

    init(
        code: String,
        createdAt: Date,
        sections: [Section],
        appVersion: String = "",
        rcloneVersion: String = "",
        macOSVersion: String = "",
        telemetryEnabled: Bool = false,
        truncated: Bool = false,
        notes: [String] = []
    ) {
        self.code = code
        self.createdAt = createdAt
        self.sections = sections
        self.appVersion = appVersion
        self.rcloneVersion = rcloneVersion
        self.macOSVersion = macOSVersion
        self.telemetryEnabled = telemetryEnabled
        self.truncated = truncated
        self.notes = notes
    }

    /// Total number of lines across all sections (= uploaded line records).
    var lineCount: Int {
        sections.reduce(0) { $0 + $1.lines.count }
    }

    /// Number of distinct profiles the report covers.
    var profileCount: Int {
        Set(sections.compactMap { $0.profileId }).count
    }

    /// Readable plain text: a header (code, timestamp, versions) and one headed block per
    /// section. Used for Preview, Save, and the CLI's stdout. Every line is already redacted.
    func render() -> String {
        var out: [String] = [
            "SyncTray diagnostic report",
            "Report code: \(code)",
            "Created: \(Self.timestampString(createdAt))",
            "SyncTray: \(appVersion)",
            "rclone: \(rcloneVersion)",
            "macOS: \(macOSVersion)",
            "Usage data sharing: \(telemetryEnabled ? "on" : "off")",
        ]
        for note in notes {
            out.append("Note: \(note)")
        }
        for section in sections {
            out.append("")
            out.append("== \(section.heading) ==")
            if section.lines.isEmpty {
                out.append("(empty)")
            } else {
                out.append(contentsOf: section.lines)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func timestampString(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }
}

// MARK: - User-facing copy

/// The disclosure and follow-up copy, shared by the app's sheet and the CLI so the two
/// always say the same thing.
enum DiagnosticReportCopy {
    static let disclosure = "This report includes recent sync log lines, your profile settings and their status. Unlike usage data, it can include file and folder names, paths in your home folder (including your username), remote names and full error messages. SyncTray removes the passwords and tokens it recognizes before anything is sent. If usage data is on, the report is linked to SyncTray's anonymous install ID. It goes to the SyncTray developer, and nothing is sent until you choose to send it."

    static let shareCode = "Send this code to the developer so they can find your report."
}

// MARK: - Report code

/// `ST-` + 6 characters from an alphabet without look-alikes (no 0/O, 1/I/L), so a code
/// read out over chat or a call survives transcription.
enum DiagnosticReportCode {
    static let prefix = "ST-"
    static let length = 6
    static let alphabet: [Character] = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")

    static func generate<R: RandomNumberGenerator>(using rng: inout R) -> String {
        var body = ""
        for _ in 0..<length {
            body.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)])
        }
        return prefix + body
    }

    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    static func isValid(_ code: String) -> Bool {
        guard code.hasPrefix(prefix) else { return false }
        let body = code.dropFirst(prefix.count)
        return body.count == length && body.allSatisfy { alphabet.contains($0) }
    }
}

// MARK: - Redaction

/// Strips secret VALUES from a line while keeping the key or flag name visible, so the
/// developer can still see that, say, `--sftp-pass` was set. Pure.
///
/// Every rule needs context — a known key, a flag name, an env-var name, URL userinfo, or
/// a header — so ordinary file names (`Keynote.key`, `passport.pdf`, `token-ring notes.txt`,
/// a folder called `secret stuff`) are left alone. Covered by `ConfigSelfTest` AC-DR2.
enum DiagnosticRedactor {
    static let placeholder = "[REDACTED]"

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    /// Order matters: JSON keys and headers first (they consume whole values, so the later
    /// key=value rule never sees half a header), then env vars and flags, then generic keys,
    /// URL userinfo and signed-URL query values.
    /// Each rule skips a value that is already `[REDACTED]`, so `redact` is idempotent.
    private static let ruleSpecs: [(pattern: String, template: String)] = [
        // 1. JSON `"<key>": "<value>"` for a secret key (exact key match).
        (#"(?i)("(?:password|passwd|pass|token|access[_\-]?token|refresh[_\-]?token|auth[_\-]?token|session[_\-]?token|client[_\-]?secret|secret[_\-]?access[_\-]?key|private[_\-]?key|account[_\-]?key|sas[_\-]?url|secret|api[_\-]?key|cookie|set-cookie|authorization|proxy-authorization)"\s*:\s*")(?:[^"\\]|\\.)*(")"#,
         "$1[REDACTED]$2"),
        // 2. `Authorization: …` / `Cookie: …` header values, up to a quote or end of line.
        (#"(?i)(\b(?:proxy-)?authorization\s*+[:=]\s*+|\b(?:set-)?cookie\s*+:\s*+)(?!\[REDACTED\])[^"\r\n]+"#,
         "$1[REDACTED]"),
        // 3. A bare `Bearer <token>`.
        (#"(?i)\b(bearer)\s++(?!\[REDACTED\])[A-Za-z0-9\-._~+/]{16,}=*"#,
         "$1 [REDACTED]"),
        // 4. Secret env assignments: RCLONE_…_PASS/_TOKEN/_SECRET/_KEY (incl. RCLONE_RC_PASS),
        //    DASH0_AUTH_TOKEN, OTEL_EXPORTER_OTLP[_<SIGNAL>]_HEADERS.
        (#"(?i)(?<![A-Za-z0-9_])((?:RCLONE_[A-Z0-9_]*_(?:PASS|PASSWORD|TOKEN|SECRET|KEY)[0-9]?)|DASH0_AUTH_TOKEN|OTEL_EXPORTER_OTLP(?:_[A-Z]+)?_HEADERS)(\s*+=\s*+)(?!\[REDACTED\])(?:\{[^\{\}\r\n]*\}|"[^"]*"|'[^']*'|[^\s"]+)"#,
         "$1$2[REDACTED]"),
        // 5. CLI flags whose name ends in -pass/-password/-token/-secret/-key (so also
        //    -client-secret, -secret-access-key), `--flag value` and `--flag=value`. The flag
        //    must start a word, so a path like `a-b-token notes` is not a flag.
        (#"(?i)(?<![^\s"'])(--?(?:[a-z0-9][a-z0-9_\-]*-)?(?:pass|password|token|secret|key|key-pem|credentials|sas-url)[0-9]?)(=|\s++)(?!\[REDACTED\])(?!--[a-z])(?:\{[^\{\}\r\n]*\}|\\".*?\\"|"[^"]*"|'[^']*'|[^\s"]+)"#,
         "$1$2[REDACTED]"),
        // 6. `key=value`, `key: value`, `key = value` for a known secret key.
        (#"(?i)(?<![a-z0-9])(password|passwd|pass|access_token|refresh_token|auth_token|session_token|client_secret|secret_access_key|private_key|account_key|sas_url|secret|api_key|api-key|apikey|cookie|token)(\s*+[=:]\s*+)(?!\[REDACTED\])("[^"]*"|'[^']*'|[^\s,;\&"'\}\]]+)"#,
         "$1$2[REDACTED]"),
        // 7. URL userinfo: scheme://user:pass@host → scheme://[REDACTED]@host.
        (#"(?i)\b([a-z][a-z0-9+.\-]*://)(?!\[REDACTED\]@)[^/\s@"']+@"#,
         "$1[REDACTED]@"),
        // 8. Signed-URL query parameters (Azure SAS `sig=`, S3 `X-Amz-Signature=`).
        (#"(?i)([?\&](?:sig|signature|x-amz-signature)=)(?!\[REDACTED\])[^\&\s"'#]+"#,
         "$1[REDACTED]"),
    ]

    private static let rules: [Rule] = ruleSpecs.compactMap { spec -> Rule? in
        guard let regex = try? NSRegularExpression(pattern: spec.pattern, options: []) else {
            assertionFailure("DiagnosticRedactor: invalid pattern \(spec.pattern)")
            return nil
        }
        return Rule(regex: regex, template: spec.template)
    }

    /// Number of rules defined vs. compiled — the self-test asserts they match, so a pattern
    /// that stops compiling can never silently weaken redaction.
    static var definedRuleCount: Int { ruleSpecs.count }
    static var compiledRuleCount: Int { rules.count }

    static func redact(_ line: String) -> String {
        guard !line.isEmpty else { return line }
        var result = line
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: rule.template)
        }
        return result
    }
}

// MARK: - Builder environment

/// Every impure operation the builder touches, injected so `DiagnosticReportBuilder.build`
/// is testable with fakes (`ConfigSelfTest` AC-DR3). All file reads go through `readFile`
/// and `tailLines`, which the builder only ever calls for `plannedReads(for:)` paths and
/// never for a credential file.
struct DiagnosticReportEnvironment {
    /// Read a whole (small) file as UTF-8. `nil` if missing/unreadable.
    var readFile: (String) -> String?
    /// The last `count` lines of a (possibly large) file. `nil` if missing/unreadable.
    var tailLines: (_ path: String, _ count: Int) -> [String]?
    /// Run a process and return `(exitCode, stdout)`. Used for `ps` and `launchctl list`.
    var runProcess: (_ launchPath: String, _ args: [String]) -> (Int32, String)
    /// Whether a PID belongs to a running process.
    var isProcessAlive: (Int32) -> Bool
    /// `synctray status --json` for the given profiles. `nil` if unavailable.
    var statusJSON: (_ profiles: [SyncProfile]) -> String?
    /// `synctray doctor` lines for the given profiles.
    var doctorLines: (_ profiles: [SyncProfile]) -> [String]
    var now: () -> Date
    var appVersion: () -> String
    var rcloneVersion: () -> String?
    var macOSVersion: () -> String
    var telemetryEnabled: () -> Bool
    var makeCode: () -> String
}

// MARK: - Builder

enum DiagnosticReportBuilder {
    static let defaultLineLimit = 500
    /// Per-line cap (UTF-8 bytes) after redaction.
    static let maxLineBytes = 8 * 1024
    /// Whole-report cap (UTF-8 bytes); oldest log lines are dropped first to meet it.
    static let maxReportBytes = 5 * 1024 * 1024
    /// Lines longer than this are cut BEFORE redaction, only to bound regex cost; the
    /// 8 KB cap applied after redaction is what the report keeps.
    static let preRedactionLimit = 64 * 1024
    static let truncationMarker = "…[truncated]"
    /// Prefix of the single line a log section holds when the profile has no log file yet.
    static let missingLogPrefix = "(no sync log at "

    /// Files the builder must never read, enforced by construction: every read is checked
    /// against this before the injected reader is called. rclone.conf (any `*.rclone.conf`,
    /// including the Cache Only union config), `~/.config/synctray/.env` (the telemetry
    /// token), and the RC API secrets under `~/.local/state/synctray/rc/*.auth`.
    static func isNeverRead(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "rclone.conf" || name.hasSuffix(".rclone.conf") { return true }
        if name == ".env" { return true }
        if name.hasSuffix(".auth") { return true }
        return false
    }

    /// Every file a build for `profiles` reads, in order. `build` reads nothing else
    /// directly (the status/doctor closures read through the same guard in production).
    static func plannedReads(for profiles: [SyncProfile]) -> [String] {
        profiles.flatMap { profile -> [String] in
            var paths = [profile.profileFilePath, profile.filterFilePath, profile.lockFilePath]
            if profile.syncMode == .bisync {
                paths.append(SyncRunLock.sessionLockPath(for: profile))
            }
            paths.append(profile.logPath)
            return paths
        }
    }

    static func build(
        profiles: [SyncProfile],
        environment env: DiagnosticReportEnvironment,
        lineLimit: Int = DiagnosticReportBuilder.defaultLineLimit,
        maxReportBytes: Int = DiagnosticReportBuilder.maxReportBytes
    ) -> DiagnosticReport {
        let limit = max(1, lineLimit)
        let createdAt = env.now()
        var anyLineCut = false

        func readGuarded(_ path: String) -> String? {
            guard !isNeverRead(path) else { return nil }
            return env.readFile(path)
        }
        func tailGuarded(_ path: String, _ count: Int) -> [String]? {
            guard !isNeverRead(path) else { return nil }
            return env.tailLines(path, count)
        }
        func clean(_ raw: [String]) -> [String] {
            var result: [String] = []
            result.reserveCapacity(raw.count)
            for line in raw {
                // Each redaction bridges through NSString/NSRegularExpression; without a pool
                // the autoreleased temporaries pile up (~1.7 GB peak at --lines 100000).
                let sanitized = autoreleasepool { sanitize(line) }
                if sanitized.truncated { anyLineCut = true }
                result.append(sanitized.line)
            }
            return result
        }

        let appVersion = env.appVersion()
        let rcloneVersion = env.rcloneVersion() ?? "not found"
        let macOSVersion = env.macOSVersion()
        let telemetryEnabled = env.telemetryEnabled()

        var sections: [DiagnosticReport.Section] = []

        // System
        var systemLines = [
            "SyncTray version: \(appVersion)",
            "rclone version: \(rcloneVersion)",
            "macOS: \(macOSVersion)",
            "Architecture: \(hostArchitecture)",
            "Usage data sharing: \(telemetryEnabled ? "on" : "off")",
            "Profiles in this report: \(profiles.count)",
        ]
        for profile in profiles {
            systemLines.append("Profile \"\(profile.name)\" (\(profile.shortId)): mode=\(profile.syncMode.rawValue) enabled=\(profile.isEnabled)")
        }
        sections.append(DiagnosticReport.Section(source: .system, lines: clean(systemLines)))

        // Status (synctray status --json)
        let statusLines = env.statusJSON(profiles).map(splitLines) ?? ["(status unavailable)"]
        sections.append(DiagnosticReport.Section(source: .status, lines: clean(statusLines)))

        // Doctor
        let doctor = env.doctorLines(profiles)
        sections.append(DiagnosticReport.Section(source: .doctor, lines: clean(doctor.isEmpty ? ["(no checks)"] : doctor)))

        // Running sync processes
        let (psExit, psOutput) = env.runProcess("/bin/ps", ["-axww", "-o", "pid=,ppid=,etime=,args="])
        var processLines: [String]
        if psExit == 0 {
            processLines = syncProcessLines(fromPS: psOutput)
            if processLines.isEmpty {
                processLines = ["(no synctray-sync.sh or rclone processes running)"]
            }
        } else {
            processLines = ["(ps failed with exit code \(psExit))"]
        }
        sections.append(DiagnosticReport.Section(source: .processes, lines: clean(processLines)))

        // launchd
        let (launchctlExit, launchctlOutput) = env.runProcess("/bin/launchctl", ["list"])
        var launchdLines: [String]
        if launchctlExit == 0 {
            launchdLines = splitLines(launchctlOutput).filter {
                $0.range(of: "synctray", options: .caseInsensitive) != nil
            }
            launchdLines = launchdLines.isEmpty
                ? ["(no SyncTray launchd agents loaded)"]
                : ["PID\tStatus\tLabel"] + launchdLines
        } else {
            launchdLines = ["(launchctl list failed with exit code \(launchctlExit))"]
        }
        sections.append(DiagnosticReport.Section(source: .launchd, lines: clean(launchdLines)))

        // Per profile
        for profile in profiles {
            let id = profile.id
            let name = profile.name

            let configLines = readGuarded(profile.profileFilePath).map(splitLines)
                ?? ["(no profile file at \(profile.profileFilePath))"]
            sections.append(DiagnosticReport.Section(source: .config, profileId: id, profileName: name, lines: clean(configLines)))

            let filterLines = readGuarded(profile.filterFilePath).map(splitLines)
                ?? ["(no filter file at \(profile.filterFilePath))"]
            sections.append(DiagnosticReport.Section(source: .filter, profileId: id, profileName: name, lines: clean(filterLines)))

            var lockLines = [describeLock(label: "Run lock", path: profile.lockFilePath,
                                          contents: readGuarded(profile.lockFilePath), isAlive: env.isProcessAlive)]
            if profile.syncMode == .bisync {
                let sessionPath = SyncRunLock.sessionLockPath(for: profile)
                lockLines.append(describeLock(label: "Bisync session lock", path: sessionPath,
                                              contents: readGuarded(sessionPath), isAlive: env.isProcessAlive))
            }
            sections.append(DiagnosticReport.Section(source: .locks, profileId: id, profileName: name, lines: clean(lockLines)))

            let logLines = tailGuarded(profile.logPath, limit).map { Array($0.suffix(limit)) }
                ?? ["\(missingLogPrefix)\(profile.logPath))"]
            sections.append(DiagnosticReport.Section(source: .log, profileId: id, profileName: name, lines: clean(logLines)))
        }

        let dropped = enforceTotalCap(&sections, maxBytes: maxReportBytes)

        var notes: [String] = []
        if dropped > 0 {
            notes.append("\(dropped) oldest sync log line(s) were left out to keep the report under \(max(1, maxReportBytes / 1_048_576)) MB.")
        }
        if anyLineCut {
            notes.append("Lines longer than 8 KB were shortened.")
        }

        return DiagnosticReport(
            code: env.makeCode(),
            createdAt: createdAt,
            sections: sections,
            appVersion: appVersion,
            rcloneVersion: rcloneVersion,
            macOSVersion: macOSVersion,
            telemetryEnabled: telemetryEnabled,
            truncated: dropped > 0 || anyLineCut,
            notes: notes
        )
    }

    /// Redact, then cap one line at `maxLineBytes` (appending `truncationMarker`). Redacting
    /// BEFORE the cap means the cut can never leave half a secret behind.
    static func sanitize(_ raw: String) -> (line: String, truncated: Bool) {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        var cutBeforeRedaction = false
        if line.utf8.count > preRedactionLimit {
            line = utf8Prefix(line, maxBytes: preRedactionLimit)
            cutBeforeRedaction = true
        }
        let redacted = DiagnosticRedactor.redact(line)
        if redacted.utf8.count > maxLineBytes {
            return (utf8Prefix(redacted, maxBytes: maxLineBytes) + truncationMarker, true)
        }
        return cutBeforeRedaction ? (redacted + truncationMarker, true) : (redacted, false)
    }

    /// The longest prefix of `text` that fits in `maxBytes` UTF-8 bytes, never splitting a
    /// Unicode scalar.
    static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        var result = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let width = value < 0x80 ? 1 : (value < 0x800 ? 2 : (value < 0x10000 ? 3 : 4))
            if bytes + width > maxBytes { break }
            result.append(scalar)
            bytes += width
        }
        return String(result)
    }

    /// Drop the oldest log lines (round-robin across profiles) until the report fits in
    /// `maxBytes`, marking each shortened log section. A log section that only holds the
    /// "(no sync log at …)" placeholder is never touched — there is no log to shorten, and
    /// replacing it with "…[1 older log line(s) left out]" would mislead. Returns how many
    /// lines were dropped.
    static func enforceTotalCap(_ sections: inout [DiagnosticReport.Section], maxBytes: Int) -> Int {
        func size(_ line: String) -> Int { line.utf8.count + 1 }
        var total = sections.reduce(0) { sum, section in
            sum + section.lines.reduce(0) { $0 + size($1) }
        }
        guard total > maxBytes else { return 0 }

        let logIndices = sections.indices.filter { index in
            sections[index].source == .log && !isMissingLogPlaceholder(sections[index].lines)
        }
        var droppedPerSection = [Int](repeating: 0, count: sections.count)
        var progressed = true
        while total > maxBytes && progressed {
            progressed = false
            for index in logIndices where droppedPerSection[index] < sections[index].lines.count {
                total -= size(sections[index].lines[droppedPerSection[index]])
                droppedPerSection[index] += 1
                progressed = true
                if total <= maxBytes { break }
            }
        }

        var droppedTotal = 0
        for index in logIndices where droppedPerSection[index] > 0 {
            let count = droppedPerSection[index]
            sections[index].lines.removeFirst(count)
            sections[index].lines.insert("…[\(count) older log line(s) left out to keep the report small]", at: 0)
            droppedTotal += count
        }
        return droppedTotal
    }

    /// Whether a log section holds only the "(no sync log at …)" placeholder.
    static func isMissingLogPlaceholder(_ lines: [String]) -> Bool {
        lines.count == 1 && lines[0].hasPrefix(missingLogPrefix)
    }

    /// One line describing a lock file and whether its holder is alive.
    static func describeLock(label: String, path: String, contents: String?, isAlive: (Int32) -> Bool) -> String {
        guard let contents else { return "\(label) \(path): absent" }
        let state: String
        switch SyncRunLock.parseHolder(contents) {
        case .none:
            state = "empty"
        case .pending:
            state = "held by the \"pending\" placeholder (treated as live)"
        case .unreadable:
            state = "holder unreadable"
        case .pid(let pid):
            state = "held by pid \(pid) (\(isAlive(pid) ? "alive" : "not running — stale"))"
        }
        let raw = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return "\(label) \(path): \(state); contents: \(raw)"
    }

    /// `ps -axww -o pid=,ppid=,etime=,args=` output filtered to the sync script and rclone.
    static func syncProcessLines(fromPS output: String) -> [String] {
        splitLines(output).compactMap { line -> String? in
            guard let fields = parsePSLine(line), isSyncProcess(args: fields.args) else { return nil }
            return "pid=\(fields.pid) ppid=\(fields.ppid) elapsed=\(fields.etime) args=\(fields.args)"
        }
    }

    static func parsePSLine(_ line: String) -> (pid: String, ppid: String, etime: String, args: String)? {
        var rest = Substring(line)
        var fields: [String] = []
        for _ in 0..<3 {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            fields.append(String(rest[..<end]))
            rest = rest[end...]
        }
        let args = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard fields.count == 3, !args.isEmpty else { return nil }
        return (fields[0], fields[1], fields[2], String(args))
    }

    static func isSyncProcess(args: String) -> Bool {
        if args.contains("synctray-sync.sh") { return true }
        guard let executable = args.split(separator: " ").first else { return false }
        return (String(executable) as NSString).lastPathComponent == "rclone"
    }

    /// Split text into lines, dropping the empty element after a trailing newline.
    static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

// MARK: - Production environment

extension DiagnosticReportEnvironment {
    /// The real environment: actual files, `ps`, `launchctl`, rclone, and the CLI's own
    /// status/doctor derivation. Not `@MainActor` — callers run it off the main thread.
    static func production() -> DiagnosticReportEnvironment {
        DiagnosticReportEnvironment(
            readFile: { path in try? String(contentsOfFile: path, encoding: .utf8) },
            tailLines: { path, count in DiagnosticReportEnvironment.tailFile(path: path, lineCount: count) },
            runProcess: { launchPath, args in DiagnosticReportEnvironment.runProcess(launchPath: launchPath, args: args) },
            isProcessAlive: { pid in SyncRunLock.processIsAlive(pid) },
            statusJSON: { profiles in DiagnosticReportEnvironment.cliStatusJSON(profiles) },
            doctorLines: { profiles in DiagnosticReportEnvironment.cliDoctorLines(profiles) },
            now: { Date() },
            appVersion: { TelemetryService.diagnosticServiceVersion },
            rcloneVersion: {
                let (exit, output, _) = CLIEnvironment.runRcloneProcess(args: ["version"], timeout: 5)
                guard exit == 0 else { return nil }
                return output.split(separator: "\n").first.map(String.init)
            },
            macOSVersion: { ProcessInfo.processInfo.operatingSystemVersionString },
            telemetryEnabled: { SyncTraySettings.telemetryEnabled },
            makeCode: { DiagnosticReportCode.generate() }
        )
    }

    /// The CLI's production environment, narrowed to the report's profiles, with its file
    /// reader behind the same never-read guard and its stdio silenced.
    private static func cliEnvironment(for profiles: [SyncProfile]) -> CLIEnvironment {
        var env = CLIEnvironment.production()
        let baseRead = env.readFile
        env.readFile = { path in DiagnosticReportBuilder.isNeverRead(path) ? nil : baseRead(path) }
        env.readProfiles = { profiles }
        env.stdout = { _ in }
        env.stderr = { _ in }
        return env
    }

    /// `synctray status --json` for `profiles`, via the CLI's own `statusReport`.
    static func cliStatusJSON(_ profiles: [SyncProfile]) -> String? {
        let env = cliEnvironment(for: profiles)
        let reports = profiles.map { SyncTrayCLI.statusReport(for: $0, env: env) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(reports) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `synctray doctor` lines for `profiles`, via the CLI's own `doctorChecks`.
    static func cliDoctorLines(_ profiles: [SyncProfile]) -> [String] {
        SyncTrayCLI.doctorChecks(env: cliEnvironment(for: profiles)).map { $0.line }
    }

    /// Read at most this much from the end of a log when tailing it.
    static let tailReadLimit: UInt64 = 16 * 1024 * 1024

    /// The last `lineCount` lines of a file, reading backwards in chunks so a large log is
    /// never loaded whole.
    static func tailFile(path: String, lineCount: Int) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            var offset = size
            var chunks: [Data] = []
            var newlines = 0
            var readTotal: UInt64 = 0
            while offset > 0, newlines <= lineCount, readTotal < tailReadLimit {
                let length = min(UInt64(64 * 1024), offset)
                offset -= length
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: Int(length)) ?? Data()
                if data.isEmpty { break }
                readTotal += UInt64(data.count)
                for byte in data where byte == 0x0A { newlines += 1 }
                chunks.append(data)
            }
            let joined = Data(chunks.reversed().joined())
            var lines = DiagnosticReportBuilder.splitLines(String(decoding: joined, as: UTF8.self))
            // A read that stopped mid-file starts mid-line; drop that partial first line.
            if offset > 0, !lines.isEmpty { lines.removeFirst() }
            return Array(lines.suffix(max(0, lineCount)))
        } catch {
            return nil
        }
    }

    /// Run a process with a watchdog; stderr is discarded. Returns `(exitCode, stdout)`.
    static func runProcess(launchPath: String, args: [String], timeout: TimeInterval = 10) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Saving

enum DiagnosticReportFile {
    static func defaultFileName(for code: String) -> String {
        "SyncTray-report-\(code).txt"
    }

    /// Write `text` to `directory` (default: the user's Desktop) as owner-only (0600) and
    /// return the file URL.
    static func write(_ text: String, named fileName: String, in directory: URL? = nil) throws -> URL {
        let folder = directory
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let url = folder.appendingPathComponent(fileName)
        try writePrivately(text, toPath: url.path)
        return url
    }

    /// Write `text` to `path` so the file is owner-only (0600) from the moment it exists —
    /// a report can name personal paths and files, so it is never briefly world-readable the
    /// way an atomic write followed by a chmod is. An existing file (or symlink) at `path` is
    /// removed first, then the file is created with `O_CREAT | O_EXCL | O_NOFOLLOW`. Anything
    /// else at `path` — a directory above all — is refused with `EISDIR`/`EEXIST`, never
    /// removed: `removeItem` is recursive, so `--output ~/Documents` would delete the folder.
    static func writePrivately(_ text: String, toPath path: String) throws {
        let fileManager = FileManager.default
        // `attributesOfItem` does not follow a final symlink, so a link is replaced, not its target.
        if let type = (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType {
            guard type == .typeRegular || type == .typeSymbolicLink else {
                let code = type == .typeDirectory ? EISDIR : EEXIST
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
            }
            try fileManager.removeItem(atPath: path)
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

// MARK: - OTLP encoding

/// Turns a report into OTLP/HTTP JSON `ExportLogsServiceRequest` bodies: one leading
/// summary record, then one record per line, in batches of at most `maxRecordsPerBatch`
/// records and about `maxBatchBytes`. Every record is stamped with the report's creation time
/// plus its ordinal in nanoseconds, so a report sits together at send time and keeps its order
/// in a time-sorted view; an rclone line's own time travels as `rclone.time`. Pure — covered
/// by `ConfigSelfTest` AC-DR4.
enum DiagnosticOTLPEncoder {
    static let maxRecordsPerBatch = 200
    /// Soft byte cap per request, estimated from record bodies and attribute strings.
    static let maxBatchBytes = 1_000_000
    static let scopeName = "synctray.diagnostics"
    static let summaryBody = "Diagnostic report"

    enum Value: Equatable {
        case string(String)
        case int(Int)
        case bool(Bool)
    }

    struct Record: Equatable {
        var timeUnixNano: UInt64
        var severityNumber: Int
        var severityText: String
        var body: String
        var attributes: [String: Value]
    }

    /// The fields of an rclone `--use-json-log` line the encoder lifts into attributes.
    struct RcloneFields: Equatable {
        let level: String?
        let msg: String?
        let object: String?
        let time: String?
    }

    static func records(for report: DiagnosticReport) -> [Record] {
        let base = baseUnixNano(report.createdAt)
        var records: [Record] = [
            Record(
                timeUnixNano: base,
                severityNumber: 9,
                severityText: "INFO",
                body: summaryBody,
                attributes: [
                    "diagnostics.report_id": .string(report.code),
                    "diagnostics.profile_count": .int(report.profileCount),
                    "diagnostics.line_count": .int(report.lineCount),
                    "diagnostics.truncated": .bool(report.truncated),
                ]
            ),
        ]
        var ordinal: UInt64 = 0
        for section in report.sections {
            for (index, line) in section.lines.enumerated() {
                ordinal += 1
                var attributes: [String: Value] = [
                    "diagnostics.report_id": .string(report.code),
                    "diagnostics.source": .string(section.source.rawValue),
                    "diagnostics.line": .int(index + 1),
                ]
                if let profileId = section.profileId {
                    attributes["synctray.profile.id"] = .string(profileId.uuidString)
                }
                if let profileName = section.profileName {
                    attributes["synctray.profile.name"] = .string(profileName)
                }
                var severity = (number: 9, text: "INFO")
                if let fields = rcloneFields(line) {
                    if let level = fields.level {
                        attributes["rclone.level"] = .string(level)
                        severity = Self.severity(forRcloneLevel: level)
                    }
                    if let msg = fields.msg {
                        attributes["rclone.msg"] = .string(msg)
                    }
                    if let object = fields.object {
                        attributes["rclone.object"] = .string(object)
                    }
                    if let time = fields.time {
                        attributes["rclone.time"] = .string(time)
                    }
                }
                records.append(Record(
                    timeUnixNano: base + ordinal,
                    severityNumber: severity.number,
                    severityText: severity.text,
                    body: line,
                    attributes: attributes
                ))
            }
        }
        return records
    }

    /// Split records into request-sized batches: at most `maxRecords` records and about
    /// `maxBytes` (`estimatedSize`) each. A new batch starts when the next record would go
    /// over either limit; a single record bigger than `maxBytes` still goes, alone.
    static func batches(
        _ records: [Record],
        maxRecords: Int = DiagnosticOTLPEncoder.maxRecordsPerBatch,
        maxBytes: Int = DiagnosticOTLPEncoder.maxBatchBytes
    ) -> [[Record]] {
        var result: [[Record]] = []
        var current: [Record] = []
        var currentBytes = 0
        for record in records {
            let size = estimatedSize(record)
            if !current.isEmpty && (current.count >= maxRecords || currentBytes + size > maxBytes) {
                result.append(current)
                current = []
                currentBytes = 0
            }
            current.append(record)
            currentBytes += size
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// Rough encoded size of a record: its body plus every attribute key and string value
    /// (ints and bools count as a few bytes). Used only to keep requests near `maxBatchBytes`.
    static func estimatedSize(_ record: Record) -> Int {
        var size = record.body.utf8.count
        for (key, value) in record.attributes {
            size += key.utf8.count
            switch value {
            case .string(let text): size += text.utf8.count
            case .int: size += 20
            case .bool: size += 5
            }
        }
        return size
    }

    /// One `ExportLogsServiceRequest` as a JSON object.
    static func payload(records: [Record], resource: [String: String], observedUnixNano: UInt64) -> [String: Any] {
        let resourceAttributes: [[String: Any]] = resource.keys.sorted().map { key in
            attribute(key, .string(resource[key] ?? ""))
        }
        let logRecords: [[String: Any]] = records.map { record in
            let attributes: [[String: Any]] = record.attributes
                .sorted { $0.key < $1.key }
                .map { attribute($0.key, $0.value) }
            let encoded: [String: Any] = [
                "timeUnixNano": String(record.timeUnixNano),
                "observedTimeUnixNano": String(observedUnixNano),
                "severityNumber": record.severityNumber,
                "severityText": record.severityText,
                "body": ["stringValue": record.body],
                "attributes": attributes,
            ]
            return encoded
        }
        let scopeLogs: [String: Any] = [
            "scope": ["name": scopeName],
            "logRecords": logRecords,
        ]
        let resourceLogs: [String: Any] = [
            "resource": ["attributes": resourceAttributes],
            "scopeLogs": [scopeLogs],
        ]
        return ["resourceLogs": [resourceLogs]]
    }

    static func attribute(_ key: String, _ value: Value) -> [String: Any] {
        let encoded: [String: Any]
        switch value {
        case .string(let text): encoded = ["stringValue": text]
        case .int(let number): encoded = ["intValue": String(number)]
        case .bool(let flag): encoded = ["boolValue": flag]
        }
        return ["key": key, "value": encoded]
    }

    /// The request bodies to POST, in order.
    static func encodeBatches(for report: DiagnosticReport, resource: [String: String]) -> [Data] {
        let observed = baseUnixNano(report.createdAt)
        return batches(records(for: report)).compactMap { batch in
            try? JSONSerialization.data(
                withJSONObject: payload(records: batch, resource: resource, observedUnixNano: observed),
                options: [.sortedKeys])
        }
    }

    /// Fields of an rclone JSON log line (`{"level":…,"msg":…,"time":…}`), or nil when the
    /// line isn't one.
    static func rcloneFields(_ line: String) -> RcloneFields? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["level"] is String || object["msg"] is String else {
            return nil
        }
        return RcloneFields(
            level: object["level"] as? String,
            msg: object["msg"] as? String,
            object: object["object"] as? String,
            time: object["time"] as? String
        )
    }

    /// rclone level → OTLP severity: error/critical (and alert/emergency) → ERROR 17,
    /// warning → WARN 13, notice/info → INFO 9, debug → DEBUG 5; anything else INFO.
    static func severity(forRcloneLevel level: String) -> (number: Int, text: String) {
        switch level.lowercased() {
        case "error", "critical", "alert", "emergency": return (17, "ERROR")
        case "warning", "warn": return (13, "WARN")
        case "debug": return (5, "DEBUG")
        default: return (9, "INFO")
        }
    }

    /// The report's creation time in nanoseconds, at millisecond precision so it is exact.
    static func baseUnixNano(_ date: Date) -> UInt64 {
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        return millis > 0 ? UInt64(millis) * 1_000_000 : 0
    }
}

// MARK: - Upload

enum DiagnosticUploadError: LocalizedError, Equatable {
    case notConfigured
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Diagnostic upload isn't configured in this build. Save the report instead and send the file to the developer."
        case .httpStatus(let status):
            return "The diagnostic upload was rejected (HTTP \(status))."
        case .invalidResponse:
            return "The diagnostic upload got no valid response."
        }
    }
}

/// Sends a report to the maintainer's OTLP endpoint (the same endpoint, headers and resource
/// attributes as usage telemetry, see `TelemetryService.diagnosticExportEndpoint`). Not gated
/// on `SyncTraySettings.telemetryEnabled`: the user consents per send.
enum DiagnosticReportUploader {
    struct Configuration {
        let endpoint: URL
        let headers: [(String, String)]
        let resource: [String: String]
    }

    /// The upload target, or nil when this build has no OTLP credentials. With usage data
    /// off, the resource carries no install identity and `SyncTraySettings.installationId` is
    /// never read (reading it would create and persist an ID for someone who never opted in).
    static func configuration() -> Configuration? {
        guard TelemetryService.isDiagnosticExportConfigured,
              let url = URL(string: "\(TelemetryService.diagnosticExportEndpoint)/v1/logs") else {
            return nil
        }
        let telemetryEnabled = SyncTraySettings.telemetryEnabled
        let base = TelemetryService.diagnosticResourceAttributes(includeInstallIdentity: telemetryEnabled)
        return Configuration(
            endpoint: url,
            headers: TelemetryService.diagnosticExportHeaders,
            resource: resourceAttributes(base: base, telemetryEnabled: telemetryEnabled)
        )
    }

    /// The resource attributes a report's records carry: the telemetry resource with
    /// `synctray.process.kind` = `diagnostics` (so they're told apart from the app's and the
    /// CLI's own telemetry), and — unless usage data is on — without the stable install
    /// identity (`enduser.id`, `service.instance.id`). Pure.
    static func resourceAttributes(base: [String: String], telemetryEnabled: Bool) -> [String: String] {
        var resource = base
        resource["synctray.process.kind"] = "diagnostics"
        if !telemetryEnabled {
            resource.removeValue(forKey: "enduser.id")
            resource.removeValue(forKey: "service.instance.id")
        }
        return resource
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    /// POST the report as OTLP JSON to `<endpoint>/v1/logs`, ≤ 200 records and about 1 MB
    /// per request.
    /// Throws `DiagnosticUploadError.notConfigured` when there is no endpoint, and
    /// `.httpStatus` on a non-2xx response.
    static func send(_ report: DiagnosticReport) async throws {
        guard let config = configuration() else { throw DiagnosticUploadError.notConfigured }
        for body in DiagnosticOTLPEncoder.encodeBatches(for: report, resource: config.resource) {
            var request = URLRequest(url: config.endpoint)
            request.httpMethod = "POST"
            for (name, value) in config.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DiagnosticUploadError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw DiagnosticUploadError.httpStatus(http.statusCode)
            }
        }
    }

    /// A user-facing message for an upload error.
    static func message(for error: Error) -> String {
        if let upload = error as? DiagnosticUploadError, let description = upload.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private final class Outcome: @unchecked Sendable {
        var message: String?
    }

    /// Blocking bridge for the headless CLI: waits for `send` (bounded by `timeout`).
    /// Returns nil on success or a user-facing error message.
    static func sendBlocking(_ report: DiagnosticReport, timeout: TimeInterval = 600) -> String? {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                try await DiagnosticReportUploader.send(report)
            } catch {
                outcome.message = DiagnosticReportUploader.message(for: error)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            return "The diagnostic upload timed out."
        }
        return outcome.message
    }
}

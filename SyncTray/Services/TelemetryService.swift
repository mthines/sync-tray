import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp

/// Anonymous, opt-in telemetry service using OpenTelemetry.
///
/// All methods are no-ops unless `SyncTraySettings.telemetryEnabled` is true.
/// No personal data is collected — only bounded, low-cardinality values:
/// sync mode, sync result, profile counts, error types, and operational events.
///
/// ## Signal overview
/// - **Traces**: Sync lifecycle spans with real duration (start→complete/fail)
/// - **Metrics**: Sync duration histogram, operation counters, profile gauge (delta temporality, 30s export)
/// - **Logs**: Structured log records for key lifecycle events (sync, mount, errors)
///
/// ## User correlation
/// - `service.instance.id` — random UUID per install (changes on reinstall)
/// - `enduser.id` — HMAC-SHA256 of hardware UUID (stable across reinstalls, not reversible)
///
/// Both are resource attributes, so every signal (trace, metric, log) is automatically
/// correlated to the same physical machine.
///
/// ## Swift SDK note
/// opentelemetry-swift 1.17.1 requires a wildcard `registerView(name: ".*")` for the
/// stable metrics API. Without it, instruments silently record to no-op storage.
/// See: https://github.com/open-telemetry/opentelemetry-swift/issues/500
final class TelemetryService {
    static let shared = TelemetryService()

    // MARK: - Configuration
    //
    // Lookup priority (first non-empty wins):
    //   1. Process environment variables (shell, Xcode scheme, CI)
    //   2. ~/.config/synctray/.env file (development convenience)
    //   3. Info.plist values embedded at build time (release distribution)

    private static let config: [String: String] = {
        var env: [String: String] = [:]
        // 3. Info.plist (lowest priority — embedded at build time)
        if let token = Bundle.main.object(forInfoDictionaryKey: "Dash0AuthToken") as? String,
           !token.isEmpty {
            env["DASH0_AUTH_TOKEN"] = token
        }
        if let endpoint = Bundle.main.object(forInfoDictionaryKey: "OTelExporterEndpoint") as? String,
           !endpoint.isEmpty {
            env["OTEL_EXPORTER_OTLP_ENDPOINT"] = endpoint
        }
        // 2. .env file overrides Info.plist
        for (key, value) in loadDotEnv() {
            env[key] = value
        }
        // 1. Process environment overrides everything
        for (key, value) in ProcessInfo.processInfo.environment {
            env[key] = value
        }
        return env
    }()

    private static let endpoint: String = {
        config["OTEL_EXPORTER_OTLP_ENDPOINT"]
            ?? "https://ingress.europe-west4.gcp.dash0-dev.com"
    }()

    private static let serviceName: String = {
        config["OTEL_SERVICE_NAME"] ?? "synctray"
    }()

    /// Auth header resolution:
    ///   1. `OTEL_EXPORTER_OTLP_HEADERS` env var (standard OTel, comma-separated Key=Value)
    ///   2. `DASH0_AUTH_TOKEN` env var or .env file or Info.plist (convenience)
    private static let authHeaders: [(String, String)] = {
        if let raw = config["OTEL_EXPORTER_OTLP_HEADERS"], !raw.isEmpty {
            return raw.split(separator: ",").compactMap { pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]).trimmingCharacters(in: .whitespaces),
                        String(parts[1]).trimmingCharacters(in: .whitespaces))
            }
        }
        if let token = config["DASH0_AUTH_TOKEN"],
           !token.isEmpty, token != "YOUR_AUTH_TOKEN" {
            return [("Authorization", "Bearer \(token)")]
        }
        return []
    }()

    // MARK: - Metric Instruments

    private var syncDurationHistogram: DoubleHistogramMeterSdk?
    private var syncCompletedCounter: LongCounterSdk?
    private var syncFilesChangedCounter: LongCounterSdk?
    private var activeProfilesGauge: LongUpDownCounterSdk?
    private var appLaunchCounter: LongCounterSdk?
    private var syncErrorCounter: LongCounterSdk?
    private var mountOperationCounter: LongCounterSdk?
    private var directoryWatchTriggerCounter: LongCounterSdk?
    private var transportFallbackCounter: LongCounterSdk?
    private var fileOperationCounter: LongCounterSdk?
    private var remoteConfigCounter: LongCounterSdk?
    private var syncContentionCounter: LongCounterSdk?
    private var logWatcherRecoveryCounter: LongCounterSdk?
    private var staleLockCleanupCounter: LongCounterSdk?
    private var syncCheckPhaseHistogram: DoubleHistogramMeterSdk?
    private var volumeEventCounter: LongCounterSdk?
    private var directoryWatchFilterCounter: LongCounterSdk?
    private var resumedExternalSyncCounter: LongCounterSdk?
    private var settingsOpenedCounter: LongCounterSdk?
    private var autoFixTriggeredCounter: LongCounterSdk?
    private var offlinePinOperationsCounter: LongCounterSdk?
    private var wizardStepCounter: LongCounterSdk?
    private var oauthOutcomeCounter: LongCounterSdk?
    private var userRecoveryActionCounter: LongCounterSdk?
    private var settingChangedCounter: LongCounterSdk?
    private var offlineExtensionSetupCounter: LongCounterSdk?
    private var offlineCacheClearCounter: LongCounterSdk?

    // MARK: - Providers (kept alive for shutdown)

    private var meterProvider: StableMeterProviderSdk?
    private var tracerProvider: TracerProviderSdk?
    private var loggerProvider: LoggerProviderSdk?

    // MARK: - Tracer & Logger

    private var tracer: (any Tracer)?
    private var logger: (any OpenTelemetryApi.Logger)?

    // MARK: - Active Spans (keyed by profile UUID for real duration tracking)

    private var activeSyncSpans: [UUID: any Span] = [:]

    // MARK: - State

    private var lastReportedProfileCount: Int = 0

    // MARK: - Init

    private init() {}

    // MARK: - Setup

    /// Call once at app startup. Configures the OTel SDK if telemetry is enabled.
    func configure() {
        guard SyncTraySettings.telemetryEnabled else { return }
        setupOTel()
    }

    private func setupOTel() {
        // Skip if already configured or no auth headers
        guard meterProvider == nil else { return }
        guard !Self.authHeaders.isEmpty else { return }

        let resource = buildResource()

        // MARK: Metrics — stable API

        let metricsEndpoint = URL(string: "\(Self.endpoint)/v1/metrics")!
        let metricsExporter = StableOtlpHTTPMetricExporter(
            endpoint: metricsEndpoint,
            aggregationTemporalitySelector: AggregationTemporality.deltaPreferred(),
            envVarHeaders: Self.authHeaders
        )

        let metricReader = StablePeriodicMetricReaderBuilder(exporter: metricsExporter)
            .setInterval(timeInterval: 30)
            .build()

        let stableMeterProvider = StableMeterProviderSdk.builder()
            .setResource(resource: resource)
            .registerView(
                selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
                view: StableView.builder().build()
            )
            .registerMetricReader(reader: metricReader)
            .build()

        meterProvider = stableMeterProvider
        OpenTelemetry.registerStableMeterProvider(meterProvider: stableMeterProvider)
        print("[SyncTray][Telemetry] metrics exporter configured → \(metricsEndpoint) (temporality: delta, interval: 30s)")

        // MARK: Traces

        let tracesEndpoint = URL(string: "\(Self.endpoint)/v1/traces")!
        let tracesExporter = OtlpHttpTraceExporter(
            endpoint: tracesEndpoint,
            envVarHeaders: Self.authHeaders
        )

        let spanProcessor = BatchSpanProcessor(spanExporter: tracesExporter)

        let tracerProviderSdk = TracerProviderBuilder()
            .with(resource: resource)
            .add(spanProcessor: spanProcessor)
            .build()

        tracerProvider = tracerProviderSdk
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProviderSdk)
        tracer = tracerProviderSdk.get(instrumentationName: Self.serviceName)

        // MARK: Logs

        let logsEndpoint = URL(string: "\(Self.endpoint)/v1/logs")!
        let logsExporter = OtlpHttpLogExporter(
            endpoint: logsEndpoint,
            envVarHeaders: Self.authHeaders
        )

        let logProcessor = BatchLogRecordProcessor(logRecordExporter: logsExporter)

        let loggerProviderSdk = LoggerProviderBuilder()
            .with(resource: resource)
            .with(processors: [logProcessor])
            .build()

        loggerProvider = loggerProviderSdk
        OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProviderSdk)
        logger = loggerProviderSdk
            .loggerBuilder(instrumentationScopeName: Self.serviceName)
            .build()

        // MARK: Build metric instruments from the stable meter

        let meter = stableMeterProvider.get(name: Self.serviceName)

        syncDurationHistogram = meter
            .histogramBuilder(name: "synctray.sync.duration")
            .setDescription("Duration of sync operations in seconds")
            .setUnit("s")
            .build()

        syncCompletedCounter = meter
            .counterBuilder(name: "synctray.sync.completed")
            .setDescription("Number of sync operations completed")
            .setUnit("1")
            .build()

        syncFilesChangedCounter = meter
            .counterBuilder(name: "synctray.sync.files_changed")
            .setDescription("Number of files changed during sync")
            .setUnit("1")
            .build()

        activeProfilesGauge = meter
            .upDownCounterBuilder(name: "synctray.app.profiles.active")
            .setDescription("Number of active sync profiles")
            .setUnit("1")
            .build()

        appLaunchCounter = meter
            .counterBuilder(name: "synctray.app.launch")
            .setDescription("Number of app launches")
            .setUnit("1")
            .build()

        syncErrorCounter = meter
            .counterBuilder(name: "synctray.sync.errors")
            .setDescription("Number of sync errors by type")
            .setUnit("1")
            .build()

        mountOperationCounter = meter
            .counterBuilder(name: "synctray.mount.operations")
            .setDescription("Number of mount/unmount operations")
            .setUnit("1")
            .build()

        directoryWatchTriggerCounter = meter
            .counterBuilder(name: "synctray.directory_watch.triggers")
            .setDescription("Number of directory change detections that triggered syncs")
            .setUnit("1")
            .build()

        transportFallbackCounter = meter
            .counterBuilder(name: "synctray.transport.fallback_activations")
            .setDescription("Number of times fallback remote was activated")
            .setUnit("1")
            .build()

        fileOperationCounter = meter
            .counterBuilder(name: "synctray.sync.file_operations")
            .setDescription("Number of file operations by type and extension")
            .setUnit("1")
            .build()

        remoteConfigCounter = meter
            .counterBuilder(name: "synctray.remote.config_operations")
            .setDescription("Number of remote configuration operations by type and result")
            .setUnit("1")
            .build()

        syncContentionCounter = meter
            .counterBuilder(name: "synctray.sync.contention")
            .setDescription("Number of times a sync was skipped because another was already running")
            .setUnit("1")
            .build()

        logWatcherRecoveryCounter = meter
            .counterBuilder(name: "synctray.logwatcher.recovery")
            .setDescription("Number of LogWatcher recovery events (file reopen, missed bytes, polling fallback)")
            .setUnit("1")
            .build()

        staleLockCleanupCounter = meter
            .counterBuilder(name: "synctray.startup.stale_locks_cleaned")
            .setDescription("Number of stale lock files cleaned on startup")
            .setUnit("1")
            .build()

        syncCheckPhaseHistogram = meter
            .histogramBuilder(name: "synctray.sync.check_phase_duration")
            .setDescription("Duration of the bisync listing/check phase in seconds")
            .setUnit("s")
            .build()

        volumeEventCounter = meter
            .counterBuilder(name: "synctray.drive.events")
            .setDescription("Number of external drive mount/unmount events")
            .setUnit("1")
            .build()

        directoryWatchFilterCounter = meter
            .counterBuilder(name: "synctray.directory_watch.filtered")
            .setDescription("Number of directory watch events filtered out (phantom, metadata, out-of-scope)")
            .setUnit("1")
            .build()

        resumedExternalSyncCounter = meter
            .counterBuilder(name: "synctray.sync.resumed_external")
            .setDescription("Number of externally-started syncs detected and resumed at app startup")
            .setUnit("1")
            .build()

        settingsOpenedCounter = meter
            .counterBuilder(name: "synctray.app.settings_opened")
            .setDescription("Number of times the Settings window was opened")
            .setUnit("1")
            .build()

        autoFixTriggeredCounter = meter
            .counterBuilder(name: "synctray.sync.auto_fix_triggered")
            .setDescription("Number of automatic --resync recoveries triggered (by result: triggered, gave_up_backoff)")
            .setUnit("1")
            .build()

        offlinePinOperationsCounter = meter
            .counterBuilder(name: "synctray.offline.pin_operations")
            .setDescription("Number of offline pin/unpin operations by action (pin or unpin)")
            .setUnit("1")
            .build()

        wizardStepCounter = meter
            .counterBuilder(name: "synctray.wizard.step")
            .setDescription("Setup wizard funnel events by outcome (started, provider_selected, remote_ready, folder_chosen, created, abandoned)")
            .setUnit("1")
            .build()

        oauthOutcomeCounter = meter
            .counterBuilder(name: "synctray.remote.oauth")
            .setDescription("OAuth authentication outcomes by result (success, failure, cancelled) and provider type")
            .setUnit("1")
            .build()

        userRecoveryActionCounter = meter
            .counterBuilder(name: "synctray.recovery.user_action")
            .setDescription("User-initiated sync recovery actions by type (force_sync, resync, retry)")
            .setUnit("1")
            .build()

        settingChangedCounter = meter
            .counterBuilder(name: "synctray.setting.changed")
            .setDescription("App-wide preference changes by setting name and enabled state")
            .setUnit("1")
            .build()

        offlineExtensionSetupCounter = meter
            .counterBuilder(name: "synctray.offline.extension_setup")
            .setDescription("Finder extension enable-funnel actions (prompt_shown, open_settings, rechecked, enabled)")
            .setUnit("1")
            .build()

        offlineCacheClearCounter = meter
            .counterBuilder(name: "synctray.offline.cache_clear")
            .setDescription("Cache clear operations by whether pinned folders were preserved")
            .setUnit("1")
            .build()
    }

    // MARK: - Ensure Setup

    private func ensureSetup() {
        guard SyncTraySettings.telemetryEnabled else { return }
        if tracer == nil { setupOTel() }
    }

    // MARK: - Profile Attributes Helper

    /// Build low-cardinality attributes for a profile. Never includes paths or personal data.
    private func profileAttributes(
        profileId: UUID,
        profileName: String,
        syncMode: SyncMode,
        syncDirection: SyncDirection? = nil,
        hasFallback: Bool = false
    ) -> [String: AttributeValue] {
        var attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "sync.mode": .string(syncMode.rawValue),
            "sync.has_fallback": .bool(hasFallback),
        ]
        if let direction = syncDirection, syncMode == .sync {
            attrs["sync.direction"] = .string(direction.rawValue)
        }
        return attrs
    }

    // MARK: - Sync Lifecycle (Traces with Real Duration)

    /// Called when a sync operation starts. Creates a span that lives until syncEnded is called.
    func recordSyncStarted(
        profileId: UUID,
        profileName: String,
        syncMode: SyncMode,
        syncDirection: SyncDirection? = nil,
        hasFallback: Bool = false,
        trigger: String = "scheduled"  // manual | directory_watch | scheduled | startup
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        guard let tracer = tracer else { return }

        // End any stale span for this profile (shouldn't happen, but defensive)
        if let stale = activeSyncSpans.removeValue(forKey: profileId) {
            stale.setAttribute(key: "sync.result", value: .string("abandoned"))
            stale.status = .error(description: "Span replaced by new sync start")
            stale.end()
        }

        var attrs = profileAttributes(
            profileId: profileId,
            profileName: profileName,
            syncMode: syncMode,
            syncDirection: syncDirection,
            hasFallback: hasFallback
        )
        // What kicked off this sync: an app-initiated run sets the trigger; a bare
        // launchd/scheduled run leaves it at the default.
        attrs["sync.trigger"] = .string(trigger)

        let span = tracer.spanBuilder(spanName: "synctray sync")
            .setSpanKind(spanKind: .internal)
            .startSpan()

        for (key, value) in attrs {
            span.setAttribute(key: key, value: value)
        }

        activeSyncSpans[profileId] = span

        emitLog(
            severity: .info,
            body: "Sync started",
            attributes: attrs,
            spanContext: span.context
        )
    }

    /// Called when a sync operation completes successfully.
    func recordSyncCompleted(
        profileId: UUID,
        profileName: String,
        mode: SyncMode,
        duration: TimeInterval,
        filesChanged: Int
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let labels: [String: AttributeValue] = [
            "sync.mode": .string(mode.rawValue),
            "sync.result": .string("success"),
            "synctray.profile.name": .string(profileName),
        ]

        syncDurationHistogram?.record(value: duration, attributes: labels)
        syncCompletedCounter?.add(value: 1, attribute: labels)

        if filesChanged > 0 {
            syncFilesChangedCounter?.add(
                value: filesChanged,
                attribute: [
                    "sync.mode": .string(mode.rawValue),
                    "synctray.profile.name": .string(profileName),
                ]
            )
        }

        // End the active span with success
        if let span = activeSyncSpans.removeValue(forKey: profileId) {
            span.setAttribute(key: "sync.result", value: .string("success"))
            span.setAttribute(key: "sync.files_changed", value: .int(filesChanged))
            span.setAttribute(key: "sync.duration_s", value: .double(duration))
            span.status = .ok
            span.end()

            emitLog(
                severity: .info,
                body: "Sync completed",
                attributes: [
                    "synctray.profile.id": .string(profileId.uuidString),
                    "synctray.profile.name": .string(profileName),
                    "sync.mode": .string(mode.rawValue),
                    "sync.result": .string("success"),
                    "sync.files_changed": .int(filesChanged),
                    "sync.duration_s": .double(duration),
                ],
                spanContext: span.context
            )
        }
    }

    /// Called when a sync operation fails.
    func recordSyncFailed(
        profileId: UUID,
        profileName: String,
        mode: SyncMode,
        duration: TimeInterval,
        filesChanged: Int,
        exitCode: Int,
        errorMessage: String?
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let labels: [String: AttributeValue] = [
            "sync.mode": .string(mode.rawValue),
            "sync.result": .string("failure"),
            "synctray.profile.name": .string(profileName),
        ]

        syncDurationHistogram?.record(value: duration, attributes: labels)
        syncCompletedCounter?.add(value: 1, attribute: labels)

        if filesChanged > 0 {
            syncFilesChangedCounter?.add(
                value: filesChanged,
                attribute: [
                    "sync.mode": .string(mode.rawValue),
                    "synctray.profile.name": .string(profileName),
                ]
            )
        }

        // Categorize error for the error counter
        let errorType = categorizeError(errorMessage)
        syncErrorCounter?.add(value: 1, attribute: [
            "sync.mode": .string(mode.rawValue),
            "synctray.profile.name": .string(profileName),
            "error.type": .string(errorType),
        ])

        // End the active span with error
        if let span = activeSyncSpans.removeValue(forKey: profileId) {
            span.setAttribute(key: "sync.result", value: .string("failure"))
            span.setAttribute(key: "sync.files_changed", value: .int(filesChanged))
            span.setAttribute(key: "sync.duration_s", value: .double(duration))
            span.setAttribute(key: "sync.exit_code", value: .int(exitCode))
            span.setAttribute(key: "error.type", value: .string(errorType))
            span.status = .error(description: errorMessage ?? "Exit code \(exitCode)")
            span.end()

            emitLog(
                severity: .error,
                body: "Sync failed",
                attributes: [
                    "synctray.profile.id": .string(profileId.uuidString),
                    "synctray.profile.name": .string(profileName),
                    "sync.mode": .string(mode.rawValue),
                    "sync.result": .string("failure"),
                    "sync.exit_code": .int(exitCode),
                    "sync.duration_s": .double(duration),
                    "error.type": .string(errorType),
                    "error.message": .string(errorMessage ?? "Exit code \(exitCode)"),
                ],
                spanContext: span.context
            )
        }
    }

    /// Called when a scheduled sync exited early WITHOUT running — e.g. the
    /// remote failed the pre-flight reachability check, or the profile was
    /// paused mid-flight. Ends the active span with result "skipped" so it does
    /// not linger open and later get reported as "abandoned"/"app_shutdown"
    /// (which is exactly what produced the 11–37 min phantom "syncing" spans).
    func recordSyncSkipped(profileId: UUID, profileName: String, reason: String) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        if let span = activeSyncSpans.removeValue(forKey: profileId) {
            span.setAttribute(key: "sync.result", value: .string("skipped"))
            span.setAttribute(key: "sync.skip_reason", value: .string(reason))
            span.status = .ok
            span.end()

            emitLog(
                severity: .info,
                body: "Sync skipped",
                attributes: [
                    "synctray.profile.id": .string(profileId.uuidString),
                    "synctray.profile.name": .string(profileName),
                    "sync.result": .string("skipped"),
                    "sync.skip_reason": .string(reason),
                ],
                spanContext: span.context
            )
        }
    }

    // MARK: - Mount Operations

    /// Record a mount or unmount operation.
    func recordMountOperation(
        profileId: UUID,
        profileName: String,
        operation: String,  // "mount" or "unmount"
        result: String      // "success" or "failure"
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        mountOperationCounter?.add(value: 1, attribute: [
            "mount.operation": .string(operation),
            "mount.result": .string(result),
            "synctray.profile.name": .string(profileName),
        ])

        guard let tracer = tracer else { return }

        let span = tracer.spanBuilder(spanName: "synctray \(operation)")
            .setSpanKind(spanKind: .internal)
            .startSpan()
        span.setAttribute(key: "synctray.profile.id", value: .string(profileId.uuidString))
        span.setAttribute(key: "synctray.profile.name", value: .string(profileName))
        span.setAttribute(key: "mount.operation", value: .string(operation))
        span.setAttribute(key: "mount.result", value: .string(result))
        span.status = result == "success" ? .ok : .error(description: "\(operation) failed")
        span.end()

        emitLog(
            severity: result == "success" ? .info : .error,
            body: "\(operation.capitalized) \(result)",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "mount.operation": .string(operation),
                "mount.result": .string(result),
            ],
            spanContext: span.context
        )
    }

    // MARK: - Directory Watch Triggers

    /// Record when a directory change detection triggers a sync.
    func recordDirectoryWatchTrigger(
        profileId: UUID,
        profileName: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        directoryWatchTriggerCounter?.add(value: 1, attribute: [
            "synctray.profile.name": .string(profileName),
        ])

        emitLog(
            severity: .info,
            body: "Directory change detected",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
            ]
        )
    }

    // MARK: - Transport Changes

    /// Record when transport switches between primary and fallback.
    func recordTransportChange(
        profileId: UUID,
        profileName: String,
        transport: String           // "primary" or "fallback"
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        if transport == "fallback" {
            transportFallbackCounter?.add(value: 1, attribute: [
                "synctray.profile.name": .string(profileName),
            ])
        }

        emitLog(
            severity: transport == "fallback" ? .warn : .info,
            body: "Transport changed to \(transport)",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "sync.transport": .string(transport),
            ]
        )
    }

    // MARK: - Sync Errors (logged outside of sync lifecycle)

    /// Record a sync error detected in logs (for real-time error visibility).
    func recordSyncError(
        profileId: UUID,
        profileName: String,
        errorMessage: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let errorType = categorizeError(errorMessage)

        // Emit a log correlated to the active sync span if one exists
        let spanContext = activeSyncSpans[profileId]?.context

        emitLog(
            severity: .error,
            body: "Sync error",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "error.type": .string(errorType),
                "error.message": .string(String(errorMessage.prefix(256))),
            ],
            spanContext: spanContext
        )
    }

    // MARK: - Drive State

    /// Record when an external drive is not mounted.
    func recordDriveNotMounted(
        profileId: UUID,
        profileName: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        emitLog(
            severity: .warn,
            body: "External drive not mounted",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
            ]
        )
    }

    // MARK: - Profile Operations

    /// Record profile pause/resume.
    func recordProfileStateChange(
        profileId: UUID,
        profileName: String,
        action: String  // "paused", "resumed", "enabled", "disabled"
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        emitLog(
            severity: .info,
            body: "Profile \(action)",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "synctray.profile.action": .string(action),
            ]
        )
    }

    // MARK: - File Operations

    /// Record a file operation during sync (copy, delete, update, rename).
    /// Uses only low-cardinality attributes: operation type and normalized file extension.
    func recordFileOperation(
        profileName: String,
        operation: String,  // "copied", "deleted", "updated", "renamed", "unknown"
        filePath: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let ext = normalizeFileExtension(filePath)

        fileOperationCounter?.add(value: 1, attribute: [
            "file.operation": .string(operation.lowercased()),
            "file.extension": .string(ext),
            "synctray.profile.name": .string(profileName),
        ])
    }

    // MARK: - Profile Configuration Snapshot (RUM)

    /// Emit a snapshot of the user's profile configuration choices.
    /// Called on app launch and when profiles are saved/updated.
    /// Captures only feature preferences — never paths, remote names, or credentials.
    func recordProfileConfiguration(_ profile: SyncProfile) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let intervalBucket = bucketSyncInterval(profile.syncIntervalMinutes)

        emitLog(
            severity: .info,
            body: "Profile configuration",
            attributes: [
                "synctray.profile.id": .string(profile.id.uuidString),
                "synctray.profile.name": .string(profile.name),
                "config.sync_mode": .string(profile.syncMode.rawValue),
                "config.sync_direction": .string(profile.syncDirection.rawValue),
                "config.sync_interval_bucket": .string(intervalBucket),
                "config.has_fallback": .bool(profile.hasFallback),
                "config.has_external_drive": .bool(!profile.drivePathToMonitor.isEmpty),
                "config.is_enabled": .bool(profile.isEnabled),
                "config.is_muted": .bool(profile.isMuted),
                "config.has_additional_flags": .bool(!profile.additionalRcloneFlags.isEmpty),
                // Mount-specific preferences
                "config.mount_backend": .string(profile.isMountMode ? profile.mountBackend.rawValue : "n/a"),
                "config.mount_at_startup": .string(profile.isMountMode ? String(profile.mountAtStartup) : "n/a"),
                "config.vfs_cache_mode": .string(profile.isMountMode ? profile.vfsCacheMode.rawValue : "n/a"),
                "config.has_pinned_directories": .bool(!profile.pinnedDirectories.isEmpty),
                "config.pinned_directory_count": .int(profile.pinnedDirectories.count),
                "config.allow_non_empty_mount": .bool(profile.allowNonEmptyMount),
            ]
        )
    }

    /// Emit a full snapshot of all profile configurations. Call on app launch.
    func recordAllProfileConfigurations(_ profiles: [SyncProfile]) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        // Summary log: how many profiles of each type
        let modeBreakdown = Dictionary(grouping: profiles, by: { $0.syncMode.rawValue })
            .mapValues { $0.count }
        let enabledCount = profiles.filter { $0.isEnabled }.count
        let fallbackCount = profiles.filter { $0.hasFallback }.count
        let externalDriveCount = profiles.filter { !$0.drivePathToMonitor.isEmpty }.count

        emitLog(
            severity: .info,
            body: "Configuration snapshot",
            attributes: [
                "config.total_profiles": .int(profiles.count),
                "config.enabled_profiles": .int(enabledCount),
                "config.bisync_profiles": .int(modeBreakdown["bisync"] ?? 0),
                "config.sync_profiles": .int(modeBreakdown["sync"] ?? 0),
                "config.mount_profiles": .int(modeBreakdown["mount"] ?? 0),
                "config.fallback_configured_count": .int(fallbackCount),
                "config.external_drive_count": .int(externalDriveCount),
            ]
        )

        // Individual profile configs
        for profile in profiles {
            recordProfileConfiguration(profile)
        }
    }

    // MARK: - Profile Lifecycle Operations

    /// Record a profile lifecycle operation (install, reinstall, uninstall, sync_now, resync, force_sync).
    /// Captures the operation type, sync mode, and result for debugging setup issues.
    func recordProfileLifecycleOperation(
        profileId: UUID,
        profileName: String,
        operation: String,          // "install", "reinstall", "uninstall", "sync_now", "resync", "force_sync"
        syncMode: String,           // bisync, sync, mount
        result: String,             // "success", "failure", "started"
        errorMessage: String? = nil
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        var logAttrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "profile.operation": .string(operation),
            "sync.mode": .string(syncMode),
            "profile.operation.result": .string(result),
        ]
        if let errMsg = errorMessage {
            let errorType = categorizeError(errMsg)
            logAttrs["error.type"] = .string(errorType)
            logAttrs["error.message"] = .string(String(errMsg.prefix(256)))
        }

        emitLog(
            severity: result == "failure" ? .error : .info,
            body: "Profile \(operation) \(result)",
            attributes: logAttrs
        )
    }

    // MARK: - Remote Configuration

    /// Record a remote configuration operation (create, update, delete, connection_test).
    /// Emits a counter tick and a structured log with outcome details.
    /// Never includes URLs, passwords, or hostnames — only provider type and error category.
    func recordRemoteConfigOperation(
        operation: String,          // "create", "update", "delete", "connection_test"
        providerType: String,       // rclone type: "sftp", "webdav", "smb", etc.
        result: String,             // "success" or "failure"
        errorMessage: String? = nil
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let errorType = errorMessage.map { categorizeRemoteError($0) } ?? ""

        var metricAttrs: [String: AttributeValue] = [
            "remote.operation": .string(operation),
            "remote.provider_type": .string(providerType),
            "remote.result": .string(result),
        ]
        if !errorType.isEmpty {
            metricAttrs["error.type"] = .string(errorType)
        }

        remoteConfigCounter?.add(value: 1, attribute: metricAttrs)

        var logAttrs: [String: AttributeValue] = [
            "remote.operation": .string(operation),
            "remote.provider_type": .string(providerType),
            "remote.result": .string(result),
        ]
        if let errMsg = errorMessage {
            logAttrs["error.type"] = .string(errorType)
            logAttrs["error.message"] = .string(String(errMsg.prefix(256)))
        }

        emitLog(
            severity: result == "success" ? .info : .warn,
            body: "Remote \(operation) \(result)",
            attributes: logAttrs
        )
    }

    /// Categorize remote config errors into low-cardinality types.
    private func categorizeRemoteError(_ message: String) -> String {
        let msg = message.lowercased()
        if msg.contains("xml syntax") || msg.contains("html") {
            return "invalid_endpoint"
        }
        if msg.contains("base64") || msg.contains("obscure") || msg.contains("decrypt") {
            return "password_encoding"
        }
        if msg.contains("connection refused") || msg.contains("dial tcp") {
            return "connection_refused"
        }
        if msg.contains("timeout") || msg.contains("timed out") || msg.contains("deadline") {
            return "timeout"
        }
        if msg.contains("401") || msg.contains("403") || msg.contains("auth") || msg.contains("permission") {
            return "authentication"
        }
        if msg.contains("404") || msg.contains("not found") {
            return "not_found"
        }
        if msg.contains("certificate") || msg.contains("tls") || msg.contains("ssl") {
            return "tls_error"
        }
        if msg.contains("dns") || msg.contains("no such host") || msg.contains("resolve") {
            return "dns_error"
        }
        if msg.contains("already exists") {
            return "duplicate"
        }
        return "other"
    }

    // MARK: - Sync Contention

    /// Record when a sync is skipped because another is already running (lock file contention).
    /// High rates indicate the sync interval is too short for the data volume.
    func recordSyncContention(
        profileId: UUID,
        profileName: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        syncContentionCounter?.add(value: 1, attribute: [
            "synctray.profile.name": .string(profileName),
        ])

        emitLog(
            severity: .info,
            body: "Sync skipped - already running",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
            ]
        )
    }

    // MARK: - Auto-Fix

    /// Record an automatic --resync recovery attempt.
    /// - Parameters:
    ///   - profileId:   UUID of the affected profile.
    ///   - profileName: Display name of the affected profile.
    ///   - result:      `"triggered"` when the resync starts; `"gave_up_backoff"` when
    ///                  backoff suppresses the retry after repeated triggers;
    ///                  `"skipped_drive_not_mounted"` when the external drive is absent.
    func recordAutoFixTriggered(
        profileId: UUID,
        profileName: String,
        result: String     // "triggered" | "gave_up_backoff" | "skipped_drive_not_mounted"
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        autoFixTriggeredCounter?.add(value: 1, attribute: [
            "synctray.profile.name": .string(profileName),
            "result": .string(result),
        ])

        let severity: Severity = result == "gave_up_backoff" ? .warn : .info
        let body: String
        switch result {
        case "gave_up_backoff":
            body = "Auto-fix suppressed by backoff for \(profileName)"
        case "skipped_drive_not_mounted":
            body = "Auto-fix skipped: external drive not mounted for \(profileName)"
        default:
            body = "Auto-resyncing \(profileName) after sync conflict"
        }
        emitLog(
            severity: severity,
            body: body,
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "result": .string(result),
            ]
        )
    }

    // MARK: - Offline Pin Operations

    /// Record an offline pin or unpin operation triggered from Finder or the in-app UI.
    /// - Parameters:
    ///   - profileId:   UUID of the profile whose pinnedDirectories list was updated.
    ///   - profileName: Display name of the affected profile.
    ///   - action:      `"pin"` when a directory is pinned; `"unpin"` when unpinned.
    ///   - pathCount:   Number of directory paths included in this operation.
    func recordOfflinePinOperation(
        profileId: UUID,
        profileName: String,
        action: String,    // "pin" | "unpin"
        pathCount: Int
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        offlinePinOperationsCounter?.add(value: 1, attribute: [
            "synctray.profile.name": .string(profileName),
            "action": .string(action),
        ])

        emitLog(
            severity: .info,
            body: "Offline pin operation",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "offline.action": .string(action),
                "offline.path_count": .int(pathCount),
            ]
        )
    }

    // MARK: - Onboarding Wizard Funnel

    /// Record a step in the setup-wizard funnel so drop-off between provider selection,
    /// remote creation, folder choice, and profile creation is measurable. All values are
    /// bounded enums — no paths, remote names, or free text.
    func recordWizardStep(
        outcome: String,               // started | provider_selected | remote_ready | folder_chosen | created | abandoned
        providerType: String? = nil,   // bounded provider rcloneType (e.g. "drive", "s3"); nil when not yet chosen
        abandonedAtStep: String? = nil // bounded step id when outcome == "abandoned"
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        var counterAttrs: [String: AttributeValue] = ["wizard.outcome": .string(outcome)]
        if let providerType { counterAttrs["provider.type"] = .string(providerType) }
        if let abandonedAtStep { counterAttrs["wizard.abandoned_at_step"] = .string(abandonedAtStep) }

        wizardStepCounter?.add(value: 1, attribute: counterAttrs)
        emitLog(severity: .info, body: "Wizard step", attributes: counterAttrs)
    }

    // MARK: - OAuth Outcome

    /// Record the result of an OAuth authentication attempt during remote setup — a common
    /// onboarding wall. `result` and `providerType` are bounded.
    func recordOAuthOutcome(
        result: String,       // success | failure | cancelled
        providerType: String  // bounded provider rcloneType
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let attrs: [String: AttributeValue] = [
            "result": .string(result),
            "provider.type": .string(providerType),
        ]
        oauthOutcomeCounter?.add(value: 1, attribute: attrs)
        emitLog(severity: result == "failure" ? .warn : .info, body: "OAuth outcome", attributes: attrs)
    }

    // MARK: - User-Initiated Recovery

    /// Record a user-initiated sync recovery action (distinct from the automatic --resync).
    /// Signals how often users hit errors bad enough to intervene, and which action they pick.
    func recordUserRecoveryAction(
        profileId: UUID,
        profileName: String,
        action: String   // force_sync | resync | retry
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        userRecoveryActionCounter?.add(value: 1, attribute: [
            "synctray.profile.name": .string(profileName),
            "recovery.action": .string(action),
        ])

        emitLog(
            severity: .info,
            body: "User recovery action",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "recovery.action": .string(action),
            ]
        )
    }

    // MARK: - Setting Changed

    /// Record a change to an app-wide preference (e.g. auto-fix, launch-at-login, debug logging,
    /// telemetry opt-out). `name` is a bounded setting id; capturing the telemetry opt-out here
    /// is the only way to see it, since no telemetry is emitted after it's disabled.
    func recordSettingChanged(
        name: String,     // bounded: auto_fix | launch_at_login | debug_logging | telemetry
        enabled: Bool
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let attrs: [String: AttributeValue] = [
            "setting.name": .string(name),
            "setting.enabled": .bool(enabled),
        ]
        settingChangedCounter?.add(value: 1, attribute: attrs)
        emitLog(severity: .info, body: "Setting changed", attributes: attrs)
    }

    // MARK: - Offline Extension Setup Funnel

    /// Record a step in the Finder-extension enable funnel — the one manual step a fresh
    /// install requires. `action` is a bounded enum.
    func recordOfflineExtensionSetup(
        action: String   // prompt_shown | open_settings | rechecked | enabled
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let attrs: [String: AttributeValue] = ["offline.extension_action": .string(action)]
        offlineExtensionSetupCounter?.add(value: 1, attribute: attrs)
        emitLog(severity: .info, body: "Offline extension setup", attributes: attrs)
    }

    // MARK: - Offline Cache Clear

    /// Record a cache-clear operation, capturing whether the user preserved pinned folders
    /// (the default) or cleared everything — shows whether the preserve-pinned choice is used.
    func recordOfflineCacheClear(
        profileId: UUID,
        profileName: String,
        preservePinned: Bool
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        offlineCacheClearCounter?.add(value: 1, attribute: [
            "synctray.profile.name": .string(profileName),
            "offline.preserve_pinned": .bool(preservePinned),
        ])

        emitLog(
            severity: .info,
            body: "Offline cache clear",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "offline.preserve_pinned": .bool(preservePinned),
            ]
        )
    }

    // MARK: - LogWatcher Recovery

    /// Record LogWatcher recovery events (file reopen, missed bytes, polling fallback).
    /// Frequent recoveries may indicate file system reliability issues.
    func recordLogWatcherRecovery(
        reason: String,     // "file_replaced", "missed_bytes", "polling_error"
        profileName: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        logWatcherRecoveryCounter?.add(value: 1, attribute: [
            "logwatcher.recovery_reason": .string(reason),
        ])

        emitLog(
            severity: .warn,
            body: "LogWatcher recovery: \(reason)",
            attributes: [
                "synctray.profile.name": .string(profileName),
                "logwatcher.recovery_reason": .string(reason),
            ]
        )
    }

    // MARK: - Stale Lock Cleanup

    /// Record stale lock files cleaned during startup.
    /// High counts indicate frequent ungraceful shutdowns or sync interruptions.
    func recordStaleLockCleanup(
        count: Int,
        lockType: String    // "synctray" or "rclone_bisync"
    ) {
        guard SyncTraySettings.telemetryEnabled, count > 0 else { return }
        ensureSetup()

        staleLockCleanupCounter?.add(value: count, attribute: [
            "lock.type": .string(lockType),
        ])

        emitLog(
            severity: .warn,
            body: "Cleaned \(count) stale \(lockType) lock files",
            attributes: [
                "lock.type": .string(lockType),
                "lock.count": .int(count),
            ]
        )
    }

    // MARK: - Check Phase Duration

    /// Record the duration of the bisync listing/check phase.
    /// This phase scans all files on both sides and is the main bottleneck for large repos.
    func recordCheckPhaseDuration(
        profileName: String,
        syncMode: String,
        durationSeconds: Double,
        checksCompleted: Int,
        totalChecks: Int
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        syncCheckPhaseHistogram?.record(value: durationSeconds, attributes: [
            "sync.mode": .string(syncMode),
            "synctray.profile.name": .string(profileName),
        ])

        emitLog(
            severity: .info,
            body: "Check phase completed",
            attributes: [
                "synctray.profile.name": .string(profileName),
                "sync.mode": .string(syncMode),
                "sync.check_phase_duration_s": .double(durationSeconds),
                "sync.checks_completed": .int(checksCompleted),
                "sync.total_checks": .int(totalChecks),
            ]
        )
    }

    // MARK: - Session Heartbeat

    /// Emit a periodic session heartbeat log. Call every ~5 minutes from a timer.
    /// Allows detecting app availability vs. crashes (orphaned sessions with no heartbeat).
    func recordSessionHeartbeat(
        enabledProfiles: Int,
        syncingProfiles: Int,
        pausedProfiles: Int,
        errorProfiles: Int
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        emitLog(
            severity: .info,
            body: "Session heartbeat",
            attributes: [
                "session.enabled_profiles": .int(enabledProfiles),
                "session.syncing_profiles": .int(syncingProfiles),
                "session.paused_profiles": .int(pausedProfiles),
                "session.error_profiles": .int(errorProfiles),
            ]
        )
    }

    // MARK: - Volume Events

    /// Record external drive mount/unmount events detected by NSWorkspace.
    func recordVolumeEvent(
        event: String,      // "mounted" or "unmounted"
        affectedProfiles: Int
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        volumeEventCounter?.add(value: 1, attribute: [
            "drive.event": .string(event),
        ])

        emitLog(
            severity: .info,
            body: "Volume \(event)",
            attributes: [
                "drive.event": .string(event),
                "drive.affected_profiles": .int(affectedProfiles),
            ]
        )
    }

    // MARK: - DirectoryWatcher Filter Stats

    /// Record directory watch events that were filtered out.
    /// High phantom rates may indicate FSEvents reliability issues on external drives.
    func recordDirectoryWatchFiltered(
        profileName: String,
        reason: String,     // "out_of_scope", "phantom", "metadata", "no_relevant_changes"
        filteredCount: Int
    ) {
        guard SyncTraySettings.telemetryEnabled, filteredCount > 0 else { return }
        ensureSetup()

        directoryWatchFilterCounter?.add(value: filteredCount, attribute: [
            "directory_watch.filter_reason": .string(reason),
        ])
    }

    // MARK: - Sync Precondition Failures

    /// Record when a sync cannot start due to missing preconditions.
    func recordSyncPreconditionFailure(
        profileId: UUID,
        profileName: String,
        reason: String      // "script_not_found", "config_not_found", "drive_not_mounted"
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        emitLog(
            severity: .warn,
            body: "Sync precondition failed: \(reason)",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "sync.precondition_failure": .string(reason),
            ]
        )
    }

    // MARK: - Resumed External Syncs

    /// Record syncs that were detected already running at app startup.
    func recordResumedExternalSync(
        profileId: UUID,
        profileName: String,
        count: Int
    ) {
        guard SyncTraySettings.telemetryEnabled, count > 0 else { return }
        ensureSetup()

        resumedExternalSyncCounter?.add(value: count, attribute: [:])

        emitLog(
            severity: .info,
            body: "Resumed monitoring \(count) external sync(s)",
            attributes: [
                "sync.resumed_count": .int(count),
            ]
        )
    }

    // MARK: - Settings Window

    /// Record when the user opens the Settings window.
    func recordSettingsOpened() {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        settingsOpenedCounter?.add(value: 1, attribute: [:])
    }

    // MARK: - App Lifecycle

    /// Record app launch.
    func recordAppLaunch() {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        appLaunchCounter?.add(value: 1, attribute: [:])

        emitLog(severity: .info, body: "App launched", attributes: [:])

        recordDeploymentIfChanged()
    }

    /// Detect that this install is now running a different `service.version`
    /// than it was on the previous launch, and emit a discrete "App upgraded"
    /// log. Dash0 overlays these as dashboard annotations so metric/trace
    /// changes can be correlated with the rollout of a new version.
    ///
    /// No event is emitted on a fresh install (no prior version recorded) — we
    /// only mark genuine version transitions.
    private func recordDeploymentIfChanged() {
        let current = appVersion()
        let previous = SyncTraySettings.lastLaunchedVersion

        defer { SyncTraySettings.lastLaunchedVersion = current }

        guard let previous, previous != current else { return }

        emitLog(
            severity: .info,
            body: "App upgraded",
            attributes: [
                "deployment.from_version": .string(previous),
                "deployment.to_version": .string(current),
            ]
        )
    }

    /// Update the active profile count gauge.
    /// Uses delta tracking since UpDownCounter accumulates.
    func recordProfileCount(_ count: Int) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        let delta = count - lastReportedProfileCount
        guard delta != 0 else { return }
        activeProfilesGauge?.add(value: delta, attributes: [:])
        lastReportedProfileCount = count
    }

    // MARK: - Graceful Shutdown

    func shutdown() {
        guard SyncTraySettings.telemetryEnabled else { return }

        // End any orphaned sync spans
        for (_, span) in activeSyncSpans {
            span.setAttribute(key: "sync.result", value: .string("app_shutdown"))
            span.end()
        }
        activeSyncSpans.removeAll()

        // Diagnostic: spans + logs reach Dash0 but the synctray.* metrics do not
        // show up in the metric catalog. The exporter setup looks correct on
        // inspection (shared endpoint/headers with traces, wildcard StableView
        // registered), so surface the flush result here — a non-success on a live
        // run points at the OTLP /v1/metrics exchange as the real culprit.
        let metricsFlush = meterProvider?.forceFlush()
        print("[SyncTray][Telemetry] metrics forceFlush on shutdown: \(String(describing: metricsFlush)) → \(Self.endpoint)/v1/metrics")
        _ = meterProvider?.shutdown()
        tracerProvider?.shutdown()
    }

    // MARK: - Private Helpers

    private func buildResource() -> Resource {
        let version = appVersion()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var attrs: [String: AttributeValue] = [
            ResourceAttributes.serviceName.rawValue: .string(Self.serviceName),
            ResourceAttributes.serviceNamespace.rawValue: .string("synctray"),
            ResourceAttributes.serviceVersion.rawValue: .string(version),
            "service.instance.id": .string(SyncTraySettings.installationId),
            "enduser.id": .string(SyncTraySettings.anonymousUserId),
            ResourceAttributes.osType.rawValue: .string("darwin"),
            ResourceAttributes.osVersion.rawValue: .string(osVersion),
        ]

        // Distinguish development builds from real user installs so dev/test
        // telemetry lands in its own Dash0 environment. A DEBUG build is, by
        // definition, a development build; a Release build ships to users.
        // Overridable via OTEL_RESOURCE_ATTRIBUTES below.
        #if DEBUG
        attrs["deployment.environment.name"] = .string("development")
        #else
        attrs["deployment.environment.name"] = .string("production")
        #endif

        // Apply OTEL_RESOURCE_ATTRIBUTES overrides (e.g., deployment.environment.name)
        if let raw = Self.config["OTEL_RESOURCE_ATTRIBUTES"] {
            for pair in raw.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                attrs[key] = .string(value)
            }
        }

        return Resource(attributes: attrs)
    }

    /// Deployment-precise version string for Dash0 correlation.
    ///
    /// Combines marketing version + build number + git commit (when injected at
    /// build time), e.g. `0.34.0+1.gabc1234`. Each commit produces a distinct
    /// `service.version`, so Dash0 treats every shipped build as its own
    /// deployment for version-aware comparison and regression detection.
    private func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"

        var version = short
        if let build = info?["CFBundleVersion"] as? String,
           !build.isEmpty, build != "0" {
            version += "+\(build)"
        }
        if let sha = gitCommitSHA() {
            version += ".g\(sha)"
        }
        return version
    }

    /// Git short SHA injected into Info.plist by the `Embed Git Commit SHA`
    /// build phase. Returns nil when absent or left as the unsubstituted
    /// build-setting placeholder (e.g. building from a non-git source tree).
    ///
    /// The `GitCommitSHA` key name is shared across three files and must stay in
    /// sync: this reader, `SyncTray/Info.plist`, and the `Embed Git Commit SHA`
    /// build phase in the Xcode project (the writer).
    private func gitCommitSHA() -> String? {
        guard let raw = Bundle.main.infoDictionary?["GitCommitSHA"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    /// Emit a structured OTel log record, optionally correlated to a span.
    private func emitLog(
        severity: Severity,
        body: String,
        attributes: [String: AttributeValue],
        spanContext: SpanContext? = nil
    ) {
        guard let logger = logger else { return }

        var builder = logger.logRecordBuilder()
            .setSeverity(severity)
            .setBody(.string(body))
            .setTimestamp(Date())
            .setAttributes(attributes)

        if let ctx = spanContext {
            builder = builder.setSpanContext(ctx)
        }

        builder.emit()
    }

    /// Normalize a file extension to a low-cardinality value.
    /// Returns the top ~25 common extensions or "(other)" to cap cardinality.
    private func normalizeFileExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty { return "(none)" }

        let allowedExtensions: Set<String> = [
            // Documents
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "md",
            // Images
            "jpg", "jpeg", "png", "gif", "svg", "heic", "webp", "tiff",
            // Video/Audio
            "mp4", "mov", "mp3", "wav", "m4a",
            // Archives
            "zip", "tar", "gz",
            // Code/Data
            "json", "xml", "html", "css", "js", "py", "swift", "sh",
            // Other common
            "log", "db", "sqlite",
        ]

        return allowedExtensions.contains(ext) ? ".\(ext)" : "(other)"
    }

    /// Bucket sync interval into a low-cardinality label.
    private func bucketSyncInterval(_ minutes: Int) -> String {
        switch minutes {
        case ...1: return "1min"
        case 2...5: return "2-5min"
        case 6...15: return "6-15min"
        case 16...30: return "16-30min"
        case 31...60: return "31-60min"
        default: return ">60min"
        }
    }

    /// Categorize an error message into a low-cardinality type for metrics/attributes.
    private func categorizeError(_ message: String?) -> String {
        guard let msg = message else { return "unknown" }
        if SyncLogPatterns.isCriticalError(msg) {
            if msg.contains("resync") || msg.contains("out of sync") {
                return "out_of_sync"
            }
            return "critical"
        }
        if SyncLogPatterns.isTransientAllFilesChangedError(msg) {
            return "transient_all_files_changed"
        }
        if msg.contains("not found") || msg.contains("no such") {
            return "file_not_found"
        }
        if msg.contains("permission") || msg.contains("access denied") {
            return "permission_denied"
        }
        if msg.contains("timeout") || msg.contains("timed out") {
            return "timeout"
        }
        if msg.contains("network") || msg.contains("connection") {
            return "network"
        }
        return "other"
    }

    /// Loads key=value pairs from ~/.config/synctray/.env (if it exists).
    private static func loadDotEnv() -> [String: String] {
        let envFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/synctray/.env")
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

}


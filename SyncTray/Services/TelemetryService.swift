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
/// ## Source correlation
/// - `vcs.repository.url.full` — canonical https URL of the origin remote
/// - `vcs.ref.head.revision` — full commit SHA the binary was built from
///
/// Injected at build time by the `Embed Git Metadata` phase. Together they let a
/// backend resolve any signal to the exact source revision that produced it.
///
/// ## Swift SDK note
/// opentelemetry-swift 1.17.1 requires a wildcard `registerView(name: ".*")` for the
/// stable metrics API. Without it, instruments silently record to no-op storage.
/// See: https://github.com/open-telemetry/opentelemetry-swift/issues/500
final class TelemetryService {
    static let shared = TelemetryService()

    /// Which process is reporting — `app` or `cli` — emitted as the
    /// `synctray.process.kind` resource attribute. Both share `service.name` (one
    /// binary, one release); this keeps a CLI `cache move` or `mount` apart from the
    /// app's own. Set by `SyncTrayCLI.dispatch` before any telemetry is set up.
    static var processKind = "app"

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
    private var rejectedConcurrentRunCounter: LongCounterSdk?
    private var deferredReinstallCounter: LongCounterSdk?
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
    private var reinstallDetachCounter: LongCounterSdk?
    private var reinstallDetachDurationHistogram: DoubleHistogramMeterSdk?
    private var offlineExtensionSetupCounter: LongCounterSdk?
    private var offlineCacheClearCounter: LongCounterSdk?
    private var rcloneDiscoveryCounter: LongCounterSdk?
    private var warmDurationHistogram: DoubleHistogramMeterSdk?
    private var warmThroughputHistogram: DoubleHistogramMeterSdk?
    private var cachedReadThroughputHistogram: DoubleHistogramMeterSdk?
    private var cachedReadFirstByteHistogram: DoubleHistogramMeterSdk?
    private var cachedReadProbeCounter: LongCounterSdk?
    private var warmFilesCounter: LongCounterSdk?
    private var warmBytesCounter: LongCounterSdk?
    private var warmPausedCounter: LongCounterSdk?
    private var externalConfigEditCounter: LongCounterSdk?
    private var cliInvokedCounter: LongCounterSdk?
    private var cacheMigrationCounter: LongCounterSdk?
    private var cacheMigrationDurationHistogram: DoubleHistogramMeterSdk?
    private var cacheMigrationThroughputHistogram: DoubleHistogramMeterSdk?
    private var cacheMigrationFilesCounter: LongCounterSdk?
    private var cacheMigrationBytesCounter: LongCounterSdk?
    private var overlayUploadCountCounter: LongCounterSdk?
    private var overlayUploadFilesCounter: LongCounterSdk?
    private var overlayUploadBytesCounter: LongCounterSdk?
    private var overlayUploadDurationHistogram: DoubleHistogramMeterSdk?
    private var mountModeChangesCounter: LongCounterSdk?
    private var mountAutoResumeCounter: LongCounterSdk?
    private var mountCacheOnlyFallbackCounter: LongCounterSdk?
    private var mountListingWarmCounter: LongCounterSdk?
    private var mountListingWarmDurationHistogram: DoubleHistogramMeterSdk?
    private var mountSpotlightMarkerCounter: LongCounterSdk?
    private var mountInterruptionsCounter: LongCounterSdk?
    private var mountInterruptionDurationHistogram: DoubleHistogramMeterSdk?
    private var activeOverlayUploadSpans: [UUID: any Span] = [:]

    // MARK: - Providers (kept alive for shutdown)

    private var meterProvider: StableMeterProviderSdk?
    private var tracerProvider: TracerProviderSdk?
    private var loggerProvider: LoggerProviderSdk?
    /// Retained so a short-lived process (the CLI) can force-flush queued log
    /// records before exit — `LoggerProviderSdk` exposes no flush, only the
    /// `BatchLogRecordProcessor` does. See `flushForExit`.
    private var logProcessor: BatchLogRecordProcessor?

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
            useSession: Self.exportSession,
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
        Self.diagnostic("metrics exporter configured → \(metricsEndpoint) (temporality: delta, interval: 30s)")

        // MARK: Traces

        let tracesEndpoint = URL(string: "\(Self.endpoint)/v1/traces")!
        let tracesExporter = OtlpHttpTraceExporter(
            endpoint: tracesEndpoint,
            useSession: Self.exportSession,
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
            useSession: Self.exportSession,
            envVarHeaders: Self.authHeaders
        )

        let logProcessor = BatchLogRecordProcessor(logRecordExporter: logsExporter)

        let loggerProviderSdk = LoggerProviderBuilder()
            .with(resource: resource)
            .with(processors: [logProcessor])
            .build()

        self.logProcessor = logProcessor
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

        reinstallDetachCounter = meter
            .counterBuilder(name: "synctray.mount.reinstall_detach")
            .setDescription("Number of pre-uninstall volume detach attempts for mount-mode profiles (settings-save reinstall path)")
            .setUnit("1")
            .build()

        reinstallDetachDurationHistogram = meter
            .histogramBuilder(name: "synctray.mount.reinstall_detach.duration")
            .setDescription("Time taken to gracefully detach a mounted volume before a profile reinstall")
            .setUnit("s")
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

        rejectedConcurrentRunCounter = meter
            .counterBuilder(name: "synctray.sync.rejected_concurrent_run")
            .setDescription(
                "Number of times a rejected concurrent run's own \"prior lock file found\" "
                    + "failure was suppressed because the real holder is still live")
            .setUnit("1")
            .build()

        deferredReinstallCounter = meter
            .counterBuilder(name: "synctray.config.deferred_reinstall")
            .setDescription(
                "External profile edits whose reinstall was deferred because the profile's "
                    + "run was live, by outcome (deferred, applied, failed, dropped)")
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

        rcloneDiscoveryCounter = meter
            .counterBuilder(name: "synctray.rclone.discovery")
            .setDescription("rclone binary discovery outcome at launch (by source + location bucket)")
            .setUnit("1")
            .build()

        warmDurationHistogram = meter
            .histogramBuilder(name: "synctray.offline.warm.duration")
            .setDescription("Duration of an offline-file warming run (seconds)")
            .setUnit("s")
            .build()
        warmThroughputHistogram = meter
            .histogramBuilder(name: "synctray.offline.warm.throughput")
            .setDescription("Average read throughput of an offline-file warming run (MB/s) — the signal for slow-fallback diagnosis")
            .setUnit("MBy/s")
            .build()
        cachedReadThroughputHistogram = meter
            .histogramBuilder(name: "synctray.mount.cached_read.throughput")
            .setDescription("Throughput of a timed read of an already fully-cached file through a Stream mount (MB/s) — the signal for slow cache-served reads")
            .setUnit("MBy/s")
            .build()
        cachedReadFirstByteHistogram = meter
            .histogramBuilder(name: "synctray.mount.cached_read.first_byte")
            .setDescription("Time from open to the first 64 KB of a fully-cached file through a Stream mount (seconds)")
            .setUnit("s")
            .build()
        cachedReadProbeCounter = meter
            .counterBuilder(name: "synctray.mount.cached_read.probes")
            .setDescription("Mount read-health probes by result (healthy/slow/degraded/remote_fetch/no_candidate/failed)")
            .setUnit("1")
            .build()
        warmFilesCounter = meter
            .counterBuilder(name: "synctray.offline.warm.files")
            .setDescription("Files warmed into the VFS content cache")
            .setUnit("1")
            .build()
        warmBytesCounter = meter
            .counterBuilder(name: "synctray.offline.warm.bytes")
            .setDescription("Bytes read through the mount while warming the VFS content cache")
            .setUnit("By")
            .build()
        warmPausedCounter = meter
            .counterBuilder(name: "synctray.offline.warm.paused")
            .setDescription("Offline warm pause/resume events (manual toggle or auto-pause when an app reads the mount)")
            .setUnit("1")
            .build()

        externalConfigEditCounter = meter
            .counterBuilder(name: "synctray.config.external_edit")
            .setDescription("Live external edits to ~/.config/synctray files applied through the reconcile path, by kind (profile, settings)")
            .setUnit("1")
            .build()

        cliInvokedCounter = meter
            .counterBuilder(name: "synctray.cli.invoked")
            .setDescription("Headless synctray CLI invocations, by bounded command verb and ok/error result")
            .setUnit("1")
            .build()

        cacheMigrationCounter = meter
            .counterBuilder(name: "synctray.cache.migration.count")
            .setDescription("Cache-directory migrations by outcome (completed, cancelled, failed, preflight_rejected) and same-volume vs cross-volume")
            .setUnit("1")
            .build()
        cacheMigrationDurationHistogram = meter
            .histogramBuilder(name: "synctray.cache.migration.duration")
            .setDescription("Duration of a cache-directory migration run (seconds)")
            .setUnit("s")
            .build()
        cacheMigrationThroughputHistogram = meter
            .histogramBuilder(name: "synctray.cache.migration.throughput")
            .setDescription("Average copy throughput of a cross-volume cache-directory migration (MB/s)")
            .setUnit("MBy/s")
            .build()
        cacheMigrationFilesCounter = meter
            .counterBuilder(name: "synctray.cache.migration.files")
            .setDescription("Files relocated during a cache-directory migration")
            .setUnit("1")
            .build()
        cacheMigrationBytesCounter = meter
            .counterBuilder(name: "synctray.cache.migration.bytes")
            .setDescription("Bytes relocated during a cache-directory migration")
            .setUnit("By")
            .build()

        overlayUploadCountCounter = meter
            .counterBuilder(name: "synctray.overlay.upload.count")
            .setDescription("Cache Only overlay upload runs by trigger (resume, auto_resume, upload_now), outcome and transport")
            .setUnit("1")
            .build()
        overlayUploadFilesCounter = meter
            .counterBuilder(name: "synctray.overlay.upload.files")
            .setDescription("Overlay files processed by an upload run, by per-file result (uploaded, conflict, already_uploaded, failed)")
            .setUnit("1")
            .build()
        overlayUploadBytesCounter = meter
            .counterBuilder(name: "synctray.overlay.upload.bytes")
            .setDescription("Bytes uploaded from the Cache Only overlay to the remote")
            .setUnit("By")
            .build()
        overlayUploadDurationHistogram = meter
            .histogramBuilder(name: "synctray.overlay.upload.duration")
            .setDescription("Duration of a Cache Only overlay upload run (seconds)")
            .setUnit("s")
            .build()
        mountModeChangesCounter = meter
            .counterBuilder(name: "synctray.mount.mode_changes")
            .setDescription("Mount mode transitions observed for a Stream profile (streaming, cache_only_manual, cache_only_offline, cache_only_pending)")
            .setUnit("1")
            .build()
        mountAutoResumeCounter = meter
            .counterBuilder(name: "synctray.mount.auto_resume")
            .setDescription("Automatic Cache Only -> Streaming resume decisions (resumed, deferred_busy, busy_check_failed)")
            .setUnit("1")
            .build()
        mountCacheOnlyFallbackCounter = meter
            .counterBuilder(name: "synctray.mount.cache_only_fallback")
            .setDescription("Cache Only was requested (streamCacheOnly=true) but the mount settled on streaming instead — e.g. the partial-file list could not be built")
            .setUnit("1")
            .build()
        mountListingWarmCounter = meter
            .counterBuilder(name: "synctray.mount.listing_warm")
            .setDescription("Whole-tree directory-listing warm runs on a streaming Stream mount (completed, failed, skipped)")
            .setUnit("1")
            .build()
        mountListingWarmDurationHistogram = meter
            .histogramBuilder(name: "synctray.mount.listing_warm.duration")
            .setDescription("Duration of a whole-tree directory-listing warm run on mount (seconds)")
            .setUnit("s")
            .build()
        mountSpotlightMarkerCounter = meter
            .counterBuilder(name: "synctray.mount.spotlight_marker")
            .setDescription("Spotlight-exclusion marker writes at a streaming Stream mount root (written, exists, failed, skipped)")
            .setUnit("1")
            .build()
        mountInterruptionsCounter = meter
            .counterBuilder(name: "synctray.mount.interruptions")
            .setDescription("Stream mount interruptions observed by the mount monitor (mount.interruption_kind: stall = the mount root stopped answering, drop = the volume left the mount table without a requested unmount)")
            .setUnit("1")
            .build()
        mountInterruptionDurationHistogram = meter
            .histogramBuilder(name: "synctray.mount.interruption.duration")
            .setDescription("How long a Stream mount interruption lasted, until recovery or unmount (seconds). A stall runs from the start of the probe that stalled (a lower bound); a drop from when the monitor saw the volume gone")
            .setUnit("s")
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
        errorMessage: String?,
        localSyncPath: String? = nil
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
        let errorType = Self.categorizeError(errorMessage)
        let accessDenial = Self.accessDenialAttributes(for: errorMessage, localSyncPath: localSyncPath)
        var errorCounterLabels: [String: AttributeValue] = [
            "sync.mode": .string(mode.rawValue),
            "synctray.profile.name": .string(profileName),
            "error.type": .string(errorType),
        ]
        // Only the two-valued denial kind joins the counter's labels; the rest stays on the
        // span and log, which have no cardinality budget to protect.
        if let denial = accessDenial["error.access_denial"] {
            errorCounterLabels["error.access_denial"] = denial
        }
        syncErrorCounter?.add(value: 1, attribute: errorCounterLabels)

        // End the active span with error
        let errorOperation = Self.categorizeErrorOperation(errorMessage)
        if let span = activeSyncSpans.removeValue(forKey: profileId) {
            span.setAttribute(key: "sync.result", value: .string("failure"))
            span.setAttribute(key: "sync.files_changed", value: .int(filesChanged))
            span.setAttribute(key: "sync.duration_s", value: .double(duration))
            span.setAttribute(key: "sync.exit_code", value: .int(exitCode))
            span.setAttribute(key: "error.type", value: .string(errorType))
            for (key, value) in accessDenial {
                span.setAttribute(key: key, value: value)
            }
            span.setAttribute(key: "error.operation", value: .string(errorOperation))
            // Category only — the raw message can carry paths and remote names, and the
            // privacy disclosure promises "never the raw message".
            span.status = .error(description: errorType)
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
                    "error.operation": .string(errorOperation),
                ].merging(accessDenial) { current, _ in current },
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

    /// Record the pre-uninstall graceful volume detach performed for a mount-mode
    /// profile (`SyncSetupService.uninstall`). This is the regression signal for the
    /// "settings change freezes an active Stream mount" failure mode: a mounted
    /// profile whose detach is slow or falls back to a force-unmount (or a profile
    /// that reaches `uninstall` still mounted at all) is the same condition that
    /// previously froze in-flight reads with no telemetry at all on this path.
    func recordReinstallDetach(
        profileId: UUID,
        profileName: String,
        wasMounted: Bool,
        result: String,             // "not_mounted", "success", "success_forced", "failure"
        durationSeconds: Double
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        reinstallDetachCounter?.add(value: 1, attribute: [
            "mount.operation": .string("reinstall_detach"),
            "mount.result": .string(result),
            "synctray.profile.name": .string(profileName),
        ])

        if wasMounted {
            reinstallDetachDurationHistogram?.record(value: durationSeconds, attributes: [
                "mount.result": .string(result),
                "synctray.profile.name": .string(profileName),
            ])
        }

        guard let tracer = tracer else { return }

        let span = tracer.spanBuilder(spanName: "synctray reinstall_detach")
            .setSpanKind(spanKind: .internal)
            .startSpan()
        span.setAttribute(key: "synctray.profile.id", value: .string(profileId.uuidString))
        span.setAttribute(key: "synctray.profile.name", value: .string(profileName))
        span.setAttribute(key: "mount.operation", value: .string("reinstall_detach"))
        span.setAttribute(key: "mount.result", value: .string(result))
        span.setAttribute(key: "mount.was_mounted", value: .bool(wasMounted))
        span.setAttribute(key: "mount.detach_duration_s", value: .double(durationSeconds))
        span.status = result == "failure" ? .error(description: "reinstall_detach failed") : .ok
        span.end()

        if wasMounted {
            emitLog(
                severity: result == "failure" ? .error : (result == "success_forced" ? .warn : .info),
                body: "Reinstall pre-detach \(result)",
                attributes: [
                    "synctray.profile.id": .string(profileId.uuidString),
                    "synctray.profile.name": .string(profileName),
                    "mount.operation": .string("reinstall_detach"),
                    "mount.result": .string(result),
                    "mount.detach_duration_s": .double(durationSeconds),
                ],
                spanContext: span.context
            )
        }
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
        errorMessage: String,
        localSyncPath: String? = nil
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let errorType = Self.categorizeError(errorMessage)
        let accessDenial = Self.accessDenialAttributes(for: errorMessage, localSyncPath: localSyncPath)

        // Emit a log correlated to the active sync span if one exists
        let spanContext = activeSyncSpans[profileId]?.context

        emitLog(
            severity: .error,
            body: "Sync error",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "error.type": .string(errorType),
                "error.operation": .string(Self.categorizeErrorOperation(errorMessage)),
            ].merging(accessDenial) { current, _ in current },
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
        emitProfileConfigurationsAfterReadingRcloneConfig([profile])
    }

    /// Read rclone.conf (for `config.remote_type` / `config.fallback_remote_type`) on a
    /// `.utility` queue — never the caller's thread, which is the main thread for both
    /// callers (`ProfileStore.update`, the launch snapshot) — then emit one `Profile
    /// configuration` log per profile back on main, where `emitProfileConfiguration` always
    /// ran. The file is read once for all `profiles`; the attributes are unchanged.
    private func emitProfileConfigurationsAfterReadingRcloneConfig(_ profiles: [SyncProfile]) {
        guard !profiles.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let rcloneConfig = RcloneConfigService.shared.readConfigContents()
            DispatchQueue.main.async {
                for profile in profiles {
                    self.emitProfileConfiguration(profile, rcloneConfig: rcloneConfig)
                }
            }
        }
    }

    /// `recordProfileConfiguration` with rclone.conf's text already read (nil = unreadable),
    /// so a launch snapshot of every profile reads the file once, not once per profile.
    /// Re-checks the opt-in, since telemetry may have been turned off while the file was read.
    private func emitProfileConfiguration(_ profile: SyncProfile, rcloneConfig: String?) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let cacheVolume = profile.isMountMode
            ? VFSCacheService.shared.cacheVolumeInfo(path: profile.vfsCachePath) : nil

        let intervalBucket = bucketSyncInterval(profile.syncIntervalMinutes)

        // What kind of folder / storage backend this is — bounded buckets, never the path or
        // the remote's name (`SyncPathKind`, `RemoteBackendType`).
        let localPathKind = SyncPathKind.classify(localPath: profile.localSyncPath, homeDirectory: NSHomeDirectory())
        let remoteTypes = RemoteBackendType.types(for: profile, rcloneConfig: rcloneConfig)

        emitLog(
            severity: .info,
            body: "Profile configuration",
            attributes: [
                "config.local_path_kind": .string(localPathKind),
                "config.local_path_privacy_protected": .bool(SyncPathKind.isPrivacyProtected(localPathKind)),
                "config.remote_type": .string(remoteTypes.primary),
                "config.fallback_remote_type": .string(remoteTypes.fallback),
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
                "config.stream_cache_only": .string(profile.isMountMode ? String(profile.streamCacheOnly) : "n/a"),
                "config.vfs_cache_mode": .string(profile.isMountMode ? profile.vfsCacheMode.rawValue : "n/a"),
                "config.has_pinned_directories": .bool(!profile.pinnedDirectories.isEmpty),
                "config.pinned_directory_count": .int(profile.pinnedDirectories.count),
                // "Don't Sync" adoption (two-way / one-way). Count only: the patterns
                // themselves can name folders, so they never leave the machine.
                "config.sync_exclude_pattern_count": .int(profile.isMountMode ? 0 : profile.syncExcludePatterns.count),
                // "Sync Only These Folders" adoption (two-way / one-way). Count only — the
                // folder names themselves never leave the machine.
                "config.sync_include_folder_count": .int(profile.isMountMode ? 0 : profile.syncIncludeFolders.count),
                "config.allow_non_empty_mount": .bool(profile.allowNonEmptyMount),
                "config.download_connections": .int(profile.isMountMode ? profile.downloadConnections : 0),
                "config.has_bandwidth_limit": .bool(!profile.bandwidthLimit.isEmpty),
                "config.mount_resilient": .string(profile.isMountMode ? String(profile.mountResilient) : "n/a"),
                "config.cache_fs_type": .string(cacheVolume?.fsType ?? "n/a"),
                "config.cache_volume": .string(cacheVolume?.volume ?? "n/a"),
            ]
        )
    }

    // MARK: - Mount read health

    /// Record one mount read-health probe (`VFSCacheService.probeMountRead`). `result` nil
    /// means no probe ran: `outcome` is then `no_candidate` (nothing fully cached large
    /// enough to time) or `failed` (the file couldn't be opened/read through the mount).
    /// Never carries a path or file name — only the bounded cache-volume buckets.
    func recordMountReadProbe(
        profileId: UUID,
        profileName: String,
        mountBackend: String,
        cacheFsType: String,
        cacheVolume: String,
        vfsCacheFiles: Int?,
        result: MountReadProbeResult?,
        outcome: String? = nil
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let health = result.map(VFSCacheService.readHealth) ?? (outcome ?? "failed")
        let labels: [String: AttributeValue] = [
            "synctray.profile.name": .string(profileName),
            "sync.mode": .string("mount"),
            "mount.backend": .string(mountBackend),
            "cache.fs_type": .string(cacheFsType),
            "cache.volume": .string(cacheVolume),
            "mount.read_health": .string(health),
        ]
        cachedReadProbeCounter?.add(value: 1, attribute: labels)

        var attrs = labels
        attrs["synctray.profile.id"] = .string(profileId.uuidString)
        if let vfsCacheFiles { attrs["vfs.cache_files"] = .int(vfsCacheFiles) }
        guard let result else {
            emitLog(severity: .warn, body: "Mount read health probe skipped", attributes: attrs)
            return
        }
        var metricLabels = labels
        metricLabels["mount.read_health"] = nil  // the value is the measurement; don't split it by its own bucket
        cachedReadThroughputHistogram?.record(value: result.throughputMBps, attributes: metricLabels)
        cachedReadFirstByteHistogram?.record(value: result.firstByteSeconds, attributes: metricLabels)

        attrs["probe.bytes"] = .int(result.bytes)
        attrs["probe.duration_seconds"] = .double(result.seconds)
        attrs["probe.first_byte_seconds"] = .double(result.firstByteSeconds)
        attrs["probe.throughput_mbps"] = .double(result.throughputMBps)
        attrs["probe.remote_bytes"] = .int(result.remoteBytes)
        emitLog(severity: health == "healthy" ? .info : .warn, body: "Mount read health", attributes: attrs)
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

        // Individual profile configs — rclone.conf read once for all of them, off the main
        // thread; the per-profile logs follow the summary once it has been read.
        emitProfileConfigurationsAfterReadingRcloneConfig(profiles)
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
            let errorType = Self.categorizeError(errMsg)
            logAttrs["error.type"] = .string(errorType)
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
        if errorMessage != nil {
            logAttrs["error.type"] = .string(errorType)
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

    /// Record when a rejected concurrent run's own "prior lock file found" failure is
    /// suppressed rather than surfaced as this profile's failure (the single-run guard's
    /// R3 behaviour — see CLAUDE.md "One Run Per Profile"). Without this signal there is
    /// no way to see in Dash0 whether the double-bisync race this guard was built to stop
    /// is still happening (review finding).
    /// - Parameters:
    ///   - site: which log-event shape triggered the suppression — `"sync_failed"`
    ///           (the script's own `syncFailed` line) or `"error_message"` (an
    ///           intermediate `errorMessage` line, before `syncFailed` arrives).
    func recordRejectedConcurrentRun(
        profileId: UUID,
        profileName: String,
        site: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        rejectedConcurrentRunCounter?.add(value: 1, attribute: [
            "synctray.profile.name": .string(profileName),
            "rejected_concurrent_run.site": .string(site),
        ])

        emitLog(
            severity: .info,
            body: "Rejected concurrent run suppressed",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "rejected_concurrent_run.site": .string(site),
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
    ///                  `"skipped_drive_not_mounted"` when the external drive is absent;
    ///                  `"blocked_already_running"` when the single-run guard refused
    ///                  because another run already holds the profile's lock (CLAUDE.md
    ///                  "One Run Per Profile").
    func recordAutoFixTriggered(
        profileId: UUID,
        profileName: String,
        // "triggered" | "gave_up_backoff" | "skipped_drive_not_mounted" | "blocked_already_running"
        result: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        autoFixTriggeredCounter?.add(value: 1, attribute: [
            "synctray.profile.name": .string(profileName),
            "result": .string(result),
        ])

        let severity: Severity = (result == "gave_up_backoff" || result == "blocked_already_running") ? .warn : .info
        let body: String
        switch result {
        case "gave_up_backoff":
            body = "Auto-fix suppressed by backoff for \(profileName)"
        case "skipped_drive_not_mounted":
            body = "Auto-fix skipped: external drive not mounted for \(profileName)"
        case "blocked_already_running":
            body = "Auto-fix blocked: a sync is already running for \(profileName)"
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
    /// `result` is `"started"` unless the single-run guard refused the action because
    /// another run already holds the profile's lock (`"blocked_already_running"` — see
    /// CLAUDE.md "One Run Per Profile"), in which case severity is `.warn`.
    func recordUserRecoveryAction(
        profileId: UUID,
        profileName: String,
        action: String,              // force_sync | resync | retry | …
        result: String = "started"   // started | blocked_already_running
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        userRecoveryActionCounter?.add(value: 1, attribute: [
            "synctray.profile.name": .string(profileName),
            "recovery.action": .string(action),
            "recovery.result": .string(result),
        ])

        emitLog(
            severity: result == "blocked_already_running" ? .warn : .info,
            body: "User recovery action",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "recovery.action": .string(action),
                "recovery.result": .string(result),
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

    // MARK: - External Config Edit

    /// Record a live external edit to a `~/.config/synctray` file (a
    /// `*.profile.json` or `settings.json`) that was applied through the
    /// reconcile path. `kind` is bounded ("profile" | "settings"); `action`
    /// is bounded ("edit" | "create" — defaults to "edit" so every existing
    /// call site is unaffected). The attribute set never includes a
    /// filesystem path, remote name, or credential — only the low-cardinality
    /// kind/action.
    func recordExternalConfigEdit(kind: String, action: String = "edit") {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let attrs: [String: AttributeValue] = [
            "config.edit_kind": .string(kind),
            "config.edit_action": .string(action),
        ]
        externalConfigEditCounter?.add(value: 1, attribute: attrs)
        emitLog(severity: .info, body: "External config edit applied", attributes: attrs)
    }

    /// Record a deferred external-edit reinstall's lifecycle (review finding: previously
    /// only a debugLog/print, so Dash0 could not show an edit that never got applied).
    /// - Parameter outcome: `"deferred"` (a sync was live at edit time), `"applied"` (the
    ///   retry succeeded once the run ended), `"failed"` (the retry's install call itself
    ///   threw), or `"dropped"` (the profile was deleted or disabled while the reinstall
    ///   was deferred, so the retry discarded it rather than reinstall a profile that no
    ///   longer exists or that the user explicitly turned off).
    func recordDeferredReinstall(profileId: UUID, profileName: String, outcome: String) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let attrs: [String: AttributeValue] = [
            "synctray.profile.name": .string(profileName),
            "deferred_reinstall.outcome": .string(outcome),
        ]
        deferredReinstallCounter?.add(value: 1, attribute: attrs)

        emitLog(
            severity: outcome == "failed" ? .warn : .info,
            body: "Deferred external-edit reinstall",
            attributes: attrs.merging(["synctray.profile.id": .string(profileId.uuidString)]) { _, new in new }
        )
    }

    // MARK: - Headless CLI

    /// Record one headless `synctray` CLI invocation. Privacy: only the bounded
    /// command verb (allowlisted by the caller; an unrecognised one is mapped to
    /// `(other)` before it reaches here), a coarse `ok`/`error` result, the exit
    /// code, and the wall-clock duration are recorded — never args, profile
    /// names, filesystem paths, or remote names. Called once per CLI run, right
    /// before the process flushes and exits (see `flushForExit`).
    func recordCLIInvocation(command: String, exitCode: Int32, durationSeconds: Double) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let ok = exitCode == 0
        let attrs: [String: AttributeValue] = [
            "cli.command": .string(command),
            "cli.result": .string(ok ? "ok" : "error"),
        ]
        cliInvokedCounter?.add(value: 1, attribute: attrs)
        emitLog(
            severity: ok ? .info : .warn,
            body: "CLI invoked",
            attributes: [
                "cli.command": .string(command),
                "cli.result": .string(ok ? "ok" : "error"),
                "cli.exit_code": .int(Int(exitCode)),
                "cli.duration_seconds": .double(durationSeconds),
            ]
        )
    }

    /// Flush every signal for a short-lived process (the CLI) that is about to
    /// `exit()`. Unlike `shutdown()` — the app's terminate path, which prints a
    /// diagnostic line and ends the sync spans — this is SILENT (no stdout, so
    /// it never pollutes CLI output) and never shuts the providers down. It flushes
    /// the logger too, so a CLI run's `synctray.cli.invoked` counter AND its
    /// "CLI invoked" log both reach the collector before the process dies. No-op
    /// when telemetry is disabled.
    func flushForExit(timeout: TimeInterval = 3) {
        guard SyncTraySettings.telemetryEnabled else { return }
        // The OTLP exporters send on `exportSession`, which sets no custom request
        // timeout, so a synchronous `forceFlush()` can block ~60s against an
        // unreachable/black-holed collector. That is unacceptable for a CLI meant
        // for fast agent scripting, so flush on a background queue and wait only a
        // short, bounded deadline. Telemetry is best-effort: if the flush hasn't
        // landed by the deadline, the process exits anyway and the event is lost —
        // far better than hanging the command.
        //
        // `forceFlush()` returning is not enough: opentelemetry-swift 1.17.1's OTLP/HTTP
        // exporters start the request and return `.success` before it completes, so a
        // process that exits right after the flush kills the request in flight — no CLI
        // event had ever reached the collector. After flushing, wait (inside the same
        // deadline) until the exporters' own session has nothing left in flight.
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = self.meterProvider?.forceFlush()
            self.logProcessor?.forceFlush()
            self.tracerProvider?.forceFlush()
            _ = Self.waitUntilIdle(deadline: deadline, inFlight: Self.inFlightExportCount)
            group.leave()
        }
        _ = group.wait(timeout: deadline)
    }

    /// The session every OTLP exporter sends on (the SDK's own default is also an
    /// ephemeral session). Owned here so `flushForExit` can see the requests in flight.
    private static let exportSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil  // as the SDK's own default session: don't keep request bodies
        return URLSession(configuration: configuration)
    }()

    /// Requests the exporters have started and not finished, or 0 if the session
    /// doesn't answer within a second.
    private static func inFlightExportCount() -> Int {
        let done = DispatchSemaphore(value: 0)
        let count = LockedCount()
        exportSession.getAllTasks { tasks in
            count.value = tasks.filter { $0.state == .running || $0.state == .suspended }.count
            done.signal()
        }
        return done.wait(timeout: .now() + 1) == .timedOut ? 0 : count.value
    }

    private final class LockedCount: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var value: Int {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Poll `inFlight` every `pollInterval` until it reports nothing in flight or
    /// `deadline` passes. Returns whether it drained. Pure over its closures —
    /// covered by `ConfigSelfTest` AC-CLI14.
    static func waitUntilIdle(
        deadline: DispatchTime,
        pollInterval: TimeInterval = 0.05,
        inFlight: () -> Int,
        now: () -> DispatchTime = { .now() },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Bool {
        while inFlight() > 0 {
            guard now() < deadline else { return false }
            sleep(pollInterval)
        }
        return true
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

    /// Quiet period after which a run of recovery events is considered finished.
    /// A recovery arriving within this window of the previous one joins the same episode.
    private static let recoveryEpisodeQuietWindow: TimeInterval = 60

    /// An in-flight run of recovery events for one (reason, profile) pair.
    ///
    /// A recovery loop fires continuously while its underlying cause persists — a log
    /// file being appended to faster than the watcher polls produces one `missed_bytes`
    /// detection per poll, for as long as the writer stays ahead. Emitting a WARN per
    /// detection turns a single condition into thousands of identical records that say
    /// nothing the first one didn't. An episode collapses that run into two records:
    /// the leading edge (emitted immediately, so a genuine one-off is never delayed)
    /// and a summary once the run goes quiet (carrying the count and totals).
    private struct RecoveryEpisode {
        var count: Int
        var totalBytes: UInt64
        var startedAt: Date
        var summaryWorkItem: DispatchWorkItem?
    }

    /// Keyed by `"<reason>|<profileName>"`. Guarded by `recoveryEpisodeLock`.
    private var recoveryEpisodes: [String: RecoveryEpisode] = [:]
    private let recoveryEpisodeLock = NSLock()

    /// Record LogWatcher recovery events (file reopen, missed bytes, polling fallback).
    /// Frequent recoveries may indicate file system reliability issues.
    ///
    /// The counter metric records **every** event — it is pre-aggregated, so volume costs
    /// nothing there and the true rate stays visible. Log records are coalesced per
    /// episode (see `RecoveryEpisode`): the first event emits immediately, the rest are
    /// folded into one summary emitted once the episode goes quiet.
    ///
    /// - Parameter missedBytes: Bytes the watcher had to catch up on, for the
    ///   `missed_bytes` reason. Carried so the summary can answer *how far behind*
    ///   the watcher fell, which is the number that distinguishes a benign catch-up
    ///   from a watcher that cannot keep up with its writer.
    func recordLogWatcherRecovery(
        reason: String,     // "file_replaced", "missed_bytes", "polling_error"
        profileName: String,
        missedBytes: UInt64 = 0
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        logWatcherRecoveryCounter?.add(value: 1, attribute: [
            "logwatcher.recovery_reason": .string(reason),
        ])

        let key = "\(reason)|\(profileName)"

        recoveryEpisodeLock.lock()

        if var episode = recoveryEpisodes[key] {
            // Mid-episode: fold in and reschedule the summary. No log record here —
            // this is the path that used to produce the storm.
            episode.count += 1
            episode.totalBytes += missedBytes
            episode.summaryWorkItem?.cancel()
            episode.summaryWorkItem = scheduleRecoveryEpisodeSummary(
                key: key,
                reason: reason,
                profileName: profileName
            )
            recoveryEpisodes[key] = episode
            recoveryEpisodeLock.unlock()
            return
        }

        // Leading edge of a new episode.
        recoveryEpisodes[key] = RecoveryEpisode(
            count: 1,
            totalBytes: missedBytes,
            startedAt: Date(),
            summaryWorkItem: scheduleRecoveryEpisodeSummary(
                key: key,
                reason: reason,
                profileName: profileName
            )
        )
        recoveryEpisodeLock.unlock()

        var attributes: [String: AttributeValue] = [
            "synctray.profile.name": .string(profileName),
            "logwatcher.recovery_reason": .string(reason),
        ]
        if missedBytes > 0 {
            attributes["logwatcher.missed_bytes"] = .int(Int(clamping: missedBytes))
        }

        emitLog(
            severity: .warn,
            body: "LogWatcher recovery: \(reason)",
            attributes: attributes
        )
    }

    /// Schedule the end-of-episode summary. Caller must hold `recoveryEpisodeLock`.
    private func scheduleRecoveryEpisodeSummary(
        key: String,
        reason: String,
        profileName: String
    ) -> DispatchWorkItem {
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushRecoveryEpisode(key: key, reason: reason, profileName: profileName)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.recoveryEpisodeQuietWindow,
            execute: workItem
        )
        return workItem
    }

    /// Emit the summary for a finished episode and drop its state.
    ///
    /// A single-event episode emits nothing — the leading-edge record already said
    /// everything, and a summary of one would just double the volume we set out to cut.
    private func flushRecoveryEpisode(key: String, reason: String, profileName: String) {
        recoveryEpisodeLock.lock()
        guard let episode = recoveryEpisodes.removeValue(forKey: key) else {
            recoveryEpisodeLock.unlock()
            return
        }
        recoveryEpisodeLock.unlock()

        guard episode.count > 1 else { return }

        var attributes: [String: AttributeValue] = [
            "synctray.profile.name": .string(profileName),
            "logwatcher.recovery_reason": .string(reason),
            "logwatcher.recovery_count": .int(episode.count),
            "logwatcher.episode_duration_seconds": .int(
                Int(Date().timeIntervalSince(episode.startedAt).rounded())
            ),
        ]
        if episode.totalBytes > 0 {
            attributes["logwatcher.missed_bytes"] = .int(Int(clamping: episode.totalBytes))
        }

        emitLog(
            severity: .warn,
            body: "LogWatcher recovery episode ended: \(reason)",
            attributes: attributes
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

    // MARK: - Per-profile heartbeat: Sync progress / Profile status

    /// Attributes of the `Sync progress` log. Counts only: `SyncProgress.transferringFiles`
    /// (the paths of the files in flight) is deliberately never read. `has_stats` is false
    /// until rclone's first stats line has been parsed, and the `sync.progress.*` numbers are
    /// then absent. `runAgeSeconds` is how long ago the app saw the run start (absent when it
    /// didn't, e.g. a run already going when the app launched). Pure, so the self-test can
    /// assert it carries no file name (AC-TS5).
    static func syncProgressAttributes(
        profileId: UUID,
        profileName: String,
        syncMode: SyncMode,
        progress: SyncProgress?,
        runAgeSeconds: TimeInterval?
    ) -> [String: AttributeValue] {
        var attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "sync.mode": .string(syncMode.rawValue),
            "sync.progress.has_stats": .bool(progress != nil),
        ]
        if let runAgeSeconds {
            attrs["sync.run_age_s"] = .double(max(0, runAgeSeconds))
        }
        guard let progress else { return attrs }
        attrs["sync.progress.bytes_transferred"] = .int(Int(progress.bytesTransferred))
        attrs["sync.progress.bytes_total"] = .int(Int(progress.totalBytes))
        attrs["sync.progress.transfers_done"] = .int(progress.transfersDone)
        attrs["sync.progress.transfers_total"] = .int(progress.totalTransfers)
        attrs["sync.progress.checks_done"] = .int(progress.checksDone)
        attrs["sync.progress.checks_total"] = .int(progress.totalChecks)
        attrs["sync.progress.errors"] = .int(progress.errors)
        if let speed = progress.speed { attrs["sync.progress.speed_bps"] = .double(speed) }
        if let eta = progress.eta { attrs["sync.progress.eta_s"] = .int(eta) }
        if let elapsed = progress.elapsedTime { attrs["sync.progress.elapsed_s"] = .double(elapsed) }
        if let listed = progress.listedCount { attrs["sync.progress.listed"] = .int(listed) }
        return attrs
    }

    /// One `Sync progress` log for a live Two-Way / One-Way run, emitted from the 5-minute
    /// heartbeat (`SyncManager.recordProfileHeartbeatTelemetry`). The `synctray sync` span
    /// only exports when the run ends, so without this a multi-hour run shows nothing but its
    /// "Sync started" log. Correlated to that span's context while it is open. Call on the
    /// main thread (`activeSyncSpans` is main-thread state).
    func recordSyncProgress(
        profileId: UUID,
        profileName: String,
        syncMode: SyncMode,
        progress: SyncProgress?,
        runAgeSeconds: TimeInterval?
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        emitLog(
            severity: .info,
            body: "Sync progress",
            attributes: Self.syncProgressAttributes(
                profileId: profileId,
                profileName: profileName,
                syncMode: syncMode,
                progress: progress,
                runAgeSeconds: runAgeSeconds
            ),
            spanContext: activeSyncSpans[profileId]?.context
        )
    }

    /// The bounded `profile.state` label: every `SyncState` case, with a profile in
    /// `pausedProfiles` reported as `paused` whatever its state says. Pure.
    static func profileStateLabel(_ state: SyncState, isPaused: Bool) -> String {
        if isPaused { return "paused" }
        switch state {
        case .idle: return "idle"
        case .syncing: return "syncing"
        case .paused: return "paused"
        case .error: return "error"
        case .driveNotMounted: return "drive_not_mounted"
        case .notConfigured: return "not_configured"
        }
    }

    /// Attributes of the `Profile status` log. `error.type` only when the report has one
    /// (the profile is in an error state). Pure.
    static func profileStatusAttributes(_ report: ProfileStatusReport) -> [String: AttributeValue] {
        var attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(report.profileId.uuidString),
            "synctray.profile.name": .string(report.profileName),
            "sync.mode": .string(report.syncMode.rawValue),
            "profile.state": .string(report.state),
            "profile.run_live": .bool(report.runLive),
            "sync.lock_state": .string(report.lockState),
            "sync.session_lock_state": .string(report.sessionLockState),
            "config.local_path_kind": .string(report.localPathKind),
            "config.remote_type": .string(report.remoteType),
            "config.fallback_remote_type": .string(report.fallbackRemoteType),
        ]
        if let errorType = report.errorType {
            attrs["error.type"] = .string(errorType)
        }
        return attrs
    }

    /// One `Profile status` log per enabled profile, emitted from the 5-minute heartbeat
    /// alongside the aggregate `Session heartbeat` (which stays as it is). Answers "is this
    /// job really running, or held by a stale lock?" per profile: `sync.lock_state` /
    /// `sync.session_lock_state` tell a verified live run from a reused-PID lock
    /// (`SyncRunLock.lockState`).
    func recordProfileStatus(_ report: ProfileStatusReport) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        emitLog(
            severity: .info,
            body: "Profile status",
            attributes: Self.profileStatusAttributes(report)
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
        recordRcloneDiscovery()
    }

    /// Record where (and whether) the rclone binary was found at launch. This gives
    /// measurable coverage of the install-location fix for issue #53: a rise in the
    /// `nix_system` / `nix_per_user` / `login_shell` buckets confirms nix-darwin users are
    /// now discovered, and the `not_found` source flags installs still missing rclone.
    ///
    /// Only the low-cardinality source and location bucket are emitted — never the raw path,
    /// so no username or custom directory leaks (privacy rule).
    private func recordRcloneDiscovery() {
        // Resolution can spawn a login shell (blocking up to the 5s watchdog), and
        // recordAppLaunch() runs on the main thread at startup. Run it off-main so it
        // never hangs launch — the same reason AppSettingsView.detectRcloneVersion
        // resolves rclone inside a detached task (CLAUDE.md Critical Rules #1 and #2).
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = RcloneLocator.resolveDetailed()
            let attributes: [String: AttributeValue] = [
                "rclone.discovery_source": .string(result.source.rawValue),
                "rclone.location": .string(result.location),
            ]
            self?.rcloneDiscoveryCounter?.add(value: 1, attribute: attributes)
            self?.emitLog(
                severity: result.path == nil ? .warn : .info,
                body: result.path == nil ? "rclone not found" : "rclone discovered",
                attributes: attributes
            )
        }
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
        Self.diagnostic("metrics forceFlush on shutdown: \(String(describing: metricsFlush)) → \(Self.endpoint)/v1/metrics")
        logProcessor?.forceFlush()
        tracerProvider?.forceFlush()
        // The flushes only start the sends (see `flushForExit`); the app exits right
        // after this returns, so wait briefly for them to finish, as the CLI does.
        _ = Self.waitUntilIdle(deadline: .now() + 2, inFlight: Self.inFlightExportCount)
        _ = meterProvider?.shutdown()
        tracerProvider?.shutdown()
    }

    // MARK: - Private Helpers

    private func buildResource() -> Resource {
        Resource(attributes: resourceAttributes(includeInstallIdentity: true))
    }

    /// The resource attributes every signal carries. `includeInstallIdentity` is always true
    /// for telemetry; a diagnostic report sent with usage data off passes false, which omits
    /// `service.instance.id` and `enduser.id` and never reads `SyncTraySettings.installationId`
    /// (reading it creates and persists an ID).
    private func resourceAttributes(includeInstallIdentity: Bool) -> [String: AttributeValue] {
        let version = appVersion()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var attrs: [String: AttributeValue] = [
            ResourceAttributes.serviceName.rawValue: .string(Self.serviceName),
            ResourceAttributes.serviceNamespace.rawValue: .string("synctray"),
            ResourceAttributes.serviceVersion.rawValue: .string(version),
            "synctray.process.kind": .string(Self.processKind),
            ResourceAttributes.osType.rawValue: .string("darwin"),
            ResourceAttributes.osVersion.rawValue: .string(osVersion),
        ]
        if includeInstallIdentity {
            attrs["service.instance.id"] = .string(SyncTraySettings.installationId)
            attrs["enduser.id"] = .string(SyncTraySettings.anonymousUserId)
        }

        if let hostArch = hostArch() {
            attrs["host.arch"] = .string(hostArch)
        }

        // Source provenance. Lets a backend walk from a log line or span straight
        // to the code that emitted it, which is the difference between "the watcher
        // is recovering" and "the watcher is recovering at LogWatcher.swift:201".
        // Both are injected into Info.plist by the `Embed Git Metadata` build phase
        // and are absent when building from a non-git source tree.
        if let repositoryURL = infoPlistBuildValue("VCSRepositoryURL") {
            attrs["vcs.repository.url.full"] = .string(repositoryURL)
        }
        if let revision = infoPlistBuildValue("GitCommitSHAFull") {
            // `vcs.ref.head.revision` is the current semconv name and what Dash0's
            // VCS correlation keys on; the older `vcs.repository.ref.revision` is
            // deprecated.
            attrs["vcs.ref.head.revision"] = .string(revision)
        }

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
        if !includeInstallIdentity {
            // Not even through an OTEL_RESOURCE_ATTRIBUTES override.
            attrs.removeValue(forKey: "service.instance.id")
            attrs.removeValue(forKey: "enduser.id")
        }

        return attrs
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

    /// Git short SHA injected into Info.plist by the `Embed Git Metadata` build phase.
    private func gitCommitSHA() -> String? {
        infoPlistBuildValue("GitCommitSHA")
    }

    /// Read a build-time-injected Info.plist value.
    ///
    /// Returns nil when the key is absent, empty, or still holds the unsubstituted
    /// build-setting placeholder (e.g. building from a non-git source tree, where
    /// the `Embed Git Metadata` phase logs a warning and leaves the value alone).
    ///
    /// Every key read here is shared across three files and must stay in sync: this
    /// reader, `SyncTray/Info.plist`, and the `Embed Git Metadata` build phase in the
    /// Xcode project (the writer). Current keys: `GitCommitSHA`, `GitCommitSHAFull`,
    /// `VCSRepositoryURL`.
    private func infoPlistBuildValue(_ key: String) -> String? {
        guard let raw = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    /// CPU architecture of the running slice, for Apple Silicon vs Intel comparison.
    ///
    /// Resolved at compile time rather than via `uname`, so a universal binary
    /// reports the slice actually executing rather than the host's native arch.
    ///
    /// Returns nil outside arm64/amd64 rather than an `"unknown"` placeholder — that
    /// value would sit outside the `host.arch` semconv enum and isn't documented as a
    /// possible value in CLAUDE.md / telemetry.md, so it's omitted from the resource
    /// entirely rather than shipped as an undocumented, non-standard string.
    private func hostArch() -> String? {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "amd64"
        #else
        return nil
        #endif
    }

    /// Emit a structured OTel log record, optionally correlated to a span.
    // MARK: - Offline warming

    /// Opaque handle returned by `beginWarm` and passed back to `endWarm`, carrying the
    /// span and the low-cardinality labels for the end-of-run metrics.
    struct WarmSpanToken {
        let span: (any Span)?
        let profileName: String
        let concurrency: Int
        let trigger: String
    }

    /// Record an offline-warm pause or resume. `source` is `"manual"` (the user's toggle) or
    /// `"auto"` (an app was detected reading the mount). Auto events fire only on the
    /// idle→paused edge, not every monitor tick, so the counter tracks distinct pauses.
    ///
    /// `readers` are the process names the lsof busy check found reading the mount on that
    /// edge (`SyncManager.warmPauseReaders`). They go on the LOG only, never on the counter
    /// (cardinality), and only as bounded labels (`warmPauseReaderSummary`): a macOS
    /// component's own name, `shell`, or `app`. A third-party app's name is never sent.
    func recordWarmPause(profileId: UUID, profileName: String, paused: Bool, source: String, readers: [String] = []) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        let attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "warm.pause_state": .string(paused ? "paused" : "resumed"),
            "warm.pause_source": .string(source),
        ]
        warmPausedCounter?.add(value: 1, attribute: attrs)
        var logAttrs = attrs
        if !readers.isEmpty {
            logAttrs["warm.pause_readers"] = .string(Self.warmPauseReaderSummary(readers))
            logAttrs["warm.pause_reader_count"] = .int(Set(readers).count)
        }
        emitLog(severity: .info, body: paused ? "Offline warm paused" : "Offline warm resumed", attributes: logAttrs)
    }

    /// macOS components reported BY NAME in `warm.pause_readers`: Apple system processes that
    /// can open files on a mounted volume, plus SyncTray's own Finder extension. Their names
    /// identify an OS component, not the user. Anything else is `shell` or `app` (see
    /// `warmPauseReaderLabel`), the same fixed-allowlist approach as `normalizeFileExtension`.
    static let warmPauseReaderAllowlist: Set<String> = [
        // Finder previews and thumbnails
        "QuickLookSatellite", "com.apple.quicklook.ThumbnailsAgent", "quicklookd",
        // Icon rendering
        "iconservicesagent", "iconservicesd",
        // Finder copy/move operations
        "DesktopServicesHelper",
        // Spotlight and metadata (beyond the daemons the busy check already ignores)
        "corespotlightd", "mdbulkimport", "mdsync", "mdwrite", "Spotlight",
        // Versions, Time Machine, iCloud, File Provider
        "revisiond", "backupd", "fileproviderd", "bird", "cloudd",
        // Security scanning
        "XprotectService", "syspolicyd",
        // Photos and media analysis
        "photoanalysisd", "mediaanalysisd",
        // SyncTray's own Finder extension
        "SyncTrayFinderSync",
        // Already ignored by the busy check today; listed so a change there stays legible
        "Finder", "mds", "mds_stores", "mdworker", "mdworker_shared", "fseventsd", "QuickLookUIService",
    ]

    /// Shells (and tmux) report as `shell`: a terminal whose working directory is inside the
    /// mount holds it open for as long as the shell lives.
    static let warmPauseShellNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "tcsh", "csh", "dash", "ksh", "nu", "tmux",
    ]

    /// Most distinct labels one pause reports.
    static let warmPauseReaderSummaryLimit = 5

    /// macOS `lsof` reports at most 31 characters of a process name (a 32-byte kernel buffer),
    /// so an allowlisted name longer than that arrives cut short. Maps the cut form back to
    /// the full allowlist entry (e.g. `com.apple.quicklook.ThumbnailsA` →
    /// `com.apple.quicklook.ThumbnailsAgent`).
    static let warmPauseReaderTruncatedNames: [String: String] = Dictionary(
        warmPauseReaderAllowlist.filter { $0.count > 31 }.map { (String($0.prefix(31)), $0) },
        uniquingKeysWith: { first, _ in first })

    /// Bounded telemetry label for one reader process: its own name when it is an allowlisted
    /// macOS component, `shell` for a shell, otherwise `app`. A leading `-` (login shell) is
    /// ignored.
    static func warmPauseReaderLabel(_ processName: String) -> String {
        let name = processName.hasPrefix("-") ? String(processName.dropFirst()) : processName
        if warmPauseReaderAllowlist.contains(name) { return name }
        if let fullName = warmPauseReaderTruncatedNames[name] { return fullName }
        if warmPauseShellNames.contains(name) { return "shell" }
        return "app"
    }

    /// The `warm.pause_readers` value: distinct labels, sorted, at most
    /// `warmPauseReaderSummaryLimit`, comma-separated. Covered by AC-WV3.
    static func warmPauseReaderSummary(_ readers: [String]) -> String {
        Set(readers.map(warmPauseReaderLabel))
            .sorted()
            .prefix(warmPauseReaderSummaryLimit)
            .joined(separator: ",")
    }

    /// Start a `synctray warm` span for an offline-file warming run. No-op (returns an
    /// empty token) when telemetry is disabled.
    func beginWarm(
        profileId: UUID,
        profileName: String,
        directoryCount: Int,
        concurrency: Int,
        trigger: String
    ) -> WarmSpanToken {
        guard SyncTraySettings.telemetryEnabled else {
            return WarmSpanToken(span: nil, profileName: profileName, concurrency: concurrency, trigger: trigger)
        }
        ensureSetup()

        let attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "warm.directory_count": .int(directoryCount),
            "warm.concurrency": .int(concurrency),
            "warm.trigger": .string(trigger),
        ]

        let span = tracer?.spanBuilder(spanName: "synctray warm")
            .setSpanKind(spanKind: .internal)
            .startSpan()
        if let span {
            for (key, value) in attrs { span.setAttribute(key: key, value: value) }
        }

        emitLog(severity: .info, body: "Offline warm started", attributes: attrs, spanContext: span?.context)
        return WarmSpanToken(span: span, profileName: profileName, concurrency: concurrency, trigger: trigger)
    }

    /// End the warm span and record duration / throughput / file / byte metrics.
    ///
    /// - Parameter outcome: how the run ended — `"completed"` (ran to the end) or
    ///   `"cancelled"` (superseded, cache cleared, or profile unmounted mid-warm). Recorded
    ///   as a `warm.outcome` label on every metric and on the span/log so an interrupted
    ///   warm is distinguishable from a finished one.
    func endWarm(
        _ token: WarmSpanToken,
        filesWarmed: Int,
        bytesWarmed: Int64,
        durationSeconds: Double,
        outcome: String = "completed"
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }

        let throughputMBps = durationSeconds > 0
            ? (Double(bytesWarmed) / durationSeconds) / (1024 * 1024)
            : 0

        // Low-cardinality labels for the metrics (never files/bytes — those are the values).
        let labels: [String: AttributeValue] = [
            "synctray.profile.name": .string(token.profileName),
            "warm.trigger": .string(token.trigger),
            "warm.outcome": .string(outcome),
        ]
        warmDurationHistogram?.record(value: durationSeconds, attributes: labels)
        warmThroughputHistogram?.record(value: throughputMBps, attributes: labels)
        warmFilesCounter?.add(value: filesWarmed, attribute: labels)
        warmBytesCounter?.add(value: Int(bytesWarmed), attribute: labels)

        let endAttrs: [String: AttributeValue] = [
            "synctray.profile.name": .string(token.profileName),
            "warm.trigger": .string(token.trigger),
            "warm.outcome": .string(outcome),
            "warm.concurrency": .int(token.concurrency),
            "warm.files": .int(filesWarmed),
            "warm.bytes": .int(Int(bytesWarmed)),
            "warm.duration_seconds": .double(durationSeconds),
            "warm.throughput_mbps": .double(throughputMBps),
        ]
        if let span = token.span {
            for (key, value) in endAttrs { span.setAttribute(key: key, value: value) }
            span.status = .ok
            span.end()
        }
        let body = outcome == "cancelled" ? "Offline warm cancelled" : "Offline warm completed"
        emitLog(severity: .info, body: body, attributes: endAttrs, spanContext: token.span?.context)
    }

    // MARK: - Cache-directory migration

    /// Opaque handle returned by `beginCacheMigration`, carrying the span and
    /// the low-cardinality label for the end-of-run metrics. NEVER carries a
    /// path, a remote name, or any path-valued field — only the profile id
    /// and its (user-chosen, low-cardinality) display name, same as `WarmSpanToken`.
    struct CacheMigrationSpanToken {
        let span: (any Span)?
        let profileName: String
    }

    /// Pure: does a cache-migration outcome LABEL represent a genuine error
    /// for span-status purposes? Extracted out of `endCacheMigration` so
    /// this decision is behaviorally testable directly, rather than only by
    /// pinning `endCacheMigration`'s literal Swift expression text (finding
    /// 9) — "completed" and the user-initiated "cancelled" are the only
    /// non-error outcomes; every failure/rejection label (a
    /// `CacheMigrationFailure` raw value, optionally `_rolled_back`-suffixed,
    /// or "preflight_rejected") is an error.
    enum CacheMigrationSpanStatus {
        static func isError(outcome: String) -> Bool {
            outcome != "completed" && outcome != "cancelled"
        }
    }

    /// Start a `synctray cache_migration` span. No-op (returns an empty
    /// token) when telemetry is disabled.
    func beginCacheMigration(profileId: UUID, profileName: String) -> CacheMigrationSpanToken {
        guard SyncTraySettings.telemetryEnabled else {
            return CacheMigrationSpanToken(span: nil, profileName: profileName)
        }
        ensureSetup()

        let attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
        ]

        let span = tracer?.spanBuilder(spanName: "synctray cache_migration")
            .setSpanKind(spanKind: .internal)
            .startSpan()
        if let span {
            for (key, value) in attrs { span.setAttribute(key: key, value: value) }
        }

        emitLog(severity: .info, body: "Cache migration started", attributes: attrs, spanContext: span?.context)
        return CacheMigrationSpanToken(span: span, profileName: profileName)
    }

    /// End the cache-migration span and record duration / throughput / file /
    /// byte metrics plus the outcome counter.
    ///
    /// - Parameter outcome: `"completed"`, `"cancelled"`, a
    ///   `CacheMigrationFailure` raw value (optionally `_rolled_back`
    ///   suffixed), or `"preflight_rejected"`.
    func endCacheMigration(
        _ token: CacheMigrationSpanToken,
        filesMoved: Int,
        bytesMoved: Int64,
        durationSeconds: Double,
        sameVolume: Bool,
        outcome: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }

        // Same-volume relocation is a rename, not a byte-for-byte copy — a
        // throughput figure for it would be meaningless, so it's left at 0.
        let throughputMBps = (durationSeconds > 0 && !sameVolume)
            ? (Double(bytesMoved) / durationSeconds) / (1024 * 1024)
            : 0

        let labels: [String: AttributeValue] = [
            "synctray.profile.name": .string(token.profileName),
            "cache_migration.outcome": .string(outcome),
            "cache_migration.same_volume": .bool(sameVolume),
        ]
        cacheMigrationCounter?.add(value: 1, attribute: labels)
        cacheMigrationDurationHistogram?.record(value: durationSeconds, attributes: labels)
        cacheMigrationThroughputHistogram?.record(value: throughputMBps, attributes: labels)
        cacheMigrationFilesCounter?.add(value: filesMoved, attribute: labels)
        cacheMigrationBytesCounter?.add(value: Int(bytesMoved), attribute: labels)

        let endAttrs: [String: AttributeValue] = [
            "synctray.profile.name": .string(token.profileName),
            "cache_migration.outcome": .string(outcome),
            "cache_migration.same_volume": .bool(sameVolume),
            "cache_migration.files": .int(filesMoved),
            "cache_migration.bytes": .int(Int(bytesMoved)),
            "cache_migration.duration_seconds": .double(durationSeconds),
            "cache_migration.throughput_mbps": .double(throughputMBps),
        ]
        if let span = token.span {
            for (key, value) in endAttrs { span.setAttribute(key: key, value: value) }
            // Mirrors the established `result == "failure" ? .error(...) : .ok`
            // pattern (`recordReinstallDetach`) — "completed" and the
            // user-initiated "cancelled" are the only non-error outcomes;
            // every failure/rejection label is a real error (finding 13:
            // this was previously an unconditional `.ok`, so a failed move
            // still showed green in span-based dashboards/alerts). Routed
            // through the pure `CacheMigrationSpanStatus.isError` decision
            // so the self-test can exercise this logic directly (finding 9)
            // instead of pinning this line's literal Swift text.
            span.status = CacheMigrationSpanStatus.isError(outcome: outcome)
                ? .error(description: "cache_migration \(outcome)")
                : .ok
            span.end()
        }
        let body = outcome == "completed" ? "Cache migration completed" : "Cache migration ended"
        emitLog(severity: .info, body: body, attributes: endAttrs, spanContext: token.span?.context)
    }

    // MARK: - Cache Only overlay upload

    /// Start a `synctray overlay_upload` span for one upload run (a drain on Resume Syncing
    /// / auto-resume, or a keep-mode Upload Now). `trigger` is bounded: `resume` |
    /// `auto_resume` | `upload_now`.
    func recordOverlayUploadStarted(profileId: UUID, profileName: String, trigger: String) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "upload.trigger": .string(trigger),
        ]
        let span = tracer?.spanBuilder(spanName: "synctray overlay_upload")
            .setSpanKind(spanKind: .internal)
            .startSpan()
        if let span {
            for (key, value) in attrs { span.setAttribute(key: key, value: value) }
        }
        activeOverlayUploadSpans[profileId] = span
        emitLog(severity: .info, body: "Overlay upload started", attributes: attrs, spanContext: span?.context)
    }

    /// End the overlay-upload span and record count / files / bytes / duration metrics.
    /// `outcome` is derived from the result: `completed` (something uploaded, nothing
    /// failed), `partial` (some uploaded, some failed), `failed` (nothing uploaded, at
    /// least one failure), or `nothing_to_do` (overlay was already empty/fully uploaded).
    func recordOverlayUploadCompleted(
        profileId: UUID,
        profileName: String,
        trigger: String,
        result: OverlaySyncService.OverlayUploadResult,
        duration: Double
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        let outcome: String
        if result.failed > 0 {
            outcome = (result.uploaded > 0 || result.conflicts > 0) ? "partial" : "failed"
        } else if result.uploaded == 0 && result.conflicts == 0 && result.alreadyUploaded == 0 {
            outcome = "nothing_to_do"
        } else {
            outcome = "completed"
        }

        let labels: [String: AttributeValue] = [
            "synctray.profile.name": .string(profileName),
            "upload.trigger": .string(trigger),
            "upload.outcome": .string(outcome),
            "upload.transport": .string(result.transport),
        ]
        overlayUploadCountCounter?.add(value: 1, attribute: labels)
        overlayUploadDurationHistogram?.record(value: duration, attributes: labels)
        overlayUploadBytesCounter?.add(value: Int(result.bytes), attribute: labels)

        func fileLabels(_ fileResult: String) -> [String: AttributeValue] {
            ["synctray.profile.name": .string(profileName), "upload.file_result": .string(fileResult)]
        }
        if result.uploaded > 0 {
            overlayUploadFilesCounter?.add(value: result.uploaded, attribute: fileLabels("uploaded"))
        }
        if result.conflicts > 0 {
            overlayUploadFilesCounter?.add(value: result.conflicts, attribute: fileLabels("conflict"))
        }
        if result.alreadyUploaded > 0 {
            overlayUploadFilesCounter?.add(value: result.alreadyUploaded, attribute: fileLabels("already_uploaded"))
        }
        if result.failed > 0 {
            overlayUploadFilesCounter?.add(value: result.failed, attribute: fileLabels("failed"))
        }

        let endAttrs: [String: AttributeValue] = [
            "synctray.profile.name": .string(profileName),
            "upload.trigger": .string(trigger),
            "upload.outcome": .string(outcome),
            "upload.transport": .string(result.transport),
            "upload.uploaded": .int(result.uploaded),
            "upload.conflicts": .int(result.conflicts),
            "upload.already_uploaded": .int(result.alreadyUploaded),
            "upload.failed": .int(result.failed),
            "upload.duration_seconds": .double(duration),
        ]
        if let span = activeOverlayUploadSpans.removeValue(forKey: profileId) {
            for (key, value) in endAttrs { span.setAttribute(key: key, value: value) }
            span.status = (outcome == "failed") ? .error(description: "overlay upload failed") : .ok
            span.end()
        }
        emitLog(
            severity: outcome == "failed" ? .warn : .info, body: "Overlay upload ended",
            attributes: endAttrs, spanContext: nil)
    }

    /// Record an overlay upload that never started because no remote (primary or
    /// fallback) was reachable — `upload.outcome = "unreachable"`, no span (nothing ran).
    func recordOverlayUploadUnreachable(profileId: UUID, profileName: String, trigger: String) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        let labels: [String: AttributeValue] = [
            "synctray.profile.name": .string(profileName),
            "upload.trigger": .string(trigger),
            "upload.outcome": .string("unreachable"),
            "upload.transport": .string("none"),
        ]
        overlayUploadCountCounter?.add(value: 1, attribute: labels)
        emitLog(severity: .info, body: "Overlay upload ended", attributes: labels, spanContext: nil)
    }

    /// Record a Stream profile's mount mode transitioning (as observed by the mount-state
    /// reconcile loop reading the mode file). `mode` values are rendered with underscores
    /// (`cache_only_manual`, …) for the low-cardinality telemetry attribute.
    func recordMountModeChanged(profileId: UUID, profileName: String, mode: MountMode) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        let attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "mount.mode": .string(mode.rawValue.replacingOccurrences(of: "-", with: "_")),
        ]
        mountModeChangesCounter?.add(value: 1, attribute: attrs)
        emitLog(severity: .info, body: "Mount mode changed", attributes: attrs)
    }

    // MARK: - Mount Interruptions

    /// Record the leading edge of a Stream mount interruption, as seen by the mount monitor
    /// (`SyncManager.trackMountInterruption`). `kind` is `stall` (a `statfs` on the mount root
    /// has been outstanding for `MountStallProbe.stallThreshold`: the condition macOS reports
    /// as "Server connections interrupted") or `drop` (the volume left the mount table while
    /// the profile's launchd agent stayed loaded, so no unmount was requested). Emitted at
    /// detection, not at recovery, so an interruption that never recovers is still visible.
    /// `mode` is the mount mode token with underscores (`streaming`, `cache_only_manual`, …)
    /// or `unknown`.
    func recordMountInterruptionStarted(
        profileId: UUID,
        profileName: String,
        kind: String,
        backend: String,
        mode: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        mountInterruptionsCounter?.add(value: 1, attribute: [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "mount.interruption_kind": .string(kind),
            "mount.backend": .string(backend),
            "mount.mode": .string(mode),
        ])
        emitLog(severity: .warn, body: "Mount interrupted", attributes: [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "sync.mode": .string("mount"),
            "mount.interruption_kind": .string(kind),
            "mount.backend": .string(backend),
            "mount.mode": .string(mode),
        ])
    }

    /// Record the end of a Stream mount interruption. `outcome` is `recovered` (the mount
    /// answered again / the volume came back), `dropped` (a stall that ended with the volume
    /// leaving the mount table in an unexpected drop, which is then tracked as a drop of its
    /// own), or `unmounted` (an interruption closed by a deliberate unmount, disable, delete,
    /// pause or reinstall, including a drop the profile never came back from). For a stall,
    /// `durationSeconds` runs from the start of the probe that stalled, so it is a lower bound.
    func recordMountInterruptionEnded(
        profileId: UUID,
        profileName: String,
        kind: String,
        outcome: String,
        durationSeconds: Double,
        backend: String,
        mode: String
    ) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        mountInterruptionDurationHistogram?.record(value: durationSeconds, attributes: [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "mount.interruption_kind": .string(kind),
            "mount.interruption_outcome": .string(outcome),
            "mount.backend": .string(backend),
            "mount.mode": .string(mode),
        ])
        emitLog(
            severity: outcome == "recovered" ? .info : .warn,
            body: "Mount interruption ended",
            attributes: [
                "synctray.profile.id": .string(profileId.uuidString),
                "synctray.profile.name": .string(profileName),
                "sync.mode": .string("mount"),
                "mount.interruption_kind": .string(kind),
                "mount.interruption_outcome": .string(outcome),
                "mount.interruption_duration_s": .double(durationSeconds),
                "mount.backend": .string(backend),
                "mount.mode": .string(mode),
            ]
        )
    }

    /// Record a whole-tree directory-*listing* warm run on a streaming Stream mount
    /// (`SyncManager.startListingWarm` → `VFSCacheService.refreshAllListings`), fired once
    /// per mount session. This is metadata-only — it populates rclone's dir-listing cache so
    /// first-browse of every folder in Finder is instant instead of a live SMB round trip; it
    /// downloads no file bytes. `outcome` is `completed`/`failed`/`skipped`; `directoriesWarmed`
    /// and `directoriesFailed` are the per-subtree descent's successful vs failed refresh nodes
    /// (a recursive refresh that warmed a whole subtree in one call counts as one warmed). A
    /// `failed`/partial outcome is non-fatal — the mount is fully usable, folders just warm
    /// lazily on first browse — so it logs at warn, not error.
    func recordListingWarm(profileId: UUID, profileName: String, outcome: String, directoriesWarmed: Int, directoriesFailed: Int, durationSeconds: Double) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        let attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "listing_warm.outcome": .string(outcome),
            "listing_warm.directories_warmed": .int(directoriesWarmed),
            "listing_warm.directories_failed": .int(directoriesFailed),
        ]
        mountListingWarmCounter?.add(value: 1, attribute: attrs)
        mountListingWarmDurationHistogram?.record(value: durationSeconds, attributes: attrs)
        emitLog(severity: outcome == "completed" ? .info : .warn, body: "Mount listing warm", attributes: attrs)
    }

    /// Record the Spotlight-exclusion marker write at a streaming mount root
    /// (`SyncManager.writeSpotlightExclusionMarker`), fired once per mount session. `outcome`
    /// is `written` (fresh create), `exists` (already present — the steady state), `failed`
    /// (write threw, e.g. the mount isn't attached), or `skipped` (empty mount path). A
    /// `failed`/`skipped` is non-fatal — Spotlight just keeps indexing — so it logs at warn,
    /// the success cases at info. No paths: the profile id/name only, same as every mount log.
    func recordSpotlightMarker(profileId: UUID, profileName: String, outcome: String) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        let attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "spotlight_marker.outcome": .string(outcome),
        ]
        mountSpotlightMarkerCounter?.add(value: 1, attribute: attrs)
        emitLog(severity: (outcome == "written" || outcome == "exists") ? .info : .warn,
                body: "Mount Spotlight marker", attributes: attrs)
    }

    /// Profiles whose Cache Only list write has failed since its last success. A failed
    /// write leaves no list, so the heartbeat retries it every few minutes; this keeps a
    /// persistent failure to one log line until a write succeeds again. Guarded by
    /// `cacheOnlyListLock` — the writes run off the main actor.
    private var cacheOnlyListFailing: Set<UUID> = []
    private let cacheOnlyListLock = NSLock()

    /// Record a failed Cache Only partial-file list write (`SyncManager.writeCacheOnlyExcludeList`),
    /// once per failure run (see `cacheOnlyListFailing`). The failed walk removed any stale
    /// list, so the profile's next offline mount streams instead of mounting Cache Only.
    /// `error.type` is the bounded `categorizeError` bucket — never the error text, which
    /// names a cache path.
    func recordCacheOnlyListFailed(profileId: UUID, profileName: String, error: Error) {
        // Checked before marking the failure reported, so one that began while telemetry
        // was off is still logged after the user opts in.
        guard SyncTraySettings.telemetryEnabled else { return }
        cacheOnlyListLock.lock()
        let isNewFailure = cacheOnlyListFailing.insert(profileId).inserted
        cacheOnlyListLock.unlock()
        guard isNewFailure else { return }
        ensureSetup()
        let attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "error.type": .string(Self.categorizeError(error.localizedDescription)),
        ]
        emitLog(severity: .warn, body: "Cache Only list write failed", attributes: attrs)
    }

    /// Note a successful Cache Only list write, so the next failure is reported again.
    func recordCacheOnlyListWritten(profileId: UUID) {
        cacheOnlyListLock.lock()
        cacheOnlyListFailing.remove(profileId)
        cacheOnlyListLock.unlock()
    }

    /// Record an automatic Cache Only -> Streaming resume decision. `result` is bounded:
    /// `resumed` | `deferred_busy` | `busy_check_failed`.
    func recordAutoResume(profileId: UUID, profileName: String, result: String) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        let attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
            "auto_resume.result": .string(result),
        ]
        mountAutoResumeCounter?.add(value: 1, attribute: attrs)
        // "resumed" surfaces via the "Mount mode changed" log once the mode flips back to
        // streaming — only the non-resuming outcomes get their own line here.
        if result != "resumed" {
            emitLog(severity: .warn, body: "Auto-resume deferred", attributes: attrs)
        }
    }

    /// Record that Cache Only was requested (`streamCacheOnly == true`) but the mount settled
    /// on streaming instead — the silent fallback in the sync script when the partial-file
    /// exclude list can't be built. This is the "I enabled Cache Only but it's still streaming
    /// / still downloading" case; without this signal it is invisible.
    func recordCacheOnlyFallback(profileId: UUID, profileName: String) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        let attrs: [String: AttributeValue] = [
            "synctray.profile.id": .string(profileId.uuidString),
            "synctray.profile.name": .string(profileName),
        ]
        mountCacheOnlyFallbackCounter?.add(value: 1, attribute: attrs)
        emitLog(severity: .warn, body: "Cache Only fell back to streaming", attributes: attrs)
    }

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

    /// Bounded attributes that tell apart the failures `categorizeError` files under
    /// `permission_denied`. Empty for any other error. Never the path or the message.
    /// - `error.access_denial`: `operation_not_permitted` (EPERM — macOS privacy controls;
    ///   Full Disk Access can fix it) or `permission_denied` (EACCES — file ownership or mode
    ///   bits, e.g. a root-owned folder at a volume root; it can't).
    /// - `error.blocked_path.in_sync_folder`: whether the refused path is the profile's local
    ///   folder or inside it — the case the error banner offers to exclude. Only when the
    ///   message names an absolute path and the caller passed the local folder.
    /// - `error.blocked_path.kind`: `volume_system_folder` (`SyncExcludeFilter.volumeSystemFolderNames`),
    ///   `photos_library`, or `other` — only when the message names an absolute path.
    static func accessDenialAttributes(for message: String?, localSyncPath: String?) -> [String: AttributeValue] {
        guard let message else { return [:] }
        guard let blocked = SyncLogPatterns.blockedAccess(in: message) else {
            if SyncLogPatterns.isOperationNotPermitted(message) {
                return ["error.access_denial": .string(SyncLogPatterns.BlockedAccessKind.macOSPrivacy.rawValue)]
            }
            if SyncLogPatterns.isPermissionDenied(message) {
                return ["error.access_denial": .string(SyncLogPatterns.BlockedAccessKind.filePermissions.rawValue)]
            }
            return [:]
        }
        var attributes: [String: AttributeValue] = [
            "error.access_denial": .string(blocked.kind.rawValue),
            "error.blocked_path.kind": .string(blockedPathKind(blocked.path)),
        ]
        if let localSyncPath, !localSyncPath.isEmpty {
            attributes["error.blocked_path.in_sync_folder"] = .bool(
                SyncExcludeFilter.isWithinSyncFolder(blocked.path, localSyncPath: localSyncPath))
        }
        return attributes
    }

    /// The bounded `error.blocked_path.kind` of a refused path: whether any of its components
    /// is a macOS volume system folder or an Apple Photos library.
    static func blockedPathKind(_ path: String) -> String {
        let components = (path as NSString).pathComponents
        if components.contains(where: { SyncExcludeFilter.volumeSystemFolderNames.contains($0) }) {
            return "volume_system_folder"
        }
        if components.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) {
            return "photos_library"
        }
        return "other"
    }

    /// Categorize an error message into a low-cardinality type for metrics/attributes.
    /// Static and internal (pure — it only consults `SyncLogPatterns`) so `ConfigSelfTest`
    /// can assert the buckets directly.
    ///
    /// Order: the `SyncLogPatterns` checks first (unchanged), then the specific buckets in
    /// `specificErrorBuckets` (matched on a lowercased copy), then the original generic
    /// `not found` / `permission` / `timeout` / `network` checks on the raw message, exactly
    /// as before. So a message the generic checks used to bucket keeps that bucket, except
    /// when it also names a more specific cause — a rate-limit, quota or auth phrase, "no
    /// such host" (`network`, not the `file_not_found` its "no such" used to give it), and so
    /// on — which now wins; and Go's "directory not empty" moved from `critical` to
    /// `directory_not_empty` (see below).
    static func categorizeError(_ message: String?) -> String {
        guard let msg = message else { return "unknown" }
        let lower = msg.lowercased()
        if SyncLogPatterns.isCriticalError(msg) {
            if msg.contains("resync") || msg.contains("out of sync") {
                return "out_of_sync"
            }
            // Go's ENOTEMPTY text. `isCriticalError` matches it only through its "not
            // empty", which is there for rclone mount's "Directory is not empty" mount-point
            // error (that one stays `critical`); a failed rmdir is a file-level error.
            if lower.contains("directory not empty") {
                return "directory_not_empty"
            }
            return "critical"
        }
        if SyncLogPatterns.isTransientAllFilesChangedError(msg) {
            return "transient_all_files_changed"
        }
        if SyncLogPatterns.isBenignNFSExclusiveCreateNotice(msg) {
            // go-nfs (behind `rclone nfsmount`) logs this for every O_EXCL create on a
            // Stream mount; macOS retries without O_EXCL and the create succeeds. LogParser
            // no longer surfaces it as an error, so this bucket only catches it if it ever
            // arrives through another path (e.g. a sync-failure message), instead of "other".
            return "exclusive_mode_unsupported"
        }
        // EPERM — on the local side, macOS privacy controls refusing a protected path (e.g. a
        // Photos library). Checked before the generic buckets below, which its wording
        // ("…: operation not permitted") would otherwise slip past into "other".
        if SyncLogPatterns.isOperationNotPermitted(msg) {
            return "permission_denied"
        }
        // rclone's closing "not deleting files as there were IO errors": a consequence of an
        // earlier read error. Seen here only when the run's first error wasn't captured —
        // `recordSyncFailed` is normally given that first error instead.
        if SyncLogPatterns.isIOErrorsBlockedDeletes(msg) {
            return "io_errors_blocked_deletes"
        }
        // Matched against the message with one leading space, so the space-prefixed TLS and
        // oauth2 needles (" x509:", " tls:", " oauth2:") also catch a message that STARTS
        // with Go's prefix, while a path segment that merely ends in tls, x509 or oauth2
        // ("…/certs/tls: permission denied", where a "/" precedes it) never matches. Every
        // other needle is unaffected.
        let padded = " " + lower
        for (bucket, needles) in specificErrorBuckets where needles.contains(where: { padded.contains($0) }) {
            return bucket
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

    /// The specific `error.type` buckets `categorizeError` tries after its `SyncLogPatterns`
    /// checks and before its generic ones, in order, each against the LOWERCASED message.
    /// First match wins, so the order is load-bearing:
    /// - `rate_limited` before `quota_exceeded`: Google's per-minute limit reads "Quota
    ///   exceeded for quota metric … rateLimitExceeded" and is a rate limit, not a full drive.
    /// - `network`, `timeout` and `tls_certificate` before `auth_failed`: a token refresh that
    ///   failed because DNS, the connection or TLS failed or timed out ("couldn't fetch token:
    ///   … no such host", "oauth2: cannot fetch token: … i/o timeout", "… TLS handshake
    ///   timeout") is a network problem, not bad credentials. That is why `timeout` repeats
    ///   the generic "timed out" and also takes "i/o timeout" / "handshake timeout": without
    ///   them such a message would reach the " oauth2:" needle first.
    /// - all of these before the generic checks: "no such host" would otherwise be
    ///   `file_not_found` via "no such".
    /// Needles are phrases rclone and the Go runtime actually print, kept narrow because the
    /// message usually also carries a file path: TLS is matched by Go's `x509:` / `tls:`
    /// error prefixes rather than the bare words "x509" or "certificate", which would claim
    /// any error about a file named e.g. "x509.pem" or "Birth Certificate.pdf"; those two
    /// prefixes, and Go's oauth2 package prefix, are matched with a leading space (" x509:",
    /// " tls:", " oauth2:"), against the message padded with one leading space by
    /// `categorizeError`, so a path segment named `tls`, `x509` or `oauth2` followed by
    /// `: <error>` ("…/certs/tls: permission denied", "…/x/oauth2: permission denied") is
    /// not claimed either; the HTTP-status needles are matched with their code or full
    /// phrase ("401 unauthorized", "rate limit exceeded") rather than the bare words, which
    /// a file named e.g. "Unauthorized.pdf" or "rate limit notes.txt" would match; and
    /// `invalid_name` takes "invalid characters" (plural), not "invalid character", which is
    /// how Go's JSON decoder reports an HTML page where JSON was expected ("invalid character
    /// '<' looking for beginning of value"). The values are bounded labels; the message
    /// itself never leaves the machine.
    static let specificErrorBuckets: [(bucket: String, needles: [String])] = [
        ("disk_full", ["no space left on device"]),
        ("rate_limited", ["ratelimitexceeded", "userratelimitexceeded", "rate limit exceeded", "too many requests"]),
        ("quota_exceeded", ["storagequotaexceeded", "quotaexceeded", "quota exceeded", "insufficient storage"]),
        ("network", ["no such host", "connection reset", "connection refused", "network is unreachable", "broken pipe"]),
        ("timeout", ["context deadline exceeded", "deadline exceeded", "i/o timeout", "timed out", "handshake timeout"]),
        // Go's TLS alert reads "tls: bad certificate", which " tls:" already matches.
        ("tls_certificate", [" x509:", " tls:", "certificate signed by", "certificate has expired",
                             "certificate verify failed"]),
        ("auth_failed", ["invalid_grant", "token expired", "expired token", " oauth2:", "401 unauthorized",
                         "authentication failed", "couldn't fetch token", "failed to refresh token"]),
        ("name_too_long", ["file name too long", "name too long", "path too long"]),
        ("invalid_name", ["illegal character", "invalid characters", "invalid name", "invalid file name",
                          "invalid filename"]),
        ("checksum_mismatch", ["corrupted on transfer", "hash differ", "hashes differ", "md5 differ", "sizes differ"]),
        ("file_changed_during_transfer", ["source file is being updated", "changed size during"]),
        ("file_busy", ["resource busy", "text file busy", "file is locked", "being used by another process"]),
        // rclone (fs/march) logs "Duplicate object found …" / "Duplicate directory found …".
        ("duplicate_object", ["duplicate object found", "duplicate directory found"]),
        // Normally caught by the critical branch above (see there); this covers a message
        // whose case keeps it out of `isCriticalError`'s case-sensitive "not empty".
        ("directory_not_empty", ["directory not empty"]),
    ]

    /// Which rclone operation an error message is about, for the `error.operation` attribute
    /// on the `Sync error` log and the `Sync failed` log and span. A bounded label:
    /// `copy` | `delete` | `move` (a move or rename) | `list` | `mkdir` | `other`. A nil
    /// message is `other`.
    ///
    /// Conservative heuristic over the lowercased text: rclone's own operation prefixes are
    /// checked first ("Failed to copy:", "Couldn't delete:", "Failed to move:"/"Couldn't
    /// move:"/"Failed to rename:", "error listing:"/"failed to list"/"error reading
    /// source|destination [root] directory:" (rclone's march listing errors), then
    /// "failed to rmdir" (rclone's rmdir/rmdirs failures, labelled `delete`), then "mkdir"
    /// as a word (Go's "mkdir <path>:", rclone's "… mkdir:") or "make directory"), and only
    /// then the bare words "copy", "delete" and "listing". The bare words can also come from
    /// a file path inside the message, which is why they are the last resort. Pure.
    static func categorizeErrorOperation(_ message: String?) -> String {
        guard let lower = message?.lowercased() else { return "other" }
        if lower.contains("failed to copy") { return "copy" }
        if lower.contains("couldn't delete") { return "delete" }
        if lower.contains("failed to move") || lower.contains("couldn't move")
            || lower.contains("failed to rename") { return "move" }
        if lower.contains("error listing") || lower.contains("failed to list")
            || lower.contains("error reading source") || lower.contains("error reading destination") { return "list" }
        // rclone's directory-removal failures: "Failed to rmdir:", "failed to rmdirs:", "Failed to Rmdir:".
        // Anchored on rclone's prefix so a path containing "rmdir" can't match.
        if lower.contains("failed to rmdir") { return "delete" }
        // "mkdir" only as a word: Go's "mkdir <path>:", rclone's "RenameDir mkdir:" and
        // "mkdir metadata:". A path like ".../mkdir-old" or ".../mkdir.sh" doesn't match.
        let padded = " " + lower
        if padded.contains(" mkdir ") || padded.contains(" mkdir:")
            || lower.contains("make directory") { return "mkdir" }
        if lower.contains("copy") { return "copy" }
        if lower.contains("delete") { return "delete" }
        if lower.contains("listing") { return "list" }
        return "other"
    }

    /// Setup diagnostics go to stderr, never stdout: the headless CLI configures
    /// telemetry in-process, and a stray stdout line breaks every agent that
    /// parses `status --json` / `profile show`.
    /// Silent in the CLI: its stderr is the user's terminal, where exporter setup noise
    /// on every command would bury the real output.
    private static func diagnostic(_ message: String) {
        guard processKind == "app" else { return }
        FileHandle.standardError.write(Data("[SyncTray][Telemetry] \(message)\n".utf8))
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

// MARK: - Diagnostic reports (shared OTLP configuration)

/// Read-only views of the exporter configuration, so `DiagnosticReportUploader` posts a
/// user-sent diagnostic report to the same endpoint, with the same headers and resource
/// attributes, as usage telemetry — without changing how telemetry itself is set up.
/// Unlike every `record…` method, these are NOT gated on `telemetryEnabled`: a diagnostic
/// report is its own per-send consent (see CLAUDE.md "Diagnostic reports").
extension TelemetryService {
    /// OTLP/HTTP base endpoint (env > `~/.config/synctray/.env` > Info.plist > default).
    static var diagnosticExportEndpoint: String { endpoint }

    /// The exporter's auth headers (`OTEL_EXPORTER_OTLP_HEADERS` or `DASH0_AUTH_TOKEN`).
    static var diagnosticExportHeaders: [(String, String)] { authHeaders }

    /// Whether this build can upload at all — the same condition `setupOTel` uses.
    static var isDiagnosticExportConfigured: Bool { !authHeaders.isEmpty }

    /// The resource attributes every telemetry signal carries (`service.name`,
    /// `service.version`, `host.arch`, `deployment.environment.name`, …), as strings — plus
    /// `service.instance.id` and `enduser.id` only when `includeInstallIdentity` is true.
    /// With it false, `SyncTraySettings.installationId` is never read.
    static func diagnosticResourceAttributes(includeInstallIdentity: Bool) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in shared.resourceAttributes(includeInstallIdentity: includeInstallIdentity) {
            if case let .string(text) = value {
                result[key] = text
            }
        }
        return result
    }

    /// The deployment-precise `service.version`, for the report header.
    static var diagnosticServiceVersion: String { shared.appVersion() }

    /// Record that the user sent (or tried to send) a diagnostic report. Bounded — the
    /// report code, where it was sent from (`app`/`cli`), the result and the line count;
    /// never any report content. Gated on the usage-data opt-in like every other event.
    func recordDiagnosticReport(reportId: String, sourceUI: String, succeeded: Bool, lineCount: Int) {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()

        emitLog(
            severity: succeeded ? .info : .warn,
            body: succeeded ? "Diagnostic report sent" : "Diagnostic report failed",
            attributes: [
                "diagnostics.report_id": .string(reportId),
                "diagnostics.source_ui": .string(sourceUI),
                "diagnostics.result": .string(succeeded ? "sent" : "failed"),
                "diagnostics.line_count": .int(lineCount),
            ]
        )
    }
}

// MARK: - Bounded profile descriptors (never a path or a remote name)

/// One enabled profile's state for the heartbeat's `Profile status` log
/// (`TelemetryService.recordProfileStatus`). Assembled by
/// `SyncManager.profileHeartbeatReports`, which reads the lock files and the process table
/// off the main actor. Every field is a bounded label or a bool — no path, no remote name,
/// no raw error text.
struct ProfileStatusReport: Equatable {
    let profileId: UUID
    let profileName: String
    let syncMode: SyncMode
    /// `TelemetryService.profileStateLabel`.
    let state: String
    /// `SyncManager.runLiveness`: registry token or a live lock holder (registry only for a
    /// Stream profile, R7).
    let runLive: Bool
    /// `SyncRunLock.lockState` of the `/tmp` run lock, or `n/a` for a Stream profile.
    let lockState: String
    /// `SyncRunLock.lockState` of the bisync session `.lck`, or `n/a` for a One-Way or
    /// Stream profile.
    let sessionLockState: String
    /// `TelemetryService.categorizeError` of the stored error (or, when none was stored, the
    /// error state's own message, e.g. "Script not found"), only in an error state.
    let errorType: String?
    /// `SyncPathKind.classify`.
    let localPathKind: String
    /// `RemoteBackendType.types(for:rcloneConfig:)`.
    let remoteType: String
    let fallbackRemoteType: String
}

/// What kind of folder a profile syncs — `config.local_path_kind` — so telemetry can tell a
/// Pictures sync from one of `~/Library` or an external drive without ever sending the path.
/// Pure: the home directory is injected, nothing touches the file system.
enum SyncPathKind {
    /// Folders macOS privacy controls (TCC) guard, so a sync script run by launchd can be
    /// refused access to them even when the app itself has it — `config.local_path_privacy_protected`.
    static let privacyProtectedKinds: Set<String> = [
        "desktop", "documents", "downloads", "icloud_drive", "library", "external_volume",
    ]

    /// The home sub-folders reported by name: `~/<Folder>` itself or anything under it.
    private static let homeFolderKinds: [String: String] = [
        "desktop": "desktop",
        "documents": "documents",
        "downloads": "downloads",
        "pictures": "pictures",
        "music": "music",
        "movies": "movies",
        "public": "public",
    ]

    /// Bucket a local sync path: `desktop` | `documents` | `downloads` | `pictures` | `music` |
    /// `movies` | `public` (each `~/<Folder>` or below), `icloud_drive` (`~/Library/Mobile
    /// Documents`), `cloud_storage` (`~/Library/CloudStorage`), `library` (anything else under
    /// `~/Library`), `home_root` (the home folder itself), `home_other` (any other folder under
    /// home), `external_volume` (`/Volumes/<name>/…`), `other`, or `unknown` (empty path).
    /// Case-insensitive (APFS is by default), expands a leading `~`, and ignores trailing and
    /// doubled slashes and `.`/`..` components. Pure.
    static func classify(localPath: String, homeDirectory: String) -> String {
        let raw = localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "unknown" }
        let expanded: String
        if raw == "~" {
            expanded = homeDirectory
        } else if raw.hasPrefix("~/") {
            expanded = homeDirectory + "/" + String(raw.dropFirst(2))
        } else {
            expanded = raw
        }
        // A relative path (or `~otheruser/…`) can't be placed.
        guard expanded.hasPrefix("/") else { return "other" }

        let path = normalizedComponents(expanded.lowercased())
        let home = normalizedComponents(homeDirectory.lowercased())
        if !home.isEmpty, path.count >= home.count, Array(path.prefix(home.count)) == home {
            let rest = Array(path.dropFirst(home.count))
            guard let first = rest.first else { return "home_root" }
            if let kind = homeFolderKinds[first] { return kind }
            if first == "library" {
                if rest.count >= 2, rest[1] == "mobile documents" { return "icloud_drive" }
                if rest.count >= 2, rest[1] == "cloudstorage" { return "cloud_storage" }
                return "library"
            }
            return "home_other"
        }
        if path.count >= 2, path[0] == "volumes" { return "external_volume" }
        return "other"
    }

    /// Whether a `classify` result is a folder macOS privacy controls guard. Pure.
    static func isPrivacyProtected(_ kind: String) -> Bool {
        privacyProtectedKinds.contains(kind)
    }

    /// Path components with empty and `.` components dropped and `..` applied. Pure.
    private static func normalizedComponents(_ path: String) -> [String] {
        var parts: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(component))
        }
        return parts
    }
}

/// Which storage backend a profile's remote is — `config.remote_type` /
/// `config.fallback_remote_type` — read from the remote's `type = …` line in rclone.conf and
/// bucketed through a fixed allowlist of rclone backend names, so a hand-edited or future
/// type can never put free text into telemetry. The remote's NAME is never sent.
enum RemoteBackendType {
    /// rclone's backend type names (`rclone help backends`).
    static let knownTypes: Set<String> = [
        "alias", "azureblob", "azurefiles", "b2", "box", "cache", "chunker", "cloudinary",
        "combine", "compress", "crypt", "drive", "dropbox", "fichier", "filefabric", "filescom",
        "ftp", "gofile", "googlecloudstorage", "googlephotos", "hasher", "hdfs", "hidrive",
        "http", "iclouddrive", "imagekit", "internetarchive", "jottacloud", "koofr", "linkbox",
        "local", "mailru", "mega", "memory", "netstorage", "onedrive", "opendrive",
        "oracleobjectstorage", "pcloud", "pikpak", "pixeldrain", "premiumizeme", "protondrive",
        "putio", "qingstor", "quatrix", "s3", "seafile", "sftp", "sharefile", "sia", "smb",
        "storj", "sugarsync", "swift", "ulozto", "union", "uptobox", "webdav", "yandex", "zoho",
    ]

    /// A known backend type is reported as itself, any other non-empty type as `other`, and a
    /// missing or unreadable one (no such section, no `type` line, no rclone.conf) as
    /// `unknown`. Case-insensitive. Pure.
    static func bucket(_ rawType: String?) -> String {
        guard let type = rawType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !type.isEmpty else { return "unknown" }
        return knownTypes.contains(type) ? type : "other"
    }

    /// `(config.remote_type, config.fallback_remote_type)` for a profile, given rclone.conf's
    /// text (`nil` when it could not be read). The fallback is `none` when the profile has no
    /// fallback remote. Pure.
    static func types(for profile: SyncProfile, rcloneConfig: String?) -> (primary: String, fallback: String) {
        let primaryRaw = rcloneConfig.flatMap {
            RcloneConfigService.remoteType(named: profile.primaryRemoteName, inConfig: $0)
        }
        guard profile.hasFallback else { return (bucket(primaryRaw), "none") }
        let fallbackName = profile.fallbackRemote.hasSuffix(":")
            ? String(profile.fallbackRemote.dropLast()) : profile.fallbackRemote
        let fallbackRaw = rcloneConfig.flatMap {
            RcloneConfigService.remoteType(named: fallbackName, inConfig: $0)
        }
        return (bucket(primaryRaw), bucket(fallbackRaw))
    }
}


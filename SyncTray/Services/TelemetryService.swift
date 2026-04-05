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
/// - **Metrics**: Sync duration histogram, operation counters, profile gauge
/// - **Logs**: Structured log records for key lifecycle events (sync, mount, errors)
///
/// ## Per-installation differentiation
/// Every signal carries `service.instance.id` (a persistent UUID per install) as a
/// resource attribute. Combined with profile-level attributes on spans/logs, you can
/// see exactly what each installation is doing across all its profiles.
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
        // Skip setup if no auth headers are configured
        guard !Self.authHeaders.isEmpty else { return }

        let resource = buildResource()

        // MARK: Metrics — stable API

        let metricsEndpoint = URL(string: "\(Self.endpoint)/v1/metrics")!
        let metricsExporter = StableOtlpHTTPMetricExporter(
            endpoint: metricsEndpoint,
            envVarHeaders: Self.authHeaders
        )

        let metricReader = StablePeriodicMetricReaderBuilder(exporter: metricsExporter)
            .setInterval(timeInterval: 60)
            .build()

        let stableMeterProvider = StableMeterProviderSdk.builder()
            .setResource(resource: resource)
            .registerMetricReader(reader: metricReader)
            .build()

        meterProvider = stableMeterProvider
        OpenTelemetry.registerStableMeterProvider(meterProvider: stableMeterProvider)

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
        hasFallback: Bool = false
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

        let span = tracer.spanBuilder(spanName: "synctray sync")
            .setSpanKind(spanKind: .internal)
            .startSpan()

        for (key, value) in profileAttributes(
            profileId: profileId,
            profileName: profileName,
            syncMode: syncMode,
            syncDirection: syncDirection,
            hasFallback: hasFallback
        ) {
            span.setAttribute(key: key, value: value)
        }

        activeSyncSpans[profileId] = span

        emitLog(
            severity: .info,
            body: "Sync started",
            attributes: profileAttributes(
                profileId: profileId,
                profileName: profileName,
                syncMode: syncMode,
                syncDirection: syncDirection,
                hasFallback: hasFallback
            ),
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
            if errorMessage != nil {
                span.setAttribute(key: "error.type", value: .string(errorType))
            }
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
        transport: String,          // "primary" or "fallback"
        fallbackRemoteName: String? = nil
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

    // MARK: - App Lifecycle

    /// Record app launch.
    func recordAppLaunch() {
        guard SyncTraySettings.telemetryEnabled else { return }
        ensureSetup()
        appLaunchCounter?.add(value: 1, attribute: [:])

        emitLog(severity: .info, body: "App launched", attributes: [:])
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

        _ = meterProvider?.forceFlush()
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
            ResourceAttributes.osType.rawValue: .string("darwin"),
            ResourceAttributes.osVersion.rawValue: .string(osVersion),
        ]

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

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
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

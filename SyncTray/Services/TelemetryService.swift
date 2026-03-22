import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp

/// Anonymous, opt-in telemetry service using OpenTelemetry.
///
/// All methods are no-ops unless `SyncTraySettings.telemetryEnabled` is true.
/// No personal data is collected — only bounded, low-cardinality values:
/// sync mode (bisync/sync/mount), sync result (success/failure), and counts.
final class TelemetryService {
    static let shared = TelemetryService()

    // MARK: - Constants

    private static let endpoint = "https://ingress.europe-west4.gcp.dash0-dev.com"
    private static let authToken: String = {
        ProcessInfo.processInfo.environment["DASH0_AUTH_TOKEN"] ?? "YOUR_AUTH_TOKEN"
    }()

    // MARK: - Metric Instruments

    private var syncDurationHistogram: DoubleHistogramMeterSdk?
    private var syncCompletedCounter: LongCounterSdk?
    private var syncFilesChangedCounter: LongCounterSdk?
    private var activeProfilesGauge: LongUpDownCounterSdk?
    private var appLaunchCounter: LongCounterSdk?

    // MARK: - Providers (kept alive for shutdown)

    private var meterProvider: StableMeterProviderSdk?
    private var tracerProvider: TracerProviderSdk?

    // MARK: - Tracer

    private var tracer: (any Tracer)?

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
        // Skip setup if no valid auth token is configured
        guard Self.authToken != "YOUR_AUTH_TOKEN" else { return }

        let resource = buildResource()
        let authHeaders: [(String, String)] = [("Authorization", "Bearer \(Self.authToken)")]

        // MARK: Metrics — stable API

        let metricsEndpoint = URL(string: "\(Self.endpoint)/v1/metrics")!
        let metricsExporter = StableOtlpHTTPMetricExporter(
            endpoint: metricsEndpoint,
            envVarHeaders: authHeaders
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
            envVarHeaders: authHeaders
        )

        let spanProcessor = BatchSpanProcessor(spanExporter: tracesExporter)

        let tracerProviderSdk = TracerProviderBuilder()
            .with(resource: resource)
            .add(spanProcessor: spanProcessor)
            .build()

        tracerProvider = tracerProviderSdk
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProviderSdk)
        tracer = tracerProviderSdk.get(instrumentationName: "synctray")

        // MARK: Build metric instruments from the stable meter

        let meter = stableMeterProvider.get(name: "synctray")

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
    }

    // MARK: - Recording Methods

    /// Record a completed or failed sync operation.
    func recordSyncCompleted(mode: SyncMode, result: String, duration: TimeInterval, filesChanged: Int) {
        guard SyncTraySettings.telemetryEnabled else { return }
        if syncDurationHistogram == nil { setupOTel() }

        let labels: [String: AttributeValue] = [
            "sync.mode": .string(mode.rawValue),
            "sync.result": .string(result)
        ]

        syncDurationHistogram?.record(value: duration, attributes: labels)
        syncCompletedCounter?.add(value: 1, attribute: labels)

        if filesChanged > 0 {
            syncFilesChangedCounter?.add(
                value: filesChanged,
                attribute: ["sync.mode": .string(mode.rawValue)]
            )
        }

        // Record trace span
        recordSyncSpan(mode: mode, result: result, filesChanged: filesChanged)
    }

    /// Record app launch.
    func recordAppLaunch() {
        guard SyncTraySettings.telemetryEnabled else { return }
        if appLaunchCounter == nil { setupOTel() }
        appLaunchCounter?.add(value: 1, attribute: [:])
    }

    /// Update the active profile count gauge.
    /// Uses delta tracking since UpDownCounter accumulates.
    func recordProfileCount(_ count: Int) {
        guard SyncTraySettings.telemetryEnabled else { return }
        if activeProfilesGauge == nil { setupOTel() }
        let delta = count - lastReportedProfileCount
        guard delta != 0 else { return }
        activeProfilesGauge?.add(value: delta, attributes: [:])
        lastReportedProfileCount = count
    }

    // MARK: - Graceful Shutdown

    func shutdown() {
        guard SyncTraySettings.telemetryEnabled else { return }
        _ = meterProvider?.forceFlush()
        _ = meterProvider?.shutdown()
        tracerProvider?.shutdown()
    }

    // MARK: - Private Helpers

    private func buildResource() -> Resource {
        let version = appVersion()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        return Resource(attributes: [
            ResourceAttributes.serviceName.rawValue: .string("synctray"),
            ResourceAttributes.serviceNamespace.rawValue: .string("synctray"),
            ResourceAttributes.serviceVersion.rawValue: .string(version),
            "deployment.environment.name": .string("production"),
            "service.instance.id": .string(SyncTraySettings.installationId),
            ResourceAttributes.osType.rawValue: .string("darwin"),
            ResourceAttributes.osVersion.rawValue: .string(osVersion),
        ])
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func recordSyncSpan(mode: SyncMode, result: String, filesChanged: Int) {
        guard let tracer = tracer else { return }

        let span = tracer.spanBuilder(spanName: "sync.execute")
            .setSpanKind(spanKind: .internal)
            .startSpan()

        span.setAttribute(key: "sync.mode", value: .string(mode.rawValue))
        span.setAttribute(key: "sync.result", value: .string(result))
        span.setAttribute(key: "sync.files_changed", value: .int(filesChanged))
        span.end()
    }

}

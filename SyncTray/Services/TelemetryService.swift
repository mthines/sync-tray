import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHTTP

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

    // We store SDK concrete types so we can call non-mutating methods
    private var syncDurationHistogram: DoubleHistogramMeterSdk?
    private var syncCompletedCounter: LongCounterSdk?
    private var syncFilesChangedCounter: LongCounterSdk?
    private var activeProfilesGauge: LongUpDownCounterSdk?
    private var appLaunchCounter: LongCounterSdk?

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
        let resource = buildResource()
        let config = OtlpConfiguration(
            timeout: 10,
            headers: [("Authorization", "Bearer \(Self.authToken)")]
        )

        // Configure OTLP HTTP metric exporter
        let metricsEndpoint = URL(string: "\(Self.endpoint)/v1/metrics")!
        let metricsExporter = OtlpHttpMetricExporter(
            endpoint: metricsEndpoint,
            config: config
        )

        // Configure periodic reader (export every 60 seconds)
        let metricReader = PeriodicMetricReaderBuilder(exporter: metricsExporter)
            .setInterval(timeInterval: 60)
            .build()

        let meterProviderSdk = MeterProviderBuilder()
            .setResource(resource: resource)
            .registerMetricReader(reader: metricReader)
            .build()

        OpenTelemetry.registerMeterProvider(meterProvider: meterProviderSdk)

        // Configure OTLP HTTP trace exporter
        let tracesEndpoint = URL(string: "\(Self.endpoint)/v1/traces")!
        let tracesExporter = OtlpHttpTraceExporter(
            endpoint: tracesEndpoint,
            config: config
        )

        let spanProcessor = SimpleSpanProcessor(spanExporter: tracesExporter)

        let tracerProviderSdk = TracerProviderBuilder()
            .with(resource: resource)
            .add(spanProcessor: spanProcessor)
            .build()

        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProviderSdk)

        // Build metric instruments using the concrete MeterProviderSdk
        let meter = meterProviderSdk.get(name: "synctray")

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

        // Get tracer
        tracer = tracerProviderSdk.get(instrumentationName: "synctray")
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
        syncCompletedCounter?.add(value: 1, attributes: labels)

        if filesChanged > 0 {
            syncFilesChangedCounter?.add(
                value: filesChanged,
                attributes: ["sync.mode": .string(mode.rawValue)]
            )
        }

        // Record trace span
        recordSyncSpan(mode: mode, result: result, filesChanged: filesChanged)
    }

    /// Record a mount operation result.
    func recordMountResult(result: String) {
        guard SyncTraySettings.telemetryEnabled else { return }
        if tracer == nil { setupOTel() }
        recordMountSpan(result: result)
    }

    /// Record app launch.
    func recordAppLaunch() {
        guard SyncTraySettings.telemetryEnabled else { return }
        if appLaunchCounter == nil { setupOTel() }
        appLaunchCounter?.add(value: 1, attributes: [:])
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
        if let provider = OpenTelemetry.instance.tracerProvider as? TracerProviderSdk {
            provider.shutdown()
        }
        if let provider = OpenTelemetry.instance.meterProvider as? MeterProviderSdk {
            _ = provider.shutdown()
        }
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

    private func recordMountSpan(result: String) {
        guard let tracer = tracer else { return }

        let span = tracer.spanBuilder(spanName: "mount.execute")
            .setSpanKind(spanKind: .internal)
            .startSpan()

        span.setAttribute(key: "sync.result", value: .string(result))
        span.end()
    }
}

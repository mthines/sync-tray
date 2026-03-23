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

        // Parse additional resource attributes from OTEL_RESOURCE_ATTRIBUTES
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

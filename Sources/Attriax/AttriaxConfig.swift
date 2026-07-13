import Foundation

/// Immutable SDK configuration.
///
/// Defaults mirror the Flutter/Android reference. Durations are expressed in
/// seconds (`TimeInterval`) at the public boundary but converted to milliseconds
/// internally where the engine reasons about monotonic time, matching the
/// Android millisecond math exactly.
///
/// `projectToken` is trimmed via `normalizedProjectToken`; an empty token is
/// retained as-is and the transport throws when asked to send with an empty
/// token (matching the Flutter behavior where the token is required).
public struct AttriaxConfig {
    public static let defaultApiBaseURL = "https://api.attriax.com"

    public let projectToken: String
    public let apiBaseURL: String
    public let appVersion: String?
    public let appBuildNumber: String?
    /// iOS bundle identifier override. Defaults to `Bundle.main.bundleIdentifier`
    /// when nil (mirrors the Android `appPackageName` seam).
    public let appPackageName: String?
    public let requestTimeout: TimeInterval
    public let maxQueueSize: Int
    public let eventFlushInterval: TimeInterval
    public let flushEventsImmediatelyOnFirstLaunch: Bool
    /// iOS: gates IDFA collection. When `false` the IDFA candidate is never
    /// consulted even if ATT is authorized (mirrors Android `collectAdvertisingId`).
    public let collectAdvertisingId: Bool
    public let automaticCrashReportingEnabled: Bool
    public let gdprEnabled: Bool
    public let anonymousTracking: Bool
    public let sessionTrackingEnabled: Bool
    public let sessionHeartbeatInterval: TimeInterval
    public let firstLaunchSessionHeartbeatInterval: TimeInterval
    public let attestationEnabled: Bool
    /// the App Attest (or custom) attestation provider. INERT unless
    /// `attestationEnabled` is `true` AND this is non-nil; a nil provider degrades to
    /// the noop and no envelope is ever attached. Construct
    /// `AppAttestAttestationProvider()` (iOS 14+) or use `AttriaxAppAttest.provider()`
    /// (availability-safe) to supply App Attest.
    public let attestationProvider: AttriaxAttestationProvider?
    /// Apple Search Ads / AdServices attribution-token capture. When `true`
    /// the SDK captures `AAAttribution.attributionToken()` on init and POSTs it to
    /// `/api/sdk/v1/asa/token` (best-effort, off the main thread, never blocks init).
    /// Defaults to `false` (opt-in).
    public let asaAttributionEnabled: Bool
    public let pinnedCertificateSHA256Fingerprints: [String]

    public init(
        projectToken: String,
        apiBaseURL: String = defaultApiBaseURL,
        appVersion: String? = nil,
        appBuildNumber: String? = nil,
        appPackageName: String? = nil,
        requestTimeout: TimeInterval = 12,
        maxQueueSize: Int = 500,
        eventFlushInterval: TimeInterval = 60,
        flushEventsImmediatelyOnFirstLaunch: Bool = true,
        collectAdvertisingId: Bool = true,
        automaticCrashReportingEnabled: Bool = true,
        gdprEnabled: Bool = false,
        anonymousTracking: Bool = true,
        sessionTrackingEnabled: Bool = true,
        sessionHeartbeatInterval: TimeInterval = 5 * 60,
        firstLaunchSessionHeartbeatInterval: TimeInterval = 30,
        attestationEnabled: Bool = false,
        attestationProvider: AttriaxAttestationProvider? = nil,
        asaAttributionEnabled: Bool = false,
        pinnedCertificateSHA256Fingerprints: [String] = []
    ) {
        precondition(maxQueueSize > 0, "maxQueueSize must be positive")
        self.projectToken = projectToken
        self.apiBaseURL = apiBaseURL
        self.appVersion = appVersion
        self.appBuildNumber = appBuildNumber
        self.appPackageName = appPackageName
        self.requestTimeout = requestTimeout
        self.maxQueueSize = maxQueueSize
        self.eventFlushInterval = eventFlushInterval
        self.flushEventsImmediatelyOnFirstLaunch = flushEventsImmediatelyOnFirstLaunch
        self.collectAdvertisingId = collectAdvertisingId
        self.automaticCrashReportingEnabled = automaticCrashReportingEnabled
        self.gdprEnabled = gdprEnabled
        self.anonymousTracking = anonymousTracking
        self.sessionTrackingEnabled = sessionTrackingEnabled
        self.sessionHeartbeatInterval = sessionHeartbeatInterval
        self.firstLaunchSessionHeartbeatInterval = firstLaunchSessionHeartbeatInterval
        self.attestationEnabled = attestationEnabled
        self.attestationProvider = attestationProvider
        self.asaAttributionEnabled = asaAttributionEnabled
        self.pinnedCertificateSHA256Fingerprints = pinnedCertificateSHA256Fingerprints
    }

    /// The token with surrounding whitespace stripped (Flutter trims the token).
    public var normalizedProjectToken: String {
        projectToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Internal millisecond views (the engine reasons in ms, like Android).
    var requestTimeoutMs: Int64 { Int64(requestTimeout * 1000) }
    var sessionHeartbeatIntervalMs: Int64 { Int64(sessionHeartbeatInterval * 1000) }
    var firstLaunchSessionHeartbeatIntervalMs: Int64 { Int64(firstLaunchSessionHeartbeatInterval * 1000) }
}

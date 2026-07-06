import Foundation

/// A JSON object body — an alias for readability across the request/queue/batch
/// layers. Uses `Any?` values so nulls survive round-trips through the codec.
typealias AttriaxJSONObject = [String: Any?]

/// Wire endpoint paths (PARITY §8, row W1).
enum AttriaxEndpoints {
    static let open = "/api/sdk/v1/open"
    static let events = "/api/sdk/v1/events"
    static let sessions = "/api/sdk/v1/sessions"
    static let users = "/api/sdk/v1/users"
    static let notifications = "/api/sdk/v1/notifications"
    static let crashes = "/api/sdk/v1/crashes"
    static let batch = "/api/sdk/v1/batch"
    static let deepLinksResolve = "/api/sdk/v1/deep-links/resolve"
    static let dynamicLinks = "/api/sdk/v1/dynamic-links"
    static let uninstallTokens = "/api/sdk/v1/uninstall-tokens"
    static let consentCheck = "/api/sdk/v1/consent/gdpr/check"
    static let consentUpsert = "/api/sdk/v1/consent/gdpr"
    static let gdprErase = "/api/sdk/v1/privacy/gdpr/erase"
    static let receiptsValidate = "/api/sdk/v1/revenue/receipts/validate"
    static let revenueConvert = "/api/sdk/v1/revenue/convert-to-usd"
    static let config = "/api/sdk/v1/config"
    static let attestationChallenge = "/api/sdk/attestation/challenge"
    // CHUNK C — Apple framework endpoints.
    static let asaToken = "/api/sdk/v1/asa/token"
    /// SKAN conversion-value config pull; the project token is appended as a path
    /// segment (`GET /api/sdk/v1/skan/conversion-config/:projectToken`).
    static let skanConversionConfigPrefix = "/api/sdk/v1/skan/conversion-config/"
}

/// An outbound SDK request modeled as a kind + a JSON body map (PARITY §7/§8).
///
/// Deliberately data-driven rather than a type-per-endpoint: the engine only
/// needs the kind name (persisted queue tag / dispatch key), the HTTP path, and
/// the JSON body, plus a few boolean/identity queries for batching and retry.
/// Keeping the body as a plain `AttriaxJSONObject` makes every derived operation
/// (queue serialization, batch hoist/strip, legacy normalization) pure and
/// unit-testable off-device.
struct AttriaxApiRequest {
    let kind: String
    let path: String
    let body: AttriaxJSONObject

    // Queue-kind tags (persisted queue tag / dispatch key).
    static let kindOpen = "open"
    static let kindTrackEvent = "trackEvent"
    static let kindTrackSession = "trackSession"
    static let kindUser = "user"
    static let kindTrackNotification = "trackNotification"
    static let kindTrackCrash = "trackCrash"
    static let kindResolveDeepLink = "resolveDeepLink"
    static let kindCreateDynamicLink = "createDynamicLink"
    static let kindRegisterUninstallToken = "registerUninstallToken"

    /// Legacy queue-kind alias for `user` (row FR1).
    static let legacyKindIdentify = "identify"

    static let fieldProjectToken = "projectToken"
    static let fieldDeviceId = "deviceId"
    static let fieldDeviceIdSource = "deviceIdSource"
    static let fieldLegacyAppToken = "appToken"

    /// Whether this kind participates in batching, and only when identity is present.
    var isBatchable: Bool {
        switch kind {
        case Self.kindTrackEvent, Self.kindTrackSession:
            return body[Self.fieldDeviceId].flatMap { $0 } != nil
        case Self.kindUser:
            return true
        default:
            return false
        }
    }

    /// True for the app-open request (hoisted to the front of every flush; row O2).
    var isAppOpen: Bool { kind == Self.kindOpen }

    /// Deep-link resolves are exempt from the terminal-drop retry policy (row DL5/Q4).
    var isTerminalDropExempt: Bool { kind == Self.kindResolveDeepLink }

    /// The batch item kind name for this request (`event`/`session`/`user`).
    var batchKindName: String {
        switch kind {
        case Self.kindTrackEvent: return "event"
        case Self.kindTrackSession: return "session"
        case Self.kindUser: return "user"
        default: fatalError("Unsupported batch request kind: \(kind)")
        }
    }
}

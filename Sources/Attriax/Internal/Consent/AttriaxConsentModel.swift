import Foundation

/// Local GDPR consent state for the current SDK device (PARITY §5, row C1).
///
/// Mirrors the Android reference `AttriaxGdprConsentState` / Flutter
/// `AttriaxGdprConsentState`. Four states drive the whole capture/identity policy:
/// `unknown` (default), `notRequired`, `pending`, `granted`.
public enum AttriaxGdprConsentState {
    /// Consent has not been checked or set yet.
    case unknown
    /// GDPR consent is not required for this device.
    case notRequired
    /// GDPR consent is required and the SDK is waiting for a decision.
    case pending
    /// Consent values have been granted and stored.
    case granted
}

/// Category-level GDPR consent values (row C1): three independent booleans.
///
/// * `analytics` — analytics, session, crash, and diagnostic tracking.
/// * `attribution` — attribution, install referrer, deep-link attribution, identity.
/// * `adEvents` — ad-event measurement and related revenue analytics.
public struct AttriaxGdprConsentValues: Equatable {
    public let analytics: Bool
    public let attribution: Bool
    public let adEvents: Bool

    public init(analytics: Bool, attribution: Bool, adEvents: Bool) {
        self.analytics = analytics
        self.attribution = attribution
        self.adEvents = adEvents
    }
}

/// The distinct signal families the consent policy reasons about (row C4).
/// Mirrors the Flutter/Android `AttriaxTrackingSignal` enum.
enum AttriaxTrackingSignal {
    case analytics
    case adEvents
    case attribution
    case session
    case deepLink
    case uninstallTracking
}

/// How (if at all) device identity is attached to a captured signal.
enum AttriaxTrackingIdentityMode {
    case identified
    case anonymous
    case withheld
}

/// The resolved capture decision for a single signal under the current consent
/// state (mirrors Flutter `AttriaxTrackingDecision`). `capture` gates whether the
/// signal is enqueued at all; `identityMode` whether the device identity is
/// stamped; `deferNetwork` whether the request must buffer locally (anonymous
/// tracking disabled while waiting).
struct AttriaxTrackingDecision: Equatable {
    let capture: Bool
    let identityMode: AttriaxTrackingIdentityMode
    let deferNetwork: Bool

    /// True only for `.identified`.
    var attachDeviceIdentity: Bool { identityMode == .identified }

    var sendNetworkDirectly: Bool { capture && !deferNetwork }

    static let identified = AttriaxTrackingDecision(
        capture: true,
        identityMode: .identified,
        deferNetwork: false
    )
    static let anonymous = AttriaxTrackingDecision(
        capture: true,
        identityMode: .anonymous,
        deferNetwork: false
    )
    static let withheld = AttriaxTrackingDecision(
        capture: false,
        identityMode: .withheld,
        deferNetwork: false
    )
}

/// Wire-value mapping for `AttriaxGdprConsentState` (PARITY §5, row C2).
///
/// The api `AppUserGdprConsentState` enum uses snake_case string values —
/// critically `not_required`, NOT `notRequired`. These are the exact strings sent
/// on the consent write DTO `state` field and received on the consent status echo.
/// Storage uses the same tokens.
enum AttriaxConsentStateWire {
    static let unknown = "unknown"
    static let notRequired = "not_required"
    static let pending = "pending"
    static let granted = "granted"

    static func toWire(_ state: AttriaxGdprConsentState) -> String {
        switch state {
        case .unknown: return unknown
        case .notRequired: return notRequired
        case .pending: return pending
        case .granted: return granted
        }
    }

    static func fromWire(_ raw: String?) -> AttriaxGdprConsentState {
        switch raw {
        case notRequired: return .notRequired
        case pending: return .pending
        case granted: return .granted
        default: return .unknown
        }
    }
}

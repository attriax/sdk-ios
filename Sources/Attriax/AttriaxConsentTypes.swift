import Foundation

/// Local GDPR consent state for the current SDK device.
///
/// Mirrors the Android/Flutter `AttriaxGdprConsentState` and the KMP core enum. Four
/// states drive the whole capture/identity policy: `unknown` (default),
/// `notRequired`, `pending`, `granted`. The facade maps the KMP enum onto this plain
/// Swift enum so downstream `switch` sites keep working (see `AttriaxBridge`).
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

/// Category-level GDPR consent values: three independent booleans.
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

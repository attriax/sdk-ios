import Foundation
import AttriaxCore

/// Regulation-scoped consent surface exposed as `attriax.consent`.
/// Hosts the GDPR helpers under `gdpr`.
public final class AttriaxConsent {
    /// GDPR-specific consent state and actions for the current device.
    public let gdpr: AttriaxGdprConsent

    init(core: AttriaxCore.Attriax) {
        self.gdpr = AttriaxGdprConsent(core: core)
    }
}

/// GDPR consent state and actions for the current device.
/// A thin forward to the KMP core's `consent.gdpr`; state/values are mapped onto the
/// plain Swift `AttriaxGdprConsentState` / `AttriaxGdprConsentValues`.
public final class AttriaxGdprConsent {
    private let core: AttriaxCore.Attriax

    init(core: AttriaxCore.Attriax) {
        self.core = core
    }

    /// Current local GDPR consent state.
    public var state: AttriaxGdprConsentState {
        AttriaxBridge.gdprState(from: core.consent.gdpr.state)
    }

    /// Last stored category values, or nil before consent is granted.
    public var values: AttriaxGdprConsentValues? {
        AttriaxBridge.gdprValues(from: core.consent.gdpr.values)
    }

    /// Whether the SDK is currently waiting for an explicit GDPR decision.
    public var isWaitingForConsent: Bool {
        core.consent.gdpr.isWaitingForConsent
    }

    /// Resolve whether this device needs a GDPR consent decision. With `localOnly` the
    /// SDK answers from stored state only; otherwise it may ask Attriax. Performs
    /// blocking I/O when `localOnly` is false — call off the main thread.
    @discardableResult
    public func needsConsent(localOnly: Bool = false) -> Bool {
        core.consent.gdpr.needsConsent(localOnly: localOnly)
    }

    /// Store granted GDPR consent category values. Local behavior updates immediately;
    /// the decision syncs to Attriax in the background.
    public func setConsent(analytics: Bool, attribution: Bool, adEvents: Bool) {
        core.consent.gdpr.setConsent(analytics: analytics, attribution: attribution, adEvents: adEvents)
    }

    /// Mark GDPR consent as not required for this device.
    public func setNotRequired() {
        core.consent.gdpr.setNotRequired()
    }

    /// Clear the local GDPR decision and return the SDK to pending evaluation.
    public func reset() {
        core.consent.gdpr.reset()
    }

    /// Request deletion of device-linked GDPR data on the Attriax backend. Performs
    /// blocking I/O — call off the main thread.
    public func requestDataErasure() throws {
        core.consent.gdpr.requestDataErasure()
    }
}

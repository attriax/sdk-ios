import Foundation
import AttriaxCore

/// Regulation-scoped consent surface exposed as `attriax.consent`.
/// Hosts the GDPR helpers under `gdpr` and the CCPA helpers under `ccpa`.
public final class AttriaxConsent {
    /// GDPR-specific consent state and actions for the current device.
    public let gdpr: AttriaxGdprConsent
    /// CCPA "do not sell / share" state and actions for the current device.
    public let ccpa: AttriaxCcpaConsent

    init(core: AttriaxCore.Attriax) {
        self.gdpr = AttriaxGdprConsent(core: core)
        self.ccpa = AttriaxCcpaConsent(core: core)
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

/// CCPA "do not sell / share" state and actions for the current device.
/// A thin forward to the KMP core's `consent.ccpa`. The election (`doNotSell`) and the
/// IAB US Privacy string (`usPrivacy`) are seeded from `AttriaxConfig` and overridable
/// at runtime; both are sent TOP-LEVEL on the next app-open / batch envelope. Mirrors
/// the Flutter `setCcpaConsent` surface and Unity `AttriaxConsent.Ccpa`.
public final class AttriaxCcpaConsent {
    private let core: AttriaxCore.Attriax

    init(core: AttriaxCore.Attriax) {
        self.core = core
    }

    /// Current do-not-sell election, or `nil` when unset (omitted from the wire).
    public var doNotSell: Bool? {
        core.consent.ccpa.doNotSell?.boolValue
    }

    /// Current IAB US Privacy string, or `nil`/empty when unset.
    public var usPrivacy: String? {
        core.consent.ccpa.usPrivacy
    }

    /// Set the CCPA do-not-sell election. `nil` clears it (unset → omitted); an explicit
    /// `false` IS emitted and may clear a prior server-side latch. Takes effect on the
    /// next app-open / batch.
    public func setDoNotSell(_ doNotSell: Bool?) {
        core.consent.ccpa.setDoNotSell(doNotSell: AttriaxBridge.kbool(doNotSell))
    }

    /// Set the IAB US Privacy string (e.g. `1YYN`). `nil`/blank is omitted from the wire.
    public func setUsPrivacy(_ usPrivacy: String?) {
        core.consent.ccpa.setUsPrivacy(usPrivacy: usPrivacy)
    }

    /// Set both the do-not-sell election and the US Privacy string in one call. Mirrors
    /// the Flutter `setCcpaConsent(doNotSell:usPrivacy:)` entry point.
    public func set(doNotSell: Bool?, usPrivacy: String?) {
        core.consent.ccpa.set(doNotSell: AttriaxBridge.kbool(doNotSell), usPrivacy: usPrivacy)
    }
}

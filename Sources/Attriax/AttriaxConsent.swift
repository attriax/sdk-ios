import Foundation

/// Regulation-scoped consent surface exposed as `attriax.consent` (PARITY §5).
/// Currently hosts the GDPR helpers under `gdpr`; ATT/SKAN are chunk-C concerns and
/// are not mirrored here.
public final class AttriaxConsent {
    /// GDPR-specific consent state and actions for the current device.
    public let gdpr: AttriaxGdprConsent

    init(engine: Attriax) {
        self.gdpr = AttriaxGdprConsent(engine: engine)
    }
}

/// GDPR consent state and actions for the current device (PARITY §5, rows C1–C5).
/// Mirrors the Flutter/Android reference `AttriaxGdprConsent`.
///
/// Until consent is granted or marked not required, identified tracking is held
/// back per the configured anonymous-tracking policy. All decisions apply locally
/// IMMEDIATELY and sync to Attriax in the background (generation-guarded).
public final class AttriaxGdprConsent {
    private unowned let engine: Attriax

    init(engine: Attriax) {
        self.engine = engine
    }

    /// Current local GDPR consent state.
    public var state: AttriaxGdprConsentState { engine.gdprConsentState }

    /// Last stored category values, or nil before consent is granted.
    public var values: AttriaxGdprConsentValues? { engine.gdprConsentValues }

    /// Whether the SDK is currently waiting for an explicit GDPR decision.
    public var isWaitingForConsent: Bool { engine.isWaitingForGdprConsent }

    /// Resolve whether this device needs a GDPR consent decision. With `localOnly`
    /// the SDK answers from stored state only; otherwise it may ask Attriax for the
    /// current status. Performs blocking I/O when `localOnly` is false — call off the
    /// main thread.
    @discardableResult
    public func needsConsent(localOnly: Bool = false) -> Bool {
        engine.needsGdprConsent(localOnly: localOnly)
    }

    /// Store granted GDPR consent category values. Local behavior updates
    /// immediately; the decision syncs to Attriax in the background.
    public func setConsent(analytics: Bool, attribution: Bool, adEvents: Bool) {
        engine.setGdprConsent(analytics: analytics, attribution: attribution, adEvents: adEvents)
    }

    /// Mark GDPR consent as not required for this device.
    public func setNotRequired() {
        engine.setGdprConsentNotRequired()
    }

    /// Clear the local GDPR decision and return the SDK to pending evaluation.
    public func reset() {
        engine.resetGdprConsent()
    }

    /// Request deletion of device-linked GDPR data on the Attriax backend. On
    /// success this also clears local SDK state and returns the SDK to pre-init.
    /// Performs blocking I/O — call off the main thread. Throws the transport error
    /// on failure.
    public func requestDataErasure() throws {
        try engine.requestGdprDataErasure()
    }
}

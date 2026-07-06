import Foundation

/// Pure consent decision policy (PARITY §5, row C4). Framework-free and fully
/// unit-testable off-device. Mirrors the Flutter reference `AttriaxConsentPolicy`
/// and the Android `AttriaxConsentPolicy`.
///
/// TWO predicate families intentionally answer DIFFERENT questions over the same
/// consent state — do not treat them as synonyms:
///
///  * `allowsCategory` (STRICT identity gate): may we track this category with the
///    device IDENTITY (and full runtime persistence)? Anonymous tracking does NOT
///    relax a category the user explicitly declined under granted consent.
///  * `canCaptureSignal` / `trackingDecisionFor` (PERMISSIVE anonymous-capture
///    gate): may we CAPTURE this signal at all, possibly anonymously? With
///    anonymous tracking enabled, a declined-but-anonymous-capable category is
///    still captured (anonymized).
struct AttriaxConsentPolicy {
    private let gdprEnabled: Bool
    private let state: AttriaxGdprConsentState
    private let values: AttriaxGdprConsentValues?
    private let anonymousTrackingEnabled: Bool

    init(
        gdprEnabled: Bool,
        state: AttriaxGdprConsentState,
        values: AttriaxGdprConsentValues?,
        anonymousTrackingEnabled: Bool
    ) {
        self.gdprEnabled = gdprEnabled
        self.state = state
        self.values = values
        self.anonymousTrackingEnabled = anonymousTrackingEnabled
    }

    var isWaitingForGdprConsent: Bool {
        state == .pending || state == .unknown
    }

    /// When GDPR is on, we are still waiting, and anonymous tracking is OFF, network
    /// dispatch must be deferred (traffic buffers locally until consent resolves).
    var shouldDeferNetworkDispatch: Bool {
        gdprEnabled && isWaitingForGdprConsent && !anonymousTrackingEnabled
    }

    /// Strict identity gate: may `selector`'s category be tracked with the device
    /// identity? Anonymous tracking does NOT relax a declined category.
    func allowsCategory(_ selector: (AttriaxGdprConsentValues) -> Bool) -> Bool {
        if !gdprEnabled { return true }
        switch state {
        case .notRequired: return true
        case .granted: return values.map(selector) ?? false
        case .pending, .unknown: return false
        }
    }

    func canCaptureCategory(
        _ selector: (AttriaxGdprConsentValues) -> Bool,
        allowWhileWaiting: Bool
    ) -> Bool {
        if !gdprEnabled { return true }
        switch state {
        case .notRequired: return true
        case .granted: return values.map(selector) ?? false
        case .pending, .unknown: return allowWhileWaiting
        }
    }

    /// Permissive capture gate: may this signal be captured at all, possibly
    /// anonymously? With `anonymousTrackingEnabled` on, a declined but
    /// anonymous-capable signal is still captured (anonymized) — intentional.
    func canCaptureSignal(_ signal: AttriaxTrackingSignal) -> Bool {
        if !gdprEnabled { return true }
        switch state {
        case .notRequired:
            return true
        case .granted:
            guard let values = values else { return false }
            return isSignalGranted(signal, values) ||
                (anonymousTrackingEnabled && isAnonymousCapableSignal(signal))
        case .pending, .unknown:
            return canCaptureWhileWaiting(signal)
        }
    }

    func trackingDecisionFor(_ signal: AttriaxTrackingSignal) -> AttriaxTrackingDecision {
        if !gdprEnabled { return .identified }

        if state == .unknown || state == .pending {
            if !canCaptureWhileWaiting(signal) { return .withheld }
            return AttriaxTrackingDecision(
                capture: true,
                identityMode: .anonymous,
                deferNetwork: !anonymousTrackingEnabled
            )
        }

        if state == .notRequired {
            return .identified
        }

        guard state == .granted, let currentValues = values else {
            return .withheld
        }

        if isSignalGranted(signal, currentValues) {
            return .identified
        }

        if anonymousTrackingEnabled && isAnonymousCapableSignal(signal) {
            return .anonymous
        }

        return .withheld
    }

    /// Which signals may be captured (anonymously) while consent is still
    /// pending/unknown (row C4). Analytics, ad-events, session, and deep-link
    /// diagnostics are anonymous-capable; attribution and uninstall tracking are
    /// identity-linked and NEVER captured while waiting.
    func canCaptureWhileWaiting(_ signal: AttriaxTrackingSignal) -> Bool {
        switch signal {
        case .analytics, .adEvents, .session, .deepLink:
            return true
        case .attribution, .uninstallTracking:
            return false
        }
    }

    func isAnonymousCapableSignal(_ signal: AttriaxTrackingSignal) -> Bool {
        canCaptureWhileWaiting(signal)
    }

    func isSignalGranted(_ signal: AttriaxTrackingSignal, _ values: AttriaxGdprConsentValues) -> Bool {
        switch signal {
        case .analytics: return values.analytics
        case .adEvents: return values.adEvents
        case .attribution: return values.attribution
        case .session: return values.analytics || values.adEvents
        case .deepLink: return values.attribution
        case .uninstallTracking: return values.attribution
        }
    }
}

import Foundation

/// Pure queue-rewrite predicate policy for consent resolution (PARITY §5, row C5).
///
/// Mirrors the Flutter reference `AttriaxConsentQueuePolicy` and the Android
/// `AttriaxConsentQueuePolicy`. Answers the three questions the runtime's
/// consent-resolution passes ask about each persisted request. The engine models
/// requests as a `kind` + body map (not a class per endpoint), so these predicates
/// key off `AttriaxApiRequest.kind` and inspect the body for the ad-event name /
/// device identity.
///
/// The policy delegates the actual consent reasoning to the (also pure)
/// `AttriaxConsentPolicy` via the injected suppliers, so it holds no state and is
/// fully unit-testable off-device.
struct AttriaxConsentQueuePolicy {
    private let isWaitingForGdprConsent: () -> Bool
    private let anonymousTrackingEnabled: () -> Bool
    private let allowsAttributionTracking: () -> Bool
    private let trackingDecisionFor: (AttriaxTrackingSignal) -> AttriaxTrackingDecision

    init(
        isWaitingForGdprConsent: @escaping () -> Bool,
        anonymousTrackingEnabled: @escaping () -> Bool,
        allowsAttributionTracking: @escaping () -> Bool,
        trackingDecisionFor: @escaping (AttriaxTrackingSignal) -> AttriaxTrackingDecision
    ) {
        self.isWaitingForGdprConsent = isWaitingForGdprConsent
        self.anonymousTrackingEnabled = anonymousTrackingEnabled
        self.allowsAttributionTracking = allowsAttributionTracking
        self.trackingDecisionFor = trackingDecisionFor
    }

    /// The tracking decision for a queued request, or nil for kinds that carry no
    /// consent-gated signal (dynamic links, uninstall tokens handled separately).
    func trackingDecisionForQueuedRequest(_ request: AttriaxApiRequest) -> AttriaxTrackingDecision? {
        switch request.kind {
        case AttriaxApiRequest.kindTrackEvent:
            return trackingDecisionFor(
                isAdEventName(eventNameOf(request)) ? .adEvents : .analytics
            )
        case AttriaxApiRequest.kindTrackCrash:
            return trackingDecisionFor(.analytics)
        case AttriaxApiRequest.kindTrackNotification:
            return trackingDecisionFor(.analytics)
        case AttriaxApiRequest.kindTrackSession:
            return trackingDecisionFor(.session)
        case AttriaxApiRequest.kindResolveDeepLink:
            return trackingDecisionFor(.deepLink)
        default:
            return nil
        }
    }

    /// PASS 1 predicate: after consent resolved to IDENTIFIED tracking, this
    /// anonymous request may now have the device identity re-attached.
    func shouldIdentifyQueuedRequestForResolvedConsent(_ request: AttriaxApiRequest) -> Bool {
        if isWaitingForGdprConsent() { return false }
        guard let decision = trackingDecisionForQueuedRequest(request) else { return false }
        return decision.capture && decision.attachDeviceIdentity
    }

    /// PASS 3 predicate (negated by the caller): whether this request is still
    /// allowed under the resolved consent. Anything not allowed is discarded with
    /// reason `gdpr_consent_denied`.
    func isRequestAllowedByResolvedConsent(_ request: AttriaxApiRequest) -> Bool {
        switch request.kind {
        case AttriaxApiRequest.kindTrackEvent,
             AttriaxApiRequest.kindTrackCrash,
             AttriaxApiRequest.kindTrackNotification,
             AttriaxApiRequest.kindTrackSession,
             AttriaxApiRequest.kindResolveDeepLink:
            return trackingDecisionForQueuedRequest(request)?.capture ?? false
        case AttriaxApiRequest.kindUser:
            return allowsAttributionTracking()
        case AttriaxApiRequest.kindOpen:
            return allowsAttributionTracking()
        case AttriaxApiRequest.kindRegisterUninstallToken:
            return allowsAttributionTracking()
        case AttriaxApiRequest.kindCreateDynamicLink:
            return true
        default:
            return true
        }
    }

    /// PASS 2 predicate: after consent resolved, this request keeps being captured
    /// but only ANONYMOUSLY (a declined-but-anonymous-capable category), so its
    /// device identity must be stripped.
    func shouldAnonymizeQueuedRequest(_ request: AttriaxApiRequest) -> Bool {
        if isWaitingForGdprConsent() || !anonymousTrackingEnabled() { return false }
        guard let decision = trackingDecisionForQueuedRequest(request) else { return false }
        return decision.capture && !decision.attachDeviceIdentity
    }

    private func eventNameOf(_ request: AttriaxApiRequest) -> String {
        (request.body["eventName"] as? String) ?? ""
    }

    private func isAdEventName(_ eventName: String) -> Bool {
        if eventName == AttriaxAnalyticsEventKeys.adRevenue { return true }
        return AttriaxConsentQueuePolicy.adEventNames.contains(eventName)
    }

    /// The canonical ad-lifecycle event names (row C5 ad-event classification).
    private static let adEventNames: Set<String> = {
        let types: [AttriaxAdEventType] = [
            .request, .load, .loadFailed, .show, .showFailed,
            .impression, .click, .dismiss, .reward,
        ]
        return Set(types.map { $0.eventName })
    }()
}

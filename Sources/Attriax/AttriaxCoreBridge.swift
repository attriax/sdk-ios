import Foundation
import AttriaxCore

// Central KMP ⇄ Swift bridge for the thin `sdk-ios` facade.
//
// The engine lives in the `AttriaxCore` XCFramework (Kotlin/Native → Obj-C). Its
// Swift-facing types collide by NAME with this module's public API (both were
// extracted from the same source), so every KMP reference here is module-qualified
// (`AttriaxCore.…`) and the bridge maps between the KMP surface (NSNumber-boxed
// primitives, enums-as-classes, ms-based config) and the idiomatic public Swift API.
//
// Kept deliberately in one place so the facade classes stay declarative.

/// The session snapshot is a plain value object; re-export the KMP type under the
/// public name (it was internal-only in the standalone SDK, so this widens nothing
/// the public contract guaranteed).
public typealias AttriaxSessionSnapshot = AttriaxCore.AttriaxSessionSnapshot

enum AttriaxBridge {

    // MARK: - config (public Swift AttriaxConfig → KMP AttriaxConfig)

    static func kmpConfig(from config: AttriaxConfig) -> AttriaxCore.AttriaxConfig {
        AttriaxCore.AttriaxConfig(
            projectToken: config.projectToken,
            apiBaseUrl: config.apiBaseURL,
            appVersion: config.appVersion,
            appBuildNumber: config.appBuildNumber,
            appPackageName: config.appPackageName,
            sdkMetadata: nil,
            deviceContext: nil,
            enableDebugLogs: false,
            requestTimeoutMs: config.requestTimeoutMs,
            maxQueueSize: Int32(config.maxQueueSize),
            eventFlushIntervalMs: Int64(config.eventFlushInterval * 1000),
            flushEventsImmediatelyOnFirstLaunch: config.flushEventsImmediatelyOnFirstLaunch,
            collectAdvertisingId: config.collectAdvertisingId,
            automaticCrashReportingEnabled: config.automaticCrashReportingEnabled,
            gdprEnabled: config.gdprEnabled,
            anonymousTracking: config.anonymousTracking,
            sessionTrackingEnabled: config.sessionTrackingEnabled,
            sessionHeartbeatIntervalMs: config.sessionHeartbeatIntervalMs,
            firstLaunchSessionHeartbeatIntervalMs: config.firstLaunchSessionHeartbeatIntervalMs,
            installReferrerEnabled: true,
            attestationEnabled: config.attestationEnabled,
            attestationProvider: kmpAttestationProvider(config.attestationProvider),
            pinnedCertificateSha256Fingerprints: config.pinnedCertificateSHA256Fingerprints,
            automaticBrowserHandling: true,
            attStatus: nil,
            requestTrackingAuthorizationOnInit: false,
            trackingAuthorizationStatusTimeoutMs: 60_000,
            skan: nil,
            asaTokenCaptureEnabled: config.asaAttributionEnabled,
            doNotSell: nil,
            usPrivacy: nil
        )
    }

    // MARK: - attestation provider bridge

    /// Adapt a public Swift `AttriaxAttestationProvider` to the KMP provider protocol
    /// the config expects. Our own `AppAttestAttestationProvider` already wraps a KMP
    /// provider, so it is unwrapped directly; any other (custom) provider is wrapped.
    static func kmpAttestationProvider(
        _ provider: AttriaxAttestationProvider?
    ) -> AttriaxCore.AttriaxAttestationProvider? {
        guard let provider = provider else { return nil }
        if let appAttest = provider as? AppAttestAttestationProvider {
            return appAttest.kmpProvider
        }
        return SwiftAttestationProviderAdapter(provider)
    }

    // MARK: - enums

    static func attStatus(from status: AttriaxCore.AttriaxAttStatus) -> AttriaxAttStatus {
        AttriaxAttStatus(rawValue: status.wireValue) ?? .unknown
    }

    static func coarse(from value: AttriaxCore.AttriaxSkanCoarseValue?) -> AttriaxSkanCoarseValue? {
        guard let value = value else { return nil }
        return AttriaxSkanCoarseValue(rawValue: value.wireValue)
    }

    static func kmpCoarse(from value: AttriaxSkanCoarseValue?) -> AttriaxCore.AttriaxSkanCoarseValue? {
        switch value {
        case .some(.low): return AttriaxCore.AttriaxSkanCoarseValue.low
        case .some(.medium): return AttriaxCore.AttriaxSkanCoarseValue.medium
        case .some(.high): return AttriaxCore.AttriaxSkanCoarseValue.high
        case .none: return nil
        }
    }

    static func gdprState(from state: AttriaxCore.AttriaxGdprConsentState) -> AttriaxGdprConsentState {
        if state == AttriaxCore.AttriaxGdprConsentState.notRequired { return .notRequired }
        if state == AttriaxCore.AttriaxGdprConsentState.pending { return .pending }
        if state == AttriaxCore.AttriaxGdprConsentState.granted { return .granted }
        return .unknown
    }

    static func gdprValues(from values: AttriaxCore.AttriaxGdprConsentValues?) -> AttriaxGdprConsentValues? {
        guard let values = values else { return nil }
        return AttriaxGdprConsentValues(
            analytics: values.analytics,
            attribution: values.attribution,
            adEvents: values.adEvents
        )
    }

    static func trigger(from trigger: AttriaxCore.AttriaxDeepLinkTrigger) -> AttriaxDeepLinkTrigger {
        if trigger == AttriaxCore.AttriaxDeepLinkTrigger.coldStart { return .coldStart }
        if trigger == AttriaxCore.AttriaxDeepLinkTrigger.deferred { return .deferred }
        return .foreground
    }

    static func resolutionStatus(
        from status: AttriaxCore.AttriaxDeepLinkResolutionStatus
    ) -> AttriaxDeepLinkResolutionStatus {
        if status == AttriaxCore.AttriaxDeepLinkResolutionStatus.matched { return .matched }
        if status == AttriaxCore.AttriaxDeepLinkResolutionStatus.invalid { return .invalid }
        return .unmatched
    }

    static func openMode(from mode: AttriaxCore.AttriaxResolvedUrlOpenMode) -> AttriaxResolvedUrlOpenMode {
        if mode == AttriaxCore.AttriaxResolvedUrlOpenMode.inApp { return .inApp }
        if mode == AttriaxCore.AttriaxResolvedUrlOpenMode.external { return .external }
        return .unknown
    }

    static func kmpAdEventType(from type: AttriaxAdEventType) -> AttriaxCore.AttriaxAdEventType {
        switch type {
        case .request: return AttriaxCore.AttriaxAdEventType.request
        case .load: return AttriaxCore.AttriaxAdEventType.load_
        case .loadFailed: return AttriaxCore.AttriaxAdEventType.loadFailed
        case .show: return AttriaxCore.AttriaxAdEventType.show
        case .showFailed: return AttriaxCore.AttriaxAdEventType.showFailed
        case .impression: return AttriaxCore.AttriaxAdEventType.impression
        case .click: return AttriaxCore.AttriaxAdEventType.click
        case .dismiss: return AttriaxCore.AttriaxAdEventType.dismiss
        case .reward: return AttriaxCore.AttriaxAdEventType.reward
        }
    }

    static func kmpNotificationType(
        from type: AttriaxNotificationEventType
    ) -> AttriaxCore.AttriaxNotificationEventType {
        switch type {
        case .received: return AttriaxCore.AttriaxNotificationEventType.received
        case .opened: return AttriaxCore.AttriaxNotificationEventType.opened
        case .dismissed: return AttriaxCore.AttriaxNotificationEventType.dismissed
        }
    }

    static func kmpNotificationSource(
        from source: AttriaxNotificationEventSource?
    ) -> AttriaxCore.AttriaxNotificationEventSource? {
        switch source {
        case .some(.fcm): return AttriaxCore.AttriaxNotificationEventSource.fcm
        case .some(.apns): return AttriaxCore.AttriaxNotificationEventSource.apns
        case .some(.other): return AttriaxCore.AttriaxNotificationEventSource.other
        case .none: return nil
        }
    }

    // MARK: - value objects

    static func browserAction(from action: AttriaxCore.AttriaxBrowserAction?) -> AttriaxBrowserAction? {
        guard let action = action else { return nil }
        return AttriaxBrowserAction(url: action.url, openMode: openMode(from: action.openMode))
    }

    static func rawDeepLinkEvent(from event: AttriaxCore.AttriaxRawDeepLinkEvent) -> AttriaxRawDeepLinkEvent {
        AttriaxRawDeepLinkEvent(
            url: event.uri.raw,
            receivedAtMs: event.receivedAtMs,
            isInitial: event.isInitial
        )
    }

    static func deepLinkEvent(from event: AttriaxCore.AttriaxDeepLinkEvent) -> AttriaxDeepLinkEvent {
        AttriaxDeepLinkEvent(
            url: event.uri.raw,
            clickedAtMs: event.clickedAtMs,
            consumedAtMs: event.consumedAtMs,
            found: event.found,
            trigger: trigger(from: event.trigger),
            isAttriaxSubDomain: event.isAttriaxSubDomain,
            status: resolutionStatus(from: event.status),
            rawEvent: event.rawEvent.map(rawDeepLinkEvent(from:)),
            data: event.data,
            utm: event.utm,
            browserAction: browserAction(from: event.browserAction)
        )
    }

    static func createDynamicLinkResult(
        from result: AttriaxCore.AttriaxCreateDynamicLinkResult
    ) -> AttriaxCreateDynamicLinkResult {
        AttriaxCreateDynamicLinkResult(
            shortUrl: result.shortUrl,
            record: dynamicLinkRecord(from: result.record)
        )
    }

    static func dynamicLinkRecord(
        from record: AttriaxCore.AttriaxDynamicLinkRecord
    ) -> AttriaxDynamicLinkRecord {
        AttriaxDynamicLinkRecord(
            id: record.id,
            path: record.path,
            shortUrl: record.shortUrl,
            name: record.name,
            destinationUrl: record.destinationUrl,
            group: record.group,
            prefix: record.prefix,
            data: record.data
        )
    }

    static func kmpSocialPreview(
        from preview: AttriaxDynamicLinkSocialPreview?
    ) -> AttriaxCore.AttriaxDynamicLinkSocialPreview? {
        guard let preview = preview else { return nil }
        return AttriaxCore.AttriaxDynamicLinkSocialPreview(title: preview.title, description: preview.description)
    }

    static func kmpUtms(from utms: AttriaxDynamicLinkUtms?) -> AttriaxCore.AttriaxDynamicLinkUtms? {
        guard let utms = utms else { return nil }
        return AttriaxCore.AttriaxDynamicLinkUtms(
            source: utms.source,
            medium: utms.medium,
            campaign: utms.campaign,
            term: utms.term,
            content: utms.content
        )
    }

    static func kmpRedirects(
        from redirects: AttriaxDynamicLinkRedirects?
    ) -> AttriaxCore.AttriaxDynamicLinkRedirects? {
        guard let redirects = redirects else { return nil }
        return AttriaxCore.AttriaxDynamicLinkRedirects(
            ios: redirects.ios.map { KotlinBoolean(bool: $0) },
            android: redirects.android.map { KotlinBoolean(bool: $0) }
        )
    }

    // MARK: - receipt validation → decoded map (public API returns `Any?`)

    static func receiptResultDict(
        from result: AttriaxCore.AttriaxRevenueReceiptValidationResult
    ) -> [String: Any?] {
        [
            "validationId": result.validationId,
            "status": result.status.name.lowercased(),
            "requestVersion": result.requestVersion,
            "acceptedAt": iso(result.acceptedAtMs),
            "provider": result.provider,
            "environment": result.environment,
            "transactionId": result.transactionId,
            "originalTransactionId": result.originalTransactionId,
            "productId": result.productId,
            "failureReason": result.failureReason,
            "expiresAt": iso(result.expiresAtMs),
            "providerResult": result.providerResult,
            "publicReceipt": result.publicReceipt,
        ]
    }

    // MARK: - helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func iso(_ ms: KotlinLong?) -> String? {
        guard let ms = ms else { return nil }
        return isoFormatter.string(from: Date(timeIntervalSince1970: Double(ms.int64Value) / 1000.0))
    }

    /// Box an optional Swift `Bool` as the KMP `KotlinBoolean?` the ObjC surface wants.
    static func kbool(_ value: Bool?) -> KotlinBoolean? {
        value.map { KotlinBoolean(bool: $0) }
    }

    /// Box an optional Swift `Double` as the KMP `KotlinDouble?`.
    static func kdouble(_ value: Double?) -> KotlinDouble? {
        value.map { KotlinDouble(double: $0) }
    }

    /// Bridge a Swift `[String: Any?]` to the `[String: Any]` (NSDictionary) the KMP
    /// surface expects, mapping explicit-nil values to `NSNull` so they survive the
    /// Obj-C boundary (matching the Flutter plugin's channel encoding).
    static func objcMap(_ map: [String: Any?]?) -> [String: Any]? {
        guard let map = map else { return nil }
        var out = [String: Any]()
        for (key, value) in map { out[key] = value ?? NSNull() }
        return out
    }
}

/// Wraps a custom public Swift `AttriaxAttestationProvider` so the KMP config can
/// call it through the KMP provider protocol.
private final class SwiftAttestationProviderAdapter: NSObject, AttriaxCore.AttriaxAttestationProvider {
    private let provider: AttriaxAttestationProvider

    init(_ provider: AttriaxAttestationProvider) {
        self.provider = provider
    }

    func attest(nonce: String) -> AttriaxCore.AttriaxAttestationToken? {
        guard let token = provider.attest(nonce: nonce) else { return nil }
        return AttriaxCore.AttriaxAttestationToken(token: token.token, keyId: token.keyId)
    }
}

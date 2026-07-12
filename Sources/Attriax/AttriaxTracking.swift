import Foundation
import AttriaxCore

/// Public tracking, revenue, notification, error, and identify surface
/// (PARITY §4, rows E1–E6). A thin forward to the KMP core's `AttriaxTracking`,
/// which owns the reserved-name lowering, currency normalization, and consent-gated
/// enqueue. Parameter names/signatures are preserved from the standalone SDK.
public final class AttriaxTracking {
    private let core: AttriaxCore.Attriax

    init(core: AttriaxCore.Attriax) {
        self.core = core
    }

    /// Whether event-style tracking is currently enabled.
    public var enabled: Bool {
        get { core.tracking.enabled }
        set { core.tracking.enabled = newValue }
    }

    // MARK: - events / page views

    public func recordEvent(
        _ name: String,
        eventData: [String: Any?]? = nil,
        flushImmediately: Bool = false
    ) {
        core.tracking.recordEvent(
            name: name,
            eventData: AttriaxBridge.objcMap(eventData),
            flushImmediately: flushImmediately
        )
    }

    public func recordPageView(
        pageName: String,
        pageClass: String? = nil,
        pageTitle: String? = nil,
        previousPageName: String? = nil,
        parameters: [String: Any?]? = nil,
        source: String = "manual",
        flushImmediately: Bool = false
    ) {
        core.tracking.recordPageView(
            pageName: pageName,
            pageClass: pageClass,
            pageTitle: pageTitle,
            previousPageName: previousPageName,
            parameters: AttriaxBridge.objcMap(parameters),
            source: source,
            flushImmediately: flushImmediately
        )
    }

    // MARK: - revenue

    public func recordPurchase(
        revenue: Double,
        currency: String = "USD",
        revenueInMicros: Bool = false,
        purchaseType: String? = nil,
        productId: String? = nil,
        transactionId: String? = nil,
        originalTransactionId: String? = nil,
        validationProvider: String? = nil,
        validationEnvironment: String? = nil,
        purchaseToken: String? = nil,
        receiptData: String? = nil,
        signedPayload: String? = nil,
        receiptSignature: String? = nil,
        isRenewal: Bool? = nil,
        quantity: Int = 1,
        store: String? = nil,
        packageName: String? = nil,
        voided: Bool? = nil,
        test: Bool? = nil,
        validationId: String? = nil,
        metadata: [String: Any?]? = nil,
        flushImmediately: Bool = true
    ) {
        core.tracking.recordPurchase(
            revenue: revenue,
            currency: currency,
            revenueInMicros: revenueInMicros,
            purchaseType: purchaseType,
            productId: productId,
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            validationProvider: validationProvider,
            validationEnvironment: validationEnvironment,
            purchaseToken: purchaseToken,
            receiptData: receiptData,
            signedPayload: signedPayload,
            receiptSignature: receiptSignature,
            isRenewal: AttriaxBridge.kbool(isRenewal),
            quantity: Int32(quantity),
            store: store,
            packageName: packageName,
            voided: AttriaxBridge.kbool(voided),
            test: AttriaxBridge.kbool(test),
            validationId: validationId,
            metadata: AttriaxBridge.objcMap(metadata),
            flushImmediately: flushImmediately
        )
    }

    public func recordRefund(
        revenue: Double,
        currency: String = "USD",
        revenueInMicros: Bool = false,
        purchaseType: String? = nil,
        productId: String? = nil,
        transactionId: String? = nil,
        originalTransactionId: String? = nil,
        quantity: Int = 1,
        store: String? = nil,
        packageName: String? = nil,
        voided: Bool? = nil,
        test: Bool? = nil,
        reason: String? = nil,
        metadata: [String: Any?]? = nil,
        flushImmediately: Bool = true
    ) {
        core.tracking.recordRefund(
            revenue: revenue,
            currency: currency,
            revenueInMicros: revenueInMicros,
            purchaseType: purchaseType,
            productId: productId,
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            quantity: Int32(quantity),
            store: store,
            packageName: packageName,
            voided: AttriaxBridge.kbool(voided),
            test: AttriaxBridge.kbool(test),
            reason: reason,
            metadata: AttriaxBridge.objcMap(metadata),
            flushImmediately: flushImmediately
        )
    }

    public func recordAdRevenue(
        revenue: Double,
        currency: String = "USD",
        revenueInMicros: Bool = false,
        adNetwork: String? = nil,
        adFormat: String? = nil,
        adType: String? = nil,
        adPlacement: String? = nil,
        test: Bool? = nil,
        metadata: [String: Any?]? = nil,
        flushImmediately: Bool = true
    ) {
        core.tracking.recordAdRevenue(
            revenue: revenue,
            currency: currency,
            revenueInMicros: revenueInMicros,
            adNetwork: adNetwork,
            adFormat: adFormat,
            adType: adType,
            adPlacement: adPlacement,
            test: AttriaxBridge.kbool(test),
            metadata: AttriaxBridge.objcMap(metadata),
            flushImmediately: flushImmediately
        )
    }

    public func recordAdEvent(
        type: AttriaxAdEventType,
        adNetwork: String? = nil,
        mediationNetwork: String? = nil,
        adUnitId: String? = nil,
        adPlacement: String? = nil,
        adFormat: String? = nil,
        adType: String? = nil,
        failureReason: String? = nil,
        loadLatencyMs: Double? = nil,
        rewardType: String? = nil,
        rewardAmount: Double? = nil,
        test: Bool? = nil,
        metadata: [String: Any?]? = nil,
        flushImmediately: Bool = true
    ) {
        core.tracking.recordAdEvent(
            type: AttriaxBridge.kmpAdEventType(from: type),
            adNetwork: adNetwork,
            mediationNetwork: mediationNetwork,
            adUnitId: adUnitId,
            adPlacement: adPlacement,
            adFormat: adFormat,
            adType: adType,
            failureReason: failureReason,
            loadLatencyMs: AttriaxBridge.kdouble(loadLatencyMs),
            rewardType: rewardType,
            rewardAmount: AttriaxBridge.kdouble(rewardAmount),
            test: AttriaxBridge.kbool(test),
            metadata: AttriaxBridge.objcMap(metadata),
            flushImmediately: flushImmediately
        )
    }

    // MARK: - errors / crashes

    public func recordError(
        _ error: Error,
        stackTrace: String? = nil,
        fatal: Bool = false,
        source: String = "manual",
        reason: String? = nil,
        metadata: [String: Any?]? = nil
    ) {
        let nsError = error as NSError
        let message = (error as? LocalizedError)?.errorDescription ?? nsError.localizedDescription
        core.tracking.recordError(
            error: KotlinThrowable(message: message),
            stackTrace: stackTrace ?? Thread.callStackSymbols.joined(separator: "\n"),
            fatal: fatal,
            source: source,
            reason: reason,
            metadata: AttriaxBridge.objcMap(metadata)
        )
    }

    // MARK: - notifications

    public func recordNotification(
        type: AttriaxNotificationEventType,
        notificationId: String,
        linkId: String? = nil,
        campaignId: String? = nil,
        title: String? = nil,
        source: AttriaxNotificationEventSource? = nil,
        payload: [String: Any?]? = nil,
        metadata: [String: Any?]? = nil,
        flushImmediately: Bool = false
    ) {
        core.tracking.recordNotification(
            type: AttriaxBridge.kmpNotificationType(from: type),
            notificationId: notificationId,
            linkId: linkId,
            campaignId: campaignId,
            title: title,
            source: AttriaxBridge.kmpNotificationSource(from: source),
            payload: AttriaxBridge.objcMap(payload),
            metadata: AttriaxBridge.objcMap(metadata),
            flushImmediately: flushImmediately
        )
    }

    public func recordNotificationReceived(
        notificationId: String,
        linkId: String? = nil,
        campaignId: String? = nil,
        title: String? = nil,
        source: AttriaxNotificationEventSource? = nil,
        payload: [String: Any?]? = nil,
        metadata: [String: Any?]? = nil,
        flushImmediately: Bool = false
    ) {
        recordNotification(
            type: .received, notificationId: notificationId, linkId: linkId, campaignId: campaignId,
            title: title, source: source, payload: payload, metadata: metadata, flushImmediately: flushImmediately
        )
    }

    public func recordNotificationOpened(
        notificationId: String,
        linkId: String? = nil,
        campaignId: String? = nil,
        title: String? = nil,
        source: AttriaxNotificationEventSource? = nil,
        payload: [String: Any?]? = nil,
        metadata: [String: Any?]? = nil,
        flushImmediately: Bool = false
    ) {
        recordNotification(
            type: .opened, notificationId: notificationId, linkId: linkId, campaignId: campaignId,
            title: title, source: source, payload: payload, metadata: metadata, flushImmediately: flushImmediately
        )
    }

    public func recordNotificationDismissed(
        notificationId: String,
        linkId: String? = nil,
        campaignId: String? = nil,
        title: String? = nil,
        source: AttriaxNotificationEventSource? = nil,
        payload: [String: Any?]? = nil,
        metadata: [String: Any?]? = nil,
        flushImmediately: Bool = false
    ) {
        recordNotification(
            type: .dismissed, notificationId: notificationId, linkId: linkId, campaignId: campaignId,
            title: title, source: source, payload: payload, metadata: metadata, flushImmediately: flushImmediately
        )
    }

    // MARK: - identify

    /// Associate the current device with a user. `userId == nil` clears it.
    public func setUser(userId: String?, userName: String? = nil) {
        core.tracking.setUser(userId: userId, userName: userName)
    }

    /// Set a single user property; a nil value clears the named property.
    public func setUserProperty(name: String, value: Any?) {
        core.tracking.setUserProperty(name: name, value: value)
    }

    /// Merge user properties into future events.
    public func setUserProperties(_ properties: [String: Any?]) {
        core.tracking.setUserProperties(properties: AttriaxBridge.objcMap(properties) ?? [:])
    }

    /// Clear user properties. nil/empty `propertyNames` clears ALL stored properties.
    public func clearUserProperties(propertyNames: [String]? = nil) {
        core.tracking.clearUserProperties(propertyNames: propertyNames)
    }

    // MARK: - uninstall token

    /// Register (or, with a nil token, de-register) the APNs uninstall-tracking token.
    public func registerApnsToken(_ token: String?, metadata: [String: Any?]? = nil) {
        core.tracking.registerApplePushToken(token: token, metadata: AttriaxBridge.objcMap(metadata))
    }
}

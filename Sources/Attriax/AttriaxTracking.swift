import Foundation

/// Public tracking, revenue, notification, error, and identify surface
/// (PARITY §4, rows E1–E6). Mirrors the Flutter/Android reference `AttriaxTracking`.
///
/// Every standardized helper (`recordPurchase`/`recordRefund`/`recordAdRevenue`/
/// `recordAdEvent`/`recordPageView`) LOWERS to `recordEvent` with the reserved
/// event names + param keys — there is no separate revenue endpoint for tracked
/// purchases. Requests traverse the same frozen-identity queue + dispatcher as the
/// engine; only `Attriax.validateReceipt` bypasses the queue.
///
/// Consent-driven anonymous capture arrives in CHUNK B; this surface honors the
/// engine `enabled` flag and stamps the frozen build-time identity the engine
/// already resolved.
public final class AttriaxTracking {
    private unowned let engine: Attriax

    init(engine: Attriax) {
        self.engine = engine
    }

    /// Whether event-style tracking is currently enabled (delegates to the engine).
    public var enabled: Bool {
        get { engine.enabled }
        set { engine.enabled = newValue }
    }

    // MARK: - events / page views

    public func recordEvent(
        _ name: String,
        eventData: [String: Any?]? = nil,
        flushImmediately: Bool = false
    ) {
        guard engine.isTrackingEnabled else { return }
        engine.recordEvent(name, eventData: eventData, flushImmediately: flushImmediately)
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
        let normalizedPageName = pageName.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedPageName.isEmpty, "pageName must not be empty.")

        var eventData = [String: Any?]()
        if let parameters = parameters { for (k, v) in parameters { eventData[k] = v } }
        eventData[AttriaxAnalyticsParamKeys.pageName] = normalizedPageName
        if let v = AttriaxRevenue.trimOrNull(pageClass) { eventData[AttriaxAnalyticsParamKeys.pageClass] = v }
        if let v = AttriaxRevenue.trimOrNull(pageTitle) { eventData[AttriaxAnalyticsParamKeys.pageTitle] = v }
        if let v = AttriaxRevenue.trimOrNull(previousPageName) { eventData[AttriaxAnalyticsParamKeys.previousPageName] = v }
        eventData[AttriaxAnalyticsParamKeys.source] = source

        recordEvent(AttriaxAnalyticsEventKeys.pageView, eventData: eventData, flushImmediately: flushImmediately)
    }

    // MARK: - revenue (lowered to recordEvent; rows E1/E2/E3)

    /// Record a completed purchase (row E1). Flushes immediately by default.
    /// Currency is validated `^[A-Z]{3}$` else revenue is forced to `0 USD` (row E3).
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
        precondition(revenue.isFinite, "revenue must be finite.")
        precondition(quantity > 0, "quantity must be positive.")
        let normalized = normalizeRevenueCurrency(revenue, currency)

        var eventData = [String: Any?]()
        if let metadata = metadata { for (k, v) in metadata { eventData[k] = v } }
        eventData[AttriaxAnalyticsParamKeys.revenue] = normalized.revenue
        eventData[AttriaxAnalyticsParamKeys.currency] = normalized.currency
        if revenueInMicros { eventData[AttriaxAnalyticsParamKeys.revenueInMicros] = true }
        if let v = AttriaxRevenue.trimOrNull(purchaseType) { eventData[AttriaxAnalyticsParamKeys.purchaseType] = v }
        if let v = AttriaxRevenue.trimOrNull(productId) { eventData[AttriaxAnalyticsParamKeys.productId] = v }
        if let v = AttriaxRevenue.trimOrNull(transactionId) { eventData[AttriaxAnalyticsParamKeys.transactionId] = v }
        if let v = AttriaxRevenue.trimOrNull(originalTransactionId) { eventData[AttriaxAnalyticsParamKeys.originalTransactionId] = v }
        if let v = AttriaxRevenue.trimOrNull(validationProvider) { eventData[AttriaxAnalyticsParamKeys.validationProvider] = v }
        if let v = AttriaxRevenue.trimOrNull(validationEnvironment) { eventData[AttriaxAnalyticsParamKeys.validationEnvironment] = v }
        if let v = AttriaxRevenue.trimOrNull(purchaseToken) { eventData[AttriaxAnalyticsParamKeys.purchaseToken] = v }
        if let v = AttriaxRevenue.trimOrNull(receiptData) { eventData[AttriaxAnalyticsParamKeys.receiptData] = v }
        if let v = AttriaxRevenue.trimOrNull(signedPayload) { eventData[AttriaxAnalyticsParamKeys.signedPayload] = v }
        if let v = AttriaxRevenue.trimOrNull(receiptSignature) { eventData[AttriaxAnalyticsParamKeys.receiptSignature] = v }
        if let isRenewal = isRenewal { eventData[AttriaxAnalyticsParamKeys.isRenewal] = isRenewal }
        if quantity != 1 { eventData[AttriaxAnalyticsParamKeys.quantity] = quantity }
        if let v = AttriaxRevenue.trimOrNull(store) { eventData[AttriaxAnalyticsParamKeys.store] = v }
        if let v = AttriaxRevenue.trimOrNull(packageName) { eventData[AttriaxAnalyticsParamKeys.packageName] = v }
        if let voided = voided { eventData[AttriaxAnalyticsParamKeys.voided] = voided }
        if let test = test { eventData[AttriaxAnalyticsParamKeys.test] = test }
        if let v = AttriaxRevenue.trimOrNull(validationId) { eventData[AttriaxAnalyticsParamKeys.validationId] = v }

        recordEvent(AttriaxAnalyticsEventKeys.purchase, eventData: eventData, flushImmediately: flushImmediately)
    }

    /// Record a refund (row E2): the revenue is NEGATED (`0` preserved as `0`) and
    /// tagged `revenueType=refund`. Flushes immediately by default.
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
        precondition(revenue.isFinite, "revenue must be finite.")
        precondition(quantity > 0, "quantity must be positive.")
        let normalized = normalizeRevenueCurrency(revenue, currency)
        let refundRevenue = AttriaxRevenue.refundRevenue(normalized.revenue)

        var eventData = [String: Any?]()
        if let metadata = metadata { for (k, v) in metadata { eventData[k] = v } }
        eventData[AttriaxAnalyticsParamKeys.revenue] = refundRevenue
        eventData[AttriaxAnalyticsParamKeys.currency] = normalized.currency
        eventData[AttriaxAnalyticsParamKeys.revenueType] = AttriaxAnalyticsEventKeys.refund
        if revenueInMicros { eventData[AttriaxAnalyticsParamKeys.revenueInMicros] = true }
        if let v = AttriaxRevenue.trimOrNull(purchaseType) { eventData[AttriaxAnalyticsParamKeys.purchaseType] = v }
        if let v = AttriaxRevenue.trimOrNull(productId) { eventData[AttriaxAnalyticsParamKeys.productId] = v }
        if let v = AttriaxRevenue.trimOrNull(transactionId) { eventData[AttriaxAnalyticsParamKeys.transactionId] = v }
        if let v = AttriaxRevenue.trimOrNull(originalTransactionId) { eventData[AttriaxAnalyticsParamKeys.originalTransactionId] = v }
        if quantity != 1 { eventData[AttriaxAnalyticsParamKeys.quantity] = quantity }
        if let v = AttriaxRevenue.trimOrNull(store) { eventData[AttriaxAnalyticsParamKeys.store] = v }
        if let v = AttriaxRevenue.trimOrNull(packageName) { eventData[AttriaxAnalyticsParamKeys.packageName] = v }
        if let voided = voided { eventData[AttriaxAnalyticsParamKeys.voided] = voided }
        if let test = test { eventData[AttriaxAnalyticsParamKeys.test] = test }
        if let v = AttriaxRevenue.trimOrNull(reason) { eventData[AttriaxAnalyticsParamKeys.reason] = v }

        recordEvent(AttriaxAnalyticsEventKeys.refund, eventData: eventData, flushImmediately: flushImmediately)
    }

    /// Record realized ad revenue (row E1). Flushes immediately by default.
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
        precondition(revenue.isFinite, "revenue must be finite.")
        let normalized = normalizeRevenueCurrency(revenue, currency)

        var eventData = [String: Any?]()
        if let metadata = metadata { for (k, v) in metadata { eventData[k] = v } }
        eventData[AttriaxAnalyticsParamKeys.revenue] = normalized.revenue
        eventData[AttriaxAnalyticsParamKeys.currency] = normalized.currency
        if revenueInMicros { eventData[AttriaxAnalyticsParamKeys.revenueInMicros] = true }
        if let v = AttriaxRevenue.trimOrNull(adNetwork) { eventData[AttriaxAnalyticsParamKeys.adNetwork] = v }
        if let v = AttriaxRevenue.trimOrNull(adFormat) { eventData[AttriaxAnalyticsParamKeys.adFormat] = v }
        if let v = AttriaxRevenue.trimOrNull(adType) { eventData[AttriaxAnalyticsParamKeys.adType] = v }
        if let v = AttriaxRevenue.trimOrNull(adPlacement) { eventData[AttriaxAnalyticsParamKeys.adPlacement] = v }
        if let test = test { eventData[AttriaxAnalyticsParamKeys.test] = test }

        recordEvent(AttriaxAnalyticsEventKeys.adRevenue, eventData: eventData, flushImmediately: flushImmediately)
    }

    /// Record an ad-lifecycle event under its reserved name (row E1). Flushes
    /// immediately by default.
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
        precondition(loadLatencyMs == nil || loadLatencyMs!.isFinite, "loadLatencyMs must be finite.")
        precondition(rewardAmount == nil || rewardAmount!.isFinite, "rewardAmount must be finite.")

        var eventData = [String: Any?]()
        if let metadata = metadata { for (k, v) in metadata { eventData[k] = v } }
        if let v = AttriaxRevenue.trimOrNull(adNetwork) { eventData[AttriaxAnalyticsParamKeys.adNetwork] = v }
        if let v = AttriaxRevenue.trimOrNull(mediationNetwork) { eventData[AttriaxAnalyticsParamKeys.mediationNetwork] = v }
        if let v = AttriaxRevenue.trimOrNull(adUnitId) { eventData[AttriaxAnalyticsParamKeys.adUnitId] = v }
        if let v = AttriaxRevenue.trimOrNull(adPlacement) { eventData[AttriaxAnalyticsParamKeys.adPlacement] = v }
        if let v = AttriaxRevenue.trimOrNull(adFormat) { eventData[AttriaxAnalyticsParamKeys.adFormat] = v }
        if let v = AttriaxRevenue.trimOrNull(adType) { eventData[AttriaxAnalyticsParamKeys.adType] = v }
        if let v = AttriaxRevenue.trimOrNull(failureReason) { eventData[AttriaxAnalyticsParamKeys.failureReason] = v }
        if let v = AttriaxRevenue.trimOrNull(rewardType) { eventData[AttriaxAnalyticsParamKeys.rewardType] = v }
        if let loadLatencyMs = loadLatencyMs { eventData[AttriaxAnalyticsParamKeys.loadLatencyMs] = loadLatencyMs }
        if let rewardAmount = rewardAmount { eventData[AttriaxAnalyticsParamKeys.rewardAmount] = rewardAmount }
        if let test = test { eventData[AttriaxAnalyticsParamKeys.test] = test }

        recordEvent(type.eventName, eventData: eventData, flushImmediately: flushImmediately)
    }

    // MARK: - errors / crashes (POST /api/sdk/v1/crashes)

    public func recordError(
        _ error: Error,
        stackTrace: String? = nil,
        fatal: Bool = false,
        source: String = "manual",
        reason: String? = nil,
        metadata: [String: Any?]? = nil
    ) {
        guard engine.isTrackingEnabled else { return }
        let nsError = error as NSError
        let request = AttriaxRequestBuilders.buildCrash(
            projectToken: engine.projectTokenForTracking,
            context: engine.contextSnapshot,
            deviceId: engine.resolvedDeviceId,
            deviceIdSource: engine.resolvedDeviceIdSource,
            source: AttriaxRevenue.trimOrNull(source) ?? "manual",
            isFatal: fatal,
            exceptionType: "\(nsError.domain)",
            message: (error as? LocalizedError)?.errorDescription ?? nsError.localizedDescription,
            stackTrace: stackTrace ?? Thread.callStackSymbols.joined(separator: "\n"),
            isFirstLaunch: engine.isFirstLaunch,
            clientOccurredAtIso: engine.nowIso(),
            reason: AttriaxRevenue.trimOrNull(reason),
            sessionId: nil,
            sessionRelativeTimeMs: nil,
            metadata: metadata
        )
        engine.enqueueRequest(request, flushImmediately: false)
    }

    // MARK: - notifications (POST /api/sdk/v1/notifications; rows E6)

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
        guard engine.isTrackingEnabled else { return }
        let normalizedNotificationId = notificationId.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedNotificationId.isEmpty, "notificationId must not be empty.")

        let resolvedSource = source ?? AttriaxRevenue.inferNotificationSource(payload)
        let mergedMetadata = AttriaxRevenue.mergeNotificationMetadata(metadata: metadata, payload: payload)

        let request = AttriaxRequestBuilders.buildNotification(
            projectToken: engine.projectTokenForTracking,
            platform: engine.contextSnapshot.platform,
            type: type.wireValue,
            notificationId: normalizedNotificationId,
            deviceId: engine.resolvedDeviceId,
            deviceIdSource: engine.resolvedDeviceIdSource,
            linkId: AttriaxRevenue.trimOrNull(linkId),
            campaignId: AttriaxRevenue.trimOrNull(campaignId),
            title: AttriaxRevenue.trimOrNull(title),
            source: resolvedSource?.wireValue,
            sessionId: nil,
            occurredAtIso: engine.nowIso(),
            metadata: mergedMetadata
        )
        engine.enqueueRequest(request, flushImmediately: flushImmediately)
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

    // MARK: - identify (POST /api/sdk/v1/users)

    /// Associate the current device with a user. `userId == nil` clears it.
    public func setUser(userId: String?, userName: String? = nil) {
        guard engine.isTrackingEnabled else { return }
        enqueueUserUpdate(
            externalUserId: AttriaxRevenue.trimOrNull(userId),
            externalUserName: AttriaxRevenue.trimOrNull(userName),
            clearExternalUser: userId == nil
        )
    }

    /// Set a single user property; a nil value clears the named property.
    public func setUserProperty(name: String, value: Any?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return }
        if value == nil {
            clearUserProperties(propertyNames: [trimmedName])
            return
        }
        setUserProperties([trimmedName: value])
    }

    /// Merge user properties into future events (blank keys dropped).
    public func setUserProperties(_ properties: [String: Any?]) {
        guard engine.isTrackingEnabled else { return }
        var sanitized = [String: Any?]()
        for (key, value) in properties {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sanitized[trimmed] = value }
        }
        if sanitized.isEmpty { return }
        enqueueUserUpdate(properties: sanitized)
    }

    /// Clear user properties. nil/empty `propertyNames` clears ALL stored properties.
    public func clearUserProperties(propertyNames: [String]? = nil) {
        guard engine.isTrackingEnabled else { return }
        let normalized = propertyNames?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let effective = (normalized?.isEmpty ?? true) ? nil : normalized
        enqueueUserUpdate(
            clearPropertyKeys: effective,
            clearAllProperties: effective == nil
        )
    }

    // MARK: - uninstall token (POST /api/sdk/v1/uninstall-tokens)

    /// Register (or, with a nil token, de-register) the APNs uninstall-tracking
    /// token. The iOS equivalent of the Android FCM token → same endpoint,
    /// provider `apns`.
    public func registerApnsToken(_ token: String?, metadata: [String: Any?]? = nil) {
        guard engine.isTrackingEnabled else { return }
        guard let deviceId = engine.resolvedDeviceId else { return }
        let request = AttriaxRequestBuilders.buildUninstallToken(
            projectToken: engine.projectTokenForTracking,
            deviceId: deviceId,
            deviceIdSource: engine.resolvedDeviceIdSource,
            platform: engine.contextSnapshot.platform,
            provider: Self.uninstallTokenProviderApns,
            token: AttriaxRevenue.trimOrNull(token),
            metadata: metadata
        )
        engine.enqueueRequest(request, flushImmediately: false)
    }

    // MARK: - internals

    private func enqueueUserUpdate(
        externalUserId: String? = nil,
        externalUserName: String? = nil,
        clearExternalUser: Bool = false,
        properties: [String: Any?]? = nil,
        clearPropertyKeys: [String]? = nil,
        clearAllProperties: Bool = false
    ) {
        // SdkUserDto requires deviceId; identify is not part of the anonymous-capable
        // signal set, so it needs the resolved identity.
        guard let deviceId = engine.resolvedDeviceId else { return }
        let request = AttriaxRequestBuilders.buildUser(
            projectToken: engine.projectTokenForTracking,
            externalUserId: externalUserId,
            externalUserName: externalUserName,
            properties: properties,
            deviceId: deviceId,
            deviceIdSource: engine.resolvedDeviceIdSource,
            clearExternalUser: clearExternalUser,
            clearPropertyKeys: clearPropertyKeys,
            clearAllProperties: clearAllProperties
        )
        engine.enqueueRequest(request, flushImmediately: false)
    }

    /// Validate `currency` and warn on the invalid → 0 USD default (row E3). The
    /// pure normalization lives in `AttriaxRevenue`; the warning is the only side
    /// effect kept here so the lowering stays unit-testable.
    private func normalizeRevenueCurrency(_ revenue: Double, _ currency: String) -> AttriaxRevenue.NormalizedRevenue {
        if !AttriaxRevenue.isValidCurrency(currency) {
            FileHandle.standardError.write(
                Data("[Attriax][WARNING] Invalid revenue currency \"\(currency)\"; defaulting revenue to 0 USD.\n".utf8)
            )
        }
        return AttriaxRevenue.normalizeRevenueCurrency(revenue, currency)
    }

    private static let uninstallTokenProviderApns = "apns"
}

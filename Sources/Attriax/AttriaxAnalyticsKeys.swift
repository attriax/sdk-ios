import Foundation

/// Reserved analytics event names used by the standardized tracking helpers
/// (PARITY §4, row E1). Mirrors the Flutter/Android reserved keys exactly. Keep
/// in sync across SDKs so dashboard funnels, SKAN rules, and revenue rollups
/// agree on names.
public enum AttriaxAnalyticsEventKeys {
    public static let signUp = "sign_up"
    public static let login = "login"
    public static let tutorialBegin = "tutorial_begin"
    public static let tutorialComplete = "tutorial_complete"
    public static let levelStart = "level_start"
    public static let levelComplete = "level_complete"
    public static let levelUp = "level_up"
    public static let addPaymentInfo = "add_payment_info"
    public static let addToCart = "add_to_cart"
    public static let checkoutStarted = "checkout_started"
    public static let purchase = "purchase"
    public static let refund = "refund"
    public static let subscriptionStarted = "subscription_started"
    public static let subscriptionRenewed = "subscription_renewed"
    public static let trialStarted = "trial_started"
    public static let adRequest = "ad_request"
    public static let adLoad = "ad_load"
    public static let adLoadFailed = "ad_load_failed"
    public static let adShow = "ad_show"
    public static let adShowFailed = "ad_show_failed"
    public static let adImpression = "ad_impression"
    public static let adClick = "ad_click"
    public static let adDismiss = "ad_dismiss"
    public static let adReward = "ad_reward"
    public static let adRevenue = "ad_revenue"
    public static let pageView = "page_view"
}

/// Reserved analytics payload keys used by the standardized tracking helpers
/// (PARITY §4, rows E2/E3). Mirrors the Flutter/Android param keys exactly.
public enum AttriaxAnalyticsParamKeys {
    public static let revenue = "revenue"
    public static let currency = "currency"
    public static let revenueInMicros = "revenueInMicros"
    public static let revenueType = "revenueType"
    public static let purchaseType = "purchaseType"
    public static let method = "method"
    public static let paymentType = "paymentType"
    public static let productId = "productId"
    public static let transactionId = "transactionId"
    public static let originalTransactionId = "originalTransactionId"
    public static let validationProvider = "validationProvider"
    public static let validationEnvironment = "validationEnvironment"
    public static let purchaseToken = "purchaseToken"
    public static let receiptData = "receiptData"
    public static let signedPayload = "signedPayload"
    public static let receiptSignature = "receiptSignature"
    public static let isRenewal = "isRenewal"
    public static let quantity = "quantity"
    public static let store = "store"
    public static let packageName = "packageName"
    public static let voided = "voided"
    public static let test = "test"
    public static let validationId = "validationId"
    public static let reason = "reason"
    public static let adNetwork = "adNetwork"
    public static let mediationNetwork = "mediationNetwork"
    public static let adUnitId = "adUnitId"
    public static let adPlacement = "adPlacement"
    public static let adFormat = "adFormat"
    public static let adType = "adType"
    public static let failureReason = "failureReason"
    public static let loadLatencyMs = "loadLatencyMs"
    public static let rewardType = "rewardType"
    public static let rewardAmount = "rewardAmount"
    public static let pageName = "pageName"
    public static let pageClass = "pageClass"
    public static let pageTitle = "pageTitle"
    public static let previousPageName = "previousPageName"
    public static let source = "source"
    public static let level = "level"
    public static let value = "value"
}

/// Canonical ad-lifecycle events tracked by `AttriaxTracking.recordAdEvent`.
/// Mirrors the Flutter/Android `AttriaxAdEventType`.
public enum AttriaxAdEventType {
    case request
    case load
    case loadFailed
    case show
    case showFailed
    case impression
    case click
    case dismiss
    case reward

    var eventName: String {
        switch self {
        case .request: return AttriaxAnalyticsEventKeys.adRequest
        case .load: return AttriaxAnalyticsEventKeys.adLoad
        case .loadFailed: return AttriaxAnalyticsEventKeys.adLoadFailed
        case .show: return AttriaxAnalyticsEventKeys.adShow
        case .showFailed: return AttriaxAnalyticsEventKeys.adShowFailed
        case .impression: return AttriaxAnalyticsEventKeys.adImpression
        case .click: return AttriaxAnalyticsEventKeys.adClick
        case .dismiss: return AttriaxAnalyticsEventKeys.adDismiss
        case .reward: return AttriaxAnalyticsEventKeys.adReward
        }
    }
}

/// Push-notification lifecycle stages attributed by `AttriaxTracking`.
/// Wire values match the api `NotificationEventType` enum.
public enum AttriaxNotificationEventType {
    case received
    case opened
    case dismissed

    var wireValue: String {
        switch self {
        case .received: return "received"
        case .opened: return "opened"
        case .dismissed: return "dismissed"
        }
    }
}

/// Delivery channel a push notification arrived through. Wire values match the
/// api `NotificationEventSource` enum. Inferred from the raw payload when omitted
/// (`aps` → apns; `google.`/`gcm.` → fcm; PARITY row E6).
public enum AttriaxNotificationEventSource {
    case fcm
    case apns
    case other

    var wireValue: String {
        switch self {
        case .fcm: return "fcm"
        case .apns: return "apns"
        case .other: return "other"
        }
    }
}

import Foundation

/// Pure builders that assemble the JSON body maps for the core request kinds
/// (PARITY §3/§4, rows E4/E5). Field placement matters:
///  - event/user payloads OMIT platform/version by design (backend derives from
///    AppUser); open/session/crash carry the full context.
///  - identity fields (`projectToken`/`deviceId`/`deviceIdSource`) are stamped at
///    BUILD time and frozen (row D3) — never re-stamped at flush.
///
/// Wire shapes confirmed against the api DTOs under `api/src/modules/sdk/dto/`:
/// `SdkV1OpenDto` (nested sdk/app/device), `SdkEventDto`, `SdkSessionDto`,
/// `SdkUserDto`, `SdkCrashDto`, `SdkNotificationDto`, `SdkRegisterUninstallTokenDto`,
/// `SdkV1RevenueReceiptValidateDto`. Unknown top-level props are rejected by the
/// backend whitelist validation, so absent optionals are OMITTED, not sent null.
enum AttriaxRequestBuilders {

    /// App-open (`/api/sdk/v1/open`) — carries full context + identity + session
    /// hints. NESTS context under `sdk`/`app`/`device` sub-objects (the api rejects
    /// unknown top-level properties). iOS `platform` = "ios".
    static func buildOpen(
        projectToken: String,
        context: AttriaxContextSnapshot,
        deviceId: String,
        deviceIdSource: String,
        isFirstLaunch: Bool,
        sessionId: String?,
        sessionStartedAtIso: String?,
        attestation: AttriaxJSONObject? = nil
    ) -> AttriaxApiRequest {
        var body = AttriaxJSONObject()
        body["projectToken"] = projectToken
        body["platform"] = context.platform
        body["deviceId"] = deviceId
        body["deviceIdSource"] = deviceIdSource
        body["isFirstLaunch"] = isFirstLaunch

        body["sdk"] = [
            "apiVersion": context.sdkApiVersion,
            "packageVersion": context.sdkPackageVersion,
        ] as AttriaxJSONObject

        var app = AttriaxJSONObject()
        if let v = context.appVersion { app["version"] = v }
        if let b = context.appBuildNumber { app["buildNumber"] = b }
        if let p = context.packageName { app["packageName"] = p }
        body["app"] = app

        var device = AttriaxJSONObject()
        if let m = context.deviceModel { device["model"] = m }
        if let mf = context.deviceManufacturer { device["manufacturer"] = mf }
        device["osVersion"] = context.osVersion
        if let tz = context.deviceTimezone { device["timezone"] = tz }
        // DeviceContextDto names this `language` (not `locale`).
        if let lang = context.deviceLocale { device["language"] = lang }
        body["device"] = device

        if let sid = sessionId { body["sessionId"] = sid }
        if let started = sessionStartedAtIso { body["sessionStartedAt"] = started }
        if let att = attestation { body["attestation"] = att }
        return AttriaxApiRequest(kind: AttriaxApiRequest.kindOpen, path: AttriaxEndpoints.open, body: body)
    }

    /// Event (`/api/sdk/v1/events`). platform/version OMITTED (row E4). Identity is
    /// nullable to support anonymous capture, but batching requires it present.
    static func buildEvent(
        projectToken: String,
        eventName: String,
        eventData: AttriaxJSONObject?,
        deviceId: String?,
        deviceIdSource: String?,
        sessionId: String?,
        sessionRelativeTimeMs: Int64?,
        clientOccurredAtIso: String
    ) -> AttriaxApiRequest {
        var body = AttriaxJSONObject()
        body["projectToken"] = projectToken
        body["eventName"] = eventName
        if let data = eventData { body["eventData"] = data }
        if let did = deviceId { body["deviceId"] = did }
        if let src = deviceIdSource { body["deviceIdSource"] = src }
        if let sid = sessionId { body["sessionId"] = sid }
        if let rel = sessionRelativeTimeMs { body["sessionRelativeTimeMs"] = rel }
        body["clientOccurredAt"] = clientOccurredAtIso
        return AttriaxApiRequest(kind: AttriaxApiRequest.kindTrackEvent, path: AttriaxEndpoints.events, body: body)
    }

    /// Session lifecycle (`/api/sdk/v1/sessions`). FLAT per `SdkSessionDto`.
    /// Identity is nullable for anonymous capture; absent optionals are OMITTED.
    static func buildSession(
        projectToken: String,
        kind: String,
        sessionId: String,
        deviceId: String?,
        deviceIdSource: String?,
        clientOccurredAtIso: String,
        sessionRelativeTimeMs: Int64? = nil,
        platform: String? = nil,
        locale: String? = nil,
        isFirstLaunch: Bool? = nil,
        appVersion: String? = nil,
        appBuildNumber: String? = nil,
        appPackageName: String? = nil,
        sdkApiVersion: String? = nil,
        sdkPackageVersion: String? = nil,
        metadata: AttriaxJSONObject? = nil
    ) -> AttriaxApiRequest {
        var body = AttriaxJSONObject()
        body["projectToken"] = projectToken
        body["kind"] = kind
        body["sessionId"] = sessionId
        if let did = deviceId { body["deviceId"] = did }
        if let src = deviceIdSource { body["deviceIdSource"] = src }
        if let rel = sessionRelativeTimeMs { body["sessionRelativeTimeMs"] = rel }
        body["clientOccurredAt"] = clientOccurredAtIso
        if let p = platform { body["platform"] = p }
        if let l = locale { body["locale"] = l }
        if let f = isFirstLaunch { body["isFirstLaunch"] = f }
        if let v = appVersion { body["appVersion"] = v }
        if let b = appBuildNumber { body["appBuildNumber"] = b }
        if let pkg = appPackageName { body["appPackageName"] = pkg }
        if let sa = sdkApiVersion { body["sdkApiVersion"] = sa }
        if let sp = sdkPackageVersion { body["sdkPackageVersion"] = sp }
        if let m = metadata { body["metadata"] = m }
        return AttriaxApiRequest(kind: AttriaxApiRequest.kindTrackSession, path: AttriaxEndpoints.sessions, body: body)
    }

    /// User/identify (`/api/sdk/v1/users`). platform/version OMITTED (row E4). Wire
    /// field names match `SdkUserDto`: `externalUserId`/`externalUserName`/
    /// `properties` (NOT userId), `deviceId` REQUIRED, and there is NO
    /// `clientOccurredAt` on this DTO. Clear flags are only emitted when true.
    static func buildUser(
        projectToken: String,
        externalUserId: String?,
        externalUserName: String?,
        properties: AttriaxJSONObject?,
        deviceId: String?,
        deviceIdSource: String?,
        clearExternalUser: Bool = false,
        clearPropertyKeys: [String]? = nil,
        clearAllProperties: Bool = false
    ) -> AttriaxApiRequest {
        var body = AttriaxJSONObject()
        body["projectToken"] = projectToken
        if let did = deviceId { body["deviceId"] = did }
        if let src = deviceIdSource { body["deviceIdSource"] = src }
        if let uid = externalUserId { body["externalUserId"] = uid }
        if let uname = externalUserName { body["externalUserName"] = uname }
        if clearExternalUser { body["clearExternalUser"] = true }
        if let props = properties { body["properties"] = props }
        if let keys = clearPropertyKeys, !keys.isEmpty { body["clearPropertyKeys"] = keys }
        if clearAllProperties { body["clearAllProperties"] = true }
        return AttriaxApiRequest(kind: AttriaxApiRequest.kindUser, path: AttriaxEndpoints.users, body: body)
    }

    /// Crash/error (`/api/sdk/v1/crashes`). FLAT per `SdkCrashDto` — carries full
    /// context inline (unlike open, which nests). `platform`/`isFirstLaunch`
    /// required; identity nullable for anonymous capture.
    static func buildCrash(
        projectToken: String,
        context: AttriaxContextSnapshot,
        deviceId: String?,
        deviceIdSource: String?,
        source: String,
        isFatal: Bool,
        exceptionType: String,
        message: String,
        stackTrace: String,
        isFirstLaunch: Bool,
        clientOccurredAtIso: String,
        reason: String?,
        sessionId: String?,
        sessionRelativeTimeMs: Int64?,
        metadata: AttriaxJSONObject?
    ) -> AttriaxApiRequest {
        var body = AttriaxJSONObject()
        body["projectToken"] = projectToken
        if let did = deviceId { body["deviceId"] = did }
        if let src = deviceIdSource { body["deviceIdSource"] = src }
        body["source"] = source
        body["clientOccurredAt"] = clientOccurredAtIso
        body["platform"] = context.platform
        body["isFatal"] = isFatal
        body["exceptionType"] = exceptionType
        body["message"] = message
        body["stackTrace"] = stackTrace
        body["isFirstLaunch"] = isFirstLaunch
        if let r = reason { body["reason"] = r }
        if let sid = sessionId { body["sessionId"] = sid }
        if let rel = sessionRelativeTimeMs { body["sessionRelativeTimeMs"] = rel }
        if let l = context.deviceLocale { body["locale"] = l }
        if let v = context.appVersion { body["appVersion"] = v }
        if let b = context.appBuildNumber { body["appBuildNumber"] = b }
        if let pkg = context.packageName { body["appPackageName"] = pkg }
        body["sdkApiVersion"] = context.sdkApiVersion
        body["sdkPackageVersion"] = context.sdkPackageVersion
        if let m = metadata { body["metadata"] = m }
        return AttriaxApiRequest(kind: AttriaxApiRequest.kindTrackCrash, path: AttriaxEndpoints.crashes, body: body)
    }

    /// Notification lifecycle (`/api/sdk/v1/notifications`). FLAT per
    /// `SdkNotificationDto`: `type`/`notificationId`/`platform` required, `source`
    /// (fcm/apns/other) + `occurredAt` optional; raw payload lives under
    /// `metadata.payload` (assembled by the caller). No `clientOccurredAt`.
    static func buildNotification(
        projectToken: String,
        platform: String,
        type: String,
        notificationId: String,
        deviceId: String?,
        deviceIdSource: String?,
        linkId: String?,
        campaignId: String?,
        title: String?,
        source: String?,
        sessionId: String?,
        occurredAtIso: String?,
        metadata: AttriaxJSONObject?
    ) -> AttriaxApiRequest {
        var body = AttriaxJSONObject()
        body["projectToken"] = projectToken
        if let did = deviceId { body["deviceId"] = did }
        if let src = deviceIdSource { body["deviceIdSource"] = src }
        if let sid = sessionId { body["sessionId"] = sid }
        body["type"] = type
        body["notificationId"] = notificationId
        if let lid = linkId { body["linkId"] = lid }
        if let cid = campaignId { body["campaignId"] = cid }
        if let t = title { body["title"] = t }
        if let s = source { body["source"] = s }
        body["platform"] = platform
        if let occ = occurredAtIso { body["occurredAt"] = occ }
        if let m = metadata { body["metadata"] = m }
        return AttriaxApiRequest(
            kind: AttriaxApiRequest.kindTrackNotification,
            path: AttriaxEndpoints.notifications,
            body: body
        )
    }

    /// Uninstall-token registration (`/api/sdk/v1/uninstall-tokens`). FLAT per
    /// `SdkRegisterUninstallTokenDto`: `deviceId`/`platform`/`provider` required,
    /// `token` nullable (a nil token de-registers). iOS provider = "apns".
    static func buildUninstallToken(
        projectToken: String,
        deviceId: String,
        deviceIdSource: String?,
        platform: String,
        provider: String,
        token: String?,
        metadata: AttriaxJSONObject?
    ) -> AttriaxApiRequest {
        var body = AttriaxJSONObject()
        body["projectToken"] = projectToken
        body["deviceId"] = deviceId
        if let src = deviceIdSource { body["deviceIdSource"] = src }
        body["platform"] = platform
        body["provider"] = provider
        if let t = token { body["token"] = t }
        if let m = metadata { body["metadata"] = m }
        return AttriaxApiRequest(
            kind: AttriaxApiRequest.kindRegisterUninstallToken,
            path: AttriaxEndpoints.uninstallTokens,
            body: body
        )
    }

    /// Deep-link resolve (`/api/sdk/v1/deep-links/resolve`). Wire shape matches the
    /// api `SdkV1DeepLinkResolveDto`: `projectToken` (required), `platform`
    /// (required), and the optional `deviceId`/`deviceIdSource`/`rawUrl`/`linkPath`/
    /// `source`/`sessionId`/`sessionRelativeTimeMs`/`isFirstLaunch`/`metadata`.
    /// Unknown props are rejected by whitelist validation, so absent optionals are
    /// OMITTED rather than sent as null. Identity is nullable to support anonymous
    /// deep-link diagnostics while consent is pending (PARITY §5/§6). `linkPath` is
    /// the normalized (slashes-stripped) path.
    static func buildResolveDeepLink(
        projectToken: String,
        platform: String,
        source: String?,
        isFirstLaunch: Bool,
        deviceId: String?,
        deviceIdSource: String?,
        rawUrl: String?,
        linkPath: String?,
        sessionId: String?,
        sessionRelativeTimeMs: Int64?,
        metadata: AttriaxJSONObject?
    ) -> AttriaxApiRequest {
        var body = AttriaxJSONObject()
        body["projectToken"] = projectToken
        if let did = deviceId { body["deviceId"] = did }
        if let src = deviceIdSource { body["deviceIdSource"] = src }
        body["platform"] = platform
        if let raw = rawUrl { body["rawUrl"] = raw }
        if let lp = linkPath { body["linkPath"] = lp }
        if let s = source { body["source"] = s }
        if let sid = sessionId { body["sessionId"] = sid }
        if let rel = sessionRelativeTimeMs { body["sessionRelativeTimeMs"] = rel }
        body["isFirstLaunch"] = isFirstLaunch
        if let m = metadata { body["metadata"] = m }
        return AttriaxApiRequest(
            kind: AttriaxApiRequest.kindResolveDeepLink,
            path: AttriaxEndpoints.deepLinksResolve,
            body: body
        )
    }

    /// Create dynamic link (`/api/sdk/v1/dynamic-links`). Wire shape matches the api
    /// `SdkCreateDynamicLinkDto`: `projectToken` (required) + all-optional
    /// `name`/`destinationUrl`/`iosRedirect`/`androidRedirect`/`previewTitle`/
    /// `previewDescription`/`group`/`prefix`/`data`/`utm{Source,Medium,Campaign,
    /// Term,Content}`. `iosRedirect`/`androidRedirect` are BOOLEANS (not URLs). The
    /// redirects/socialPreview/utms value objects are flattened to these flat wire
    /// keys. Sent DIRECTLY (non-queued) — it is a synchronous request/response.
    static func buildCreateDynamicLink(
        projectToken: String,
        name: String?,
        destinationUrl: String?,
        group: String?,
        prefix: String?,
        iosRedirect: Bool?,
        androidRedirect: Bool?,
        previewTitle: String?,
        previewDescription: String?,
        utmSource: String?,
        utmMedium: String?,
        utmCampaign: String?,
        utmTerm: String?,
        utmContent: String?,
        data: AttriaxJSONObject?
    ) -> AttriaxJSONObject {
        var body = AttriaxJSONObject()
        body["projectToken"] = projectToken
        if let n = name { body["name"] = n }
        if let d = destinationUrl { body["destinationUrl"] = d }
        if let ir = iosRedirect { body["iosRedirect"] = ir }
        if let ar = androidRedirect { body["androidRedirect"] = ar }
        if let pt = previewTitle { body["previewTitle"] = pt }
        if let pd = previewDescription { body["previewDescription"] = pd }
        if let g = group { body["group"] = g }
        if let p = prefix { body["prefix"] = p }
        if let d = data { body["data"] = d }
        if let s = utmSource { body["utmSource"] = s }
        if let m = utmMedium { body["utmMedium"] = m }
        if let c = utmCampaign { body["utmCampaign"] = c }
        if let t = utmTerm { body["utmTerm"] = t }
        if let c = utmContent { body["utmContent"] = c }
        return body
    }

    /// Receipt validation body (`/api/sdk/v1/revenue/receipts/validate`). Sent
    /// DIRECTLY (non-queued) by `Attriax.validateReceipt`. FLAT per
    /// `SdkV1RevenueReceiptValidateDto` — every field except the token is optional.
    static func buildReceiptValidate(
        projectToken: String,
        receipt: String,
        deviceId: String?,
        clientOccurredAtIso: String,
        provider: String?,
        environment: String?,
        transactionId: String?,
        productId: String?,
        test: Bool?
    ) -> AttriaxJSONObject {
        var body = AttriaxJSONObject()
        body["projectToken"] = projectToken
        if let did = deviceId { body["deviceId"] = did }
        body["clientOccurredAt"] = clientOccurredAtIso
        body["receipt"] = receipt
        if let p = provider { body["provider"] = p }
        if let e = environment { body["environment"] = e }
        if let tid = transactionId { body["transactionId"] = tid }
        if let pid = productId { body["productId"] = pid }
        if let t = test { body["test"] = t }
        return body
    }
}

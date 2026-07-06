import Foundation

/// Pure body-map rewrites applied to queued requests when consent resolves
/// (PARITY §5, row C5). Mirrors the Flutter reference `consent_request_rewrites.dart`
/// (`attriaxAnonymizeRequestForConsent` / `attriaxIdentifyRequestForConsentNotRequired`)
/// and the Android `AttriaxConsentRequestRewrites`.
///
/// The engine models a request as a `kind` + JSON body map, so identity handling
/// reduces to adding/removing the `deviceId`/`deviceIdSource` keys — no per-DTO
/// reconstruction is needed. Both functions are pure and return a NEW request
/// (the body map is copied), so the queue rewrite stays free of aliasing bugs.
enum AttriaxConsentRequestRewrites {

    /// ANONYMIZE (pass 2): strip the device identity from a request so it is sent
    /// without device-linked identity. Applied to capture-but-anonymous requests.
    /// Requests are stripped unconditionally (matching the Flutter anonymize
    /// rewrite, which rebuilds the payload without deviceId/deviceIdSource).
    static func anonymize(_ request: AttriaxApiRequest) -> AttriaxApiRequest {
        if !hasIdentity(request) { return request }
        var body = request.body
        body.removeValue(forKey: AttriaxApiRequest.fieldDeviceId)
        body.removeValue(forKey: AttriaxApiRequest.fieldDeviceIdSource)
        return AttriaxApiRequest(kind: request.kind, path: request.path, body: body)
    }

    /// IDENTIFY (pass 1): attach the device identity to an anonymous request now
    /// that identified tracking is allowed. Only requests that DO NOT already carry
    /// a deviceId are rewritten (mirrors the Flutter `when payload.deviceId == null`
    /// guards); already-identified requests return nil so the caller's rewrite count
    /// reflects only the ones actually changed.
    static func identify(
        _ request: AttriaxApiRequest,
        deviceId: String,
        deviceIdSource: String
    ) -> AttriaxApiRequest? {
        if !supportsIdentity(request.kind) { return nil }
        if request.body[AttriaxApiRequest.fieldDeviceId].flatMap({ $0 }) != nil { return nil }
        var body = request.body
        body[AttriaxApiRequest.fieldDeviceId] = deviceId
        body[AttriaxApiRequest.fieldDeviceIdSource] = deviceIdSource
        return AttriaxApiRequest(kind: request.kind, path: request.path, body: body)
    }

    private static func hasIdentity(_ request: AttriaxApiRequest) -> Bool {
        request.body[AttriaxApiRequest.fieldDeviceId].flatMap({ $0 }) != nil ||
            request.body[AttriaxApiRequest.fieldDeviceIdSource].flatMap({ $0 }) != nil
    }

    /// Request kinds that carry an optional device identity eligible for rewrite.
    private static func supportsIdentity(_ kind: String) -> Bool {
        switch kind {
        case AttriaxApiRequest.kindTrackEvent,
             AttriaxApiRequest.kindTrackCrash,
             AttriaxApiRequest.kindTrackSession,
             AttriaxApiRequest.kindResolveDeepLink,
             AttriaxApiRequest.kindTrackNotification:
            return true
        default:
            return false
        }
    }
}

import Foundation

/// The remote consent status echo (PARITY §5, row C2). Mirrors the api
/// `SdkGdprConsentStatusDto` (returned inside the `{data:...}` envelope the
/// transport already unwraps). Only the fields the SDK consumes are modeled.
struct AttriaxRemoteConsentStatus {
    let state: AttriaxGdprConsentState
    let values: AttriaxGdprConsentValues?
    let needsConsent: Bool
    let countryCode: String?
    let regionSource: String?
    let checkedAtIso: String?
}

/// Narrow port the `AttriaxConsentManager` uses to talk to the backend. Kept as a
/// protocol (no URLSession / transport type in the signature) so the
/// generation-guard race can be reproduced deterministically in tests with a fake
/// that controls exactly when each echo returns.
///
/// WIRE-SHAPE RULE (grounded in the api DTOs, not prose):
///  * check  → POST /api/sdk/v1/consent/gdpr/check   body: {projectToken, consentId}
///  * upsert → POST /api/sdk/v1/consent/gdpr          body: {projectToken, consentId,
///             state, values?{analytics,attribution,adEvents}, countryCode?,
///             regionSource?, clientOccurredAt?}
///  * erase  → POST /api/sdk/v1/privacy/gdpr/erase    body: {projectToken, deviceId}
///
/// Consent check/upsert send an SDK-generated `consentId` and carry NO deviceId or
/// user identifier (the api check/write DTOs reject unknown props). `state` uses
/// the api snake_case tokens (`not_required`, not `notRequired`).
protocol AttriaxConsentTransport: AnyObject {
    func checkGdprConsent(projectToken: String, consentId: String) throws -> AttriaxRemoteConsentStatus

    func upsertGdprConsent(
        projectToken: String,
        consentId: String,
        state: AttriaxGdprConsentState,
        values: AttriaxGdprConsentValues?,
        countryCode: String?,
        regionSource: String?,
        clientOccurredAtIso: String?
    ) throws -> AttriaxRemoteConsentStatus

    func eraseGdprData(projectToken: String, deviceId: String) throws
}

/// The on-device `AttriaxConsentTransport` backed by the shared `AttriaxHttpClient`.
/// It assembles the exact DTO bodies above and parses the status echo out of the
/// (already envelope-unwrapped) response body.
final class AttriaxHttpConsentTransport: AttriaxConsentTransport {
    private let http: AttriaxHttpClient

    init(http: AttriaxHttpClient) {
        self.http = http
    }

    func checkGdprConsent(projectToken: String, consentId: String) throws -> AttriaxRemoteConsentStatus {
        var body = AttriaxJSONObject()
        body[AttriaxApiRequest.fieldProjectToken] = projectToken
        body[Self.fieldConsentId] = consentId
        let response = try http.post(AttriaxEndpoints.consentCheck, AttriaxJson.encode(body))
        return Self.parseStatus(response.body)
    }

    func upsertGdprConsent(
        projectToken: String,
        consentId: String,
        state: AttriaxGdprConsentState,
        values: AttriaxGdprConsentValues?,
        countryCode: String?,
        regionSource: String?,
        clientOccurredAtIso: String?
    ) throws -> AttriaxRemoteConsentStatus {
        var body = AttriaxJSONObject()
        body[AttriaxApiRequest.fieldProjectToken] = projectToken
        body[Self.fieldConsentId] = consentId
        body[Self.fieldState] = AttriaxConsentStateWire.toWire(state)
        if let values = values {
            body[Self.fieldValues] = [
                Self.fieldAnalytics: values.analytics,
                Self.fieldAttribution: values.attribution,
                Self.fieldAdEvents: values.adEvents,
            ] as AttriaxJSONObject
        }
        if let cc = countryCode { body[Self.fieldCountryCode] = cc }
        if let rs = regionSource { body[Self.fieldRegionSource] = rs }
        if let ca = clientOccurredAtIso { body[Self.fieldClientOccurredAt] = ca }
        let response = try http.post(AttriaxEndpoints.consentUpsert, AttriaxJson.encode(body))
        return Self.parseStatus(response.body)
    }

    func eraseGdprData(projectToken: String, deviceId: String) throws {
        var body = AttriaxJSONObject()
        body[AttriaxApiRequest.fieldProjectToken] = projectToken
        body[AttriaxApiRequest.fieldDeviceId] = deviceId
        _ = try http.post(AttriaxEndpoints.gdprErase, AttriaxJson.encode(body))
    }

    static func parseStatus(_ rawBody: String?) -> AttriaxRemoteConsentStatus {
        let obj: [String: Any?]
        if let rawBody = rawBody, !rawBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let decoded = try? AttriaxJson.decodeObject(rawBody) {
            obj = decoded
        } else {
            obj = [:]
        }
        let values = AttriaxConsentStore.decodeValues(obj[fieldValues] ?? nil)
        return AttriaxRemoteConsentStatus(
            state: AttriaxConsentStateWire.fromWire(obj[fieldState] as? String),
            values: values,
            needsConsent: (obj[fieldNeedsConsent] as? Bool) ?? false,
            countryCode: obj[fieldCountryCode] as? String,
            regionSource: obj[fieldRegionSource] as? String,
            checkedAtIso: obj[fieldCheckedAt] as? String
        )
    }

    private static let fieldConsentId = "consentId"
    private static let fieldState = "state"
    private static let fieldValues = "values"
    private static let fieldAnalytics = "analytics"
    private static let fieldAttribution = "attribution"
    private static let fieldAdEvents = "adEvents"
    private static let fieldCountryCode = "countryCode"
    private static let fieldRegionSource = "regionSource"
    private static let fieldClientOccurredAt = "clientOccurredAt"
    private static let fieldNeedsConsent = "needsConsent"
    private static let fieldCheckedAt = "checkedAt"
}

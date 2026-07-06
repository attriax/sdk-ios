import Foundation

/// Snapshot of the persisted consent decision (PARITY §5, row C2).
struct AttriaxStoredConsent: Equatable {
    let state: AttriaxGdprConsentState
    let values: AttriaxGdprConsentValues?
    let countryCode: String?
    let regionSource: String?
    let checkedAtIso: String?
    let pendingSync: Bool
}

/// Persists the GDPR consent decision + the SDK-generated `consentId` to the
/// `AttriaxKeyValueStore` (PARITY §5, row C2). The consentId is generated ONCE with
/// the same id generator used for device / queued-request ids and reused for every
/// consent check/upsert, so the backend can correlate a device's consent history
/// WITHOUT the SDK ever sending a device or user identifier on the consent body.
final class AttriaxConsentStore {
    static let keyConsent = "attriax.gdpr_consent"
    static let keyConsentId = "attriax.gdpr_consent_id"

    private let store: AttriaxKeyValueStore

    init(store: AttriaxKeyValueStore) {
        self.store = store
    }

    /// Return the stored consent snapshot, or nil when nothing has been persisted.
    func read() -> AttriaxStoredConsent? {
        guard let raw = store.getString(Self.keyConsent) else { return nil }
        do {
            let obj = try AttriaxJson.decodeObject(raw)
            let values = Self.decodeValues(obj["values"] ?? nil)
            return AttriaxStoredConsent(
                state: AttriaxConsentStateWire.fromWire(obj["state"] as? String),
                values: values,
                countryCode: obj["countryCode"] as? String,
                regionSource: obj["regionSource"] as? String,
                checkedAtIso: obj["checkedAt"] as? String,
                pendingSync: (obj["pendingSync"] as? Bool) ?? false
            )
        } catch {
            // Corrupt consent blob: drop it and fall back to the default state.
            store.remove(Self.keyConsent)
            return nil
        }
    }

    /// Persist `data`, or clear the stored blob when `data` is nil.
    func write(_ data: AttriaxStoredConsent?) {
        guard let data = data else {
            store.remove(Self.keyConsent)
            return
        }
        var body = AttriaxJSONObject()
        body["state"] = AttriaxConsentStateWire.toWire(data.state)
        if let values = data.values {
            body["values"] = [
                "analytics": values.analytics,
                "attribution": values.attribution,
                "adEvents": values.adEvents,
            ] as AttriaxJSONObject
        }
        if let cc = data.countryCode { body["countryCode"] = cc }
        if let rs = data.regionSource { body["regionSource"] = rs }
        if let ca = data.checkedAtIso { body["checkedAt"] = ca }
        body["pendingSync"] = data.pendingSync
        store.putString(Self.keyConsent, AttriaxJson.encode(body))
    }

    /// Load the persisted consentId, generating + persisting one on first use.
    func ensureConsentId() -> String {
        if let existing = store.getString(Self.keyConsentId) { return existing }
        let generated = AttriaxIdGenerator.generate()
        store.putString(Self.keyConsentId, generated)
        return generated
    }

    /// Clear both the consent decision and the consentId (reset()/erase()).
    func clear() {
        store.remove(Self.keyConsent)
        store.remove(Self.keyConsentId)
    }

    static func decodeValues(_ value: Any?) -> AttriaxGdprConsentValues? {
        guard let map = value as? [String: Any?] else { return nil }
        return AttriaxGdprConsentValues(
            analytics: (map["analytics"] as? Bool) ?? false,
            attribution: (map["attribution"] as? Bool) ?? false,
            adEvents: (map["adEvents"] as? Bool) ?? false
        )
    }
}

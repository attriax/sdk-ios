import Foundation

/// Pure (de)serialization of the persisted queue, including the legacy
/// field-normalization boundary (PARITY §10, row FR1; Flutter
/// `request_json_codec.dart:34-76`).
///
/// At the deserialization boundary:
///  - `appToken` → `projectToken` rename (older builds stored the token as
///    `appToken`; if `projectToken` is absent and `appToken` present, rename and
///    drop `appToken`).
///  - `identify` kind → `user` handler alias.
///
/// Corruption handling (row Q1):
///  - a whole-payload that is not a JSON array → clear the queue.
///  - individual invalid entries → dropped (the rest are kept).
enum AttriaxQueueCodec {

    /// Result of decoding the persisted queue payload.
    struct DecodeResult {
        let queue: [AttriaxQueuedRequest]
        /// True when the entire payload was unparseable and should be cleared.
        var clearedWholePayload = false
        /// Count of individually-invalid entries that were dropped.
        var droppedEntryCount = 0
    }

    static func encode(_ queue: [AttriaxQueuedRequest]) -> String {
        AttriaxJson.encode(queue.map(encodeEntry))
    }

    private static func encodeEntry(_ entry: AttriaxQueuedRequest) -> AttriaxJSONObject {
        var map = AttriaxJSONObject()
        map["id"] = entry.id
        map["kind"] = entry.request.kind
        map["body"] = entry.request.body
        map["createdAt"] = entry.createdAtMs
        map["attemptCount"] = entry.attemptCount
        if let v = entry.lastAttemptAtMs { map["lastAttemptAt"] = v }
        if let v = entry.lastErrorClass { map["lastErrorClass"] = v }
        if let v = entry.lastHttpStatusCode { map["lastHttpStatusCode"] = v }
        if let v = entry.nextRetryAtMs { map["nextRetryAt"] = v }
        return map
    }

    static func decode(_ rawPayload: String?) -> DecodeResult {
        guard let rawPayload = rawPayload, !rawPayload.isEmpty else {
            return DecodeResult(queue: [])
        }

        let list: [Any?]
        do {
            list = try AttriaxJson.decodeArray(rawPayload)
        } catch {
            // Invalid whole payload → clear (row Q1).
            return DecodeResult(queue: [], clearedWholePayload: true)
        }

        var queue = [AttriaxQueuedRequest]()
        var dropped = 0
        for element in list {
            guard let obj = element as? AttriaxJSONObject else {
                dropped += 1
                continue
            }
            if let entry = decodeEntry(obj) {
                queue.append(entry)
            } else {
                dropped += 1
            }
        }
        return DecodeResult(queue: queue, droppedEntryCount: dropped)
    }

    private static func decodeEntry(_ json: AttriaxJSONObject) -> AttriaxQueuedRequest? {
        guard let id = json["id"].flatMap({ $0 }) as? String else { return nil }
        guard let rawKind = json["kind"].flatMap({ $0 }) as? String else { return nil }
        let rawBody = (json["body"].flatMap { $0 } as? AttriaxJSONObject) ?? AttriaxJSONObject()

        let (kind, body) = normalize(rawKind: rawKind, rawBody: rawBody)
        guard let path = pathForKind(kind) else { return nil }
        let request = AttriaxApiRequest(kind: kind, path: path, body: body)

        return AttriaxQueuedRequest(
            id: id,
            request: request,
            createdAtMs: long(json["createdAt"].flatMap { $0 }) ?? 0,
            attemptCount: int(json["attemptCount"].flatMap { $0 }) ?? 0,
            lastAttemptAtMs: long(json["lastAttemptAt"].flatMap { $0 }),
            lastErrorClass: json["lastErrorClass"].flatMap { $0 } as? String,
            lastHttpStatusCode: int(json["lastHttpStatusCode"].flatMap { $0 }),
            nextRetryAtMs: long(json["nextRetryAt"].flatMap { $0 })
        )
    }

    /// Legacy normalization at the restore boundary (row FR1). Exposed so it can be
    /// unit-tested directly against the parity contract.
    static func normalize(rawKind: String, rawBody: AttriaxJSONObject) -> (String, AttriaxJSONObject) {
        // Kind alias: 'identify' → 'user'.
        let kind = rawKind == AttriaxApiRequest.legacyKindIdentify ? AttriaxApiRequest.kindUser : rawKind
        return (kind, migrateLegacyProjectToken(rawBody))
    }

    private static func migrateLegacyProjectToken(_ body: AttriaxJSONObject) -> AttriaxJSONObject {
        if let existing = body[AttriaxApiRequest.fieldProjectToken].flatMap({ $0 }) as? String, !existing.isEmpty {
            return body
        }
        guard let legacy = body[AttriaxApiRequest.fieldLegacyAppToken].flatMap({ $0 }) as? String, !legacy.isEmpty else {
            return body
        }
        var migrated = body
        migrated[AttriaxApiRequest.fieldProjectToken] = legacy
        migrated.removeValue(forKey: AttriaxApiRequest.fieldLegacyAppToken)
        return migrated
    }

    /// Map a persisted kind back to its wire endpoint. Returns nil for an unknown
    /// kind (→ the entry is dropped as invalid, matching the Android throw+drop).
    static func pathForKind(_ kind: String) -> String? {
        switch kind {
        case AttriaxApiRequest.kindOpen: return AttriaxEndpoints.open
        case AttriaxApiRequest.kindTrackEvent: return AttriaxEndpoints.events
        case AttriaxApiRequest.kindTrackSession: return AttriaxEndpoints.sessions
        case AttriaxApiRequest.kindUser: return AttriaxEndpoints.users
        case AttriaxApiRequest.kindTrackNotification: return AttriaxEndpoints.notifications
        case AttriaxApiRequest.kindTrackCrash: return AttriaxEndpoints.crashes
        case AttriaxApiRequest.kindResolveDeepLink: return AttriaxEndpoints.deepLinksResolve
        case AttriaxApiRequest.kindCreateDynamicLink: return AttriaxEndpoints.dynamicLinks
        case AttriaxApiRequest.kindRegisterUninstallToken: return AttriaxEndpoints.uninstallTokens
        default: return nil
        }
    }

    private static func long(_ value: Any?) -> Int64? {
        switch value {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as Double: return Int64(v)
        case let v as NSNumber: return v.int64Value
        case let v as String: return Int64(v)
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Int64: return Int(v)
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v)
        default: return nil
        }
    }
}

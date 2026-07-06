import Foundation

/// Persists the current `AttriaxSessionSnapshot` to an `AttriaxKeyValueStore` as a
/// small JSON object (PARITY §3, row S5 — "snapshot persisted + revalidated each
/// launch"). Mirrors the Android `AttriaxSessionSnapshotStore`, adapted to the
/// SDK's dependency-free `AttriaxJson` codec.
///
/// A corrupt payload is treated as "no session" (returns nil) rather than
/// crashing — a bad snapshot must never break init; the launch simply starts a
/// fresh session, exactly as if none had been persisted.
final class AttriaxSessionSnapshotStore {
    static let keySession = "attriax.session_snapshot"

    private let store: AttriaxKeyValueStore

    init(store: AttriaxKeyValueStore) {
        self.store = store
    }

    /// The persisted snapshot, or nil when absent/corrupt.
    func read() -> AttriaxSessionSnapshot? {
        guard let raw = store.getString(Self.keySession) else { return nil }
        do {
            return try Self.decode(AttriaxJson.decodeObject(raw))
        } catch {
            // Corrupt snapshot → drop it and behave as if no session were stored.
            store.remove(Self.keySession)
            return nil
        }
    }

    /// Persist `snapshot`, or clear the stored snapshot when nil.
    func write(_ snapshot: AttriaxSessionSnapshot?) {
        guard let snapshot = snapshot else {
            store.remove(Self.keySession)
            return
        }
        store.putString(Self.keySession, AttriaxJson.encode(Self.encode(snapshot)))
    }

    func clear() { store.remove(Self.keySession) }

    /// Pure snapshot → JSON-map encoding (exposed for tests).
    static func encode(_ snapshot: AttriaxSessionSnapshot) -> AttriaxJSONObject {
        var map = AttriaxJSONObject()
        map["sessionId"] = snapshot.sessionId
        map["startedAtMs"] = snapshot.startedAtMs
        map["lastActivityAtMs"] = snapshot.lastActivityAtMs
        map["heartbeatIntervalMs"] = snapshot.heartbeatIntervalMs
        if let v = snapshot.deviceId { map["deviceId"] = v }
        map["platform"] = snapshot.platform
        if let v = snapshot.appPackageName { map["appPackageName"] = v }
        if let v = snapshot.appVersion { map["appVersion"] = v }
        if let v = snapshot.appBuildNumber { map["appBuildNumber"] = v }
        if let v = snapshot.locale { map["locale"] = v }
        map["isFirstLaunch"] = snapshot.isFirstLaunch
        if let v = snapshot.sdkPackageVersion { map["sdkPackageVersion"] = v }
        return map
    }

    /// Pure JSON-map → snapshot decoding (exposed for tests). Throws on a bad shape.
    static func decode(_ map: [String: Any?]) throws -> AttriaxSessionSnapshot {
        guard let sessionId = map["sessionId"].flatMap({ $0 }) as? String,
              let platform = map["platform"].flatMap({ $0 }) as? String else {
            throw AttriaxJson.ParseError(message: "session snapshot missing required fields")
        }
        return AttriaxSessionSnapshot(
            sessionId: sessionId,
            startedAtMs: try asLong(map["startedAtMs"].flatMap { $0 }),
            lastActivityAtMs: try asLong(map["lastActivityAtMs"].flatMap { $0 }),
            heartbeatIntervalMs: try asLong(map["heartbeatIntervalMs"].flatMap { $0 }),
            deviceId: map["deviceId"].flatMap { $0 } as? String,
            platform: platform,
            appPackageName: map["appPackageName"].flatMap { $0 } as? String,
            appVersion: map["appVersion"].flatMap { $0 } as? String,
            appBuildNumber: map["appBuildNumber"].flatMap { $0 } as? String,
            locale: map["locale"].flatMap { $0 } as? String,
            isFirstLaunch: (map["isFirstLaunch"].flatMap { $0 } as? Bool) ?? false,
            sdkPackageVersion: map["sdkPackageVersion"].flatMap { $0 } as? String
        )
    }

    private static func asLong(_ value: Any?) throws -> Int64 {
        switch value {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as Double: return Int64(v)
        case let v as NSNumber: return v.int64Value
        default: throw AttriaxJson.ParseError(message: "expected numeric, got \(String(describing: value))")
        }
    }
}

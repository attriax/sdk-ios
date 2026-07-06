import Foundation

/// Decoded SKAN conversion-value config (PARITY §13 / Epic 12.2 wire shape).
///
/// Mirrors the api `SdkCvConfigResponse` (see
/// `api/src/modules/skan-conversion-modeling/application/cv-rule-transformer.ts`):
/// `{ schemaVersion, schemaUpdatedAt, enabled, rules[], disclaimer }`. The SDK does
/// NOT compose a conversion value from these rules on its own (that needs the host's
/// per-event/revenue state); it surfaces the ordered rule list to the host, which
/// evaluates it and calls `AttriaxSkan.updateConversionValue`.
public struct AttriaxSkanConversionConfig: Equatable {
    public let schemaVersion: Int?
    public let schemaUpdatedAt: String?
    public let enabled: Bool
    public let rules: [AttriaxSkanCvRule]
    public let disclaimer: String?
}

/// One SKAN CV rule: "when `whenEvent` (and its conditions) is satisfied, group
/// `groupId` contributes `bitContribution` (rank << startBit) to the fine value, and
/// the update should adopt `coarseValue` / `lockWindow`." Ordered group-by-group
/// (ascending startBit), each group's rules in descending rank, so a "highest rank
/// wins per group" evaluator can take the first satisfied rule per group.
public struct AttriaxSkanCvRule: Equatable {
    public let id: String
    public let groupId: String?
    public let groupDisplayName: String?
    public let startBit: Int
    public let bitCount: Int
    public let rank: Int
    public let bitContribution: Int
    public let whenEvent: String
    public let whenConditions: [AttriaxSkanCvCondition]
    public let whenRevenue: AttriaxSkanCvRevenueCondition?
    /// `low` / `medium` / `high`, or nil.
    public let coarseValue: AttriaxSkanCoarseValue?
    public let lockWindow: Bool
}

/// A parameter condition that must ALSO hold for a rule to fire.
public struct AttriaxSkanCvCondition: Equatable {
    public let paramKey: String
    public let `operator`: String
    /// Opaque comparison value (string / number / bool), preserved as-is.
    public let value: AttriaxSkanCvValue?
}

/// Convenience view of a `__revenue` condition on a rule (or nil).
public struct AttriaxSkanCvRevenueCondition: Equatable {
    public let `operator`: String
    public let value: AttriaxSkanCvValue?
}

/// A JSON-scalar condition value (string / number / bool), kept type-preserving so
/// the host can compare against its own event params.
public enum AttriaxSkanCvValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

/// Fetches + decodes the project's SKAN CV config from
/// `GET /api/sdk/v1/skan/conversion-config/:projectToken` (PARITY §13; CHUNK C).
///
/// Pure over the `AttriaxHttpClient` port so it is testable with a fake transport.
/// Best-effort: any transport error (unknown token → 404, offline, malformed body)
/// yields nil. Blocking I/O — invoked off the main thread by `AttriaxSkan`.
struct AttriaxSkanConfigFetcher {
    private let transport: AttriaxHttpClient
    private let projectToken: String

    init(transport: AttriaxHttpClient, projectToken: String) {
        self.transport = transport
        self.projectToken = projectToken
    }

    func fetch() -> AttriaxSkanConversionConfig? {
        let token = projectToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return nil }
        // Percent-encode the token as a single path segment.
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .attriaxPathSegmentAllowed) ?? token
        let path = AttriaxEndpoints.skanConversionConfigPrefix + encoded

        guard let response = try? transport.get(path), let body = response.body else { return nil }
        guard let map = (try? AttriaxJson.decode(body)) as? [String: Any?] else { return nil }
        return Self.decodeConfig(map)
    }

    // MARK: - decoding

    static func decodeConfig(_ map: [String: Any?]) -> AttriaxSkanConversionConfig {
        let rawRules = (map["rules"].flatMap { $0 } as? [Any?]) ?? []
        let rules = rawRules.compactMap { $0 as? [String: Any?] }.map(decodeRule)
        return AttriaxSkanConversionConfig(
            schemaVersion: intOrNil(map["schemaVersion"].flatMap { $0 }),
            schemaUpdatedAt: map["schemaUpdatedAt"].flatMap { $0 } as? String,
            enabled: (map["enabled"].flatMap { $0 } as? Bool) ?? false,
            rules: rules,
            disclaimer: map["disclaimer"].flatMap { $0 } as? String
        )
    }

    private static func decodeRule(_ map: [String: Any?]) -> AttriaxSkanCvRule {
        let rawConditions = (map["whenConditions"].flatMap { $0 } as? [Any?]) ?? []
        let conditions = rawConditions.compactMap { $0 as? [String: Any?] }.map(decodeCondition)
        let revenue: AttriaxSkanCvRevenueCondition?
        if let rev = map["whenRevenue"].flatMap({ $0 }) as? [String: Any?] {
            revenue = AttriaxSkanCvRevenueCondition(
                operator: (rev["operator"].flatMap { $0 } as? String) ?? "exists",
                value: decodeValue(rev["value"].flatMap { $0 })
            )
        } else {
            revenue = nil
        }
        return AttriaxSkanCvRule(
            id: (map["id"].flatMap { $0 } as? String) ?? "",
            groupId: map["groupId"].flatMap { $0 } as? String,
            groupDisplayName: map["groupDisplayName"].flatMap { $0 } as? String,
            startBit: intOrNil(map["startBit"].flatMap { $0 }) ?? 0,
            bitCount: intOrNil(map["bitCount"].flatMap { $0 }) ?? 1,
            rank: intOrNil(map["rank"].flatMap { $0 }) ?? 0,
            bitContribution: intOrNil(map["bitContribution"].flatMap { $0 }) ?? 0,
            whenEvent: (map["whenEvent"].flatMap { $0 } as? String) ?? "",
            whenConditions: conditions,
            whenRevenue: revenue,
            coarseValue: decodeCoarse(map["coarseValue"].flatMap { $0 }),
            lockWindow: (map["lockWindow"].flatMap { $0 } as? Bool) ?? false
        )
    }

    private static func decodeCondition(_ map: [String: Any?]) -> AttriaxSkanCvCondition {
        AttriaxSkanCvCondition(
            paramKey: (map["paramKey"].flatMap { $0 } as? String) ?? "",
            operator: (map["operator"].flatMap { $0 } as? String) ?? "exists",
            value: decodeValue(map["value"].flatMap { $0 })
        )
    }

    private static func decodeValue(_ value: Any?) -> AttriaxSkanCvValue? {
        switch value {
        case let v as Bool: return .bool(v)
        case let v as String: return .string(v)
        case let v as Int: return .number(Double(v))
        case let v as Int64: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            return .number(v.doubleValue)
        default: return nil
        }
    }

    private static func decodeCoarse(_ value: Any?) -> AttriaxSkanCoarseValue? {
        guard let raw = value as? String else { return nil }
        return AttriaxSkanCoarseValue(rawValue: raw)
    }

    private static func intOrNil(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Int64: return Int(v)
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        default: return nil
        }
    }
}

private extension CharacterSet {
    /// URL path-segment safe set (RFC 3986 unreserved + a few sub-delims), used to
    /// percent-encode the project token as a single path component.
    static let attriaxPathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

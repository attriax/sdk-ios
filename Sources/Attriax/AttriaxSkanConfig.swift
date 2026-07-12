import Foundation

/// Decoded SKAN conversion-value config (PARITY §13 / Epic 12.2 wire shape).
///
/// Mirrors the api `SdkCvConfigResponse`
/// (`{ schemaVersion, schemaUpdatedAt, enabled, rules[], disclaimer }`). The SDK does
/// NOT compose a conversion value from these rules on its own (that needs the host's
/// per-event/revenue state); it surfaces the ordered rule list to the host, which
/// evaluates it and calls `AttriaxSkan.updateConversionValue`.
///
/// NOTE: the config-fetch (`AttriaxSkan.fetchConversionConfig`) is not yet wired
/// through the KMP core — the KMP `AttriaxSkan` surface exposes conversion-value
/// updates but not the config pull. These value types are retained so the public API
/// is unchanged; see `AttriaxSkan.fetchConversionConfig`.
public struct AttriaxSkanConversionConfig: Equatable {
    public let schemaVersion: Int?
    public let schemaUpdatedAt: String?
    public let enabled: Bool
    public let rules: [AttriaxSkanCvRule]
    public let disclaimer: String?

    public init(
        schemaVersion: Int?,
        schemaUpdatedAt: String?,
        enabled: Bool,
        rules: [AttriaxSkanCvRule],
        disclaimer: String?
    ) {
        self.schemaVersion = schemaVersion
        self.schemaUpdatedAt = schemaUpdatedAt
        self.enabled = enabled
        self.rules = rules
        self.disclaimer = disclaimer
    }
}

/// One SKAN CV rule: "when `whenEvent` (and its conditions) is satisfied, group
/// `groupId` contributes `bitContribution` to the fine value, and the update should
/// adopt `coarseValue` / `lockWindow`."
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

    public init(
        id: String,
        groupId: String?,
        groupDisplayName: String?,
        startBit: Int,
        bitCount: Int,
        rank: Int,
        bitContribution: Int,
        whenEvent: String,
        whenConditions: [AttriaxSkanCvCondition],
        whenRevenue: AttriaxSkanCvRevenueCondition?,
        coarseValue: AttriaxSkanCoarseValue?,
        lockWindow: Bool
    ) {
        self.id = id
        self.groupId = groupId
        self.groupDisplayName = groupDisplayName
        self.startBit = startBit
        self.bitCount = bitCount
        self.rank = rank
        self.bitContribution = bitContribution
        self.whenEvent = whenEvent
        self.whenConditions = whenConditions
        self.whenRevenue = whenRevenue
        self.coarseValue = coarseValue
        self.lockWindow = lockWindow
    }
}

/// A parameter condition that must ALSO hold for a rule to fire.
public struct AttriaxSkanCvCondition: Equatable {
    public let paramKey: String
    public let `operator`: String
    /// Opaque comparison value (string / number / bool), preserved as-is.
    public let value: AttriaxSkanCvValue?

    public init(paramKey: String, operator: String, value: AttriaxSkanCvValue?) {
        self.paramKey = paramKey
        self.`operator` = `operator`
        self.value = value
    }
}

/// Convenience view of a `__revenue` condition on a rule (or nil).
public struct AttriaxSkanCvRevenueCondition: Equatable {
    public let `operator`: String
    public let value: AttriaxSkanCvValue?

    public init(operator: String, value: AttriaxSkanCvValue?) {
        self.`operator` = `operator`
        self.value = value
    }
}

/// A JSON-scalar condition value (string / number / bool), kept type-preserving so
/// the host can compare against its own event params.
public enum AttriaxSkanCvValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

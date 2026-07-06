import Foundation

/// SKAdNetwork coarse conversion-value tier (SKAN 4, iOS 16.1+).
///
/// Maps to `SKAdNetwork.CoarseConversionValue` (`.low`/`.medium`/`.high`). Exposed
/// as a plain enum so the public surface does not require StoreKit at the call site
/// and so pre-16.1 hosts can still name the value (it is simply ignored below 16.1,
/// where only the fine value applies).
public enum AttriaxSkanCoarseValue: String, Equatable {
    case low
    case medium
    case high
}

/// Public SKAdNetwork surface (`attriax.skan`; PARITY §13 / Epic 12.2, CHUNK C).
///
/// A thin, HONEST passthrough over Apple's `SKAdNetwork` — the SDK does NOT
/// reimplement Apple's attribution. It exposes:
///  - `registerForAttribution()` — the first-postback registration
///    (`updatePostbackConversionValue` on iOS 16.1+, `registerAppForAdNetworkAttribution`
///    / `updateConversionValue` on the 14/15 fallbacks),
///  - `updateConversionValue(...)` — fine (+ optional coarse / lockWindow on 16.1+),
///  - `applyConversionConfig()` — an OPTIONAL helper that pulls the project's CV
///    rules from `GET /api/sdk/v1/skan/conversion-config/:projectToken` and hands them
///    back to the host to evaluate (the SDK does not silently mutate the conversion
///    value from server config without the host driving event state).
///
/// Every StoreKit call is availability-gated; on a platform/OS without SKAdNetwork
/// these methods are safe no-ops. SKAN postbacks are DEVICE-only (the Simulator does
/// not deliver them), so this surface is code-complete but device-verified.
public final class AttriaxSkan {
    private let passthrough: AttriaxSkanPassthrough
    private let configFetcher: AttriaxSkanConfigFetcher

    init(passthrough: AttriaxSkanPassthrough, configFetcher: AttriaxSkanConfigFetcher) {
        self.passthrough = passthrough
        self.configFetcher = configFetcher
    }

    /// Register the app for SKAdNetwork attribution (the first postback). Idempotent
    /// and safe to call at launch. On iOS 16.1+ this seeds conversion value 0 via
    /// `updatePostbackConversionValue`; on iOS 15.4–15.x it uses
    /// `updateConversionValue(0)`; on iOS 11.3–14 it calls the legacy
    /// `registerAppForAdNetworkAttribution`.
    public func registerForAttribution() {
        passthrough.registerForAttribution()
    }

    /// Update the SKAdNetwork conversion value. `fineValue` is 0–63. On iOS 16.1+ the
    /// optional `coarseValue` and `lockWindow` are applied; on earlier iOS they are
    /// ignored (only the fine value is representable). Safe no-op where SKAdNetwork is
    /// unavailable.
    public func updateConversionValue(
        _ fineValue: Int,
        coarseValue: AttriaxSkanCoarseValue? = nil,
        lockWindow: Bool = false,
        completion: ((Error?) -> Void)? = nil
    ) {
        passthrough.updateConversionValue(
            fineValue,
            coarseValue: coarseValue,
            lockWindow: lockWindow,
            completion: completion
        )
    }

    /// OPTIONAL: pull the project's configured SKAN conversion-value rules from the
    /// backend (`GET /api/sdk/v1/skan/conversion-config/:projectToken`). Best-effort;
    /// blocking I/O — call off the main thread. Returns the decoded config, or nil on
    /// any failure (unknown token → 404, offline, malformed).
    ///
    /// The rules are returned to the host to evaluate against its own event state —
    /// the SDK does not silently compose + apply a conversion value from server config
    /// alone (that requires the host's per-event/revenue state). Once the host
    /// resolves a fine/coarse value from the rules, it calls `updateConversionValue`.
    public func fetchConversionConfig() -> AttriaxSkanConversionConfig? {
        configFetcher.fetch()
    }
}

import Foundation
import AttriaxCore

/// SKAdNetwork coarse conversion-value tier (SKAN 4, iOS 16.1+).
public enum AttriaxSkanCoarseValue: String, Equatable {
    case low
    case medium
    case high
}

/// Public SKAdNetwork surface (`attriax.skan`).
///
/// A thin, HONEST passthrough over the KMP core's SKAN surface (which wraps Apple's
/// `SKAdNetwork` — the SDK does NOT reimplement Apple's attribution). Every call is
/// availability-gated inside the core; on a platform/OS without SKAdNetwork these are
/// safe no-ops. SKAN postbacks are DEVICE-only (the Simulator does not deliver them).
public final class AttriaxSkan {
    private let core: AttriaxCore.Attriax

    init(core: AttriaxCore.Attriax) {
        self.core = core
    }

    /// Register the app for SKAdNetwork attribution (the first postback). Idempotent
    /// and safe to call at launch — seeds conversion value 0 (the KMP core folds the
    /// legacy `registerAppForAdNetworkAttribution` / `updateConversionValue(0)` paths
    /// into a single conversion-value update).
    public func registerForAttribution() {
        _ = core.skan.updateConversionValue(fineValue: 0, coarseValue: nil, lockWindow: false)
    }

    /// Update the SKAdNetwork conversion value. `fineValue` is 0–63. On iOS 16.1+ the
    /// optional `coarseValue` and `lockWindow` are applied; on earlier iOS they are
    /// ignored. Safe no-op where SKAdNetwork is unavailable.
    public func updateConversionValue(
        _ fineValue: Int,
        coarseValue: AttriaxSkanCoarseValue? = nil,
        lockWindow: Bool = false,
        completion: ((Error?) -> Void)? = nil
    ) {
        _ = core.skan.updateConversionValue(
            fineValue: Int32(fineValue),
            coarseValue: AttriaxBridge.kmpCoarse(from: coarseValue),
            lockWindow: lockWindow
        )
        // The KMP update is synchronous and returns a status result; the passthrough
        // has no error channel, so the completion always resolves with nil.
        completion?(nil)
    }

    /// OPTIONAL: pull the project's configured SKAN conversion-value rules from the
    /// backend (Epic 12.2 CV management).
    ///
    /// Delegates to the KMP core's `fetchConversionConfig`, which GETs
    /// `/api/sdk/v1/skan/conversion-config/<projectToken>` and decodes the api
    /// `SdkCvConfigResponse`. Returns `nil` when the project has no schema, the token
    /// is unknown, or the pull fails — it is best-effort and never throws. The SDK does
    /// NOT auto-apply these rules; evaluate them against your own event/revenue state
    /// and call `updateConversionValue`. Performs blocking network I/O — call off the
    /// main thread.
    public func fetchConversionConfig() -> AttriaxSkanConversionConfig? {
        core.skan.fetchConversionConfig().map(AttriaxBridge.skanConversionConfig(from:))
    }
}

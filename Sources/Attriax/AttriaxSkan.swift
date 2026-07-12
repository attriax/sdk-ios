import Foundation
import AttriaxCore

/// SKAdNetwork coarse conversion-value tier (SKAN 4, iOS 16.1+).
public enum AttriaxSkanCoarseValue: String, Equatable {
    case low
    case medium
    case high
}

/// Public SKAdNetwork surface (`attriax.skan`; PARITY §13 / Epic 12.2, CHUNK C).
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

    /// OPTIONAL: pull the project's configured SKAN conversion-value rules.
    ///
    /// DEFERRED: the KMP `AttriaxSkan` surface exposes conversion-value updates but not
    /// the CV-config fetch, so this currently returns nil. The public type
    /// (`AttriaxSkanConversionConfig`) is retained; wire this through once the KMP core
    /// exposes the config pull (or a thin transport seam is added).
    public func fetchConversionConfig() -> AttriaxSkanConversionConfig? {
        nil
    }
}

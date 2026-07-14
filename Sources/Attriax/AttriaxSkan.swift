import Foundation
import AttriaxCore

/// SKAdNetwork coarse conversion-value tier (SKAN 4, iOS 16.1+).
public enum AttriaxSkanCoarseValue: String, Equatable {
    case low
    case medium
    case high
}

/// Outcome of a SKAdNetwork conversion-value update. Mirrors the KMP core's
/// `AttriaxSkanUpdateStatus` (and the Flutter reference) 1:1; raw values are the
/// snake_case wire strings. `notSupported` is returned on any non-iOS platform / OS
/// below the SKAN floor, where the update is a safe no-op.
public enum AttriaxSkanUpdateStatus: String, Equatable {
    case updated
    case skipped
    case alreadyAtOrAboveValue = "already_at_or_above_value"
    case invalidValue = "invalid_value"
    case disabled
    case notSupported = "not_supported"
    case error
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
    ///
    /// The KMP update is synchronous, so the resolved `AttriaxSkanUpdateStatus` is
    /// returned directly (no completion handler — the earlier `(Error?) -> Void` callback
    /// was misleading: it fired synchronously and always with `nil`, discarding the real
    /// status). Result is `@discardableResult` for fire-and-forget callers.
    @discardableResult
    public func updateConversionValue(
        _ fineValue: Int,
        coarseValue: AttriaxSkanCoarseValue? = nil,
        lockWindow: Bool = false
    ) -> AttriaxSkanUpdateStatus {
        let result = core.skan.updateConversionValue(
            fineValue: Int32(fineValue),
            coarseValue: AttriaxBridge.kmpCoarse(from: coarseValue),
            lockWindow: lockWindow
        )
        return AttriaxBridge.skanUpdateStatus(from: result)
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

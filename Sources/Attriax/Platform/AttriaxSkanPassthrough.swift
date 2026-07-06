import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// Thin passthrough over Apple's `SKAdNetwork` (PARITY §13; CHUNK C).
///
/// Version-gates the three eras of the SKAdNetwork conversion API, newest first:
///  - iOS 16.1+ (SKAN 4): `SKAdNetwork.updatePostbackConversionValue(_:coarseValue:
///    lockWindow:completionHandler:)` — fine + coarse tier + lock window.
///  - iOS 15.4–16.0: `SKAdNetwork.updateConversionValue(_:)` — fine only (the
///    completion-less signature landed in 15.4; the coarse/lockWindow variant is 16.1).
///  - iOS 11.3–15.3: legacy `SKAdNetwork.registerAppForAdNetworkAttribution()` +
///    `updateConversionValue(_:)` (deprecated but functional).
///
/// Framework-gated (`#if canImport(StoreKit)`) so non-Apple targets compile without
/// StoreKit. Every method is a safe no-op where SKAdNetwork is unavailable.
///
/// This is a HONEST passthrough: it does NOT reimplement Apple's attribution, it only
/// forwards the host's (or the CV-config helper's) resolved values to the OS.
struct AttriaxSkanPassthrough {

    /// Register for attribution — the first postback (conversion value 0).
    func registerForAttribution() {
        #if canImport(StoreKit)
        if #available(iOS 16.1, macCatalyst 16.1, *) {
            SKAdNetwork.updatePostbackConversionValue(0, coarseValue: .low) { _ in }
        } else if #available(iOS 15.4, macCatalyst 15.4, *) {
            SKAdNetwork.updateConversionValue(0)
        } else if #available(iOS 14.0, macCatalyst 14.0, *) {
            // registerAppForAdNetworkAttribution seeds the initial postback on the
            // 11.3–15.3 era (deprecated in 15.4 but still the correct call there).
            SKAdNetwork.registerAppForAdNetworkAttribution()
        }
        #endif
    }

    /// Update the conversion value. Fine 0–63; coarse/lockWindow honored on 16.1+.
    func updateConversionValue(
        _ fineValue: Int,
        coarseValue: AttriaxSkanCoarseValue?,
        lockWindow: Bool,
        completion: ((Error?) -> Void)?
    ) {
        let clamped = max(0, min(63, fineValue))
        #if canImport(StoreKit)
        if #available(iOS 16.1, macCatalyst 16.1, *) {
            let coarse = Self.mapCoarse(coarseValue ?? .low)
            SKAdNetwork.updatePostbackConversionValue(
                clamped,
                coarseValue: coarse,
                lockWindow: lockWindow
            ) { error in
                completion?(error)
            }
            return
        } else if #available(iOS 15.4, macCatalyst 15.4, *) {
            SKAdNetwork.updateConversionValue(clamped)
            completion?(nil)
            return
        } else if #available(iOS 14.0, macCatalyst 14.0, *) {
            SKAdNetwork.updateConversionValue(clamped)
            completion?(nil)
            return
        }
        #endif
        completion?(nil)
    }

    #if canImport(StoreKit)
    @available(iOS 16.1, macCatalyst 16.1, *)
    private static func mapCoarse(_ value: AttriaxSkanCoarseValue) -> SKAdNetwork.CoarseConversionValue {
        switch value {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
    #endif
}

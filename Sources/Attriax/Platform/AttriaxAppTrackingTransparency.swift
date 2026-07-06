import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(AdSupport)
import AdSupport
#endif

/// Platform ATT status reader backed by `ATTrackingManager` (PARITY §11; iOS 14+).
///
/// Doubly gated:
///  - `#if canImport(AppTrackingTransparency)` so non-Apple targets do not reference
///    the framework, and
///  - `@available(iOS 14, *)` at each call site because `ATTrackingManager` is iOS 14+.
///
/// On an OS below iOS 14 (or a platform without the framework), every call degrades
/// to `.unknown` and the prompt completes immediately — ATT is simply not a concept
/// there, and the SDK must run unchanged. Reading the status NEVER prompts.
final class AttriaxAppTrackingTransparencyReader: AttriaxAttStatusReader {

    func currentStatus() -> AttriaxAttStatus {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, macCatalyst 14, tvOS 14, *) {
            return Self.map(ATTrackingManager.trackingAuthorizationStatus)
        }
        #endif
        return .unknown
    }

    func requestAuthorization(_ completion: @escaping (AttriaxAttStatus) -> Void) {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, macCatalyst 14, tvOS 14, *) {
            ATTrackingManager.requestTrackingAuthorization { status in
                completion(Self.map(status))
            }
            return
        }
        #endif
        completion(.unknown)
    }

    #if canImport(AppTrackingTransparency)
    @available(iOS 14, macCatalyst 14, tvOS 14, *)
    private static func map(_ status: ATTrackingManager.AuthorizationStatus) -> AttriaxAttStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
    #endif
}

/// IDFA supplier backed by `ASIdentifierManager`, gated on ATT-authorization
/// (PARITY §2 IDFA rung; iOS 14+).
///
/// Returns the IDFA (`advertisingIdentifier`) ONLY when:
///  1. `collectAdvertisingId` is enabled in config, AND
///  2. the ATT status is `.authorized` (Apple zeroes the IDFA otherwise —
///     `00000000-0000-0000-0000-000000000000` — so reading it without authorization
///     is useless), AND
///  3. the resolved id is non-zero / non-empty.
///
/// Doubly gated (`#if canImport(AdSupport)` + the ATT check) so no AdSupport symbol
/// is referenced on non-Apple targets and the id is never consulted without
/// authorization. This is the supplier the `AttriaxSdk` factory wires into the
/// chunk-A IDFA seam; when ATT is not authorized it returns nil and device-identity
/// resolution falls through to IDFV / persistent storage.
struct AttriaxAttGatedAdvertisingIdSupplier {
    private let collectAdvertisingId: Bool
    private let attStatus: () -> AttriaxAttStatus

    init(collectAdvertisingId: Bool, attStatus: @escaping () -> AttriaxAttStatus) {
        self.collectAdvertisingId = collectAdvertisingId
        self.attStatus = attStatus
    }

    /// The ATT-authorized IDFA, or nil.
    func advertisingId() -> String? {
        guard collectAdvertisingId else { return nil }
        guard attStatus() == .authorized else { return nil }

        #if canImport(AdSupport)
        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        if idfa.isEmpty || idfa == Self.zeroIdfa { return nil }
        return idfa
        #else
        return nil
        #endif
    }

    /// The all-zero IDFA Apple returns when tracking is not authorized.
    private static let zeroIdfa = "00000000-0000-0000-0000-000000000000"
}

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// `AttriaxDeviceIdSources` backed by the iOS platform (PARITY §2, row D4).
///
///  - `idfv()` reads `UIDevice.current.identifierForVendor?.uuidString` (IDFV).
///  - `advertisingId()` returns nil unless `collectAdvertisingId` is true AND an
///    ATT-authorized IDFA has been supplied via `advertisingIdSupplier`.
///
/// The IDFA is intentionally INJECTED rather than resolved inline: reading
/// `ASIdentifierManager.advertisingIdentifier` is only meaningful once App
/// Tracking Transparency authorization is `.authorized`, and the ATT prompt +
/// AdSupport wiring is a CHUNK-C concern. Until then the host (or chunk C) wires
/// in a supplier that returns the IDFA only when ATT-authorized; when absent,
/// resolution falls through to the persistent-storage id (source
/// `persistent_storage`), and with an IDFV present the source is `ios_idfv`.
///
/// This keeps a clean ATT seam: no AdSupport / AppTrackingTransparency symbol is
/// referenced in this chunk, so the SDK links and runs without an ATT usage
/// description; chunk C supplies the real IDFA path.
final class AttriaxIOSDeviceIdSources: AttriaxDeviceIdSources {
    private let collectAdvertisingId: Bool
    private let advertisingIdSupplier: () -> String?

    init(collectAdvertisingId: Bool, advertisingIdSupplier: @escaping () -> String? = { nil }) {
        self.collectAdvertisingId = collectAdvertisingId
        self.advertisingIdSupplier = advertisingIdSupplier
    }

    func idfv() -> String? {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    func advertisingId() -> String? {
        guard collectAdvertisingId else { return nil }
        return advertisingIdSupplier()
    }
}

import Foundation
import AttriaxCore

/// Factory for the Attriax native iOS SDK (re-wrapped onto the shared KMP core).
///
/// `create` builds the KMP `AttriaxCore.Attriax` engine via `AttriaxApple` and wraps
/// it in the public `Attriax` facade. The engine owns transport, persistence,
/// connectivity, device identity, ATT/IDFA/ASA/SKAN/App-Attest, and the real
/// WKWebView User-Agent — all resolved inside `AttriaxCore`.
public enum AttriaxSdk {
    /// SDK release version.
    public static let version = AttriaxVersion.packageVersion

    /// Build a runtime for `config`. Call `initialize()` afterwards to bootstrap.
    ///
    /// - Parameter advertisingIdSupplier: retained for source compatibility. The KMP
    ///   core now resolves the IDFA itself (ATT-gated by `config.collectAdvertisingId`),
    ///   so a custom supplier is not forwarded; pass one only for legacy call sites.
    public static func create(
        config: AttriaxConfig,
        advertisingIdSupplier: (() -> String?)? = nil
    ) -> Attriax {
        _ = advertisingIdSupplier
        // userAgent nil → the KMP Apple layer resolves the REAL WKWebView Safari UA
        // (off the main thread), else a Safari-shaped fallback.
        let core = AttriaxCore.AttriaxApple.shared.create(
            config: AttriaxBridge.kmpConfig(from: config),
            userAgent: nil
        )
        return Attriax(core: core)
    }
}

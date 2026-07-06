import Foundation

/// Narrow ports (hexagonal boundaries) behind which all iOS-specific I/O lives.
///
/// Every port here is a plain Swift protocol/value type with no UIKit/Foundation-
/// networking types in its signature, so the pure engine and its tests depend only
/// on these abstractions. The platform implementations (`UserDefaults`,
/// `URLSession`, `UIDevice`, ATT/IDFA) live under `Platform/` and are never
/// touched by the pure-logic tests.

/// Key/value persistence port (backed by a suite-scoped `UserDefaults` on device).
protocol AttriaxKeyValueStore: AnyObject {
    func getString(_ key: String) -> String?
    func putString(_ key: String, _ value: String?)
    func remove(_ key: String)
}

/// Result of a single HTTP send.
struct AttriaxHttpResponse {
    let statusCode: Int
    /// Already envelope-unwrapped body (the value of the top-level `data` field,
    /// or the raw body when no envelope was present).
    let body: String?
    let headers: [String: String]

    init(statusCode: Int, body: String?, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

/// Transport failures, typed so the retry policy can classify them (mirrors the
/// Android `AttriaxHttpException`/`AttriaxTimeoutException`/`AttriaxTransportException`).
enum AttriaxTransportError: Error {
    case http(statusCode: Int, responseBody: String?, headers: [String: String])
    case timeout(underlying: Error?)
    case transport(underlying: Error?)
}

/// HTTP transport port. The single long-lived platform implementation stamps the
/// mandatory User-Agent (PARITY §8) on EVERY request and unwraps the `{data:...}`
/// envelope. Throws `AttriaxTransportError` on non-2xx / timeout / transport
/// failure so the retry policy can classify them. `post` is SYNCHRONOUS (blocking)
/// so the dispatcher — which runs on a dedicated background queue — reasons about
/// delivery sequentially, exactly like the Android OkHttp `execute()` path.
protocol AttriaxHttpClient: AnyObject {
    /// POST a JSON `body` to `path` (appended to the configured base URL).
    /// - Returns: the successful (2xx) response, envelope-unwrapped.
    /// - Throws: `AttriaxTransportError`.
    func post(_ path: String, _ body: String) throws -> AttriaxHttpResponse
}

/// Connectivity port. Implementations invoke `onConnectivityRestored` on regain.
protocol AttriaxConnectivityMonitor: AnyObject {
    func isConnected() -> Bool
    func register(_ onConnectivityRestored: @escaping () -> Void)
    func unregister()
}

/// Supplies the raw native device-id candidates used by
/// `AttriaxDeviceIdentityResolver`. The iOS implementation reads
/// `identifierForVendor` (IDFV) and, when ATT-authorized and enabled, the IDFA.
/// Both may be nil/unavailable.
///
/// The ATT/IDFA wiring is a CHUNK-C concern; this chunk supplies IDFV + a nil
/// IDFA seam (see `AttriaxDeviceSources` default). `advertisingId()` MUST return
/// nil unless ATT is authorized.
protocol AttriaxDeviceIdSources {
    /// `UIDevice.current.identifierForVendor?.uuidString` (IDFV), or nil.
    func idfv() -> String?
    /// IDFA (`ASIdentifierManager.advertisingIdentifier`), or nil unless
    /// ATT-authorized AND collection is enabled. Nil in this chunk's default seam.
    func advertisingId() -> String?
}

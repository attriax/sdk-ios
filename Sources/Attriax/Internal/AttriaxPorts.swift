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

    /// GET `path` (appended to the configured base URL). Used only by the CHUNK-C
    /// SKAN CV-config pull (a low-frequency, best-effort read). A default
    /// implementation throws `.transport` so existing fake transports (which only
    /// model POST) need not implement it; the real `AttriaxURLSessionClient`
    /// overrides it.
    /// - Returns: the successful (2xx) response, envelope-unwrapped.
    /// - Throws: `AttriaxTransportError`.
    func get(_ path: String) throws -> AttriaxHttpResponse
}

extension AttriaxHttpClient {
    func get(_ path: String) throws -> AttriaxHttpResponse {
        throw AttriaxTransportError.transport(underlying: nil)
    }
}

/// Connectivity port. Implementations invoke `onConnectivityRestored` on regain.
protocol AttriaxConnectivityMonitor: AnyObject {
    func isConnected() -> Bool
    func register(_ onConnectivityRestored: @escaping () -> Void)
    func unregister()
}

/// A cancellable, repeating scheduler port (PARITY §3, row S3 heartbeat timers).
///
/// The pure session-lifecycle manager schedules the heartbeat through this seam so
/// timers stay deterministic in tests (a fake scheduler can fire ticks on demand
/// with no wall-clock sleep). The iOS implementation runs a `Timer` on a dedicated
/// run-loop thread OFF the main thread; a scheduled task must never leak, so
/// `AttriaxScheduledHandle.cancel()` invalidates the underlying timer.
protocol AttriaxScheduler: AnyObject {
    /// Run `action` every `intervalMs` (first tick after one interval).
    func schedulePeriodic(intervalMs: Int64, action: @escaping () -> Void) -> AttriaxScheduledHandle
}

/// A handle to a scheduled repeating task; `cancel()` stops future ticks.
protocol AttriaxScheduledHandle: AnyObject {
    func cancel()
}

/// A scheduler that never fires (used by the pure engine + tests). The iOS factory
/// injects a real `AttriaxTimerScheduler`.
final class AttriaxNoopScheduler: AttriaxScheduler {
    private final class NoopHandle: AttriaxScheduledHandle {
        func cancel() {}
    }
    func schedulePeriodic(intervalMs: Int64, action: @escaping () -> Void) -> AttriaxScheduledHandle {
        NoopHandle()
    }
}

/// Binds app foreground/background/terminate detection to the session lifecycle
/// (PARITY §3, row S3). The engine calls `bind` once its session-lifecycle manager
/// is ready and `unbind` on reset/dispose. The iOS implementation subscribes to
/// `UIApplication` notifications; the pure engine + its tests use a no-op or fake
/// binder and drive the lifecycle manager directly.
protocol AttriaxLifecycleBinder: AnyObject {
    func bind()
    func unbind()
}

/// A no-op binder for tests / hosts that drive lifecycle transitions manually.
final class AttriaxNoopLifecycleBinder: AttriaxLifecycleBinder {
    func bind() {}
    func unbind() {}
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

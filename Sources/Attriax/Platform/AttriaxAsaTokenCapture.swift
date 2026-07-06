import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// Apple Search Ads / AdServices attribution-token capture (PARITY §12; Epic 8.5 /
/// CHUNK C). Captures `AAAttribution.attributionToken()` and POSTs it to
/// `POST /api/sdk/v1/asa/token` (wire body `{ projectToken, token }`, matching
/// `SdkAsaTokenDto`).
///
/// Availability + framework gating:
///  - `#if canImport(AdServices)` so non-Apple targets do not reference the framework, and
///  - `@available(iOS 14.3, macCatalyst 14.3, *)` because `AAAttribution` is iOS 14.3+.
///
/// On older iOS / a platform without AdServices, `capture` is a no-op — ASA is simply
/// unavailable and the SDK runs unchanged.
///
/// ## Best-effort, never blocks init
/// The whole flow is fire-and-forget on a background queue: `attributionToken()` can
/// throw (no token available, called too early, unsupported), and the POST can fail;
/// EITHER outcome is swallowed. It NEVER blocks or crashes init. Opt-in via
/// `AttriaxConfig.asaAttributionEnabled`; automatic-on-init when enabled.
///
/// The token is opaque: the SDK does not parse it (Apple's attribution payload is
/// fetched server-side from Apple with this token), so we only forward it verbatim.
struct AttriaxAsaTokenCapture {
    private let transport: AttriaxHttpClient
    private let projectToken: String
    private let queue: DispatchQueue

    init(transport: AttriaxHttpClient, projectToken: String, queue: DispatchQueue) {
        self.transport = transport
        self.projectToken = projectToken
        self.queue = queue
    }

    /// Capture + POST the AdServices attribution token, off the main thread. Returns
    /// immediately; the work runs asynchronously and swallows every failure.
    func capture() {
        let projectToken = self.projectToken
        if projectToken.isEmpty { return }
        let transport = self.transport

        queue.async {
            guard let token = Self.fetchAttributionToken() else { return }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }

            var body = AttriaxJSONObject()
            body["projectToken"] = projectToken
            body["token"] = trimmed
            // Best-effort: a transport error here is expected offline and must never
            // surface — it is swallowed exactly like the Android/Flutter ASA path.
            _ = try? transport.post(AttriaxEndpoints.asaToken, AttriaxJson.encode(body))
        }
    }

    /// Reads `AAAttribution.attributionToken()` when available, else nil. Any thrown
    /// error (token unavailable / unsupported) degrades to nil.
    private static func fetchAttributionToken() -> String? {
        #if canImport(AdServices)
        if #available(iOS 14.3, macCatalyst 14.3, *) {
            return try? AAAttribution.attributionToken()
        }
        #endif
        return nil
    }
}

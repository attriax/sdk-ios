import Foundation

/// Pure deferred deep-link recovery from the app-open RESPONSE (PARITY §6, row DL3).
/// Mirrors the Flutter reference (buildDeferredUri / buildDeferredResolution +
/// handleDeferredAppOpen) and the Android `AttriaxDeepLinkDeferredRecovery`.
///
/// The open response envelope is `{ data: { ... } }`; the transport has already
/// unwrapped it, so `recover` receives the inner `data` map. Source PREFERENCE
/// order for the deferred URI is:
///
///   1. `data.deepLink.uri` (falls back to a path-derived URI)
///   2. `data.reinstallReferrer.deepLinkUri`
///   3. `data.installReferrer.deepLinkUri`
///
/// A response with `installState == "appDataClear"` is skipped entirely (a data
/// clear is not a genuine deferred-conversion signal). `found` is true only when a
/// concrete `deepLink` object is present.
enum AttriaxDeepLinkDeferredRecovery {

    static let installStateAppDataClear = "appDataClear"

    /// Attempt to recover a deferred deep-link event from an unwrapped app-open
    /// response `data` map. Returns nil when there is nothing to emit (no data,
    /// appDataClear, or no recoverable URI/deepLink at all).
    ///
    /// - Parameter fallbackTimeMs: used for clicked/consumed timestamps when the
    ///   response omits them.
    static func recover(_ data: [String: Any?]?, fallbackTimeMs: Int64) -> AttriaxDeepLinkEvent? {
        guard let data = data else { return nil }
        if (data["installState"] as? String) == installStateAppDataClear { return nil }

        let deepLink = data["deepLink"] as? [String: Any?]
        let reinstall = data["reinstallReferrer"] as? [String: Any?]
        let install = data["installReferrer"] as? [String: Any?]

        let uriString: String?
        if let u = deepLink?["uri"] as? String {
            uriString = u
        } else if let p = deepLink?["path"] as? String {
            uriString = AttriaxDeepLinkResolver.pathAsUri(AttriaxDeepLinkResolver.normalizeLinkPath(p))
        } else if let ru = reinstall?["deepLinkUri"] as? String {
            uriString = ru
        } else if let iu = install?["deepLinkUri"] as? String {
            uriString = iu
        } else {
            return nil
        }

        guard let uri = AttriaxUri.parse(uriString) else { return nil }

        let clickedAt = timeOrNil(data["deepLinkClickedAt"] ?? nil)
            ?? timeOrNil(data["acceptedAt"] ?? nil)
            ?? fallbackTimeMs
        let consumedAt = timeOrNil(data["deepLinkConsumedAt"] ?? nil)
            ?? timeOrNil(data["acceptedAt"] ?? nil)
            ?? fallbackTimeMs

        return AttriaxDeepLinkEvent(
            uri: uri,
            clickedAtMs: clickedAt,
            consumedAtMs: consumedAt,
            // Deferred is a confirmed match only when a concrete deepLink is present.
            found: deepLink != nil,
            trigger: .deferred,
            isAttriaxSubDomain: AttriaxDeepLinkResolver.isAttriaxDomain(uri),
            status: deepLink != nil ? .matched : .unmatched,
            data: AttriaxDeepLinkResolver.stringMap(
                deepLink?["data"]
                    ?? reinstall?["deepLinkData"]
                    ?? install?["deepLinkData"]
                    ?? nil
            ),
            utm: AttriaxDeepLinkResolver.stringMap(
                deepLink?["utm"]
                    ?? referrerUtm(reinstall)
                    ?? referrerUtm(install)
                    ?? nil
            )
        )
    }

    /// The install-referrer result carries UTM fields flat (source/medium/campaign/
    /// term/content); collect the present ones into a map for the event `utm`.
    private static func referrerUtm(_ referrer: [String: Any?]?) -> [String: Any?]? {
        guard let referrer = referrer else { return nil }
        var utm = AttriaxJSONObject()
        for key in utmKeys {
            if let v = referrer[key] as? String { utm[key] = v }
        }
        return utm.isEmpty ? nil : utm
    }

    /// Deferred timestamps arrive as numbers; we only need a monotone ordering.
    private static func timeOrNil(_ value: Any?) -> Int64? {
        switch value {
        case let i as Int64: return i
        case let i as Int: return Int64(i)
        case let d as Double: return Int64(d)
        default: return nil
        }
    }

    private static let utmKeys = ["source", "medium", "campaign", "term", "content"]
}

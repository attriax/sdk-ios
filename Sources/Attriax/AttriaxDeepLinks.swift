import Foundation

/// Public deep-link surface exposed as `attriax.deepLinks` (PARITY §6, rows DL1–DL4).
/// Mirrors the Flutter reference `AttriaxDeepLinks` and the Android `AttriaxDeepLinks`,
/// adapted to a native library: instead of a platform EventChannel, the host app
/// forwards its iOS Universal Links / custom-scheme URLs from its AppDelegate /
/// SceneDelegate via `handleUniversalLink` / `handleUrl`.
///
/// Observers use a simple closure-listener pattern (`addListener` returns a token;
/// pass it to `removeListener`) — no Combine dependency required.
public final class AttriaxDeepLinks {
    private unowned let engine: Attriax

    init(engine: Attriax) {
        self.engine = engine
    }

    // MARK: - native capture (row DL1)

    /// Feed an incoming iOS Universal Link (from
    /// `application(_:continue:restorationHandler:)` /
    /// `scene(_:continue:)`). The `NSUserActivity.webpageURL` string is what you
    /// forward here. Resolution happens asynchronously; observe `addListener` for the
    /// resolved event.
    ///
    /// - Parameters:
    ///   - url: the Universal Link URL string.
    ///   - isLaunch: pass `true` when this link launched the app (cold start), so it
    ///     is treated as the initial link.
    public func handleUniversalLink(_ url: String, isLaunch: Bool = false) {
        engine.handleIncomingDeepLink(url, isInitialLink: isLaunch)
    }

    /// Feed an incoming custom-scheme URL (from `application(_:open:options:)` /
    /// `scene(_:openURLContexts:)`). `isLaunch` marks the launch link (cold start).
    ///
    /// This is the iOS analog of Android's `onNewIntent` / launch-Intent handling.
    public func handleUrl(_ url: String, isLaunch: Bool = false) {
        engine.handleIncomingDeepLink(url, isInitialLink: isLaunch)
    }

    /// Mark the initial-link probe complete when the app launched WITHOUT a deep
    /// link, so `waitForInitialDeepLink` / `initialDeepLinkResolved` do not stall.
    /// Call this from your launch path when there was no Universal Link / URL.
    public func completeLaunchWithoutLink() {
        engine.completeInitialDeepLinkIfAbsent()
    }

    // MARK: - observers

    /// Broadcast handled deep-link events (resolved incoming + deferred matches).
    /// Returns a token; pass it to `removeListener` to unsubscribe.
    @discardableResult
    public func addListener(_ listener: @escaping AttriaxDeepLinkListener) -> AttriaxDeepLinkListenerToken {
        engine.addDeepLinkListener(listener)
    }

    public func removeListener(_ token: AttriaxDeepLinkListenerToken) {
        engine.removeDeepLinkListener(token)
    }

    /// Broadcast raw (pre-resolution) deep-link inputs from native capture.
    @discardableResult
    public func addRawListener(_ listener: @escaping AttriaxRawDeepLinkListener) -> AttriaxDeepLinkListenerToken {
        engine.addRawDeepLinkListener(listener)
    }

    public func removeRawListener(_ token: AttriaxDeepLinkListenerToken) {
        engine.removeRawDeepLinkListener(token)
    }

    // MARK: - state

    /// Launch raw deep-link event captured during startup, when one was present.
    public var rawInitialDeepLink: AttriaxRawDeepLinkEvent? { engine.rawInitialDeepLink }

    /// Most recent handled deep-link event seen by the SDK.
    public var latestDeepLink: AttriaxDeepLinkEvent? { engine.latestDeepLink }

    /// Launch deep-link event captured during startup, when one was present. Stays
    /// nil until the initial-link probe completes; use `initialDeepLinkResolved` to
    /// distinguish "not resolved yet" from "resolved and none found".
    public var initialDeepLink: AttriaxDeepLinkEvent? { engine.initialDeepLink }

    /// Whether the initial-link probe has completed for this app session.
    public var initialDeepLinkResolved: Bool { engine.isInitialDeepLinkResolved }

    /// Block until the initial-link probe finishes, returning the launch deep-link
    /// event (or nil when none was present). MUST be called off the main thread.
    public func waitForInitialDeepLink() -> AttriaxDeepLinkEvent? {
        engine.waitForInitialDeepLink()
    }

    // MARK: - manual / dynamic links

    /// Record a deep link manually. Use when your router receives a URL before the
    /// SDK captures it. `metadata` is sent with the resolution request; the resolved
    /// event is emitted to observers.
    public func recordDeepLink(
        _ url: String,
        metadata: [String: Any?]? = nil,
        source: String = "manual"
    ) {
        engine.recordDeepLink(url, metadata: metadata, source: source)
    }

    /// Create a short dynamic link. Attriax generates the short code server-side and
    /// returns the shareable URL + persisted record. Performs blocking I/O — call off
    /// the main thread. Throws the transport error on failure.
    ///
    /// Note: `redirects.ios` / `redirects.android` are BOOLEAN flags (not URLs).
    @discardableResult
    public func createDynamicLink(
        name: String? = nil,
        destinationUrl: String? = nil,
        group: String? = nil,
        prefix: String? = nil,
        socialPreview: AttriaxDynamicLinkSocialPreview? = nil,
        utms: AttriaxDynamicLinkUtms? = nil,
        redirects: AttriaxDynamicLinkRedirects? = nil,
        data: [String: Any?]? = nil
    ) throws -> AttriaxCreateDynamicLinkResult {
        try engine.createDynamicLink(
            name: name,
            destinationUrl: destinationUrl,
            group: group,
            prefix: prefix,
            socialPreview: socialPreview,
            utms: utms,
            redirects: redirects,
            data: data
        )
    }
}

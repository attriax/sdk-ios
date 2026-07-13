import Foundation
import AttriaxCore

/// Public deep-link surface exposed as `attriax.deepLinks`.
///
/// The host forwards its iOS Universal Links / custom-scheme URLs from its
/// AppDelegate / SceneDelegate via `handleUniversalLink` / `handleUrl`; the KMP core
/// resolves them and emits events to registered closure listeners. Observers use a
/// simple token pattern (`addListener` returns a token; pass it to `removeListener`).
public final class AttriaxDeepLinks {
    private let core: AttriaxCore.Attriax
    private let lock = NSLock()
    private var listeners = [String: DeepLinkListenerAdapter]()
    private var rawListeners = [String: RawDeepLinkListenerAdapter]()

    init(core: AttriaxCore.Attriax) {
        self.core = core
    }

    // MARK: - native capture

    /// Feed an incoming iOS Universal Link. Pass `isLaunch: true` when this link
    /// launched the app (cold start).
    public func handleUniversalLink(_ url: String, isLaunch: Bool = false) {
        core.deepLinks.handleUri(rawUri: url, isInitialLink: isLaunch)
    }

    /// Feed an incoming custom-scheme URL. `isLaunch` marks the launch link.
    public func handleUrl(_ url: String, isLaunch: Bool = false) {
        core.deepLinks.handleUri(rawUri: url, isInitialLink: isLaunch)
    }

    /// Mark the initial-link probe complete when the app launched WITHOUT a deep link.
    ///
    /// NOTE: the KMP core does not expose an explicit "no launch link" completion; the
    /// initial-link state resolves through `handleUri` / the core's own probe. This is
    /// therefore a no-op today — call it for forward-compatibility; see the re-wrap
    /// report for the gap.
    public func completeLaunchWithoutLink() {
        // No KMP equivalent — intentionally a no-op (documented gap).
    }

    // MARK: - observers

    @discardableResult
    public func addListener(_ listener: @escaping AttriaxDeepLinkListener) -> AttriaxDeepLinkListenerToken {
        let id = UUID().uuidString
        let adapter = DeepLinkListenerAdapter(listener)
        lock.lock()
        listeners[id] = adapter
        lock.unlock()
        core.deepLinks.addListener(listener: adapter)
        return AttriaxDeepLinkListenerToken(id: id)
    }

    public func removeListener(_ token: AttriaxDeepLinkListenerToken) {
        lock.lock()
        let adapter = listeners.removeValue(forKey: token.id)
        lock.unlock()
        if let adapter = adapter {
            core.deepLinks.removeListener(listener: adapter)
        }
    }

    @discardableResult
    public func addRawListener(_ listener: @escaping AttriaxRawDeepLinkListener) -> AttriaxDeepLinkListenerToken {
        let id = UUID().uuidString
        let adapter = RawDeepLinkListenerAdapter(listener)
        lock.lock()
        rawListeners[id] = adapter
        lock.unlock()
        core.deepLinks.addRawListener(listener: adapter)
        return AttriaxDeepLinkListenerToken(id: id)
    }

    public func removeRawListener(_ token: AttriaxDeepLinkListenerToken) {
        lock.lock()
        let adapter = rawListeners.removeValue(forKey: token.id)
        lock.unlock()
        if let adapter = adapter {
            core.deepLinks.removeRawListener(listener: adapter)
        }
    }

    // MARK: - state

    public var rawInitialDeepLink: AttriaxRawDeepLinkEvent? {
        core.deepLinks.rawInitialDeepLink.map(AttriaxBridge.rawDeepLinkEvent(from:))
    }

    public var latestDeepLink: AttriaxDeepLinkEvent? {
        core.deepLinks.latestDeepLink.map(AttriaxBridge.deepLinkEvent(from:))
    }

    public var initialDeepLink: AttriaxDeepLinkEvent? {
        core.deepLinks.initialDeepLink.map(AttriaxBridge.deepLinkEvent(from:))
    }

    public var initialDeepLinkResolved: Bool {
        core.deepLinks.initialDeepLinkResolved
    }

    /// Block until the initial-link probe finishes. MUST be called off the main thread.
    public func waitForInitialDeepLink() -> AttriaxDeepLinkEvent? {
        core.deepLinks.waitForInitialDeepLink().map(AttriaxBridge.deepLinkEvent(from:))
    }

    // MARK: - manual / dynamic links

    /// Record a deep link manually (e.g. your router received a URL before the SDK).
    public func recordDeepLink(
        _ url: String,
        metadata: [String: Any?]? = nil,
        source: String = "manual"
    ) {
        _ = core.deepLinks.recordDeepLink(
            uri: url,
            metadata: AttriaxBridge.objcMap(metadata),
            source: source
        )
    }

    /// Create a short dynamic link. Performs blocking I/O — call off the main thread.
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
        let result = core.deepLinks.createDynamicLink(
            name: name,
            destinationUrl: destinationUrl,
            group: group,
            prefix: prefix,
            socialPreview: AttriaxBridge.kmpSocialPreview(from: socialPreview),
            utms: AttriaxBridge.kmpUtms(from: utms),
            redirects: AttriaxBridge.kmpRedirects(from: redirects),
            data: AttriaxBridge.objcMap(data)
        )
        return AttriaxBridge.createDynamicLinkResult(from: result)
    }
}

// MARK: - KMP listener adapters

/// Bridges a closure `AttriaxDeepLinkListener` to the KMP core's listener protocol.
private final class DeepLinkListenerAdapter: NSObject, AttriaxCore.AttriaxDeepLinkListener {
    private let callback: AttriaxDeepLinkListener

    init(_ callback: @escaping AttriaxDeepLinkListener) {
        self.callback = callback
    }

    func onDeepLink(event: AttriaxCore.AttriaxDeepLinkEvent) {
        callback(AttriaxBridge.deepLinkEvent(from: event))
    }
}

/// Bridges a closure `AttriaxRawDeepLinkListener` to the KMP core's listener protocol.
private final class RawDeepLinkListenerAdapter: NSObject, AttriaxCore.AttriaxRawDeepLinkListener {
    private let callback: AttriaxRawDeepLinkListener

    init(_ callback: @escaping AttriaxRawDeepLinkListener) {
        self.callback = callback
    }

    func onRawDeepLink(event: AttriaxCore.AttriaxRawDeepLinkEvent) {
        callback(AttriaxBridge.rawDeepLinkEvent(from: event))
    }
}

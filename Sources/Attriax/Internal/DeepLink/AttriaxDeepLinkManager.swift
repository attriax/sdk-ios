import Foundation

/// Owns deep-link listener lifecycle, near-duplicate suppression, initial-link
/// probe state, deferred fire-once recovery, and observer fan-out (PARITY §6, rows
/// DL1–DL4). Mirrors the Flutter reference `attriax_deep_link_manager.dart` +
/// `attriax_deep_link_listener.dart` and the Android `AttriaxDeepLinkManager`,
/// adapted to the engine's plain-thread / closure-listener model (no Combine).
///
/// Network dispatch is delegated to `resolveDispatch` (supplied by the engine) so
/// this coordinator stays free of transport/queue concerns and remains easy to test
/// with a fake dispatcher. The pure URI/normalization/recovery logic lives in
/// `AttriaxDeepLinkResolver` / `AttriaxDeepLinkDeferredRecovery`.
final class AttriaxDeepLinkManager {
    /// Dispatch a resolve request for `uri` with the given metadata + source. The
    /// engine builds the DTO, gates it through consent, and enqueues it; when the
    /// backend responds it calls back with the decoded resolution `data` map (or nil
    /// on failure), which this manager turns into an emitted event.
    typealias ResolveDispatch = (
        _ uri: AttriaxUri,
        _ metadata: [String: Any?],
        _ source: String,
        _ isInitialLink: Bool,
        _ onResolved: @escaping ([String: Any?]?) -> Void
    ) -> Void

    private let nowMs: () -> Int64
    /// Late-bound so the engine can construct the manager before `self` is fully
    /// initialized, then wire the dispatch closure that captures `self` weakly.
    /// Set once at composition; guarded by `lock` for a safe publish.
    private var resolveDispatch: ResolveDispatch?
    private let readDeferredHandled: () -> Bool
    private let writeDeferredHandled: (Bool) -> Void
    private let dedupWindowMs: Int64

    private let lock = NSRecursiveLock()

    private var deepLinkListeners = [String: AttriaxDeepLinkListener]()
    private var rawListeners = [String: AttriaxRawDeepLinkListener]()

    private var lastHandledRaw: String?
    private var lastHandledAtMs: Int64 = 0

    private var latestEvent: AttriaxDeepLinkEvent?
    private var initialEvent: AttriaxDeepLinkEvent?
    private var rawInitialEvent: AttriaxRawDeepLinkEvent?
    private var initialResolvedFlag = false
    private let initialLatch = DispatchSemaphore(value: 0)
    private var deferredFiredThisRuntime = false

    init(
        nowMs: @escaping () -> Int64,
        resolveDispatch: ResolveDispatch? = nil,
        readDeferredHandled: @escaping () -> Bool,
        writeDeferredHandled: @escaping (Bool) -> Void,
        dedupWindowMs: Int64 = defaultDedupWindowMs
    ) {
        self.nowMs = nowMs
        self.resolveDispatch = resolveDispatch
        self.readDeferredHandled = readDeferredHandled
        self.writeDeferredHandled = writeDeferredHandled
        self.dedupWindowMs = dedupWindowMs
    }

    /// Wire (once) the resolve-dispatch closure. Called by the engine after `self`
    /// is fully constructed so the closure can capture the engine weakly.
    func setResolveDispatch(_ dispatch: @escaping ResolveDispatch) {
        withLock { resolveDispatch = dispatch }
    }

    var latestDeepLink: AttriaxDeepLinkEvent? { withLock { latestEvent } }
    var initialDeepLink: AttriaxDeepLinkEvent? { withLock { initialEvent } }
    var rawInitialDeepLink: AttriaxRawDeepLinkEvent? { withLock { rawInitialEvent } }
    var isInitialDeepLinkResolved: Bool { withLock { initialResolvedFlag } }

    /// Register a deep-link listener. If a deep link has ALREADY been emitted (e.g.
    /// a deferred link recovered from the app-open response before the host wired its
    /// listener), it is replayed to the new listener immediately so a late subscriber
    /// never misses the current value. Mirrors the reference `latestDeepLink`-backed
    /// broadcast semantics.
    @discardableResult
    func addListener(_ listener: @escaping AttriaxDeepLinkListener) -> AttriaxDeepLinkListenerToken {
        let token = AttriaxDeepLinkListenerToken(id: AttriaxIdGenerator.generate())
        // Synchronize add + replay against emit on `lock` so a concurrent emit never
        // double-delivers the same event.
        let replay: AttriaxDeepLinkEvent? = withLock {
            deepLinkListeners[token.id] = listener
            return latestEvent
        }
        if let replay = replay { listener(replay) }
        return token
    }

    func removeListener(_ token: AttriaxDeepLinkListenerToken) {
        withLock { _ = deepLinkListeners.removeValue(forKey: token.id) }
    }

    @discardableResult
    func addRawListener(_ listener: @escaping AttriaxRawDeepLinkListener) -> AttriaxDeepLinkListenerToken {
        let token = AttriaxDeepLinkListenerToken(id: AttriaxIdGenerator.generate())
        withLock { rawListeners[token.id] = listener }
        return token
    }

    func removeRawListener(_ token: AttriaxDeepLinkListenerToken) {
        withLock { _ = rawListeners.removeValue(forKey: token.id) }
    }

    /// Block until the initial-link probe completes, returning the launch deep-link
    /// event (or nil when none was present). Returns immediately once resolved.
    /// MUST be called off the main thread (it blocks).
    func waitForInitialDeepLink(timeoutMs: Int64 = defaultWaitTimeoutMs) -> AttriaxDeepLinkEvent? {
        if withLock({ initialResolvedFlag }) { return withLock { initialEvent } }
        _ = initialLatch.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        return withLock { initialEvent }
    }

    /// Mark the initial-link probe complete with no launch link present.
    func completeInitialLinkIfAbsent() {
        let shouldSignal: Bool = withLock {
            if initialResolvedFlag { return false }
            initialResolvedFlag = true
            return true
        }
        if shouldSignal { initialLatch.signal() }
    }

    /// Feed a raw incoming link (from a forwarded launch/foreground URL). Applies the
    /// 2s dedup window, publishes the raw event, then dispatches a resolve request;
    /// the resolved event is emitted to observers when the backend responds.
    ///
    /// - Parameters:
    ///   - isInitialLink: true for the launch link captured during startup.
    ///   - source: the resolve `source` tag (defaults to `attriax_sdk`).
    func handleIncomingLink(
        _ rawUri: String,
        isInitialLink: Bool,
        source: String = sourceAutomatic
    ) {
        guard let uri = AttriaxUri.parse(rawUri) else {
            if isInitialLink { completeInitialLinkIfAbsent() }
            return
        }
        let receivedAt = nowMs()
        if isDuplicate(uri.stringValue, nowMs: receivedAt) {
            if isInitialLink { completeInitialLinkIfAbsent() }
            return
        }

        let raw = AttriaxRawDeepLinkEvent(uri: uri, receivedAtMs: receivedAt, isInitial: isInitialLink)
        let rawRecipients: [AttriaxRawDeepLinkListener] = withLock {
            if isInitialLink { rawInitialEvent = raw }
            return Array(rawListeners.values)
        }
        rawRecipients.forEach { $0(raw) }

        let metadata = AttriaxDeepLinkResolver.buildResolveMetadata(uri, isInitialLink: isInitialLink)
        guard let dispatch = withLock({ resolveDispatch }) else {
            if isInitialLink { completeInitialLinkIfAbsent() }
            return
        }
        dispatch(uri, metadata, source, isInitialLink) { [weak self] data in
            guard let self = self else { return }
            let trigger: AttriaxDeepLinkTrigger = isInitialLink ? .coldStart : .foreground
            let event: AttriaxDeepLinkEvent?
            if let data = data {
                event = AttriaxDeepLinkResolver.buildResolution(
                    result: AttriaxDeepLinkResolver.decodeResolution(data),
                    clickedAtMs: receivedAt,
                    consumedAtMs: self.nowMs(),
                    trigger: trigger,
                    fallbackUri: uri,
                    rawEvent: raw
                )
            } else {
                event = nil
            }
            if isInitialLink {
                self.withLock { self.initialEvent = event }
                self.completeInitialLinkIfAbsent()
            }
            if let event = event { self.emit(event) }
        }
    }

    /// Record a manual deep-link conversion (public `recordDeepLink`). Behaves like
    /// an incoming link but with a caller-supplied source + optional metadata and
    /// WITHOUT dedup/initial-link probing. The resolved event is emitted to observers.
    func recordDeepLink(
        _ rawUri: String,
        metadata: [String: Any?]?,
        source: String = sourceManual
    ) {
        guard let uri = AttriaxUri.parse(rawUri) else { return }
        let receivedAt = nowMs()
        let merged = AttriaxDeepLinkResolver.buildResolveMetadata(uri, isInitialLink: false, extra: metadata)
        guard let dispatch = withLock({ resolveDispatch }) else { return }
        dispatch(uri, merged, source, false) { [weak self] data in
            guard let self = self, let data = data else { return }
            self.emit(
                AttriaxDeepLinkResolver.buildResolution(
                    result: AttriaxDeepLinkResolver.decodeResolution(data),
                    clickedAtMs: receivedAt,
                    consumedAtMs: self.nowMs(),
                    trigger: .foreground,
                    fallbackUri: uri
                )
            )
        }
    }

    /// Recover a deferred deep link from the app-open RESPONSE (row DL3). Fires at
    /// most ONCE (guarded in-memory for this runtime AND by the persisted flag), and
    /// is skipped on `appDataClear`.
    func handleDeferredAppOpen(_ openResponseData: [String: Any?]?) {
        let alreadyFired: Bool = withLock { deferredFiredThisRuntime }
        if alreadyFired { return }
        if readDeferredHandled() { return }
        guard let event = AttriaxDeepLinkDeferredRecovery.recover(openResponseData, fallbackTimeMs: nowMs()) else {
            return
        }
        let claimed: Bool = withLock {
            if deferredFiredThisRuntime { return false }
            deferredFiredThisRuntime = true
            return true
        }
        if !claimed { return }
        writeDeferredHandled(true)
        emit(event)
    }

    func reset() {
        withLock {
            deepLinkListeners.removeAll()
            rawListeners.removeAll()
            lastHandledRaw = nil
            lastHandledAtMs = 0
            latestEvent = nil
            initialEvent = nil
            rawInitialEvent = nil
            deferredFiredThisRuntime = false
            // Leave the initial-latch state alone: any pending waiter is released via
            // completeInitialLinkIfAbsent on a fresh runtime, not on reset.
        }
    }

    private func emit(_ event: AttriaxDeepLinkEvent) {
        // Hold `lock` so a concurrent addListener (which also holds it) cannot both
        // observe this event as latestEvent AND be in the listener list for this
        // emit — otherwise a mid-emit registration would receive the event twice.
        let recipients: [AttriaxDeepLinkListener] = withLock {
            latestEvent = event
            return Array(deepLinkListeners.values)
        }
        recipients.forEach { $0(event) }
    }

    private func isDuplicate(_ uriString: String, nowMs: Int64) -> Bool {
        withLock {
            let prevUri = lastHandledRaw
            let prevAt = lastHandledAtMs
            lastHandledRaw = uriString
            lastHandledAtMs = nowMs
            return prevUri == uriString && nowMs - prevAt < dedupWindowMs
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    static let defaultDedupWindowMs: Int64 = 2_000
    static let defaultWaitTimeoutMs: Int64 = 10_000
    static let sourceAutomatic = "attriax_sdk"
    static let sourceManual = "manual"
}

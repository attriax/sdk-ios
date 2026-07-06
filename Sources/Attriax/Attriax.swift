import Foundation

/// Attriax native iOS SDK core engine (Epic 9.3, CHUNK A: core runtime + tracking API).
///
/// Composition root that wires the pure engine (config, device identity, queue,
/// retry, batching, dispatcher, session snapshot machine) to its iOS I/O ports.
/// Implements the init → app-open bootstrap (rows I1/O1/O3), the frozen build-time
/// identity stamping (row D3), the session restore + initial START / recovered-END
/// telemetry (rows S1/S2/S5), and the tracking enqueue path (§4).
///
/// CHUNK-B seams left intentionally UNWIRED here (do NOT build in this chunk):
///  - consent + anonymous mode (the enqueue gate is `enabled`-only for now; the
///    consent-aware `enqueueTracked` gate + queue-rewrite passes land in B),
///  - deep links (resolve dispatch + deferred recovery from the open response),
///  - session LIFECYCLE timers (heartbeat / foreground-background transitions +
///    the batch keep-alive injection) — the pure snapshot machine is present, but
///    no timer drives it and the dispatcher keep-alive builder is nil,
///  - ATT / ASA / SKAN / App Attest (chunk C — the IDFA source seam returns nil).
public final class Attriax {
    private let config: AttriaxConfig
    private let store: AttriaxKeyValueStore
    private let transport: AttriaxHttpClient
    private let connectivity: AttriaxConnectivityMonitor
    private let context: AttriaxContextSnapshot
    private let deviceIdentityStore: AttriaxDeviceIdentityStore
    private let clock: AttriaxClock

    private let queue: AttriaxQueueManager
    private var dispatcher: AttriaxDispatcher!
    private let sessionManager: AttriaxSessionManager

    /// Serial background queue for flushes (mirrors the Android single-thread flush
    /// executor). All network I/O runs here, off the caller's thread.
    private let flushQueue = DispatchQueue(label: "com.attriax.sdk.flush")

    private let stateLock = NSRecursiveLock()
    private var initializedFlag = false
    private var appOpenScheduledFlag = false
    private var enabledFlag = true
    private var deviceIdentity: ResolvedDeviceId?
    private var firstLaunchFlag = true

    /// Public tracking / revenue / identify surface (PARITY §4).
    public private(set) lazy var tracking = AttriaxTracking(engine: self)

    init(
        config: AttriaxConfig,
        store: AttriaxKeyValueStore,
        transport: AttriaxHttpClient,
        connectivity: AttriaxConnectivityMonitor,
        context: AttriaxContextSnapshot,
        deviceIdentityStore: AttriaxDeviceIdentityStore,
        clock: AttriaxClock = AttriaxSystemClock()
    ) {
        self.config = config
        self.store = store
        self.transport = transport
        self.connectivity = connectivity
        self.context = context
        self.deviceIdentityStore = deviceIdentityStore
        self.clock = clock

        self.queue = AttriaxQueueManager(store: store, maxQueueSize: config.maxQueueSize)
        self.sessionManager = AttriaxSessionManager(
            clock: clock,
            snapshotStore: AttriaxSessionSnapshotStore(store: store),
            heartbeatIntervalMs: config.sessionHeartbeatIntervalMs,
            firstLaunchHeartbeatIntervalMs: config.firstLaunchSessionHeartbeatIntervalMs,
            generateSessionId: { AttriaxIdGenerator.generate() }
        )
        self.dispatcher = AttriaxDispatcher(
            queue: queue,
            transport: transport,
            clock: clock,
            onDelivered: { [weak self] queued, response in
                self?.onRequestDelivered(queued, response)
            },
            // CHUNK B: session keep-alive injection + delivery callback are nil here.
            buildSessionKeepAliveBatch: nil,
            onSessionKeepAliveDelivered: nil
        )
    }

    // MARK: - public state

    public var isInitialized: Bool { withState { initializedFlag } }
    public var isFirstLaunch: Bool { withState { firstLaunchFlag } }
    public var deviceId: String? { withState { deviceIdentity?.value } }

    public var enabled: Bool {
        get { withState { enabledFlag } }
        set { withState { enabledFlag = newValue } }
    }

    /// The current session snapshot, or nil when none is active.
    public var currentSession: AttriaxSessionSnapshot? { sessionManager.currentSession }

    // Engine accessors used by the tracking surface (identity is frozen at build
    // time — the surface reads the same resolved identity the engine holds).
    var contextSnapshot: AttriaxContextSnapshot { context }
    var resolvedDeviceId: String? { withState { deviceIdentity?.value } }
    var resolvedDeviceIdSource: String? { withState { deviceIdentity?.source } }
    var isTrackingEnabled: Bool { withState { enabledFlag } }
    var projectTokenForTracking: String { config.normalizedProjectToken }

    // MARK: - init / lifecycle

    /// Bootstrap the runtime (PARITY §1 init sequence):
    ///  1. restore persisted state (device id, first-launch flag, session snapshot),
    ///  2. generate-or-load device id + resolve source,
    ///  3. context snapshot is already captured (injected),
    ///  4. mark isInitialized,
    ///  5. schedule the app-open ONCE per runtime (best-effort, non-blocking),
    ///  6. restore/continue-or-start the session + seed initial START / recovered END.
    public func initialize() {
        stateLock.lock()
        if initializedFlag {
            stateLock.unlock()
            return
        }
        initializedFlag = true
        firstLaunchFlag = store.getString(Self.keyFirstLaunch) == nil
        deviceIdentity = deviceIdentityStore.loadOrCreate()
        stateLock.unlock()

        connectivity.register { [weak self] in self?.scheduleFlush() }

        scheduleAppOpenIfNeeded()
        bootstrapSession()

        stateLock.lock()
        let wasFirstLaunch = firstLaunchFlag
        stateLock.unlock()
        if wasFirstLaunch {
            store.putString(Self.keyFirstLaunch, "false")
        }
    }

    /// Restore-or-start the session at init and seed lifecycle telemetry (PARITY §3).
    /// A replaced session (continuation window exceeded on restore) is enqueued as a
    /// recovered END (row S5); a freshly-started session enqueues the initial START
    /// (row S3). The heartbeat TIMER + foreground/background transitions are CHUNK B.
    private func bootstrapSession() {
        guard config.sessionTrackingEnabled else { return }
        let result = sessionManager.restoreOrStart(currentSessionIdentity())
        if result.startedNewSession {
            enqueueSessionLifecycle(
                kind: AttriaxSessionContinuation.Lifecycle.start,
                session: result.currentSession,
                occurredAtMs: result.currentSession.startedAtMs
            )
            if let replaced = result.replacedSession {
                enqueueSessionLifecycle(
                    kind: AttriaxSessionContinuation.Lifecycle.end,
                    session: replaced,
                    occurredAtMs: sessionManager.inferredRecoveredEndAtMs(replaced),
                    metadata: ["recovered": true]
                )
            }
            scheduleFlush()
        }
    }

    /// The current-launch identity snapshot fed to the session state machine.
    private func currentSessionIdentity() -> AttriaxSessionIdentity {
        let identity = withState { deviceIdentity }
        return AttriaxSessionIdentity(
            deviceId: identity?.value,
            platform: context.platform,
            appPackageName: context.packageName,
            appVersion: context.appVersion,
            appBuildNumber: context.appBuildNumber,
            locale: context.deviceLocale,
            isFirstLaunch: withState { firstLaunchFlag },
            sdkPackageVersion: context.sdkPackageVersion
        )
    }

    /// Enqueue an event (thin engine-level entry; the richer public tracking API
    /// lives on `tracking`). Precondition-fails if called before `initialize()`.
    func recordEvent(_ name: String, eventData: [String: Any?]? = nil, flushImmediately: Bool = false) {
        requireInitialized()
        let identity = withState { deviceIdentity }
        // Stamp the current session (PARITY §3): events carry the live session id +
        // ms-since-start so the backend correlates them.
        let session = sessionManager.currentSession
        let occurredAtMs = clock.nowMs()
        let request = AttriaxRequestBuilders.buildEvent(
            projectToken: config.normalizedProjectToken,
            eventName: name,
            eventData: eventData,
            deviceId: identity?.value,
            deviceIdSource: identity?.source,
            sessionId: session?.sessionId,
            sessionRelativeTimeMs: session?.sessionRelativeTimeMs(occurredAtMs),
            clientOccurredAtIso: nowIso(occurredAtMs)
        )
        enqueueRequest(request, flushImmediately: flushImmediately)
    }

    /// Enqueue a pre-built session lifecycle request through the same queue path.
    private func enqueueSessionLifecycle(
        kind: String,
        session: AttriaxSessionSnapshot,
        occurredAtMs: Int64,
        metadata: [String: Any?]? = nil
    ) {
        let identity = withState { deviceIdentity }
        let request = AttriaxRequestBuilders.buildSession(
            projectToken: config.normalizedProjectToken,
            kind: kind,
            sessionId: session.sessionId,
            deviceId: identity?.value,
            deviceIdSource: identity?.source,
            clientOccurredAtIso: nowIso(occurredAtMs),
            sessionRelativeTimeMs: session.sessionRelativeTimeMs(occurredAtMs),
            platform: session.platform,
            locale: session.locale,
            isFirstLaunch: session.isFirstLaunch,
            appVersion: session.appVersion,
            appBuildNumber: session.appBuildNumber,
            appPackageName: session.appPackageName,
            sdkApiVersion: context.sdkApiVersion,
            sdkPackageVersion: session.sdkPackageVersion ?? context.sdkPackageVersion,
            metadata: metadata
        )
        enqueue(request)
    }

    /// Enqueue a pre-built request through the frozen-identity queue path and
    /// optionally kick a flush (PARITY §4/§7). Shared by the `tracking` surface so
    /// events/crashes/notifications/user updates all traverse the same engine.
    ///
    /// CHUNK B replaces the `enabled`-only gate below with the consent-aware
    /// `enqueueTracked` policy (drop / anonymize / defer-network).
    func enqueueRequest(_ request: AttriaxApiRequest, flushImmediately: Bool) {
        requireInitialized()
        guard isTrackingEnabled else { return }
        enqueue(request)
        if flushImmediately { scheduleFlush() }
    }

    /// Direct (non-queued) receipt validation (PARITY §4). Works even when tracking
    /// is disabled because it bypasses the queue and the enabled gate entirely — it
    /// is a synchronous request/response. Returns the decoded response payload
    /// (envelope already unwrapped by the transport), or throws the transport error.
    ///
    /// Performs blocking I/O — call off the main thread (or wrap in your own async).
    @discardableResult
    public func validateReceipt(
        _ receipt: String,
        test: Bool = false,
        provider: String? = nil,
        environment: String? = nil,
        productId: String? = nil,
        transactionId: String? = nil
    ) throws -> Any? {
        requireInitialized()
        let normalizedReceipt = receipt.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedReceipt.isEmpty, "receipt must not be empty.")
        let body = AttriaxRequestBuilders.buildReceiptValidate(
            projectToken: config.normalizedProjectToken,
            receipt: normalizedReceipt,
            deviceId: resolvedDeviceId,
            clientOccurredAtIso: nowIso(),
            provider: AttriaxRevenue.trimOrNull(provider),
            environment: AttriaxRevenue.trimOrNull(environment),
            transactionId: AttriaxRevenue.trimOrNull(transactionId),
            productId: AttriaxRevenue.trimOrNull(productId),
            test: test
        )
        let response = try transport.post(AttriaxEndpoints.receiptsValidate, AttriaxJson.encode(body))
        guard let responseBody = response.body else { return nil }
        return try AttriaxJson.decode(responseBody)
    }

    /// Best-effort flush kicked onto the background queue.
    public func flush() {
        scheduleFlush()
    }

    /// Clear SDK state to pre-init (PARITY §1 reset; rows D2).
    public func reset() {
        sessionManager.reset()
        deviceIdentityStore.clear()
        store.remove(Self.keyFirstLaunch)
        store.remove(Self.keyDeferredDeepLinkHandled)
        queue.writeAll([])
        stateLock.lock()
        deviceIdentity = nil
        firstLaunchFlag = true
        appOpenScheduledFlag = false
        initializedFlag = false
        stateLock.unlock()
    }

    public func dispose() {
        connectivity.unregister()
    }

    // MARK: - internals

    /// Delivery callback from the dispatcher (single-send only). CHUNK B routes
    /// app-open responses to deferred deep-link recovery and resolve responses to
    /// their pending callback. Here it is a best-effort no-op hook so the dispatcher
    /// contract is stable. Never crash a flush.
    private func onRequestDelivered(_ queued: AttriaxQueuedRequest, _ response: AttriaxHttpResponse) {
        // CHUNK B: deferred deep-link recovery from the app-open response.
    }

    private func scheduleAppOpenIfNeeded() {
        stateLock.lock()
        if appOpenScheduledFlag {
            stateLock.unlock()
            return
        }
        appOpenScheduledFlag = true
        let enabled = enabledFlag && !config.normalizedProjectToken.isEmpty
        let identity = deviceIdentity
        stateLock.unlock()

        guard enabled, let identity = identity else { return }

        // CHUNK C: attestation resolves a nonce challenge + provider token before
        // enqueuing the open. Here the fast path enqueues immediately with no
        // attestation envelope. The attestation seam is intentionally not built.
        let open = AttriaxRequestBuilders.buildOpen(
            projectToken: config.normalizedProjectToken,
            context: context,
            deviceId: identity.value,
            deviceIdSource: identity.source,
            isFirstLaunch: withState { firstLaunchFlag },
            sessionId: nil,
            sessionStartedAtIso: nil,
            attestation: nil
        )
        enqueue(open)
        scheduleFlush()
    }

    private func enqueue(_ request: AttriaxApiRequest) {
        queue.enqueue(
            AttriaxQueuedRequest(
                id: AttriaxIdGenerator.generate(),
                request: request,
                createdAtMs: clock.nowMs()
            )
        )
    }

    private func scheduleFlush() {
        guard isEnabled() else { return }
        flushQueue.async { [weak self] in
            self?.dispatcher.flush()
        }
    }

    private func isEnabled() -> Bool {
        withState { enabledFlag } && !config.normalizedProjectToken.isEmpty
    }

    private func requireInitialized() {
        precondition(withState { initializedFlag }, "Attriax.initialize() must complete before tracking calls.")
    }

    /// UTC ISO-8601 timestamp for a given epoch-ms (exposed to `tracking`).
    func nowIso(_ atMs: Int64? = nil) -> String {
        AttriaxIso8601.string(fromMs: atMs ?? clock.nowMs())
    }

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    private static let keyFirstLaunch = "attriax.first_launch_completed"
    private static let keyDeferredDeepLinkHandled = "attriax.deferred_deep_link_handled"
}

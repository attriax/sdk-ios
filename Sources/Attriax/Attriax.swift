import Foundation

/// Attriax native iOS SDK core engine (Epic 9.3).
///
/// Composition root that wires the pure engine (config, device identity, queue,
/// retry, batching, dispatcher, consent, deep links, session lifecycle) to its iOS
/// I/O ports.
///
/// CHUNK A delivered: init → app-open bootstrap (rows I1/O1/O3), frozen build-time
/// identity stamping (row D3), session snapshot machine + initial START / recovered
/// END (rows S1/S2/S5), and the tracking enqueue path (§4).
///
/// CHUNK B (this chunk) adds:
///  - consent + anonymous mode (rows C1–C5): the enqueue gate is now the
///    consent-aware `enqueueTracked` policy (drop / anonymize / defer-network) plus
///    the three consent-resolution queue-rewrite passes,
///  - deep links (rows DL1–DL5): `deepLinks.handleUniversalLink` / `handleUrl`
///    forwarding, resolve dispatch, deferred recovery from the app-open response,
///    dynamic-link creation,
///  - session LIFECYCLE (rows S2–S5): heartbeat timer + foreground/background/
///    terminate transitions via `UIApplication`, and the dispatcher keep-alive
///    injection (row S4).
///
/// CHUNK C seams still UNWIRED: ATT / ASA / SKAN / App Attest (the IDFA source seam
/// returns nil; the attestation envelope is nil).
public final class Attriax {
    private let config: AttriaxConfig
    private let store: AttriaxKeyValueStore
    private let transport: AttriaxHttpClient
    private let connectivity: AttriaxConnectivityMonitor
    private let context: AttriaxContextSnapshot
    private let deviceIdentityStore: AttriaxDeviceIdentityStore
    private let clock: AttriaxClock

    private let queue: AttriaxQueueManager
    // The dispatcher, session-lifecycle manager, lifecycle binder, deep-link manager
    // and consent queue policy all close over `self` (weakly), so they are wired at
    // the END of init once every stored property is initialized — hence IUOs.
    private var dispatcher: AttriaxDispatcher!
    private let sessionManager: AttriaxSessionManager
    private var sessionLifecycleManager: AttriaxSessionLifecycleManager!
    private var lifecycleBinder: AttriaxLifecycleBinder!

    private let consentManager: AttriaxConsentManager
    private var consentQueuePolicy: AttriaxConsentQueuePolicy!
    private var deepLinkManager: AttriaxDeepLinkManager!

    /// Serial background queue for flushes (mirrors the Android single-thread flush
    /// executor). All network I/O runs here, off the caller's thread.
    private let flushQueue = DispatchQueue(label: "com.attriax.sdk.flush")

    /// Dedicated serial queue for consent-resolution reconciliation, serialized
    /// against the consent sync loop conceptually (both are best-effort, off-thread).
    private let consentReconcileQueue = DispatchQueue(label: "com.attriax.sdk.consent-reconcile")

    private let stateLock = NSRecursiveLock()
    private var initializedFlag = false
    private var appOpenScheduledFlag = false
    private var enabledFlag = true
    private var anonymousTrackingFlag: Bool
    private var deviceIdentity: ResolvedDeviceId?
    private var firstLaunchFlag = true

    /// Pending resolve-response callbacks keyed by queued-request id (row DL2).
    /// Registered before enqueue; fired from `onRequestDelivered` with the decoded
    /// response `data` map when the resolve is delivered.
    private let pendingResolveLock = NSLock()
    private var pendingResolveCallbacks = [String: ([String: Any?]?) -> Void]()

    /// Public tracking / revenue / identify surface (PARITY §4).
    public private(set) lazy var tracking = AttriaxTracking(engine: self)

    /// Public GDPR consent + anonymous-mode surface (PARITY §5).
    public private(set) lazy var consent = AttriaxConsent(engine: self)

    /// Public deep-link surface (PARITY §6).
    public private(set) lazy var deepLinks = AttriaxDeepLinks(engine: self)

    init(
        config: AttriaxConfig,
        store: AttriaxKeyValueStore,
        transport: AttriaxHttpClient,
        connectivity: AttriaxConnectivityMonitor,
        context: AttriaxContextSnapshot,
        deviceIdentityStore: AttriaxDeviceIdentityStore,
        clock: AttriaxClock = AttriaxSystemClock(),
        scheduler: AttriaxScheduler = AttriaxNoopScheduler(),
        lifecycleBinderFactory: (AttriaxSessionLifecycleManager) -> AttriaxLifecycleBinder = { _ in AttriaxNoopLifecycleBinder() },
        consentTransport: AttriaxConsentTransport? = nil,
        consentSyncQueue: DispatchQueue = DispatchQueue(label: "com.attriax.sdk.consent")
    ) {
        self.config = config
        self.store = store
        self.transport = transport
        self.connectivity = connectivity
        self.context = context
        self.deviceIdentityStore = deviceIdentityStore
        self.clock = clock
        self.anonymousTrackingFlag = config.anonymousTracking

        self.queue = AttriaxQueueManager(store: store, maxQueueSize: config.maxQueueSize)

        self.sessionManager = AttriaxSessionManager(
            clock: clock,
            snapshotStore: AttriaxSessionSnapshotStore(store: store),
            heartbeatIntervalMs: config.sessionHeartbeatIntervalMs,
            firstLaunchHeartbeatIntervalMs: config.firstLaunchSessionHeartbeatIntervalMs,
            generateSessionId: { AttriaxIdGenerator.generate() }
        )

        self.consentManager = AttriaxConsentManager(
            config: config,
            clock: clock,
            consentStore: AttriaxConsentStore(store: store),
            transport: consentTransport ?? AttriaxHttpConsentTransport(http: transport),
            syncQueue: consentSyncQueue
        )

        // The session lifecycle manager needs closures back into `self`; they capture
        // `self` weakly so they are safe to build during phase-1 init (nothing on
        // `self` is touched until a real transition fires post-init).
        self.sessionLifecycleManager = AttriaxSessionLifecycleManager(
            sessionManager: sessionManager,
            clock: clock,
            scheduler: scheduler,
            isEnabled: { [weak self] in self?.isEnabled() ?? false },
            currentIdentity: { [weak self] in self?.currentSessionIdentity() ?? Self.emptyIdentity(context) },
            enqueueLifecycle: { [weak self] event in self?.enqueueSessionLifecycle(event) },
            requestFlush: { [weak self] in self?.scheduleFlush() }
        )
        self.lifecycleBinder = lifecycleBinderFactory(sessionLifecycleManager)

        self.deepLinkManager = AttriaxDeepLinkManager(
            nowMs: { clock.nowMs() },
            // resolveDispatch is wired below via setResolveDispatch, once `self` is fully built.
            readDeferredHandled: { store.getString(Self.keyDeferredDeepLinkHandled) != nil },
            writeDeferredHandled: { handled in
                if handled { store.putString(Self.keyDeferredDeepLinkHandled, "true") }
                else { store.remove(Self.keyDeferredDeepLinkHandled) }
            }
        )

        self.dispatcher = AttriaxDispatcher(
            queue: queue,
            transport: transport,
            clock: clock,
            onDelivered: { [weak self] queued, response in
                self?.onRequestDelivered(queued, response)
            },
            buildSessionKeepAliveBatch: { [weak self] group in
                self?.buildSessionKeepAliveBatch(group)
            },
            onSessionKeepAliveDelivered: { [weak self] sessionId, occurredAtMs in
                self?.sessionLifecycleManager.handleSuccessfulForegroundFlush(sessionId: sessionId, occurredAtMs: occurredAtMs)
            }
        )

        self.consentQueuePolicy = AttriaxConsentQueuePolicy(
            isWaitingForGdprConsent: { [weak self] in self?.consentManager.isWaitingForGdprConsent ?? false },
            anonymousTrackingEnabled: { [weak self] in self?.anonymousTrackingSnapshot() ?? false },
            allowsAttributionTracking: { [weak self] in self?.consentManager.allowsAttributionTracking() ?? true },
            trackingDecisionFor: { [weak self] signal in self?.consentManager.trackingDecisionFor(signal) ?? .identified }
        )

        // Rebind the deep-link resolve dispatch now that `self` is fully constructed.
        deepLinkManager.setResolveDispatch { [weak self] uri, metadata, source, isInitialLink, onResolved in
            self?.dispatchDeepLinkResolve(uri, metadata: metadata, source: source, isInitialLink: isInitialLink, onResolved: onResolved)
        }
    }

    // MARK: - public state

    public var isInitialized: Bool { withState { initializedFlag } }
    public var isFirstLaunch: Bool { withState { firstLaunchFlag } }
    public var deviceId: String? { withState { deviceIdentity?.value } }

    public var enabled: Bool {
        get { withState { enabledFlag } }
        set { withState { enabledFlag = newValue } }
    }

    /// GDPR-safe anonymous-tracking toggle (PARITY §4/§5). Defaults from
    /// `AttriaxConfig.anonymousTracking`. Toggling notifies the consent manager so a
    /// pending decision re-evaluates capture/defer semantics.
    public var anonymousTrackingEnabled: Bool {
        get { withState { anonymousTrackingFlag } }
        set {
            withState { anonymousTrackingFlag = newValue }
            consentManager.anonymousTrackingEnabled = newValue
        }
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
    ///  1. restore persisted state (device id, first-launch flag, consent, session),
    ///  2. generate-or-load device id + resolve source,
    ///  3. context snapshot is already captured (injected),
    ///  4. mark isInitialized,
    ///  5. schedule the app-open ONCE per runtime (best-effort, non-blocking),
    ///  6. restore/continue-or-start the session + seed initial START / recovered END,
    ///     then activate the lifecycle telemetry (heartbeat + fg/bg detection),
    ///  7. flush any consent decision persisted with pendingSync across a restart.
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

        // Restore persisted consent BEFORE any capture gating runs, and reconcile the
        // queue whenever the consent decision changes (PARITY §5, rows C2/C5).
        consentManager.restore()
        consentManager.onStateChanged = { [weak self] in self?.onConsentStateChanged() }

        connectivity.register { [weak self] in self?.scheduleFlush() }

        scheduleAppOpenIfNeeded()
        bootstrapSession()

        // Flush any consent decision persisted with pendingSync across a restart.
        consentManager.flushPendingSync()

        stateLock.lock()
        let wasFirstLaunch = firstLaunchFlag
        stateLock.unlock()
        if wasFirstLaunch {
            store.putString(Self.keyFirstLaunch, "false")
        }
    }

    /// Restore-or-start the session at init and wire lifecycle telemetry (PARITY §3).
    /// A replaced session (continuation window exceeded on restore) is seeded as a
    /// recovered END (row S5); a freshly-started session seeds the initial START
    /// (row S3). Then the lifecycle manager is activated (emits the seeded START +
    /// starts the heartbeat) and foreground/background/terminate detection is bound.
    private func bootstrapSession() {
        guard config.sessionTrackingEnabled else { return }
        let result = sessionManager.restoreOrStart(currentSessionIdentity())
        if result.startedNewSession {
            sessionLifecycleManager.seedInitialSessionStart(result.currentSession)
            sessionLifecycleManager.seedRecoveredSessionEnd(result.replacedSession)
        }
        lifecycleBinder.bind()
        sessionLifecycleManager.activate()
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

    private static func emptyIdentity(_ context: AttriaxContextSnapshot) -> AttriaxSessionIdentity {
        AttriaxSessionIdentity(
            deviceId: nil,
            platform: context.platform,
            appPackageName: context.packageName,
            appVersion: context.appVersion,
            appBuildNumber: context.appBuildNumber,
            locale: context.deviceLocale,
            isFirstLaunch: false,
            sdkPackageVersion: context.sdkPackageVersion
        )
    }

    /// Enqueue an event (thin engine-level entry; the richer public tracking API
    /// lives on `tracking`). Precondition-fails if called before `initialize()`.
    func recordEvent(_ name: String, eventData: [String: Any?]? = nil, flushImmediately: Bool = false) {
        requireInitialized()
        let identity = withState { deviceIdentity }
        // Stamp the current session (PARITY §3): events carry the live session id +
        // ms-since-start so the backend correlates them, and so the dispatcher can
        // inject a session keep-alive when a batch carries a live-session event (S4).
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

    /// Build the session request for a lifecycle `event` and push it through the SAME
    /// consent-gated queue path as every other signal (session is an anon-capable
    /// signal — row C4). Identity is stamped from the frozen build-time device id; the
    /// full SdkSessionDto context comes from the snapshot.
    private func enqueueSessionLifecycle(_ event: AttriaxSessionLifecycleEvent) {
        guard withState({ initializedFlag }) else { return }
        let request = buildSessionRequest(event)
        _ = enqueueTracked(request, flushImmediately: false)
    }

    private func buildSessionRequest(_ event: AttriaxSessionLifecycleEvent) -> AttriaxApiRequest {
        let session = event.session
        let identity = withState { deviceIdentity }
        return AttriaxRequestBuilders.buildSession(
            projectToken: config.normalizedProjectToken,
            kind: event.kind,
            sessionId: session.sessionId,
            deviceId: identity?.value,
            deviceIdSource: identity?.source,
            clientOccurredAtIso: nowIso(event.occurredAtMs),
            sessionRelativeTimeMs: session.sessionRelativeTimeMs(event.occurredAtMs),
            platform: session.platform,
            locale: session.locale,
            isFirstLaunch: session.isFirstLaunch,
            appVersion: session.appVersion,
            appBuildNumber: session.appBuildNumber,
            appPackageName: session.appPackageName,
            sdkApiVersion: context.sdkApiVersion,
            sdkPackageVersion: session.sdkPackageVersion ?? context.sdkPackageVersion,
            metadata: event.metadata
        )
    }

    /// Session keep-alive injection hook for the dispatcher (PARITY §4, row S4). When
    /// a batch `group` carries an EVENT tagged with the live session's id, returns a
    /// synthetic HEARTBEAT session request (sharing the batch identity) to append;
    /// otherwise nil.
    private func buildSessionKeepAliveBatch(_ group: [AttriaxQueuedRequest]) -> AttriaxBatchKeepAlive? {
        guard let current = sessionManager.currentSession else { return nil }
        let carriesCurrentSessionEvent = group.contains { queued in
            queued.request.kind == AttriaxApiRequest.kindTrackEvent &&
                (queued.request.body["sessionId"] as? String) == current.sessionId
        }
        if !carriesCurrentSessionEvent { return nil }

        guard let heartbeat = sessionLifecycleManager.buildKeepAliveHeartbeat(occurredAtMs: clock.nowMs()) else {
            return nil
        }
        let request = buildSessionRequest(heartbeat)
        // The synthetic keep-alive must be batchable (identity present) to share the
        // batch envelope; if identity is stripped (anonymous) it cannot ride along.
        if !request.isBatchable { return nil }
        return AttriaxBatchKeepAlive(
            request: request,
            sessionId: heartbeat.session.sessionId,
            occurredAtMs: heartbeat.occurredAtMs
        )
    }

    /// Consent-aware enqueue gate (PARITY §5, row C4). Replaces the old `enabled`-only
    /// gate: every tracking request is now filtered through the consent policy BEFORE
    /// it is persisted.
    ///
    ///  * WITHHELD (capture=false) → the request is dropped (not enqueued).
    ///  * ANONYMOUS (capture=true, attachDeviceIdentity=false) → the device identity
    ///    is stripped before enqueue so it is sent without device-linked identity.
    ///  * IDENTIFIED (capture=true, attachDeviceIdentity=true) → enqueued as built.
    ///  * deferNetwork=true (anonymousTracking OFF while waiting) → enqueued but NOT
    ///    flushed; it buffers locally until consent allows dispatch.
    ///
    /// Kinds the consent-signal policy does not classify (user / uninstall token) are
    /// attribution-gated: dropped unless attribution tracking is allowed.
    ///
    /// - Returns: true if the request was enqueued, false if it was withheld/dropped.
    @discardableResult
    private func enqueueTracked(_ request: AttriaxApiRequest, flushImmediately: Bool) -> Bool {
        if let decision = consentQueuePolicy.trackingDecisionForQueuedRequest(request) {
            if !decision.capture { return false }
            let toEnqueue = decision.attachDeviceIdentity
                ? request
                : AttriaxConsentRequestRewrites.anonymize(request)
            enqueue(toEnqueue)
            // Buffer locally (no flush) when network dispatch must be deferred.
            if flushImmediately && !decision.deferNetwork { scheduleFlush() }
            return true
        }

        // Identity-linked kinds not covered by the signal policy: user / uninstall
        // token require attribution consent. Dynamic links are always allowed.
        let allowed: Bool
        switch request.kind {
        case AttriaxApiRequest.kindUser, AttriaxApiRequest.kindRegisterUninstallToken:
            allowed = consentManager.allowsAttributionTracking()
        default:
            allowed = true
        }
        if !allowed { return false }
        enqueue(request)
        if flushImmediately { scheduleFlush() }
        return true
    }

    /// Enqueue a pre-built request through the frozen-identity queue path and
    /// optionally kick a flush (PARITY §4/§7). Shared by the `tracking` surface so
    /// events/crashes/notifications/user updates all traverse the same engine and the
    /// same consent gate.
    func enqueueRequest(_ request: AttriaxApiRequest, flushImmediately: Bool) {
        requireInitialized()
        _ = enqueueTracked(request, flushImmediately: flushImmediately)
    }

    /// Direct (non-queued) receipt validation (PARITY §4). Works even when tracking
    /// is disabled / consent is unresolved because it bypasses the queue and the
    /// enabled gate entirely — it is a synchronous request/response. Returns the
    /// decoded response payload (envelope already unwrapped by the transport), or
    /// throws the transport error.
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

    // MARK: - deep links (PARITY §6, rows DL1–DL5) — engine methods behind `deepLinks`

    var latestDeepLink: AttriaxDeepLinkEvent? { deepLinkManager.latestDeepLink }
    var initialDeepLink: AttriaxDeepLinkEvent? { deepLinkManager.initialDeepLink }
    var rawInitialDeepLink: AttriaxRawDeepLinkEvent? { deepLinkManager.rawInitialDeepLink }
    var isInitialDeepLinkResolved: Bool { deepLinkManager.isInitialDeepLinkResolved }

    @discardableResult
    func addDeepLinkListener(_ listener: @escaping AttriaxDeepLinkListener) -> AttriaxDeepLinkListenerToken {
        deepLinkManager.addListener(listener)
    }
    func removeDeepLinkListener(_ token: AttriaxDeepLinkListenerToken) {
        deepLinkManager.removeListener(token)
    }
    @discardableResult
    func addRawDeepLinkListener(_ listener: @escaping AttriaxRawDeepLinkListener) -> AttriaxDeepLinkListenerToken {
        deepLinkManager.addRawListener(listener)
    }
    func removeRawDeepLinkListener(_ token: AttriaxDeepLinkListenerToken) {
        deepLinkManager.removeRawListener(token)
    }

    func handleIncomingDeepLink(_ rawUri: String, isInitialLink: Bool) {
        requireInitialized()
        deepLinkManager.handleIncomingLink(rawUri, isInitialLink: isInitialLink)
    }

    func completeInitialDeepLinkIfAbsent() {
        deepLinkManager.completeInitialLinkIfAbsent()
    }

    func waitForInitialDeepLink() -> AttriaxDeepLinkEvent? {
        deepLinkManager.waitForInitialDeepLink()
    }

    func recordDeepLink(_ uri: String, metadata: [String: Any?]?, source: String) {
        requireInitialized()
        deepLinkManager.recordDeepLink(uri, metadata: metadata, source: source)
    }

    /// Create a short dynamic link (PARITY §6). Sent DIRECTLY (non-queued) — a
    /// synchronous request/response, so it works even while tracking is deferred.
    /// Blocking I/O — call off the main thread.
    func createDynamicLink(
        name: String?,
        destinationUrl: String?,
        group: String?,
        prefix: String?,
        socialPreview: AttriaxDynamicLinkSocialPreview?,
        utms: AttriaxDynamicLinkUtms?,
        redirects: AttriaxDynamicLinkRedirects?,
        data: [String: Any?]?
    ) throws -> AttriaxCreateDynamicLinkResult {
        requireInitialized()
        let body = AttriaxRequestBuilders.buildCreateDynamicLink(
            projectToken: config.normalizedProjectToken,
            name: name,
            destinationUrl: destinationUrl,
            group: group,
            prefix: prefix,
            iosRedirect: redirects?.ios,
            androidRedirect: redirects?.android,
            previewTitle: socialPreview?.title,
            previewDescription: socialPreview?.description,
            utmSource: utms?.source,
            utmMedium: utms?.medium,
            utmCampaign: utms?.campaign,
            utmTerm: utms?.term,
            utmContent: utms?.content,
            data: data
        )
        let response = try transport.post(AttriaxEndpoints.dynamicLinks, AttriaxJson.encode(body))
        guard let responseBody = response.body,
              let decoded = try AttriaxJson.decode(responseBody) as? [String: Any?] else {
            throw AttriaxTransportError.transport(underlying: nil)
        }
        return try parseDynamicLinkResult(decoded)
    }

    /// Dispatch a deep-link resolve (PARITY §6, row DL2). Builds the DTO with the
    /// consent-aware identity decision (deep-link diagnostics are anon-capable while
    /// waiting), registers the resolution callback under the queued id, and enqueues
    /// through the same terminal-drop-exempt dispatcher as every other request. When
    /// the resolve is delivered, `onRequestDelivered` fires the callback.
    private func dispatchDeepLinkResolve(
        _ uri: AttriaxUri,
        metadata: [String: Any?],
        source: String,
        isInitialLink: Bool,
        onResolved: @escaping ([String: Any?]?) -> Void
    ) {
        let decision = consentManager.trackingDecisionFor(.deepLink)
        if !decision.capture {
            onResolved(nil)
            return
        }
        let attachIdentity = decision.attachDeviceIdentity
        let identity = withState { deviceIdentity }
        let request = AttriaxRequestBuilders.buildResolveDeepLink(
            projectToken: config.normalizedProjectToken,
            platform: context.platform,
            source: source,
            isFirstLaunch: withState { firstLaunchFlag },
            deviceId: attachIdentity ? identity?.value : nil,
            deviceIdSource: attachIdentity ? identity?.source : nil,
            rawUrl: uri.stringValue,
            linkPath: AttriaxDeepLinkResolver.extractLinkPathFromUri(uri),
            sessionId: nil,
            sessionRelativeTimeMs: nil,
            metadata: metadata
        )
        let id = AttriaxIdGenerator.generate()
        pendingResolveLock.lock()
        pendingResolveCallbacks[id] = onResolved
        pendingResolveLock.unlock()

        queue.enqueue(
            AttriaxQueuedRequest(id: id, request: request, createdAtMs: clock.nowMs())
        )
        // Deep-link resolve is anon-capable; flush unless network dispatch is deferred.
        if !decision.deferNetwork { scheduleFlush() }
    }

    // MARK: - consent (PARITY §5) — engine methods behind the `consent.gdpr` surface

    var gdprConsentState: AttriaxGdprConsentState { consentManager.gdprConsentState }
    var gdprConsentValues: AttriaxGdprConsentValues? { consentManager.gdprConsentValues }
    var isWaitingForGdprConsent: Bool { consentManager.isWaitingForGdprConsent }

    func needsGdprConsent(localOnly: Bool) -> Bool {
        requireInitialized()
        return consentManager.needsConsent(localOnly: localOnly)
    }

    func setGdprConsent(analytics: Bool, attribution: Bool, adEvents: Bool) {
        requireInitialized()
        consentManager.setConsent(analytics: analytics, attribution: attribution, adEvents: adEvents)
    }

    func setGdprConsentNotRequired() {
        requireInitialized()
        consentManager.setNotRequired()
    }

    func resetGdprConsent() {
        requireInitialized()
        consentManager.reset()
    }

    /// Request GDPR data erasure (PARITY §5, row C5 erase). Sends the deviceId to
    /// `/api/sdk/v1/privacy/gdpr/erase` (the ONLY consent-family endpoint that carries
    /// the deviceId — the check/upsert bodies never do), then resets the SDK to
    /// pre-init on success. Blocking I/O — call off the main thread.
    func requestGdprDataErasure() throws {
        requireInitialized()
        guard let deviceId = withState({ deviceIdentity?.value }) else {
            throw AttriaxTransportError.transport(underlying: nil)
        }
        var body = AttriaxJSONObject()
        body[AttriaxApiRequest.fieldProjectToken] = config.normalizedProjectToken
        body[AttriaxApiRequest.fieldDeviceId] = deviceId
        _ = try transport.post(AttriaxEndpoints.gdprErase, AttriaxJson.encode(body))
        reset()
    }

    /// Consent-resolution queue reconciliation (PARITY §5, row C5). Runs the three
    /// passes over the persisted queue whenever the consent decision changes and we
    /// are no longer waiting: (1) IDENTIFY anonymous requests now that identified
    /// tracking is allowed, (2) ANONYMIZE denied-but-anonymous-capable requests,
    /// (3) DISCARD now-disallowed requests (reason `gdpr_consent_denied`). Runs on a
    /// dedicated serial queue so it is serialized against itself.
    private func onConsentStateChanged() {
        guard withState({ initializedFlag && enabledFlag }) else { return }
        consentReconcileQueue.async { [weak self] in
            guard let self = self else { return }
            self.reconcileQueueForConsent()
            if !self.consentManager.shouldDeferNetworkDispatch {
                self.consentManager.flushPendingSync()
                self.scheduleFlush()
            }
        }
    }

    private func reconcileQueueForConsent() {
        if !config.gdprEnabled || consentManager.isWaitingForGdprConsent { return }

        let identity = withState { deviceIdentity }
        if let identity = identity {
            // PASS 1: attach identity to anonymous requests now allowed identified.
            queue.rewriteWhere { entry in
                if self.consentQueuePolicy.shouldIdentifyQueuedRequestForResolvedConsent(entry.request),
                   let rewritten = AttriaxConsentRequestRewrites.identify(
                       entry.request, deviceId: identity.value, deviceIdSource: identity.source
                   ) {
                    return entry.withRequest(rewritten)
                }
                return nil
            }
        }

        // PASS 2: strip identity from denied-but-anonymous-capable requests.
        queue.rewriteWhere { entry in
            if self.consentQueuePolicy.shouldAnonymizeQueuedRequest(entry.request) {
                return entry.withRequest(AttriaxConsentRequestRewrites.anonymize(entry.request))
            }
            return nil
        }

        // PASS 3: discard now-disallowed requests (reason gdpr_consent_denied).
        queue.discardWhere { entry in
            !self.consentQueuePolicy.isRequestAllowedByResolvedConsent(entry.request)
        }
    }

    /// Clear SDK state to pre-init (PARITY §1 reset; rows D2).
    public func reset() {
        // Tear down session telemetry BEFORE clearing identity so no in-flight
        // heartbeat/transition re-persists a snapshot after the wipe (PARITY §3).
        lifecycleBinder.unbind()
        sessionLifecycleManager.reset()
        sessionManager.reset()
        deviceIdentityStore.clear()
        store.remove(Self.keyFirstLaunch)
        store.remove(Self.keyDeferredDeepLinkHandled)
        queue.writeAll([])
        pendingResolveLock.lock()
        pendingResolveCallbacks.removeAll()
        pendingResolveLock.unlock()
        deepLinkManager.reset()
        consentManager.clearMemory()
        AttriaxConsentStore(store: store).clear()
        stateLock.lock()
        deviceIdentity = nil
        firstLaunchFlag = true
        appOpenScheduledFlag = false
        initializedFlag = false
        stateLock.unlock()
    }

    public func dispose() {
        lifecycleBinder.unbind()
        sessionLifecycleManager.deactivate()
        connectivity.unregister()
    }

    // MARK: - internals

    /// Delivery callback from the dispatcher (single-send only). Routes app-open
    /// responses to deferred deep-link recovery (row DL3) and resolve responses to
    /// their pending resolution callback (row DL2). Best-effort — never crash a flush.
    private func onRequestDelivered(_ queued: AttriaxQueuedRequest, _ response: AttriaxHttpResponse) {
        switch queued.request.kind {
        case AttriaxApiRequest.kindOpen:
            let data = decodeResponseObject(response)
            deepLinkManager.handleDeferredAppOpen(data)
        case AttriaxApiRequest.kindResolveDeepLink:
            pendingResolveLock.lock()
            let callback = pendingResolveCallbacks.removeValue(forKey: queued.id)
            pendingResolveLock.unlock()
            callback?(decodeResponseObject(response))
        default:
            break
        }
    }

    private func decodeResponseObject(_ response: AttriaxHttpResponse) -> [String: Any?]? {
        guard let body = response.body else { return nil }
        return (try? AttriaxJson.decode(body)) as? [String: Any?]
    }

    private func parseDynamicLinkResult(_ decoded: [String: Any?]) throws -> AttriaxCreateDynamicLinkResult {
        // The transport unwraps the `{data:...}` envelope, so `decoded` is the
        // SdkCreateDynamicLinkResponseDto: `{ requestVersion, acceptedAt, link }`.
        guard let link = decoded["link"] as? [String: Any?] else {
            throw AttriaxTransportError.transport(underlying: nil)
        }
        let linkData = link["data"] as? [String: Any?]
        let record = AttriaxDynamicLinkRecord(
            id: (link["id"] as? String) ?? "",
            path: (link["path"] as? String) ?? "",
            shortUrl: (link["shortUrl"] as? String) ?? "",
            name: link["name"] as? String,
            destinationUrl: link["destinationUrl"] as? String,
            group: link["group"] as? String,
            prefix: link["prefix"] as? String,
            data: linkData
        )
        return AttriaxCreateDynamicLinkResult(shortUrl: record.shortUrl, record: record)
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
        // App-open carries attribution/install-referrer data (attribution-linked).
        // Enqueue always (so it is reconciled/hoisted later), but only flush it to the
        // network once attribution tracking is actually allowed — otherwise it buffers
        // until consent resolves (PARITY §3/§5).
        if allowsAppOpenDispatch() { scheduleFlush() }
    }

    /// Whether the app-open may be dispatched under the current consent state.
    private func allowsAppOpenDispatch() -> Bool {
        !config.gdprEnabled || consentManager.allowsAttributionTracking()
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

    private func anonymousTrackingSnapshot() -> Bool {
        withState { anonymousTrackingFlag }
    }

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    private static let keyFirstLaunch = "attriax.first_launch_completed"
    private static let keyDeferredDeepLinkHandled = "attriax.deferred_deep_link_handled"
}

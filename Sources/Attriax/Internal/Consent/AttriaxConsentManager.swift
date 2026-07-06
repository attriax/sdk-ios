import Foundation

/// Local GDPR consent state machine + generation-guarded background sync
/// (PARITY §5, rows C1–C3). Framework-free: it depends only on the `AttriaxConfig`
/// value, an `AttriaxClock`, an `AttriaxConsentStore` over the KeyValueStore port,
/// an `AttriaxConsentTransport` port, and a serial `DispatchQueue` for the async
/// sync — so the downgrade race can be reproduced deterministically in tests.
///
/// Mirrors the Flutter/Android reference `AttriaxConsentManager`.
///
/// THE GENERATION GUARD (row C3 — the critical fix). Every local consent decision
/// (`setConsent`/`setNotRequired`/`reset`) applies immediately, then bumps the
/// monotonic `generation` counter and kicks a background sync. The sync loop
/// captures the generation BEFORE the network await; when the echo returns it
/// checks `generation != capturedGeneration`. On mismatch a NEWER local decision
/// landed mid-flight, so the (now stale) echo is DISCARDED and the loop re-syncs
/// the current state — a newer setConsent(false) can never be clobbered by an
/// in-flight older setConsent(true) echo.
///
/// CONCURRENCY MODEL (Swift analog of the Android lock + Executor + AtomicBoolean):
///  * `lock` (NSRecursiveLock) guards ALL mutable state (`state`/`values`/
///    `generation`/`pendingSync`/…) — the moral equivalent of `synchronized(lock)`.
///  * `syncQueue` is a SERIAL DispatchQueue: the single-thread background sync
///    executor. All upsert I/O runs here, off the caller's thread.
///  * `syncingFlag` (guarded by `syncFlagLock`) is the single-flight CAS guard —
///    the analog of Android's `AtomicBoolean syncing.compareAndSet(false, true)`.
final class AttriaxConsentManager {
    private let config: AttriaxConfig
    private let clock: AttriaxClock
    private let consentStore: AttriaxConsentStore
    private let transport: AttriaxConsentTransport
    private let syncQueue: DispatchQueue

    /// Notified when the consent DECISION (state or values) changes.
    var onStateChanged: (() -> Void)?

    private let lock = NSRecursiveLock()

    private var state: AttriaxGdprConsentState = .unknown
    private var values: AttriaxGdprConsentValues?
    private var countryCode: String?
    private var regionSource: String?
    private var checkedAtIso: String?
    private var pendingSync = false
    private var restored = false

    /// Anonymous-tracking toggle. Its own lock so `anonymousTrackingEnabled` reads
    /// stay cheap and never block on the state lock (the Android `@Volatile`).
    private let anonLock = NSLock()
    private var anonymousTracking: Bool

    /// Monotonic generation counter (row C3). Read/bumped under `lock` on every
    /// local consent decision. The sync loop compares against a value captured
    /// before its network await to detect a newer decision landing mid-flight.
    private var generation = 0

    /// Single-flight guard so a second decision coalesces into the running sync.
    private let syncFlagLock = NSLock()
    private var syncingFlag = false

    init(
        config: AttriaxConfig,
        clock: AttriaxClock,
        consentStore: AttriaxConsentStore,
        transport: AttriaxConsentTransport,
        syncQueue: DispatchQueue
    ) {
        self.config = config
        self.clock = clock
        self.consentStore = consentStore
        self.transport = transport
        self.syncQueue = syncQueue
        self.anonymousTracking = config.anonymousTracking
    }

    // MARK: - read view

    var gdprConsentState: AttriaxGdprConsentState { withLock { state } }
    var gdprConsentValues: AttriaxGdprConsentValues? { withLock { values } }

    var anonymousTrackingEnabled: Bool {
        get { anonLock.lock(); defer { anonLock.unlock() }; return anonymousTracking }
        set {
            anonLock.lock()
            let changed = anonymousTracking != newValue
            anonymousTracking = newValue
            anonLock.unlock()
            if changed { onStateChanged?() }
        }
    }

    var isWaitingForGdprConsent: Bool { policy().isWaitingForGdprConsent }
    var shouldDeferNetworkDispatch: Bool { policy().shouldDeferNetworkDispatch }

    func allowsAnalyticsTracking() -> Bool { policy().allowsCategory { $0.analytics } }
    func allowsAttributionTracking() -> Bool { policy().allowsCategory { $0.attribution } }
    func allowsAdEventsTracking() -> Bool { policy().allowsCategory { $0.adEvents } }

    func canCaptureSignal(_ signal: AttriaxTrackingSignal) -> Bool {
        policy().canCaptureSignal(signal)
    }

    func trackingDecisionFor(_ signal: AttriaxTrackingSignal) -> AttriaxTrackingDecision {
        policy().trackingDecisionFor(signal)
    }

    /// Snapshot the policy over the current state (taken under `lock`).
    func policy() -> AttriaxConsentPolicy {
        withLock {
            AttriaxConsentPolicy(
                gdprEnabled: config.gdprEnabled,
                state: state,
                values: values,
                anonymousTrackingEnabled: anonymousTrackingEnabled
            )
        }
    }

    // MARK: - lifecycle

    /// Restore persisted consent state (idempotent).
    func restore() {
        withLock {
            if restored { return }
            if let stored = consentStore.read() {
                state = stored.state
                values = stored.values
                countryCode = stored.countryCode
                regionSource = stored.regionSource
                checkedAtIso = stored.checkedAtIso
                pendingSync = stored.pendingSync
            }
            restored = true
        }
    }

    // MARK: - decisions (apply locally immediately; row C2)

    func setConsent(analytics: Bool, attribution: Bool, adEvents: Bool) {
        applyLocalDecision(
            newState: .granted,
            newValues: AttriaxGdprConsentValues(analytics: analytics, attribution: attribution, adEvents: adEvents),
            newRegionSource: "manual"
        )
    }

    func setNotRequired() {
        applyLocalDecision(newState: .notRequired, newValues: nil, newRegionSource: "manual")
    }

    func reset() {
        applyLocalDecision(newState: .unknown, newValues: nil, newRegionSource: nil, clearCountryCode: true)
    }

    /// needsConsent (row C1 semantics). With `localOnly` we answer from stored state
    /// only; otherwise we may ask the backend (generation-guarded like the sync).
    /// Returns whether the SDK is still waiting for an explicit decision. Performs
    /// blocking I/O when `localOnly` is false — call off the main thread.
    func needsConsent(localOnly: Bool) -> Bool {
        restore()
        let (snapshotState, capturedGeneration) = withLock { (state, generation) }

        let cacheable = snapshotState == .granted || snapshotState == .notRequired
        if localOnly || cacheable {
            return isWaitingForGdprConsent
        }

        do {
            let consentId = consentStore.ensureConsentId()
            let status = try transport.checkGdprConsent(
                projectToken: config.normalizedProjectToken,
                consentId: consentId
            )
            withLock {
                // Capture-before-await guard: only apply the echo if no newer local
                // decision landed during the check.
                if generation == capturedGeneration {
                    applyRemoteStatusLocked(status, pending: false)
                }
            }
            return isWaitingForGdprConsent
        } catch {
            return isWaitingForGdprConsent
        }
    }

    /// Kick a background flush of any pending sync (no-op when nothing pending).
    func flushPendingSync() {
        restore()
        let pending = withLock { pendingSync }
        if pending { scheduleSync() }
    }

    func clearMemory() {
        withLock {
            state = .unknown
            values = nil
            countryCode = nil
            regionSource = nil
            checkedAtIso = nil
            pendingSync = false
            restored = false
            generation += 1
        }
    }

    // MARK: - internals

    private func applyLocalDecision(
        newState: AttriaxGdprConsentState,
        newValues: AttriaxGdprConsentValues?,
        newRegionSource: String?,
        clearCountryCode: Bool = false
    ) {
        restore()
        var decisionChanged = false
        withLock {
            decisionChanged = newState != state || newValues != values
            state = newState
            values = newValues
            regionSource = newRegionSource
            if clearCountryCode { countryCode = nil }
            checkedAtIso = nowIso()
            pendingSync = true
            // Bump the generation for EVERY decision (row C3) so an in-flight echo
            // for the previous decision is detected as stale even when the state
            // token is unchanged (e.g. granted→granted with different values).
            generation += 1
            persistCurrentStateLocked()
        }
        if decisionChanged { onStateChanged?() }
        scheduleSync()
    }

    private func scheduleSync() {
        // Single-flight: only one sync task runs; a second decision that lands
        // before the task starts sets pendingSync (already true) and the running
        // loop re-reads the current state, so it converges without a second task.
        syncFlagLock.lock()
        if syncingFlag {
            syncFlagLock.unlock()
            return
        }
        syncingFlag = true
        syncFlagLock.unlock()

        syncQueue.async { [weak self] in
            guard let self = self else { return }
            self.runSyncLoop()

            self.syncFlagLock.lock()
            self.syncingFlag = false
            self.syncFlagLock.unlock()

            // A decision may have landed (and found syncing==true, so did NOT
            // schedule) between the loop's last generation read and the flag
            // release; re-schedule so its intent is not stranded.
            let stillPending = self.withLock { self.pendingSync }
            if stillPending { self.scheduleSync() }
        }
    }

    /// The generation-guarded convergence loop (row C3). Each iteration captures the
    /// generation BEFORE the upsert await; if it advanced by the time the echo
    /// returns, a newer local decision landed and the echo is DISCARDED (we loop and
    /// re-sync the now-current state). Otherwise the echo is applied and we stop.
    private func runSyncLoop() {
        while true {
            let snapshot: SyncSnapshot? = withLock {
                if !pendingSync { return nil }
                return SyncSnapshot(
                    generation: generation,
                    state: state,
                    values: values,
                    countryCode: countryCode,
                    regionSource: regionSource,
                    checkedAtIso: checkedAtIso
                )
            }
            guard let snapshot = snapshot else { return }

            let status: AttriaxRemoteConsentStatus
            do {
                let consentId = consentStore.ensureConsentId()
                status = try transport.upsertGdprConsent(
                    projectToken: config.normalizedProjectToken,
                    consentId: consentId,
                    state: snapshot.state,
                    values: snapshot.values,
                    countryCode: snapshot.countryCode,
                    regionSource: snapshot.regionSource,
                    clientOccurredAtIso: snapshot.checkedAtIso
                )
            } catch {
                // Transient failure: leave pendingSync set so a later flush retries.
                withLock {
                    pendingSync = true
                    persistCurrentStateLocked()
                }
                return
            }

            let applied: Bool = withLock {
                if generation != snapshot.generation {
                    // A newer local decision landed while we awaited this upsert.
                    // The echo reflects the OLD intent; discard it and re-sync.
                    return false
                }
                applyRemoteStatusLocked(status, pending: false)
                return true
            }
            if applied { return }
            // else: loop again with the now-current state (stale echo discarded).
        }
    }

    private struct SyncSnapshot {
        let generation: Int
        let state: AttriaxGdprConsentState
        let values: AttriaxGdprConsentValues?
        let countryCode: String?
        let regionSource: String?
        let checkedAtIso: String?
    }

    /// Apply a remote echo. Must hold `lock`. Does NOT bump the generation.
    private func applyRemoteStatusLocked(_ status: AttriaxRemoteConsentStatus, pending: Bool) {
        var mappedState = status.state
        let mappedValues = status.values
        if mappedState == .granted && mappedValues == nil {
            mappedState = .pending
        }
        let decisionChanged = mappedState != state || mappedValues != values
        state = mappedState
        values = mappedValues
        checkedAtIso = status.checkedAtIso ?? checkedAtIso
        if let cc = normalize(status.countryCode) { countryCode = cc }
        if let rs = normalize(status.regionSource) { regionSource = rs }
        pendingSync = pending
        persistCurrentStateLocked()
        if decisionChanged {
            // Notify outside the lock is preferable, but the listener is a light
            // signal in practice; keep it simple and consistent with the reference.
            onStateChanged?()
        }
    }

    /// Persist the current state. Must hold `lock`.
    private func persistCurrentStateLocked() {
        if !pendingSync && state == .unknown {
            consentStore.write(nil)
            return
        }
        consentStore.write(
            AttriaxStoredConsent(
                state: state,
                values: values,
                countryCode: countryCode,
                regionSource: regionSource,
                checkedAtIso: checkedAtIso,
                pendingSync: pendingSync
            )
        )
    }

    private func normalize(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed = trimmed, !trimmed.isEmpty { return trimmed }
        return nil
    }

    private func nowIso() -> String {
        AttriaxIso8601.string(fromMs: clock.nowMs())
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

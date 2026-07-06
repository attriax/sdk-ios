import Foundation

/// A lifecycle telemetry request to enqueue: a session snapshot + kind + the
/// timestamp the event occurred at + optional metadata (e.g. `{recovered:true}`).
/// The engine turns this into an `AttriaxApiRequest` and pushes it through the
/// consent-gated queue.
struct AttriaxSessionLifecycleEvent {
    let session: AttriaxSessionSnapshot
    let kind: String
    let occurredAtMs: Int64
    let metadata: AttriaxJSONObject?

    init(session: AttriaxSessionSnapshot, kind: String, occurredAtMs: Int64, metadata: AttriaxJSONObject? = nil) {
        self.session = session
        self.kind = kind
        self.occurredAtMs = occurredAtMs
        self.metadata = metadata
    }
}

/// Pure session lifecycle + heartbeat state machine (PARITY §3, rows S3/S5).
///
/// Owns the foreground/background/detach transitions, the heartbeat timer, the
/// pending initial-start and recovered-end telemetry, and the successful-flush
/// activity bump. Framework-free: foreground/background/terminate signals arrive
/// via `handleForeground`/`handleBackground`/`handleDetached` (the iOS layer wires
/// `UIApplication` notifications to these), the timer runs through the injected
/// `AttriaxScheduler` seam (deterministic in tests), and enqueue is delegated to
/// `enqueueLifecycle`. Mirrors the Flutter/Android `AttriaxSessionLifecycleManager`.
///
///  - foreground after the continuation window → START a new session (+ recovered
///    END for the replaced one); within the window → RESUME the same id.
///  - background/hidden → PAUSE + stop the heartbeat.
///  - process detach → END.
///  - a heartbeat timer at `session.heartbeatInterval` enqueues a HEARTBEAT.
///
/// All enqueue paths are gated on `isEnabled() && sessionManager.isTrackingEnabled`
/// and are no-ops in the background (except the terminal pause/end transitions).
final class AttriaxSessionLifecycleManager {
    private let sessionManager: AttriaxSessionManager
    private let clock: AttriaxClock
    private let scheduler: AttriaxScheduler
    private let isEnabled: () -> Bool
    private let currentIdentity: () -> AttriaxSessionIdentity
    private let enqueueLifecycle: (AttriaxSessionLifecycleEvent) -> Void
    private let requestFlush: () -> Void

    private let lock = NSRecursiveLock()

    private var heartbeatHandle: AttriaxScheduledHandle?
    private var isInBackground = false
    private var isActive = false
    private var pendingInitialStart: AttriaxSessionSnapshot?
    private var pendingRecoveredEnd: AttriaxSessionSnapshot?

    init(
        sessionManager: AttriaxSessionManager,
        clock: AttriaxClock,
        scheduler: AttriaxScheduler,
        isEnabled: @escaping () -> Bool,
        currentIdentity: @escaping () -> AttriaxSessionIdentity,
        enqueueLifecycle: @escaping (AttriaxSessionLifecycleEvent) -> Void,
        requestFlush: @escaping () -> Void
    ) {
        self.sessionManager = sessionManager
        self.clock = clock
        self.scheduler = scheduler
        self.isEnabled = isEnabled
        self.currentIdentity = currentIdentity
        self.enqueueLifecycle = enqueueLifecycle
        self.requestFlush = requestFlush
    }

    var inBackground: Bool { withLock { isInBackground } }

    /// Seed the START to emit for a freshly-started restore session (row S3).
    func seedInitialSessionStart(_ session: AttriaxSessionSnapshot?) {
        withLock { pendingInitialStart = session }
    }

    /// Seed the recovered END to emit for a replaced restore session (row S5).
    func seedRecoveredSessionEnd(_ session: AttriaxSessionSnapshot?) {
        withLock { pendingRecoveredEnd = session }
    }

    /// Activate telemetry (called once the runtime is foregrounded / init completes):
    /// flush any pending initial START and (re)start the heartbeat timer.
    func activate() {
        let toFlush: (() -> Void)? = withLock {
            isActive = true
            let action = flushPendingInitialStartLocked()
            restartHeartbeatLocked()
            return action
        }
        toFlush?()
    }

    /// Stop the heartbeat and mark inactive (deactivate / dispose).
    func deactivate() {
        withLock {
            isActive = false
            stopHeartbeatLocked()
        }
    }

    func reset() {
        withLock {
            stopHeartbeatLocked()
            isActive = false
            isInBackground = false
            pendingInitialStart = nil
            pendingRecoveredEnd = nil
        }
    }

    /// The app moved to the foreground (row S3). On the first foreground of a launch
    /// (was not in background) this is a no-op beyond (re)starting the heartbeat —
    /// the initial START was already seeded at restore. A foreground FROM background
    /// resumes the same session (within window) or starts a new one (past window,
    /// with a recovered END for the replaced session).
    func handleForeground(atMs: Int64? = nil) {
        let at = atMs ?? clock.nowMs()
        var actions = [() -> Void]()
        withLock {
            let wasInBackground = isInBackground
            isInBackground = false
            if !isActive || !isEnabled() || !sessionManager.isTrackingEnabled {
                restartHeartbeatLocked()
                return
            }
            if !wasInBackground {
                restartHeartbeatLocked()
                return
            }

            let result = sessionManager.resumeOrStart(currentIdentity(), atMs: at)
            if let replaced = result.replacedSession {
                actions.append(enqueueRecoveredEndAction(replaced))
            }
            let kind = result.startedNewSession
                ? AttriaxSessionContinuation.Lifecycle.start
                : AttriaxSessionContinuation.Lifecycle.resume
            let occurredAt = result.startedNewSession ? result.currentSession.startedAtMs : at
            actions.append(enqueueLifecycleAction(kind, result.currentSession, occurredAt))
            restartHeartbeatLocked()
        }
        runActions(actions)
    }

    /// The app moved to the background/hidden (row S3): PAUSE the current session and
    /// stop the heartbeat. A no-op if already backgrounded.
    func handleBackground(atMs: Int64? = nil) {
        let at = atMs ?? clock.nowMs()
        var actions = [() -> Void]()
        withLock {
            let wasInBackground = isInBackground
            isInBackground = true
            stopHeartbeatLocked()
            if wasInBackground || !isEnabled() || !sessionManager.isTrackingEnabled {
                return
            }
            guard let session = sessionManager.recordActivity(at) else { return }
            if let recovered = flushPendingRecoveredEndLocked() { actions.append(recovered) }
            actions.append(enqueueLifecycleAction(AttriaxSessionContinuation.Lifecycle.pause, session, at))
        }
        runActions(actions, flushAfter: true)
    }

    /// The process is detaching (row S3): END the current session and stop the
    /// heartbeat.
    func handleDetached(atMs: Int64? = nil) {
        let at = atMs ?? clock.nowMs()
        var actions = [() -> Void]()
        withLock {
            isInBackground = true
            stopHeartbeatLocked()
            if !isEnabled() || !sessionManager.isTrackingEnabled { return }
            guard let session = sessionManager.end(at) else { return }
            actions.append(enqueueLifecycleAction(AttriaxSessionContinuation.Lifecycle.end, session, at))
        }
        runActions(actions, flushAfter: true)
    }

    /// Called by the dispatcher when a batch carrying an event tagged with
    /// `sessionId` is delivered (PARITY §4, row S4 keep-alive). Bumps the session's
    /// last-activity to `occurredAtMs` and restarts the heartbeat, so a stream of
    /// foreground events keeps the session alive without emitting extra heartbeats.
    func handleSuccessfulForegroundFlush(sessionId: String, occurredAtMs: Int64) {
        withLock {
            if !isEnabled() || !sessionManager.isTrackingEnabled || isInBackground { return }
            guard let session = sessionManager.currentSession else { return }
            if session.sessionId != sessionId { return }
            sessionManager.recordActivity(occurredAtMs)
            restartHeartbeatLocked()
        }
    }

    /// Build the keep-alive HEARTBEAT lifecycle event for the current session at
    /// `occurredAtMs` (row S4). Returns nil when there is no active foreground
    /// session — the dispatcher then appends no synthetic keep-alive.
    func buildKeepAliveHeartbeat(occurredAtMs: Int64? = nil) -> AttriaxSessionLifecycleEvent? {
        let at = occurredAtMs ?? clock.nowMs()
        return withLock {
            if isInBackground { return nil }
            guard let session = sessionManager.currentSession else { return nil }
            return AttriaxSessionLifecycleEvent(
                session: session,
                kind: AttriaxSessionContinuation.Lifecycle.heartbeat,
                occurredAtMs: at
            )
        }
    }

    // MARK: - internals

    /// Timer tick: record activity + enqueue a HEARTBEAT (row S3).
    private func onHeartbeatTick() {
        var actions = [() -> Void]()
        withLock {
            if !isEnabled() || !sessionManager.isTrackingEnabled { return }
            let occurredAt = clock.nowMs()
            guard let session = sessionManager.recordActivity(occurredAt) else { return }
            if let recovered = flushPendingRecoveredEndLocked() { actions.append(recovered) }
            actions.append(enqueueLifecycleAction(AttriaxSessionContinuation.Lifecycle.heartbeat, session, occurredAt))
        }
        runActions(actions)
    }

    private func restartHeartbeatLocked() {
        stopHeartbeatLocked()
        let session = sessionManager.currentSession
        if !isActive || !isEnabled() || !sessionManager.isTrackingEnabled || isInBackground || session == nil {
            return
        }
        heartbeatHandle = scheduler.schedulePeriodic(intervalMs: session!.heartbeatIntervalMs) { [weak self] in
            self?.onHeartbeatTick()
        }
    }

    private func stopHeartbeatLocked() {
        heartbeatHandle?.cancel()
        heartbeatHandle = nil
    }

    /// Consume the pending initial START, returning the enqueue action (or nil).
    private func flushPendingInitialStartLocked() -> (() -> Void)? {
        guard let session = pendingInitialStart,
              isEnabled(), sessionManager.isTrackingEnabled, !isInBackground else {
            return nil
        }
        pendingInitialStart = nil
        return enqueueLifecycleAction(AttriaxSessionContinuation.Lifecycle.start, session, session.startedAtMs)
    }

    /// Consume the pending recovered END, returning the enqueue action (or nil).
    private func flushPendingRecoveredEndLocked() -> (() -> Void)? {
        guard let session = pendingRecoveredEnd, isEnabled(), sessionManager.isTrackingEnabled else {
            return nil
        }
        pendingRecoveredEnd = nil
        return enqueueRecoveredEndAction(session)
    }

    private func enqueueRecoveredEndAction(_ session: AttriaxSessionSnapshot) -> () -> Void {
        let occurredAt = sessionManager.inferredRecoveredEndAtMs(session)
        return { [weak self] in
            self?.enqueueLifecycle(
                AttriaxSessionLifecycleEvent(
                    session: session,
                    kind: AttriaxSessionContinuation.Lifecycle.end,
                    occurredAtMs: occurredAt,
                    metadata: ["recovered": true]
                )
            )
        }
    }

    private func enqueueLifecycleAction(
        _ kind: String,
        _ session: AttriaxSessionSnapshot,
        _ occurredAtMs: Int64
    ) -> () -> Void {
        return { [weak self] in
            self?.enqueueLifecycle(AttriaxSessionLifecycleEvent(session: session, kind: kind, occurredAtMs: occurredAtMs))
        }
    }

    /// Run the collected enqueue actions OUTSIDE the lock (they call back into the
    /// engine's queue/consent path, which must not run under the session lock), then
    /// optionally kick a flush.
    private func runActions(_ actions: [() -> Void], flushAfter: Bool = false) {
        actions.forEach { $0() }
        if flushAfter || !actions.isEmpty { requestFlush() }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

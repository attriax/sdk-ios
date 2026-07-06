import Foundation

/// Identity + timing of the current launch, used to build a fresh session and to
/// decide continue-vs-new against a restored snapshot (PARITY §3, rows S2/S5).
struct AttriaxSessionIdentity {
    let deviceId: String?
    let platform: String
    let appPackageName: String?
    let appVersion: String?
    let appBuildNumber: String?
    let locale: String?
    let isFirstLaunch: Bool
    let sdkPackageVersion: String?

    func toContinuationContext() -> AttriaxSessionContext {
        AttriaxSessionContext(
            deviceId: deviceId,
            platform: platform,
            appPackageName: appPackageName,
            appVersion: appVersion,
            appBuildNumber: appBuildNumber
        )
    }
}

/// Outcome of a restore/resume decision (row S5): what is current, and what it
/// replaced.
struct AttriaxSessionRestoreResult {
    let currentSession: AttriaxSessionSnapshot
    let startedNewSession: Bool
    /// The session that was replaced (→ recovered-end), or nil when continued.
    let replacedSession: AttriaxSessionSnapshot?
}

/// Pure session state machine (PARITY §3, rows S2/S3/S5). Framework-free and
/// unit-testable: it holds the current snapshot in memory, persists it through
/// `snapshotStore`, and derives continue-vs-new via `AttriaxSessionContinuation`.
///
/// This chunk (A) ports the SNAPSHOT + TIMING state machine (restore/continue,
/// activity bump, end) which the event path needs to stamp `sessionId` +
/// `sessionRelativeTimeMs`. The heartbeat TIMER + foreground/background transition
/// telemetry (`AttriaxSessionLifecycleManager` in the Android reference) is CHUNK
/// B and builds on this class — hence `resumeOrStart`/`recordActivity`/`end` are
/// present here as seams even though no timer drives them yet.
///
/// The heartbeat interval for a new session is chosen by first-launch:
/// `firstLaunchHeartbeatIntervalMs` (30s default) for the very first launch, else
/// `heartbeatIntervalMs` (5min default) — row S3.
final class AttriaxSessionManager {
    private let clock: AttriaxClock
    private let snapshotStore: AttriaxSessionSnapshotStore
    private let heartbeatIntervalMs: Int64
    private let firstLaunchHeartbeatIntervalMs: Int64
    private let generateSessionId: () -> String
    private let lock = NSRecursiveLock()

    private(set) var currentSession: AttriaxSessionSnapshot?
    private(set) var isTrackingEnabled = false

    init(
        clock: AttriaxClock,
        snapshotStore: AttriaxSessionSnapshotStore,
        heartbeatIntervalMs: Int64,
        firstLaunchHeartbeatIntervalMs: Int64,
        generateSessionId: @escaping () -> String
    ) {
        self.clock = clock
        self.snapshotStore = snapshotStore
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.firstLaunchHeartbeatIntervalMs = firstLaunchHeartbeatIntervalMs
        self.generateSessionId = generateSessionId
    }

    /// Restore the persisted snapshot at launch, continuing it (same id, bumped
    /// activity) when identity matches and it is within the continuation window,
    /// else starting a new session and reporting the replaced one (row S5).
    func restoreOrStart(_ identity: AttriaxSessionIdentity) -> AttriaxSessionRestoreResult {
        lock.lock(); defer { lock.unlock() }
        isTrackingEnabled = true
        let now = clock.nowMs()
        let stored = snapshotStore.read()
        return decide(stored, identity, now)
    }

    /// Resume the in-memory session (foreground after background) — CHUNK B seam.
    func resumeOrStart(_ identity: AttriaxSessionIdentity, atMs: Int64? = nil) -> AttriaxSessionRestoreResult {
        lock.lock(); defer { lock.unlock() }
        return decide(currentSession, identity, atMs ?? clock.nowMs())
    }

    private func decide(_ candidate: AttriaxSessionSnapshot?, _ identity: AttriaxSessionIdentity, _ nowMs: Int64) -> AttriaxSessionRestoreResult {
        let continued = AttriaxSessionContinuation.shouldContinue(candidate, identity.toContinuationContext(), nowMs)
        let session: AttriaxSessionSnapshot
        if continued, let candidate = candidate {
            session = candidate.withLastActivity(nowMs)
        } else {
            session = buildSession(identity, nowMs)
        }
        currentSession = session
        snapshotStore.write(session)
        return AttriaxSessionRestoreResult(
            currentSession: session,
            startedNewSession: !continued,
            replacedSession: continued ? nil : candidate
        )
    }

    /// Bump the current session's last-activity to `atMs`. Monotonic: an
    /// out-of-order (earlier) timestamp is ignored. Returns the (possibly
    /// unchanged) current session, or nil when there is no active session.
    @discardableResult
    func recordActivity(_ atMs: Int64? = nil) -> AttriaxSessionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let session = currentSession else { return nil }
        let at = atMs ?? clock.nowMs()
        if at < session.lastActivityAtMs { return session }
        let updated = session.withLastActivity(at)
        currentSession = updated
        snapshotStore.write(updated)
        return updated
    }

    /// End the current session (process detach), clearing it from memory and
    /// storage. Returns the final snapshot, or nil when none was active.
    @discardableResult
    func end(_ atMs: Int64? = nil) -> AttriaxSessionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let session = currentSession else { return nil }
        let at = atMs ?? clock.nowMs()
        let finalSession = at < session.lastActivityAtMs ? session : session.withLastActivity(at)
        currentSession = nil
        snapshotStore.write(nil)
        return finalSession
    }

    /// Inferred recovered-end timestamp for a replaced `session` (row S5).
    func inferredRecoveredEndAtMs(_ session: AttriaxSessionSnapshot) -> Int64 {
        AttriaxSessionContinuation.inferredRecoveredEndAtMs(session, clock.nowMs())
    }

    /// Clear the current session from memory + storage (reset / disabled).
    func clear() {
        lock.lock(); defer { lock.unlock() }
        currentSession = nil
        snapshotStore.write(nil)
    }

    /// Full reset to the disabled/no-session state (PARITY reset).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        isTrackingEnabled = false
        currentSession = nil
        snapshotStore.write(nil)
    }

    private func buildSession(_ identity: AttriaxSessionIdentity, _ nowMs: Int64) -> AttriaxSessionSnapshot {
        AttriaxSessionSnapshot(
            sessionId: generateSessionId(),
            startedAtMs: nowMs,
            lastActivityAtMs: nowMs,
            heartbeatIntervalMs: identity.isFirstLaunch ? firstLaunchHeartbeatIntervalMs : heartbeatIntervalMs,
            deviceId: identity.deviceId,
            platform: identity.platform,
            appPackageName: identity.appPackageName,
            appVersion: identity.appVersion,
            appBuildNumber: identity.appBuildNumber,
            locale: identity.locale,
            isFirstLaunch: identity.isFirstLaunch,
            sdkPackageVersion: identity.sdkPackageVersion
        )
    }
}

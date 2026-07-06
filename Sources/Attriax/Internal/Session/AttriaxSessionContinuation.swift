import Foundation

/// A persisted session snapshot's identity + timing fields relevant to the
/// continuation decision (PARITY §3, rows S2/S5).
struct AttriaxSessionSnapshot: Equatable {
    let sessionId: String
    let startedAtMs: Int64
    var lastActivityAtMs: Int64
    let heartbeatIntervalMs: Int64
    let deviceId: String?
    let platform: String
    let appPackageName: String?
    let appVersion: String?
    let appBuildNumber: String?
    // Context carried on the session lifecycle wire payload (SdkSessionDto).
    let locale: String?
    let isFirstLaunch: Bool
    let sdkPackageVersion: String?

    init(
        sessionId: String,
        startedAtMs: Int64,
        lastActivityAtMs: Int64,
        heartbeatIntervalMs: Int64,
        deviceId: String?,
        platform: String,
        appPackageName: String?,
        appVersion: String?,
        appBuildNumber: String?,
        locale: String? = nil,
        isFirstLaunch: Bool = false,
        sdkPackageVersion: String? = nil
    ) {
        self.sessionId = sessionId
        self.startedAtMs = startedAtMs
        self.lastActivityAtMs = lastActivityAtMs
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.deviceId = deviceId
        self.platform = platform
        self.appPackageName = appPackageName
        self.appVersion = appVersion
        self.appBuildNumber = appBuildNumber
        self.locale = locale
        self.isFirstLaunch = isFirstLaunch
        self.sdkPackageVersion = sdkPackageVersion
    }

    /// Clamped ms-since-start for a lifecycle event at `occurredAtMs` (row S3).
    func sessionRelativeTimeMs(_ occurredAtMs: Int64) -> Int64 {
        min(max(occurredAtMs - startedAtMs, 0), Int64(Int32.max))
    }

    /// Value-type copy with a bumped last-activity.
    func withLastActivity(_ atMs: Int64) -> AttriaxSessionSnapshot {
        var copy = self
        copy.lastActivityAtMs = atMs
        return copy
    }
}

/// Identity + timing of the current launch, compared against a restored snapshot.
struct AttriaxSessionContext: Equatable {
    let deviceId: String?
    let platform: String
    let appPackageName: String?
    let appVersion: String?
    let appBuildNumber: String?
}

/// Session continuation-window policy (PARITY §3, row S2).
///
/// Window = `2 × heartbeatInterval` clamped to `[60s, 30min]`. On restore, a
/// session continues (same id, bumped activity) only when the device/platform/app
/// identity match and its age since last activity is within the window.
enum AttriaxSessionContinuation {
    static let minWindowMs: Int64 = 60_000        // 60s lower bound
    static let maxWindowMs: Int64 = 30 * 60_000   // 30min upper bound

    /// Session lifecycle kinds (row S3).
    enum Lifecycle {
        static let start = "start"
        static let heartbeat = "heartbeat"
        static let pause = "pause"
        static let resume = "resume"
        static let end = "end"

        static let all = [start, heartbeat, pause, resume, end]
    }

    /// Clamped continuation window for a snapshot's heartbeat interval.
    static func continuationWindowMs(_ heartbeatIntervalMs: Int64) -> Int64 {
        let raw = heartbeatIntervalMs * 2
        if raw < minWindowMs { return minWindowMs }
        if raw > maxWindowMs { return maxWindowMs }
        return raw
    }

    /// Whether `snapshot` should be continued given the current-launch `context`
    /// and wall-clock `nowMs`. Returns false (→ start new + queue recovered-end)
    /// when the snapshot is absent, identity drifted, its start is in the future,
    /// or it is older than the continuation window.
    static func shouldContinue(_ snapshot: AttriaxSessionSnapshot?, _ context: AttriaxSessionContext, _ nowMs: Int64) -> Bool {
        guard let snapshot = snapshot else { return false }
        if snapshot.deviceId != context.deviceId { return false }
        if snapshot.platform != context.platform { return false }
        if snapshot.appPackageName != context.appPackageName { return false }
        if snapshot.appVersion != context.appVersion { return false }
        if snapshot.appBuildNumber != context.appBuildNumber { return false }
        if snapshot.startedAtMs > nowMs { return false }

        let age = nowMs - snapshot.lastActivityAtMs
        return age <= continuationWindowMs(snapshot.heartbeatIntervalMs)
    }

    /// Inferred `end` timestamp for a recovered (replaced) session (row S5). The
    /// session ended while the app was not running, so its projected end
    /// (lastActivity + window) is clamped to `nowMs`. Mirrors Flutter/Android.
    static func inferredRecoveredEndAtMs(_ snapshot: AttriaxSessionSnapshot, _ nowMs: Int64) -> Int64 {
        let projectedEnd = snapshot.lastActivityAtMs + continuationWindowMs(snapshot.heartbeatIntervalMs)
        return projectedEnd > nowMs ? nowMs : projectedEnd
    }
}

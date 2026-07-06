import Foundation

/// A single persisted queued request (PARITY §7, row Q1).
///
/// The persisted JSON shape is:
/// `{id, kind, body, createdAt, attemptCount, lastAttemptAt, lastErrorClass,
///   lastHttpStatusCode, nextRetryAt}` — mirroring Flutter/Android
/// `AttriaxQueuedRequest`. Timestamps are epoch-millis (queue bookkeeping only
/// needs monotonic comparison; the wire uses ISO-8601 inside the payloads).
struct AttriaxQueuedRequest {
    let id: String
    let request: AttriaxApiRequest
    let createdAtMs: Int64
    var attemptCount: Int = 0
    var lastAttemptAtMs: Int64?
    var lastErrorClass: String?
    var lastHttpStatusCode: Int?
    var nextRetryAtMs: Int64?

    /// Value-type copy with a replacement request (used by consent reconciliation
    /// in later chunks; kept here for structural parity with the Android `copy`).
    func withRequest(_ newRequest: AttriaxApiRequest) -> AttriaxQueuedRequest {
        var copy = self
        return AttriaxQueuedRequest(
            id: copy.id,
            request: newRequest,
            createdAtMs: copy.createdAtMs,
            attemptCount: copy.attemptCount,
            lastAttemptAtMs: copy.lastAttemptAtMs,
            lastErrorClass: copy.lastErrorClass,
            lastHttpStatusCode: copy.lastHttpStatusCode,
            nextRetryAtMs: copy.nextRetryAtMs
        )
    }
}

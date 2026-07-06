import Foundation

/// A synthetic session keep-alive appended to a batch that carries a live-session
/// event (PARITY §4, row S4). The `request` MUST be a batchable session request
/// that shares identity with the batch group. It is appended to the transport
/// payload only (never persisted in the queue); on successful batch delivery the
/// dispatcher reports `(sessionId, occurredAtMs)` so the session manager can bump
/// last-activity. Mirrors Flutter/Android `_BatchKeepAliveRequest`.
///
/// NOTE (chunk scope): the session HEARTBEAT keep-alive is produced by the session
/// LIFECYCLE manager, which lands in chunk B. In this chunk the dispatcher accepts
/// a keep-alive-builder seam but the runtime supplies `nil` (no live-session
/// heartbeat injection yet). The type is defined here so the dispatcher contract
/// is stable across chunks.
struct AttriaxBatchKeepAlive {
    let request: AttriaxApiRequest
    let sessionId: String
    let occurredAtMs: Int64

    /// Stable synthetic id (id space is disjoint from persisted queued ids).
    var syntheticId: String { "keepalive_\(sessionId)_\(occurredAtMs)" }
}

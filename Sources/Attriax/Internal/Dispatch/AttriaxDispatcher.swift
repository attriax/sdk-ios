import Foundation

/// The flush engine (PARITY §3/§7). Combines:
///  - app-open-first hoist (row O2),
///  - consecutive-identity batch grouping + limits + binary split (rows Q5/Q6/E5),
///  - single-send fallback,
///  - retry marking / backoff / terminal drop (rows Q2/Q3/Q4),
///  - single-flight flush.
///
/// Transport failures are classified into `AttriaxFailure` so the retry policy
/// stays pure; the dispatcher only owns orchestration + persistence.
final class AttriaxDispatcher {
    private let queue: AttriaxQueueManager
    private let transport: AttriaxHttpClient
    private let clock: AttriaxClock
    private let onDelivered: ((AttriaxQueuedRequest, AttriaxHttpResponse) -> Void)?
    private let buildSessionKeepAliveBatch: (([AttriaxQueuedRequest]) -> AttriaxBatchKeepAlive?)?
    private let onSessionKeepAliveDelivered: ((_ sessionId: String, _ occurredAtMs: Int64) -> Void)?
    private let onDropped: ((AttriaxQueuedRequest, _ reason: String) -> Void)?

    private let flushLock = NSRecursiveLock()

    /// - Parameters:
    ///   - onDelivered: notified with the (envelope-unwrapped) response when a
    ///     SINGLE-SEND request is delivered (2xx). Used by the app-open handler and
    ///     deep-link resolves (chunk B). Not invoked for batched items.
    ///   - buildSessionKeepAliveBatch: session keep-alive injection (row S4).
    ///     Supplied by chunk B; nil in this chunk.
    ///   - onSessionKeepAliveDelivered: notified after a batch carrying an injected
    ///     keep-alive is delivered (chunk B; nil here).
    ///   - onDropped: notified when a request is permanently dropped.
    init(
        queue: AttriaxQueueManager,
        transport: AttriaxHttpClient,
        clock: AttriaxClock,
        onDelivered: ((AttriaxQueuedRequest, AttriaxHttpResponse) -> Void)? = nil,
        buildSessionKeepAliveBatch: (([AttriaxQueuedRequest]) -> AttriaxBatchKeepAlive?)? = nil,
        onSessionKeepAliveDelivered: ((String, Int64) -> Void)? = nil,
        onDropped: ((AttriaxQueuedRequest, String) -> Void)? = nil
    ) {
        self.queue = queue
        self.transport = transport
        self.clock = clock
        self.onDelivered = onDelivered
        self.buildSessionKeepAliveBatch = buildSessionKeepAliveBatch
        self.onSessionKeepAliveDelivered = onSessionKeepAliveDelivered
        self.onDropped = onDropped
    }

    /// Flush the queue once. Single-flight: concurrent callers are serialized.
    /// Returns the number of requests successfully delivered.
    @discardableResult
    func flush() -> Int {
        flushLock.lock(); defer { flushLock.unlock() }

        let ordered = AttriaxAppOpenHoist.prioritize(queue.readAll())
        if ordered.isEmpty { return 0 }

        // Ids present at flush start; anything enqueued DURING the flush must be
        // preserved on write-back so a concurrent enqueue is not clobbered.
        let snapshotIds = Set(ordered.map { $0.id })
        var remaining = ordered
        var delivered = 0
        var index = 0

        while index < remaining.count {
            // Skip requests still inside their retry window.
            if isWaitingForRetry(remaining[index]) {
                index += 1
                continue
            }

            let items = AttriaxBatching.collectSendableRun(
                remaining.map { AttriaxBatchQueuedItem(id: $0.id, request: $0.request) },
                startIndex: index
            )
            let group = Array(remaining[index..<(index + items.count)])

            let outcome: Outcome
            if group.count == 1 && !group[0].request.isBatchable {
                outcome = sendSingle(group[0])
            } else {
                outcome = sendBatch(group)
            }

            // Replace the group in `remaining` with whatever must be re-queued.
            remaining.removeSubrange(index..<(index + group.count))
            remaining.insert(contentsOf: outcome.reQueued, at: index)
            delivered += outcome.deliveredCount

            if outcome.stop {
                // A retryable failure halts this flush pass; persist and bail.
                break
            }
            index += outcome.reQueued.count
        }

        queue.writeAllPreservingNew(remaining, snapshotIds: snapshotIds)
        return delivered
    }

    private struct Outcome {
        let reQueued: [AttriaxQueuedRequest]
        let deliveredCount: Int
        let stop: Bool
    }

    private func sendSingle(_ queued: AttriaxQueuedRequest) -> Outcome {
        do {
            let response = try transport.post(queued.request.path, AttriaxJson.encode(queued.request.body))
            onDelivered?(queued, response)
            return Outcome(reQueued: [], deliveredCount: 1, stop: false)
        } catch {
            guard let failure = classify(error) else {
                // Non-transport error — treat as a hard drop to avoid a poison loop.
                onDropped?(queued, "unexpected_error")
                return Outcome(reQueued: [], deliveredCount: 0, stop: false)
            }
            return handleSingleFailure(queued, failure)
        }
    }

    private func handleSingleFailure(_ queued: AttriaxQueuedRequest, _ failure: AttriaxFailure) -> Outcome {
        let attemptedAt = clock.nowMs()
        if AttriaxRetryPolicy.isRetryable(failure) {
            let marked = markForRetry(queued, failure, attemptedAt)
            if dropIfTerminal(marked, nowMs: attemptedAt) {
                return Outcome(reQueued: [], deliveredCount: 0, stop: false)
            }
            // Retryable failure halts the flush (server likely unhealthy).
            return Outcome(reQueued: [marked], deliveredCount: 0, stop: true)
        }

        // Non-retryable (other 4xx) → drop.
        onDropped?(queued, "non_retryable_\(AttriaxRetryPolicy.errorClass(failure))")
        return Outcome(reQueued: [], deliveredCount: 0, stop: false)
    }

    private func sendBatch(_ group: [AttriaxQueuedRequest]) -> Outcome {
        // Row S4: append a synthetic session keep-alive to the TRANSPORT payload only
        // (never persisted), when the group carries an event for the live session.
        let keepAlive = buildSessionKeepAliveBatch?(group)
        var transportItems = group.map { AttriaxBatchQueuedItem(id: $0.id, request: $0.request) }
        if let keepAlive = keepAlive {
            transportItems.append(AttriaxBatchQueuedItem(id: keepAlive.syntheticId, request: keepAlive.request))
        }
        let batchBody = AttriaxBatching.buildBatchBody(transportItems)

        do {
            _ = try transport.post(AttriaxEndpoints.batch, AttriaxJson.encode(batchBody))
            if let keepAlive = keepAlive {
                onSessionKeepAliveDelivered?(keepAlive.sessionId, keepAlive.occurredAtMs)
            }
            return Outcome(reQueued: [], deliveredCount: group.count, stop: false)
        } catch {
            let failure = classify(error)
            if let failure = failure, AttriaxRetryPolicy.isRetryable(failure) {
                let attemptedAt = clock.nowMs()
                // Mark each item for retry, but terminal-drop any that now exceed
                // the attempt/age thresholds (mirrors the single-send path).
                let survivors = group
                    .map { markForRetry($0, failure, attemptedAt) }
                    .filter { !dropIfTerminal($0, nowMs: attemptedAt) }
                return Outcome(reQueued: survivors, deliveredCount: 0, stop: true)
            }

            // Non-retryable batch failure → binary split retry.
            if group.count > 1 {
                let splitIndex = group.count / 2
                let firstHalf = sendBatch(Array(group[0..<splitIndex]))
                if firstHalf.stop {
                    return Outcome(
                        reQueued: firstHalf.reQueued + Array(group[splitIndex...]),
                        deliveredCount: firstHalf.deliveredCount,
                        stop: true
                    )
                }
                let secondHalf = sendBatch(Array(group[splitIndex...]))
                return Outcome(
                    reQueued: firstHalf.reQueued + secondHalf.reQueued,
                    deliveredCount: firstHalf.deliveredCount + secondHalf.deliveredCount,
                    stop: secondHalf.stop
                )
            }

            // A single failing item falls back to per-request handling.
            let single = group[0]
            if let failure = failure {
                return handleSingleFailure(single, failure)
            }
            onDropped?(single, "unexpected_error")
            return Outcome(reQueued: [], deliveredCount: 0, stop: false)
        }
    }

    /// Notify + report true if `marked` has hit a terminal-drop threshold.
    private func dropIfTerminal(_ marked: AttriaxQueuedRequest, nowMs: Int64) -> Bool {
        guard let terminal = AttriaxRetryPolicy.terminalDropReason(
            marked.request, attemptCount: marked.attemptCount, createdAtMs: marked.createdAtMs, nowMs: nowMs
        ) else {
            return false
        }
        onDropped?(marked, terminal)
        return true
    }

    private func markForRetry(
        _ queued: AttriaxQueuedRequest,
        _ failure: AttriaxFailure,
        _ attemptedAtMs: Int64
    ) -> AttriaxQueuedRequest {
        let nextAttempt = queued.attemptCount + 1
        var marked = queued
        marked.attemptCount = nextAttempt
        marked.lastAttemptAtMs = attemptedAtMs
        marked.lastErrorClass = AttriaxRetryPolicy.errorClass(failure)
        marked.lastHttpStatusCode = AttriaxRetryPolicy.httpStatusCode(failure)
        marked.nextRetryAtMs = AttriaxRetryPolicy.nextRetryAtMs(
            failure, attemptedAtMs: attemptedAtMs, nextAttemptCount: nextAttempt
        )
        return marked
    }

    private func isWaitingForRetry(_ queued: AttriaxQueuedRequest) -> Bool {
        guard let retryAt = queued.nextRetryAtMs else { return false }
        return retryAt > clock.nowMs()
    }

    private func classify(_ error: Error) -> AttriaxFailure? {
        guard let transportError = error as? AttriaxTransportError else { return nil }
        switch transportError {
        case let .http(statusCode, _, headers):
            return .http(statusCode: statusCode, retryAfter: headerOf(headers, "retry-after"))
        case .timeout:
            return .timeout
        case .transport:
            return .transport
        }
    }

    private func headerOf(_ headers: [String: String], _ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

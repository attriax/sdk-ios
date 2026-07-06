import Foundation

/// Batch limits (PARITY rows Q5): ≤100 items, ≤256 KiB encoded.
enum AttriaxBatchLimits {
    static let maxItems = 100
    static let maxBodyBytes = 256 * 1024
}

/// Shared identity that consecutive batchable requests must agree on (row Q6).
/// INCLUDES `projectToken` (multi-project; sdk-js omits it — we mirror
/// Flutter/Android).
struct AttriaxBatchIdentity: Equatable {
    let projectToken: String
    let deviceId: String
    let deviceIdSource: String?
}

/// Minimal view of a queued request the batcher needs (id + request).
struct AttriaxBatchQueuedItem {
    let id: String
    let request: AttriaxApiRequest
}

/// Pure batching field-placement + grouping helpers (PARITY §4/§7, rows E5/Q6).
///
/// Each batch item strips `projectToken`/`deviceId`/`deviceIdSource` and hoists
/// them to the shared batch envelope; the single-send path keeps them per-request.
enum AttriaxBatching {

    /// Extract the shared identity from a batchable request.
    static func identity(of request: AttriaxApiRequest) -> AttriaxBatchIdentity {
        precondition(request.isBatchable, "not a batchable request: \(request.kind)")
        guard let projectToken = request.body[AttriaxApiRequest.fieldProjectToken].flatMap({ $0 }) as? String else {
            fatalError("batchable request missing projectToken")
        }
        guard let deviceId = request.body[AttriaxApiRequest.fieldDeviceId].flatMap({ $0 }) as? String else {
            fatalError("batchable request missing deviceId")
        }
        return AttriaxBatchIdentity(
            projectToken: projectToken,
            deviceId: deviceId,
            deviceIdSource: request.body[AttriaxApiRequest.fieldDeviceIdSource].flatMap { $0 } as? String
        )
    }

    /// True when `left` and `right` are both batchable and share identity.
    static func canShare(_ left: AttriaxApiRequest, _ right: AttriaxApiRequest) -> Bool {
        guard left.isBatchable, right.isBatchable else { return false }
        return identity(of: left) == identity(of: right)
    }

    /// The per-item body with identity fields stripped (they live on the envelope).
    static func itemBody(of request: AttriaxApiRequest) -> AttriaxJSONObject {
        precondition(request.isBatchable, "not a batchable request: \(request.kind)")
        var stripped = request.body
        stripped.removeValue(forKey: AttriaxApiRequest.fieldProjectToken)
        stripped.removeValue(forKey: AttriaxApiRequest.fieldDeviceId)
        stripped.removeValue(forKey: AttriaxApiRequest.fieldDeviceIdSource)
        return stripped
    }

    /// Stable batch requestId derived from the first queued request id.
    static func batchRequestId(_ firstQueuedId: String) -> String { "batch_\(firstQueuedId)" }

    /// Build the `/api/sdk/v1/batch` envelope body from a group of queued requests
    /// that share identity. Identity is hoisted; items carry stripped bodies tagged
    /// with their batch kind name.
    static func buildBatchBody(_ group: [AttriaxBatchQueuedItem]) -> AttriaxJSONObject {
        precondition(!group.isEmpty, "cannot build an empty batch")
        let first = group[0]
        let identity = identity(of: first.request)
        var body = AttriaxJSONObject()
        body["requestId"] = batchRequestId(first.id)
        body[AttriaxApiRequest.fieldProjectToken] = identity.projectToken
        body[AttriaxApiRequest.fieldDeviceId] = identity.deviceId
        if let src = identity.deviceIdSource {
            body[AttriaxApiRequest.fieldDeviceIdSource] = src
        }
        body["items"] = group.map { item -> AttriaxJSONObject in
            [
                "kind": item.request.batchKindName,
                "body": itemBody(of: item.request),
            ]
        }
        return body
    }

    /// Collect the maximal run of consecutive batchable requests starting at
    /// `startIndex` that share identity AND fit within the item/byte limits.
    ///
    /// Greedily extends the run, stopping at the first non-batchable request,
    /// identity mismatch, or when adding the next item would exceed a limit. If the
    /// run at `startIndex` is not batchable at all, returns just that single request.
    static func collectSendableRun(_ queue: [AttriaxBatchQueuedItem], startIndex: Int) -> [AttriaxBatchQueuedItem] {
        var run = [AttriaxBatchQueuedItem]()
        var index = startIndex
        while index < queue.count {
            let candidate = queue[index]
            if !candidate.request.isBatchable { break }
            if let first = run.first, !canShare(first.request, candidate.request) { break }

            run.append(candidate)
            if !fits(run) {
                run.removeLast()
                break
            }
            index += 1
        }
        return run.isEmpty ? [queue[startIndex]] : run
    }

    private static func fits(_ run: [AttriaxBatchQueuedItem]) -> Bool {
        if run.isEmpty { return false }
        if run.count > AttriaxBatchLimits.maxItems { return false }
        let bytes = AttriaxJson.encodedByteSize(buildBatchBody(run))
        return bytes <= AttriaxBatchLimits.maxBodyBytes
    }
}

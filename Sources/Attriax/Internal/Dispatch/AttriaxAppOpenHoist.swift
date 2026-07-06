import Foundation

/// App-open-first ordering (PARITY §3, row O2;
/// Flutter `dispatcher.dart:515-530` `_prioritizeAppOpenRequests`).
///
/// Enforced positionally at flush, not by a lock: any app-open request is hoisted
/// to the front of the flush order, preserving the relative order of both the
/// hoisted opens and the remaining requests (a stable partition).
enum AttriaxAppOpenHoist {
    static func prioritize(_ queue: [AttriaxQueuedRequest]) -> [AttriaxQueuedRequest] {
        var opens = [AttriaxQueuedRequest]()
        var others = [AttriaxQueuedRequest]()
        for queued in queue {
            if queued.request.isAppOpen { opens.append(queued) } else { others.append(queued) }
        }
        return opens + others
    }
}

import Foundation

/// Persists the outbound request queue to an `AttriaxKeyValueStore`
/// (PARITY §7, row Q1).
///
/// All ordering/serialization/corruption logic lives in `AttriaxQueueCodec`
/// (pure); this class adds the persistence + FIFO overflow eviction beyond
/// `maxQueueSize`, guarded by a serial lock so concurrent enqueue/flush do not
/// interleave a read-modify-write.
final class AttriaxQueueManager {
    static let keyQueue = "attriax.request_queue"

    private let store: AttriaxKeyValueStore
    private let maxQueueSize: Int
    private let lock = NSRecursiveLock()

    init(store: AttriaxKeyValueStore, maxQueueSize: Int) {
        self.store = store
        self.maxQueueSize = maxQueueSize
    }

    func readAll() -> [AttriaxQueuedRequest] {
        lock.lock(); defer { lock.unlock() }
        return readAllUnlocked()
    }

    private func readAllUnlocked() -> [AttriaxQueuedRequest] {
        let result = AttriaxQueueCodec.decode(store.getString(Self.keyQueue))
        if result.clearedWholePayload {
            store.remove(Self.keyQueue)
            return []
        }
        if result.droppedEntryCount > 0 {
            // Rewrite the pruned queue so the invalid entries do not resurface.
            writeAllUnlocked(result.queue)
        }
        return result.queue
    }

    func enqueue(_ request: AttriaxQueuedRequest) {
        lock.lock(); defer { lock.unlock() }
        var queue = readAllUnlocked()
        queue.append(request)
        if queue.count > maxQueueSize {
            let overflow = queue.count - maxQueueSize
            // FIFO: evict the oldest entries at the head.
            queue.removeFirst(overflow)
        }
        writeAllUnlocked(queue)
    }

    func writeAll(_ queue: [AttriaxQueuedRequest]) {
        lock.lock(); defer { lock.unlock() }
        writeAllUnlocked(queue)
    }

    /// Persist a flushed queue `remaining` WITHOUT clobbering requests that were
    /// enqueued concurrently during the flush (PARITY §7). The dispatcher snapshots
    /// the queue at the start of a flush; any request appended while the flush was
    /// in flight (its id is in neither `remaining` nor `snapshotIds`) must be
    /// preserved and appended after the flushed remainder — otherwise a plain
    /// `writeAll(remaining)` would silently drop it. Especially important for
    /// retry-exempt kinds (deep-link resolve), which must never be lost.
    func writeAllPreservingNew(_ remaining: [AttriaxQueuedRequest], snapshotIds: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let remainingIds = Set(remaining.map { $0.id })
        let newlyAdded = readAllUnlocked().filter {
            !snapshotIds.contains($0.id) && !remainingIds.contains($0.id)
        }
        writeAllUnlocked(remaining + newlyAdded)
    }

    /// Atomically rewrite queued entries (consent reconciliation, later chunk).
    /// `transform` returns a replacement entry, or nil to leave the entry as-is.
    /// Returns the number of entries actually changed.
    @discardableResult
    func rewriteWhere(_ transform: (AttriaxQueuedRequest) -> AttriaxQueuedRequest?) -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = readAllUnlocked()
        var changed = 0
        let rewritten = current.map { entry -> AttriaxQueuedRequest in
            if let replacement = transform(entry) {
                changed += 1
                return replacement
            }
            return entry
        }
        if changed > 0 { writeAllUnlocked(rewritten) }
        return changed
    }

    /// Atomically discard queued entries matching `predicate`. Returns the number
    /// of entries removed.
    @discardableResult
    func discardWhere(_ predicate: (AttriaxQueuedRequest) -> Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = readAllUnlocked()
        let kept = current.filter { !predicate($0) }
        let removed = current.count - kept.count
        if removed > 0 { writeAllUnlocked(kept) }
        return removed
    }

    private func writeAllUnlocked(_ queue: [AttriaxQueuedRequest]) {
        if queue.isEmpty {
            store.remove(Self.keyQueue)
            return
        }
        store.putString(Self.keyQueue, AttriaxQueueCodec.encode(queue))
    }
}

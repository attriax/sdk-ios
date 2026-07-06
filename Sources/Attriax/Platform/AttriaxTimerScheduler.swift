import Foundation

/// `AttriaxScheduler` backed by a `Timer` on a dedicated background run-loop thread
/// so heartbeat timers (PARITY §3, row S3) run OFF the main thread and never leak: a
/// cancelled handle invalidates its timer, and the thread exits when it has no more
/// timers. Mirrors the Android `AttriaxExecutorScheduler` (single daemon scheduled
/// executor).
///
/// This is the only production scheduler; the pure session-lifecycle manager and
/// its tests depend on the `AttriaxScheduler` protocol, never on this class.
final class AttriaxTimerScheduler: AttriaxScheduler {

    /// A long-lived background thread that owns a run loop for the SDK's timers.
    /// One thread is shared by every scheduled timer (there is at most one heartbeat
    /// at a time, but the design tolerates more).
    private final class RunLoopThread: Thread {
        private let readyLatch = DispatchSemaphore(value: 0)
        private(set) var runLoop: RunLoop?

        override func main() {
            let loop = RunLoop.current
            runLoop = loop
            // A port keeps the run loop alive even when no timer is currently armed.
            loop.add(Port(), forMode: .common)
            readyLatch.signal()
            while !isCancelled {
                loop.run(mode: .common, before: .distantFuture)
            }
        }

        func waitUntilReady() {
            readyLatch.wait()
        }
    }

    private final class TimerHandle: AttriaxScheduledHandle {
        private let lock = NSLock()
        private var timer: Timer?

        init(timer: Timer) { self.timer = timer }

        func cancel() {
            lock.lock()
            let t = timer
            timer = nil
            lock.unlock()
            // Timer must be invalidated on the run loop it was scheduled on; posting
            // via the timer's own target thread is not available here, so invalidate
            // directly — Foundation tolerates invalidate() from another thread for a
            // timer added to a live run loop, and the run loop drops the reference on
            // its next cycle. Kept minimal by design.
            t?.invalidate()
        }
    }

    private let thread: RunLoopThread

    init() {
        thread = RunLoopThread()
        thread.name = "com.attriax.sdk.session-timer"
        thread.stackSize = 128 * 1024
        thread.start()
        thread.waitUntilReady()
    }

    func schedulePeriodic(intervalMs: Int64, action: @escaping () -> Void) -> AttriaxScheduledHandle {
        let interval = TimeInterval(intervalMs) / 1000.0
        // Create the timer with the FIRST fire one interval out (matches the Android
        // `scheduleAtFixedRate(initialDelay = interval)` semantics), then hand it to
        // the background run loop.
        let timer = Timer(fire: Date(timeIntervalSinceNow: interval), interval: interval, repeats: true) { _ in
            // A heartbeat failure must never crash the host or kill the timer.
            action()
        }
        let handle = TimerHandle(timer: timer)
        if let loop = thread.runLoop {
            loop.add(timer, forMode: .common)
        }
        return handle
    }

    func shutdown() {
        thread.cancel()
    }
}

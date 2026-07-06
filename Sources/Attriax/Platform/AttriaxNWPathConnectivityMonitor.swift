import Foundation
import Network

/// `AttriaxConnectivityMonitor` backed by `NWPathMonitor` (mirrors the Android
/// `ConnectivityManager` monitor). Invokes `onConnectivityRestored` when the path
/// transitions from unsatisfied → satisfied so the engine can re-flush a queue
/// that stalled while offline (PARITY §7 "connectivity restore re-flushes").
final class AttriaxNWPathConnectivityMonitor: AttriaxConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.attriax.sdk.connectivity")
    private let lock = NSLock()
    private var connected = false
    private var onRestored: (() -> Void)?

    func isConnected() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connected
    }

    func register(_ onConnectivityRestored: @escaping () -> Void) {
        lock.lock()
        onRestored = onConnectivityRestored
        connected = monitor.currentPath.status == .satisfied
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            let wasConnected = self.connected
            let nowConnected = path.status == .satisfied
            self.connected = nowConnected
            let callback = self.onRestored
            self.lock.unlock()

            if !wasConnected, nowConnected {
                callback?()
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func unregister() {
        lock.lock()
        onRestored = nil
        lock.unlock()
        monitor.cancel()
    }
}

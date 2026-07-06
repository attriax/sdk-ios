import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Thin iOS adapter that maps app foreground/background/terminate transitions from
/// `UIApplication` NotificationCenter onto the pure `AttriaxSessionLifecycleManager`
/// (PARITY §3, row S3). This is the ONLY session file that touches UIKit, keeping
/// the state machine + heartbeat logic unit-testable. Mirrors the Android
/// `AttriaxProcessLifecycleObserver` (ProcessLifecycleOwner adapter).
///
/// Mapping (mirrors the reference `AppLifecycleState` handling):
///  - `didBecomeActiveNotification`  (app enters foreground) → `handleForeground`.
///  - `didEnterBackgroundNotification` (app enters background) → `handleBackground`
///     (which also stops the heartbeat + triggers a flush).
///  - `willTerminateNotification`    (process teardown)      → `handleDetached` (END).
///
/// On platforms without UIKit (or when UIKit is unavailable), this binder is inert;
/// the host may still drive the lifecycle manager manually.
final class AttriaxUIApplicationLifecycleBinder: AttriaxLifecycleBinder {
    private let lifecycleManager: AttriaxSessionLifecycleManager
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()

    init(lifecycleManager: AttriaxSessionLifecycleManager) {
        self.lifecycleManager = lifecycleManager
    }

    func bind() {
        #if canImport(UIKit)
        lock.lock(); defer { lock.unlock() }
        if !observers.isEmpty { return }
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.lifecycleManager.handleForeground()
            }
        )
        observers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.lifecycleManager.handleBackground()
            }
        )
        observers.append(
            center.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.lifecycleManager.handleDetached()
            }
        )
        #endif
    }

    func unbind() {
        lock.lock(); defer { lock.unlock() }
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }
}

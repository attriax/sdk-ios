import Foundation
import AttriaxCore

/// The Attriax native iOS SDK — a THIN Swift facade over the KMP `AttriaxCore`
/// engine (`AttriaxCore.Attriax`, built via `AttriaxApple`).
///
/// The public surface is unchanged (so downstream
/// integrators are not broken); every call forwards to the KMP core, and value
/// objects are mapped by `AttriaxBridge`. Construct via `AttriaxSdk.create` and call
/// `initialize()` to bootstrap.
public final class Attriax {
    /// The underlying KMP engine. Sub-surfaces are handed the same instance.
    let core: AttriaxCore.Attriax

    init(core: AttriaxCore.Attriax) {
        self.core = core
    }

    /// Public tracking / revenue / identify surface.
    public private(set) lazy var tracking = AttriaxTracking(core: core)

    /// Public GDPR consent surface.
    public private(set) lazy var consent = AttriaxConsent(core: core)

    /// Public deep-link surface.
    public private(set) lazy var deepLinks = AttriaxDeepLinks(core: core)

    /// Public App Tracking Transparency surface.
    public private(set) lazy var att = AttriaxAtt(core: core)

    /// Public SKAdNetwork surface.
    public private(set) lazy var skan = AttriaxSkan(core: core)

    // MARK: - lifecycle

    /// Bootstrap the SDK (resolves identity, restores/starts the session, sends the
    /// app-open). Safe to call once; idempotent thereafter.
    public func initialize() {
        core.doInit()
    }

    /// Best-effort flush of any queued requests.
    public func flush() {
        core.flush()
    }

    /// Clear local device state and return the SDK to pre-init.
    public func reset() {
        core.reset()
    }

    /// Tear down the SDK, stopping timers and releasing the engine.
    public func dispose() {
        core.dispose()
    }

    // MARK: - state

    public var isInitialized: Bool { core.isInitialized }
    public var isFirstLaunch: Bool { core.isFirstLaunch }
    public var deviceId: String? { core.deviceId }

    public var enabled: Bool {
        get { core.enabled }
        set { core.enabled = newValue }
    }

    public var anonymousTrackingEnabled: Bool {
        get { core.anonymousTrackingEnabled }
        set { core.anonymousTrackingEnabled = newValue }
    }

    /// The current session snapshot, or nil before init / when session tracking is off.
    public var currentSession: AttriaxSessionSnapshot? { core.currentSession }

    // MARK: - receipt validation

    /// Validate a purchase receipt against the Attriax backend (bypasses the event
    /// queue). Performs blocking I/O — call off the main thread. Returns the decoded
    /// validation result as a map.
    @discardableResult
    public func validateReceipt(
        _ receipt: String,
        test: Bool = false,
        provider: String? = nil,
        environment: String? = nil,
        productId: String? = nil,
        transactionId: String? = nil
    ) throws -> Any? {
        let result = core.validateReceipt(
            receipt: receipt,
            test: test,
            provider: provider,
            environment: environment,
            productId: productId,
            transactionId: transactionId
        )
        return AttriaxBridge.receiptResultDict(from: result)
    }
}

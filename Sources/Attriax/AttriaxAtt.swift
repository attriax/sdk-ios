import Foundation
import AttriaxCore

/// App Tracking Transparency (ATT) status.
///
/// Maps to the exact wire strings the api `SdkV1OpenDto.attStatus` field consumes
/// (`authorized|denied|restricted|notDetermined|unknown`).
public enum AttriaxAttStatus: String, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unknown

    /// The wire value sent as `attStatus` on the open body.
    public var wireValue: String { rawValue }
}

/// Public ATT surface (`attriax.att`). Read the current status and OPT-IN prompt the
/// user for tracking authorization. Forwards to the KMP core's `consent.att`.
///
/// The SDK NEVER auto-prompts — Apple requires the host to decide when the ATT prompt
/// appears. Reading `status` is always safe and never prompts.
public final class AttriaxAtt {
    private let core: AttriaxCore.Attriax

    init(core: AttriaxCore.Attriax) {
        self.core = core
    }

    /// The current ATT authorization status (never prompts).
    public var status: AttriaxAttStatus {
        AttriaxBridge.attStatus(from: core.consent.att.status)
    }

    /// Opt-in ATT prompt. The host decides WHEN to call this. The completion is
    /// delivered with the resolved status; on pre-iOS-14 / unavailable framework it
    /// resolves to `.unknown`. Safe to call from any thread — the underlying KMP call
    /// blocks, so it is dispatched off the caller's thread and the completion fires on
    /// a background queue.
    public func requestTrackingAuthorization(completion: ((AttriaxAttStatus) -> Void)? = nil) {
        let core = self.core
        DispatchQueue.global(qos: .userInitiated).async {
            let status = core.consent.att.requestAuthorization(timeoutMs: nil)
            completion?(AttriaxBridge.attStatus(from: status))
        }
    }
}

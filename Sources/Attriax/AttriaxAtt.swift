import Foundation

/// App Tracking Transparency (ATT) status (PARITY §11; Epic 8.5 / CHUNK C).
///
/// Maps `ATTrackingManager.AuthorizationStatus` to the exact wire strings the api
/// `SdkV1OpenDto.attStatus` field consumes (`authorized|denied|restricted|
/// notDetermined|unknown`). Sent TOP-LEVEL on the app-open body (mirrors
/// `attestation`), NOT nested under `device`.
///
/// `.unknown` covers the pre-iOS-14 / framework-unavailable case where ATT is not a
/// meaningful concept — the SDK still sends a status so the ATT-gated matcher can
/// distinguish "no ATT" from an explicit determination.
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
/// user for tracking authorization.
///
/// The SDK NEVER auto-prompts — Apple requires the host to decide when the ATT
/// prompt appears (it can only be shown once, and only while the app is active with
/// an `NSUserTrackingUsageDescription` in Info.plist). `requestTrackingAuthorization`
/// is the explicit opt-in the host calls at the appropriate moment; the resulting
/// status then gates the IDFA identity rung and is stamped on the NEXT app-open.
///
/// Reading `status` is always safe and never prompts. When the AppTrackingTransparency
/// framework or iOS 14 is unavailable, `status` is `.unknown` and
/// `requestTrackingAuthorization` completes immediately with `.unknown`.
public final class AttriaxAtt {
    private let reader: AttriaxAttStatusReader

    init(reader: AttriaxAttStatusReader) {
        self.reader = reader
    }

    /// The current ATT authorization status (never prompts).
    public var status: AttriaxAttStatus { reader.currentStatus() }

    /// Opt-in ATT prompt. The host decides WHEN to call this (Apple only allows the
    /// system dialog to appear once, foregrounded, with a usage description). The
    /// completion is delivered with the resolved status; on pre-iOS-14 / unavailable
    /// framework it completes immediately with `.unknown`. Safe to call from any
    /// thread; the completion is invoked on the ATT framework's callback queue.
    public func requestTrackingAuthorization(completion: ((AttriaxAttStatus) -> Void)? = nil) {
        reader.requestAuthorization { status in
            completion?(status)
        }
    }
}

/// Internal ATT reader port. The pure engine reads the current status through this
/// seam (so `attStatus` stamping is testable off-device); the platform impl wraps
/// `ATTrackingManager`. A no-op reader returns `.unknown` and never prompts.
protocol AttriaxAttStatusReader: AnyObject {
    func currentStatus() -> AttriaxAttStatus
    func requestAuthorization(_ completion: @escaping (AttriaxAttStatus) -> Void)
}

/// A reader that always reports `.unknown` (used by the pure engine + on platforms
/// without AppTrackingTransparency).
final class AttriaxNoopAttStatusReader: AttriaxAttStatusReader {
    func currentStatus() -> AttriaxAttStatus { .unknown }
    func requestAuthorization(_ completion: @escaping (AttriaxAttStatus) -> Void) {
        completion(.unknown)
    }
}

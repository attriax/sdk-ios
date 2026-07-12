import Foundation
import AttriaxCore

/// App Attest attestation provider (PARITY §9, slug `app_attest`; Epic 9.3 CHUNK C).
///
/// Re-wrapped onto the KMP core: the real `DCAppAttestService` flow now lives in the
/// `AttriaxCore` framework (`AttriaxCore.AttriaxAppAttestProvider`). This type is a
/// thin public wrapper that (a) preserves the `AppAttestAttestationProvider` name in
/// the public API and (b) conforms to this module's `AttriaxAttestationProvider`
/// protocol, while delegating `attest` to the KMP provider. The generated App Attest
/// key id is persisted in a suite-scoped `UserDefaults` (as before).
///
/// INERT unless the integration constructs it and passes it to
/// `AttriaxConfig.attestationProvider` with `attestationEnabled == true`. Real
/// attestation is DEVICE-only (the Simulator reports `isSupported == false`), so the
/// KMP provider degrades to nil there — attestation never breaks init.
public final class AppAttestAttestationProvider: AttriaxAttestationProvider {
    /// The suite the generated App Attest key id is persisted under.
    private static let defaultsSuiteName = "com.attriax.sdk.prefs"

    /// The underlying KMP provider. The config builder passes this straight to the
    /// KMP core (avoiding a redundant Swift→KMP adapter hop).
    let kmpProvider: AttriaxCore.AttriaxAppAttestProvider

    public init() {
        let defaults = UserDefaults(suiteName: Self.defaultsSuiteName) ?? .standard
        self.kmpProvider = AttriaxCore.AttriaxAppAttestProvider(defaults: defaults)
    }

    public func attest(nonce: String) -> AttriaxAttestationToken? {
        guard let token = kmpProvider.attest(nonce: nonce) else { return nil }
        return AttriaxAttestationToken(token: token.token, keyId: token.keyId)
    }
}

/// App Attest provider factory. Historically this guarded the iOS-14+ availability of
/// `DCAppAttestService`; the KMP core now handles availability internally (degrading
/// to nil on unsupported OS/hardware), so this simply returns the wrapper.
public enum AttriaxAppAttest {
    /// A best-effort App Attest provider for the current OS. On a device without App
    /// Attest support the underlying provider yields nil (no envelope, init unaffected).
    public static func provider() -> AttriaxAttestationProvider {
        AppAttestAttestationProvider()
    }
}

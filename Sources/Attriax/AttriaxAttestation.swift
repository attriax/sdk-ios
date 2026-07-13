import Foundation

/// Public device-attestation seam.
///
/// Direct port of the Android reference `AttriaxAttestation.kt`, with the Apple
/// provider being **App Attest** (`DCAppAttestService`) rather than Play Integrity:
///  - the provider slugs the server accepts (`AttriaxAttestationProviderSlug`),
///  - the `AttriaxAttestationProvider` object seam the integration supplies,
///  - the `AttriaxAttestationToken` a provider returns (App Attest also carries a
///    `keyId`),
///  - the shipped `NoopAttestationProvider` default (always nil → no attestation).
///
/// The whole flow is INERT unless `AttriaxConfig.attestationEnabled` is `true` AND a
/// real provider is supplied via `AttriaxConfig.attestationProvider`; a nil provider
/// degrades to the noop and no envelope is ever attached. Attestation must NEVER
/// break init — a disabled config, an unsupported device, a failed challenge, a nil
/// provider result, or ANY thrown error all resolve to "no envelope, open still
/// sent" (mirrors the server's never-break-the-install invariant).

/// Canonical Attriax device-attestation provider slugs (server contract).
///
/// The server treats any other/absent value as `attestation_missing`, so the SDK
/// only ever emits these two slugs. Apple platforms produce `appAttest`; `playIntegrity`
/// is Android-only and present here purely for symmetry with the server DTO.
public enum AttriaxAttestationProviderSlug {
    /// Apple App Attest attestation.
    public static let appAttest = "app_attest"

    /// Android Play Integrity attestation (Android-only; here for server symmetry).
    public static let playIntegrity = "play_integrity"
}

/// The token a native attestation provider produces for a server-issued nonce.
///
/// `keyId` is App-Attest-only (it identifies the attested key pair the server must
/// look up to verify the assertion); the envelope omits it entirely when nil (the
/// server DTO makes every sub-field optional and rejects unknown properties). The
/// provider slug is not carried here — the `AttriaxAttestationManager` stamps
/// `app_attest` and the SDK-issued `nonce` when it assembles the envelope, so a
/// provider only ever returns the opaque OS `token` (plus a `keyId` on Apple).
public struct AttriaxAttestationToken: Equatable {
    /// The OS attestation token/blob obtained from the native provider (base64 on
    /// Apple — the App Attest attestation/assertion object, base64-encoded).
    public let token: String
    /// App Attest key id (the `keyId` returned by `generateKey`).
    public let keyId: String?

    public init(token: String, keyId: String? = nil) {
        self.token = token
        self.keyId = keyId
    }
}

/// Produces an `AttriaxAttestationToken` for a server-issued `nonce`.
///
/// Implementations acquire a platform attestation token (App Attest on Apple) that
/// binds the `nonce`, then return it.
///
/// Returning nil is a first-class, expected outcome: it means attestation is
/// unavailable on this device (unsupported hardware, a simulator, an OS error, a
/// stub build). The SDK then sends the app-open/init request with NO envelope. A
/// well-behaved provider degrades to nil rather than throwing — but the
/// `AttriaxAttestationManager` catches any thrown error defensively regardless
/// (attestation must never break init).
///
/// `attest` performs blocking I/O (App Attest is a keychain + secure-enclave +
/// network round-trip) and is invoked off the main thread by the SDK's init
/// bootstrap.
public protocol AttriaxAttestationProvider {
    /// Attempts to attest against `nonce`. Returns nil when unavailable.
    func attest(nonce: String) -> AttriaxAttestationToken?
}

/// The shipped default provider: always returns nil (no attestation).
///
/// This is what an SDK instance uses unless the integration explicitly opts in
/// (`AttriaxConfig.attestationEnabled == true`) and supplies a real provider,
/// guaranteeing that attestation is inert by default.
public struct NoopAttestationProvider: AttriaxAttestationProvider {
    public init() {}
    public func attest(nonce: String) -> AttriaxAttestationToken? { nil }
}

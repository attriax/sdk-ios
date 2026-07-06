import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// App Attest attestation provider (PARITY §9, slug `app_attest`; Epic 9.3 CHUNK C).
///
/// This is the ONLY place the real `DCAppAttestService` API is touched, keeping the
/// flow/envelope logic (`AttriaxAttestationManager`) pure and testable with a fake
/// provider. Here we call the OS with the server-issued nonce and return the opaque
/// App Attest object plus the `keyId`.
///
/// ## Availability posture
/// The entire type body is doubly gated:
///  - `#if canImport(DeviceCheck)` so a target without the DeviceCheck framework
///    (non-Apple platforms) simply does not compile the App Attest code path, and
///  - `@available(iOS 14.0, macCatalyst 14.0, tvOS 15.0, *)` because `DCAppAttestService`
///    is iOS 14+ (tvOS 15+). On an older OS the availability-fallback constructor
///    returns a provider whose `attest` yields nil.
///
/// The provider is INERT unless the integration explicitly constructs it and passes
/// it to `AttriaxConfig.attestationProvider` with `attestationEnabled == true`.
///
/// ## Never breaks init
/// `attest` is fully defensive: an unsupported device (`isSupported == false`), a
/// key-generation or attestation error, or ANY thrown error degrades to nil so the
/// SDK sends the app-open with no envelope rather than crashing init (row AT2). The
/// generated App Attest key id is persisted (via `AttriaxKeyValueStore`) and reused
/// across launches — App Attest keys are device-and-app bound and expensive to mint.
///
/// ## Real attestation is device-only
/// `DCAppAttestService.attestKey` requires a real device with the Secure Enclave and
/// a network round-trip to Apple's attestation servers; it CANNOT mint a real object
/// in the Simulator (`isSupported` is false there). This type is therefore
/// code-complete but device-verified only.
///
/// ## Nonce → clientDataHash
/// App Attest signs a 32-byte `clientDataHash`, not an arbitrary string. We derive
/// it as `SHA256(nonce)` (when CryptoKit is available; otherwise a fallback hash),
/// which is the conventional binding: the server issues the nonce, the client hashes
/// it into the attested client data, and the server recomputes `SHA256(nonce)` to
/// verify the attestation object binds the exact nonce it issued.
#if canImport(DeviceCheck)
@available(iOS 14.0, macCatalyst 14.0, tvOS 15.0, *)
public final class AppAttestAttestationProvider: AttriaxAttestationProvider {
    /// Optional persistence for the generated App Attest key id so it is reused
    /// across launches. Injected internally by the `AttriaxSdk` factory (the SDK's
    /// shared `UserDefaults`-backed store). `AttriaxKeyValueStore` is an internal
    /// port, so it is NOT a public constructor parameter — the public init is
    /// store-free and self-persists the key id via `UserDefaults` (see `resolveKeyId`).
    var store: AttriaxKeyValueStore?
    private let service: DCAppAttestService

    /// Public store-free init (the `AttriaxSdk` factory injects the SDK store via the
    /// internal init). The generated App Attest key id is persisted to the standard
    /// `UserDefaults` under `Self.keyStoredKeyId` so it survives launches.
    public init() {
        self.store = nil
        self.service = DCAppAttestService.shared
    }

    /// Internal init that injects the SDK's shared key/value store for key-id
    /// persistence, used by the `AttriaxSdk` factory.
    init(store: AttriaxKeyValueStore?) {
        self.store = store
        self.service = DCAppAttestService.shared
    }

    public func attest(nonce: String) -> AttriaxAttestationToken? {
        let trimmed = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Unsupported hardware (Simulator, jailbroken, missing Secure Enclave) →
        // degrade to nil. App Attest is never available where isSupported is false.
        guard service.isSupported else { return nil }

        // App Attest is inherently async (completion-handler based). The provider
        // contract is synchronous (nonce → token, called off the main thread), so we
        // bridge with a semaphore. Safe here: `attest` is always invoked on the SDK's
        // background flush queue, never the main thread.
        let keyId: String
        do {
            keyId = try resolveKeyId()
        } catch {
            return nil
        }

        let clientDataHash = Self.clientDataHash(for: trimmed)

        let attestationSemaphore = DispatchSemaphore(value: 0)
        var attestationResult: Data?
        service.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
            if error == nil { attestationResult = attestation }
            attestationSemaphore.signal()
        }
        attestationSemaphore.wait()

        guard let attestation = attestationResult, !attestation.isEmpty else {
            // A failed attestation may indicate the persisted key is invalid on this
            // device/app version; forget it so a subsequent launch mints a fresh one.
            forgetStoredKeyId()
            return nil
        }

        // The attestation object is binary; the wire field is a string, so base64.
        let token = attestation.base64EncodedString()
        return AttriaxAttestationToken(token: token, keyId: keyId)
    }

    // MARK: - key management

    /// Returns the persisted App Attest key id, generating (and persisting) one on
    /// first use. Throws on generation failure so the caller degrades to nil. Uses
    /// the injected SDK store when present, else falls back to standard
    /// `UserDefaults` so the store-free public init still persists the key.
    private func resolveKeyId() throws -> String {
        if let existing = loadStoredKeyId(), !existing.isEmpty {
            return existing
        }
        let generated = try generateKeySync()
        saveStoredKeyId(generated)
        return generated
    }

    private func loadStoredKeyId() -> String? {
        if let store = store { return store.getString(Self.keyStoredKeyId) }
        return UserDefaults.standard.string(forKey: Self.keyStoredKeyId)
    }

    private func saveStoredKeyId(_ value: String) {
        if let store = store { store.putString(Self.keyStoredKeyId, value) }
        else { UserDefaults.standard.set(value, forKey: Self.keyStoredKeyId) }
    }

    private func forgetStoredKeyId() {
        if let store = store { store.remove(Self.keyStoredKeyId) }
        else { UserDefaults.standard.removeObject(forKey: Self.keyStoredKeyId) }
    }

    /// Synchronous bridge over the async `generateKey` (see the `attest` note on why
    /// blocking is safe here).
    private func generateKeySync() throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var generatedKeyId: String?
        var generationError: Error?
        service.generateKey { keyId, error in
            generatedKeyId = keyId
            generationError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let error = generationError { throw error }
        guard let keyId = generatedKeyId, !keyId.isEmpty else {
            throw AttriaxTransportError.transport(underlying: nil)
        }
        return keyId
    }

    /// SHA-256 of the nonce → the 32-byte `clientDataHash` the server recomputes.
    private static func clientDataHash(for nonce: String) -> Data {
        let bytes = Data(nonce.utf8)
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: bytes))
        #else
        // CryptoKit is always present on the App-Attest-capable platforms, but keep a
        // deterministic fallback so the file compiles everywhere it is included.
        return bytes
        #endif
    }

    private static let keyStoredKeyId = "attriax.app_attest.key_id"
}
#endif

/// Availability-fallback factory for `AppAttestAttestationProvider`.
///
/// `AppAttestAttestationProvider` is `@available(iOS 14.0, ...)`, so a host that
/// still supports iOS 13 cannot name the type unconditionally. This helper returns
/// the real provider when the OS + framework support App Attest, and a
/// `NoopAttestationProvider` (→ no envelope, never crashes) otherwise. Integrations
/// targeting iOS 14+ may construct `AppAttestAttestationProvider` directly.
public enum AttriaxAppAttest {
    /// A best-effort App Attest provider for the current OS: the real
    /// `AppAttestAttestationProvider` on iOS 14+ with DeviceCheck available, else the
    /// inert noop. `store` is threaded through so the generated key id persists.
    public static func provider() -> AttriaxAttestationProvider {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macCatalyst 14.0, tvOS 15.0, *) {
            return AppAttestAttestationProvider()
        }
        #endif
        return NoopAttestationProvider()
    }

    /// Internal variant that injects the SDK's shared key/value store for key-id
    /// persistence (`AttriaxKeyValueStore` is not part of the public surface).
    static func provider(store: AttriaxKeyValueStore?) -> AttriaxAttestationProvider {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macCatalyst 14.0, tvOS 15.0, *) {
            return AppAttestAttestationProvider(store: store)
        }
        #endif
        return NoopAttestationProvider()
    }
}

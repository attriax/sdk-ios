import Foundation

/// The single-use challenge issued by `POST /api/sdk/attestation/challenge`
/// (PARITY §8/§9). Wire shape mirrors the api `AttestationChallengeResponseDto`:
/// `{ nonce, expiresInSeconds }` (only `nonce` is load-bearing; the SDK does not
/// currently act on the TTL beyond carrying it).
struct AttriaxAttestationChallenge: Equatable {
    let nonce: String
    let expiresInSeconds: Int?

    init(nonce: String, expiresInSeconds: Int? = nil) {
        self.nonce = nonce
        self.expiresInSeconds = expiresInSeconds
    }
}

/// Fetches a single-use attestation nonce from `POST /api/sdk/attestation/challenge`
/// (PARITY §8/§9). Pure over the `AttriaxHttpClient` port so the attestation flow is
/// fully testable with a fake transport.
///
/// Mirrors the Android `AttriaxAttestationChallengeFetcher`: any non-success status,
/// a missing body, or a missing/blank `nonce` yields nil (→ the SDK sends the open
/// with no envelope). Network-level exceptions from the transport are NOT swallowed
/// here — the `AttriaxAttestationManager` catches them, treating a challenge outage
/// as "no nonce" so it can never break init.
///
/// The challenge body carries no request fields (the api endpoint is `@Public()` and
/// takes no payload), so an empty JSON object is posted.
struct AttriaxAttestationChallengeFetcher {
    private let transport: AttriaxHttpClient

    init(transport: AttriaxHttpClient) {
        self.transport = transport
    }

    func fetch() throws -> AttriaxAttestationChallenge? {
        let response = try transport.post(AttriaxEndpoints.attestationChallenge, "{}")
        guard let body = response.body else { return nil }

        let decoded = try? AttriaxJson.decode(body)
        guard let map = decoded as? [String: Any?] else { return nil }

        guard let rawNonce = map["nonce"].flatMap({ $0 }) as? String else { return nil }
        let nonce = rawNonce.trimmingCharacters(in: .whitespacesAndNewlines)
        if nonce.isEmpty { return nil }

        let expiresInSeconds: Int?
        switch map["expiresInSeconds"].flatMap({ $0 }) {
        case let v as Int: expiresInSeconds = v
        case let v as Int64: expiresInSeconds = Int(v)
        case let v as Double: expiresInSeconds = Int(v)
        case let v as NSNumber: expiresInSeconds = v.intValue
        default: expiresInSeconds = nil
        }
        return AttriaxAttestationChallenge(nonce: nonce, expiresInSeconds: expiresInSeconds)
    }
}

/// Orchestrates the SDK-side device-attestation flow (PARITY §9, rows AT1/AT2).
///
/// Direct port of the Android `AttriaxAttestationManager`. Enabled only when
/// `AttriaxConfig.attestationEnabled` is `true`. When enabled, `resolveEnvelope()`
/// fetches a nonce from the challenge endpoint, asks the configured provider (App
/// Attest on Apple) to produce an attestation token, and returns the assembled
/// envelope map for attachment to the app-open request under `attestation`.
///
/// The whole flow is best-effort and defensive (row AT2 — critical): a disabled
/// config, a failed/nil challenge fetch, a nil provider result, an unsupported /
/// throwing provider, or ANY thrown error all resolve to nil, which means the open
/// is sent with NO envelope. Attestation must NEVER block or fail init — this
/// mirrors the server's "never break the install" invariant.
///
/// This type is PURE (no DeviceCheck / AppTrackingTransparency symbols): the
/// challenge fetch is a `() throws -> AttriaxAttestationChallenge?` seam and the
/// provider is the public protocol, so the flow is fully testable with fakes. The
/// real App Attest call lives behind the provider in the `Platform/` layer.
struct AttriaxAttestationManager {
    private let enabled: Bool
    private let provider: AttriaxAttestationProvider
    private let fetchChallenge: () throws -> AttriaxAttestationChallenge?

    init(
        enabled: Bool,
        provider: AttriaxAttestationProvider?,
        fetchChallenge: @escaping () throws -> AttriaxAttestationChallenge?
    ) {
        self.enabled = enabled
        self.provider = provider ?? NoopAttestationProvider()
        self.fetchChallenge = fetchChallenge
    }

    /// Whether attestation is opted in for this SDK instance.
    var isEnabled: Bool { enabled }

    /// Resolves the attestation envelope to attach to the app-open request.
    ///
    /// Returns nil (→ attach nothing) when attestation is disabled, the challenge
    /// could not be fetched, the provider returned nil, or any error occurred. Never
    /// throws.
    ///
    /// Performs blocking I/O (challenge fetch + provider attest) — call off the main
    /// thread. The SDK invokes it on its flush queue during init bootstrap.
    func resolveEnvelope() -> AttriaxJSONObject? {
        guard enabled else { return nil }

        do {
            guard let challenge = try fetchChallenge() else { return nil }
            let nonce = challenge.nonce.trimmingCharacters(in: .whitespacesAndNewlines)
            if nonce.isEmpty { return nil }

            guard let token = provider.attest(nonce: nonce) else { return nil }

            // The provider slug is stamped by the SDK (Apple → app_attest), not
            // returned by the provider; the nonce always comes from the SDK-issued
            // challenge so the server can match the single-use value it issued. keyId
            // is App-Attest-only and is included when the provider echoes it back.
            var envelope = AttriaxJSONObject()
            envelope["provider"] = AttriaxAttestationProviderSlug.appAttest
            envelope["token"] = token.token
            envelope["nonce"] = nonce
            if let keyId = token.keyId, !keyId.isEmpty { envelope["keyId"] = keyId }
            return envelope
        } catch {
            // Attestation is best-effort — never let it break init.
            return nil
        }
    }
}

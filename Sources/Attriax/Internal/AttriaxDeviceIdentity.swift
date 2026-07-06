import Foundation

/// Device-id source slugs (PARITY §2 / row D4), iOS variants.
enum AttriaxDeviceIdSource {
    static let iosIdfv = "ios_idfv"
    static let iosIdfa = "ios_idfa"
    static let persistentStorage = "persistent_storage"
}

/// A resolved device identity: the value plus the source slug it came from.
struct ResolvedDeviceId: Equatable {
    let value: String
    let source: String
    /// True when this is the generated persistent-storage fallback, not a native id.
    let isFallback: Bool

    init(value: String, source: String, isFallback: Bool = false) {
        self.value = value
        self.source = source
        self.isFallback = isFallback
    }
}

/// Resolves the preferred device id + source (PARITY §2, rows D1–D4), iOS branch.
///
/// Precedence (mirrors the Android SSAID→GAID→persistent shape, mapped to Apple):
///   1. `identifierForVendor` (IDFV) → source `ios_idfv`
///   2. IDFA (`advertisingIdentifier`) — ONLY when ATT-authorized AND collection
///      enabled → source `ios_idfa`
///   3. otherwise the persistent-storage fallback id → source `persistent_storage`
///
/// Empty strings are treated as absent. When `collectAdvertisingId == false`, the
/// IDFA candidate is never consulted. In CHUNK A the IDFA source seam always
/// returns nil (`AttriaxDeviceIdSources.advertisingId()` default) so resolution
/// yields IDFV or the persistent fallback; the full ATT/IDFA wiring is CHUNK C.
///
/// Pure: given an `AttriaxDeviceIdSources` seam and a fallback id, resolution is
/// deterministic and unit-testable with a fake sources object.
struct AttriaxDeviceIdentityResolver {
    private let sources: AttriaxDeviceIdSources
    private let collectAdvertisingId: Bool

    init(sources: AttriaxDeviceIdSources, collectAdvertisingId: Bool) {
        self.sources = sources
        self.collectAdvertisingId = collectAdvertisingId
    }

    /// - Parameter fallbackDeviceId: a stable, already-persisted (or freshly
    ///   generated) id used when no native source is available.
    func resolve(fallbackDeviceId: String) -> ResolvedDeviceId {
        if let idfv = emptyToNil(sources.idfv()) {
            return ResolvedDeviceId(value: idfv, source: AttriaxDeviceIdSource.iosIdfv)
        }

        if collectAdvertisingId, let idfa = emptyToNil(sources.advertisingId()) {
            return ResolvedDeviceId(value: idfa, source: AttriaxDeviceIdSource.iosIdfa)
        }

        return ResolvedDeviceId(
            value: fallbackDeviceId,
            source: AttriaxDeviceIdSource.persistentStorage,
            isFallback: true
        )
    }

    private func emptyToNil(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }
}

/// Persists the resolved device identity (PARITY §2, rows D1/D2/D4).
///
/// Keys `attriax.device_id` / `attriax.device_id_source`. The fallback id is
/// generated ONCE (16 secure-random bytes) and reused; both keys are cleared on
/// `clear()` (invoked by `reset()`). `loadOrCreate()` re-resolves the preferred
/// native source each launch (IDFV → IDFA → persistent fallback) but the generated
/// fallback id itself is stable.
final class AttriaxDeviceIdentityStore {
    static let keyDeviceId = "attriax.device_id"
    static let keyDeviceIdSource = "attriax.device_id_source"

    private let store: AttriaxKeyValueStore
    private let resolver: AttriaxDeviceIdentityResolver

    init(store: AttriaxKeyValueStore, resolver: AttriaxDeviceIdentityResolver) {
        self.store = store
        self.resolver = resolver
    }

    func loadOrCreate() -> ResolvedDeviceId {
        let fallbackId: String
        if let existing = store.getString(Self.keyDeviceId) {
            fallbackId = existing
        } else {
            fallbackId = AttriaxIdGenerator.generate()
            store.putString(Self.keyDeviceId, fallbackId)
        }
        let resolved = resolver.resolve(fallbackDeviceId: fallbackId)
        // Persist the currently-resolved source so it survives restarts and is
        // observable; the fallback id is already persisted above.
        store.putString(Self.keyDeviceIdSource, resolved.source)
        return resolved
    }

    func clear() {
        store.remove(Self.keyDeviceId)
        store.remove(Self.keyDeviceIdSource)
    }
}

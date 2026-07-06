import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Factory for the Attriax native iOS SDK (Epic 9.3 — standalone Swift core).
///
/// `create` assembles a fully-wired `Attriax` runtime: suite-scoped
/// `UserDefaults` persistence, the single long-lived `URLSession` transport
/// stamped with the mandatory real User-Agent (PARITY §8), `NWPathMonitor`
/// connectivity, and the device-identity resolver.
public enum AttriaxSdk {
    /// SDK release version (mirrors the Flutter/Android reference; PARITY row I3).
    public static let version = AttriaxVersion.packageVersion

    /// Build a runtime for `config`. Call `initialize()` afterwards to bootstrap.
    ///
    /// CHUNK C wires the real Apple frameworks (all inert/opt-in by config):
    ///  - the ATT status reader (`ATTrackingManager`) backs `attriax.att`,
    ///  - the IDFA supplier reads `ASIdentifierManager.advertisingIdentifier` ONLY
    ///    when ATT is `.authorized` AND `config.collectAdvertisingId` (source
    ///    `ios_idfa`), else resolution falls through to IDFV / persistent storage,
    ///  - App Attest / ASA / SKAN are driven from `config` + the public surfaces.
    ///
    /// - Parameter advertisingIdSupplier: optional OVERRIDE of the ATT-gated IDFA
    ///   supplier. When nil (the default), the SDK uses its own ATT-gated
    ///   `ASIdentifierManager` supplier; pass a closure only to inject a custom source.
    public static func create(
        config: AttriaxConfig,
        advertisingIdSupplier: (() -> String?)? = nil
    ) -> Attriax {
        let store = AttriaxUserDefaultsStore()

        let snapshot = captureContext(config)
        let userAgent = AttriaxUserAgent.format(
            osVersion: snapshot.osVersion,
            descriptor: snapshot.userAgentDescriptor()
        )

        let transport = AttriaxURLSessionClient(
            baseURL: config.apiBaseURL,
            userAgent: userAgent,
            requestTimeout: config.requestTimeout
        )

        // CHUNK C — ATT reader (drives att.status and gates the IDFA rung).
        let attReader = AttriaxAppTrackingTransparencyReader()

        // CHUNK C — the IDFA supplier: an explicit override wins; otherwise the SDK's
        // own ATT-gated ASIdentifierManager supplier (nil unless ATT-authorized AND
        // collection enabled). The chunk-A IDFA seam is now wired to a real source.
        let idfaSupplier: () -> String?
        if let override = advertisingIdSupplier {
            idfaSupplier = override
        } else {
            let attGated = AttriaxAttGatedAdvertisingIdSupplier(
                collectAdvertisingId: config.collectAdvertisingId,
                attStatus: { attReader.currentStatus() }
            )
            idfaSupplier = { attGated.advertisingId() }
        }

        let sources = AttriaxIOSDeviceIdSources(
            collectAdvertisingId: config.collectAdvertisingId,
            advertisingIdSupplier: idfaSupplier
        )
        let resolver = AttriaxDeviceIdentityResolver(sources: sources, collectAdvertisingId: config.collectAdvertisingId)
        let deviceIdentityStore = AttriaxDeviceIdentityStore(store: store, resolver: resolver)

        return Attriax(
            config: injectAttestationStore(config, store: store),
            store: store,
            transport: transport,
            connectivity: AttriaxNWPathConnectivityMonitor(),
            context: snapshot,
            deviceIdentityStore: deviceIdentityStore,
            // Session heartbeat timer runs off the main thread (PARITY §3, row S3).
            scheduler: AttriaxTimerScheduler(),
            // Foreground/background/terminate detection via UIApplication notifications.
            lifecycleBinderFactory: { manager in
                AttriaxUIApplicationLifecycleBinder(lifecycleManager: manager)
            },
            // CHUNK C — real ATT reader behind att.status / the IDFA gate.
            attStatusReader: attReader
        )
    }

    /// Inject the SDK's shared key/value store into an `AppAttestAttestationProvider`
    /// created via the public store-free init, so the generated App Attest key id is
    /// persisted in the SDK's `UserDefaults` suite rather than the standard defaults.
    /// A custom (non-App-Attest) provider is returned untouched.
    private static func injectAttestationStore(_ config: AttriaxConfig, store: AttriaxKeyValueStore) -> AttriaxConfig {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macCatalyst 14.0, tvOS 15.0, *),
           let provider = config.attestationProvider as? AppAttestAttestationProvider,
           provider.store == nil {
            provider.store = store
        }
        #endif
        return config
    }

    private static func captureContext(_ config: AttriaxConfig) -> AttriaxContextSnapshot {
        let bundle = Bundle.main
        let packageName = config.appPackageName ?? bundle.bundleIdentifier
        let appVersion = config.appVersion
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let appBuildNumber = config.appBuildNumber
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)

        #if canImport(UIKit)
        let device = UIDevice.current
        let osVersion = device.systemVersion
        let deviceModel = device.model
        #else
        let osVersion = "unknown"
        let deviceModel: String? = nil
        #endif

        return AttriaxContextSnapshot(
            packageName: packageName,
            appVersion: appVersion,
            appBuildNumber: appBuildNumber,
            deviceModel: deviceModel,
            deviceManufacturer: "Apple",
            osVersion: osVersion,
            deviceTimezone: TimeZone.current.identifier,
            deviceLocale: Locale.current.identifier
        )
    }
}

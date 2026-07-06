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
    /// - Parameter advertisingIdSupplier: optional supplier of the ATT-authorized
    ///   IDFA. When absent, resolution falls through to `identifierForVendor`
    ///   (source `ios_idfv`) or the persistent-storage device id. The ATT prompt +
    ///   AdSupport wiring is CHUNK C.
    public static func create(
        config: AttriaxConfig,
        advertisingIdSupplier: @escaping () -> String? = { nil }
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

        let sources = AttriaxIOSDeviceIdSources(
            collectAdvertisingId: config.collectAdvertisingId,
            advertisingIdSupplier: advertisingIdSupplier
        )
        let resolver = AttriaxDeviceIdentityResolver(sources: sources, collectAdvertisingId: config.collectAdvertisingId)
        let deviceIdentityStore = AttriaxDeviceIdentityStore(store: store, resolver: resolver)

        return Attriax(
            config: config,
            store: store,
            transport: transport,
            connectivity: AttriaxNWPathConnectivityMonitor(),
            context: snapshot,
            deviceIdentityStore: deviceIdentityStore
        )
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

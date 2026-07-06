import Foundation

/// App/device/sdk/platform context captured once at init and stamped on
/// open/session/crash payloads (PARITY §1 step 3, §3).
///
/// Pure value type — the platform layer populates it from `UIDevice`/`Bundle`
/// and passes it in, so request building stays unit-testable off-device.
struct AttriaxContextSnapshot {
    // App
    let packageName: String?
    let appVersion: String?
    let appBuildNumber: String?
    // Device
    let deviceModel: String?
    let deviceManufacturer: String?
    let osVersion: String
    let deviceTimezone: String?
    let deviceLocale: String?
    // Platform / SDK
    let platform: String
    let sdkApiVersion: String
    let sdkPackageVersion: String

    init(
        packageName: String?,
        appVersion: String?,
        appBuildNumber: String?,
        deviceModel: String?,
        deviceManufacturer: String?,
        osVersion: String,
        deviceTimezone: String?,
        deviceLocale: String?,
        platform: String = "ios",
        sdkApiVersion: String = AttriaxVersion.apiVersion,
        sdkPackageVersion: String = AttriaxVersion.packageVersion
    ) {
        self.packageName = packageName
        self.appVersion = appVersion
        self.appBuildNumber = appBuildNumber
        self.deviceModel = deviceModel
        self.deviceManufacturer = deviceManufacturer
        self.osVersion = osVersion
        self.deviceTimezone = deviceTimezone
        self.deviceLocale = deviceLocale
        self.platform = platform
        self.sdkApiVersion = sdkApiVersion
        self.sdkPackageVersion = sdkPackageVersion
    }

    /// UA descriptor: bundle id preferred, else device model, else "unknown".
    func userAgentDescriptor() -> String {
        if let pkg = packageName, !pkg.isEmpty { return pkg }
        if let model = deviceModel, !model.isEmpty { return model }
        return "unknown"
    }
}

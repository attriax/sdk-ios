import Foundation

/// SDK version constants.
///
/// Mirrors the Flutter/Android reference:
///   attriaxSdkApiVersion = "v1"
///   attriaxSdkPackageVersion = "0.5.0"
///
/// Shipped on session/crash payloads as `sdkApiVersion` / `sdkPackageVersion`
/// and load-bearing for the wire User-Agent (see `AttriaxUserAgent`).
public enum AttriaxVersion {
    /// Wire API version segment (`/api/sdk/v1/...`).
    public static let apiVersion = "v1"

    /// SDK package/release version. Kept in lockstep with the Flutter reference.
    public static let packageVersion = "0.5.0"
}

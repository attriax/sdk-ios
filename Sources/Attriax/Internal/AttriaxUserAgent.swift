import Foundation

/// Builds the mandatory, load-bearing SDK User-Agent (PARITY §8 / row W2).
///
/// The backend runs `isbot` over the UA. The OpenAPI-Generator default — and
/// even the bare `attriax-ios-sdk/x` form WITHOUT the parenthetical suffix —
/// trips the bot filter, silently hiding SDK traffic. The UA is ALSO an
/// anonymous-identity key (`sha256(appId, ip, userAgent, dailySalt)`), so it
/// must be stable per install or a drifting UA mints multiple anonymous users
/// per device.
///
/// Shape:  `attriax-ios-sdk/<ver> (iOS <osVersion>; <bundleId>)`
///
/// Pure — the caller supplies `osVersion` and `descriptor` (bundle id preferred,
/// else device model) so this is unit-testable off-device.
enum AttriaxUserAgent {
    static func format(
        osVersion: String,
        descriptor: String,
        packageVersion: String = AttriaxVersion.packageVersion
    ) -> String {
        let os = osVersion.isEmpty ? "unknown" : osVersion
        let desc = descriptor.isEmpty ? "unknown" : descriptor
        return "attriax-ios-sdk/\(packageVersion) (iOS \(os); \(desc))"
    }
}

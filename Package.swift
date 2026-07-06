// swift-tools-version:5.7
import PackageDescription

// Attriax native iOS SDK (Epic 9.3).
//
// Foundation-only — NO external dependencies. The library links UIKit for
// `UIDevice.identifierForVendor` and the CHUNK-C Apple platform frameworks —
// AppTrackingTransparency (ATT), AdSupport (IDFA), AdServices (Apple Search Ads),
// StoreKit (SKAdNetwork), DeviceCheck (App Attest) — each imported behind
// `#if canImport(...)` and used behind `@available(...)`. SwiftPM auto-links these
// system frameworks on import; they are NOT SwiftPM deps. The base config (all
// CHUNK-C features OFF) references none of their symbols at runtime, and the min
// deployment target stays iOS 13 (the 14+/14.3+/16.1+ APIs are availability-gated).
//
// Publish coordinates mirror the Android core decision: per-platform native
// core, standalone Swift (no shared cross-platform core), manual/local publish,
// no CI.
let package = Package(
    name: "Attriax",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(
            name: "Attriax",
            targets: ["Attriax"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Attriax",
            dependencies: [],
            path: "Sources/Attriax"
        ),
        // No test target yet — the user compiles + writes tests on the Mac
        // (this chunk ships code-complete-UNVERIFIED). Add a `.testTarget`
        // pointing at `Tests/AttriaxTests` when tests are authored.
    ]
)

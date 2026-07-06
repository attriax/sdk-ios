// swift-tools-version:5.7
import PackageDescription

// Attriax native iOS SDK (Epic 9.3).
//
// Foundation-only — NO external dependencies. The library links UIKit for
// `UIDevice.identifierForVendor` and AdSupport/AppTrackingTransparency for the
// (chunk-C) IDFA/ATT seam; those are weak platform frameworks, not SwiftPM deps.
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

// swift-tools-version:5.7
import PackageDescription

// Attriax native iOS SDK (re-wrapped onto the shared KMP core).
//
// The engine no longer lives here: it was extracted into the Kotlin Multiplatform
// core (`sdk-kmp`) and ships as the `AttriaxCore` XCFramework (a STATIC framework
// with device arm64 + simulator arm64/x64 + macOS slices). `sdk-ios` is now a THIN
// Swift facade over that framework — it preserves the public `com.attriax`-style
// Swift API (so downstream integrators are unchanged) while forwarding to the KMP
// Obj-C surface (`AttriaxApple` / `AttriaxCore.Attriax`). This mirrors the Android
// AAR re-export and the Flutter/Unity re-wraps.
//
// The `AttriaxCore.xcframework` binary is VENDORED (git-ignored — a reproducible
// build artifact of `sdk-kmp`, see .gitignore) and consumed via a `.binaryTarget`.
// The system frameworks the STATIC KMP core references (ATT/IDFA, ASA via AdServices,
// App Attest via DeviceCheck, SKAN via StoreKit, the real WKWebView UA via WebKit,
// networking via Network/SystemConfiguration, the CSPRNG via Security) are linked
// here — they ship with the OS, so no third-party dependency is introduced. This
// matches `attriax_flutter_ios.podspec`.
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
        // The KMP core, consumed as a remote binary XCFramework from the GitHub
        // Release. For local dev against an unreleased core, swap this back to
        // `path: "Frameworks/AttriaxCore.xcframework"` after running
        // scripts/build-xcframework.sh.
        .binaryTarget(
            name: "AttriaxCore",
            url: "https://github.com/attriax/sdk-ios/releases/download/0.6.0/AttriaxCore.xcframework.zip",
            checksum: "7508371ac2da86e31b78042f46226d943d3f3f3a590dc4e1636db53460308bd5"
        ),
        .target(
            name: "Attriax",
            dependencies: ["AttriaxCore"],
            path: "Sources/Attriax",
            linkerSettings: [
                .linkedFramework("AdSupport"),
                .linkedFramework("AppTrackingTransparency"),
                .linkedFramework("AdServices"),
                .linkedFramework("DeviceCheck"),
                .linkedFramework("StoreKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("SafariServices"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
            ]
        ),
        // No test target yet — the KMP core owns the engine unit-test coverage.
        // Public-API-vs-framework smoke
        // lives in the example / host integration.
    ]
)

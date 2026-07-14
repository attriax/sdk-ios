# Publishing the Attriax iOS SDK (manual / local — no CI)

`sdk-ios` is a **thin Swift facade** over the shared Kotlin Multiplatform core
(`sdk-kmp`), which ships to this package as the **`AttriaxCore` static XCFramework**
(see `README.md` / `PARITY` notes). Publishing the iOS SDK means distributing this
Swift facade **plus** that vendored framework to consumers.

Distribution is **manual and local** — there is intentionally **no CI/CD**. You run the
scripts and the publish commands from a Mac.

## Distribution: Swift Package Manager only

The Attriax iOS SDK is distributed via **Swift Package Manager only**. Consumers add the
package by Git URL and SwiftPM resolves a binary `AttriaxCore.xcframework` from a
**GitHub Release asset** via a remote `.binaryTarget(url:checksum:)`. GitHub itself is
the registry — there is nothing else to register; the repo must be **public**.

There is **no CocoaPods distribution** — no standalone `Attriax` podspec, no CocoaPods
Trunk. (The Flutter iOS plugin has its own separate, path-sourced pod in the
`sdk-flutter` repo; that is unrelated to distributing this SDK — see the clarification
at the end.)

### Today's state

`Package.swift` currently uses a **LOCAL path** binaryTarget
(`path: "Frameworks/AttriaxCore.xcframework"`) — that is for **local dev/testing only**
(the framework is a git-ignored build artifact). **Nothing is published to external
consumers yet.** The release flow below swaps that local path for the remote
url/checksum stanza.

## Prerequisites

- A **Mac with Xcode + command-line tools** (the Swift toolchain and the Kotlin/Native
  Apple targets that emit the XCFramework only build on macOS).
- **SwiftPM:** nothing to register — GitHub is the registry. The
  `github.com/attriax/sdk-ios` repo must be **public** for SwiftPM consumers to resolve
  it.

## Build the framework

The release starts from a freshly built, vendored XCFramework:

```bash
scripts/build-xcframework.sh
# -> builds sdk-kmp's :core:assembleAttriaxCoreReleaseXCFramework and vendors it to
#    sdk-ios/Frameworks/AttriaxCore.xcframework
```

## Release flow (SwiftPM)

1. **Prepare the release asset** (build + zip + checksum):

   ```bash
   scripts/release-apple.sh 0.6.0
   ```

   It builds/vendors the framework, writes `Frameworks/AttriaxCore.xcframework.zip`,
   runs `swift package compute-checksum`, prints the sha256, and prints the exact
   `.binaryTarget(url:checksum:)` stanza. It does **not** create a Release or push
   anything unless you pass `--yes`.

2. **Create the GitHub Release + upload the zip.** Either the command the script prints
   (with the `gh` CLI):

   ```bash
   gh release create 0.6.0 Frameworks/AttriaxCore.xcframework.zip \
     --repo attriax/sdk-ios --title "Attriax iOS 0.6.0" \
     --notes "AttriaxCore XCFramework binary for SwiftPM 0.6.0."
   ```

   …or via the web UI at `https://github.com/attriax/sdk-ios/releases/new` (tag `0.6.0`,
   upload `AttriaxCore.xcframework.zip` as an asset). Re-running
   `release-apple.sh 0.6.0 --yes` does this step and step 4's tag/push automatically.

3. **Paste the remote binaryTarget stanza into `Package.swift`**, replacing the local
   `path:` binaryTarget:

   ```swift
   .binaryTarget(
       name: "AttriaxCore",
       url: "https://github.com/attriax/sdk-ios/releases/download/0.6.0/AttriaxCore.xcframework.zip",
       checksum: "<sha256 printed by release-apple.sh>"
   ),
   ```

4. **Commit, tag, push:**

   ```bash
   git add Package.swift && git commit -m "release: iOS SDK 0.6.0 (remote binaryTarget)"
   git tag 0.6.0 && git push origin 0.6.0
   ```

   SwiftPM versions come from Git tags — the tag must match the Release tag and the
   download URL's version segment.

## Consumer install

Xcode → *File ▸ Add Package Dependencies…* → `https://github.com/attriax/sdk-ios`
→ pick `0.6.0`. Or in a `Package.swift`:

```swift
.package(url: "https://github.com/attriax/sdk-ios.git", from: "0.6.0")
```

## Flutter iOS testing uses the local vendored framework — no publish needed

Testing the Flutter iOS plugin does **not** involve this SwiftPM release at all (and,
now that the standalone pod is gone, there is no pod to publish either).

The Flutter iOS plugin (`sdk-flutter/attriax_flutter_ios`) has its **own** Package.swift
and its own **path-sourced** pod (`attriax_flutter_ios.podspec`, `s.source = { :path => '.' }`)
that both vendor the framework from a **LOCAL path** relative to the plugin:

```
sdk-flutter/attriax_flutter_ios/ios/Frameworks/AttriaxCore.xcframework
```

(That `ios/Frameworks/` directory is git-ignored in the plugin too — a build artifact,
not source.) So to test Flutter on iOS locally you only need to:

1. **Build the XCFramework** with `scripts/build-xcframework.sh` (it lands at
   `sdk-ios/Frameworks/AttriaxCore.xcframework`), then **copy it to where the Flutter
   plugin expects it:**

   ```bash
   mkdir -p ../sdk-flutter/attriax_flutter_ios/ios/Frameworks
   rm -rf   ../sdk-flutter/attriax_flutter_ios/ios/Frameworks/AttriaxCore.xcframework
   cp -R Frameworks/AttriaxCore.xcframework \
         ../sdk-flutter/attriax_flutter_ios/ios/Frameworks/
   ```

   (Same reproducible gradle artifact — `sdk-kmp/core/build/XCFrameworks/release/AttriaxCore.xcframework`
   — vendored into a second consumer.)

2. **`pod install`** in the Flutter iOS example and run:

   ```bash
   cd ../sdk-flutter/attriax_flutter_ios/example/ios && pod install
   ```

No GitHub Release and no version tag is involved in the Flutter iOS test loop.

## Versioning

Keep these **in lockstep** per release:

- `Sources/Attriax/AttriaxVersion.swift` → `packageVersion` (currently `0.6.0`),
- the **git tag** (SwiftPM reads the version from it; must match the Release tag/URL).

These track the `com.attriax:core` / `sdk-kmp` version the facade ships (the SDK
package version + User-Agent are stamped by the core itself).

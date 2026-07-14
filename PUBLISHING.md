# Publishing the Attriax iOS SDK (manual / local — no CI)

`sdk-ios` is a **thin Swift facade** over the shared Kotlin Multiplatform core
(`sdk-kmp`), which ships to this package as the **`AttriaxCore` static XCFramework**
(see `README.md` / `PARITY` notes). Publishing the iOS SDK means distributing this
Swift facade **plus** that vendored framework to consumers.

Distribution is **manual and local** — there is intentionally **no CI/CD**. You run the
scripts and the publish commands from a Mac.

## What we use

- **SwiftPM (primary).** Consumers add the package by Git URL and SwiftPM resolves a
  binary `AttriaxCore.xcframework` from a **GitHub Release asset** via a remote
  `.binaryTarget(url:checksum:)`. GitHub itself is the registry — nothing else to
  register; the repo must be **public**.
- **CocoaPods (secondary).** Published to **CocoaPods Trunk** via `Attriax.podspec`, for
  consumers on a CocoaPods workflow.

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
  `github.com/attriax/sdk-ios` repo must be **public**.
- **CocoaPods:** a free CocoaPods **Trunk** account (ONE-TIME):

  ```bash
  gem install cocoapods
  pod trunk register you@email.com 'Your Name' --description='my-mac'
  # then click the confirmation link CocoaPods emails you
  ```

## Build the framework

Both distribution paths start from a freshly built, vendored XCFramework:

```bash
scripts/build-xcframework.sh
# -> builds sdk-kmp's :core:assembleAttriaxCoreReleaseXCFramework and vendors it to
#    sdk-ios/Frameworks/AttriaxCore.xcframework
```

## Publish via SwiftPM (primary)

1. **Prepare the release asset** (build + zip + checksum):

   ```bash
   scripts/release-apple.sh 0.6.0
   ```

   It builds/vendors the framework, writes `Frameworks/AttriaxCore.xcframework.zip`,
   prints the sha256 checksum, and prints the exact `.binaryTarget(url:checksum:)`
   stanza. It does **not** create a Release or push anything unless you pass `--yes`.

2. **Create the GitHub Release + upload the zip.** Either the command the script prints
   (with the `gh` CLI):

   ```bash
   gh release create 0.6.0 Frameworks/AttriaxCore.xcframework.zip \
     --repo attriax/sdk-ios --title "Attriax iOS 0.6.0" \
     --notes "AttriaxCore XCFramework binary for SwiftPM 0.6.0."
   ```

   …or via the web UI at `https://github.com/attriax/sdk-ios/releases/new` (tag `0.6.0`,
   upload the zip as an asset). Re-running `release-apple.sh 0.6.0 --yes` does step 2 and
   step 4's tag/push automatically.

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
   git tag 0.6.0 && git push --tags
   ```

   SwiftPM versions come from Git tags — the tag must match the Release tag and the
   download URL's version segment.

**Consumers:** Xcode → *File ▸ Add Package Dependencies…* → `https://github.com/attriax/sdk-ios`
→ pick `0.6.0`. Or in a `Package.swift`:

```swift
.package(url: "https://github.com/attriax/sdk-ios.git", from: "0.6.0")
```

## Publish via CocoaPods (secondary)

1. **Build the framework** (`scripts/build-xcframework.sh`).

2. **Make the framework available on the tag.** `Frameworks/AttriaxCore.xcframework` is
   git-ignored, so a plain `:git`/`:tag` pod source won't contain it. Per the caveat
   documented in `Attriax.podspec`, the **default** is to **commit the built XCFramework
   onto the release tag** so `pod lib lint` and `pod install` from the tag get the
   binary. (The alternative — an `:http` source pointing at the Release zip with an
   `unzip` `prepare_command` — is also spelled out in the podspec.)

3. **Lint** (must pass):

   ```bash
   pod lib lint Attriax.podspec
   ```

4. **Push to Trunk:**

   ```bash
   pod trunk push Attriax.podspec
   ```

**Consumers:**

```ruby
pod 'Attriax', '~> 0.6.0'
```

## CRITICAL: testing the Flutter iOS plugin does NOT require CocoaPods Trunk

Publishing the standalone `Attriax` pod to Trunk is **only for external consumers of
that pod**. The Flutter iOS plugin does **not** depend on it.

`sdk-flutter/attriax_flutter_ios/ios/attriax_flutter_ios.podspec` is a **path-sourced**
pod (`s.source = { :path => '.' }`) that vendors the framework from a **LOCAL path**:

```ruby
s.vendored_frameworks = 'Frameworks/AttriaxCore.xcframework'
```

That path is relative to the plugin podspec, i.e. the plugin expects the framework at:

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

No Trunk account, no GitHub Release, no version tag is involved in the Flutter iOS test
loop.

## Versioning

Keep these **in lockstep** per release:

- `Sources/Attriax/AttriaxVersion.swift` → `packageVersion` (currently `0.6.0`),
- the **git tag** (SwiftPM reads the version from it; must match the Release tag/URL),
- `Attriax.podspec` → `s.version` (currently `0.6.0`).

These track the `com.attriax:core` / `sdk-kmp` version the facade ships (the SDK
package version + User-Agent are stamped by the core itself).

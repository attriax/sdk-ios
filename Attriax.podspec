#
# Attriax.podspec — standalone CocoaPods spec for the native Attriax iOS SDK.
#
# This is the pod EXTERNAL consumers integrate (`pod 'Attriax'`). It is distinct
# from the Flutter plugin pod (`sdk-flutter/attriax_flutter_ios/.../attriax_flutter_ios.podspec`),
# which is a private, path-sourced pod consumed only by the Flutter plugin and does
# NOT need Trunk. See PUBLISHING.md.
#
# The Attriax engine lives in the shared Kotlin Multiplatform core (`sdk-kmp`) and
# ships as the `AttriaxCore` static XCFramework; this pod's Swift sources are the thin
# facade in `Sources/Attriax`. Build/vendor the framework first with
# `scripts/build-xcframework.sh`.
#
Pod::Spec.new do |s|
  # Keep this in lockstep with Sources/Attriax/AttriaxVersion.swift (packageVersion)
  # and the git release tag. Bump all three together per release.
  s.version          = '0.6.0'

  s.name             = 'Attriax'
  s.summary          = 'Attriax native iOS SDK — analytics + attribution, a thin Swift facade over the shared KMP core.'
  s.description      = <<-DESC
    Attriax is a mobile analytics + attribution SDK. This pod is a thin Swift facade
    that forwards to the shared Attriax engine (Kotlin Multiplatform core, shipped as
    the AttriaxCore static XCFramework): event/purchase tracking, GDPR/CCPA consent,
    deep links, ATT/IDFA, Apple Search Ads, SKAdNetwork, and App Attest.
  DESC
  s.homepage         = 'https://attriax.com'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Attriax' => 'hello@attriax.com' }

  # NOTE (source vs. vendored framework): `Frameworks/AttriaxCore.xcframework` is a
  # git-ignored build artifact of sdk-kmp (see .gitignore), so a plain :git + :tag
  # source will NOT contain the vendored framework. Two ways to ship it:
  #
  #   (a) [DEFAULT — documented here] Commit the built XCFramework on the RELEASE TAG
  #       only, so `pod lib lint` / `pod install` from the tag get the binary. Keeps
  #       linting simple (no prepare_command). Build it first:
  #         scripts/build-xcframework.sh
  #       then commit Frameworks/AttriaxCore.xcframework onto the release tag before
  #       `pod trunk push`.
  #
  #   (b) [ALTERNATIVE] Keep the framework out of git and fetch the GitHub Release zip:
  #         s.source = { :http => 'https://github.com/attriax/sdk-ios/releases/download/0.6.0/AttriaxCore.xcframework.zip' }
  #         s.prepare_command = 'unzip -o AttriaxCore.xcframework.zip -d Frameworks'
  #       (mirrors the SwiftPM remote binaryTarget; avoids committing the binary but
  #       needs the Release published first and a prepare_command that lint must run).
  #
  # Default (option a): source the tag from the public repo.
  s.source           = { :git => 'https://github.com/attriax/sdk-ios.git', :tag => s.version.to_s }

  s.source_files     = 'Sources/Attriax/**/*.swift'
  # The shared KMP core, vendored as a static XCFramework (see the source note above).
  s.vendored_frameworks = 'Frameworks/AttriaxCore.xcframework'

  # System frameworks the static KMP core references — they ship with the OS, so no
  # third-party dependency is introduced. Matches Package.swift's linkerSettings and
  # the Flutter plugin pod: AdSupport/AppTrackingTransparency (ATT/IDFA), AdServices
  # (ASA), DeviceCheck (App Attest), StoreKit (SKAN), WebKit/SafariServices (real
  # WKWebView UA + deep links), Network/SystemConfiguration (transport/connectivity),
  # Security (CSPRNG).
  s.frameworks       = 'AdSupport', 'AppTrackingTransparency', 'AdServices',
                       'DeviceCheck', 'StoreKit', 'WebKit', 'SafariServices',
                       'Network', 'SystemConfiguration', 'Security'

  # iOS 13 to match Package.swift's `.iOS(.v13)`. (The Flutter plugin pod pins 14.0
  # because it exercises the ATT/AdServices/App Attest paths that require iOS 14+; the
  # facade compiles/links against 13 and those APIs are runtime-gated in the core, so
  # the standalone pod tracks the SwiftPM manifest's floor.)
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
end

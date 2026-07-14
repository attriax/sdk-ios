# Attriax native iOS SDK (Swift)

`sdk-ios` is a **thin Swift facade over the shared Attriax core** — it is no longer a
standalone Swift engine. The runtime (transport, persistence, connectivity, device
identity, session lifecycle, consent, deep links, ATT/IDFA/ASA/SKAN/App Attest, and
the real WKWebView User-Agent) lives in the Kotlin Multiplatform core (`sdk-kmp`) and
ships as the **`AttriaxCore` XCFramework**. This module forwards every public call to
that core (`AttriaxApple` / `AttriaxCore.Attriax`) and maps value objects across the
Kotlin/Native Obj-C boundary in `AttriaxCoreBridge`. It mirrors the Android AAR
re-export and the Flutter / Unity re-wraps, so all platforms share ONE engine.

The public API is preserved so downstream integrators are unchanged.

## Layout

- `Package.swift` — consumes the vendored `Frameworks/AttriaxCore.xcframework`
  (`.binaryTarget`, git-ignored — a reproducible build artifact of `sdk-kmp`) and
  links the OS system frameworks the static core references (AdSupport,
  AppTrackingTransparency, AdServices, DeviceCheck, StoreKit, WebKit, SafariServices,
  Network, SystemConfiguration, Security).
- `Sources/Attriax/` — the facade classes + `AttriaxCoreBridge` (the single KMP⇄Swift
  mapping seam). No engine code, no `Internal/` tree.

## Building

The XCFramework is produced from `sdk-kmp` (requires a Mac with Xcode — Kotlin/Native
Apple targets do not build on Windows/Linux). Build it there, drop it at
`Frameworks/AttriaxCore.xcframework`, then:

```
swift build          # from sdk-ios/
```

See `VERIFICATION.md` for the full Mac build + smoke checklist.

## Public API

Construct via `AttriaxSdk.create` and call `initialize()`:

```swift
let attriax = AttriaxSdk.create(config: AttriaxConfig(projectToken: "pt_..."))
attriax.initialize()

attriax.tracking.recordEvent("level_complete", eventData: ["level": 3])
attriax.tracking.recordPurchase(revenue: 4.99, currency: "USD", productId: "gold_100")
attriax.tracking.setUser(userId: "u_42")

// Consent (network variants: call off the main thread)
attriax.consent.gdpr.setConsent(analytics: true, attribution: true, adEvents: false)

// Deep links — forward from your AppDelegate / SceneDelegate
attriax.deepLinks.addListener { event in print("deep link:", event.url) }
attriax.deepLinks.handleUniversalLink(url.absoluteString, isLaunch: true) // Universal Link
attriax.deepLinks.handleUrl(url.absoluteString)                            // custom scheme
attriax.deepLinks.completeLaunchWithoutLink()                             // launched with no link
```

Surfaces, all forwarding to the core:

- **`attriax.tracking`** — `recordEvent`, `recordPageView`, `recordPurchase`,
  `recordRefund`, `recordAdRevenue`, `recordAdEvent`, `recordError`,
  `recordNotification(Received/Opened/Dismissed)`, `setUser` /
  `setUserProperty(ies)` / `clearUserProperties`, `registerApnsToken`.
- **`attriax.consent.gdpr`** — `state`, `values`, `isWaitingForConsent`,
  `needsConsent`, `setConsent`, `setNotRequired`, `reset`, `requestDataErasure`.
- **`attriax.consent.ccpa`** — `doNotSell`, `usPrivacy`, `setDoNotSell`,
  `setUsPrivacy`, `set(doNotSell:usPrivacy:)` (CCPA "do not sell / share";
  also seedable via `AttriaxConfig.doNotSell` / `.usPrivacy`).
- **`attriax.deepLinks`** — `handleUniversalLink` / `handleUrl` /
  `completeLaunchWithoutLink`, `addListener` / `addRawListener` (+ remove),
  `initialDeepLink` / `latestDeepLink` / `rawInitialDeepLink` /
  `initialDeepLinkResolved` / `waitForInitialDeepLink`, `recordDeepLink`,
  `createDynamicLink`.
- **`attriax.att`** — `status` (reads ATT, never prompts),
  `requestTrackingAuthorization` (host opt-in prompt).
- **`attriax.skan`** — `registerForAttribution`, `updateConversionValue`,
  `fetchConversionConfig` (pulls the project's configured CV rules from
  `GET /api/sdk/v1/skan/conversion-config/<projectToken>`).
- **top-level** — `initialize`, `flush`, `reset`, `dispose`, `isInitialized`,
  `isFirstLaunch`, `deviceId`, `enabled`, `anonymousTrackingEnabled`,
  `currentSession`, `validateReceipt`.
- **App Attest** — opt in via `AttriaxConfig.attestationProvider`
  (`AppAttestAttestationProvider`); the core attaches the attestation envelope to the
  app-open and degrades to no-envelope on any failure.

### Advertising id

`AttriaxSdk.create(config:advertisingIdSupplier:)` accepts an optional host-provided
IDFA source. When supplied and `config.collectAdvertisingId` is true, its value is
used ahead of the core's internal ATT-gated IDFA resolution (the internal seam is
consulted only when the supplier returns nil/blank). Pass `nil` to let the core
resolve the IDFA itself under its own ATT gate.

## Tests

The engine's unit-test coverage lives in the KMP core (`sdk-kmp`, `commonTest`). This
module has no test target; public-API-vs-framework smoke lives in the example / host
integration (see `VERIFICATION.md`).

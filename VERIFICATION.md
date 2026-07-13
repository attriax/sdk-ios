# iOS facade — Mac verification checklist

`sdk-ios` is a thin Swift facade over the `AttriaxCore` XCFramework (the shared KMP
core in `sdk-kmp`). The engine's behavior is exercised by the KMP `commonTest` suite,
which runs on every buildable target. What CANNOT be built off a Mac is (a) the
Kotlin/Native **Apple** targets that produce the XCFramework and (b) this Swift
facade. So this checklist is the Mac-gated work: build the framework, compile the
facade against it, and smoke the wired surface end-to-end.

## 1. Build the `AttriaxCore` XCFramework (from `sdk-kmp`, on a Mac)

Kotlin/Native Apple targets require Xcode. Build the device arm64 + simulator
arm64/x64 (+ macOS) slices and assemble the XCFramework, then drop it at
`sdk-ios/Frameworks/AttriaxCore.xcframework` (git-ignored — a reproducible artifact).

## 2. Compile the facade (`swift build` from `sdk-ios/`)

The facade is small and declarative; the compile risks are all at the KMP⇄Swift Obj-C
boundary in `Sources/Attriax/AttriaxCoreBridge.swift`. Eyeball:

- **NSNumber boxing** — `AttriaxConfig` ms-based fields, `KotlinBoolean` /
  `KotlinLong` / `KotlinInt` conversions (e.g. `schemaVersion.map { Int($0.int32Value) }`
  in `skanConversionConfig`). Confirm the `KotlinInt.int32Value` accessor name matches
  what the generated framework header exports.
- **Sealed-class-as-Obj-C-class casts** — `skanCvValue` down-casts the exported
  `AttriaxSkanCvValue` base to `AttriaxSkanCvValueStringValue` /
  `…NumberValue` / `…BoolValue`. Confirm the generated subclass names (Kotlin nested
  sealed subclasses) match; adjust the cast names if the header differs.
- **Reserved-keyword property** — the KMP `operator` property is read via backticks
  (`condition.\`operator\``). Confirm the generated Obj-C selector is `operator` (not a
  `operator_`-style rename); adjust if the header renamed it.
- **Function-type parameter** — `AttriaxApple.create(config:userAgent:advertisingIdSupplier:)`
  takes an optional `(() -> String?)?`. Confirm the exported block signature bridges
  cleanly from the Swift closure.

## 3. Live smoke against the dev stack

Point the SDK at the dev API and confirm init → app-open succeeds: the nested open
body (`sdk`/`app`/`device`) is accepted (HTTP 201), a new identified app-user is
created with `platform: ios`, and `botOperator` is empty (the real WKWebView Safari
User-Agent must pass the backend isbot filter — load-bearing). Then `recordEvent`,
`recordPurchase` (immediate flush), `setUser`, a notification, `registerApnsToken`
(→ `/uninstall-tokens`, provider `apns`), and `validateReceipt` should each round-trip.
Device id resolves to IDFV (`ios_idfv`), falling to `persistent_storage` in the
Simulator; the UA is stable across launches; the queue persists + retries across a
kill.

## 4. Confirm the three newly-wired facade methods

These three were previously degraded shims; they now forward to real core behavior.
Verify each:

- **`attriax.skan.fetchConversionConfig()`** — pulls the project's configured SKAN
  CV rules via `GET /api/sdk/v1/skan/conversion-config/<projectToken>` and decodes the
  api `SdkCvConfigResponse` into `AttriaxSkanConversionConfig`. With a project that has
  a schema configured, confirm a populated config (schemaVersion / enabled / ordered
  `rules[]` with `startBit` / `bitContribution` / `whenEvent` / `whenConditions` /
  `whenRevenue` / `coarseValue` / `lockWindow`); with an unknown token or no schema it
  returns `nil` (404 → nil, best-effort, never throws). Call off the main thread. (The
  decode is already covered by the KMP `AttriaxSkanCvConfigTest`; this confirms the
  Swift mapping.)
- **`attriax.deepLinks.completeLaunchWithoutLink()`** — call it from a launch path that
  carried NO deep link and confirm a `waitForInitialDeepLink()` observer unblocks
  immediately with `initialDeepLinkResolved == true` and `initialDeepLink == nil`
  (instead of blocking for the full timeout). Confirm it is idempotent and that a link
  later arriving via `handleUniversalLink(_:isLaunch:true)` still resolves.
- **`AttriaxSdk.create(config:advertisingIdSupplier:)`** — pass a supplier returning a
  known IDFA with `collectAdvertisingId: true` and confirm the device id resolves to
  that value (source `ios_idfa`) ahead of the internal ATT-gated resolution; with the
  supplier returning nil/blank, resolution falls back to the internal ATT-gated seam
  (IDFV / persistent when not authorized). With `advertisingIdSupplier: nil`, behavior
  is unchanged (core resolves the IDFA itself).

## 5. On-device checks (cannot be proven in the Simulator)

These depend on real Apple frameworks that no-op in the Simulator:

- **ATT prompt** — `attriax.att.status` reads without prompting;
  `attriax.att.requestTrackingAuthorization { … }` shows the system dialog once (needs
  `NSUserTrackingUsageDescription`); the resolved status is stamped on the next
  app-open's `attStatus`. The SDK must NOT auto-prompt at init.
- **IDFA only when authorized** — before authorization / when denied, device id is
  `ios_idfv` (or `persistent_storage`), never a zero IDFA; after ATT `.authorized` +
  `collectAdvertisingId: true`, a relaunch resolves `ios_idfa`.
- **ASA token capture** — with `asaAttributionEnabled: true`, init fires a background
  `POST /api/sdk/v1/asa/token`; it must never block init and must silently no-op on the
  Simulator (AdServices returns nil). Real device only.
- **SKAN postbacks** — `registerForAttribution()` / `updateConversionValue(...)` are
  device-only (the Simulator does not deliver postbacks); confirm the calls don't crash.
- **App Attest** — on a supported real device, with `attestationEnabled: true` and an
  `AppAttestAttestationProvider`, the open body carries the `attestation` envelope; every
  failure mode (Simulator/unsupported, disabled, nil provider, offline challenge, thrown
  error) must degrade to no-envelope with the open still sent.

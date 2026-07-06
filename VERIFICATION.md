# iOS SDK — Mac verification punch-list

This SDK was written on Windows and **has NOT been compiled or run** (no macOS/Xcode
available). It is a careful port of the live-verified Android SDK (`sdk-android`,
mirroring `sdk-android/PARITY.md`), and an independent parity review found it a
faithful mirror with **zero wire/behavior divergences**. But nothing here is proven
until it builds and runs on a Mac. Work this list on the Intel MacBook Pro.

## 1. Compile (`swift build` from `sdk-ios/`)

The port is idiomatic Swift, but the `[String: Any?]` heterogeneous-dictionary
existential casts are where Swift's type-checker is fussiest. Verify these spots
first; if the `.flatMap { $0 }` double-optional flatten is rejected, the mechanical
fix is to collapse it through the cast — `(dict[key] as? String)` — applied uniformly:

- `Internal/Request/AttriaxBatching.swift` (~L33,42) — `body[field].flatMap { $0 } as? String`.
- `Internal/Request/AttriaxApiRequest.swift` (~L64) — same idiom in `isBatchable`.
- `Internal/Queue/AttriaxQueueCodec.swift` (~L75-107) — high-frequency `dict[key].flatMap { $0 }` / `as? T`.
- `Internal/Request/AttriaxRequestBuilders.swift` (~L37-40) — `[...] as AttriaxJSONObject` literal annotation (heterogeneous-collection inference).
- `Internal/Json/AttriaxJson.swift` (~L56-66) — the nested `as? [String: Any]` / `[Any?]` cascade in `encodeInto`.
- `Platform/AttriaxURLSessionClient.swift` (~L99) — `map["data"].flatMap { $0 }` envelope unwrap.

## 2. DECISION: tracking-before-init behavior

`Attriax.requireInitialized()` currently uses `precondition(...)` — a **hard crash** in
release if a tracking call happens before `initialize()` completes. The Flutter/Android
contract says this should *throw* (a catchable error). For an analytics SDK, crashing
the host app is undesirable. **Pick one and apply it deliberately:**
- **(recommended) graceful no-op + warning log** — never crash the host; make
  `requireInitialized()` return a `Bool` and `guard requireInitialized() else { return }`
  at the 3 call sites (`Attriax.swift` ~L182,237,258), returning a sensible default for
  `validateReceipt`.
- **throw** — mark the public tracking methods `throws` (heavier ergonomics: callers `try`).
- keep `precondition` (crash-on-misuse) — only if you want the strictest fail-fast.

This was left as a decision for you rather than guessed blind.

## 3. Add a test target + unit tests

`Package.swift` is ready for a `.testTarget`. The code was factored pure-logic-vs-I/O
specifically so these deterministic seams test with no simulator:
`AttriaxIdGenerator.formatId`, `AttriaxRetryPolicy` (backoff/Retry-After/terminal-drop),
`AttriaxRevenue` (currency/refund/notification-source), `AttriaxQueueCodec.normalize`
(legacy appToken/identify), `AttriaxBatching` (build/collect/split), `AttriaxSessionContinuation`.

## 4. Live smoke against the dev stack (the same check that proved Android)

Point the SDK at the dev API (`http://<host>:33000`) and confirm:
- init → app-open: the **nested** open body (`sdk`/`app`/`device`) is accepted (HTTP 201),
  a new **identified** app-user is created with `platform: ios`, and `botOperator` is
  **empty** (the `attriax-ios-sdk/... (iOS ...; ...)` User-Agent must pass the backend
  isbot filter — this is load-bearing).
- `recordEvent`, `recordPurchase` (immediate flush), `setUser` (identify), a notification,
  `registerApnsToken` (→ `/uninstall-tokens`, provider `apns`), and `validateReceipt` all
  round-trip 201.
- device id resolves to IDFV (source `ios_idfv`); falls to `persistent_storage` in the
  Simulator when IDFV is nil; UA is stable across launches; queue persists + retries
  across an app kill; the `{data:…}` envelope unwraps.

## 5. CHUNK B — additional compile spots to eyeball

The heterogeneous-dictionary idiom concern from §1 extends to the new files. Verify:

- `Internal/Consent/AttriaxConsentStore.swift` / `AttriaxConsentTransport.swift` —
  `obj[field] ?? nil` collapse feeding `decodeValues(_ value: Any?)`.
- `Internal/DeepLink/AttriaxDeepLinkResolver.swift` (`stringMap`, `decodeResolution`)
  and `AttriaxDeepLinkDeferredRecovery.swift` — nested `as? [String: Any?]` / `?? nil`.
- `Internal/DeepLink/AttriaxUri.swift` — `NSRegularExpression.firstMatch` +
  `range(at: 1)` group extraction, and the percent-decode byte loop.
- `Internal/DeepLink/AttriaxDeepLinkManager.swift` — the late-bound
  `resolveDispatch` optional and `DispatchSemaphore`-backed initial-link latch.
- `Attriax.swift` init — the wired-after-init managers are IUOs
  (`dispatcher!`/`sessionLifecycleManager!`/`lifecycleBinder!`/`deepLinkManager!`/
  `consentQueuePolicy!`) so `[weak self]` closures are legal during phase-1 init.
  If the compiler still objects to a `self` capture, the fix is to assign every
  remaining stored property before the first self-capturing closure.

## 6. CHUNK B — behavior to confirm on device / simulator

- **Generation guard (the load-bearing consent fix).** Rapid
  `setConsent(true)` → `setConsent(false)` must NOT leave analytics stuck on: the
  in-flight older upsert echo is discarded when `generation` advanced
  (`AttriaxConsentManager.runSyncLoop`). Reproduce with a fake `AttriaxConsentTransport`
  that delays the first echo. `AttriaxConsentManager(consentTransport:)` /
  `consentSyncQueue:` init params exist expressly for this test.
- **Consent gate + queue rewrites.** With `gdprEnabled: true`, pending consent +
  `anonymousTracking: true` captures analytics/session/deep-link ANONYMOUSLY (no
  `deviceId`), NOT attribution/user/open. On `setConsent`, the three passes run:
  identify (re-attach id), anonymize (strip id), discard (`gdpr_consent_denied`).
- **Deep links.** `handleUniversalLink` / `handleUrl` → `/deep-links/resolve` with a
  normalized `linkPath` (slashes stripped); 2s dedup suppresses a repeat; the resolve
  is terminal-drop-exempt; deferred link recovers ONCE from the app-open response and
  replays to a late listener; `createDynamicLink` sends BOOLEAN `iosRedirect`/
  `androidRedirect`.
- **Session lifecycle.** Heartbeat fires at 30s (first launch) then 5min off the main
  thread; `didEnterBackground` pauses + flushes + cancels the heartbeat;
  `didBecomeActive` resumes within the window or starts a new session (+ recovered
  END) past it; `willTerminate` ends; a batch carrying a live-session event gets a
  synthetic keep-alive and its delivery bumps last-activity.
- **Timer thread.** `AttriaxTimerScheduler` runs the heartbeat `Timer` on a dedicated
  background run-loop thread. Confirm ticks fire (the `Port()` keeps the loop alive)
  and `cancel()` / `shutdown()` stop them without leaking the thread.

## 7. CHUNK C — Apple frameworks (ATT / IDFA / ASA / SKAdNetwork / App Attest)

CHUNK C wires the real Apple platform frameworks. **This is the riskiest chunk** (most
novel Apple API surface) and, like A/B, is **code-complete-UNVERIFIED** — it has not
been compiled or run. Every framework is optional at runtime: the SDK must build + run
on the **base config with all of these OFF** and degrade gracefully when an OS version
or framework is unavailable.

### Frameworks, min iOS, and the config flag that gates each

| Framework | Symbols | Min iOS | Config gate | Wire shape |
|---|---|---|---|---|
| **AppTrackingTransparency** (ATT) | `ATTrackingManager.trackingAuthorizationStatus` / `requestTrackingAuthorization` | 14.0 | always read; prompt is host opt-in (never auto) | `attStatus` TOP-LEVEL on the open body: `authorized\|denied\|restricted\|notDetermined\|unknown` (`SdkV1OpenDto.attStatus`) |
| **AdSupport** (IDFA) | `ASIdentifierManager.shared().advertisingIdentifier` | 14.0 | `collectAdvertisingId` **AND** ATT `.authorized` | device id `deviceIdSource: ios_idfa` (else `ios_idfv` / `persistent_storage`) |
| **AdServices** (Apple Search Ads) | `AAAttribution.attributionToken()` | 14.3 | `asaAttributionEnabled` | `POST /api/sdk/v1/asa/token` body `{ projectToken, token }` (`SdkAsaTokenDto`) |
| **StoreKit** (SKAdNetwork) | `updatePostbackConversionValue` (16.1) / `updateConversionValue` (15.4) / `registerAppForAdNetworkAttribution` (14) | 14.0 (SKAN 4 coarse/lock = 16.1) | host-driven via `attriax.skan` | CV-config pull `GET /api/sdk/v1/skan/conversion-config/:projectToken` (`SdkCvConfigResponse`) |
| **DeviceCheck** (App Attest) | `DCAppAttestService.shared` (`isSupported`/`generateKey`/`attestKey`) | 14.0 | `attestationEnabled` **AND** `attestationProvider != nil` | envelope under `attestation` on the open body (`SdkAttestationDto`) |

**App Attest envelope fields** (assembled in `AttriaxAttestationManager.resolveEnvelope`,
attached under `open.attestation`): `provider: "app_attest"`, `token` (base64 of the
`DCAppAttestService.attestKey` attestation object), `nonce` (the SDK-issued challenge
nonce, echoed for the server to match), `keyId` (the `generateKey` key id; App-Attest-only,
omitted when nil). `clientDataHash = SHA256(nonce)` — the server recomputes this to bind
the exact nonce it issued.

### Availability / canImport gates to eyeball at compile time

Every Apple symbol is **doubly gated**: `#if canImport(<Framework>)` (so non-Apple
targets never reference it) **plus** `@available(...)` / `if #available(...)` at each
call site (so the iOS-13 min-deployment build is legal). Verify these files compile with
the gates intact:

- `Sources/Attriax/Platform/AttriaxAppTrackingTransparency.swift` — `#if canImport(AppTrackingTransparency)`
  + `if #available(iOS 14, *)` in `currentStatus`/`requestAuthorization`/`map`; the IDFA
  supplier's `#if canImport(AdSupport)` + `.authorized` gate + all-zero-IDFA reject.
- `Sources/Attriax/Platform/AttriaxAppAttestProvider.swift` — the whole
  `AppAttestAttestationProvider` body is inside `#if canImport(DeviceCheck)` **and**
  `@available(iOS 14.0, macCatalyst 14.0, tvOS 15.0, *)`; `CryptoKit` behind
  `#if canImport(CryptoKit)`. `AttriaxAppAttest.provider()` is the availability-safe
  factory a pre-14 host can name unconditionally (returns the noop below 14).
- `Sources/Attriax/Platform/AttriaxAsaTokenCapture.swift` — `#if canImport(AdServices)`
  + `if #available(iOS 14.3, *)` around `AAAttribution.attributionToken()`.
- `Sources/Attriax/Platform/AttriaxSkanPassthrough.swift` — `#if canImport(StoreKit)`
  + the newest-first `if #available(iOS 16.1, *) … else if 15.4 … else if 14.0` ladder;
  `mapCoarse` is `@available(iOS 16.1, *)`. Expect a deprecation *warning* (not error) on
  the 15.4 `updateConversionValue` branch — that is fine.
- `Sources/Attriax/AttriaxAtt.swift` / `AttriaxSkan.swift` / `AttriaxAttestation.swift` —
  PURE public surfaces (no framework imports); the enum wire strings must match the api
  DTO literals exactly.
- `Sources/Attriax/Internal/Skan/AttriaxSkanConfig.swift` — heterogeneous-dict decode
  (`map[key].flatMap { $0 } as? T`), same §1 idiom concern; the `CharacterSet` path-segment
  encoding for the project token.
- `Sources/Attriax/AttriaxSdk.swift` — `injectAttestationStore` mutates
  `AppAttestAttestationProvider.store` inside `#if canImport(DeviceCheck)` + `#available`.

### On-device checks (the parts that CANNOT be proven in the Simulator)

Base-config sanity first: with **all** CHUNK-C flags off (default config), init → app-open
still succeeds and the open body carries `attStatus: "notDetermined"` (or `"unknown"` on
a pre-14 OS) and **no** `attestation`.

- **ATT prompt flow.** `attriax.att.status` reads without prompting. `attriax.att.requestTrackingAuthorization { … }`
  shows the system dialog ONCE (needs `NSUserTrackingUsageDescription` in Info.plist);
  the resolved status is stamped on the NEXT app-open's `attStatus`. Confirm the SDK does
  NOT auto-prompt at init.
- **IDFA only when authorized.** Before authorization / when denied, device id resolves to
  `ios_idfv` (or `persistent_storage`), NOT `ios_idfa`, and no all-zero IDFA leaks. After
  ATT `.authorized` **and** `collectAdvertisingId: true`, a relaunch resolves `ios_idfa`.
  (IDFA is real-device only — the Simulator returns the zero IDFA.)
- **ASA token capture.** With `asaAttributionEnabled: true`, init fires a background
  `POST /api/sdk/v1/asa/token` with `{ projectToken, token }` where `token` is the opaque
  `AAAttribution.attributionToken()`. Confirm it NEVER blocks init and silently no-ops
  offline / on the Simulator (no token). **Needs a real device** (AdServices returns nil
  in the Simulator).
- **SKAN conversion update.** `attriax.skan.registerForAttribution()` seeds the first
  postback; `attriax.skan.updateConversionValue(fine, coarseValue:, lockWindow:)` updates
  it (coarse/lock honored only on 16.1+). `attriax.skan.fetchConversionConfig()` pulls the
  project CV rules (404 → nil on unknown token). **SKAN postbacks are device-only** — the
  Simulator does not deliver them; verify the calls don't crash and the config pull
  round-trips.
- **App Attest supported-device attestation + the challenge/envelope live path.** On a
  **real device** (`DCAppAttestService.isSupported == true`; false in the Simulator), with
  `attestationEnabled: true` and `attestationProvider: AppAttestAttestationProvider()` (or
  `AttriaxAppAttest.provider()`): init → `POST /api/sdk/attestation/challenge` → App Attest
  `generateKey`+`attestKey(clientDataHash: SHA256(nonce))` → the open body carries
  `attestation: { provider:"app_attest", token, nonce, keyId }`. Confirm the key id
  persists across launches (SDK `UserDefaults` suite) and — critically — that **every**
  failure mode (Simulator/unsupported, `attestationEnabled:false`, nil provider, offline
  challenge, thrown error) degrades to **no envelope, open still sent** — attestation must
  NEVER break init.
- **Queue restore.** Kill the app after an attested open is enqueued but before it flushes;
  on relaunch the persisted `attestation` envelope (nested in the open body) round-trips
  intact through `AttriaxQueueCodec` and the open still sends.

## Scope note

This is CHUNK A + CHUNK B + **CHUNK C** (core runtime + tracking + consent/anonymous +
deep links + session lifecycle + the Apple frameworks: ATT / IDFA / Apple Search Ads /
SKAdNetwork / App Attest). Every CHUNK-C framework is optional at runtime and inert by
default; the base config references none of their symbols.

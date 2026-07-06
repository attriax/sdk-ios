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

## Scope note

This is CHUNK A + CHUNK B (core runtime + tracking + consent/anonymous + deep links +
session lifecycle). The Apple frameworks (ATT/IDFA/ASA/SKAN, App Attest) arrive in
CHUNK C and are stubbed with stable seams (IDFA supplier nil, no attestation).

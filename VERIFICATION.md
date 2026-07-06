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

## Scope note

This is CHUNK A (core runtime + tracking). Consent + anonymous mode, deep links,
session-lifecycle timers/keep-alive, and the Apple frameworks (ATT/IDFA/ASA/SKAN,
App Attest) arrive in later chunks and are stubbed with stable seams (IDFA supplier nil,
dispatcher keep-alive builder nil, no attestation).

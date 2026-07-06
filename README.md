# Attriax native iOS SDK (Swift) — Epic 9.3

Standalone Swift core, Foundation-only (no SwiftPM dependencies). Per-platform
native core — mirrors the **already-proven Android core** (`sdk-android/`, itself
a live-verified port of the `sdk-flutter/` reference). The behavior contract is
`sdk-android/PARITY.md`; wire shapes are confirmed against
`api/src/modules/sdk/dto/`.

## Status

**Epic 9.3, CHUNK A + CHUNK B — code-complete, UNVERIFIED.** Written blind on
Windows (no macOS/Xcode). It has **not** been compiled or run. Compile + test on a
Mac before relying on it. No tests are included (by request). Chunk B mirrors the
live-verified Android consent (slice 3), deep-link (slice 4), and session-lifecycle
(slice 6) slices, including the generation-guard downgrade-race fix.

## What CHUNK A contains

Core engine + tracking:

- **Config / version / keys** — `AttriaxConfig`, `AttriaxVersion`, reserved
  event-name/param-key/enum tables (`AttriaxAnalyticsKeys`).
- **Pure primitives** — id generator (UUID-v4-like), User-Agent builder, clock +
  ISO-8601, revenue lowering (currency validation / refund negation /
  notification-source inference), dependency-free JSON codec.
- **Request layer** — `AttriaxApiRequest`, endpoints, per-endpoint body builders
  (open/event/session/user/crash/notification/uninstall/receipt), batching
  (identity hoist + strip + run collection + limits).
- **Queue / dispatch** — persisted queue codec (+ legacy `appToken`→`projectToken`
  / `identify`→`user` normalization), queue manager (FIFO overflow, flush/enqueue
  race preservation), retry policy (retryable statuses, `Retry-After`/jittered
  backoff, terminal drop), app-open hoist, dispatcher (hoist → batch/single →
  retry/drop → single-flight).
- **Session** — continuation-window policy + snapshot store + snapshot state
  machine; init emits the initial `start` and any recovered `end` (row S5).
- **Public surface** — `Attriax`, `AttriaxTracking`, `AttriaxSdk.create`,
  `validateReceipt`.
- **Platform I/O** — `URLSession` transport (stamps the UA, unwraps `{data}`,
  typed errors), suite-scoped `UserDefaults` store, `NWPathMonitor` connectivity,
  IDFV device-id source (+ ATT/IDFA supplier seam).

## What CHUNK B adds

- **Consent + anonymous mode** (`attriax.consent.gdpr`, rows C1–C5) — local state
  machine (`unknown`/`not_required`/`pending`/`granted`), apply-locally-immediately
  + generation-guarded background sync (the downgrade-race fix), two-gate anonymous
  policy (`allowsCategory` strict vs `canCaptureSignal`/`trackingDecisionFor`
  permissive), the consent-aware `enqueueTracked` gate (drop / anonymize /
  defer-network) replacing the `enabled`-only gate, the three consent-resolution
  queue-rewrite passes (identify / anonymize / discard `gdpr_consent_denied`), and
  `requestDataErasure` → `/privacy/gdpr/erase`.
- **Deep links** (`attriax.deepLinks`, rows DL1–DL5) — `handleUniversalLink(_:)` /
  `handleUrl(_:)` forwarding from the host's AppDelegate/SceneDelegate, direct
  resolve (normalized `linkPath`, 2s dedup, terminal-drop-exempt), deferred recovery
  from the app-open response (`deepLink` > `reinstallReferrer` > `installReferrer`,
  fire-once persisted, skip on `appDataClear`), closure-listener/observer pattern
  (no Combine), and `createDynamicLink` → `/dynamic-links` (`iosRedirect`/
  `androidRedirect` are booleans).
- **Session lifecycle** (rows S2–S5) — heartbeat timer (first-launch 30s → 5min)
  off the main thread, foreground/background/terminate via `UIApplication`
  notifications (`didBecomeActive` → resume|new-start, `didEnterBackground` → pause
  + flush + cancel heartbeat, `willTerminate` → end), and the dispatcher keep-alive
  injection (a batch carrying a live-session event gets a synthetic heartbeat;
  delivery bumps last-activity).

## Explicitly NOT built (Chunk C — clean seams left)

- **Chunk C** — ATT / ASA / SKAN / App Attest. The IDFA source returns nil until
  an ATT-authorized supplier is wired in; no AdSupport/ATT symbol is referenced,
  so the SDK links without an ATT usage description in this chunk.

## Usage

```swift
let attriax = AttriaxSdk.create(config: AttriaxConfig(projectToken: "pt_..."))
attriax.initialize()
attriax.tracking.recordEvent("level_complete", eventData: ["level": 3])
attriax.tracking.recordPurchase(revenue: 4.99, currency: "USD", productId: "gold_100")

// Consent (call off the main thread for the network variants)
attriax.consent.gdpr.setConsent(analytics: true, attribution: true, adEvents: false)

// Deep links — forward from your AppDelegate / SceneDelegate
attriax.deepLinks.addListener { event in print("deep link:", event.url) }
// application(_:continue:restorationHandler:) → activity.webpageURL
attriax.deepLinks.handleUniversalLink(url.absoluteString, isLaunch: true)
// application(_:open:options:) / scene(_:openURLContexts:)
attriax.deepLinks.handleUrl(url.absoluteString)
```

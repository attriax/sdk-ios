# Attriax native iOS SDK (Swift) — Epic 9.3

Standalone Swift core, Foundation-only (no SwiftPM dependencies). Per-platform
native core — mirrors the **already-proven Android core** (`sdk-android/`, itself
a live-verified port of the `sdk-flutter/` reference). The behavior contract is
`sdk-android/PARITY.md`; wire shapes are confirmed against
`api/src/modules/sdk/dto/`.

## Status

**Epic 9.3, CHUNK A: core runtime + tracking API — code-complete, UNVERIFIED.**
Written blind on Windows (no macOS/Xcode). It has **not** been compiled or run.
Compile + test on a Mac before relying on it. No tests are included (by request).

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

## Explicitly NOT built (later chunks — clean seams left)

- **Chunk B** — consent + anonymous mode (the enqueue gate is `enabled`-only for
  now), deep links (resolve dispatch + deferred recovery), session **lifecycle
  timers** (heartbeat / foreground-background transitions + batch keep-alive
  injection). The pure session *snapshot* machine is present; no timer drives it.
- **Chunk C** — ATT / ASA / SKAN / App Attest. The IDFA source returns nil until
  an ATT-authorized supplier is wired in; no AdSupport/ATT symbol is referenced,
  so the SDK links without an ATT usage description in this chunk.

## Usage

```swift
let attriax = AttriaxSdk.create(config: AttriaxConfig(projectToken: "pt_..."))
attriax.initialize()
attriax.tracking.recordEvent("level_complete", eventData: ["level": 3])
attriax.tracking.recordPurchase(revenue: 4.99, currency: "USD", productId: "gold_100")
```

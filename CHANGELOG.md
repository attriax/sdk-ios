# Changelog

## 0.6.0

First tracked release of the `Attriax` Swift package.

### Added
- `attriax.consent.ccpa` (`AttriaxCcpaConsent`): `doNotSell` / `usPrivacy` getters plus `setDoNotSell`, `setUsPrivacy`, and `set(doNotSell:usPrivacy:)`, seeded from the new `AttriaxConfig.doNotSell` / `usPrivacy` and overridable at runtime — mirroring the Flutter `setCcpaConsent` surface and Unity's `AttriaxConsent.Ccpa`. Both fields ride top-level on the app-open / batch envelopes. CCPA was previously unreachable through the Swift facade, which hardcoded both values to `nil`.
- `skan.fetchConversionConfig()` to pull the project's configured SKAdNetwork conversion-value rules from the backend. Best-effort: returns `nil` when the project has no schema, the token is unknown, or the pull fails. The SDK does not auto-apply the rules.

### Changed
- The SDK is now a **thin Swift facade** over the `AttriaxCore` XCFramework built from the shared Kotlin Multiplatform core; the standalone Swift engine was retired. The public `Attriax` Swift API is preserved, so downstream integrators are unchanged.
- Distributed via **Swift Package Manager only** (`github.com/attriax/sdk-ios`, tag `0.6.0`), with the `AttriaxCore.xcframework` binary resolved from the matching GitHub Release. **CocoaPods is not supported** — there is no standalone `Attriax` podspec.
- Breaking: `skan.updateConversionValue(_:coarseValue:lockWindow:)` now returns the real `AttriaxSkanUpdateStatus` instead of taking an `(Error?) -> Void` completion handler. The old callback was misleading — it fired synchronously and always with `nil`, discarding the actual status. The result is `@discardableResult` for fire-and-forget callers.

### Fixed
- Corrected two KMP-to-Obj-C interop names in the SKAdNetwork conversion-value bridge.

---

Earlier releases predate this changelog.

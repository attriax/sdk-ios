import Foundation

/// Pure, framework-free lowering helpers shared by the tracking surface
/// (PARITY §4, rows E2/E3/E6). Kept platform-free so the reserved
/// event-name/param-key lowering, refund negation, currency validation, and
/// notification-source inference stay unit-testable off-device.
enum AttriaxRevenue {

    private static let currencyRegex = try! NSRegularExpression(pattern: "^[A-Z]{3}$")

    /// Normalized revenue amount + currency after validation (row E3).
    struct NormalizedRevenue {
        let revenue: Double
        let currency: String
    }

    /// Validate `currency` against `^[A-Z]{3}$` (after trim+uppercase). On a valid
    /// code the `revenue` passes through unchanged; otherwise revenue is defaulted
    /// to `0` and the currency to `USD` (the caller emits a warning) — row E3.
    static func normalizeRevenueCurrency(_ revenue: Double, _ currency: String?) -> NormalizedRevenue {
        if let normalized = normalizedCurrency(currency), matchesCurrency(normalized) {
            return NormalizedRevenue(revenue: revenue, currency: normalized)
        }
        return NormalizedRevenue(revenue: 0, currency: "USD")
    }

    /// True when `currency` passes the `^[A-Z]{3}$` check (used to gate the warning).
    static func isValidCurrency(_ currency: String?) -> Bool {
        guard let normalized = normalizedCurrency(currency) else { return false }
        return matchesCurrency(normalized)
    }

    /// Refund revenue is the negated absolute value of the normalized revenue,
    /// with `0` preserved as `0` (avoids a signed-zero) — row E2.
    static func refundRevenue(_ normalizedRevenue: Double) -> Double {
        normalizedRevenue == 0 ? 0 : -abs(normalizedRevenue)
    }

    /// Best-effort inference of the delivery channel from a raw FCM/APNs payload
    /// (row E6). APNs payloads carry an `aps` envelope; FCM payloads carry a
    /// `google.*` / `gcm.*` key. Returns `nil` when undecidable so the server
    /// falls back to `other`.
    static func inferNotificationSource(_ payload: [String: Any?]?) -> AttriaxNotificationEventSource? {
        guard let payload = payload, !payload.isEmpty else { return nil }
        if payload.keys.contains("aps") { return .apns }
        let looksFcm = payload.keys.contains { key in
            key == "google.message_id" || key == "gcm.message_id" ||
                key.hasPrefix("google.") || key.hasPrefix("gcm.")
        }
        return looksFcm ? .fcm : nil
    }

    /// Preserve the raw FCM/APNs `payload` under a `payload` key inside the
    /// notification metadata so attribution context survives to the server.
    /// Explicit `metadata` entries take precedence over the payload key.
    static func mergeNotificationMetadata(
        metadata: [String: Any?]?,
        payload: [String: Any?]?
    ) -> [String: Any?]? {
        let hasPayload = payload != nil && !(payload!.isEmpty)
        let hasMetadata = metadata != nil && !(metadata!.isEmpty)
        if !hasPayload && !hasMetadata { return metadata }
        var merged = [String: Any?]()
        if hasPayload { merged["payload"] = payload }
        if hasMetadata { for (k, v) in metadata! { merged[k] = v } }
        return merged
    }

    /// Trim `value` to nil when blank (matches the Flutter `_trimOrNull`).
    static func trimOrNull(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedCurrency(_ currency: String?) -> String? {
        guard let trimmed = currency?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.uppercased()
    }

    private static func matchesCurrency(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return currencyRegex.firstMatch(in: value, range: range) != nil
    }
}

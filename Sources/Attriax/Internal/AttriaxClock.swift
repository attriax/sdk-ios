import Foundation

/// Time source seam so timestamp-dependent logic stays deterministic in tests.
/// `nowMs()` returns epoch milliseconds (matching the Android `AttriaxClock`),
/// so the retry/backoff/session math is identical to the proven reference.
protocol AttriaxClock {
    func nowMs() -> Int64
}

/// The production system clock.
struct AttriaxSystemClock: AttriaxClock {
    func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

/// UTC ISO-8601 formatting shared by request builders (`clientOccurredAt`, etc.).
/// Matches the Android `SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")` UTC form.
enum AttriaxIso8601 {
    static func string(fromMs ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

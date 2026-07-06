import Foundation

/// Describes a delivery failure independently of the transport implementation,
/// so the retry policy is pure and unit-testable.
enum AttriaxFailure: Equatable {
    /// A non-2xx HTTP response.
    case http(statusCode: Int, retryAfter: String?)
    /// A request timeout (always retryable).
    case timeout
    /// Any other transport/IO failure (always retryable).
    case transport
}

/// Retry / backoff / terminal-drop policy (PARITY §7, rows Q2/Q3/Q4).
///
///  - Retryable: HTTP 408/425/429/≥500, plus timeout & transport errors.
///    Every other 4xx is dropped.
///  - Backoff: `Retry-After` wins; else capped exponential (base 2s, doubling,
///    cap 5min) with a deterministic ±20% jitter derived from `attemptedAt` (no RNG).
///  - Terminal drop: attemptCount ≥ 8 → `max_attempts_exceeded`;
///    age > 7 days → `max_age_exceeded`. Deep-link resolves are EXEMPT.
enum AttriaxRetryPolicy {
    static let maxRetryAttempts = 8
    static let maxRetryAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000 // 7 days
    static let baseBackoffMs: Int64 = 2_000
    static let maxBackoffMs: Int64 = 5 * 60 * 1000 // 5 minutes

    static let reasonMaxAttempts = "max_attempts_exceeded"
    static let reasonMaxAge = "max_age_exceeded"

    static func isRetryableHttpStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500
    }

    static func isRetryable(_ failure: AttriaxFailure) -> Bool {
        switch failure {
        case let .http(statusCode, _): return isRetryableHttpStatus(statusCode)
        case .timeout, .transport: return true
        }
    }

    static func errorClass(_ failure: AttriaxFailure) -> String {
        switch failure {
        case let .http(statusCode, _): return "http_\(statusCode)"
        case .timeout: return "timeout"
        case .transport: return "transport"
        }
    }

    static func httpStatusCode(_ failure: AttriaxFailure) -> Int? {
        if case let .http(statusCode, _) = failure { return statusCode }
        return nil
    }

    /// Capped exponential backoff with deterministic jitter.
    /// - Parameters:
    ///   - attemptedAtMs: epoch millis of this attempt (drives the jitter, no RNG).
    ///   - attemptCount: post-increment attempt number (1 after the first failure).
    /// - Returns: the absolute epoch-millis time of the next retry.
    static func backoffRetryAtMs(attemptedAtMs: Int64, attemptCount: Int) -> Int64 {
        let exponent = min(max(attemptCount - 1, 0), 20)
        let scaledMs = baseBackoffMs * (Int64(1) << exponent)
        let cappedMs = min(maxBackoffMs, scaledMs)
        let jitterRange = Int64((Double(cappedMs) * 0.2))
        let jitterMs = jitterRange == 0 ? 0 : (abs(attemptedAtMs) % (jitterRange + 1))
        return attemptedAtMs + cappedMs + jitterMs
    }

    /// Resolve the `Retry-After` header to an absolute retry time, or nil when
    /// absent/non-positive/unparseable (caller then falls back to backoff).
    /// Supports delta-seconds and the HTTP-date format.
    static func retryAfterAtMs(_ failure: AttriaxFailure, attemptedAtMs: Int64) -> Int64? {
        guard case let .http(_, retryAfter) = failure else { return nil }
        let raw = (retryAfter ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return nil }

        if let seconds = Int64(raw) {
            if seconds <= 0 { return nil }
            return attemptedAtMs + seconds * 1000
        }

        guard let dateMs = parseHttpDateMs(raw) else { return nil }
        return dateMs > attemptedAtMs ? dateMs : nil
    }

    /// `Retry-After` wins, else jittered backoff.
    static func nextRetryAtMs(_ failure: AttriaxFailure, attemptedAtMs: Int64, nextAttemptCount: Int) -> Int64 {
        retryAfterAtMs(failure, attemptedAtMs: attemptedAtMs)
            ?? backoffRetryAtMs(attemptedAtMs: attemptedAtMs, attemptCount: nextAttemptCount)
    }

    /// Terminal-drop reason for a queued request, or nil if it should stay queued.
    /// Deep-link resolves are exempt from terminal drop (row DL5).
    static func terminalDropReason(
        _ request: AttriaxApiRequest,
        attemptCount: Int,
        createdAtMs: Int64,
        nowMs: Int64
    ) -> String? {
        if request.isTerminalDropExempt { return nil }
        if attemptCount >= maxRetryAttempts { return reasonMaxAttempts }
        if nowMs - createdAtMs > maxRetryAgeMs { return reasonMaxAge }
        return nil
    }

    // RFC 7231 IMF-fixdate: "Sun, 06 Nov 1994 08:49:37 GMT"
    private static func parseHttpDateMs(_ value: String) -> Int64? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: value) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

import Foundation

/// Generates UUID-v4-*like* identifiers used for device ids AND queued-request ids
/// (PARITY rows D1 / S1; Flutter `attriax_id_generator.dart:5-16`).
///
/// Format: 16 random bytes rendered lowercase hex, with dashes inserted after
/// bytes 3, 5, 7 and 9. The backend treats the value as opaque, so only the
/// SHAPE matters — this is NOT a spec-compliant UUID.
///
/// `formatId(_:)` is factored out (pure, no RNG) so the exact formatting is
/// unit-testable deterministically on the Mac; production uses secure random
/// bytes via `SecRandomCopyBytes`.
enum AttriaxIdGenerator {
    private static let hex = Array("0123456789abcdef")

    /// Generate a new random id using cryptographically-secure random bytes.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback: SecRandom should not fail, but never crash the host — use
            // arc4random which is also non-deterministic and adequate for an
            // opaque id. (Same shape; only the entropy source differs.)
            for i in bytes.indices { bytes[i] = UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return formatId(bytes)
    }

    /// Render `bytes` as the Attriax id string. Requires exactly 16 bytes.
    /// Pure — no RNG — so format determinism is unit-testable.
    static func formatId(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16, "Attriax id requires exactly 16 bytes, got \(bytes.count)")
        var buffer = String()
        buffer.reserveCapacity(36)
        for (i, byte) in bytes.enumerated() {
            let unsigned = Int(byte)
            buffer.append(hex[unsigned >> 4])
            buffer.append(hex[unsigned & 0x0F])
            if i == 3 || i == 5 || i == 7 || i == 9 {
                buffer.append("-")
            }
        }
        return buffer
    }
}

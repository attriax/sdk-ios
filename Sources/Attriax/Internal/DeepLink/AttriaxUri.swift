import Foundation

/// A tiny, framework-free URI value used by the deep-link core (PARITY §6).
///
/// Rationale: the deep-link normalization/metadata logic (linkPath stripping,
/// query-parameter extraction, Attriax-domain detection) must be pure so it is
/// unit-testable WITHOUT `URLComponents`/`NSURL` edge-case quirks. The thin iOS
/// entry points (`AttriaxDeepLinks.handleUniversalLink` / `handleUrl`) hand the SDK
/// a raw URL string forwarded from the host's AppDelegate/SceneDelegate; parsing
/// happens here.
///
/// This is intentionally minimal — it covers the shapes real deep links take
/// (`scheme://host/path?query`, `https://sub.attriax.com/abc?x=1`, custom
/// `myapp://open/thing`) without aiming to be a full RFC 3986 implementation.
/// Ported byte-for-byte from the proven Android `AttriaxUri`.
struct AttriaxUri: Equatable {
    let raw: String
    let scheme: String?
    let host: String?
    let path: String
    /// Query parameters preserving multiplicity + order (mirrors Dart `queryParametersAll`).
    let queryParametersAll: [String: [String]]

    func isScheme(_ candidate: String) -> Bool {
        guard let scheme = scheme else { return false }
        return scheme.caseInsensitiveCompare(candidate) == .orderedSame
    }

    var stringValue: String { raw }

    /// Parse `rawInput`, returning nil for blank/unparseable input.
    static func parse(_ rawInput: String?) -> AttriaxUri? {
        guard let rawInput = rawInput else { return nil }
        let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }

        var rest = raw
        var scheme: String?

        // scheme:
        if let schemeMatch = schemeRegex.firstMatch(in: rest, options: [], range: NSRange(rest.startIndex..., in: rest)) {
            if let full = Range(schemeMatch.range, in: rest),
               let group = Range(schemeMatch.range(at: 1), in: rest) {
                scheme = String(rest[group]).lowercased()
                rest = String(rest[full.upperBound...])
            }
        }

        // Strip fragment (#...) — not used by resolution.
        if let fragmentIdx = rest.firstIndex(of: "#") {
            rest = String(rest[..<fragmentIdx])
        }

        // Split query.
        var query = ""
        if let queryIdx = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: queryIdx)...])
            rest = String(rest[..<queryIdx])
        }

        var host: String?
        var path: String
        if rest.hasPrefix("//") {
            // authority form: //host[/path]
            let afterSlashes = String(rest.dropFirst(2))
            if let slashIdx = afterSlashes.firstIndex(of: "/") {
                host = stripUserInfoAndPort(String(afterSlashes[..<slashIdx]))
                path = String(afterSlashes[slashIdx...])
            } else {
                host = stripUserInfoAndPort(afterSlashes)
                path = ""
            }
        } else {
            // No authority (custom scheme like `myapp:open/thing`) or relative.
            path = rest
        }

        return AttriaxUri(
            raw: raw,
            scheme: scheme,
            host: host,
            path: path,
            queryParametersAll: parseQuery(query)
        )
    }

    private static func stripUserInfoAndPort(_ authority: String) -> String {
        var a = authority
        if let at = a.lastIndex(of: "@") {
            a = String(a[a.index(after: at)...])
        }
        if let colon = a.firstIndex(of: ":") {
            a = String(a[..<colon])
        }
        return a
    }

    private static func parseQuery(_ query: String) -> [String: [String]] {
        if query.isEmpty { return [:] }
        var result = [String: [String]]()
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pairStr = String(pair)
            let key: String
            let value: String
            if let eq = pairStr.firstIndex(of: "=") {
                key = decode(String(pairStr[..<eq]))
                value = decode(String(pairStr[pairStr.index(after: eq)...]))
            } else {
                key = decode(pairStr)
                value = ""
            }
            result[key, default: []].append(value)
        }
        return result
    }

    private static func decode(_ value: String) -> String {
        if !value.contains("%") && !value.contains("+") { return value }
        var out = String()
        var bytes = [UInt8]()
        func flushBytes() {
            if bytes.isEmpty { return }
            out.append(String(decoding: bytes, as: UTF8.self))
            bytes.removeAll(keepingCapacity: true)
        }
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%" && i + 2 < chars.count {
                let hex = String(chars[(i + 1)...(i + 2)])
                if let b = UInt8(hex, radix: 16) {
                    bytes.append(b)
                    i += 3
                    continue
                }
                flushBytes(); out.append(c); i += 1
            } else if c == "+" {
                flushBytes(); out.append(" "); i += 1
            } else {
                flushBytes(); out.append(c); i += 1
            }
        }
        flushBytes()
        return out
    }

    // swiftlint:disable:next force_try
    private static let schemeRegex = try! NSRegularExpression(pattern: "^([a-zA-Z][a-zA-Z0-9+.-]*):")
}

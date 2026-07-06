import Foundation

/// Pure deep-link resolution helpers (PARITY §6, rows DL2/DL3/DL4). Mirrors the
/// Flutter reference `attriax_deep_link_resolver.dart` and the Android
/// `AttriaxDeepLinkResolver`. Framework-free so link-path normalization,
/// query-parameter metadata, status mapping, and deferred recovery are all
/// unit-testable off-device.
enum AttriaxDeepLinkResolver {

    /// Normalize a link path: trim, strip leading/trailing slashes, collapse to nil
    /// when empty. Mirrors the Dart `normalizeLinkPath` (leading `^/+`, trailing `/+$`).
    static func normalizeLinkPath(_ path: String?) -> String? {
        guard let path = path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        var normalized = trimmed
        while normalized.hasPrefix("/") { normalized.removeFirst() }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized.isEmpty ? nil : normalized
    }

    /// Extract the normalized link path from a URI (Dart `extractLinkPathFromUri`).
    /// For http/https, prefer the path, else fall back to the host. For custom
    /// schemes, join host + path when both present.
    static func extractLinkPathFromUri(_ uri: AttriaxUri) -> String? {
        let normalizedPath = normalizeLinkPath(uri.path)
        if uri.isScheme("http") || uri.isScheme("https") {
            return normalizedPath ?? normalizeLinkPath(uri.host)
        }
        let normalizedHost = normalizeLinkPath(uri.host)
        if let normalizedHost = normalizedHost, let normalizedPath = normalizedPath {
            return normalizeLinkPath("\(normalizedHost)/\(normalizedPath)")
        }
        return normalizedPath ?? normalizedHost
    }

    /// Whether a URI targets an `*.attriax.com` subdomain (case-insensitive).
    static func isAttriaxDomain(_ uri: AttriaxUri) -> Bool {
        let host = (uri.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? ""
        return !host.isEmpty && host.hasSuffix(".attriax.com")
    }

    /// Build the resolve-request metadata (Dart `_handleIncomingLink` metadata):
    /// `isInitialLink` plus flattened `queryParameters` (multi-value preserved as
    /// lists). Manual conversions may override/augment with caller metadata.
    static func buildResolveMetadata(
        _ uri: AttriaxUri,
        isInitialLink: Bool,
        extra: [String: Any?]? = nil
    ) -> [String: Any?] {
        var metadata = AttriaxJSONObject()
        if let extra = extra { for (k, v) in extra { metadata[k] = v } }
        metadata["isInitialLink"] = isInitialLink
        metadata["queryParameters"] = uri.queryParametersAll
        return metadata
    }

    // MARK: - response decoding

    /// Decode a `/deep-links/resolve` response body map into a resolution result.
    static func decodeResolution(_ data: [String: Any?]) -> AttriaxDeepLinkResolutionResult {
        let deepLink = data["deepLink"] as? [String: Any?]
        return AttriaxDeepLinkResolutionResult(
            matched: (data["matched"] as? Bool) ?? false,
            status: AttriaxDeepLinkResolutionStatus.fromWire(data["status"] as? String),
            isFirstLaunch: (data["isFirstLaunch"] as? Bool) ?? false,
            reason: data["reason"] as? String,
            consumedAtMs: nil,
            path: deepLink?["path"] as? String,
            uri: deepLink?["uri"] as? String,
            data: stringMap(deepLink?["data"] ?? nil),
            utm: stringMap(deepLink?["utm"] ?? nil),
            browserAction: decodeBrowserAction(data["browserAction"] ?? nil)
        )
    }

    static func decodeBrowserAction(_ value: Any?) -> AttriaxBrowserAction? {
        guard let map = value as? [String: Any?], let url = map["url"] as? String else { return nil }
        return AttriaxBrowserAction(
            url: url,
            openMode: AttriaxResolvedUrlOpenMode.fromWire(map["openMode"] as? String)
        )
    }

    /// Build the emitted event from a decoded resolution (Dart `buildResolution`).
    static func buildResolution(
        result: AttriaxDeepLinkResolutionResult,
        clickedAtMs: Int64,
        consumedAtMs: Int64,
        trigger: AttriaxDeepLinkTrigger,
        fallbackUri: AttriaxUri,
        rawEvent: AttriaxRawDeepLinkEvent? = nil
    ) -> AttriaxDeepLinkEvent {
        // Prefer the backend canonical URI, then a URI derived from a normalized
        // path (only when a path was actually returned), else the original link.
        let canonical = AttriaxUri.parse(result.uri)
            ?? normalizeLinkPath(result.path).flatMap { AttriaxUri.parse(pathAsUri($0)) }
            ?? fallbackUri
        return AttriaxDeepLinkEvent(
            uri: canonical,
            clickedAtMs: clickedAtMs,
            consumedAtMs: result.consumedAtMs ?? consumedAtMs,
            found: result.matched,
            trigger: trigger,
            isAttriaxSubDomain: isAttriaxDomain(fallbackUri),
            status: result.status,
            rawEvent: rawEvent,
            data: result.data,
            utm: result.utm,
            browserAction: result.browserAction
        )
    }

    static func pathAsUri(_ normalizedPath: String?) -> String {
        guard let normalizedPath = normalizedPath else { return "/" }
        return "/\(normalizedPath)"
    }

    static func stringMap(_ value: Any?) -> [String: String]? {
        guard let map = value as? [String: Any?] else { return nil }
        if map.isEmpty { return nil }
        var out = [String: String]()
        for (k, v) in map {
            if let v = v {
                out[k] = stringify(v)
            } else {
                out[k] = ""
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Stable string coercion matching the reference `v?.toString() ?: ""`.
    private static func stringify(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int64: return String(i)
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case is NSNull: return ""
        default: return String(describing: value)
        }
    }
}

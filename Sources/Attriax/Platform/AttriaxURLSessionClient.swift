import Foundation

/// The single long-lived `URLSession`-backed transport (PARITY §8, rows W1/W2/W3).
///
/// Responsibilities:
///  - stamp the mandatory real User-Agent on EVERY request (load-bearing: the bare
///    form / generator default trips the backend isbot filter and a drifting UA
///    fragments anonymous identity),
///  - `Content-Type: application/json`, config timeouts,
///  - treat 2xx as success and unwrap the `{data: ...}` response envelope,
///  - map non-2xx / timeout / transport failures to `AttriaxTransportError` so the
///    retry policy can classify them.
///
/// One instance per SDK runtime — the `URLSession` connection reuse and the stable
/// UA are shared across all requests. `post` blocks the calling thread using a
/// semaphore so the dispatcher (which runs on its own serial background queue,
/// never the main thread) reasons about delivery sequentially, exactly like the
/// Android OkHttp `execute()` path.
///
/// Certificate pinning (`config.pinnedCertificateSHA256Fingerprints`) is a seam:
/// the fingerprints are accepted but pinning enforcement via
/// `URLSessionDelegate.urlSession(_:didReceive:)` is left for a later hardening
/// pass, matching the Flutter TODO(live) no-op (NOT a parity requirement).
final class AttriaxURLSessionClient: NSObject, AttriaxHttpClient {
    private let baseURL: String
    private let userAgent: String
    private let session: URLSession

    init(baseURL: String, userAgent: String, requestTimeout: TimeInterval) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    func post(_ path: String, _ body: String) throws -> AttriaxHttpResponse {
        guard let url = URL(string: joinURL(baseURL, path)) else {
            throw AttriaxTransportError.transport(underlying: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Set explicitly on the request too (belt-and-braces over the session
        // default), so the load-bearing UA is present on every send.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        let task = session.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = resultError {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                throw AttriaxTransportError.timeout(underlying: error)
            }
            throw AttriaxTransportError.transport(underlying: error)
        }

        guard let httpResponse = resultResponse as? HTTPURLResponse else {
            throw AttriaxTransportError.transport(underlying: nil)
        }

        let headers = Self.headerMap(httpResponse)
        let rawBody = resultData.flatMap { String(data: $0, encoding: .utf8) }

        let status = httpResponse.statusCode
        guard (200..<300).contains(status) else {
            throw AttriaxTransportError.http(statusCode: status, responseBody: rawBody, headers: headers)
        }

        return AttriaxHttpResponse(
            statusCode: status,
            body: unwrapEnvelope(rawBody),
            headers: headers
        )
    }

    /// Unwrap `{ "data": <value> }` → the re-encoded `<value>`; pass through otherwise.
    private func unwrapEnvelope(_ raw: String?) -> String? {
        guard let raw = raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return raw }
        do {
            let decoded = try AttriaxJson.decode(raw)
            if let map = decoded as? [String: Any?], map.keys.contains("data") {
                return AttriaxJson.encode(map["data"].flatMap { $0 })
            }
            return raw
        } catch {
            return raw
        }
    }

    private static func headerMap(_ response: HTTPURLResponse) -> [String: String] {
        var map = [String: String]()
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                map[k] = v
            }
        }
        return map
    }

    private func joinURL(_ base: String, _ path: String) -> String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        let p = path.hasPrefix("/") ? path : "/\(path)"
        return b + p
    }
}

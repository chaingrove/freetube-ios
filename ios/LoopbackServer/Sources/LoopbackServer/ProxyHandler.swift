import Foundation
import FlyingFox

/// `ANY /__yt/<percent-encoded absolute URL>` → upstream request with YouTube's expected headers,
/// body streamed back chunk by chunk.
struct ProxyHandler: HTTPHandler {
    static let pathPrefix = "/__yt/"
    /// Debug only (see `LoopbackConfiguration.debugRulesOverride`); never forwarded upstream.
    static let rulesOverrideHeader = "X-FT-Rules-For"

    let configuration: LoopbackConfiguration
    let upstream: UpstreamSession

    /// Parses the raw (still percent-encoded) request path into the target URL.
    static func targetURL(fromRawPath raw: String) -> URL? {
        guard raw.hasPrefix(pathPrefix) else { return nil }
        let encoded = String(raw.dropFirst(pathPrefix.count))
        guard !encoded.isEmpty, let decoded = encoded.removingPercentEncoding, let url = URL(string: decoded) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let raw = request.target.path()
        guard let url = Self.targetURL(fromRawPath: raw) else {
            return JSONResponses.error(.badRequest, "bad proxy target; expected /__yt/<percent-encoded absolute http(s) URL>")
        }
        if url.scheme?.lowercased() == "http" && !configuration.allowInsecureUpstream {
            return JSONResponses.error(.badRequest, "insecure upstream refused: \(url.absoluteString)")
        }
        guard configuration.allowedHosts.allows(url) else {
            return JSONResponses.error(.forbidden, "host not allowed: \(url.host ?? "?")")
        }

        var incoming: [String: String] = [:]
        var rulesURL = url
        for (header, value) in request.headers {
            if header == HTTPHeader(Self.rulesOverrideHeader) {
                if configuration.debugRulesOverride, let override = URL(string: value) { rulesURL = override }
                continue
            }
            incoming[header.rawValue] = value
        }

        var upstreamRequest = URLRequest(url: url)
        upstreamRequest.httpMethod = request.method.rawValue
        upstreamRequest.httpShouldHandleCookies = false
        upstreamRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let outbound = YouTubeHeaderRules.outboundHeaders(
            for: rulesURL,
            incoming: incoming,
            defaultUserAgent: configuration.defaultUserAgent,
            timeZoneIdentifier: configuration.timeZoneIdentifier
        )
        for (name, value) in outbound {
            upstreamRequest.setValue(value, forHTTPHeaderField: name)
        }
        if request.method != .GET && request.method != .HEAD {
            upstreamRequest.httpBody = try await request.bodyData
        }

        let started = Date()
        let response: HTTPURLResponse
        let stream: UpstreamSession.BodyStream
        do {
            (response, stream) = try await upstream.start(upstreamRequest)
        } catch {
            configuration.log("proxy \(request.method.rawValue) \(url.absoluteString.prefix(120)) failed: \(error)")
            return JSONResponses.error(.badGateway, "upstream request failed: \(error.localizedDescription)")
        }
        configuration.log(String(format: "proxy %@ %@ -> %d in %.0f ms", request.method.rawValue, String(url.absoluteString.prefix(100)), response.statusCode, Date().timeIntervalSince(started) * 1000))

        var upstreamHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String { upstreamHeaders[k] = v }
        }
        let filtered = YouTubeHeaderRules.filteredResponseHeaders(upstreamHeaders)
        var headers = HTTPHeaders()
        for (name, value) in filtered.headers {
            headers[HTTPHeader(name)] = value
        }
        headers[HTTPHeader("X-FT-Proxy")] = "loopback"
        headers[HTTPHeader("X-FT-Upstream-Status")] = String(response.statusCode)

        let status = HTTPStatusCode(response.statusCode, phrase: HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
        let bodyless = request.method == .HEAD || response.statusCode == 204 || response.statusCode == 304 || (100..<200).contains(response.statusCode)
        if bodyless {
            // Dropping `stream` cancels the task via onTermination.
            return HTTPResponse(statusCode: status, headers: headers)
        }

        let chunks = DataChunkSequence(stream: stream)
        let body: HTTPBodySequence
        if let length = filtered.contentLength, length >= 0 {
            body = HTTPBodySequence(from: chunks, count: length, suggestedBufferSize: 65_536)
        } else {
            body = HTTPBodySequence(from: chunks, suggestedBufferSize: 65_536)
        }
        return HTTPResponse(statusCode: status, headers: headers, body: body)
    }
}

enum JSONResponses {
    static func error(_ status: HTTPStatusCode, _ message: String) -> HTTPResponse {
        json(status, ["ok": false, "error": message])
    }

    static func json(_ status: HTTPStatusCode, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: status,
            headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
            body: data
        )
    }
}

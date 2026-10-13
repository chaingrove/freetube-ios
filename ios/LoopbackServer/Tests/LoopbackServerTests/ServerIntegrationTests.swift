import Foundation
import Testing
import FlyingFox
import FlyingSocks
@testable import LoopbackServer

/// End-to-end tests against a real listening socket (port 0 = random), including a local
/// FlyingFox "upstream" so the proxy's streaming and header handling can be observed
/// without touching the network.
@Suite("Loopback server integration", .serialized)
struct ServerIntegrationTests {
    static let token = "feedfacefeedfacefeedfacefeedface"

    /// One running server plus its scratch directories. Always stop it, even on failure.
    struct Fixture {
        let root: URL
        let server: LoopbackServer
        let port: UInt16

        static func make(extraRules: [HostAllowList.Rule] = []) async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-web-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("<!doctype html><title>test</title>hello".utf8).write(to: root.appendingPathComponent("index.html"))
            try Data(repeating: 0x41, count: 100_000).write(to: root.appendingPathComponent("big.bin"))
            try Data("console.log(1)".utf8).write(to: root.appendingPathComponent("app.js"))

            let config = LoopbackConfiguration(
                port: 0,
                webDirectory: root,
                token: token,
                allowedHosts: HostAllowList.youtube.adding(extraRules),
                timeZoneIdentifier: "Europe/Berlin",
                allowInsecureUpstream: true,
                debugRulesOverride: true
            )
            let server = LoopbackServer(configuration: config)
            try await server.start()
            let port = try #require(await server.listeningPort)
            return Fixture(root: root, server: server, port: port)
        }

        func stop() async {
            await server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        func request(_ path: String, method: String = "GET", token: String? = nil, headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            r.httpMethod = method
            if let token { r.setValue(token, forHTTPHeaderField: TokenGate.headerName) }
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            r.httpBody = body
            r.httpShouldHandleCookies = false
            return r
        }

        func fetch(_ r: URLRequest) async throws -> (HTTPURLResponse, Data) {
            let (data, response) = try await URLSession.shared.data(for: r)
            return (try #require(response as? HTTPURLResponse), data)
        }
    }

    static func withServer(extraRules: [HostAllowList.Rule] = [], _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture.make(extraRules: extraRules)
        do {
            try await body(fixture)
        } catch {
            await fixture.stop()
            throw error
        }
        await fixture.stop()
    }

    /// A local FlyingFox upstream on a random loopback port.
    static func withUpstream(_ configure: (HTTPServer) async -> Void, _ body: (UInt16) async throws -> Void) async throws {
        let upstream = HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: 0), logger: .disabled)
        await configure(upstream)
        let task = Task { try await upstream.run() }
        try await upstream.waitUntilListening()
        let port: UInt16? = await upstream.listeningAddress.flatMap { if case .ip4(_, let p) = $0 { return p } else { return nil } }
        do {
            try await body(try #require(port))
        } catch {
            await upstream.stop()
            task.cancel()
            throw error
        }
        await upstream.stop()
        task.cancel()
    }

    /// Captures what the upstream saw.
    actor Seen {
        var headers: [String: String] = [:]
        var method = ""
        var body = Data()
        func record(_ request: HTTPRequest, body: Data) {
            var h: [String: String] = [:]
            for (k, v) in request.headers { h[k.rawValue.lowercased()] = v }
            headers = h
            method = request.method.rawValue
            self.body = body
        }
    }

    // MARK: static files + token

    @Test func requestsWithoutTokenAreRejected() async throws {
        try await Self.withServer { f in
            let (r1, _) = try await f.fetch(f.request("/"))
            #expect(r1.statusCode == 401)
            let (r2, _) = try await f.fetch(f.request("/", token: "wrong"))
            #expect(r2.statusCode == 401)
            let (r3, _) = try await f.fetch(f.request("/__yt/https%3A%2F%2Fwww.youtube.com%2F"))
            #expect(r3.statusCode == 401)
        }
    }

    @Test func staticFilesWithQueryTokenSetCookieAndMime() async throws {
        try await Self.withServer { f in
            let (r, data) = try await f.fetch(f.request("/?ft=\(Self.token)"))
            #expect(r.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == "<!doctype html><title>test</title>hello")
            #expect(r.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")
            #expect(r.value(forHTTPHeaderField: "Set-Cookie") == "ft=\(Self.token); Path=/; SameSite=Strict; HttpOnly")

            let (js, _) = try await f.fetch(f.request("/app.js", token: Self.token))
            #expect(js.value(forHTTPHeaderField: "Content-Type") == "text/javascript; charset=utf-8")
            #expect(js.value(forHTTPHeaderField: "Set-Cookie") == nil, "header-authorised requests do not re-set the cookie")

            let (cookie, _) = try await f.fetch(f.request("/app.js", headers: ["Cookie": "ft=\(Self.token)"]))
            #expect(cookie.statusCode == 200)
        }
    }

    @Test func staticRangeRequests() async throws {
        try await Self.withServer { f in
            let (r, data) = try await f.fetch(f.request("/big.bin", token: Self.token, headers: ["Range": "bytes=10-19"]))
            #expect(r.statusCode == 206)
            #expect(data.count == 10)
            #expect(r.value(forHTTPHeaderField: "Content-Range") == "bytes 10-19/100000")
            #expect(r.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")

            let (full, all) = try await f.fetch(f.request("/big.bin", token: Self.token))
            #expect(full.statusCode == 200)
            #expect(all.count == 100_000)
            #expect(full.value(forHTTPHeaderField: "Content-Length") == "100000")

            let (missing, _) = try await f.fetch(f.request("/nope.txt", token: Self.token))
            #expect(missing.statusCode == 404)
        }
    }

    // MARK: proxy

    @Test func proxyRejectsBadAndDisallowedTargets() async throws {
        try await Self.withServer { f in
            let (bad, _) = try await f.fetch(f.request("/__yt/not-a-url", token: Self.token))
            #expect(bad.statusCode == 400)
            let (denied, body) = try await f.fetch(f.request("/__yt/https%3A%2F%2Fexample.com%2F", token: Self.token))
            #expect(denied.statusCode == 403)
            #expect(String(decoding: body, as: UTF8.self).contains("host not allowed"))
        }
    }

    /// Local upstream: `/slow` sends three 1000-byte chunks 400 ms apart via chunked encoding.
    /// The proxied client must see the first bytes long before the last ones, which proves the
    /// URLSessionDataDelegate → FlyingFox body path streams instead of buffering.
    @Test func proxyStreamsChunksProgressively() async throws {
        try await Self.withUpstream({ upstream in
            await upstream.appendRoute("GET /slow") { _ in
                let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
                Task {
                    for i in 0..<3 {
                        if i > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
                        continuation.yield(Data(repeating: UInt8(0x30 + i), count: 1000))
                    }
                    continuation.finish()
                }
                return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/octet-stream"], body: HTTPBodySequence(from: DataChunkSequence(stream: stream)))
            }
        }) { upstreamPort in
            try await Self.withServer(extraRules: [HostAllowList.Rule(host: .exact("127.0.0.1"))]) { f in
                let target = "http://127.0.0.1:\(upstreamPort)/slow".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                let (bytes, response) = try await URLSession.shared.bytes(for: f.request("/__yt/\(target)", token: Self.token))
                let http = try #require(response as? HTTPURLResponse)
                #expect(http.statusCode == 200)
                #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
                #expect(http.value(forHTTPHeaderField: "Content-Length") == nil, "unknown length must be chunked")

                let start = Date()
                var firstByteAt: TimeInterval?
                var count = 0
                for try await _ in bytes {
                    if firstByteAt == nil { firstByteAt = Date().timeIntervalSince(start) }
                    count += 1
                }
                let lastByteAt = Date().timeIntervalSince(start)
                #expect(count == 3000)
                let first = try #require(firstByteAt)
                #expect(lastByteAt - first > 0.5, "first byte at \(first)s, last at \(lastByteAt)s: body was buffered, not streamed")
            }
        }
    }

    /// Local upstream `/echo` reports the headers and body it received, so we can see exactly what
    /// URLSession put on the wire after the header rules ran.
    @Test func proxyForwardsMethodBodyRangeAndRewritesHeaders() async throws {
        let seen = Seen()
        try await Self.withUpstream({ upstream in
            await upstream.appendRoute("POST /echo") { request in
                let body = try await request.bodyData
                await seen.record(request, body: body)
                return HTTPResponse(
                    statusCode: .partialContent,
                    headers: [.contentType: "audio/mp4", .contentRange: "bytes 0-9/100", .setCookie: "tracker=1", HTTPHeader("Content-Security-Policy"): "x", HTTPHeader("X-Upstream"): "yes"],
                    body: Data("0123456789".utf8)
                )
            }
        }) { upstreamPort in
            try await Self.withServer(extraRules: [HostAllowList.Rule(host: .exact("127.0.0.1"))]) { f in
                let target = "http://127.0.0.1:\(upstreamPort)/echo".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                let (r, data) = try await f.fetch(f.request("/__yt/\(target)", method: "POST", token: Self.token, headers: [
                    "Range": "bytes=0-9", "Content-Type": "application/json", "X-Youtube-Client-Name": "1",
                    "Cookie": "ft=\(Self.token); leaked=1", "Origin": "http://127.0.0.1:\(f.port)", "User-Agent": "WebView",
                ], body: Data(#"{"q":1}"#.utf8)))

                #expect(r.statusCode == 206)
                #expect(data == Data("0123456789".utf8))
                #expect(r.value(forHTTPHeaderField: "Content-Range") == "bytes 0-9/100")
                #expect(r.value(forHTTPHeaderField: "Content-Length") == "10")
                #expect(r.value(forHTTPHeaderField: "X-Upstream") == "yes")
                #expect(r.value(forHTTPHeaderField: "Set-Cookie") == nil)
                #expect(r.value(forHTTPHeaderField: "Content-Security-Policy") == nil)

                let headers = await seen.headers
                #expect(await seen.method == "POST")
                #expect(await seen.body == Data(#"{"q":1}"#.utf8))
                #expect(headers["range"] == "bytes=0-9")
                #expect(headers["content-type"] == "application/json")
                #expect(headers["x-youtube-client-name"] == "1")
                #expect(headers["user-agent"] == LoopbackConfiguration.desktopSafariUserAgent, "URLSession must send the User-Agent we set")
                #expect(headers["cookie"] == nil, "the WebView's cookies must never reach upstream")
                #expect(headers["origin"] == nil)
                #expect(headers["x-ft-token"] == nil)
            }
        }
    }

    /// Does Foundation's URLSession put the spoofed
    /// Origin, Referer, Cookie, User-Agent and Sec-Fetch-* headers on the wire unchanged?
    /// Apply the InnerTube rules (via the debug override) to a request that lands on a local
    /// echo upstream and look at what actually arrived.
    @Test func urlSessionSendsSpoofedYouTubeHeadersUnchanged() async throws {
        let seen = Seen()
        try await Self.withUpstream({ upstream in
            await upstream.appendRoute("POST /echo") { request in
                await seen.record(request, body: try await request.bodyData)
                return HTTPResponse(statusCode: .ok)
            }
        }) { upstreamPort in
            try await Self.withServer(extraRules: [HostAllowList.Rule(host: .exact("127.0.0.1"))]) { f in
                let target = "http://127.0.0.1:\(upstreamPort)/echo".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                let (r, _) = try await f.fetch(f.request("/__yt/\(target)", method: "POST", token: Self.token, headers: [
                    "Content-Type": "application/json",
                    "X-FT-Rules-For": "https://www.youtube.com/youtubei/v1/search?prettyPrint=false",
                ], body: Data("{}".utf8)))
                #expect(r.statusCode == 200)
                let h = await seen.headers
                #expect(h["origin"] == "https://www.youtube.com")
                #expect(h["referer"] == "https://www.youtube.com/")
                #expect(h["cookie"] == "CONSENT=YES+; SOCS=CAI")
                #expect(h["user-agent"] == LoopbackConfiguration.desktopSafariUserAgent)
                #expect(h["sec-fetch-site"] == "same-origin")
                #expect(h["sec-fetch-mode"] == "same-origin")
                #expect(h["x-youtube-bootstrap-logged-in"] == "false")
                #expect(h["x-ft-rules-for"] == nil)

                let (w, _) = try await f.fetch(f.request("/__yt/\(target)", method: "POST", token: Self.token, headers: [
                    "X-FT-Rules-For": "https://www.youtube.com/watch?v=abc",
                ], body: Data("{}".utf8)))
                #expect(w.statusCode == 200)
                let wh = await seen.headers
                #expect(wh["cookie"] == "CONSENT=YES+; SOCS=CAI; PREF=tz=Europe.Berlin")
                #expect(wh["origin"] == nil)
                #expect(wh["referer"] == nil)
                #expect(wh["sec-fetch-mode"] == "navigate")
                #expect(wh["sec-fetch-user"] == "?1")
            }
        }
    }
}

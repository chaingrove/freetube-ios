import Foundation
import Testing
@testable import LoopbackServer

@Suite("Host allow list")
struct HostAllowListTests {
    let list = HostAllowList.youtube

    func allows(_ s: String) -> Bool { list.allows(URL(string: s)!) }

    @Test func youTubeFamilyIsAllowed() {
        #expect(allows("https://www.youtube.com/youtubei/v1/search"))
        #expect(allows("https://youtube.com/"))
        #expect(allows("https://rr3---sn-x.googlevideo.com/videoplayback?x=1"))
        #expect(allows("https://i.ytimg.com/vi/a/b.jpg"))
        #expect(allows("https://yt3.ggpht.com/x"))
        #expect(allows("https://lh3.googleusercontent.com/x"))
        #expect(allows("https://www.google.com/js/bg/abc.js"))
    }

    @Test func everythingElseIsDenied() {
        #expect(!allows("https://example.com/"))
        #expect(!allows("https://youtube.com.evil.example/"))
        #expect(!allows("https://notyoutube.com/"))
        #expect(!allows("https://www.google.com/search?q=x"))
        #expect(!allows("https://google.com/js/x"))
        #expect(!allows("https://storage.googleapis.com/other-bucket/x.mpd"))
    }
}

@Suite("Token gate")
struct TokenGateTests {
    let gate = TokenGate(token: "0123456789abcdef0123456789abcdef")

    @Test func acceptsHeaderQueryAndCookie() {
        #expect(gate.authorize(headerValue: gate.token, queryValue: nil, cookieHeader: nil) == .header)
        #expect(gate.authorize(headerValue: nil, queryValue: gate.token, cookieHeader: nil) == .query)
        #expect(gate.authorize(headerValue: nil, queryValue: nil, cookieHeader: "a=b; ft=\(gate.token); c=d") == .cookie)
    }

    @Test func rejectsMissingOrWrong() {
        #expect(gate.authorize(headerValue: nil, queryValue: nil, cookieHeader: nil) == nil)
        #expect(gate.authorize(headerValue: "nope", queryValue: "nope", cookieHeader: "ft=nope") == nil)
        #expect(gate.authorize(headerValue: String(gate.token.dropLast()), queryValue: nil, cookieHeader: nil) == nil)
        #expect(gate.authorize(headerValue: nil, queryValue: nil, cookieHeader: "xft=\(gate.token)") == nil)
    }

    @Test func makeTokenIs32Hex() {
        let t = TokenGate.makeToken()
        #expect(t.count == 32)
        #expect(t.allSatisfy { $0.isHexDigit })
        #expect(t != TokenGate.makeToken())
    }

    @Test func setCookieValue() {
        #expect(gate.setCookieValue == "ft=\(gate.token); Path=/; SameSite=Strict; HttpOnly")
    }
}

@Suite("Proxy target parsing")
struct ProxyTargetTests {
    @Test func decodesPercentEncodedAbsoluteURL() {
        let raw = "/__yt/https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc%26t%3D1s"
        #expect(ProxyHandler.targetURL(fromRawPath: raw)?.absoluteString == "https://www.youtube.com/watch?v=abc&t=1s")
    }

    @Test func rejectsMalformedTargets() {
        #expect(ProxyHandler.targetURL(fromRawPath: "/__yt/") == nil)
        #expect(ProxyHandler.targetURL(fromRawPath: "/__yt/not-a-url") == nil)
        #expect(ProxyHandler.targetURL(fromRawPath: "/__yt/ftp%3A%2F%2Fexample.com%2F") == nil)
        #expect(ProxyHandler.targetURL(fromRawPath: "/other/https%3A%2F%2Fwww.youtube.com%2F") == nil)
    }
}

@Suite("Static files")
struct StaticFileTests {
    @Test func resolveStaysInsideRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-static-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hi".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("x".utf8).write(to: root.appendingPathComponent("sub/index.html"))
        let handler = StaticFileHandler(root: root)

        #expect(handler.resolve(requestPath: "/")?.lastPathComponent == "index.html")
        #expect(handler.resolve(requestPath: "/sub")?.path == root.appendingPathComponent("sub/index.html").standardizedFileURL.path)
        #expect(handler.resolve(requestPath: "/sub/")?.lastPathComponent == "index.html")
        #expect(handler.resolve(requestPath: "/missing.js") == nil)
        #expect(handler.resolve(requestPath: "/../") == nil)
        #expect(handler.resolve(requestPath: "/../../etc/passwd") == nil)
    }

    @Test func contentTypes() {
        #expect(StaticFileHandler.contentType(for: URL(fileURLWithPath: "/a/b.js")) == "text/javascript; charset=utf-8")
        #expect(StaticFileHandler.contentType(for: URL(fileURLWithPath: "/a/b.mpd")) == "application/dash+xml")
        #expect(StaticFileHandler.contentType(for: URL(fileURLWithPath: "/a/b.m4s")) == "video/iso.segment")
        #expect(StaticFileHandler.contentType(for: URL(fileURLWithPath: "/a/b.unknownext")) == "application/octet-stream")
    }
}

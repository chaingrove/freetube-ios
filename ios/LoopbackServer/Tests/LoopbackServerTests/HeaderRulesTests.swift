import Foundation
import Testing
@testable import LoopbackServer

// Swift Testing (not XCTest): the macOS Command Line Tools ship Testing.framework but no XCTest,
// and this package must `swift test` without Xcode. Run with:
//     swift test --disable-xctest --enable-swift-testing

@Suite("YouTube header rules (port of src/main/index.js:558-666)")
struct HeaderRulesTests {
    let ua = LoopbackConfiguration.desktopSafariUserAgent
    let tz = "America/New_York"

    func outbound(_ url: String, incoming: [String: String] = [:]) -> [String: String] {
        YouTubeHeaderRules.outboundHeaders(for: URL(string: url)!, incoming: incoming, defaultUserAgent: ua, timeZoneIdentifier: tz)
    }

    @Test func innerTubeRequestGetsYouTubeOriginRefererAndLoggedOutMarker() {
        let h = outbound("https://www.youtube.com/youtubei/v1/search?prettyPrint=false", incoming: [
            "Content-Type": "application/json",
            "X-Youtube-Client-Name": "1",
            "Cookie": "leaked=1",
            "Origin": "http://127.0.0.1:17173",
            "Referer": "http://127.0.0.1:17173/",
            "User-Agent": "WebKitWhatever",
            "X-FT-Token": "secret",
        ])
        #expect(h["Referer"] == "https://www.youtube.com/")
        #expect(h["Origin"] == "https://www.youtube.com")
        #expect(h["Sec-Fetch-Site"] == "same-origin")
        #expect(h["Sec-Fetch-Mode"] == "same-origin")
        #expect(h["X-Youtube-Bootstrap-Logged-In"] == "false")
        #expect(h["Cookie"] == "CONSENT=YES+; SOCS=CAI")
        #expect(h["Content-Type"] == "application/json")
        #expect(h["X-Youtube-Client-Name"] == "1")
        #expect(h["User-Agent"] == ua)
        #expect(h["X-Ft-Token"] == nil)
        #expect(h["X-FT-Token"] == nil)
    }

    @Test func watchPageLooksLikeNavigationWithPrefCookie() {
        let h = outbound("https://www.youtube.com/watch?v=abc&bpctr=9999999999&has_verified=1", incoming: [
            "Referer": "http://127.0.0.1:17173/", "Origin": "http://127.0.0.1:17173", "Accept-Language": "en-US",
        ])
        #expect(h["Referer"] == nil)
        #expect(h["Origin"] == nil)
        #expect(h["Sec-Fetch-Dest"] == "document")
        #expect(h["Sec-Fetch-Mode"] == "navigate")
        #expect(h["Sec-Fetch-Site"] == "none")
        #expect(h["Sec-Fetch-User"] == "?1")
        #expect(h["Cookie"] == "CONSENT=YES+; SOCS=CAI; PREF=tz=America.New_York")
        #expect(h["Accept-Language"] == "en-US")
    }

    @Test func homePageIsTreatedLikeWatchPage() {
        let h = outbound("https://www.youtube.com/")
        #expect(h["Sec-Fetch-Mode"] == "navigate")
        #expect(h["Cookie"]?.contains("PREF=tz=") == true)
    }

    @Test(arguments: ["https://www.youtube.com/api/timedtext?v=abc&lang=en", "https://www.youtube.com/sw.js_data"])
    func timedTextAndSwJsDataUseServiceWorkerReferer(url: String) {
        let h = outbound(url)
        #expect(h["Referer"] == "https://www.youtube.com/sw.js")
        #expect(h["Sec-Fetch-Site"] == "same-origin")
        #expect(h["Origin"] == nil)
    }

    @Test(arguments: ["https://i.ytimg.com/vi/abc/hqdefault.jpg", "https://yt3.ggpht.com/x", "https://lh3.googleusercontent.com/y"])
    func imageHostsGetYouTubeReferer(url: String) {
        let h = outbound(url)
        #expect(h["Referer"] == "https://www.youtube.com/")
        #expect(h["Origin"] == "https://www.youtube.com")
        #expect(h["Cookie"] == nil)
    }

    @Test func videoplaybackDropsContentTypeAndSetsOrigin() {
        let h = outbound("https://rr3---sn-x.googlevideo.com/videoplayback?expire=1&itag=140", incoming: [
            "Content-Type": "application/x-protobuf", "Range": "bytes=0-1023",
        ])
        #expect(h["Content-Type"] == nil)
        #expect(h["Range"] == "bytes=0-1023")
        #expect(h["Referer"] == "https://www.youtube.com/")
        #expect(h["Origin"] == "https://www.youtube.com")
        #expect(h["Cookie"] == nil)
    }

    @Test func otherYouTubePathsOnlyGetConsentCookies() {
        let h = outbound("https://www.youtube.com/s/player/4fd832e7/player_es6.vflset/en_US/base.js")
        #expect(h["Cookie"] == "CONSENT=YES+; SOCS=CAI")
        #expect(h["Referer"] == nil)
        #expect(h["Origin"] == nil)
        #expect(h["Sec-Fetch-Mode"] == nil)
    }

    @Test func pageCannotChooseTheUserAgent() {
        let h = outbound("https://www.youtube.com/youtubei/v1/player", incoming: ["X-FT-User-Agent": "com.google.ios.youtube/20.10.38", "User-Agent": "WebView"])
        #expect(h["User-Agent"] == ua)
        #expect(h["X-Ft-User-Agent"] == nil)
    }

    @Test func hopByHopAndForbiddenIncomingHeadersAreDropped() {
        let h = outbound("https://www.google.com/js/bg/x.js", incoming: [
            "Host": "127.0.0.1:17173", "Connection": "keep-alive", "Accept-Encoding": "gzip", "Content-Length": "12",
            "Sec-Fetch-Dest": "empty", "Cookie": "ft=secret", "Accept": "*/*",
        ])
        #expect(h["Accept"] == "*/*")
        #expect(h["User-Agent"] == ua)
        #expect(h.count == 2, "\(h)")
    }

    @Test func responseFilterDropsTrackingAndEncodingHeaders() {
        let (headers, length) = YouTubeHeaderRules.filteredResponseHeaders([
            "Content-Type": "text/html; charset=utf-8",
            "Set-Cookie": "VISITOR_INFO1_LIVE=x; Path=/",
            "Content-Security-Policy": "default-src 'self'",
            "Content-Security-Policy-Report-Only": "x",
            "Cross-Origin-Opener-Policy": "same-origin",
            "Report-To": "{}",
            "Reporting-Endpoints": "x",
            "Content-Encoding": "gzip",
            "Content-Length": "12345",
            "Transfer-Encoding": "chunked",
            "X-Content-Type-Options": "nosniff",
            "Accept-Ranges": "bytes",
        ])
        #expect(headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(headers["X-Content-Type-Options"] == "nosniff")
        #expect(headers["Accept-Ranges"] == "bytes")
        for dropped in ["Set-Cookie", "Content-Security-Policy", "Content-Security-Policy-Report-Only", "Cross-Origin-Opener-Policy", "Report-To", "Reporting-Endpoints", "Content-Encoding", "Content-Length", "Transfer-Encoding"] {
            #expect(headers[dropped] == nil, "\(dropped) must be dropped")
        }
        #expect(length == nil, "gzip body: upstream Content-Length must not be reused")
    }

    @Test func responseFilterKeepsLengthForIdentityBodies() {
        let (headers, length) = YouTubeHeaderRules.filteredResponseHeaders([
            "content-type": "audio/mp4", "content-length": "1024", "content-range": "bytes 0-1023/5000",
        ])
        #expect(length == 1024)
        #expect(headers["Content-Range"] == "bytes 0-1023/5000")
        #expect(headers["Content-Length"] == nil)
    }

    @Test func prefTimeZoneReplacesFirstSlashOnly() {
        #expect(YouTubeHeaderRules.prefCookieTimeZone("Europe/Berlin") == "Europe.Berlin")
        #expect(YouTubeHeaderRules.prefCookieTimeZone("America/Argentina/Buenos_Aires") == "America.Argentina/Buenos_Aires")
        #expect(YouTubeHeaderRules.prefCookieTimeZone("UTC") == "UTC")
    }
}

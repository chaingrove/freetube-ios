import Foundation

/// Port of the desktop app's request/response header hygiene, `src/main/index.js:558-666`:
///
/// - `:558-562`  strip app identifiers from the User-Agent (here: replace it with a desktop Safari UA)
/// - `:564-583`  plant `CONSENT=YES+` and `SOCS=CAI` cookies for youtube.com
/// - `:585-644`  `onBeforeSendHeaders`: per-URL Referer / Origin / Sec-Fetch-* / X-Youtube-Bootstrap-Logged-In,
///                `PREF=tz=` cookie on the watch page, drop Content-Type on /videoplayback
/// - `:646-666`  `onHeadersReceived`: drop set-cookie, CSP, COOP, report-to, reporting-endpoints
///
/// These are pure functions on plain dictionaries so they can be unit tested without a server.
public enum YouTubeHeaderRules {
    public static let youtubeOrigin = "https://www.youtube.com"
    public static let youtubeReferer = "https://www.youtube.com/"
    public static let consentCookies = "CONSENT=YES+; SOCS=CAI"

    /// Request headers copied from the WebView's request to the upstream request.
    /// Everything else is dropped: `Cookie`, `Origin`, `Referer`, `Sec-Fetch-*`, `User-Agent`,
    /// `Host`, `Connection`, `Content-Length`, `Accept-Encoding` (URLSession manages those) and `X-FT-*`.
    static let forwardedRequestHeaders: Set<String> = [
        "accept", "accept-language", "content-type", "range",
        "if-none-match", "if-modified-since", "if-range",
    ]
    static let forwardedRequestHeaderPrefixes = ["x-youtube-", "x-goog-"]

    /// Response headers never passed back to the WebView.
    /// `content-encoding` and `content-length` go because URLSession already decoded the body.
    static let droppedResponseHeaders: Set<String> = [
        "set-cookie", "set-cookie2",
        "content-security-policy", "content-security-policy-report-only",
        "cross-origin-opener-policy", "cross-origin-embedder-policy", "cross-origin-resource-policy",
        "report-to", "reporting-endpoints", "nel",
        "content-encoding", "content-length", "transfer-encoding",
        "connection", "keep-alive", "strict-transport-security", "alt-svc",
        "x-frame-options",
    ]

    public struct Outbound: Sendable, Equatable {
        public var headers: [String: String]
    }

    /// Builds the upstream request headers for `url` from the WebView's `incoming` headers.
    public static func outboundHeaders(
        for url: URL,
        incoming: [String: String],
        defaultUserAgent: String,
        timeZoneIdentifier: String
    ) -> [String: String] {
        var out: [String: String] = [:]

        for (name, value) in incoming {
            let lower = name.lowercased()
            if forwardedRequestHeaders.contains(lower) || forwardedRequestHeaderPrefixes.contains(where: { lower.hasPrefix($0) }) {
                out[canonical(name)] = value
            }
        }

        out["User-Agent"] = defaultUserAgent

        let absolute = url.absoluteString
        let host = (url.host ?? "").lowercased()
        let path = url.path.isEmpty ? "/" : url.path
        let isYouTube = host == "youtube.com" || host.hasSuffix(".youtube.com")

        if absolute.hasPrefix("https://www.youtube.com/youtubei/") {
            // index.js:592-600: make InnerTube requests work with fetch
            out["Referer"] = youtubeReferer
            out["Origin"] = youtubeOrigin
            out["Sec-Fetch-Site"] = "same-origin"
            out["Sec-Fetch-Mode"] = "same-origin"
            out["X-Youtube-Bootstrap-Logged-In"] = "false"
            out["Cookie"] = consentCookies
        } else if absolute.hasPrefix("https://www.youtube.com/watch") || (host == "www.youtube.com" && path == "/") {
            // index.js:601-613: the watch page and home page look like a top-level navigation
            out.removeValue(forKey: "Referer")
            out.removeValue(forKey: "Origin")
            out["Sec-Fetch-Dest"] = "document"
            out["Sec-Fetch-Mode"] = "navigate"
            out["Sec-Fetch-Site"] = "none"
            out["Sec-Fetch-User"] = "?1"
            out["Cookie"] = consentCookies + "; PREF=tz=" + prefCookieTimeZone(timeZoneIdentifier)
        } else if absolute == "https://www.youtube.com/sw.js_data" || absolute.hasPrefix("https://www.youtube.com/api/timedtext") {
            // index.js:614-617
            out["Referer"] = "https://www.youtube.com/sw.js"
            out["Sec-Fetch-Site"] = "same-origin"
            out["Sec-Fetch-Mode"] = "same-origin"
            out["Cookie"] = consentCookies
        } else if host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".ggpht.com") || host.hasSuffix(".ytimg.com") {
            // index.js:618-624
            out["Referer"] = youtubeReferer
            out["Origin"] = youtubeOrigin
        } else if host.hasSuffix(".googlevideo.com") && path == "/videoplayback" {
            // index.js:625-630: YouTube does not send Content-Type for media requests, so neither do we
            out["Referer"] = youtubeReferer
            out["Origin"] = youtubeOrigin
            out.removeValue(forKey: "Content-Type")
        } else if isYouTube {
            // index.js:564-583: the desktop session's cookie jar sends the consent cookies on every youtube.com request
            out["Cookie"] = consentCookies
        }

        return out
    }

    /// Filters upstream response headers for the WebView and extracts a usable Content-Length.
    /// Returns `contentLength` only when the body was not content-encoded (URLSession has already
    /// decoded gzip/br bodies, so the upstream length would be wrong).
    public static func filteredResponseHeaders(_ upstream: [String: String]) -> (headers: [String: String], contentLength: Int?) {
        var out: [String: String] = [:]
        var contentLength: Int?
        var encoded = false

        for (name, value) in upstream {
            let lower = name.lowercased()
            if lower == "content-encoding", !value.trimmingCharacters(in: .whitespaces).isEmpty, value.lowercased() != "identity" {
                encoded = true
            }
            if lower == "content-length" {
                contentLength = Int(value.trimmingCharacters(in: .whitespaces))
            }
            if droppedResponseHeaders.contains(lower) { continue }
            out[canonical(name)] = value
        }

        return (out, encoded ? nil : contentLength)
    }

    /// `Intl.DateTimeFormat().resolvedOptions().timeZone.replace('/', '.')` replaces only the first slash.
    public static func prefCookieTimeZone(_ identifier: String) -> String {
        guard let slash = identifier.firstIndex(of: "/") else { return identifier }
        return identifier.replacingCharacters(in: slash...slash, with: ".")
    }

    /// Normalises header-name casing so the same header is never emitted twice with different case.
    static func canonical(_ name: String) -> String {
        name.split(separator: "-", omittingEmptySubsequences: false)
            .map { part -> String in
                guard let first = part.first else { return "" }
                return String(first).uppercased() + part.dropFirst().lowercased()
            }
            .joined(separator: "-")
    }
}

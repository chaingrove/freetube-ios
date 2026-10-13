import Foundation

/// Everything the loopback server needs to know. Built once per app launch.
public struct LoopbackConfiguration: Sendable {
    /// Fixed port declared in `capacitor.config.json` as `server.url = http://127.0.0.1:17173`.
    /// It is part of the page's origin, so changing it loses the app's stored data.
    public static let defaultPort: UInt16 = 17173

    /// Desktop Safari user agent. YouTube must see a desktop-class UA or it serves the mobile
    /// site, which breaks the regexes FreeTube runs over the watch page.
    public static let desktopSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    public var port: UInt16
    /// Directory with the static web bundle (Capacitor's `public/` folder in the app bundle).
    public var webDirectory: URL
    /// Per-launch secret. Every request must carry it (header, `?ft=` query or cookie).
    public var token: String
    /// Hosts the `/__yt/` proxy may talk to.
    public var allowedHosts: HostAllowList
    /// User agent sent upstream.
    public var defaultUserAgent: String
    /// Used for the `PREF=tz=` cookie on watch-page requests, like the desktop app.
    public var timeZoneIdentifier: String
    /// Tests only: let the proxy talk to plain `http://` upstreams.
    public var allowInsecureUpstream: Bool
    /// Tests only: honour `X-FT-Rules-For: <url>` so the YouTube header rules for that URL are
    /// applied to a request that is actually sent to a local echo server. This is how the tests
    /// show, on the wire, that URLSession sends the spoofed Origin/Referer/Cookie/User-Agent unchanged.
    public var debugRulesOverride: Bool
    /// Log sink.
    public var log: @Sendable (String) -> Void

    public init(
        port: UInt16 = LoopbackConfiguration.defaultPort,
        webDirectory: URL,
        token: String = TokenGate.makeToken(),
        allowedHosts: HostAllowList = .youtube,
        defaultUserAgent: String = LoopbackConfiguration.desktopSafariUserAgent,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        allowInsecureUpstream: Bool = false,
        debugRulesOverride: Bool = false,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.port = port
        self.webDirectory = webDirectory
        self.token = token
        self.allowedHosts = allowedHosts
        self.defaultUserAgent = defaultUserAgent
        self.timeZoneIdentifier = timeZoneIdentifier
        self.allowInsecureUpstream = allowInsecureUpstream
        self.debugRulesOverride = debugRulesOverride
        self.log = log
    }
}

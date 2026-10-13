import Foundation

/// Which upstream hosts the `/__yt/` proxy is willing to contact.
public struct HostAllowList: Sendable, Equatable {
    public struct Rule: Sendable, Equatable {
        public enum HostMatch: Sendable, Equatable {
            /// Host must equal this string (case-insensitive).
            case exact(String)
            /// Host must end with this string, e.g. ".youtube.com" matches "www.youtube.com".
            case suffix(String)
        }

        public var host: HostMatch
        /// When set, the URL path must start with this prefix (e.g. "/js/" on www.google.com).
        public var pathPrefix: String?
        public var note: String

        public init(host: HostMatch, pathPrefix: String? = nil, note: String = "") {
            self.host = host
            self.pathPrefix = pathPrefix
            self.note = note
        }

        func matches(host: String, path: String) -> Bool {
            let h = host.lowercased()
            let hostOK: Bool
            switch self.host {
            case .exact(let value):
                hostOK = h == value.lowercased()
            case .suffix(let value):
                hostOK = h.hasSuffix(value.lowercased())
            }
            guard hostOK else { return false }
            if let prefix = pathPrefix {
                return path.hasPrefix(prefix)
            }
            return true
        }
    }

    public var rules: [Rule]

    public init(rules: [Rule]) {
        self.rules = rules
    }

    /// A registrable domain and every subdomain of it.
    public static func domain(_ name: String, note: String = "") -> [Rule] {
        [
            Rule(host: .exact(name), note: note),
            Rule(host: .suffix("." + name), note: note),
        ]
    }

    public func allows(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return rules.contains { $0.matches(host: host, path: path) }
    }

    public func adding(_ extra: [Rule]) -> HostAllowList {
        HostAllowList(rules: rules + extra)
    }

    /// The hosts FreeTube's direct client talks to.
    public static let youtube = HostAllowList(rules:
        domain("youtube.com", note: "InnerTube, watch page, player JS, captions")
        + domain("googlevideo.com", note: "media (/videoplayback, SABR)")
        + domain("ytimg.com", note: "thumbnails, player assets")
        + domain("ggpht.com", note: "avatars")
        + domain("googleusercontent.com", note: "images")
        + [Rule(host: .exact("www.google.com"), pathPrefix: "/js/", note: "BotGuard interpreter")]
    )
}

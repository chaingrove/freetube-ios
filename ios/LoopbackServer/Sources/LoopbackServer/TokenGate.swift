import Foundation

/// Per-launch shared secret. Anything on the phone can connect to 127.0.0.1:17173; only the
/// WebView knows the token (it is in the initial page URL), so only the WebView can use the proxy.
public struct TokenGate: Sendable, Equatable {
    public static let headerName = "X-FT-Token"
    public static let queryName = "ft"
    public static let cookieName = "ft"

    public enum Source: Sendable, Equatable {
        case header, query, cookie
    }

    public let token: String

    public init(token: String) {
        self.token = token
    }

    /// 128 random bits as 32 hex characters.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in
            String(UInt64.random(in: UInt64.min...UInt64.max, using: &generator), radix: 16)
        }.map { String(repeating: "0", count: max(0, 16 - $0.count)) + $0 }.joined()
    }

    /// Returns where a valid token was found, or nil if the request is not authorised.
    public func authorize(headerValue: String?, queryValue: String?, cookieHeader: String?) -> Source? {
        if let headerValue, constantTimeEquals(headerValue, token) { return .header }
        if let queryValue, constantTimeEquals(queryValue, token) { return .query }
        if let cookieHeader, let cookie = Self.cookieValue(named: Self.cookieName, in: cookieHeader), constantTimeEquals(cookie, token) {
            return .cookie
        }
        return nil
    }

    /// The Set-Cookie value that lets plain subresource loads (`<script src>`, `<img>`) carry the token.
    public var setCookieValue: String {
        "\(Self.cookieName)=\(token); Path=/; SameSite=Strict; HttpOnly"
    }

    static func cookieValue(named name: String, in header: String) -> String? {
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<eq] == name {
                return String(trimmed[trimmed.index(after: eq)...])
            }
        }
        return nil
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

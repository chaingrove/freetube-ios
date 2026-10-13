import Foundation
import FlyingFox
import FlyingSocks

/// The in-app loopback HTTP server. Binds 127.0.0.1:<port> and serves:
///
/// - `GET /*`                    static files from the web directory (MIME types, Range)
/// - `ANY /__yt/<encoded URL>`   proxy to the allowed YouTube hosts, streaming bodies
///
/// Every request must carry the per-launch token (`X-FT-Token` header, `?ft=` query or `ft` cookie).
public actor LoopbackServer {
    public nonisolated let configuration: LoopbackConfiguration

    private let server: HTTPServer
    private let upstream: UpstreamSession
    private var runTask: Task<Void, Never>?

    public init(configuration: LoopbackConfiguration) {
        self.configuration = configuration
        let upstream = UpstreamSession(log: configuration.log)
        self.upstream = upstream
        let root = RootHandler(
            gate: TokenGate(token: configuration.token),
            proxy: ProxyHandler(configuration: configuration, upstream: upstream),
            files: StaticFileHandler(root: configuration.webDirectory)
        )
        // 127.0.0.1 always parses; the force-try cannot fail.
        let address = try! sockaddr_in.inet(ip4: "127.0.0.1", port: configuration.port)
        self.server = HTTPServer(address: address, timeout: 600, logger: .disabled, handler: root)
    }

    /// The bound port (useful when `configuration.port == 0`).
    public var listeningPort: UInt16? {
        get async {
            guard let address = await server.listeningAddress else { return nil }
            switch address {
            case .ip4(_, let port), .ip6(_, let port): return port
            case .unix: return nil
            }
        }
    }

    /// Starts listening and returns once the socket accepts connections.
    /// The listener is restarted automatically if iOS closes it while the app is suspended
    /// (FlyingFox throws `SocketError.disconnected` in that case).
    public func start(timeout: TimeInterval = 5) async throws {
        guard runTask == nil else { return }
        let server = self.server
        let log = configuration.log
        runTask = Task {
            var quickFailures = 0
            while !Task.isCancelled {
                let began = Date()
                do {
                    try await server.run()
                    log("listener stopped")
                } catch {
                    log("listener ended: \(error)")
                }
                if Task.isCancelled { break }
                quickFailures = Date().timeIntervalSince(began) < 1 ? quickFailures + 1 : 0
                if quickFailures >= 5 {
                    log("listener failed \(quickFailures) times in a row; giving up")
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                log("restarting listener")
            }
        }
        try await server.waitUntilListening(timeout: timeout)
        configuration.log("listening on http://127.0.0.1:\(await listeningPort ?? configuration.port)/")
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await server.stop(timeout: 1)
        upstream.invalidate()
    }
}

/// Synchronous start for `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, which must
/// have the socket listening before Capacitor's view controller loads `server.url`.
public enum LoopbackLauncher {
    @discardableResult
    public static func startAndWait(configuration: LoopbackConfiguration, timeout: TimeInterval = 5) -> LoopbackServer {
        let server = LoopbackServer(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                try await server.start(timeout: timeout)
            } catch {
                configuration.log("loopback server failed to start: \(error)")
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            configuration.log("loopback server start timed out")
        }
        return server
    }
}

/// Token gate + dispatch by raw path prefix. One catch-all route keeps FlyingFox's path
/// standardisation (which percent-decodes `/__yt/…`) out of the way.
struct RootHandler: HTTPHandler {
    let gate: TokenGate
    let proxy: ProxyHandler
    let files: StaticFileHandler

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let source = gate.authorize(
            headerValue: request.headers[HTTPHeader(TokenGate.headerName)],
            queryValue: request.query[TokenGate.queryName],
            cookieHeader: request.headers[.cookie]
        ) else {
            return JSONResponses.error(.unauthorized, "missing or invalid \(TokenGate.headerName)")
        }

        let raw = request.target.path()
        var response: HTTPResponse
        if raw.hasPrefix(ProxyHandler.pathPrefix) {
            response = try await proxy.handleRequest(request)
        } else {
            response = try await files.handleRequest(request)
        }
        if source == .query {
            // The initial navigation carries `?ft=`; hand the token to plain subresource loads too.
            response.headers[.setCookie] = gate.setCookieValue
        }
        return response
    }
}

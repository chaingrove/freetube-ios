import UIKit
import WebKit
import LoopbackServer

enum PoTokenError: LocalizedError {
    case scriptMissing
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .scriptMissing: return "botGuardScript.js missing from the app bundle"
        case .timedOut: return "timed out"
        case .failed(let message): return message
        }
    }
}

/// Port of src/main/poTokenGenerator.js: runs src/botGuardScript.js (built into public/ by
/// `pnpm run pack:ios`) in a throwaway hidden web view whose origin is https://www.youtube.com,
/// so the BotGuard requests are same-origin or CORS-allowed exactly like on the real site.
/// One token at a time, with a fresh non-persistent data store each time.
@MainActor
final class PoTokenGenerator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    private static let timeout: TimeInterval = 30

    /// The BotGuard interpreter on www.google.com/js/ sends no CORS headers. Electron injects them
    /// (poTokenGenerator.js `onHeadersReceived`), WKWebView can't, so those fetches go through native code.
    private static let fetchShim = """
        const ftOriginalFetch = window.fetch
        window.fetch = (input, init) => {
          const url = input instanceof Request ? input.url : String(input)
          if (url.startsWith('https://www.google.com/js/')) {
            return window.webkit.messageHandlers.ftFetch.postMessage(url)
              .then(text => new Response(text, { headers: { 'Content-Type': 'text/javascript' } }))
          }
          return ftOriginalFetch(input, init)
        }
        """

    private lazy var botGuardScript: String? = {
        guard let url = Bundle.main.url(forResource: "public/botGuardScript", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let export = source.range(of: #"export\{(\w+) as default\};"#, options: .regularExpression) else {
            return nil
        }
        let function = source[export].dropFirst("export{".count).prefix { $0 != " " }
        return source.replacingCharacters(in: export, with: """
            ;\(function)(ftParams.videoId, JSON.parse(ftParams.context), JSON.parse(ftParams.initialAttestationData), JSON.parse(ftParams.ytConfig))
              .then(poToken => window.webkit.messageHandlers.ftPoToken.postMessage({ poToken }),
                    error => window.webkit.messageHandlers.ftPoToken.postMessage({ error: String(error) }))
            """)
    }()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private var queue: Task<Void, Never> = Task {}
    private var pending: CheckedContinuation<String, Error>?
    private var runCount = 0

    func generate(videoId: String, context: String, initialAttestationData: String, ytConfig: String, hostView: UIView) async throws -> String {
        let previous = queue
        let job = Task { @MainActor in
            await previous.value
            return try await self.run(videoId: videoId, context: context, initialAttestationData: initialAttestationData, ytConfig: ytConfig, hostView: hostView)
        }
        queue = Task { _ = try? await job.value }
        return try await job.value
    }

    private func run(videoId: String, context: String, initialAttestationData: String, ytConfig: String, hostView: UIView) async throws -> String {
        guard let botGuardScript else { throw PoTokenError.scriptMissing }

        let params = try JSONSerialization.data(withJSONObject: [
            "videoId": videoId,
            "context": context,
            "initialAttestationData": initialAttestationData,
            "ytConfig": ytConfig,
        ])
        let script = Self.fetchShim + "\nconst ftParams = " + String(decoding: params, as: UTF8.self) + "\n" + botGuardScript

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let controller = configuration.userContentController
        controller.add(self, contentWorld: .page, name: "ftPoToken")
        controller.addScriptMessageHandler(self, contentWorld: .page, name: "ftFetch")
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        // Desktop-sized like Electron's offscreen view, and in the window but off screen,
        // so timers are not throttled the way they are for detached web views.
        let webView = WKWebView(frame: CGRect(x: -4000, y: 0, width: 1280, height: 720), configuration: configuration)
        webView.customUserAgent = LoopbackConfiguration.desktopSafariUserAgent
        webView.isUserInteractionEnabled = false
        hostView.addSubview(webView)
        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
            controller.removeAllScriptMessageHandlers()
            controller.removeAllUserScripts()
        }

        runCount += 1
        let thisRun = runCount
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            webView.loadHTMLString("<!DOCTYPE html><html lang=\"en\"><head><title></title></head><body></body></html>",
                                   baseURL: URL(string: "https://www.youtube.com/"))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                guard let self, self.runCount == thisRun else { return }
                self.finish(.failure(PoTokenError.timedOut))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(with: result)
    }

    // ftPoToken: the result of the BotGuard script
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        if let poToken = body?["poToken"] as? String {
            finish(.success(poToken))
        } else {
            finish(.failure(PoTokenError.failed(body?["error"] as? String ?? "no PoToken returned")))
        }
    }

    // ftFetch: the BotGuard interpreter script
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let string = message.body as? String, let url = URL(string: string),
              url.scheme == "https", url.host == "www.google.com", url.path.hasPrefix("/js/") else {
            replyHandler(nil, "only https://www.google.com/js/ is fetched natively")
            return
        }
        var request = URLRequest(url: url)
        request.setValue(LoopbackConfiguration.desktopSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("script", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        Task {
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    replyHandler(nil, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url)")
                    return
                }
                replyHandler(String(decoding: data, as: UTF8.self), nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }
}

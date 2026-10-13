import Foundation
import FlyingSocks

public enum ProxyError: Error, LocalizedError {
    case notHTTP
    case noResponse
    case badTarget(String)
    case hostNotAllowed(String)
    case insecureUpstream(String)

    public var errorDescription: String? {
        switch self {
        case .notHTTP: return "upstream response was not HTTP"
        case .noResponse: return "upstream task completed without a response"
        case .badTarget(let s): return "bad proxy target: \(s)"
        case .hostNotAllowed(let s): return "host not allowed: \(s)"
        case .insecureUpstream(let s): return "insecure upstream refused: \(s)"
        }
    }
}

/// One ephemeral URLSession, cookies disabled, whose data tasks deliver their bodies through
/// `URLSessionDataDelegate.urlSession(_:dataTask:didReceive:)` into an `AsyncThrowingStream<Data>`
/// Each chunk is handed to the FlyingFox response as soon as it
/// arrives, so `fetch()` in the WebView sees the body progressively.
final class UpstreamSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias BodyStream = AsyncThrowingStream<Data, Error>

    private final class Pending {
        var head: CheckedContinuation<HTTPURLResponse, Error>?
        let body: BodyStream.Continuation
        init(body: BodyStream.Continuation) { self.body = body }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpAdditionalHeaders = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = 8
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Starts the request and returns as soon as the response head is available.
    /// The body arrives on the returned stream; dropping the stream cancels the task.
    func start(_ request: URLRequest) async throws -> (HTTPURLResponse, BodyStream) {
        let (stream, continuation) = BodyStream.makeStream(bufferingPolicy: .unbounded)
        let task = session.dataTask(with: request)
        let entry = Pending(body: continuation)
        lock.withLock { pending[task.taskIdentifier] = entry }
        continuation.onTermination = { @Sendable [weak task] _ in task?.cancel() }

        let response: HTTPURLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPURLResponse, Error>) in
                lock.withLock { entry.head = cont }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (response, stream)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let head = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            let entry = pending[dataTask.taskIdentifier]
            let h = entry?.head
            entry?.head = nil
            return h
        }
        if let http = response as? HTTPURLResponse {
            head?.resume(returning: http)
            completionHandler(.allow)
        } else {
            head?.resume(throwing: ProxyError.notHTTP)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let entry = lock.withLock { pending[dataTask.taskIdentifier] }
        entry?.body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        let head = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            let h = entry.head
            entry.head = nil
            return h
        }
        if let error {
            head?.resume(throwing: error)
            entry.body.finish(throwing: error)
        } else {
            head?.resume(throwing: ProxyError.noResponse)
            entry.body.finish()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Follow redirects natively, like Electron's session does.
        completionHandler(request)
    }
}

/// Adapts a stream of `Data` chunks to FlyingFox's byte-buffer sequence protocol, so it can be
/// wrapped in `HTTPBodySequence(from:)` (chunked transfer encoding) or `HTTPBodySequence(from:count:)`.
struct DataChunkSequence: AsyncBufferedSequence, @unchecked Sendable {
    typealias Element = UInt8

    let stream: AsyncThrowingStream<Data, Error>

    func makeAsyncIterator() -> Iterator {
        Iterator(inner: stream.makeAsyncIterator())
    }

    struct Iterator: AsyncBufferedIteratorProtocol {
        var inner: AsyncThrowingStream<Data, Error>.Iterator
        var leftover = Data()

        mutating func next() async throws -> UInt8? {
            if leftover.isEmpty {
                guard let chunk = try await nextNonEmpty() else { return nil }
                leftover = chunk
            }
            return leftover.popFirst()
        }

        mutating func nextBuffer(suggested count: Int) async throws -> Data? {
            if !leftover.isEmpty {
                let chunk = leftover
                leftover = Data()
                return chunk
            }
            return try await nextNonEmpty()
        }

        /// A zero-length buffer would be encoded as the chunked-transfer terminator, so skip empties.
        private mutating func nextNonEmpty() async throws -> Data? {
            while let chunk = try await inner.next() {
                if !chunk.isEmpty { return chunk }
            }
            return nil
        }
    }
}

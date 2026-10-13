import Foundation
import FlyingFox
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// `GET /*` → files from the web directory with MIME types and Range support.
/// Delegates the actual file streaming (Range, HEAD, ETag) to FlyingFox's `FileHTTPHandler`.
struct StaticFileHandler: HTTPHandler {
    let root: URL

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.method == .GET || request.method == .HEAD else {
            return HTTPResponse(statusCode: .methodNotAllowed)
        }
        guard let file = resolve(requestPath: request.path) else {
            return HTTPResponse(statusCode: .notFound, headers: [.contentType: "text/plain"], body: Data("not found\n".utf8))
        }
        let handler = FileHTTPHandler(path: file, contentType: Self.contentType(for: file), cacheControl: [.noStore])
        return try await handler.handleRequest(request)
    }

    /// Maps a decoded request path to a file inside `root`; nil when missing or outside the root.
    func resolve(requestPath: String) -> URL? {
        let rootPath = root.standardizedFileURL.path
        var relative = requestPath
        if relative.hasSuffix("/") || relative.isEmpty { relative += "index.html" }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            let index = candidate.appendingPathComponent("index.html")
            return FileManager.default.fileExists(atPath: index.path) ? index : nil
        }
        return candidate
    }

    static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json; charset=utf-8",
        "map": "application/json", "txt": "text/plain; charset=utf-8", "xml": "application/xml",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf",
        "wasm": "application/wasm", "mpd": "application/dash+xml", "m3u8": "application/vnd.apple.mpegurl",
        "mp4": "video/mp4", "m4v": "video/mp4", "m4s": "video/iso.segment", "m4a": "audio/mp4",
        "webm": "video/webm", "mp3": "audio/mpeg", "vtt": "text/vtt", "br": "application/octet-stream",
    ]

    static func contentType(for file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        if let known = mimeTypes[ext] { return known }
#if canImport(UniformTypeIdentifiers)
        if let mime = UTType(filenameExtension: ext)?.preferredMIMEType { return mime }
#endif
        return "application/octet-stream"
    }
}

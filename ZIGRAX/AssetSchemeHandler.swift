import Foundation
import WebKit

/// Serves the bundled page (www/) at zxapp://localhost/… so it runs like a normal web origin:
/// fetch(), Web Workers, WebAssembly (served as application/wasm), localStorage and audio all work.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "zxapp"
    static let host = "localhost"
    static var startURL: URL { URL(string: "\(scheme)://\(host)/ZIGRAX.html")! }

    private let root: URL = Bundle.main.resourceURL!.appendingPathComponent("www", isDirectory: true)
    private var stopped = Set<ObjectIdentifier>()
    private let lock = NSLock()

    private static let types: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "json": "application/json", "wasm": "application/wasm", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "ogg": "audio/ogg", "wav": "audio/wav",
        "txt": "text/plain", "woff2": "font/woff2", "woff": "font/woff", "ico": "image/x-icon",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard let url = task.request.url else { return fail(task, 400) }
        var path = url.path.removingPercentEncoding ?? url.path
        if path.isEmpty || path == "/" { path = "/ZIGRAX.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        // never leave the www folder
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return fail(task, 404)
        }
        let mime = Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        var body = data
        var status = 200
        var headers: [String: String] = [
            "Content-Type": mime,
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
            "Accept-Ranges": "bytes",
        ]
        // audio/video elements ask for byte ranges
        if let range = task.request.value(forHTTPHeaderField: "Range"), let r = Self.parseRange(range, count: data.count) {
            body = data.subdata(in: r)
            status = 206
            headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(data.count)"
        }
        headers["Content-Length"] = String(body.count)
        guard let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return fail(task, 500) }
        lock.lock(); let gone = stopped.remove(id) != nil; lock.unlock()
        if gone { return }
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); stopped.insert(ObjectIdentifier(task)); lock.unlock()
    }

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        if let url = task.request.url, let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"]) {
            task.didReceive(resp)
            task.didReceive(Data())
            task.didFinish()
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
        }
    }

    /// "bytes=a-b", "bytes=a-", "bytes=-n"
    static func parseRange(_ h: String, count: Int) -> Range<Int>? {
        guard count > 0, h.hasPrefix("bytes=") else { return nil }
        let spec = h.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        var start: Int, end: Int
        if parts[0].isEmpty {
            guard let n = Int(parts[1]), n > 0 else { return nil }
            start = max(0, count - n); end = count - 1
        } else {
            guard let a = Int(parts[0]) else { return nil }
            start = a
            end = parts[1].isEmpty ? count - 1 : min(Int(parts[1]) ?? (count - 1), count - 1)
        }
        guard start <= end, start < count else { return nil }
        return start..<(end + 1)
    }
}

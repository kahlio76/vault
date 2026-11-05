import Foundation
import WebKit

/// Serves everything the page loads over `vault://app/...`:
///   /                      the shell
///   /res/<file>            bundled scripts
///   /collections           the configured folders
///   /index/<n>  /stamp/<n> folder tree and change fingerprint
///   /state                 the last location, saved by the app
///   /c/<n>/<relative path> a file from collection n (read-only, confined to that folder)
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private let library: Library
    private let lock = NSLock()
    private var live = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "vault.scheme", qos: .userInitiated, attributes: .concurrent)
    private static let resources: Set<String> = ["shell.html", "render.js", "katex/katex.min.js", "katex/katex.min.css", "katex/mhchem.min.js"]

    init(library: Library) { self.library = library }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock(); live.insert(id); lock.unlock()
        let url = urlSchemeTask.request.url
        queue.async { [weak self] in
            guard let self else { return }
            let (status, mime, data) = self.respond(to: url)
            DispatchQueue.main.async {
                self.lock.lock(); let ok = self.live.remove(id) != nil; self.lock.unlock()
                guard ok, let u = url else { return }
                let headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"]
                let resp = HTTPURLResponse(url: u, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                urlSchemeTask.didReceive(resp)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock(); live.remove(ObjectIdentifier(urlSchemeTask as AnyObject)); lock.unlock()
    }

    private func respond(to url: URL?) -> (Int, String, Data) {
        guard let url else { return (400, "text/plain", Data()) }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch parts.first {
        case nil:
            return bundled("shell.html")
        case "res":
            return parts.count >= 2 ? bundled(parts.dropFirst().joined(separator: "/")) : (404, "text/plain", Data())
        case "collections":
            let list = library.collections.map { c -> [String: Any] in
                var d: [String: Any] = ["name": c.name, "path": c.path]
                if let w = c.web { d["web"] = ["prefix": w.prefix, "base": w.base] }
                if let m = c.site { d["site"] = ["root": m.root, "entry": m.entry] }
                if let m = c.math { d["math"] = m }
                if let h = c.hidden { d["hidden"] = h }
                return d
            }
            return json(list)
        case "index":
            if parts.count == 2, let i = Int(parts[1]), let d = library.index(i) { return (200, "application/json", d) }
            return (404, "text/plain", Data())
        case "stamp":
            if parts.count == 2, let i = Int(parts[1]) { return (200, "text/plain", Data(library.stamp(i).utf8)) }
            return (404, "text/plain", Data())
        case "state":
            let s = UserDefaults.standard.string(forKey: "state") ?? "{}"
            return (200, "application/json", Data(s.utf8))
        case "c":
            guard parts.count >= 3, let i = Int(parts[1]) else { return (404, "text/plain", Data()) }
            let rel = parts[2...].joined(separator: "/")
            guard let file = library.resolve(i, rel) else { return (403, "text/plain", Data("outside the folder".utf8)) }
            guard let data = try? Data(contentsOf: file) else { return (404, "text/plain", Data()) }
            return (200, SchemeHandler.mime(file.pathExtension), data)
        default:
            return (404, "text/plain", Data())
        }
    }

    private func bundled(_ name: String) -> (Int, String, Data) {
        let isFont = name.hasPrefix("katex/fonts/") && name.hasSuffix(".woff2") && !name.contains("..")
        guard SchemeHandler.resources.contains(name) || isFont else { return (404, "text/plain", Data()) }
        var candidates: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["VAULT_RES"] { candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name)) }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent(name)) }
        for u in candidates {
            if let d = try? Data(contentsOf: u) { return (200, SchemeHandler.mime(u.pathExtension), d) }
        }
        return (404, "text/plain", Data("missing resource \(name)".utf8))
    }

    private func json(_ obj: Any) -> (Int, String, Data) {
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("[]".utf8)
        return (200, "application/json", d)
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "md", "txt", "csv", "log", "py", "swift", "c", "h", "cpp", "sh", "yaml", "yml", "toml", "ini": return "text/plain; charset=utf-8"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "map": return "application/json"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}

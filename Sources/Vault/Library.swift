import Foundation

/// Where the live version of a mirrored site lives, so links to files that are missing locally can open it.
struct WebMap: Codable {
    var prefix: String   // folder inside the collection that mirrors the site, e.g. "Course Site/site/"
    var base: String     // site root, e.g. "https://example.edu/course/"
}

/// A folder that holds an offline copy of a generated site. The app shows that site, using its own
/// sidebar as the table of contents, instead of rendering the folder's notes.
struct SiteMap: Codable {
    var root: String     // folder inside the collection, e.g. "Course Site/site"
    var entry: String    // page that has the sidebar, e.g. "intro.html"
}

struct Collection: Codable {
    var name: String
    var path: String
    var web: WebMap?
    var site: SiteMap?
    var math: Bool?      // render $...$ as LaTeX (default true)
    var hidden: Bool?    // not listed in the wheel; only used to find attachments (images) by name
}

struct Config: Codable {
    var collections: [Collection] = []
}

/// The list of folders the app shows, plus read-only access to them.
/// Everything the web view can reach goes through `resolve`, which refuses paths outside a collection.
final class Library {
    private let lock = NSLock()
    private var config = Config()
    private let fm = FileManager.default

    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vault", isDirectory: true)
    }
    static var configURL: URL { supportDir.appendingPathComponent("config.json") }

    init() {
        if let d = try? Data(contentsOf: Library.configURL),
           let c = try? JSONDecoder().decode(Config.self, from: d) {
            config = c
        }
    }

    var collections: [Collection] {
        lock.lock(); defer { lock.unlock() }
        return config.collections
    }

    @discardableResult
    func add(name: String, path: String, site: SiteMap? = nil, hidden: Bool? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if config.collections.contains(where: { $0.path == path }) { return false }
        config.collections.append(Collection(name: name, path: path, web: nil, site: site, math: nil, hidden: hidden))
        saveLocked()
        return true
    }

    private func saveLocked() {
        try? fm.createDirectory(at: Library.supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(config) { try? d.write(to: Library.configURL, options: .atomic) }
    }

    /// "ENGR 13100", "MA 16100", "CHM 11520 & 11510": a course code followed by a number.
    static func isClassFolder(_ name: String) -> Bool {
        name.range(of: #"^[A-Z]{2,5}[ _-]?\d{3,5}"#, options: .regularExpression) != nil
    }

    /// Looks (three levels down) for a folder holding an offline copy of a generated site.
    func detectSite(in folder: URL) -> SiteMap? {
        func walk(_ dir: URL, _ rel: String, _ depth: Int) -> SiteMap? {
            if fm.fileExists(atPath: dir.appendingPathComponent("intro.html").path),
               fm.fileExists(atPath: dir.appendingPathComponent("_static").path) {
                return SiteMap(root: rel, entry: "intro.html")
            }
            guard depth < 3, let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
            for k in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = k.lastPathComponent
                guard !name.hasPrefix("."), (try? k.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if let found = walk(k, rel.isEmpty ? name : rel + "/" + name, depth + 1) { return found }
            }
            return nil
        }
        return walk(folder, "", 0)
    }

    /// Adds every class folder inside a vault as its own top-level entry, plus the vault's shared `attachments`
    /// folder as a hidden one so pasted images resolve. Returns how many class folders were added.
    @discardableResult
    func addVault(_ vault: URL) -> Int {
        var added = 0
        let kids = (try? fm.contentsOfDirectory(at: vault, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for k in kids.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = k.lastPathComponent
            guard (try? k.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if Library.isClassFolder(name) {
                if add(name: name, path: k.path, site: detectSite(in: k)) { added += 1 }
            } else if name.lowercased() == "attachments" {
                add(name: name, path: k.path, hidden: true)
            }
        }
        return added
    }

    func root(_ i: Int) -> URL? {
        let cs = collections
        guard cs.indices.contains(i) else { return nil }
        let p = (cs[i].path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Maps a path relative to collection `i` to a real file, or nil if it would leave the collection.
    func resolve(_ i: Int, _ rel: String) -> URL? {
        guard let r = root(i) else { return nil }
        let u = r.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        return (u.path == r.path || u.path.hasPrefix(r.path + "/")) ? u : nil
    }

    // MARK: scanning

    private struct Entry { let url: URL; let name: String; let dir: Bool; let size: Int; let mtime: Int }

    private func skip(_ name: String, dir: Bool) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("~$") { return true }
        if !dir && name.lowercased().hasSuffix(".canvas") { return true }   // Obsidian canvases are not shown
        if dir && name.hasPrefix("_") && name != "_downloads" { return true }   // asset folders from site generators
        if dir && name == "node_modules" { return true }
        return false
    }

    private func entries(_ dir: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else { return [] }
        return urls.compactMap { u in
            let name = u.lastPathComponent
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false
            if skip(name, dir: isDir) { return nil }
            return Entry(url: u, name: name, dir: isDir, size: v?.fileSize ?? 0,
                         mtime: Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
    }

    /// Folder tree as JSON: {"name", "children":[{"n","p","d"?,"s"?,"m"?,"c"?}]}. Empty folders are dropped.
    func index(_ i: Int) -> Data? {
        guard let r = root(i) else { return nil }
        var budget = 20000   // a safety valve in case someone points this at their whole home folder
        func walk(_ dir: URL, _ rel: String, _ depth: Int) -> [[String: Any]] {
            guard depth < 14 else { return [] }
            var out: [[String: Any]] = []
            for e in entries(dir).sorted(by: { $0.name < $1.name }) {
                if budget <= 0 { break }
                let p = rel.isEmpty ? e.name : rel + "/" + e.name
                if e.dir {
                    let kids = walk(e.url, p, depth + 1)
                    if !kids.isEmpty { out.append(["n": e.name, "p": p, "d": 1, "c": kids]) }
                } else {
                    budget -= 1
                    out.append(["n": e.name, "p": p, "s": e.size, "m": e.mtime])
                }
            }
            return out
        }
        let obj: [String: Any] = ["name": collections[i].name, "children": walk(r, "", 0)]
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    /// A cheap fingerprint (file count + newest modification time) the page polls to notice edits.
    func stamp(_ i: Int) -> String {
        guard let r = root(i) else { return "" }
        var count = 0, newest = 0
        func walk(_ dir: URL, _ depth: Int) {
            guard depth < 14, count < 20000 else { return }
            for e in entries(dir) {
                if e.dir { walk(e.url, depth + 1) } else { count += 1; newest = max(newest, e.mtime) }
            }
        }
        walk(r, 0)
        return "\(count):\(newest)"
    }
}

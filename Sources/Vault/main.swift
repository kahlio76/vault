import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let library = Library()
    var window: NSWindow!
    var webView: WKWebView!
    private let selftestDir = ProcessInfo.processInfo.environment["VAULT_SELFTEST"]
    private var selftestStarted = false

    // Opening these with their default app would run them. Show them in Finder instead.
    private static let risky: Set<String> = ["app", "command", "sh", "bash", "zsh", "tool", "pkg", "dmg", "workflow", "action",
                                             "scpt", "applescript", "jar", "terminal", "py", "pl", "rb", "js", "ipynb"]

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()

        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(SchemeHandler(library: library), forURLScheme: "vault")
        cfg.userContentController.add(self, name: "native")
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = .black
        if #available(macOS 13.3, *), ProcessInfo.processInfo.environment["VAULT_INSPECT"] != nil { webView.isInspectable = true }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.contentView = webView
        window.title = "Vault"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName("VaultMain") { window.center() }
        window.setFrameAutosaveName("VaultMain")
        if selftestDir != nil { window.level = .floating }   // keep the test window on top so animation frames are not throttled
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: URL(string: "vault://app/")!))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: navigation: the page never leaves vault://, web links open in the default browser

    // File types the web view can show itself. Anything else that a page links to (xlsx, docx, ...) is
    // handed to the app that owns it, so a template link in the mirrored site opens it in Excel or Word.
    private static let inline: Set<String> = ["", "html", "htm", "pdf", "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "css", "js",
                                              "json", "txt", "md", "py", "map", "woff", "woff2", "ttf", "otf", "ico", "xml"]

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        switch url.scheme {
        case "vault":
            let ext = url.pathExtension.lowercased()
            if url.path.hasPrefix("/c/"), !AppDelegate.inline.contains(ext) {
                let parts = url.path.split(separator: "/").map(String.init)
                if parts.count >= 3, let i = Int(parts[1]), let file = library.resolve(i, parts[2...].joined(separator: "/")) {
                    openFile(file)
                }
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        case "about":
            decisionHandler(.allow)
        case "http", "https":
            // A clicked link, or a navigation of the whole page, goes to the browser. A frame the page loads by itself
            // (an embedded video, say) is allowed to load in place.
            let isFrameEmbed = action.navigationType != .linkActivated && !(action.targetFrame?.isMainFrame ?? true)
            if isFrameEmbed { decisionHandler(.allow) } else { NSWorkspace.shared.open(url); decisionHandler(.cancel) }
        default:
            decisionHandler(.cancel)
        }
    }

    private func openFile(_ url: URL) {
        if ProcessInfo.processInfo.environment["VAULT_NO_OPEN"] != nil {   // test mode: report instead of launching apps
            FileHandle.standardError.write(Data(("OPEN " + url.path + "\n").utf8)); return
        }
        if AppDelegate.risky.contains(url.pathExtension.lowercased()) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let dir = selftestDir, !selftestStarted { selftestStarted = true; runSelfTest(dir) }
    }

    // MARK: messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the app's own page may use the bridge, never a frame inside it (the mirrored site runs its own scripts).
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        if let t = body["title"] as? String { window.title = t }
        if let s = body["save"] as? String { UserDefaults.standard.set(s, forKey: "state") }
        if let l = body["log"] as? String { FileHandle.standardError.write(Data((l + "\n").utf8)) }
        if let u = body["ext"] as? String, let url = URL(string: u), ["http", "https"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        for key in ["open", "reveal", "obsidian"] {
            guard let d = body[key] as? [String: Any], let c = d["c"] as? Int, let rel = d["rel"] as? String,
                  let url = library.resolve(c, rel) else { continue }
            switch key {
            case "open":
                openFile(url)
            case "reveal":
                NSWorkspace.shared.activateFileViewerSelecting([url])
            default:
                var comp = URLComponents(string: "obsidian://open")!
                comp.queryItems = [URLQueryItem(name: "path", value: url.path)]
                if let o = comp.url { NSWorkspace.shared.open(o) }
            }
        }
    }

    // MARK: menu actions

    @objc func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Add"
        p.message = "Choose a folder of notes to show in Vault."
        guard p.runModal() == .OK, let url = p.url else { return }
        library.add(name: url.lastPathComponent, path: url.path)
        webView.evaluateJavaScript("window.vaultReload && window.vaultReload()")
    }

    @objc func addVault() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Add Vault"
        p.message = "Choose your vault folder. Each class folder inside it becomes its own entry."
        guard p.runModal() == .OK, let url = p.url else { return }
        let n = library.addVault(url)
        if n == 0 { library.add(name: url.lastPathComponent, path: url.path) }
        webView.evaluateJavaScript("window.vaultReload && window.vaultReload()")
    }

    @objc func reload() { webView.evaluateJavaScript("window.vaultReload && window.vaultReload()") }

    @objc func revealCurrent() {
        guard let s = UserDefaults.standard.string(forKey: "state"), let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let c = o["c"] as? Int, let p = o["path"] as? String, let url = library.resolve(c, p) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 2.0) }
    @objc func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.6) }
    @objc func zoomReset() { webView.pageZoom = 1.0 }

    private func buildMenu() {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            menu.addItem(item)
        }
        func submenu(_ title: String, _ fill: (NSMenu) -> Void) {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            fill(m)
            item.submenu = m
            main.addItem(item)
        }
        submenu("Vault") { m in
            add(m, "About Vault", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.addItem(.separator())
            add(m, "Hide Vault", #selector(NSApplication.hide(_:)), "h")
            m.addItem(.separator())
            add(m, "Quit Vault", #selector(NSApplication.terminate(_:)), "q")
        }
        submenu("File") { m in
            add(m, "Add Folder…", #selector(addFolder), "o", target: self)
            add(m, "Add Vault…", #selector(addVault), "o", [.command, .shift], target: self)
            add(m, "Reload", #selector(reload), "r", target: self)
            add(m, "Reveal in Finder", #selector(revealCurrent), "r", [.command, .shift], target: self)
            m.addItem(.separator())
            add(m, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        }
        submenu("Edit") { m in
            add(m, "Undo", Selector(("undo:")), "z")
            add(m, "Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            add(m, "Cut", #selector(NSText.cut(_:)), "x")
            add(m, "Copy", #selector(NSText.copy(_:)), "c")
            add(m, "Paste", #selector(NSText.paste(_:)), "v")
            add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
        }
        submenu("View") { m in
            add(m, "Zoom In", #selector(zoomIn), "=", target: self)
            add(m, "Zoom Out", #selector(zoomOut), "-", target: self)
            add(m, "Actual Size", #selector(zoomReset), "0", target: self)
        }
        submenu("Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
        }
        NSApp.mainMenu = main
    }

    // MARK: self-test (VAULT_SELFTEST=/some/dir): drives the real UI, writes screenshots, prints results

    private func runSelfTest(_ dir: String) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            func js(_ body: String, _ args: [String: Any] = [:]) async -> String {
                do {
                    let r = try await self.webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
                    return r.map { "\($0)" } ?? "null"
                } catch { return "ERROR: \(error)" }
            }
            func snap(_ name: String) async {
                guard let img = try? await self.webView.takeSnapshot(configuration: nil),
                      let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            print("BOOT", await js("return JSON.stringify(vaultTest.state('boot'))"))
            await snap("00-boot")
            print("RENDERALL", await js("return await vaultTest.renderAll()"))
            let n = Int(await js("return vaultTest.count()")) ?? 0
            for k in 0..<n {
                print("STEP", k, await js("return await vaultTest.run(k)", ["k": k]))
                await snap(String(format: "%02d", k + 1))
            }
            print("DONE")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

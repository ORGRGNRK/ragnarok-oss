import AppKit
import SwiftUI
import WebKit

/// The Browser tab (owner, 2026-11-13: "add google chrome into my app ... make it able to pop out").
/// Real Google Chrome can't be put inside another app, so this is a web browser built on WebKit (Safari's engine)
/// with an "Open in Chrome" button that hands the current page to the real Chrome. One web view is shared by the tab
/// and the pop-out window, so popping out or back never reloads the page or logs a site out.
enum Browser {
    static let home = "https://www.google.com"
    static let chromeID = "com.google.Chrome"

    /// What the owner typed in the address bar → the address to load. A URL (with or without https://) loads as is;
    /// anything else (spaces, no dot, not a URL) becomes a Google search. Only http/https pages load.
    nonisolated static func resolve(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased() {
            if ["http", "https"].contains(scheme), u.host != nil { return u }
            if s.contains("://") { return search(s) }          // file://, javascript:, ftp:// … are searched, never opened
        }
        let looksLikeHost = !s.contains(" ") && (s.contains(".") || s.hasPrefix("localhost")) && !s.hasSuffix(".")
        if looksLikeHost, let u = URL(string: "https://" + s), u.host != nil { return u }
        return search(s)
    }

    nonisolated static func search(_ q: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        return c.url
    }
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = BrowserModel()

    @Published var address = ""
    @Published var title = ""
    @Published var loading = false
    @Published var canBack = false
    @Published var canForward = false
    @Published var poppedOut = false
    @Published var note = ""

    private(set) lazy var web: WKWebView = {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()        // keeps site logins between launches
        // A bare WKWebView doesn't say "Safari", so Google and others serve their old basic pages. Say it, like Safari does.
        c.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let w = WKWebView(frame: .zero, configuration: c)
        w.navigationDelegate = self; w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = true
        watch(w)
        return w
    }()
    private var observers: [NSKeyValueObservation] = []
    private var window: NSWindow?
    private var started = false

    private func watch(_ w: WKWebView) {
        observers = [
            w.observe(\.url) { [weak self] w, _ in MainActor.assumeIsolated { if let u = w.url?.absoluteString { self?.address = u } } },
            w.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.title = w.title ?? ""; self?.window?.title = self?.windowTitle ?? "Browser" } },
            w.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.loading = w.isLoading } },
            w.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canBack = w.canGoBack } },
            w.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canForward = w.canGoForward } },
        ]
    }

    var windowTitle: String { title.isEmpty ? "Browser" : "\(title) — Browser" }

    func appear() { if !started { started = true; go(Browser.home) } }

    func go(_ raw: String) {
        guard let u = Browser.resolve(raw) else { return }
        started = true   // a page opened from a link is not replaced by the home page when the tab first shows
        note = ""; web.load(URLRequest(url: u))
    }
    func back() { web.goBack() }
    func forward() { web.goForward() }
    func reload() { if web.url == nil { go(address.isEmpty ? Browser.home : address) } else { web.reload() } }
    func stop() { web.stopLoading() }

    /// The current page in the real Google Chrome (or the default browser if Chrome isn't installed).
    func openInChrome() {
        guard let u = web.url ?? Browser.resolve(address) else { return }
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Browser.chromeID) {
            NSWorkspace.shared.open([u], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: fill from the vault (Vault.swift)
    func fillFromVault() {
        let asked = web.url
        VaultModel.shared.fill(for: asked) { [weak self] login in
            guard let self, let now = self.web.url, now.host == asked?.host, Vault.fillable(now) else {
                VaultModel.shared.note = "The page changed before filling; nothing was typed."; return
            }
            let totp = Vault.totpCode(login.totp)            // made now, on this Mac, from the vault's 2FA secret
            self.web.evaluateJavaScript(Vault.fillScript(username: login.username, password: login.password, code: totp?.code ?? "")) { r, _ in
                let did = r as? String ?? ""
                if did.contains("code") {
                    VaultModel.shared.note = did.contains("password") ? "Filled \(login.name) and its 2FA code." : "Filled the 2FA code for \(login.name)."
                } else if let totp {
                    // No 2FA box on this page yet: put the code on the clipboard and take it back off when it expires.
                    let pb = NSPasteboard.general; pb.clearContents(); pb.setString(totp.code, forType: .string)
                    let mark = pb.changeCount
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(totp.secondsLeft)) {
                        if NSPasteboard.general.changeCount == mark { NSPasteboard.general.clearContents() }
                    }
                    VaultModel.shared.note = (did.contains("password") ? "Filled \(login.name). " : "") + "2FA code copied (good for \(totp.secondsLeft) s)."
                } else if did.hasPrefix("no-password-field") || did == "user no-password-field" {
                    VaultModel.shared.note = "Filled the username; this page has no password box yet."
                }
            }
        }
    }

    // MARK: pop out / bring back
    func popOut() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        poppedOut = true
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = windowTitle
        w.setFrameAutosaveName("HeimdallBrowserWindow")
        if w.frame.origin == .zero { w.center() }
        w.contentView = NSHostingView(rootView: BrowserPage(m: self, inWindow: true))
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// Close the window; the page goes back into the tab (same page, nothing reloads).
    func bringBack() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        poppedOut = false
    }

    // MARK: WKNavigationDelegate / WKUIDelegate
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { note = "" }
    private func fail(_ e: Error) {
        let ns = e as NSError
        if ns.code == NSURLErrorCancelled { return }
        AppLog.error("browser", e, context: web.url?.host ?? "navigation")
        note = "The page didn't load: \(ns.localizedDescription)"
    }

    /// Links that ask for a new window (target=_blank) open here.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let u = navigationAction.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }

    /// Only web pages load inside; mailto:, tel:, app links and the like go to the Mac app that handles them.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let u = navigationAction.request.url, let s = u.scheme?.lowercased() else { decisionHandler(.cancel); return }
        if ["http", "https", "about", "blob", "data"].contains(s) { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(u) }
        decisionHandler(.cancel)
    }

    /// Pages that can't be shown (downloads) are handed to the real Chrome, which knows how to save them.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if let u = navigationResponse.response.url {
            note = "That's a download; it was opened in Chrome to save it."
            if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Browser.chromeID) {
                NSWorkspace.shared.open([u], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
            } else { NSWorkspace.shared.open(u) }
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories; p.canChooseFiles = true
        let finish: (NSApplication.ModalResponse) -> Void = { completionHandler($0 == .OK ? p.urls : nil) }
        if let w = webView.window { p.beginSheetModal(for: w, completionHandler: finish) } else { finish(p.runModal()) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = alert(message, frame); a.addButton(withTitle: "OK"); a.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = alert(message, frame); a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = alert(prompt, frame); a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = defaultText ?? ""
        a.accessoryView = f; a.window.initialFirstResponder = f
        completionHandler(a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil)
    }
    private func alert(_ text: String, _ frame: WKFrameInfo) -> NSAlert {
        let a = NSAlert(); a.messageText = frame.securityOrigin.host.isEmpty ? "Browser" : frame.securityOrigin.host
        a.informativeText = text; return a
    }
}

/// The Browser tab. When the page is popped out, the tab shows a note and a "Bring back" button instead.
struct BrowserView: View {
    @ObservedObject var m: BrowserModel = .shared
    var body: some View {
        Group {
            if m.poppedOut {
                VStack(spacing: 12) {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("The browser is in its own window").font(.headline)
                    Text(m.title.isEmpty ? m.address : m.title).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        Button("Show window") { m.popOut() }
                        Button("Bring back here") { m.bringBack() }.keyboardShortcut(.defaultAction)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BrowserPage(m: m, inWindow: false)
            }
        }.onAppear { m.appear() }
    }
}

/// Toolbar + page. Used in the tab and in the pop-out window.
struct BrowserPage: View {
    @ObservedObject var m: BrowserModel
    @ObservedObject var vault: VaultModel = .shared
    let inWindow: Bool
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { m.back() } label: { Image(systemName: "chevron.left") }.disabled(!m.canBack).help("Back")
                Button { m.forward() } label: { Image(systemName: "chevron.right") }.disabled(!m.canForward).help("Forward")
                Button { m.loading ? m.stop() : m.reload() } label: { Image(systemName: m.loading ? "xmark" : "arrow.clockwise") }
                    .help(m.loading ? "Stop" : "Reload")
                Button { m.go(Browser.home) } label: { Image(systemName: "house") }.help("Google")
                TextField("Search Google or type an address", text: $draft)
                    .textFieldStyle(.roundedBorder).focused($typing)
                    .onSubmit { m.go(draft); typing = false }
                Button { m.fillFromVault() } label: { Label("Fill", systemImage: vault.busy ? "hourglass" : "key.fill") }
                    .help("Fill this page's login from your vault (Touch ID)").disabled(vault.busy)
                    .popover(isPresented: Binding(get: { !vault.choices.isEmpty }, set: { if !$0 { vault.choices = [] } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Which login?").font(.headline).padding(.bottom, 4)
                            ForEach(vault.choices) { l in
                                Button { vault.pick(l) } label: {
                                    VStack(alignment: .leading) { Text(l.name); Text(l.username).font(.caption).foregroundStyle(.secondary) }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).padding(.vertical, 3)
                            }
                        }.padding(12).frame(width: 280)
                    }
                Button { m.openInChrome() } label: { Label("Open in Chrome", systemImage: "arrow.up.forward.app") }
                    .help("Open this page in Google Chrome")
                if inWindow {
                    Button { m.bringBack() } label: { Label("Back into Ragnarok", systemImage: "rectangle.portrait.and.arrow.forward") }
                        .help("Close this window and show the page in the Browser tab again")
                } else {
                    Button { m.popOut() } label: { Label("Pop out", systemImage: "macwindow.on.rectangle") }
                        .help("Show the browser in its own window")
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
            if m.loading { ProgressView().progressViewStyle(.linear).frame(height: 2) }
            if !m.note.isEmpty || !vault.note.isEmpty {
                Text(m.note.isEmpty ? vault.note : m.note).font(.caption).foregroundStyle(m.note.isEmpty ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 4)
            }
            Divider()
            BrowserWeb(web: m.web)
        }
        .sheet(isPresented: $vault.askMaster) { VaultSetupSheet() }
        .onAppear { draft = m.address }
        .onChange(of: m.address) { _, a in if !typing { draft = a } }
    }
}

/// Hosts the one shared WKWebView; moving it between the tab and the window keeps the page as it is.
private struct BrowserWeb: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> NSView { let v = NSView(); attach(v); return v }
    func updateNSView(_ v: NSView, context: Context) { if web.superview !== v { attach(v) } }
    private func attach(_ v: NSView) {
        web.removeFromSuperview(); web.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: v.leadingAnchor), web.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                     web.topAnchor.constraint(equalTo: v.topAnchor), web.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A web page from Alexus shown inside the app: the receipt pipe (Money → Receipts) and Home Assistant (its own tab).
/// Top bar: is it answering (checked with curl as a child process, like Chat.swift: the app's own URLSession got
/// "offline" for Alexus's LAN address), the address (editable, saved in UserDefaults), Reload, Open in browser.
/// Logins happen on the page itself (Home Assistant's login page) or in a username/password box for pages that ask
/// with HTTP Basic (the pipe). That password is kept for this run of the app only, never saved or logged.
enum WebPanel {
    /// What the Open panel lets the owner pick for a file <input> on a panel page: photos (any image, HEIC included) and PDFs.
    static let pickableTypes: [UTType] = [.image, .pdf]
    /// What the owner typed → a clean address, or nil if it isn't one. Adds http:// when there's no scheme, only http/https,
    /// host must look like a host (LocalConfig.validHost), no user:password@ part, no trailing slash.
    nonisolated static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, LocalConfig.validHost(host), c.user == nil, c.password == nil else { return nil }
        if let p = c.port, !(1...65535).contains(p) { return nil }
        return s
    }

    /// One line for the status bar from curl's result (code 0 = no answer).
    nonisolated static func describe(_ code: Int, url: String) -> (up: Bool, text: String) {
        switch code {
        case 0: return (false, "Not answering at \(url)")
        case 200..<400: return (true, "Answering at \(url)")
        case 401, 403: return (true, "Answering at \(url) (asks for a login)")
        default: return (false, "Answered with an error (\(code)) at \(url)")
        }
    }

    /// Which address to show: the saved one if it answers, else the fallback if that answers, else the saved one.
    nonisolated static func pick(primary: String, primaryUp: Bool, fallback: String?, fallbackUp: Bool) -> String {
        if !primaryUp, let fallback, fallbackUp { return fallback }
        return primary
    }

    /// Saved address, then the built-in address, then the other fallback. Duplicates are dropped.
    /// A saved home-network address that is also the fallback must not hide the Tailscale address.
    nonisolated static func addresses(saved: String, defaultURL: String, fallback: String?) -> [String] {
        var out: [String] = []
        for c in [saved, defaultURL, fallback].compactMap({ $0 }) where !c.isEmpty && !out.contains(c) {
            out.append(c)
        }
        return out
    }

    /// The first address that answers, or the first candidate when none do.
    nonisolated static func choose(_ tries: [(url: String, up: Bool)]) -> String {
        tries.first { $0.up }?.url ?? tries.first?.url ?? ""
    }

    /// HTTP status of url (0 = no answer), via curl. Only the status line is read; nothing is printed or stored.
    /// Mic only, https only, and only the host of the address the panel is showing.
    nonisolated static func micAllowed(type: WKMediaCaptureType, origin scheme: String, host: String, shown: String) -> Bool {
        guard type == .microphone, scheme == "https", let h = URL(string: shown)?.host, !h.isEmpty else { return false }
        return host.lowercased() == h.lowercased()
    }

    nonisolated static func probe(_ url: String, timeout: Int = 5) -> Int {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-o", "/dev/null", "--proto", "=http,https", "--max-time", "\(timeout)", "-w", "%{http_code}", url]
        let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
        do { try p.run() } catch { return 0 }
        let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return Int(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

@MainActor
final class WebPanelModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    /// The Money tab's own receipt pipe: port 8449 on Alexus (made once by bin/ragnarok-pipe-money-setup), falling back to the main pipe on 8448.
    static let pipe = WebPanelModel(key: "moneyPipeURL", title: "Receipt pipe (Money)", healthPath: "/healthz",
                                    defaultURL: ReceiptPipe.defaultURL, fallbackURL: ReceiptPipe.fallbackURL)
    /// Home Assistant on Alexus: HA_URL from local.conf first (the https Tailscale Serve address; the Assist mic only works
    /// on https), then plain http on the Tailscale address. Without HA_URL: Tailscale address, then home network.
    static let homeAssistant = WebPanelModel(key: "homeAssistantURL", title: "Home Assistant", healthPath: "/manifest.json",
                                             defaultURL: LocalConfig.current.homeAssistantURL ?? "http://\(LocalConfig.current.alexusTailscale):8123",
                                             fallbackURL: LocalConfig.current.homeAssistantURL == nil ? "http://\(LocalConfig.current.alexusHost):8123"
                                                                                                    : "http://\(LocalConfig.current.alexusTailscale):8123")

    let key: String, title: String, healthPath: String, defaultURL: String, fallbackURL: String?
    @Published var url: String { didSet { UserDefaults.standard.set(url, forKey: key) } }
    @Published var shown: String = ""          // the address the page is showing (url, or the fallback)
    @Published var status = "Checking…"
    @Published var up: Bool? = nil
    @Published var pageNote = ""
    private(set) lazy var web: WKWebView = {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()        // keeps Home Assistant's own login between launches
        let w = WKWebView(frame: .zero, configuration: c)
        w.navigationDelegate = self; w.uiDelegate = self
        return w
    }()
    private var loaded = false

    init(key: String, title: String, healthPath: String, defaultURL: String, fallbackURL: String?) {
        self.key = key; self.title = title; self.healthPath = healthPath; self.defaultURL = defaultURL; self.fallbackURL = fallbackURL
        self.url = WebPanel.normalize(UserDefaults.standard.string(forKey: key) ?? "") ?? defaultURL
        super.init()
    }

    func appear() { if !loaded { loaded = true; check(load: true) } }

    /// Check the saved address, then the built-in Tailscale address, then the home-network address. With load, show the first that answers.
    func check(load: Bool = false) {
        status = "Checking…"; up = nil
        let saved = url
        let list = WebPanel.addresses(saved: saved, defaultURL: defaultURL, fallback: fallbackURL)
        let path = healthPath
        Task.detached {
            var tries: [(url: String, up: Bool, text: String)] = []
            for c in list {
                let code = WebPanel.probe(c + path)
                let d = WebPanel.describe(code, url: c)
                tries.append((c, d.up, d.text))
                if d.up { break }
            }
            let use = WebPanel.choose(tries.map { ($0.url, $0.up) })
            let chosen = tries.first { $0.url == use }
            let anyUp = tries.contains { $0.up }
            await MainActor.run {
                if let chosen, chosen.url == saved || !anyUp {
                    self.status = chosen.text; self.up = chosen.up
                } else if anyUp {
                    self.status = "\(saved) isn't answering; using \(use)"; self.up = true
                }
                if anyUp && (load || self.shown != use) { self.shown = use; self.load(use) }
                else if !anyUp { self.pageNote = "Wait until \(saved) is reachable, then click Reload." }
            }
        }
    }

    func load(_ s: String) { if let u = URL(string: s) { pageNote = ""; web.load(URLRequest(url: u)) } }
    func reload() { if web.url == nil { check(load: true) } else { web.reload(); check() } }
    func openInBrowser() { if let u = web.url ?? URL(string: shown.isEmpty ? url : shown) { NSWorkspace.shared.open(u) } }
    func setURL(_ raw: String) -> Bool {
        guard let n = WebPanel.normalize(raw) else { return false }
        url = n; check(load: true); return true
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { note(error, webView: webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { note(error, webView: webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageNote = ""; reportIfChecking(ok: true, webView.url?.absoluteString ?? "") }
    private func note(_ e: Error, webView: WKWebView) {
        let ns = e as NSError
        if ns.code == NSURLErrorCancelled && !checking { return }
        AppLog.error("web-panel", e, context: webView.url?.host ?? "navigation")
        pageNote = "The page didn't load: \(ns.localizedDescription)"
        reportIfChecking(ok: false, "\(ns.domain) \(ns.code) \(ns.localizedDescription)")
    }

    /// HTTP Basic (the pipe): ask in a small box; kept for this run only (.forSession), never saved. Anything else: default.
    @objc(webView:didReceiveAuthenticationChallenge:completionHandler:)
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let m = challenge.protectionSpace.authenticationMethod
        guard m == NSURLAuthenticationMethodHTTPBasic || m == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if checking { print("webcheck: page asks for a login (\(m == NSURLAuthenticationMethodHTTPBasic ? "Basic" : "Digest")); not answered in test mode; the page was reached"); completionHandler(.cancelAuthenticationChallenge, nil); exit(0) }
        if challenge.previousFailureCount >= 3 { completionHandler(.cancelAuthenticationChallenge, nil); return }
        // the Money receipt pipe's login is in the keychain (bin/ragnarok-pipe-money-setup): use it once without asking
        if self === WebPanelModel.pipe, challenge.previousFailureCount == 0, let pw = ReceiptPipe.password() {
            completionHandler(.useCredential, URLCredential(user: ReceiptPipe.user, password: pw, persistence: .forSession)); return
        }
        let a = NSAlert()
        a.messageText = "\(title) login"
        a.informativeText = (challenge.previousFailureCount > 0 ? "That didn't work. " : "")
            + "\(challenge.protectionSpace.host) asks for a user and password. Kept only until Ragnarok quits."
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24)); user.placeholderString = "User"
        user.stringValue = challenge.proposedCredential?.user ?? ""
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); pass.placeholderString = "Password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54)); box.addSubview(user); box.addSubview(pass)
        a.accessoryView = box
        a.addButton(withTitle: "Log in"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = user.stringValue.isEmpty ? user : pass
        if a.runModal() == .alertFirstButtonReturn {
            completionHandler(.useCredential, URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession))
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    /// The page asks for the microphone (Home Assistant's Assist voice button). Allowed only for the page this panel is
    /// showing, only over https, and only the mic (never the camera). macOS still asks the owner once (NSMicrophoneUsageDescription).
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(WebPanel.micAllowed(type: type, origin: origin.protocol, host: origin.host, shown: shown) ? .grant : .deny)
    }

    // links that open a new window (target=_blank): open them here instead of dropping them
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let u = navigationAction.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }

    // A file <input> on the page (the pipe's "Take photo"): a Mac web view has no camera picker, so show a normal
    // Open panel for photos (or PDFs) instead. Several at once if the input has `multiple`. Cancel sends back nothing.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = false; p.canChooseFiles = true
        p.allowedContentTypes = WebPanel.pickableTypes
        p.message = parameters.allowsMultipleSelection ? "Choose photos to send" : "Choose a photo to send"
        p.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        let finish: (NSApplication.ModalResponse) -> Void = { completionHandler($0 == .OK ? p.urls : nil) }
        if let w = webView.window { p.beginSheetModal(for: w, completionHandler: finish) } else { finish(p.runModal()) }
    }

    // alert() / confirm() / prompt() from the page (e.g. the pipe's approve/fix step), shown as normal Mac boxes
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = jsAlert(message, frame); a.addButton(withTitle: "OK"); a.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = jsAlert(message, frame); a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = jsAlert(prompt, frame); a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = defaultText ?? ""
        a.accessoryView = f; a.window.initialFirstResponder = f
        completionHandler(a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil)
    }
    private func jsAlert(_ text: String, _ frame: WKFrameInfo) -> NSAlert {
        let a = NSAlert(); a.messageText = frame.securityOrigin.host.isEmpty ? title : frame.securityOrigin.host
        a.informativeText = text; return a
    }

    // MARK: --webcheck URL (test mode): load a page in a real WKWebView, print what came back, exit 0 if it loaded
    static func webcheck(_ s: String) {
        _ = NSApplication.shared
        let m = WebPanelModel(key: "webcheck-unused", title: "webcheck", healthPath: "", defaultURL: s, fallbackURL: nil)
        m.checking = true; checker = m
        let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = m.web
        checkWindow = w
        m.load(s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("webcheck: timed out"); exit(1) }
    }
    private var checking = false
    private static var checker: WebPanelModel?
    private static var checkWindow: NSWindow?
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if checking, let h = navigationResponse.response as? HTTPURLResponse { print("webcheck: HTTP \(h.statusCode) from \(h.url?.absoluteString ?? "?")") }
        decisionHandler(.allow)
    }
}

extension WebPanelModel {
    // test mode only: report finish/fail and exit (the normal delegate methods above still run first)
    func reportIfChecking(ok: Bool, _ detail: String) { if checking { print("webcheck: \(ok ? "loaded" : "failed"): \(detail)"); exit(ok ? 0 : 1) } }
}

struct WebPanelView: View {
    @ObservedObject var m: WebPanelModel
    var note: String = ""
    @State private var editing = false
    @State private var draft = ""
    @State private var bad = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(m.up == nil ? Color.gray : m.up! ? Color.green : Color.red).frame(width: 9, height: 9)
                Text(m.status).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                if editing {
                    TextField(m.defaultURL, text: $draft).textFieldStyle(.roundedBorder).frame(width: 260)
                        .onSubmit(save).foregroundStyle(bad ? .red : .primary)
                    Button("Save", action: save)
                    Button("Default") { draft = m.defaultURL; save() }.help(m.defaultURL)
                    Button("Cancel") { editing = false; bad = false }
                } else {
                    Button { draft = m.url; editing = true } label: { Label("Address", systemImage: "link") }
                        .help("Change the address (now \(m.url))")
                }
                Button { m.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                Button { m.openInBrowser() } label: { Label("Open in browser", systemImage: "safari") }
            }.padding(.horizontal, 10).padding(.vertical, 6)
            if !note.isEmpty || !m.pageNote.isEmpty {
                Text(m.pageNote.isEmpty ? note : m.pageNote).font(.caption).foregroundStyle(m.pageNote.isEmpty ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 4)
            }
            Divider()
            WebPanelWeb(web: m.web)
        }
        .onAppear { m.appear() }
    }

    private func save() {
        if m.setURL(draft) { editing = false; bad = false } else { bad = true }
    }
}

/// Hosts the model's one WKWebView, so switching tabs doesn't reload the page or log the owner out.
private struct WebPanelWeb: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); attach(v); return v
    }
    func updateNSView(_ v: NSView, context: Context) { if web.superview !== v { attach(v) } }
    private func attach(_ v: NSView) {
        web.removeFromSuperview(); web.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: v.leadingAnchor), web.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                     web.topAnchor.constraint(equalTo: v.topAnchor), web.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
    }
}

/// The Home Assistant tab: HA's own page inside Ragnarok. The owner logs in there; the app never reads or keeps an HA token.
/// (Cut in the 11-02 trim, back the same day: Ragnarok is the HQ where things get done, not a launcher.)
struct HomeAssistantView: View {
    var body: some View {
        WebPanelView(m: .homeAssistant, note: "Log in on Home Assistant's own page below; it remembers you. If the Tailscale address doesn't answer, the home-network address is tried.")
    }
}

/// Money → Receipts: the receipt pipe's own page (upload a photo, list, "needs review" → fix → Approve).
struct ReceiptsPage: View {
    var body: some View {
        VStack(spacing: 0) {
            ReceiptsMatchPanel()
            Divider()
            WebPanelView(m: .pipe, note: "The Money tab's receipt pipe on Alexus (port 8449, its own database): upload a photo, see what was read, and approve or fix anything marked \"needs review\". Everything below is the pipe's own page.")
        }
    }
}

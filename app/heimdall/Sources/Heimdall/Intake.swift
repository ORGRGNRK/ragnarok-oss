import SwiftUI
import AppKit
import Darwin
import UniformTypeIdentifiers

/// Intake tab. Text, files and photos are stored as data on Alexus. Nothing sent from here is run.
enum Intake {
    nonisolated static let tabMarker = "heimdall-intake-tab"
    nonisolated static let unreachableMessage = "Alexus is unreachable. Intake did not answer, so nothing was loaded or sent."
    nonisolated static let missingConfig = "Intake is not set up on this Mac. ~/.ragnarok/intake.env needs a URL and a TOKEN."
    nonisolated static let confPath = ("~/.ragnarok/intake.env" as NSString).expandingTildeInPath
    private nonisolated static let photoExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]
    private nonisolated static let previewCap: Int64 = 30 * 1024 * 1024

    struct Config { var url: String; var token: String }

    nonisolated static func loadConfig() -> Config? {
        guard let text = try? String(contentsOfFile: confPath, encoding: .utf8) else { return nil }
        let kv = LocalConfig.parse(text)
        guard var url = kv["URL"], LocalConfig.validURL(url) else { return nil }
        while url.hasSuffix("/") { url.removeLast() }
        guard let token = kv["TOKEN"], token.count >= 32, token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return Config(url: url, token: token)
    }

    nonisolated static func kind(filename: String, mime: String) -> String {
        if mime.lowercased().hasPrefix("image/") { return "photo" }
        let ext = (filename as NSString).pathExtension.lowercased()
        return photoExt.contains(ext) ? "photo" : "file"
    }

    /// A name stored as data. A slash, a backslash, or "." / ".." is refused. Never used as a path.
    nonisolated static func safeName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 255 { return nil }
        if name.contains("\0") || name.contains("/") || name.contains("\\") { return nil }
        if name == "." || name == ".." { return nil }
        return name
    }

    /// Matches Python urllib.parse.quote(value, safe=""): letters, digits, and -._~
    nonisolated static let headerSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// HTTP headers are Latin-1. A name that does not fit is sent as UTF-8 percent-encoding
    /// so the stack does not drop it or cut it before the extension.
    nonisolated static func utf8Header(_ value: String) -> String? {
        if value.isEmpty || value.contains("\n") || value.contains("\r") || value.contains("\0") { return nil }
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: headerSafe) else { return nil }
        return "UTF-8''" + encoded
    }

    /// Plain header only when every character fits in Latin-1. Otherwise nil, so nothing sends a cut-off name.
    nonisolated static func plainHeader(_ value: String) -> String? {
        if value.isEmpty || value.contains("\n") || value.contains("\r") || value.contains("\0") { return nil }
        for scalar in value.unicodeScalars where scalar.value > 255 { return nil }
        return value
    }

    nonisolated static func wireHeaders(_ fields: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in fields {
            if let utf = utf8Header(value) { out[key + "-Utf8"] = utf }
            if let plain = plainHeader(value) { out[key] = plain }
        }
        return out
    }

    /// Query values. `&` and `+` must be escaped: the server splits on `&`, and `+` is a space.
    nonisolated static func queryPart(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// "open" shows the file in its viewer. "reveal" selects it in Finder and does not launch it.
    /// Scripts, apps, archives and anything with no type stay data: they are not run.
    nonisolated static let riskyExt: Set<String> = [
        "app", "exe", "bin", "command", "sh", "bash", "zsh", "fish", "pkg", "dmg", "mpkg", "iso",
        "workflow", "action", "scpt", "scptd", "applescript", "jar", "dll", "so", "dylib", "kext",
        "html", "htm", "xhtml", "svg", "js", "mjs", "cjs", "py", "rb", "pl", "php", "cgi",
        "webloc", "inetloc", "url", "terminal", "tool", "docm", "xlsm", "pptm", "apk", "ipa", "msi",
        "bat", "cmd", "ps1", "vbs"
    ]

    nonisolated static func openPlan(filename: String, mime: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        let kind = mime.lowercased()
        if riskyExt.contains(ext) { return "reveal" }
        if kind.contains("javascript") || kind.contains("html") || kind.contains("x-sh")
            || kind.contains("x-executable") || kind.contains("x-mach-binary") || kind.contains("diskimage") {
            return "reveal"
        }
        if ext.isEmpty && (kind.isEmpty || kind == "application/octet-stream") { return "reveal" }
        return "open"
    }

    /// A saved copy is marked as downloaded data.
    nonisolated static func quarantineValue(at date: Date = Date()) -> String {
        String(format: "0083;%08x;Heimdall;Intake", Int(date.timeIntervalSince1970))
    }

    nonisolated static func markDataOnly(_ url: URL) {
        let bytes = Array(quarantineValue().utf8)
        _ = bytes.withUnsafeBytes { buf in
            setxattr(url.path, "com.apple.quarantine", buf.baseAddress, buf.count, 0, 0)
        }
    }

    nonisolated static func diskLine(free: Int64, used: Int64) -> String {
        let gib = { (n: Int64) in String(format: "%.1f", Double(n) / 1_073_741_824.0) }
        return "\(gib(free)) GB free · \(gib(used)) GB used"
    }

    struct Item: Identifiable, Hashable {
        var id: Int
        var kind: String
        var title: String
        var body: String
        var preview: String
        var filename: String
        var mime: String
        var size: Int64
        var sha256: String
        var sender: String
        var tags: String
        var project: String
        var created: String
        var showInline: Bool { kind == "photo" && size > 0 && size <= previewCap }
    }

    nonisolated static func item(_ d: [String: Any]) -> Item? {
        guard let id = (d["id"] as? NSNumber)?.intValue, id > 0 else { return nil }
        func s(_ k: String) -> String { d[k] as? String ?? "" }
        func n(_ k: String) -> Int64 {
            if let v = d[k] as? NSNumber { return v.int64Value }
            if let v = d[k] as? String, let i = Int64(v) { return i }
            return 0
        }
        return Item(id: id, kind: s("kind"), title: s("title"), body: s("body"), preview: s("preview"),
                    filename: s("original_filename"), mime: s("mime"), size: n("size"), sha256: s("sha256"),
                    sender: s("sender"), tags: s("tags"), project: s("project"), created: s("created"))
    }
}

@MainActor
final class IntakeModel: ObservableObject {
    @Published var items: [Intake.Item] = []
    @Published var disk = ""
    @Published var error = ""
    @Published var info = ""
    @Published var busy = false
    @Published var selected: Intake.Item?
    @Published var preview: NSImage?
    @Published var query = ""
    @Published var kind = ""
    @Published var sender = ""
    @Published var tag = ""
    @Published var draft = ""

    func reload() async {
        guard let cfg = Intake.loadConfig() else { error = Intake.missingConfig; items = []; disk = ""; return }
        busy = true
        defer { busy = false }
        var parts = ["limit=200"]
        if !query.isEmpty { parts.append("q=" + Intake.queryPart(query)) }
        if !kind.isEmpty { parts.append("kind=" + Intake.queryPart(kind)) }
        if !sender.isEmpty { parts.append("sender=" + Intake.queryPart(sender)) }
        if !tag.isEmpty { parts.append("tag=" + Intake.queryPart(tag)) }
        let (code, data) = await IntakeHTTP.get(cfg, "/intake/items?" + parts.joined(separator: "&"))
        if code == 0 { error = Intake.unreachableMessage; return }
        if code == 401 { error = "Intake refused the token. Nothing was loaded."; return }
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["items"] as? [[String: Any]] else {
            error = IntakeHTTP.message(data) ?? "Intake did not return a list."
            return
        }
        error = ""
        items = rows.compactMap(Intake.item)
        if let sel = selected { selected = items.first { $0.id == sel.id } ?? selected }
        let (dc, dd) = await IntakeHTTP.get(cfg, "/intake/disk")
        if dc == 200, let diskObj = try? JSONSerialization.jsonObject(with: dd) as? [String: Any] {
            let free = (diskObj["free_bytes"] as? NSNumber)?.int64Value ?? 0
            let used = (diskObj["used_bytes"] as? NSNumber)?.int64Value ?? 0
            disk = Intake.diskLine(free: free, used: used)
        }
    }

    func open(_ item: Intake.Item) async {
        selected = item
        preview = nil
        guard let cfg = Intake.loadConfig() else { error = Intake.missingConfig; return }
        let (code, data) = await IntakeHTTP.get(cfg, "/intake/items/\(item.id)")
        if code == 0 { error = Intake.unreachableMessage; return }
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var full = Intake.item(obj) else { error = IntakeHTTP.message(data) ?? "Could not open that item."; return }
        if full.body.isEmpty { full.body = item.preview }
        selected = full
        if let i = items.firstIndex(where: { $0.id == full.id }) { items[i] = full }
        guard full.showInline else { return }
        let (cc, bytes) = await IntakeHTTP.get(cfg, "/intake/items/\(full.id)/content")
        if cc == 200, let img = NSImage(data: bytes) { preview = img }
    }

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await sendText(text)
        if error.isEmpty { draft = "" }
    }

    func sendText(_ text: String) async {
        guard let cfg = Intake.loadConfig() else { error = Intake.missingConfig; return }
        let payload: [String: String] = [
            "kind": "text", "body": text, "sender": NSUserName(),
            "source_machine": ProcessInfo.processInfo.hostName, "tags": tag
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload.filter { !$0.value.isEmpty }) else { return }
        busy = true
        defer { busy = false }
        let (code, data) = await IntakeHTTP.send(cfg, "/intake/items", method: "POST", body: body, headers: ["Content-Type": "application/json"], timeout: 60)
        if code == 0 { error = Intake.unreachableMessage; return }
        guard code == 201 else { error = IntakeHTTP.message(data) ?? "Intake did not store that text."; return }
        error = ""
        info = "Stored."
        await reload()
    }

    func addFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = Intake.safeName(url.lastPathComponent)
        guard let name else { error = "That filename is not allowed. Nothing was stored."; return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await upload(url, filename: name, mime: mime, kind: Intake.kind(filename: name, mime: mime))
    }

    func upload(_ url: URL, filename: String, mime: String, kind: String) async {
        guard let cfg = Intake.loadConfig() else { error = Intake.missingConfig; return }
        guard Intake.safeName(filename) != nil else { error = "That filename is not allowed. Nothing was stored."; return }
        busy = true
        defer { busy = false }
        var headers = Intake.wireHeaders([
            "X-Intake-Filename": filename,
            "X-Intake-Kind": kind,
            "X-Intake-Sender": NSUserName(),
            "X-Intake-Source-Machine": ProcessInfo.processInfo.hostName,
            "X-Intake-Tags": tag,
            "X-Intake-Mime": mime,
        ])
        headers["Content-Type"] = Intake.plainHeader(mime) ?? "application/octet-stream"
        let (code, data) = await IntakeHTTP.upload(cfg, url, headers: headers)
        if code == 0 { error = Intake.unreachableMessage; return }
        guard code == 201 else { error = IntakeHTTP.message(data) ?? "Intake did not store that file."; return }
        error = ""
        info = "Stored \(filename)."
        await reload()
    }

    func paste() async {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let u = urls.first, u.isFileURL {
            await addFile(u); return
        }
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("intake-paste-\(UUID().uuidString).png")
            do { try png.write(to: tmp) } catch { self.error = "Could not read the pasted picture."; return }
            await upload(tmp, filename: "paste.png", mime: "image/png", kind: "photo")
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await sendText(s); return
        }
        error = "The clipboard has nothing Intake can store."
    }

    /// Writes a copy where the owner asks. Does not open it. Stored bytes stay data.
    func saveCopy(_ item: Intake.Item) async {
        guard let cfg = Intake.loadConfig() else { error = Intake.missingConfig; return }
        let (code, data) = await IntakeHTTP.get(cfg, "/intake/items/\(item.id)/content")
        if code == 0 { error = Intake.unreachableMessage; return }
        guard code == 200 else { error = IntakeHTTP.message(data) ?? "Could not read that file. Nothing was opened."; return }
        let name = Intake.safeName(item.filename) ?? "intake-\(item.id)"
        let panel = NSSavePanel()
        panel.title = "Save a copy"
        panel.prompt = "Save"
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.message = "Intake saves a copy and does not open it."
        let response = await withCheckedContinuation { (cont: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { cont.resume(returning: $0) }
        }
        guard response == .OK, let dest = panel.url else { return }
        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }
        do {
            try data.write(to: dest, options: .atomic)
            Intake.markDataOnly(dest)
        } catch {
            self.error = "Could not save that copy. Nothing was opened."
            return
        }
        error = ""
        info = "Saved a copy. It is marked as downloaded data."
    }

    /// Opens a safe file in its viewer. A script, app or other runnable file is only selected in Finder.
    func openFile(_ item: Intake.Item) async {
        guard let cfg = Intake.loadConfig() else { error = Intake.missingConfig; return }
        let (code, data) = await IntakeHTTP.get(cfg, "/intake/items/\(item.id)/content")
        if code == 0 { error = Intake.unreachableMessage; return }
        guard code == 200 else { error = IntakeHTTP.message(data) ?? "Could not read that file."; return }
        let name = Intake.safeName(item.filename) ?? "intake-\(item.id)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("intake-open-\(item.id)", isDirectory: true)
        let dest = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
            Intake.markDataOnly(dest)
        } catch {
            self.error = "Could not write a copy of that file."
            return
        }
        if Intake.openPlan(filename: name, mime: item.mime) == "reveal" {
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            error = ""
            info = "This file can run code, so Intake did not open it. It is selected in Finder and marked as downloaded data."
            return
        }
        NSWorkspace.shared.open(dest)
        error = ""
        info = "Opened a copy. It is marked as downloaded data."
    }

    func archive(_ item: Intake.Item) async {
        guard let cfg = Intake.loadConfig() else { error = Intake.missingConfig; return }
        let (code, data) = await IntakeHTTP.send(cfg, "/intake/items/\(item.id)/archive", method: "POST", body: Data(), headers: [:], timeout: 30)
        if code == 0 { error = Intake.unreachableMessage; return }
        guard code == 200 else { error = IntakeHTTP.message(data) ?? "Could not archive that item. Nothing was erased."; return }
        info = "Archived. The record is kept."
        if selected?.id == item.id { selected = nil; preview = nil }
        await reload()
    }
}

enum IntakeHTTP {
    nonisolated static func message(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let err = obj["error"] as? String, !err.isEmpty else { return nil }
        if let token = Intake.loadConfig()?.token { return err.replacingOccurrences(of: token, with: "[token]") }
        return err
    }

    nonisolated static func get(_ cfg: Intake.Config, _ path: String) async -> (Int, Data) {
        await send(cfg, path, method: "GET", body: nil, headers: [:], timeout: 60)
    }

    nonisolated static func send(_ cfg: Intake.Config, _ path: String, method: String, body: Data?, headers: [String: String], timeout: TimeInterval) async -> (Int, Data) {
        guard let url = URL(string: cfg.url + path) else { return (0, Data()) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch { return (0, Data()) }
    }

    nonisolated static func upload(_ cfg: Intake.Config, _ file: URL, headers: [String: String]) async -> (Int, Data) {
        guard let url = URL(string: cfg.url + "/intake/items") else { return (0, Data()) }
        var req = URLRequest(url: url, timeoutInterval: 6 * 60 * 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch { return (0, Data()) }
    }
}

struct IntakeView: View {
    @StateObject private var model = IntakeModel()
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Picker("Kind", selection: $model.kind) {
                    Text("All").tag(""); Text("Text").tag("text"); Text("Files").tag("file"); Text("Photos").tag("photo")
                }.pickerStyle(.segmented).frame(maxWidth: 280)
                TextField("Sender", text: $model.sender).textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                TextField("Tag", text: $model.tag).textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                Button("Search") { Task { await model.reload() } }
                Spacer()
                Text(model.disk.isEmpty ? " " : model.disk).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(10)
            if !model.error.isEmpty {
                Text(model.error).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 6)
            } else if !model.info.isEmpty {
                Text(model.info).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            HStack(spacing: 0) {
                List(selection: Binding(get: { model.selected?.id }, set: { id in
                    guard let id, let item = model.items.first(where: { $0.id == id }) else { return }
                    Task { await model.open(item) }
                })) {
                    ForEach(model.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title.isEmpty ? "(no title)" : item.title).lineLimit(1)
                            Text("\(item.kind) · \(item.sender) · \(item.created)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.tag(item.id)
                    }
                }.frame(minWidth: 280, maxWidth: 420)
                Divider()
                detail
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $model.draft).font(.body).frame(height: 64).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                VStack(spacing: 6) {
                    Button("Send text") { Task { await model.sendDraft() } }.disabled(model.busy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Paste") { Task { await model.paste() } }.disabled(model.busy)
                }
            }.padding(10)
        }
        .accessibilityIdentifier(Intake.tabMarker)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(hovering ? Color.accentColor : Color.clear, lineWidth: 2).padding(4).allowsHitTesting(false))
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            Task { await dropped(providers) }
            return true
        }
        .task { await model.reload() }
    }

    @ViewBuilder private var detail: some View {
        if let item = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.title3)
                    Text("\(item.kind) · \(item.sender)" + (item.project.isEmpty ? "" : " · \(item.project)") + (item.tags.isEmpty ? "" : " · \(item.tags)"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(item.sha256).font(.caption.monospaced()).textSelection(.enabled)
                    if item.kind == "text" || !item.body.isEmpty {
                        Text(item.body.isEmpty ? item.preview : item.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let img = model.preview {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 360)
                    } else if item.kind == "photo" && !item.showInline {
                        Text("This photo is over 30 MB, so it is not shown here. Open it to look at it.").font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Open") { Task { await model.openFile(item) } }
                            .help("Opens a safe file. A script or app is only shown in Finder, and the copy is marked as downloaded data.")
                        Button("Save copy") { Task { await model.saveCopy(item) } }
                            .help("Saves a copy on this Mac and marks it as downloaded data.")
                        Button("Archive") { Task { await model.archive(item) } }
                            .help("Hides this from the list. The record stays. Nothing is erased.")
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.items.isEmpty && model.error.isEmpty ? "Nothing here yet." : "Select an item.").font(.headline)
                Text("Drop a file or photo, paste, or type a note below. Newest is at the top. Stored items are data, not instructions.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func dropped(_ providers: [NSItemProvider]) async {
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { cont in
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let u = item as? URL { cont.resume(returning: u) }
                    else if let data = item as? Data { cont.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                    else { cont.resume(returning: nil) }
                }
            }
            if let url { await model.addFile(url) }
        }
    }
}

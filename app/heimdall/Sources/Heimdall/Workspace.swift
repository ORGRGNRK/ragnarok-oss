import AppKit
import Foundation
import SwiftUI

/// The Room tab's IDE side: a folder tree on the Mac, editor tabs, save.
/// Files are read and written as the Mac user running Heimdall; nothing goes over the network.
@MainActor
final class WorkspaceModel: ObservableObject {
    struct Entry: Hashable { let name: String; let path: String; let isDir: Bool }
    struct Row: Identifiable, Hashable { let entry: Entry; let depth: Int; var id: String { entry.path } }
    struct OpenFile: Identifiable, Hashable {
        let path: String; var text: String; var saved: String; var problem: String?
        var id: String { path }
        var dirty: Bool { problem == nil && text != saved }
        var name: String { (path as NSString).lastPathComponent }
    }

    nonisolated static let skip: Set<String> = [".git", ".build", "build", "node_modules", ".staging", "__pycache__", "DerivedData"]
    nonisolated static let maxBytes = 2_000_000

    @Published var root: String = ("~/Developer" as NSString).expandingTildeInPath
    @Published var expanded: Set<String> = []
    @Published var files: [OpenFile] = []
    @Published var current: String?
    @Published var note = ""
    @Published var conflict: String?        // file whose disk copy changed since it was opened (save asks first)
    private var cache: [String: [Entry]] = [:]
    private var autosaveWork: DispatchWorkItem?

    // Report item 2: unsaved editor text survives lock, restart, update and crashes. Dirty buffers are copied (2 s after
    // typing stops) to ~/Library/Application Support/Heimdall/unsaved/buffers.json (0600) and reopened on next launch.
    nonisolated static let unsavedFile = NSHomeDirectory() + "/Library/Application Support/Heimdall/unsaved/buffers.json"

    init() { restoreUnsaved() }

    func scheduleAutosave() {
        autosaveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.writeUnsaved() }
        autosaveWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    func writeUnsaved() {
        let dirty = files.filter { $0.dirty }.map { ["path": $0.path, "text": $0.text] }
        let fm = FileManager.default
        if dirty.isEmpty { try? fm.removeItem(atPath: Self.unsavedFile); return }
        let dir = (Self.unsavedFile as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let d = try? JSONSerialization.data(withJSONObject: dirty) else { return }
        if (try? d.write(to: URL(fileURLWithPath: Self.unsavedFile), options: .atomic)) != nil {
            chmod(Self.unsavedFile, 0o600)
        }
    }

    private func restoreUnsaved() {
        guard let d = FileManager.default.contents(atPath: Self.unsavedFile),
              let list = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] else { return }
        var n = 0
        for item in list {
            guard let p = item["path"], let t = item["text"] else { continue }
            open(p)
            if let i = files.firstIndex(where: { $0.path == p }), files[i].problem == nil { files[i].text = t; n += 1 }
            else if files.firstIndex(where: { $0.path == p }) == nil || files.first(where: { $0.path == p })?.problem != nil {
                // file gone or unreadable: keep the text in a buffer of its own so it isn't lost
                files.removeAll { $0.path == p }
                files.append(OpenFile(path: p, text: t, saved: "", problem: nil)); n += 1
            }
        }
        if n > 0 { note = "Restored \(n) unsaved file\(n == 1 ? "" : "s") from last time" }
    }

    /// Folders first, then files, by name; hidden files and build folders left out.
    nonisolated static func list(_ dir: String) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [Entry] = []
        for n in names where !n.hasPrefix(".") && !skip.contains(n) {
            var isDir: ObjCBool = false
            let p = (dir as NSString).appendingPathComponent(n)
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            let pkg = isDir.boolValue && NSWorkspace.shared.isFilePackage(atPath: p)
            out.append(Entry(name: n, path: p, isDir: isDir.boolValue && !pkg))
        }
        out.sort { $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Array(out.prefix(1000))
    }

    private func children(_ dir: String) -> [Entry] {
        if let c = cache[dir] { return c }
        let c = Self.list(dir); cache[dir] = c; return c
    }

    var rows: [Row] {
        var out: [Row] = []
        func walk(_ dir: String, _ depth: Int) {
            for e in children(dir) {
                out.append(Row(entry: e, depth: depth))
                if e.isDir && expanded.contains(e.path) && out.count < 5000 { walk(e.path, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    func toggle(_ e: Entry) {
        if expanded.contains(e.path) { expanded.remove(e.path) } else { cache[e.path] = nil; expanded.insert(e.path) }
    }

    func refresh() { cache = [:]; objectWillChange.send() }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: root)
        if panel.runModal() == .OK, let u = panel.url { root = u.path; expanded = []; refresh() }
    }

    func open(_ path: String) {
        if files.contains(where: { $0.path == path }) { current = path; return }
        var f = OpenFile(path: path, text: "", saved: "", problem: nil)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size > Self.maxBytes {
            f.problem = "Too big to edit here (\(size / 1000) KB; limit \(Self.maxBytes / 1000) KB)."
        } else if let d = FileManager.default.contents(atPath: path) {
            if let s = String(data: d, encoding: .utf8) { f.text = s; f.saved = s }
            else { f.problem = "Not a text file (not UTF-8), so it isn't shown." }
        } else { f.problem = "Can't read this file." }
        files.append(f); current = path
    }

    func binding(_ path: String) -> Binding<String> {
        Binding(get: { [weak self] in self?.files.first { $0.path == path }?.text ?? "" },
                set: { [weak self] v in
                    guard let self, let i = self.files.firstIndex(where: { $0.path == path }) else { return }
                    self.files[i].text = v; self.scheduleAutosave() })
    }

    /// Report item 1: if the file changed on disk since it was opened (an AI or another tool edited it), don't write over
    /// it; ask (Overwrite / Reload). Item 3: the real file behind a symlink is written, and its permissions are kept.
    func save(force: Bool = false) {
        guard let p = current, let i = files.firstIndex(where: { $0.path == p }), files[i].problem == nil else { return }
        let disk = FileManager.default.contents(atPath: p).flatMap { String(data: $0, encoding: .utf8) }
        if !force, let disk, disk != files[i].saved { conflict = p; return }
        do {
            try Self.writeKeepingFile(files[i].text, to: p)
            files[i].saved = files[i].text
            note = "Saved \(files[i].name)"
            writeUnsaved()
        } catch { note = "Couldn't save: \(error.localizedDescription)".oneLine(160) }
    }

    /// Reload from disk; the typed text is first kept in unsaved/<name>.<time>.mine so it's never lost.
    func reload(_ p: String) {
        guard let i = files.firstIndex(where: { $0.path == p }) else { return }
        if files[i].dirty {
            let dir = (Self.unsavedFile as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let keep = dir + "/" + files[i].name + ".\(Int(Date().timeIntervalSince1970)).mine"
            FileManager.default.createFile(atPath: keep, contents: Data(files[i].text.utf8), attributes: [.posixPermissions: 0o600])
            note = "Reloaded. Your version is kept in \((keep as NSString).abbreviatingWithTildeInPath)"
        }
        if let d = FileManager.default.contents(atPath: p), let s = String(data: d, encoding: .utf8) { files[i].text = s; files[i].saved = s }
        writeUnsaved()
    }

    nonisolated static func writeKeepingFile(_ text: String, to path: String) throws {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: real)[.posixPermissions] as? NSNumber)?.int16Value
        let tmp = (real as NSString).deletingLastPathComponent + "/.\((real as NSString).lastPathComponent).heimdall-save"
        try Data(text.utf8).write(to: URL(fileURLWithPath: tmp))
        if let perms { try? fm.setAttributes([.posixPermissions: NSNumber(value: perms)], ofItemAtPath: tmp) }
        guard rename(tmp, real) == 0 else { try? fm.removeItem(atPath: tmp); throw CocoaError(.fileWriteUnknown) }
    }

    func close(_ path: String) {
        files.removeAll { $0.path == path }
        if current == path { current = files.last?.path }
        writeUnsaved()
    }

    var currentFile: OpenFile? { files.first { $0.path == current } }

    /// Existing files named in a room message (absolute or ~/ paths), so they can be opened with one click.
    nonisolated static func paths(in text: String) -> [String] {
        var found: [String] = []
        for raw in text.split(whereSeparator: { $0.isWhitespace || $0 == "`" || $0 == "\"" || $0 == "'" }) {
            var t = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]<>"))
            if let colon = t.range(of: ":", options: .backwards), Int(t[colon.upperBound...]) != nil { t = String(t[..<colon.lowerBound]) }
            guard t.hasPrefix("/") || t.hasPrefix("~/") else { continue }
            let p = (t as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, !found.contains(p) { found.append(p) }
            if found.count >= 3 { break }
        }
        return found
    }
}

/// Folder tree on the left of the Room tab.

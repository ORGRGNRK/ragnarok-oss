import Foundation

/// Receipts for work done from the Room terminal: what actually changed on disk while an AI answered, and whether
/// what it SAID it did ("Created `x`", "deleted y") matches the disk. One JSON line per answer in
/// ~/.ragnarok/terminal-receipts.jsonl (the timeline shows it; mismatches feed `heimdall-recall --failures`).
/// The claim check reads the reply's wording, so it can misread; the changed-files list is measured.
enum Receipts {
    nonisolated static let file = NSHomeDirectory() + "/.ragnarok/terminal-receipts.jsonl"

    struct Claim: Equatable { let verb: String; let path: String; let ok: Bool; let why: String }

    /// Files under `dir` modified at or after `since` (anything could have changed them, not only the AI).
    /// Skips the explorer's build/dependency folders and hidden folders; stops after 150k entries or 4 s.
    nonisolated static func changed(since: Date, under dir: String) -> [String] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: dir)
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        // the enumerator hands back resolved paths (/private/var/… for /var/…); report them under `dir` as given
        let real: String = { guard let r = realpath(dir, nil) else { return dir }; defer { free(r) }; return String(cString: r) }()
        func shown(_ p: String) -> String { p.hasPrefix(real + "/") && real != dir ? dir + p.dropFirst(real.count) : p }
        let deadline = Date().addingTimeInterval(4)
        var n = 0
        for case let u as URL in en {
            n += 1
            if n > 150_000 || Date() > deadline { break }
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if v?.isDirectory == true, WorkspaceModel.skip.contains(u.lastPathComponent) { en.skipDescendants(); continue }
            if let m = v?.contentModificationDate, m >= since.addingTimeInterval(-1) {
                // a folder's date changes when something inside is added/removed; report folders only if new-ish and empty-ish
                if v?.isDirectory == true, (try? fm.contentsOfDirectory(atPath: u.path).count) ?? 0 > 0 { continue }
                out.append(shown(u.path))
                if out.count >= 200 { break }
            }
        }
        return out.sorted()
    }

    nonisolated static let makeVerbs = ["created", "wrote", "written", "added", "saved", "updated", "edited", "modified", "changed", "made", "fixed"]
    nonisolated static let goneVerbs = ["deleted", "removed"]

    /// Paths the reply says it created/changed/deleted, checked against the disk.
    nonisolated static func claims(in reply: String, cwd: String, since: Date) -> [Claim] {
        var out: [Claim] = []
        let fm = FileManager.default
        for raw in reply.split(separator: "\n") {
            let line = String(raw)
            let low = line.lowercased()
            // first verb in the line decides; lines that say "didn't"/"not"/"will"/"would" aren't claims of done work
            guard let verb = (makeVerbs + goneVerbs).first(where: { low.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) else { continue }
            if low.range(of: #"\b(didn't|did not|not |won't|will |would |should |could |can |to be |if )"#, options: .regularExpression) != nil { continue }
            for token in pathTokens(line) {
                let p = resolve(token, cwd: cwd)
                guard !out.contains(where: { $0.path == p }) else { continue }
                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: p, isDirectory: &isDir)
                if goneVerbs.contains(verb) {
                    out.append(Claim(verb: verb, path: p, ok: !exists, why: exists ? "it is still there" : "gone, as said"))
                } else if !exists {
                    out.append(Claim(verb: verb, path: p, ok: false, why: "it doesn't exist"))
                } else {
                    let mod = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast
                    let fresh = mod >= since.addingTimeInterval(-1)
                    out.append(Claim(verb: verb, path: p, ok: fresh, why: fresh ? "changed during this answer" : "it exists but wasn't changed during this answer"))
                }
                if out.count >= 12 { return out }
            }
        }
        return out
    }

    /// `backticked things` that look like paths, and bare /abs or ~/ paths.
    nonisolated static func pathTokens(_ line: String) -> [String] {
        var t: [String] = []
        let ns = line as NSString
        for m in (try! NSRegularExpression(pattern: "`([^`\\n]{2,200})`")).matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("/") || s.hasPrefix("~/") || (s.contains("/") && !s.contains(" ")) || s.range(of: #"^[\w.-]+\.\w{1,8}$"#, options: .regularExpression) != nil {
                if !s.contains("://") && !s.hasPrefix("-") { t.append(s) }
            }
        }
        let bare = line.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        for w in bare.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) {
            let s = String(w).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]<>*"))
            if (s.hasPrefix("/") && s.count > 2 && s.dropFirst().contains("/")) || s.hasPrefix("~/") { t.append(s) }
        }
        return t
    }

    nonisolated static func resolve(_ token: String, cwd: String) -> String {
        let e = (token as NSString).expandingTildeInPath
        return e.hasPrefix("/") ? (e as NSString).standardizingPath : ((cwd as NSString).appendingPathComponent(e) as NSString).standardizingPath
    }

    nonisolated static func verdict(exit: Int32, claims: [Claim]) -> String {
        if exit != 0 && exit != 15 { return "failed" }
        if claims.contains(where: { !$0.ok }) { return "mismatch" }
        return claims.isEmpty ? "no-claims" : "verified"
    }

    /// One line for the terminal under the reply.
    nonisolated static func summary(changed: [String], claims: [Claim], verdict: String, cwd: String) -> String {
        func short(_ p: String) -> String { p.hasPrefix(cwd + "/") ? String(p.dropFirst(cwd.count + 1)) : (p as NSString).abbreviatingWithTildeInPath }
        var s = "🧾 receipt: "
        s += changed.isEmpty ? "no files changed in \((cwd as NSString).abbreviatingWithTildeInPath)"
            : "\(changed.count) file\(changed.count == 1 ? "" : "s") changed (" + changed.prefix(4).map(short).joined(separator: ", ") + (changed.count > 4 ? ", …" : "") + ")"
        let bad = claims.filter { !$0.ok }
        if !claims.isEmpty {
            s += " · claims checked: \(claims.count - bad.count) ✓"
            if !bad.isEmpty { s += ", \(bad.count) ✗ — " + bad.prefix(3).map { "said \($0.verb) \(short($0.path)) but \($0.why)" }.joined(separator: "; ") }
        }
        if verdict == "failed" { s += " · the AI exited with an error" }
        return s
    }

    nonisolated static func write(provider: String, question: String, cwd: String, start: Date, exit: Int32,
                                  changed: [String], claims: [Claim], verdict: String) {
        let d: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()), "provider": provider, "by": NSUserName(), "cwd": cwd,
            "question": String(question.prefix(300)), "seconds": Int(Date().timeIntervalSince(start)), "exit": Int(exit),
            "changed": changed, "claims": claims.map { ["verb": $0.verb, "path": $0.path, "ok": $0.ok, "why": $0.why] },
            "verdict": verdict,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
        let line = data + Data("\n".utf8)
        appendLine(file, line)
    }
}

extension Parsers {
    // MARK: Room terminal receipts (~/.ragnarok/terminal-receipts.jsonl, written by Receipts.write)
    static let terminalReceipts: Parser = { _, line in
        guard let d = json(line) else { return [] }
        let v = d["verdict"] as? String ?? "?"
        let n = (d["changed"] as? [Any])?.count ?? 0
        let mark = v == "verified" ? "✓" : v == "mismatch" ? "✗ claims don't match" : v == "failed" ? "✗ failed" : "·"
        return [Event(time: Time.parse(d["ts"] as? String) ?? Date(), actor: Actors.normalize(d["provider"] as? String ?? ""), host: "mac",
                      source: "terminal-receipts", kind: "change",
                      title: "terminal receipt \(mark): \(n) file\(n == 1 ? "" : "s") changed · \((d["question"] as? String ?? "").oneLine(80))",
                      body: pretty(d), session: "heimdall-terminal")]
    }
}

/// Report item 20: append with O_APPEND (one write() per line), so the app and the scripts writing the same log at the
/// same time can't overwrite each other's lines. New files are created 0600.
func appendLine(_ path: String, _ data: Data) {
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
}

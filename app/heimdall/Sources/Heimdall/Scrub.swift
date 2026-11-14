import Foundation

/// Local secret scrubber: everything an AI may read (Shell output, logs via bin/ragnarok-ai-log) goes through here first.
/// Runs on this Mac only; nothing is sent anywhere. Three layers:
///   1. known secret formats (cloud/API keys, tokens, private keys, JWTs, age secrets, user:pass@ and :pass@ in URLs,
///      key=value and key="quoted value" secrets, "the password is X", mysql -pPASSWORD); a private key read line by line
///      (filterStdin) stays hidden from its BEGIN line to its END line
///   2. exact values: secret-named environment variables (*KEY*, *TOKEN*, *SECRET*, *PASS*, *AUTH*, *CREDENTIAL*) from the
///      app and from a login zsh, plus any line in ~/.ragnarok/scrub-values (one value per line, yours to add; keep it 0600)
///   3. long random-looking strings (≥32 chars, mixed case + digits, high entropy, / and + count as part of them);
///      hex (commit hashes) and paths are kept
/// Replacements say what was hidden, never the value: [hidden:github-token], [hidden:env:OPENAI_API_KEY], [hidden:random].
enum Scrub {
    nonisolated static let patterns: [(String, String)] = [
        ("private-key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#),
        ("age-secret", #"AGE-(?:SECRET-KEY|PLUGIN-[A-Z0-9-]+?)-1[A-Z0-9]{20,}"#),
        ("anthropic-key", #"sk-ant-[A-Za-z0-9_-]{20,}"#),
        ("openai-key", #"sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}"#),
        ("xai-key", #"xai-[A-Za-z0-9]{20,}"#),
        ("github-token", #"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#),
        ("gitlab-token", #"glpat-[A-Za-z0-9_-]{20,}"#),
        ("slack-token", #"xox[abprs]-[A-Za-z0-9-]{10,}"#),
        ("aws-key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("google-key", #"AIza[0-9A-Za-z_-]{35}"#),
        ("stripe-key", #"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}"#),
        ("nocodb-token", #"nc_pat_[A-Za-z0-9_-]{16,}"#),
        ("jwt", #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
        ("bearer", #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"#),
        ("url-password", #"(?<=://)[^\s:/@]*:[^\s@/]+(?=@)"#),   // user:pw@ and :pw@ (redis)
        ("quoted-secret", #"(?i)\b[A-Z0-9_]*(?:password|passwd|passphrase|pwd|secret|token|api[_-]?key|apikey|auth|credential)[A-Z0-9_]*["']?\s*[:=]\s*(["'])(?!\[hidden)[^"'\n]{4,}\1"#),
        ("assignment", #"(?i)\b(?:[A-Z0-9_]*(?:password|passwd|passphrase|pwd|secret|token|api[_-]?key|apikey|auth|credential)[A-Z0-9_]*)\s*[:=]\s*["']?(?!\[hidden)[^\s"']{6,}"#),
        // "the passphrase is FAKEhorse…": only a value with a digit or capital, so "password is wrong" stays readable
        ("said-secret", #"\b(?i:password|passphrase|passwd|secret|token)\s+(?i:is|was)\s+(?!\[hidden)(?=\S*[0-9A-Z])\S{6,}"#),
    ]
    /// Rules that keep the command in front ($1) and hide only the value: `mysql -u root -pPASSWORD shop`.
    nonisolated static let keepPrefix: [(String, String)] = [
        ("db-password", #"(?i)(\b(?:mysql|mysqldump|mysqladmin|mariadb|mariadb-dump)\b[^\n]*?\s-p)(?!\[hidden)(\S+)"#),
    ]
    nonisolated(unsafe) static var compiledKeep: [(String, NSRegularExpression)] = keepPrefix.compactMap { n, p in
        (try? NSRegularExpression(pattern: p)).map { (n, $0) }
    }
    nonisolated(unsafe) static var compiled: [(String, NSRegularExpression)] = patterns.compactMap { n, p in
        (try? NSRegularExpression(pattern: p)).map { (n, $0) }
    }
    nonisolated(unsafe) static var values: [(String, String)] = []   // (label, exact secret value), longest first
    nonisolated(unsafe) static var loaded = false
    private static let lock = NSLock()

    nonisolated static let secretName = try! NSRegularExpression(pattern: #"(?i)(key|token|secret|pass|auth|credential|cookie|session)"#)

    /// Collect exact secret values once: app environment, a login zsh's environment, ~/.ragnarok/scrub-values.
    nonisolated static func loadValues(includeLoginShell: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        var found: [String: String] = [:]
        func take(_ env: [String: String]) {
            for (k, v) in env where v.count >= 8 && !v.hasPrefix("/") && !v.contains(" ")
                && secretName.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) != nil
                && !["SSH_AUTH_SOCK", "XPC_SERVICE_NAME", "TERM_SESSION_ID", "SECURITYSESSIONID"].contains(k) { found[v] = "env:" + k }
        }
        take(ProcessInfo.processInfo.environment)
        if includeLoginShell {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lic", "env -0"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment; env["RAGNAROK_RECEIPTS_TERMINAL"] = "0"; p.environment = env
            if (try? p.run()) != nil {
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
                let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); killer.cancel()
                var e: [String: String] = [:]
                for kv in d.split(separator: 0) { let s = String(decoding: kv, as: UTF8.self); if let i = s.firstIndex(of: "=") { e[String(s[..<i])] = String(s[s.index(after: i)...]) } }
                take(e)
            }
        }
        let file = NSHomeDirectory() + "/.ragnarok/scrub-values"
        for l in ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n") {
            let v = l.trimmingCharacters(in: .whitespaces); if v.count >= 6 && !v.hasPrefix("#") { found[v] = "listed" }
        }
        values = found.map { ($1, $0) }.sorted { $0.1.count > $1.1.count }
        loaded = true
    }

    nonisolated static func entropy(_ s: Substring) -> Double {
        var c: [Character: Int] = [:]; for ch in s { c[ch, default: 0] += 1 }
        let n = Double(s.count); return c.values.reduce(0) { $0 - (Double($1) / n) * log2(Double($1) / n) }
    }
    nonisolated static let randomish = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9+/_=-])[A-Za-z0-9+/_=-]{32,}(?![A-Za-z0-9+/_=-])"#)
    /// A path, not a key: starts with / , has no + or = , and no piece between slashes is longer than 40.
    nonisolated static func pathLike(_ w: Substring) -> Bool {
        w.hasPrefix("/") && !w.contains("+") && !w.contains("=") && !w.split(separator: "/").contains { $0.count > 40 }
    }

    nonisolated static func clean(_ text: String) -> String {
        if !loaded { loadValues() }
        var t = text
        for (label, v) in values where t.contains(v) { t = t.replacingOccurrences(of: v, with: "[hidden:\(label)]") }
        for (name, re) in compiledKeep {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1[hidden:\(name)]")
        }
        for (name, re) in compiled {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "[hidden:\(name)]")
        }
        // layer 3: random-looking runs (skip pure hex like commit hashes, and anything without upper+lower+digit)
        let ns = t as NSString
        var out = "", last = 0
        for m in randomish.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let w = Substring(ns.substring(with: m.range))
            let hex = w.allSatisfy { $0.isHexDigit }
            let mixed = w.contains(where: \.isUppercase) && w.contains(where: \.isLowercase) && w.contains(where: \.isNumber)
            guard !hex, mixed, !pathLike(w), entropy(w) >= 4.0 else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "[hidden:random]"
            last = m.range.location + m.range.length
        }
        return last == 0 ? t : out + ns.substring(from: last)
    }

    /// `Heimdall --scrub`: stdin → scrubbed stdout (used by bin/ragnarok-ai-log).
    /// Line by line, with memory: from `-----BEGIN … PRIVATE KEY-----` every line is hidden until the END line.
    struct Lines {
        var inKey = false
        nonisolated static let begin = #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, end = #"-----END [A-Z ]*PRIVATE KEY-----"#
        nonisolated mutating func feed(_ line: String) -> String {
            if inKey {
                guard let r = line.range(of: Self.end, options: .regularExpression) else { return "" }
                inKey = false
                let rest = String(line[r.upperBound...])
                return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : Scrub.clean(rest)
            }
            if let r = line.range(of: Self.begin, options: .regularExpression),
               line.range(of: Self.end, options: .regularExpression, range: r.upperBound..<line.endIndex) == nil {
                inKey = true
                return Scrub.clean(String(line[..<r.lowerBound])) + "[hidden:private-key]\n"
            }
            return Scrub.clean(line)
        }
    }

    nonisolated static func filterStdin() -> Never {
        loadValues()
        var lines = Lines()
        while let line = readLine(strippingNewline: false) { FileHandle.standardOutput.write(Data(lines.feed(line).utf8)) }
        exit(0)
    }
}

import Foundation

/// Local secret scrubber: everything an AI may read (Shell output, logs via bin/ragnarok-ai-log) goes through here first.
/// Runs on this Mac only; nothing is sent anywhere. Three layers:
///   1. known secret formats (cloud/API keys, tokens, private keys, JWTs, age secrets, user:pass@ in URLs, key=value secrets)
///   2. exact values: secret-named environment variables (*KEY*, *TOKEN*, *SECRET*, *PASS*, *AUTH*, *CREDENTIAL*) from the
///      app and from a login zsh, plus any line in ~/.ragnarok/scrub-values (one value per line, yours to add; keep it 0600)
///   3. long random-looking strings (≥32 chars, mixed case + digits, high entropy); hex (commit hashes) and paths are kept
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
        ("url-password", #"(?<=://)[^\s:/@]+:[^\s@/]+(?=@)"#),
        ("assignment", #"(?i)\b(?:[A-Z0-9_]*(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|auth|credential)[A-Z0-9_]*)\s*[:=]\s*["']?(?!\[hidden)[^\s"']{6,}"#),
    ]
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
    nonisolated static let randomish = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9+_=-])[A-Za-z0-9+_=-]{32,}(?![A-Za-z0-9+_=-])"#)

    nonisolated static func clean(_ text: String) -> String {
        if !loaded { loadValues() }
        var t = text
        for (label, v) in values where t.contains(v) { t = t.replacingOccurrences(of: v, with: "[hidden:\(label)]") }
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
            guard !hex, mixed, entropy(w) >= 4.0 else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "[hidden:random]"
            last = m.range.location + m.range.length
        }
        return last == 0 ? t : out + ns.substring(from: last)
    }

    /// `Heimdall --scrub`: stdin → scrubbed stdout (used by bin/ragnarok-ai-log).
    nonisolated static func filterStdin() -> Never {
        loadValues()
        while let line = readLine(strippingNewline: false) { FileHandle.standardOutput.write(Data(clean(line).utf8)) }
        exit(0)
    }
}

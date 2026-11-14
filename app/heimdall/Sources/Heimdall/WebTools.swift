import Foundation

/// Web tools for the local model (alexus) in the Room terminal: web_search (DuckDuckGo's plain HTML page, no key)
/// and fetch_page (GET one public web page, as text). Both run on this Mac. Nothing is POSTed, but every GET goes out:
/// the search words to DuckDuckGo, and each page URL (chosen by Heimdall or by the model) to that site.
/// The model can put any text it has seen (including the open file) into a URL it asks for. fetch_page refuses local/private addresses.
enum WebTools {
    struct Call { let name: String; let args: [String: Any]; var id: String = ""
        var arg: String { (args["query"] ?? args["url"]).map { "\($0)" } ?? "" } }

    /// Where the local model runs, chosen in the Alexus tab ("Run on").
    enum Backend { case ollama(model: String), openAI(base: String, model: String), apple(useCase: String) }

    // MARK: HTTP via curl
    // The app's own URLSession got "offline" for Alexus's LAN address (2026-10-31, see Chat.swift); curl as a child
    // process works, so every request here goes through curl. Redirects are followed by hand so each hop is checked.

    struct Response { let code: Int; let body: Data; let type: String }

    /// resolve: "host:port:ip" pins curl to an address we already checked, so DNS can't change between check and fetch.
    static func curl(_ url: String, body: Data? = nil, timeout: Int = 30, maxBytes: Int = 3_000_000, resolve: String? = nil) async -> Response? {
        var args = ["-sS", "--proto", "=http,https", "--max-time", "\(timeout)", "--max-filesize", "\(maxBytes)",
                    "-A", ua, "-w", "\n__HC__%{http_code} %{content_type}\n__LOC__%{redirect_url}"]
        if let resolve { args += ["--resolve", resolve, "--noproxy", "*"] }
        if body != nil { args += ["-H", "Content-Type: application/json", "--data-binary", "@-"] }
        args.append(url)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); p.arguments = args
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = Pipe()
        let out: Data? = await withTaskCancellationHandler {
            await withCheckedContinuation { (k: CheckedContinuation<Data?, Never>) in
                DispatchQueue.global().async {
                    do { try p.run() } catch { k.resume(returning: nil); return }
                    if let body { i.fileHandleForWriting.write(body) }
                    try? i.fileHandleForWriting.close()
                    // report item 26: --max-filesize doesn't stop chunked pages, so stop reading past the cap ourselves
                    var d = Data(); let h = o.fileHandleForReading
                    while true {
                        let c = h.availableData
                        if c.isEmpty { break }
                        d.append(c)
                        if d.count > maxBytes + 4096 { p.terminate(); d = d.prefix(maxBytes) + Data("\n__HC__0 toolarge\n__LOC__".utf8); break }
                    }
                    p.waitUntilExit()
                    k.resume(returning: d)
                }
            }
        } onCancel: { p.terminate() }
        guard let out, let r = out.range(of: Data("\n__HC__".utf8), options: .backwards) else { return nil }
        let tail = String(decoding: out[r.upperBound...], as: UTF8.self)
        let first = tail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let hc = first.first.map(String.init) ?? ""
        let code = Int(hc.split(separator: " ").first ?? "") ?? 0
        let type = hc.split(separator: " ").dropFirst().joined(separator: " ")
        let loc = first.count > 1 ? String(first[1]).replacingOccurrences(of: "__LOC__", with: "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return Response(code: code, body: Data(out[..<r.lowerBound]), type: loc.isEmpty ? type : "redirect:" + loc)
    }

    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static let toolSpecs: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "web_search",
            "description": "Search the web (DuckDuckGo) for current information. Returns titles, URLs and short snippets.",
            "parameters": ["type": "object", "properties": ["query": ["type": "string", "description": "search words"]], "required": ["query"]]]],
        ["type": "function", "function": [
            "name": "fetch_page",
            "description": "Read the text of one web page, e.g. a result from web_search. Use it to get exact steps or facts.",
            "parameters": ["type": "object", "properties": ["url": ["type": "string", "description": "full https URL"]], "required": ["url"]]]],
        ["type": "function", "function": [
            "name": "search_files",
            "description": "Search \(LocalConfig.owner)'s own code and notes on their Mac by meaning (not the web). Returns the most relevant excerpts with their file paths. Set failures=true to get past failures on their Mac instead.",
            "parameters": ["type": "object", "properties": [
                "query": ["type": "string", "description": "what you are looking for, in words"],
                "failures": ["type": "boolean", "description": "true = past failures related to the query"]], "required": ["query"]]]],
    ]

    // MARK: Ollama

    /// One reply (not streamed) from Ollama or an OpenAI-style server, with the tools offered when `tools` is true.
    static func chat(_ b: Backend, messages: [[String: Any]], tools: Bool) async throws -> [String: Any] {
        var body: [String: Any] = ["messages": messages, "stream": false]
        if tools { body["tools"] = toolSpecs }
        let url: String
        switch b {
        case .ollama(let m): body["model"] = m; url = ChatModel.ollama.absoluteString
        case .openAI(let base, let m):
            guard !m.isEmpty else { throw NSError(domain: "local", code: 2, userInfo: [NSLocalizedDescriptionKey: "pick a model for the other server in the Alexus tab first"]) }
            body["model"] = m; url = LocalModels.base(base) + "/v1/chat/completions"
        case .apple: throw NSError(domain: "local", code: 3, userInfo: [NSLocalizedDescriptionKey: "Apple's model has no tool calls"])
        }
        try Task.checkCancellation()
        guard let r = await curl(url, body: try JSONSerialization.data(withJSONObject: body), timeout: 300, maxBytes: 20_000_000) else {
            try Task.checkCancellation()
            throw NSError(domain: "local", code: 4, userInfo: [NSLocalizedDescriptionKey: "no answer from \(url)"])
        }
        guard let d = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
            throw NSError(domain: "local", code: 5, userInfo: [NSLocalizedDescriptionKey: "HTTP \(r.code) from \(url): " + String(decoding: r.body.prefix(200), as: UTF8.self)])
        }
        if let e = d["error"] { throw NSError(domain: "local", code: 1, userInfo: [NSLocalizedDescriptionKey: "\((e as? [String: Any])?["message"] ?? e)"]) }
        if let m = d["message"] as? [String: Any] { return m }
        return ((d["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
    }

    /// Tool calls from a reply: proper `tool_calls`, or (qwen2.5-coder) a JSON object written as the content.
    static func toolCalls(_ msg: [String: Any]) -> [Call] {
        if let tc = msg["tool_calls"] as? [[String: Any]], !tc.isEmpty {
            return tc.compactMap { c in
                guard let f = c["function"] as? [String: Any], let n = f["name"] as? String else { return nil }
                let a = (f["arguments"] as? [String: Any])
                    ?? ((f["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }) ?? [:]
                return Call(name: n, args: a, id: c["id"] as? String ?? "")
            }
        }
        var text = (msg["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") { text = text.split(separator: "\n").dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n") }
        guard text.hasPrefix("{"), let d = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let n = d["name"] as? String, ["web_search", "fetch_page"].contains(n) else { return [] }
        return [Call(name: n, args: d["arguments"] as? [String: Any] ?? d["parameters"] as? [String: Any] ?? [:])]
    }

    static func run(_ c: Call) async -> String {
        switch c.name {
        case "web_search":
            guard let q = c.args["query"] as? String, !q.isEmpty else { return "error: no query" }
            return await search(q)
        case "fetch_page":
            guard let u = c.args["url"] as? String else { return "error: no url" }
            return await fetch(u)
        case "search_files":
            guard let q = c.args["query"] as? String, !q.isEmpty else { return "error: no query" }
            let f = (c.args["failures"] as? Bool) ?? ((c.args["failures"] as? String) == "true")
            return await Recall.cli(f ? ["--failures", q, "5"] : [q, "5"]) ?? "error: heimdall-recall isn't available"
        default: return "error: unknown tool \(c.name)"
        }
    }

    // MARK: Search

    /// DuckDuckGo first; if it answers with its bot check (HTTP 202) or nothing, Bing. Both are plain HTML pages, no key.
    static func search(_ q: String) async -> String {
        var results: [(title: String, url: String, snippet: String)] = []
        var engine = "DuckDuckGo"
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        if let r = await curl(c.url!.absoluteString, timeout: 20), r.code == 200 { results = parseDDG(String(decoding: r.body, as: UTF8.self)) }
        if results.isEmpty {
            engine = "Bing"
            var b = URLComponents(string: "https://www.bing.com/search")!
            b.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "setlang", value: "en")]
            if let r = await curl(b.url!.absoluteString, timeout: 20), r.code == 200 { results = parseBing(String(decoding: r.body, as: UTF8.self)) }
        }
        if results.isEmpty { return "SEARCH FAILED: no search engine answered (DuckDuckGo and Bing both blocked or offline). You have no web results." }
        return "(results from \(engine))\n" + results.prefix(6).enumerated().map { "\($0 + 1). \($1.title)\n   \($1.url)\n   \($1.snippet)" }.joined(separator: "\n")
    }

    static func parseBing(_ html: String) -> [(title: String, url: String, snippet: String)] {
        let blocks = html.components(separatedBy: "<li class=\"b_algo\"").dropFirst()
        return blocks.compactMap { blk in
            guard let m = matches(#"<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, blk).first else { return nil }
            var url = unescape(m[0])
            if let c = URLComponents(string: url), c.host?.hasSuffix("bing.com") == true,
               var u = c.queryItems?.first(where: { $0.name == "u" })?.value, u.hasPrefix("a1") {
                u = String(u.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while u.count % 4 != 0 { u += "=" }
                if let d = Data(base64Encoded: u), let real = String(data: d, encoding: .utf8) { url = real }
            }
            guard url.hasPrefix("http"), !(URL(string: url)?.host?.hasSuffix("bing.com") ?? true) else { return nil }
            let snip = matches(#"<p[^>]*>(.*?)</p>"#, blk).first.map { text($0[0]) } ?? ""
            return (text(m[1]), url, snip)
        }
    }

    static func parseDDG(_ html: String) -> [(title: String, url: String, snippet: String)] {
        let a = matches(#"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, html)
        let sn = matches(#"class="result__snippet"[^>]*>(.*?)</(?:a|td|div)>"#, html).map { $0[0] }
        var out: [(String, String, String)] = []
        for (i, m) in a.enumerated() {
            var url = unescape(m[0])
            if let c = URLComponents(string: url.hasPrefix("//") ? "https:" + url : url),
               let real = c.queryItems?.first(where: { $0.name == "uddg" })?.value { url = real }
            if url.contains("duckduckgo.com/y.js") { continue }      // ads
            out.append((text(m[1]), url, i < sn.count ? text(sn[i]) : ""))
        }
        return out
    }

    /// First `count` result URLs from a `search` result text (lines that are just a URL).
    static func topURLs(_ results: String, count: Int) -> [String] {
        results.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("http") && !$0.contains(" ") }.prefix(count).map { $0 }
    }

    // MARK: Fetch

    // Break-test K1: the old name check let 127.1, 0x7f.0.0.1, localhost., router.lan etc. through. Now the host is
    // resolved and EVERY address must be public; curl is then pinned to that address (--resolve).
    static let blockedSuffixes = [".localhost", ".local", ".lan", ".home", ".home.arpa", ".internal", ".intranet", ".corp",
                                  ".private", ".ts.net", ".localdomain"]

    /// Quick name-only check (no DNS): scheme, and obviously local names.
    static func isPublic(_ u: URL) -> Bool {
        guard let s = u.scheme?.lowercased(), s == "https" || s == "http", var h = u.host?.lowercased(), !h.isEmpty else { return false }
        while h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" || !h.contains(".") || blockedSuffixes.contains(where: { h.hasSuffix($0) }) { return false }
        if u.user != nil || u.password != nil { return false }
        // numeric hosts in any spelling (127.1, 0x7f.0.0.1, 0177.0.0.1, 2130706433) are decoded and range-checked
        var v4 = in_addr()
        if inet_aton(h, &v4) != 0 { return isPublicIPv4(withUnsafeBytes(of: &v4) { Array($0) }) }
        if h.contains(":") || h.hasPrefix("[") {
            var v6 = in6_addr(); let bare = h.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return inet_pton(AF_INET6, bare, &v6) == 1 && isPublicIPv6(withUnsafeBytes(of: &v6) { Array($0) })
        }
        if h.allSatisfy({ $0.isNumber || $0 == "." || $0 == "x" }) && h.first?.isNumber == true { return false }  // odd numeric forms
        return true
    }

    static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        let (a, c) = (b[0], b[1])
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }                 // this-net, private, loopback, multicast, reserved
        if a == 100 && (64...127).contains(c) { return false }                          // CGNAT / Tailscale
        if a == 169 && c == 254 { return false }                                        // link-local
        if a == 172 && (16...31).contains(c) { return false }
        if a == 192 && c == 168 { return false }
        if a == 192 && c == 0 && (b[2] == 0 || b[2] == 2) { return false }              // IETF, TEST-NET-1
        if a == 198 && (c == 18 || c == 19) { return false }                            // benchmarking
        if a == 198 && c == 51 && b[2] == 100 { return false }
        if a == 203 && c == 0 && b[2] == 113 { return false }
        return true
    }

    static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPublicIPv4(Array(b[12...])) }   // v4-mapped
        if b[0..<4] == [0x00, 0x64, 0xff, 0x9b] { return isPublicIPv4(Array(b[12...])) }                                // NAT64
        guard (b[0] & 0xe0) == 0x20 else { return false }                               // only global unicast 2000::/3
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false } // documentation
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0 && b[3] == 0 { return false }       // Teredo
        if b[0] == 0x20 && b[1] == 0x02 { return false }                                 // 6to4 (embeds any v4)
        return true
    }

    /// Resolves the host; returns the curl --resolve value only if every address is public, else nil.
    static func publicPin(_ u: URL) -> String? {
        guard isPublic(u), var h = u.host?.lowercased() else { return nil }
        while h.hasSuffix(".") { h.removeLast() }
        let bare = h.hasPrefix("[") ? String(h.dropFirst().dropLast()) : h
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(bare, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var pin: String?
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            let a = ai.pointee
            if a.ai_family == AF_INET, let sa = a.ai_addr {
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let bytes = withUnsafeBytes(of: &sin.sin_addr) { Array($0) }
                guard isPublicIPv4(bytes) else { return nil }
                if pin == nil { pin = bytes.map(String.init).joined(separator: ".") }
            } else if a.ai_family == AF_INET6, let sa = a.ai_addr {
                var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                let bytes = withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }
                guard isPublicIPv6(bytes) else { return nil }
                if pin == nil {
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &sin6.sin6_addr, &buf, socklen_t(buf.count))
                    pin = "[" + String(cString: buf) + "]"
                }
            } else { return nil }
            p = a.ai_next
        }
        guard let ip = pin else { return nil }
        let port = u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80)
        return "\(u.host!):\(port):\(ip)"
    }

    static func fetch(_ s: String) async -> String {
        guard var u = URL(string: s.trimmingCharacters(in: .whitespaces)), isPublic(u) else { return "error: only public http(s) web pages can be read" }
        for _ in 0..<6 {
            let target = u
            guard let pin = await Task.detached(operation: { publicPin(target) }).value else {
                return "error: only public web pages can be read (\(u.host ?? "?") is local, private or doesn't resolve)"
            }
            guard let r = await curl(u.absoluteString, timeout: 20, resolve: pin) else { return "error: could not load \(u.absoluteString)" }
            if r.type.hasPrefix("redirect:") {
                guard let next = URL(string: String(r.type.dropFirst(9)), relativeTo: u)?.absoluteURL, isPublic(next) else {
                    return "error: page redirected to a local or odd address"
                }
                u = next; continue
            }
            if r.code >= 400 || r.code == 0 { return "error: HTTP \(r.code) for \(u.absoluteString)" }
            let body = String(decoding: r.body, as: UTF8.self)
            let t = r.type.contains("html") || body.contains("<html") ? text(body) : body
            let cap = 6000
            return "Page \(u.absoluteString):\n" + (t.count > cap ? String(t.prefix(cap)) + "\n… (cut)" : t)
        }
        return "error: too many redirects"
    }

    /// The parts of a long page that match the question, in page order, within `budget` characters.
    /// Lines score by question words they contain (plus Mac words, since the owner is on a Mac), and extra if they
    /// look like a command. Each picked line brings its neighbours for context. Falls back to the start of the page.
    static func relevant(_ page: String, question: String, budget: Int) -> String {
        if page.count <= budget { return page }
        let stop: Set<String> = ["the", "and", "for", "how", "what", "can", "you", "with", "this", "that", "does", "are", "my", "do", "is", "to", "of", "in", "on", "it", "me", "i", "a"]
        var words = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !stop.contains($0) })
        words.formUnion(["mac", "macos"])
        let lines = page.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var score = [Int](repeating: 0, count: lines.count)
        for (i, l) in lines.enumerated() where l.count >= 3 {
            let low = l.lowercased()
            score[i] = words.reduce(0) { $0 + (low.contains($1) ? 1 : 0) }
            if score[i] > 0, low.range(of: #"(^\$ |npm |brew |curl |pip3? |sudo |\| ?sh\b|git clone)"#, options: .regularExpression) != nil { score[i] += 2 }
        }
        let ranked = score.indices.filter { score[$0] > 0 }.sorted { score[$0] != score[$1] ? score[$0] > score[$1] : $0 < $1 }
        if ranked.isEmpty { return String(page.prefix(budget)) }
        var keep = Set<Int>(), used = 0
        for i in ranked {
            for j in max(0, i - 1)...min(lines.count - 1, i + 1) where !keep.contains(j) && !lines[j].isEmpty {
                if used + lines[j].count + 1 > budget { break }
                keep.insert(j); used += lines[j].count + 1
            }
            if used >= budget - 40 { break }
        }
        var out: [String] = [], last = -2
        for i in keep.sorted() { if i != last + 1 && !out.isEmpty { out.append("…") }; out.append(lines[i]); last = i }
        return out.joined(separator: "\n")
    }

    // MARK: Text helpers

    static func text(_ html: String) -> String {
        var t = html
        for tag in ["script", "style", "noscript", "svg", "head", "nav", "footer"] {
            t = t.replacingOccurrences(of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr|/pre)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = unescape(t)
        t = t.replacingOccurrences(of: "[ \t\u{00A0}]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s*\n\\s*(\n\\s*)+", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unescape(_ s: String) -> String {
        var t = s
        for (k, v) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }

    static func matches(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
}

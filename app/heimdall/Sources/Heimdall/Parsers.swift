import Foundation

/// Turn one log line into events. Each feed has its own format; unknown shapes fall back to raw text.
enum Parsers {
    typealias Parser = (_ path: String, _ line: String) -> [Event]

    static func json(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func pretty(_ v: Any?) -> String {
        guard let v else { return "" }
        if let s = v as? String { return s }
        if JSONSerialization.isValidJSONObject(v),
           let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) { return s }
        return "\(v)"
    }

    static func sessionName(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if let i = parts.firstIndex(where: { $0 == "brain" }), i + 1 < parts.count { return String(parts[i + 1].prefix(8)) }
        return String((parts.last ?? "").replacingOccurrences(of: ".jsonl", with: "").prefix(8))
    }

    // MARK: Claude Code transcripts (~/.claude/projects/*/*.jsonl)
    static let claude: Parser = { path, line in
        guard let d = json(line), let type = d["type"] as? String, type == "user" || type == "assistant",
              let msg = d["message"] as? [String: Any] else { return [] }
        let t = Time.parse(d["timestamp"] as? String) ?? Date()
        let s = sessionName(path)
        func ev(_ actor: String, _ kind: String, _ title: String, _ body: String) -> Event {
            Event(time: t, actor: actor, host: "mac", source: "claude-code", kind: kind, title: title, body: body, session: s)
        }
        if let text = msg["content"] as? String {
            return [type == "user" ? ev("owner", "prompt", "→ Claude: " + text.oneLine(), text) : ev("claude", "said", text.oneLine(), text)]
        }
        guard let items = msg["content"] as? [[String: Any]] else { return [] }
        var out: [Event] = []
        for it in items {
            switch it["type"] as? String {
            case "text":
                let text = it["text"] as? String ?? ""
                out.append(type == "user" ? ev("owner", "prompt", "→ Claude: " + text.oneLine(), text) : ev("claude", "said", text.oneLine(), text))
            case "tool_use":
                let name = it["name"] as? String ?? "tool"
                let input = it["input"] as? [String: Any] ?? [:]
                let headline = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["description"] as? String) ?? ""
                out.append(ev("claude", "tool", "\(name): \(headline.oneLine())", pretty(input)))
            case "tool_result":
                let c = it["content"]
                var text = ""
                if let s = c as? String { text = s } else if let arr = c as? [[String: Any]] { text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                out.append(ev("claude", "result", "result: " + text.oneLine(), text))
            default: break
            }
        }
        return out
    }

    // MARK: Antigravity / Argon (~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl)
    static let argon: Parser = { path, line in
        guard let d = json(line), let type = d["type"] as? String else { return [] }
        let t = Time.parse(d["created_at"] as? String) ?? Date()
        let s = sessionName(path)
        let content = d["content"] as? String ?? ""
        func ev(_ actor: String, _ kind: String, _ title: String, _ body: String) -> Event {
            Event(time: t, actor: actor, host: "mac", source: "antigravity", kind: kind, title: title, body: body, session: s)
        }
        switch type {
        case "USER_INPUT":
            var req = content
            if let a = content.range(of: "<USER_REQUEST>"), let b = content.range(of: "</USER_REQUEST>") {
                req = String(content[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return [ev("owner", "prompt", "→ Argon: " + req.oneLine(), content)]
        case "PLANNER_RESPONSE":
            var out: [Event] = []
            if !content.isEmpty { out.append(ev("argon", "said", content.oneLine(), content)) }
            if let calls = d["tool_calls"] { out.append(ev("argon", "tool", "tools: " + pretty(calls).oneLine(), pretty(calls))) }
            return out
        case "GENERIC":
            return content.isEmpty ? [] : [ev("argon", "result", "result: " + content.oneLine(), content)]
        case "SYSTEM_MESSAGE":
            guard content.contains("📯") || content.contains("Stop hook blocked") else { return [] }
            return [ev("argon", "hook", "📯 Gjallarhorn: " + content.oneLine(), content)]
        default:
            return []
        }
    }

    // MARK: Grok CLI (~/.grok/sessions/*/*/chat_history.jsonl) — no timestamps in the file
    static let grok: Parser = { path, line in
        guard let d = json(line), let type = d["type"] as? String else { return [] }
        let s = sessionName(path)
        // report item 24: use the line's own time, so backfilled history isn't stamped "now"
        let when = Time.parse(d["timestamp"] as? String ?? d["ts"] as? String) ?? Date()
        func ev(_ actor: String, _ kind: String, _ title: String, _ body: String) -> Event {
            Event(time: when, actor: actor, host: "mac", source: "grok-cli", kind: kind, title: title, body: body, session: s)
        }
        switch type {
        case "user":
            let c = pretty(d["content"]); return [ev("owner", "prompt", "→ Grok: " + c.oneLine(), c)]
        case "assistant":
            let c = pretty(d["content"]); return c.isEmpty ? [] : [ev("grok", "said", c.oneLine(), c)]
        case "reasoning":
            let parts = (d["summary"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            return parts.isEmpty ? [] : [ev("grok", "said", "thinking: " + parts.oneLine(), parts + "\n\n(full reasoning is stored encrypted by Grok)")]
        default:
            return [ev("grok", "tool", type + ": " + pretty(d).oneLine(), pretty(d))]
        }
    }

    // MARK: Mac AI receipts (~/.ragnarok/receipts-spool.jsonl, written by receipt.mjs)
    static let macReceipts: Parser = { _, line in
        guard let d = json(line) else { return [] }
        let actor = Actors.normalize(d["actor"] as? String ?? "")
        let cmd = (d["command"] as? String) ?? (d["record_ref"] as? String) ?? ""
        let tool = d["tool"] as? String ?? (d["kind"] as? String ?? "")
        let rawKind = (d["kind"] as? String ?? "").lowercased()
        let kind = ["read", "change", "command", "tool"].contains(rawKind) ? rawKind : "command"
        return [Event(time: Time.parse(d["at"] as? String) ?? Date(), actor: actor, host: "mac", source: "mac-receipts",
                      kind: kind, title: "\(tool) exit \(d["exit_code"].map { "\($0)" } ?? "?"): \(cmd.oneLine())",
                      body: pretty(d), session: String((d["session"] as? String ?? "").prefix(8)))]
    }

    // Codex desktop records tools that do not necessarily pass through command hooks.
    // Keep metadata only. Never ingest model reasoning, messages, tool arguments/results, or screenshots.
    static let codexTools: Parser = { path, line in
        guard let d=json(line),d["type"] as? String == "event_msg",
              let payload=d["payload"] as? [String:Any],payload["type"] as? String == "item_completed",
              let item=payload["item"] as? [String:Any],let type=item["type"] as? String else{return []}
        let title:String
        if type == "McpToolCall" {
            title="MCP: \(item["server"] as? String ?? "unknown").\(item["tool"] as? String ?? "unknown")"
        } else if type == "Extension" {
            title="Tool: \(item["kind"] as? String ?? "extension")"
        } else {return []} // Shell commands already have command receipts; don't duplicate them.
        let safe=Scrub.clean(title)
        let status=Scrub.clean(item["status"] as? String ?? "recorded")
        let session=String((payload["thread_id"] as? String ?? sessionName(path)).prefix(8))
        return [Event(time:Time.parse(d["timestamp"] as? String) ?? Date(),actor:"codex",host:"mac",source:"codex-tools",kind:"tool",
                      title:safe+" · "+status,body:safe+"\nStatus: "+status+"\nSource: Codex local transcript metadata. Arguments, results and model messages are not included.",session:session)]
    }

    // MARK: the owner's own shell commands (~/.ragnarok/user-commands.jsonl, written by the zsh hook)
    static let ownerShell: Parser = { _, line in
        guard let d = json(line) else { return [] }
        let cmd = Scrub.clean(d["cmd"] as? String ?? "")   // older lines were logged unmasked; scrub before showing
        let rc = d["exit"].map { "\($0)" } ?? "?"
        let src = d["src"] as? String ?? "zsh"
        return [Event(time: Time.parse(d["ts"] as? String) ?? Date(), actor: "owner", host: "mac", source: src,
                      kind: "command", title: "$ \(cmd.oneLine())  (exit \(rc))",
                      body: "\(cmd)\n\ncwd: \(d["cwd"] as? String ?? "")\nexit: \(rc)", session: src)]
    }

    // MARK: Alexus: every AI SSH command (/var/log/ragnarok/ai_ssh_receipts.jsonl)
    static let alexusReceipts: Parser = { _, line in
        guard let d = json(line) else { return [] }
        let raw = d["actor"] as? String ?? ""   // e.g. claude@alexus
        let actor = Actors.normalize(String(raw.split(separator: "@").first ?? ""))
        let cmd = d["cmd"] as? String ?? ""
        return [Event(time: Time.parse(d["ts"] as? String) ?? Date(), actor: actor, host: "alexus", source: "ai-ssh-receipts",
                      kind: "command", title: "$ \(cmd.oneLine())  (\(d["status"] as? String ?? ""))", body: pretty(d), session: raw)]
    }

    // MARK: Heimdall's own edits, installs, crashes and rollbacks (~/.ragnarok/heimdall-edits.jsonl)
    static let edits: Parser = { _, line in
        guard let d = json(line) else { return [] }
        let who = d["who"] as? String ?? ""
        let actor: String
        switch who {
        case "manual": actor = "owner"
        case "launcher": actor = "heimdall"
        case "gemini": actor = "gemini"
        default: actor = who.hasPrefix("api:") ? who : Actors.normalize(who)
        }
        let step = d["step"] as? String ?? ""
        let ok = d["ok"] as? Bool ?? true
        let detail = d["detail"] as? String ?? ""
        return [Event(time: Time.parse(d["ts"] as? String) ?? Date(), actor: actor, host: "mac", source: "heimdall-edit",
                      kind: step == "ai" ? "said" : "edit", title: "\(ok ? "" : "✗ ")edit \(step): \(detail.oneLine())",
                      body: pretty(d), session: d["edit"] as? String ?? "")]
    }

    // MARK: Project self-healing runs (~/.ragnarok/ragnarok-heal.jsonl)
    static let heal: Parser = { _, line in
        guard let d = json(line) else { return [] }
        let who = d["who"] as? String ?? ""
        let actor = who == "manual" ? "owner" : (who.hasPrefix("api:") ? who : Actors.normalize(who))
        let step = d["step"] as? String ?? ""
        let ok = d["ok"] as? Bool ?? true
        let detail = d["detail"] as? String ?? ""
        let project = ((d["project"] as? String ?? "") as NSString).lastPathComponent
        let prefix = project.isEmpty ? "heal" : "heal \(project)"
        return [Event(time: Time.parse(d["ts"] as? String) ?? Date(), actor: actor, host: "mac", source: "ragnarok-heal",
                      kind: step == "ai" ? "said" : "edit", title: "\(ok ? "" : "✗ ")\(prefix) \(step): \(detail.oneLine())",
                      body: pretty(d), session: d["heal"] as? String ?? "")]
    }

    // MARK: Ragnarok app-level errors (~/.ragnarok/ragnarok-app-errors.jsonl)
    static let appErrors: Parser = { _, line in
        let clean = Scrub.clean(line)
        guard let d = json(clean) else { return [] }
        let area = d["area"] as? String ?? "app"
        let message = d["message"] as? String ?? "error"
        let domain = d["domain"] as? String
        let code = d["code"].map { " (\($0))" } ?? ""
        let detail = [domain, message].compactMap { $0 }.joined(separator: ": ")
        func label(_ key: String) -> String {
            guard let value = d[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !["unknown", "unverified"].contains(value.lowercased()) else { return "Unverified" }
            return value
        }
        let attribution = ["actor", "os_user", "origin", "run_id", "incident_id", "build"]
            .map { "\($0): \(label($0))" }.joined(separator: "\n")
        let run = label("run_id")
        return [Event(time: Time.parse(d["ts"] as? String) ?? Date(), actor: label("actor"), host: "mac",
                      source: "ragnarok-app-error", kind: "error", title: "\(area)\(code): \(message.oneLine())",
                      body: detail + "\n" + attribution,
                      session: run == "Unverified" ? (d["process_session"] as? String ?? area) : run)]
    }

    // MARK: Alexus chat inside Heimdall (~/.ragnarok/heimdall-chat.jsonl)
    static let chat: Parser = { _, line in
        guard let d = json(line) else { return [] }
        let role = d["role"] as? String ?? ""
        let text = d["content"] as? String ?? ""
        let actor = role == "user" ? "owner" : "alexus"
        let title = role == "user" ? "→ Alexus: " + text.oneLine() : (role == "seal" ? "chat " + text.oneLine() : text.oneLine())
        return [Event(time: Time.parse(d["ts"] as? String) ?? Date(), actor: actor, host: "alexus", source: "alexus-chat",
                      kind: role == "user" ? "prompt" : (role == "seal" ? "change" : "said"), title: title, body: text,
                      session: d["session"] as? String ?? "")]
    }

    // MARK: The shared room on Alexus (`room watch`, see room/room.py). "by" comes from the file owner on Alexus.
    /// `room watch` replays its last 50 messages every time the ssh connection is remade, so ids already shown are skipped.
    private static let roomSeen = RoomSeen()
    final class RoomSeen: @unchecked Sendable {
        private var ids = Set<String>(); private let lock = NSLock()
        func firstTime(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.insert(id).inserted }
    }
    static let room: Parser = { _, line in
        guard let d = json(line), let id = d["id"] as? String, roomSeen.firstTime(id) else { return [] }
        let by = d["by"] as? String ?? "?"
        let verified = !(d["unverified"] as? Bool ?? false)
        let actor = verified ? Actors.normalize(by) : "unknown"
        let type = d["type"] as? String ?? "say"
        let text = d["text"] as? String ?? ""
        let ref = d["ref"] as? String ?? ""
        let title: String
        switch type {
        case "task": title = "room task \(id): \(text.oneLine())"
        case "claim": title = "room: claimed task \(ref)" + (text.isEmpty ? "" : " — \(text.oneLine())")
        case "done": title = "room: finished task \(ref)" + (text.isEmpty ? "" : " — \(text.oneLine())")
        default: title = "room: \(text.oneLine())"
        }
        return [Event(time: Time.parse(d["ts"] as? String) ?? Date(), actor: actor, host: "alexus", source: "room",
                      kind: type == "say" ? "said" : "change", title: (verified ? "" : "⚠︎ unverified (\(by)) ") + title,
                      body: pretty(d), session: "room")]
    }

    // MARK: Alexus: auditd lines tagged key="ai_*"
    static let audit: Parser = { _, line in
        func field(_ name: String) -> String? {
            guard let r = line.range(of: " \(name)=") else { return nil }
            let rest = line[r.upperBound...]
            if rest.first == "\"" { return rest.dropFirst().split(separator: "\"").first.map(String.init) }
            return rest.split(separator: " ").first.map(String.init)
        }
        var t = Date()
        if let r = line.range(of: "msg=audit("), let end = line[r.upperBound...].firstIndex(of: ":"),
           let secs = Double(line[r.upperBound..<end]) { t = Date(timeIntervalSince1970: secs) }
        let auid = field("auid") ?? ""
        let actor = Actors.auid[auid] ?? (auid == "4294967295" ? "os" : "uid \(auid)")
        let key = field("key") ?? ""
        let what = field("exe") ?? field("comm") ?? field("name") ?? ""
        return [Event(time: t, actor: actor, host: "alexus", source: "auditd", kind: "audit",
                      title: "\(key): \(what)", body: line, session: "auid \(auid)")]
    }
}

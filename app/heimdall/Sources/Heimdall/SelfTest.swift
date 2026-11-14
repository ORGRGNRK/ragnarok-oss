import SQLite3
import UniformTypeIdentifiers
import Foundation
import Darwin
import WebKit

/// `Heimdall --selftest`: run by bin/heimdall-edit on every new build before it is installed.
/// Checks the parsers on fixed sample lines (one per feed) and that the feeds and gate can be set up,
/// without opening a window or touching the network. Exit 0 = good.
enum SelfTest {
    static func run() -> Bool {
        var ok = true
        let destinations = WorkspaceSection.allCases.flatMap { $0.destinations.map(\.id) }
        let legacyRoutes: [String: WorkspaceSection] = ["hub": .projects, "shell": .projects,
            "alexus": .chat, "room": .chat, "agents": .tasks, "belt": .tasks,
            "timeline": .activity, "money": .money, "home": .home, "intake": .intake, "browser": .browser]
        let navigationOK = WorkspaceSection.allCases.count == 9
            && destinations.count == Set(destinations).count
            && legacyRoutes.allSatisfy { WorkspaceSection.containing($0.key) == $0.value }
            && WorkspaceSection.containing("unknown-old-route") == .projects
        print("\(navigationOK ? "ok  " : "FAIL") workspace-navigation-legacy-routes")
        if !navigationOK { ok = false }
        let intakeKindOK = Intake.kind(filename: "shot.png", mime: "image/png") == "photo"
            && Intake.kind(filename: "notes.txt", mime: "text/plain") == "file"
            && Intake.kind(filename: "pic.HEIC", mime: "") == "photo"
        let intakeNameOK = Intake.safeName("../etc/passwd") == nil
            && Intake.safeName("..") == nil
            && Intake.safeName("notes.txt") == "notes.txt"
        let intakeDiskOK = Intake.diskLine(free: Int64(11) << 30, used: Int64(20) << 30).contains("GB")
        let intakeNavOK = destinations.contains("intake") && WorkspaceSection.containing("intake") == .intake
        let intakeOK = intakeKindOK && intakeNameOK && intakeDiskOK && intakeNavOK
            && Intake.unreachableMessage.contains("Alexus")
            && Intake.tabMarker == "heimdall-intake-tab"
        print("\(intakeOK ? "ok  " : "FAIL") intake-tab")
        if !intakeOK { ok = false }
        let narrowName = "Screenshot 4.18.00\u{202F}PM.png"
        let intakeFileOK = Intake.utf8Header("写真.png") == "UTF-8''%E5%86%99%E7%9C%9F.png"
            && Intake.plainHeader("写真.png") == nil
            && Intake.utf8Header(narrowName) == "UTF-8''Screenshot%204.18.00%E2%80%AFPM.png"
            && Intake.plainHeader(narrowName) == nil
            && Intake.plainHeader("café.png") == "café.png"
            && Intake.utf8Header("café.png") == "UTF-8''caf%C3%A9.png"
            && Intake.plainHeader("notes.txt") == "notes.txt"
            && Intake.wireHeaders(["X-Intake-Filename": "写真.png"])["X-Intake-Filename"] == nil
            && Intake.wireHeaders(["X-Intake-Filename": "写真.png"])["X-Intake-Filename-Utf8"] == "UTF-8''%E5%86%99%E7%9C%9F.png"
            && Intake.quarantineValue(at: Date(timeIntervalSince1970: 0)) == "0083;00000000;Heimdall;Intake"
        print("\(intakeFileOK ? "ok  " : "FAIL") intake-filename")
        if !intakeFileOK { ok = false }
        let intakeQuery = Intake.queryPart("AT&T c++ =x")
        let intakeQueryOK = intakeQuery == "AT%26T%20c%2B%2B%20%3Dx" && !intakeQuery.contains("&") && !intakeQuery.contains("+")
        print("\(intakeQueryOK ? "ok  " : "FAIL") intake-query")
        if !intakeQueryOK { ok = false }
        let intakeOpenOK = Intake.openPlan(filename: "shot.png", mime: "image/png") == "open"
            && Intake.openPlan(filename: "notes.txt", mime: "text/plain") == "open"
            && Intake.openPlan(filename: "data.json", mime: "application/json") == "open"
            && Intake.openPlan(filename: "page.html", mime: "text/html") == "reveal"
            && Intake.openPlan(filename: "run.sh", mime: "text/x-sh") == "reveal"
            && Intake.openPlan(filename: "Tool.app", mime: "") == "reveal"
            && Intake.openPlan(filename: "payload", mime: "application/octet-stream") == "reveal"
        print("\(intakeOpenOK ? "ok  " : "FAIL") intake-open")
        if !intakeOpenOK { ok = false }
        func check(_ name: String, _ events: [Event], actor: String) {
            let pass = events.first?.actor == actor
            print("\(pass ? "ok  " : "FAIL") \(name): \(events.first.map { "[\($0.actor)] \($0.title)" } ?? "no event")")
            if !pass { ok = false }
        }
        check("claude", Parsers.claude("/x/abc.jsonl",
            #"{"type":"assistant","timestamp":"2026-10-31T16:00:00.000Z","message":{"content":[{"type":"text","text":"hi"}]}}"#), actor: "claude")
        check("argon", Parsers.argon("/brain/abc/x",
            #"{"type":"PLANNER_RESPONSE","created_at":"2026-10-31T16:00:00Z","content":"hi"}"#), actor: "argon")
        check("grok", Parsers.grok("/x/abc.jsonl", #"{"type":"assistant","content":"hi"}"#), actor: "grok")
        check("mac-receipts", Parsers.macReceipts("",
            #"{"at":"2026-10-31T16:00:00.000Z","actor":"human-terminal","command":"ls","exit_code":"0"}"#), actor: "owner")
        for (name, json, expected) in [
            ("receipt-read", #"{"actor":"Codex","kind":"Read","command":"cat source.swift"}"#, "read"),
            ("receipt-change", #"{"actor":"Codex","kind":"Change","command":"touch source.swift"}"#, "change"),
            ("receipt-legacy", #"{"actor":"Codex","command":"pwd"}"#, "command"),
            ("receipt-unknown-kind", #"{"actor":"Codex","kind":"unexpected","command":"pwd"}"#, "command")
        ] {
            let events = Parsers.macReceipts("", json)
            let pass = events.first?.actor == "codex" && events.first?.kind == expected
            print("\(pass ? "ok  " : "FAIL") \(name)")
            if !pass { ok = false }
        }
        let codexMCP=Parsers.codexTools("", #"{"type":"event_msg","timestamp":"2026-11-04T23:00:00Z","payload":{"type":"item_completed","thread_id":"fixture-session","item":{"type":"McpToolCall","server":"cua_repl","tool":"js","status":"completed","arguments":{"private":"DO_NOT_SHOW"},"result":"DO_NOT_SHOW"}}}"#)
        let codexWeb=Parsers.codexTools("", #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Extension","kind":"web.search","query":"DO_NOT_SHOW"}}}"#)
        let codexIgnored=Parsers.codexTools("", #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","raw_content":"DO_NOT_SHOW"}}}"#)
        let codexToolsOK=codexMCP.first?.actor == "codex" && codexMCP.first?.kind == "tool"
            && codexMCP.first?.title.contains("cua_repl.js") == true && codexMCP.first?.body.contains("DO_NOT_SHOW") == false
            && codexWeb.first?.title.contains("web.search") == true && codexIgnored.isEmpty
        print("\(codexToolsOK ? "ok  " : "FAIL") codex-tools-metadata-only")
        if !codexToolsOK {ok=false}
        check("owner-shell", Parsers.ownerShell("", #"{"ts":"2026-10-31T16:00:00Z","cmd":"ls","exit":0}"#), actor: "owner")
        check("alexus-receipts", Parsers.alexusReceipts("",
            #"{"ts":"2026-10-31T16:00:00Z","actor":"grok@alexus","cmd":"ls","status":"ok"}"#), actor: "grok")
        check("audit", Parsers.audit("",
            #"type=SYSCALL msg=audit(1793462400.123:42): auid=1002 comm="ls" exe="/usr/bin/ls" key="ai_exec""#), actor: "argon")
        check("edits", Parsers.edits("",
            #"{"ts":"2026-10-31T16:00:00Z","edit":"1","who":"manual","step":"installed","ok":true,"detail":"abc"}"#), actor: "owner")
        let appError = Parsers.appErrors("", #"{"ts":"2026-10-31T16:00:00Z","level":"error","area":"chat","message":"failed: sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"}"#)
        check("app-errors", appError, actor: "Unverified")
        let attributedError = Parsers.appErrors("", #"{"area":"agent","message":"failed","actor":"codex","os_user":"sam","run_id":"run-123","origin":"agent-runner"}"#)
        check("app-errors-actor", attributedError, actor: "codex")
        let labels = AppLog.attribution(environment: ["RAGNAROK_ACTOR": "claude", "RAGNAROK_AGENT_RUN": "old-run"])
        let attributionOK = labels["actor"] == "claude" && labels["run_id"] == "old-run"
            && labels["os_user"] == NSUserName() && labels["incident_id"] == "Unverified"
            && AppLog.attribution(environment: [:])["actor"] == "Unverified"
            && AppLog.attribution(environment: ["RAGNAROK_ACTOR": "unknown"])["actor"] == "Unverified"
            && attributedError.first?.session == "run-123"
            && attributedError.first?.body.contains("os_user: sam") == true
        print("\(attributionOK ? "ok  " : "FAIL") app-error-attribution")
        if !attributionOK { ok = false }
        let appErrorSafe = appError.first?.body.contains("[hidden:anthropic-key]") == true
        print("\(appErrorSafe ? "ok  " : "FAIL") app-errors-scrub")
        if !appErrorSafe { ok = false }
        check("chat", Parsers.chat("", #"{"ts":"2026-10-31T16:00:00Z","session":"s","role":"assistant","content":"Hmph."}"#), actor: "alexus")
        check("chat-user", Parsers.chat("", #"{"ts":"2026-10-31T16:00:00Z","session":"s","role":"user","content":"hi"}"#), actor: "owner")
        check("heimdall-shell", Parsers.ownerShell("", #"{"ts":"2026-10-31T16:00:00Z","cmd":"ls -la","cwd":"/Users/x","exit":0,"src":"heimdall-shell"}"#), actor: "owner")
        let cleaned = ShellSession.clean("\u{1B}[1;32mgreen\u{1B}[0m\r\nnext\u{1B}]0;title\u{07}")
        print("\(cleaned == "green\nnext" ? "ok  " : "FAIL") shell-clean: \(cleaned.debugDescription)")
        if cleaned != "green\nnext" { ok = false }
        // gh-style menus send ESC 7 / ESC 8 (save/restore cursor) and charset selects; none may leak into the text copy
        let menu = ShellSession.clean("\u{1B}7\u{1B}8? Pick\u{1B}(B one\r")
        print("\(menu == "? Pick one" ? "ok  " : "FAIL") shell-clean-esc78: \(menu.debugDescription)")
        if menu != "? Pick one" { ok = false }
        let bar = ShellSession.clean("Scanning [==  ]\rScanning [====]\r\n", keepCR: true)
        print("\(bar == "Scanning [==  ]\rScanning [====]\n" ? "ok  " : "FAIL") shell-clean-keepcr: \(bar.debugDescription)")
        if bar != "Scanning [==  ]\rScanning [====]\n" { ok = false }
        // LoginPath: his shell's PATH goes first, duplicates and blanks dropped; and with it set, claude is found
        let merged = LoginPath.merge("/a:/b::/a", "/usr/bin:/b:/c")
        let debugBin = LoginPath.which("heimdall-debug") != nil
        let pathOK = merged == "/a:/b:/usr/bin:/c" && LoginPath.which("claude") != nil && debugBin
        print("\(pathOK ? "ok  " : "FAIL") login-path: merge \(merged), claude \(LoginPath.which("claude") ?? "NOT FOUND"), heimdall-debug \(LoginPath.which("heimdall-debug") ?? "NOT FOUND") (PATH from \(LoginPath.source))")
        if !pathOK { ok = false }
        // Agents tab: a state.json written by bin/ragnarok-agent decodes, and "where it is" comes from the plan
        let webRun = try? JSONDecoder().decode(AgentRun.self, from: Data(#"{"id":"web","status":"done","final":"Ready: [app](http://localhost:4321/demo)."}"#.utf8))
        let plainRun = try? JSONDecoder().decode(AgentRun.self, from: Data(#"{"id":"plain","final":"Done without a web app"}"#.utf8))
        let linkOK = webRun?.webURL?.absoluteString == "http://localhost:4321/demo" && plainRun?.webURL == nil
        print("\(linkOK ? "ok  " : "FAIL") agent-browser-link")
        if !linkOK { ok = false }
        let gateRun = try? JSONDecoder().decode(AgentRun.self, from: Data(#"{"id":"gate","status":"done","final":"LEFT: Physical touch on YubiKey or Apple Touch ID sensor using ./unlock.sh"}"#.utf8))
        let gateStatus = try? JSONDecoder().decode(PlatformGateStatus.self, from: Data(#"{"platform":"secure-mcp-platform","locked":true,"remainingMinutes":0}"#.utf8))
        let unrelatedRun = try? JSONDecoder().decode(AgentRun.self, from: Data(#"{"id":"unrelated","status":"done","cwd":"/Users/sam/Developer/ragnarok","final":"Done without a web app"}"#.utf8))
        let gateOK = gateRun?.hasHardwareGate == true && plainRun?.hasHardwareGate == false && gateStatus?.locked == true && unrelatedRun?.hasHardwareGate == false
        print("\(gateOK ? "ok  " : "FAIL") agent-hardware-gate")
        if !gateOK { ok = false }
        let forceRun = try? JSONDecoder().decode(AgentRun.self, from: Data(#"{"id":"f","status":"stopped","now":"force stopped by the owner","pid":null}"#.utf8))
        let forceOK = forceRun?.status == "stopped" && forceRun?.isLive == false && forceRun?.now == "force stopped by the owner"
        print("\(forceOK ? "ok  " : "FAIL") agent-force-stop")
        if !forceOK { ok = false }
        let agentJSON = #"{"id":"x","status":"running","started":"2026-11-02T16:00:00-0800","room_task_id":"ab12cd34","plan":[{"step":"a","status":"completed"},{"step":"b","doing":"doing b","status":"in_progress"},{"step":"c","status":"pending"}],"actions":[{"kind":"tool","tool":"Bash","what":"running ls","result":"ok"}],"tools":1}"#
        let agent = try? JSONDecoder().decode(AgentRun.self, from: Data(agentJSON.utf8))
        let agentOK = agent?.planDone == 1 && agent?.currentStep?.doing == "doing b" && agent?.isLive == true
            && agent?.room_task_id == "ab12cd34"
            && agent?.elapsed(at: AgentRun.stamp.date(from: "2026-11-02T16:01:05-0800")!) == "1m 5s"
        print("\(agentOK ? "ok  " : "FAIL") agent-state: \(agent.map { "\($0.planDone)/\($0.plan?.count ?? 0) \($0.currentStep?.doing ?? "-")" } ?? "nil")")
        if !agentOK { ok = false }
        let agentWho = try? JSONDecoder().decode(AgentRun.self, from: Data(#"{"id":"g","who":"grok","provider":"xai","status":"done"}"#.utf8))
        let whoOK = agentWho?.agent == "grok" && agentWho?.provider == "xai" && agent?.agent == "claude"
        print("\(whoOK ? "ok  " : "FAIL") agent-who: \(agentWho?.agent ?? "nil") / \(agent?.agent ?? "nil")")
        if !whoOK { ok = false }
        let proved = try? JSONDecoder().decode(AgentRun.self, from: Data(#"{"id":"p","status":"done","verdict":"needs you","checks":[{"claim":"a","cmd":"true","ok":true},{"claim":"b","cmd":"HUMAN","ok":null,"human":true}],"critic":{"verdict":"pass","refuted":[]}}"#.utf8))
        let provedOK = proved?.checks?.count == 2 && proved?.checks?[1].ok == nil && proved?.critic?.verdict == "pass" && proved?.verdict == "needs you"
        print("\(provedOK ? "ok  " : "FAIL") agent-proved: \(proved?.verdict ?? "nil") \(proved?.checks?.count ?? 0) checks")
        if !provedOK { ok = false }
        let plan = try? JSONDecoder().decode(AgentPlan.self, from: Data(#"{"ok":true,"session":"s","understood":"u","checklist":"- [ ] a :: verify: true","steps":[{"claim":"a","cmd":"true","ok":true,"human":false}],"cost_usd":0.1}"#.utf8))
        let planOK = plan?.ok == true && plan?.steps?.first?.ok == true && plan?.session == "s"
        print("\(planOK ? "ok  " : "FAIL") agent-plan: \(plan?.understood ?? "nil") \(plan?.steps?.count ?? 0) steps")
        if !planOK { ok = false }
        let rm = RoomModel.parse(#"{"ts":"2026-10-31T16:00:00Z","id":"ab12cd34","type":"task","text":"t","by":"argon"}"#)
        print("\(rm?.by == "argon" && rm?.type == "task" ? "ok  " : "FAIL") room-parse: \(rm.map { "[\($0.by)] \($0.type)" } ?? "nil")")
        if rm?.by != "argon" { ok = false }
        let roomLine = #"{"ts":"2026-10-31T16:00:00Z","id":"selftest1","type":"say","text":"hi","by":"grok"}"#
        check("room-timeline", Parsers.room("", roomLine), actor: "grok")
        let again = Parsers.room("", roomLine).count
        print("\(again == 0 ? "ok  " : "FAIL") room-dedupe: replayed message gave \(again) event(s)")
        if again != 0 { ok = false }
        check("room-unverified", Parsers.room("",
            #"{"ts":"2026-10-31T16:00:00Z","id":"selftest2","type":"say","text":"hi","by":"claude?","unverified":true}"#), actor: "unknown")
        let tmp = NSTemporaryDirectory() + "heimdall-selftest-\(getpid())"
        try? FileManager.default.createDirectory(atPath: tmp + "/zdir", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp + "/a.txt", contents: Data("x".utf8))
        FileManager.default.createFile(atPath: tmp + "/.hidden", contents: Data())
        let listed = WorkspaceModel.list(tmp).map(\.name)
        let wsOK = listed == ["zdir", "a.txt"]
        print("\(wsOK ? "ok  " : "FAIL") workspace-list: \(listed)")
        if !wsOK { ok = false }
        let found = WorkspaceModel.paths(in: "see `\(tmp)/a.txt:12` and /nope/x")
        let pathsOK = found == [tmp + "/a.txt"]
        print("\(pathsOK ? "ok  " : "FAIL") workspace-paths: \(found.count) found")
        if !pathsOK { ok = false }
        try? FileManager.default.removeItem(atPath: tmp)
        let lineN = LineNumberRuler.lineNumber("a\nb\nc" as NSString, upTo: 4)
        print("\(lineN == 3 ? "ok  " : "FAIL") editor-line-number: \(lineN)")
        if lineN != 3 { ok = false }
        let lt = RoomView.localTime("2026-11-01T17:10:00Z"), lt2 = RoomView.localTime("2026-11-01T17:10:00.123Z")
        let ltOK = lt.count == 5 && lt == lt2 && lt.hasSuffix(":10")
        print("\(ltOK ? "ok  " : "FAIL") room-local-time: \(lt) / \(lt2)")
        if !ltOK { ok = false }
        let tmpBridge = NSTemporaryDirectory() + "room-bridge-test-\(getpid()).on"
        try? FileManager.default.removeItem(atPath: tmpBridge)
        let bridgeInit = !RoomModel.isConveyorBridgeEnabled(path: tmpBridge)
        RoomModel.setConveyorBridge(enabled: true, path: tmpBridge)
        let bridgeOn = RoomModel.isConveyorBridgeEnabled(path: tmpBridge)
        RoomModel.setConveyorBridge(enabled: false, path: tmpBridge)
        let bridgeOff = !RoomModel.isConveyorBridgeEnabled(path: tmpBridge)
        let bridgeOK = bridgeInit && bridgeOn && bridgeOff
        print("\(bridgeOK ? "ok  " : "FAIL") room-conveyor-bridge: init=\(bridgeInit) on=\(bridgeOn) off=\(bridgeOff)")
        if !bridgeOK { ok = false }
        let pr = AITerminal.prompt("next?", history: [AITerminal.Turn(who: "owner", isUser: true, text: "hi"),
                                                       AITerminal.Turn(who: "grok", isUser: false, text: "hello")], cwd: "/tmp")
        let prOK = pr.contains("[grok] hello") && pr.hasSuffix("next?") && pr.contains("/tmp")
        print("\(prOK ? "ok  " : "FAIL") terminal-prompt")
        if !prOK { ok = false }
        let pf = AITerminal.prompt("what is this", history: [], cwd: "/tmp", file: ("/tmp/x.py", "print(1)", false))
        let pfOK = pf.contains("/tmp/x.py") && pf.contains("print(1)")
        print("\(pfOK ? "ok  " : "FAIL") terminal-open-file")
        if !pfOK { ok = false }
        let lg = AITerminal.needsLogin("opening authentication page in your browser. do you want to continue? [y/n]:")
            && !AITerminal.needsLogin("ok gemini")
        print("\(lg ? "ok  " : "FAIL") terminal-login-detect")
        if !lg { ok = false }
        let to = AITerminal.prompt("install codex", history: [], cwd: "/tmp", textOnly: true)
        let toOK = to.contains("you are text only") && !AITerminal.prompt("x", history: [], cwd: "/tmp").contains("you are text only")
        print("\(toOK ? "ok  " : "FAIL") terminal-text-only")
        if !toOK { ok = false }
        let ddg = WebTools.parseDDG(#"<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fgithub.com%2Fopenai%2Fcodex&amp;rut=x">GitHub - <b>openai</b>/codex</a> <a class="result__snippet" href="x">Codex <b>CLI</b> runs locally</a>"#)
        let ddgOK = ddg.first?.url == "https://github.com/openai/codex" && ddg.first?.title == "GitHub - openai/codex" && ddg.first?.snippet == "Codex CLI runs locally"
        print("\(ddgOK ? "ok  " : "FAIL") web-search-parse: \(ddg.first.map { "\($0.title) | \($0.url)" } ?? "none")")
        if !ddgOK { ok = false }
        let tc1 = WebTools.toolCalls(["tool_calls": [["function": ["name": "web_search", "arguments": ["query": "q1"]]]]])
        let tc2 = WebTools.toolCalls(["content": #"{"name": "fetch_page", "arguments": {"url": "https://a.b"}}"#])
        let tc3 = WebTools.toolCalls(["content": "plain answer"])
        let tcOK = tc1.first?.arg == "q1" && tc2.first?.name == "fetch_page" && tc2.first?.arg == "https://a.b" && tc3.isEmpty
        print("\(tcOK ? "ok  " : "FAIL") web-tool-calls")
        if !tcOK { ok = false }
        let riskOK = Explainer.risk(in: "RISK: low (it is not high)") == "low" && Explainer.risk(in: "RISK: medium") == "medium"
        let t0 = Date(); let (hubRC, _) = HubModel.run("/bin/sh", ["-c", "sleep 30 & sleep 30"], timeout: 1)
        let hubTimeoutOK = hubRC == 124 && Date().timeIntervalSince(t0) < 6
        let (h1, held) = ShellSession.holdIncompleteEscape("red \u{1B}[3")
        let escOK = h1 == "red " && held == "\u{1B}[3" && ShellSession.holdIncompleteEscape("x\u{1B}[31m").1.isEmpty
        let k25 = riskOK && hubTimeoutOK && escOK
        print("\(k25 ? "ok  " : "FAIL") breaktest-k2-k5: risk \(riskOK) hubTimeout \(hubTimeoutOK) esc \(escOK)")
        if !k25 { ok = false }
        // report items 3, 10, 20, 21
        let tdir = NSTemporaryDirectory() + "heimdall-selftest-\(getpid())"
        try? FileManager.default.createDirectory(atPath: tdir, withIntermediateDirectories: true)
        let real = tdir + "/run.sh", link = tdir + "/link.sh"
        FileManager.default.createFile(atPath: real, contents: Data("old".utf8), attributes: [.posixPermissions: 0o755])
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        try? WorkspaceModel.writeKeepingFile("new", to: link)
        let perm = (try? FileManager.default.attributesOfItem(atPath: real)[.posixPermissions] as? NSNumber)?.intValue
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == real
        let saveOK = isLink && perm == 0o755 && (try? String(contentsOfFile: real, encoding: .utf8)) == "new"
        let sensOK = Explainer.isSensitive("/x/.env.local") && Explainer.isSensitive("/x/server.pem") && Explainer.isSensitive("/x/id_ed25519")
            && !Explainer.isSensitive("/x/main.swift") && !Explainer.isSensitive("/x/README.md")
        appendLine(tdir + "/a.log", Data("1\n".utf8)); appendLine(tdir + "/a.log", Data("2\n".utf8))
        let appendOK = (try? String(contentsOfFile: tdir + "/a.log", encoding: .utf8)) == "1\n2\n"
        try? FileManager.default.removeItem(atPath: tdir)
        let fileOK = saveOK && sensOK && appendOK
        print("\(fileOK ? "ok  " : "FAIL") breaktest-files: save-keeps-link+perms \(saveOK) sensitive \(sensOK) append \(appendOK)")
        if !fileOK { ok = false }
        let pubOK = WebTools.isPublic(URL(string: "https://github.com/x")!) && !WebTools.isPublic(URL(string: "http://192.168.1.10:11434")!)
            && !WebTools.isPublic(URL(string: "http://localhost/x")!) && !WebTools.isPublic(URL(string: "file:///etc/passwd")!)
            && !WebTools.isPublic(URL(string: "http://alexus-1/x")!) && !WebTools.isPublic(URL(string: "http://100.64.0.7/")!)
            // break-test K1 spellings
            && ["http://127.1/", "http://0x7f.0.0.1/", "http://0177.0.0.1/", "http://2130706433/", "http://localhost./",
                "http://router.lan/", "http://printer.home.arpa/", "http://224.0.0.1/", "http://[::1]/", "http://[::ffff:127.0.0.1]/",
                "http://[fe80::1]/", "http://x.internal/", "http://user@example.com/"].allSatisfy { !WebTools.isPublic(URL(string: $0)!) }
            && WebTools.publicPin(URL(string: "http://127.0.0.1:11434/")!) == nil
            && WebTools.publicPin(URL(string: "https://1.1.1.1/")!) == "1.1.1.1:443:1.1.1.1"
        print("\(pubOK ? "ok  " : "FAIL") web-fetch-public-only")
        // report item 30: Alexus identity/addresses come from ~/.ragnarok/local.conf; absent/bad values keep defaults
        let lcDef = LocalConfig.resolve("")
        let lcSet = LocalConfig.resolve("# test\nALEXUS_HOST = 10.9.8.7\nALEXUS_USER=\"tester\"\n\nOLLAMA_URL=http://box.test:1/\n")
        let lcBad = LocalConfig.resolve("ALEXUS_HOST=-oProxyCommand=x\nALEXUS_USER=Root;rm\nOLLAMA_URL=file:///etc\nALEXUS_TAILSCALE=a b")
        let lcOK = lcDef.ssh == LocalConfig.loginUser + "@alexus.local" && lcDef.ollama == "http://alexus.local:11434" && lcDef.alexusTailscale == "alexus"
            && lcSet.ssh == "tester@10.9.8.7" && lcSet.ollama == "http://box.test:1" && lcSet.alexusHome == "/home/tester"
            && LocalConfig.resolve("ALEXUS_HOST=10.0.0.2").ollama == "http://10.0.0.2:11434"
            && lcBad == lcDef
        print("\(lcOK ? "ok  " : "FAIL") local-config: defaults, overrides, rejects odd values")
        if !lcOK { ok = false }
        if !pubOK { ok = false }
        let ht = WebTools.text("<html><head><title>t</title></head><body><style>\n.a{b:c}\n</style><script>\nx()\n</script><!-- c\n --><p>Run <code>npm i</code> &amp; go</p></body></html>")
        print("\(ht == "Run npm i & go" ? "ok  " : "FAIL") web-html-text: \(ht.debugDescription)")
        if ht != "Run npm i & go" { ok = false }
        let tu = WebTools.topURLs("1. A\n   https://a.com/x\n   snip\n2. B\n   https://b.org\n   s\n3. C\n   https://c.net\n", count: 2)
        print("\(tu == ["https://a.com/x", "https://b.org"] ? "ok  " : "FAIL") web-top-urls: \(tu)")
        if tu != ["https://a.com/x", "https://b.org"] { ok = false }
        let pageT = (1...200).map { "Menu item \($0)" }.joined(separator: "\n") + "\nInstall the Codex CLI with the standalone installer for macOS and Linux.\ncurl -fsSL https://example.com/install.sh | sh\n" + (1...50).map { "Footer \($0)" }.joined(separator: "\n")
        let rel = WebTools.relevant(pageT, question: "how do i install codex", budget: 300)
        let relOK = rel.contains("standalone installer for macOS") && rel.contains("install.sh | sh") && rel.count <= 320
        print("\(relOK ? "ok  " : "FAIL") web-relevant-passages: \(rel.count) chars")
        if !relOK { ok = false }
        let bing = WebTools.parseBing(#"<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?!&amp;&amp;p=x&amp;u=a1aHR0cHM6Ly9sZWFybi5jaGF0Z3B0LmNvbS9kb2NzL2NvZGV4L2NsaQ&amp;ntb=1">Codex <b>CLI</b></a></h2><p>Use Codex from your terminal</p></li>"#)
        let bingOK = bing.first?.url == "https://learn.chatgpt.com/docs/codex/cli" && bing.first?.title == "Codex CLI" && bing.first?.snippet == "Use Codex from your terminal"
        print("\(bingOK ? "ok  " : "FAIL") web-bing-parse: \(bing.first.map { $0.url } ?? "none")")
        if !bingOK { ok = false }
        let ol = AITerminal.ollamaText(#"{"message":{"role":"assistant","content":"Hmph."},"done":true}"#)
        print("\(ol == "Hmph." ? "ok  " : "FAIL") terminal-ollama: \(ol)")
        if ol != "Hmph." { ok = false }
        let rj = #"{"ok":true,"query":"q","rows":3,"seconds":0.1,"hits":[{"score":0.71,"path":"/Users/x/Developer/notes/a.md","name":"a.md","text":"alpha"},{"score":0.6,"path":"/Users/x/logs/run.log","text":"noise"},{"score":0.5,"path":"/Users/x/d/dump.jsonl","text":"noise"}]}"#
        let rh = Recall.parse(Data(rj.utf8))
        let rb = Recall.block(rh) ?? ""
        let recOK = rh.count == 1 && rb.hasPrefix("## FROM THEIR OWN NOTES AND FILES") && rb.contains("[0.71] /Users/x/Developer/notes/a.md\nalpha")
            && Recall.block([]) == nil && Recall.parse(Data(#"{"ok":false}"#.utf8)).isEmpty
        print("\(recOK ? "ok  " : "FAIL") recall-converse-format: \(rh.count) kept")
        if !recOK { ok = false }
        let pn = AITerminal.prompt("hi", history: [], cwd: "/", notes: "## FROM THEIR OWN NOTES AND FILES x")
        let pnOK = pn.contains("## FROM THEIR OWN NOTES AND FILES x\n\n\(LocalConfig.owner) now says:\nhi") && !AITerminal.prompt("hi", history: [], cwd: "/").contains("FROM THEIR")
        print("\(pnOK ? "ok  " : "FAIL") recall-in-prompt")
        if !pnOK { ok = false }
        let rmsgs = [RoomModel.Msg(id: "a1", ts: "", by: "grok", type: "task", text: "fix the link", ref: nil, unverified: false),
                     RoomModel.Msg(id: "a2", ts: "", by: "claude", type: "say", text: "on it", ref: nil, unverified: false)]
        let rc = AITerminal.roomContext(rmsgs, tasks: [(id: "a1", text: "fix the link", by: "grok", state: "open", owner: nil)]) ?? ""
        let rp = AITerminal.prompt("what's up", history: [], cwd: "/", room: rc)
        let sh = AITerminal.shareText(AITerminal.Turn(who: "grok", isUser: false, text: "📚 found related notes in your files\nDone."))
        let rcOK = rc.contains("[grok] 📋 Task: fix the link") && rc.contains("[claude] on it") && rc.contains("- fix the link (open)")
            && rp.contains("[claude] on it") && AITerminal.roomContext([], tasks: []) == nil
            && sh == "(grok's reply in the Heimdall terminal, shared by \(LocalConfig.owner))\nDone."
        print("\(rcOK ? "ok  " : "FAIL") room-terminal-link")
        if !rcOK { ok = false }
        let explainDir = NSTemporaryDirectory() + "heimdall-explain-notes-\(getpid())"
        try? FileManager.default.createDirectory(atPath: explainDir, withIntermediateDirectories: true)
        let explainHome = Explainer.dir
        Explainer.dir = explainDir
        defer { Explainer.dir = explainHome; try? FileManager.default.removeItem(atPath: explainDir) }
        let tmpF = NSTemporaryDirectory() + "heimdall-explain-test.txt"
        try? "hello".write(toFile: tmpF, atomically: true, encoding: .utf8)
        Explainer.save(tmpF, risk: Explainer.risk(in: "## What it is\nx\nRISK: medium"), markdown: "## What it is\n- SAFE: x", by: "test")
        let n1 = Explainer.load(tmpF)
        try? "hello again".write(toFile: tmpF, atomically: true, encoding: .utf8)
        let n2 = Explainer.load(tmpF)
        try? FileManager.default.removeItem(atPath: Explainer.noteFile(tmpF)); try? FileManager.default.removeItem(atPath: tmpF)
        let exOK = n1?.risk == "medium" && n1?.stale == false && n1?.markdown == "## What it is\n- SAFE: x" && n2?.stale == true
            && Explainer.risk(in: "blah") == "unknown" && ExplainNoteView.tint("- BREAKS: y") == .red && ExplainNoteView.tint("- SAFE: y") == .green
        print("\(exOK ? "ok  " : "FAIL") explain-note-save-stale")
        if !exOK { ok = false }
        // receipts: a file that existed before, one made during the "answer", one that was never made, one deleted
        let rd = NSTemporaryDirectory() + "heimdall-receipt-test-\(getpid())"
        try? FileManager.default.createDirectory(atPath: rd, withIntermediateDirectories: true)
        try? "old".write(toFile: rd + "/old.txt", atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: rd + "/old.txt")
        let rStart = Date()
        try? "new".write(toFile: rd + "/new.txt", atomically: true, encoding: .utf8)
        let reply = "Created `new.txt` in the folder.\nUpdated `old.txt` too.\nWrote \(rd)/ghost.md\nDeleted `gone.txt`.\nI didn't create `nope.txt`."
        let cl = Receipts.claims(in: reply, cwd: rd, since: rStart)
        let ch = Receipts.changed(since: rStart, under: rd)
        let okOf = { (name: String) in cl.first { $0.path.hasSuffix("/" + name) }?.ok }
        let rv = Receipts.verdict(exit: 0, claims: cl)
        let sum = Receipts.summary(changed: ch, claims: cl, verdict: rv, cwd: rd)
        try? FileManager.default.removeItem(atPath: rd)
        let rcptOK = okOf("new.txt") == true && okOf("old.txt") == false && okOf("ghost.md") == false && okOf("gone.txt") == true
            && okOf("nope.txt") == nil && ch.map { ($0 as NSString).lastPathComponent } == ["new.txt"] && rv == "mismatch"
            && Receipts.verdict(exit: 1, claims: []) == "failed" && sum.contains("1 file changed (new.txt)") && sum.contains("2 ✗")
        print("\(rcptOK ? "ok  " : "FAIL") terminal-receipts: \(cl.map { "\(($0.path as NSString).lastPathComponent)=\($0.ok)" }) changed=\(ch.count)" + (rcptOK ? "" : " summary=\(sum)"))
        if !rcptOK { ok = false }
        let pfp = AITerminal.prompt("x", history: [], cwd: "/", failures: "## PAST FAILURES ON THIS MAC y")
        let pfpOK = pfp.contains("## PAST FAILURES ON THIS MAC y") && pfp.contains("heimdall-recall") && !AITerminal.prompt("x", history: [], cwd: "/", textOnly: true).contains("heimdall-recall")
            && WebTools.toolSpecs.contains { (($0["function"] as? [String: Any])?["name"] as? String) == "search_files" }
        print("\(pfpOK ? "ok  " : "FAIL") failures-and-lookup-in-prompt")
        if !pfpOK { ok = false }
        let ownOK = AITerminal.aboutOwnStuff("search my own files: how does X work") && AITerminal.aboutOwnStuff("how does the heimdall launcher roll back")
            && AITerminal.aboutOwnStuff("what's in this repo") && !AITerminal.aboutOwnStuff("how do i install codex on a mac")
        print("\(ownOK ? "ok  " : "FAIL") own-stuff-skips-web")
        if !ownOK { ok = false }
        let sh2 = SplashView.html
        let splashOK = sh2.contains("id=\"pathText\"") && sh2.contains("messageHandlers.done") && !sh2.contains("http://") && !sh2.contains("https://")
            && sh2.contains("M 300 270 C 340 180, 335 125, 300 125")
        print("\(splashOK ? "ok  " : "FAIL") opening-scene-offline")
        if !splashOK { ok = false }
        let hc = [HubModel.Container(name: "ck-ragnarok-hq-mcp-1", status: "Up 1 hour (healthy)", project: "ck-ragnarok-hq"),
                  HubModel.Container(name: "ragnarok-ollama", status: "Up 1 hour", project: "ragnarok-pipe"),
                  HubModel.Container(name: "ck-receipts-mcp-1", status: "Up 2 hours (unhealthy)", project: "ck-receipts"),
                  HubModel.Container(name: "homeassistant", status: "Up 1 hour", project: "")]
        let hl = HubModel.link([HubModel.Project(path: NSHomeDirectory() + "/Developer/ragnarok"),
                                HubModel.Project(path: NSHomeDirectory() + "/Developer/ragnarok-pipe")], folders: ["ragnarok-hq"], containers: hc)
        let ha = hl.first { $0.path == "alexus:home-assistant" }
        let hubOK = hl.first { $0.name == "ragnarok" }?.containers.isEmpty == true
            && hl.first { $0.name == "ragnarok-pipe" }?.containers.map(\.name) == ["ragnarok-ollama"]
            && hl.first { $0.name == "ragnarok-hq" }?.containers.map(\.name) == ["ck-ragnarok-hq-mcp-1"]
            && hl.first { $0.name == "ck-receipts" }?.containers.first?.healthy == false
            && ha?.label == "Home Assistant" && ha?.containers.map(\.name) == ["homeassistant"]
            && hl.first?.path == "alexus:home-assistant"
            && !hl.contains { $0.path == "alexus:docker/homeassistant" }
            && HubModel.Project(path: NSHomeDirectory() + "/scripts").label == "~/scripts"
        let mcp = HubModel.parseMCP("Checking MCP server health…\n\nragnarok-hq: /bin/bash /x.sh - ✔ Connected\nclaude.ai Stripe: https://mcp.stripe.com - ! Needs authentication\nclaude.ai Yggdrasil: https://m.example/mcp - ✘ Failed to connect — HTTP 502: bad\n")
        let mcpOK = mcp.map(\.state) == ["ok", "auth", "fail"] && mcp[0].name == "ragnarok-hq" && mcp[2].detail == "HTTP 502: bad"
            && HubModel.safeName("ck-receipts-mcp-1") && !HubModel.safeName("x; rm -rf ~") && !HubModel.safeName("-v")
        let hp = HubModel.Project(path: NSHomeDirectory() + "/Developer/ygg-scratch")
        let handOK = HubView.taskText(hp, mode: "belt", ask: " add a README \n") == "belt: In ~/Developer/ygg-scratch: add a README"
            && HubView.taskText(hp, mode: "hand", ask: "x").hasPrefix("no-belt: In ~/Developer/ygg-scratch: ")
            && HubView.taskText(hp, mode: "quick", ask: "why?") == "In ~/Developer/ygg-scratch: why?"
            && HubView.roomName(HubModel.Project(path: "alexus:~/Developer/ragnarok-hq")) == "Alexus ~/Developer/ragnarok-hq"
        let insp = HubModel.parseInspect("/ck-x-mcp-1\t2026-11-01T10:00:00.123456789Z\t2026-11-01T09:59:58.5Z\t3\trunning\t0\tunhealthy\t4\n/old\t2026-10-30T10:00:00Z\t2026-10-30T11:00:00Z\t0\texited\t137\n", now: Date())
        let histOK = insp.count == 4
            && insp[0].title == "ck-x-mcp-1 started (Docker has restarted it 3 times)" && insp[0].detail.contains("4 checks failing")
            && insp.contains { $0.kind == "failure" && $0.title == "ck-x-mcp-1 is unhealthy now" }
            && insp.contains { $0.kind == "failure" && $0.title == "old stopped (exit 137)" }
            && !insp.contains { $0.title == "ck-x-mcp-1 stopped (exit 0)" }
            && HubModel.matches("commit", "code") && !HubModel.matches("commit", "failure")
            && HubModel.commits(FileManager.default.currentDirectoryPath).count > 0
        print("\(histOK ? "ok  " : "FAIL") hub-history: \(insp.map(\.title))")
        if !histOK { ok = false }
        Scrub.values = [("env:TEST_API_KEY", "plainvalue-9f8e7d6c")]; Scrub.loaded = true
        let fakeGH = "ghp_" + String(repeating: "A1b2", count: 6)
        let sample = """
        token=abc123def then \(fakeGH) and AGE-PLUGIN-FIDO2-HMAC-1QQPQZRFR7ZZ2WCVXYZ0123456789 ok
        curl https://sam:hunter2pass@example.com/x · env value plainvalue-9f8e7d6c · Bearer abcdefghijklmnop1234
        random Zq8Lm2Xv9Rt4Yp7Kw3Nb6Hs1Jd5Gf0Qa end
        keep commit 989728b3c1f0e2d4a5b6c7d8e9f0a1b2c3d4e5f6, path ~/Developer/heimdall/Sources/Heimdall/HubHistory.swift, age1fido2-hmac1qqpxwg8r4nn
        """
        let red = Scrub.clean(sample)
        let gone = ["abc123def", fakeGH, "1QQPQZRFR7", "hunter2pass", "plainvalue-9f8e7d6c", "abcdefghijklmnop1234", "Zq8Lm2Xv9Rt4"]
        let kept = ["989728b3c1f0e2d4a5b6c7d8e9f0a1b2c3d4e5f6", "~/Developer/heimdall/Sources/Heimdall/HubHistory.swift", "age1fido2-hmac1qqpxwg8r4nn",
                    "[hidden:env:TEST_API_KEY]", "[hidden:github-token]", "[hidden:url-password]", " end", " ok"]
        let redOK = gone.allSatisfy { !red.contains($0) } && kept.allSatisfy { red.contains($0) }
        print("\(redOK ? "ok  " : "FAIL") scrub: \(red.replacingOccurrences(of: "\n", with: " ⏎ "))")
        if !redOK { ok = false }
        Scrub.values = []; Scrub.loaded = false
        // Money tab: three bank CSV shapes, amounts, dates, categories, repeating charges, duplicate-safe import (temp file)
        let chase = "Details,Posting Date,Description,Amount,Type,Balance\nDEBIT,10/03/2026,\"STARBUCKS STORE 123, SEATTLE\",-5.75,DEBIT_CARD,100\nCREDIT,10/01/2026,PAYROLL ACME,1500.00,ACH,1600\nDEBIT,10/02/2026,NETFLIX.COM,-15.49,DEBIT_CARD,1584.51\n"
        let card = "Transaction Date,Description,Debit,Credit\n2026-09-02,NETFLIX.COM,15.49,\n2026-09-05,PAYMENT THANK YOU,,200.00\n"
        let nohead = "10/04/2026,-42.10,*,,SHELL OIL 1234\n10/05/2026,-12.00,*,,DOORDASH TACO\n"
        let mp1 = Money.parse(chase, flip: false), mp2 = Money.parse(card, flip: false), mp3 = Money.parse(nohead, flip: false)
        let mdb = NSTemporaryDirectory() + "money-selftest-\(UUID().uuidString).sqlite"
        let ms = MoneyStore(path: mdb)
        let ma1 = ms.save(mp1.rows, account: "chk", source: "t"), ma2 = ms.save(mp1.rows, account: "chk", source: "t")
        ms.save(mp2.rows, account: "card", source: "t"); ms.save(mp3.rows, account: "chk", source: "t")
        let mperm = ((try? FileManager.default.attributesOfItem(atPath: mdb))?[.posixPermissions] as? Int) ?? 0
        if let sb = ms.txns.first(where: { $0.desc.hasPrefix("STARBUCKS") }) { ms.setCategory(sb, "Business", remember: true) }
        ms.addDebt(Money.Debt(creditor: "Card Co", collector: "Midland", balance: 120000, firstNotice: "2026-10-20", lastPayment: "2021-03-01", limitYears: 4))
        let mdebt = ms.debts.first
        if let d = mdebt { ms.pay(d, cents: 5000, day: "2026-10-30", account: "chk"); ms.setDebtStatus(d, "asked for proof") }
        let mpaid = mdebt.map { ms.paid($0) } ?? -1, md2 = ms.debts.first
        let msum = Money.summary(ms.txns.filter { $0.debtID == nil }), mreps = Money.repeating(ms.txns)
        let mrows = ms.txns.count, mcat = ms.txns.first(where: { $0.desc.hasPrefix("STARBUCKS") })?.category, mrule = ms.rules.contains { $0.0 == "starbucks store seattle" }
        try? FileManager.default.removeItem(atPath: mdb)
        let moneyOK = mp1.rows.count == 3 && mp1.rows.first?.desc == "STARBUCKS STORE 123, SEATTLE" && mp1.rows.first?.cents == -575 && mp1.rows.first?.day == "2026-10-03"
            && mp2.rows.map(\.cents) == [-1549, 20000] && mp3.rows.map(\.desc) == ["SHELL OIL 1234", "DOORDASH TACO"] && mp3.rows.first?.cents == -4210
            && Money.cents("(1,234.50)") == -123450 && Money.cents("$-5") == -500 && Money.cents("abc") == nil && Money.cents("1.2.3") == nil
            && Money.day("Oct 5, 2026") == "2026-10-05" && Money.day("1/5/26") == "2026-01-05" && Money.day("2026-01-05T10:00:00Z") == "2026-01-05" && Money.day("hello") == nil
            && Money.categorize("NETFLIX.COM", cents: -1549, rules: []) == "Subscriptions" && Money.categorize("AMAZON PRIME*1X", cents: -1499, rules: []) == "Subscriptions"
            && Money.categorize("AMAZON MKTPL", cents: -2000, rules: []) == "Shopping" && Money.categorize("PAYMENT THANK YOU", cents: 20000, rules: []) == "Transfers"
            && Money.categorize("CURRENT INC", cents: -900, rules: []) == "Other" && Money.categorize("RANDOM CO", cents: 5000, rules: []) == "Income"
            && Money.categorize("RANDOM CO", cents: -5000, rules: [("random co", "Food")]) == "Food"
            && ma1.added == 3 && ma2.added == 0 && ma2.dupes == 3 && mrows == 8 && mperm == 0o600 && mcat == "Business" && mrule
            && mpaid == 5000 && md2?.lastPayment == "2026-10-30" && md2?.status == "asked for proof" && md2?.proofAsked != nil
            && Money.proofWindowEnds(md2 ?? Money.Debt()) == "2026-11-19" && Money.limitEnds(Money.Debt(lastPayment: "2021-03-01", limitYears: 4)) == "2025-03-01"
            && Money.limitEnds(Money.Debt(lastPayment: "2021-03-01")) == nil && ms.txns.first(where: { $0.debtID != nil })?.category == "Debt & Fees"
            && msum.income == 150000 && msum.spent == 575 + 1549 + 1549 + 4210 + 1200 && mreps.map(\.merchant) == ["netflix.com"]
        print("\(moneyOK ? "ok  " : "FAIL") money: \(mp1.rows.count)+\(mp2.rows.count)+\(mp3.rows.count) parsed, reimport added \(ma2.added), in \(msum.income) out \(msum.spent), repeats \(mreps.map(\.merchant))")
        if !moneyOK { ok = false }
        let prog = "$ x\n=== round 1/3 · h ===\n▸ stage: packet\n▸ stage: ai\n· reading Hub.swift\n=== round 2/3 · h ===\n▸ stage: build\n[92/94] Heimdall\n"
        let progOK = HubModel.stage(in: prog) == "build" && HubModel.round(in: prog) == "round 2/3" && HubModel.lastActivity(in: prog) == "[92/94] Heimdall"
            && HubModel.stage(in: "no markers") == nil && HubModel.lastActivity(in: "· editing X\n▸ stage: test\n\n[exit 0 · 3 s] ok") == "· editing X"
            && RunProgress.dur(59) == "59s" && RunProgress.dur(125) == "2m 5s"
        print("\(progOK ? "ok  " : "FAIL") hub-progress: stage \(HubModel.stage(in: prog) ?? "nil"), \(HubModel.round(in: prog) ?? "nil")")
        if !progOK { ok = false }
        print("\(handOK ? "ok  " : "FAIL") hub-handoff: \(HubView.taskText(hp, mode: "belt", ask: "add a README"))")
        if !handOK { ok = false }
        print("\(mcpOK ? "ok  " : "FAIL") hub-services: \(mcp.map { "\($0.name)=\($0.state)" })")
        if !mcpOK { ok = false }
        print("\(hubOK ? "ok  " : "FAIL") hub-linking: \(hl.map { "\($0.label)=\($0.containers.count)" })")
        if !hubOK { ok = false }
        // Money: a Cash App-style export (fake people): who/what from "Name of sender/receiver" → Notes → Transaction Type,
        // Net Amount over Amount, FAILED rows left out; "my names" → Transfers (out of in/out); accounts grouped by case;
        // a rebuild from the original file replaces its rows and keeps a hand-picked category.
        let cash = "Date,Transaction ID,Transaction Type,Currency,Amount,Fee,Net Amount,Asset Type,Asset Price,Asset Amount,Status,Notes,Name of sender/receiver,Account\n"
            + "2026-10-01 10:00:00 PDT,#T1,P2P,USD,$50.00,$0.00,$50.00,,,,COMPLETE,rent share,Sam Sample,Cash Balance\n"
            + "2026-10-02 11:00:00 PDT,#T2,P2P,USD,-$40.00,$0.00,-$40.00,,,,COMPLETE,a,Pat Example,Cash Balance\n"
            + "2026-10-03 12:00:00 PDT,,Cash Card,USD,-$12.99,$0.00,-$12.99,,,,COMPLETE,SPOTIFY USA,,Visa Debit 0000\n"
            + "2026-10-04 13:00:00 PDT,,Cash Card,USD,-$9.00,$0.00,-$9.00,,,,FAILED,TACO BELL 0001,,Visa Debit 0000\n"
            + "2026-10-05 14:00:00 PDT,#T3,Withdrawal,USD,-$100.00,-$1.75,-$101.75,,,,COMPLETE,,,Cash Balance\n"
            + "2026-10-06 15:00:00 PDT,,Deposits,USD,$20.00,$0.00,$20.00,,,,COMPLETE,Add Cash,,Cash Balance\n"
        let me = ["Pat Example", "Add Cash"]
        let cp = Money.parse(cash, flip: false)
        let cpOK = cp.rows.count == 5 && cp.failed == 1 && cp.rows.map(\.desc) == ["Sam Sample", "Pat Example", "SPOTIFY USA", "Withdrawal", "Add Cash"]
            && cp.rows.map(\.cents) == [5000, -4000, -1299, -10175, 2000] && cp.note.contains("1 failed")
        let cats = cp.rows.map { Money.categorize($0.desc, cents: $0.cents, rules: [], me: me) }
        let catOK = cats == ["Income", "Transfers", "Subscriptions", "Other", "Transfers"]
            && Money.categorize("Sam Sample", cents: -500, rules: [("sam sample", "Food")], me: ["Sam Sample"]) == "Food"   // your rule wins
            && !Money.isMe("Lee Example-Other", ["Pat Example"]) && !Money.isMe("Sam Sample", ["Pat Example", "AB"]) && Money.isMe("CASH APP*PAT EXAMPLE*CAS", ["pat example"])
            && Money.names(" Pat Example \n\npat example\nAB\nTop-up by\n") == ["Pat Example", "Top-up by"]
        let rev = Money.parse("Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\nCard Payment,Current,2026-10-01 10:00:00,2026-10-01 10:00:00,Corner Shop,-5.00,0.50,USD,COMPLETED,10\nCard Payment,Current,2026-10-02 10:00:00,,Corner Shop,-6.00,0.00,USD,REVERTED,10\n", flip: false)
        let revOK = rev.rows.count == 1 && rev.rows.first?.desc == "Corner Shop" && rev.rows.first?.cents == -550 && rev.failed == 1
        let txs = cp.rows.enumerated().map { Money.Txn(id: $0.offset, day: $0.element.day, cents: $0.element.cents, desc: $0.element.desc, category: cats[$0.offset]) }
        let csum = Money.summary(txs)
        let sumOK = csum.income == 5000 && csum.spent == 1299 + 10175 && csum.transfersOut == 4000 && csum.transfersIn == 2000
        let acctOK = Money.accountLabel(["cash app", "Cash app"]) == "Cash App" && Money.accountLabel(["TD Bank", "td bank"]) == "TD Bank"
            && Money.accountKey(" Cash app ") == Money.accountKey("cash app")
        let rdb = NSTemporaryDirectory() + "heimdall-selftest-rebuild-\(getpid()).sqlite"
        let rs = MoneyStore(path: rdb)
        // what the old parser stored: gross Amount, and "(no description)" when Name of sender/receiver was empty
        rs.save([Money.Row(day: "2026-10-01", cents: 5000, desc: "Sam Sample"), Money.Row(day: "2026-10-02", cents: -4000, desc: "Pat Example"),
                 Money.Row(day: "2026-10-03", cents: -1299, desc: "(no description)"), Money.Row(day: "2026-10-04", cents: -900, desc: "(no description)"),
                 Money.Row(day: "2026-10-05", cents: -10000, desc: "(no description)"), Money.Row(day: "2026-10-06", cents: 2000, desc: "(no description)")],
                account: "cash app", source: "fake.csv")
        if let t = rs.txns.first(where: { $0.cents == 5000 }) { rs.setCategory(t, "Business", remember: false) }
        rs.save([Money.Row(day: "2026-10-07", cents: -4000, desc: "Pat Example")], account: "Cash app", source: "manual-ish.csv")
        let dry = try? rs.rebuild(source: "fake.csv", text: cash, apply: false).get()
        let done = try? rs.rebuild(source: "fake.csv", text: cash, apply: true).get()
        // a second Cash App account with the same name: same shop, day and amount is a second payment; the $0 notice isn't
        let other = "Date,Transaction Type,Amount,Net Amount,Status,Notes,Name of sender/receiver\n2026-10-03,Cash Card,-$12.99,-$12.99,COMPLETE,SPOTIFY USA,\n2026-10-08,Account Notifications,$0,$0,COMPLETE,Notice,\n"
        rs.save([Money.Row(day: "2026-10-03", cents: -1299, desc: "(no description)")], account: "Cash app", source: "other.csv")
        rs.save([Money.Row(day: "2026-10-08", cents: 0, desc: "Notice")], account: "cash app", source: "fake2.csv")
        let two = try? rs.rebuild(source: "other.csv", text: other, apply: true).get()
        let twoOK = two?.after == 1 && two?.dupes == 1 && rs.txns.filter { $0.day == "2026-10-03" && $0.cents == -1299 }.count == 2
        let moved = rs.setMyNames(me)
        let rbParts = [dry?.before == 6, dry?.noDescBefore == 4, done?.noDescAfter == 0, done?.after == 5, done?.failedLeftOut == 1, done?.handKept == 1,
                       rs.txns.first(where: { $0.cents == 5000 })?.category == "Business",
                       rs.txns.filter { $0.source == "fake.csv" }.map(\.desc).contains("Sam Sample"),
                       rs.txns.first(where: { $0.source == "manual-ish.csv" })?.category == "Transfers", moved >= 1,
                       rs.accountLabels.count == 1 && rs.accountLabels.values.first == "Cash App", twoOK]
        let rebuiltOK = !rbParts.contains(false) && done?.after == 5 && done?.failedLeftOut == 1 && done?.handKept == 1
            && rs.txns.first(where: { $0.cents == 5000 })?.category == "Business"
            && rs.txns.filter { $0.source == "fake.csv" }.map(\.desc).contains("Sam Sample")
            && rs.txns.first(where: { $0.source == "manual-ish.csv" })?.category == "Transfers" && moved >= 1
            && rs.accountLabels.count == 1 && rs.accountLabels.values.first == "Cash App"
        try? FileManager.default.removeItem(atPath: rdb)
        let cashOK = cpOK && catOK && revOK && sumOK && acctOK && rebuiltOK
        print("\(cashOK ? "ok  " : "FAIL") money-cash-app: parse \(cpOK), categories \(catOK) \(cats), revolut \(revOK), totals \(sumOK), accounts \(acctOK), rebuild \(rebuiltOK)\(rebuiltOK ? "" : " \(rbParts)")")
        if !cashOK { ok = false }
        // Debts → settlement: savings math, deadline and in-writing warnings, open-offer totals, the schema upgrade keeps old
        // debts, and "Paid settlement" records a linked Debt & Fees payment, marks it settled and keeps the offer
        let sv1 = Money.savings(left: 120000, offer: 48000), sv2 = Money.savings(left: 30000, offer: 45000)
        let mathOK = sv1?.cents == 72000 && sv1?.percent == 60 && sv2?.cents == 0 && sv2?.percent == 0
            && Money.savings(left: 100000, offer: nil) == nil && Money.savings(left: 0, offer: 500) == nil
            && Money.savings(left: 100001, offer: 33333)?.percent == 67 && Money.days(from: "2026-10-30", to: "2026-11-02") == 3
        let today = "2026-11-01"
        let w0 = Money.offerWarnings(Money.Debt(offer: 50000, offerDeadline: "2026-12-31", offerInWriting: true), today: today)
        let w1 = Money.offerWarnings(Money.Debt(offer: 50000), today: today)
        let w2 = Money.offerWarnings(Money.Debt(offer: 50000, offerDeadline: "2026-11-04", offerInWriting: true), today: today)
        let w3 = Money.offerWarnings(Money.Debt(offer: 50000, offerDeadline: "2026-10-31", offerInWriting: true), today: today)
        let w4 = Money.offerWarnings(Money.Debt(offer: 50000, offerDeadline: "2026-11-01", offerInWriting: true), today: today)
        let w5 = Money.offerWarnings(Money.Debt(status: "settled", offer: 50000, offerDeadline: "2026-10-01", offerInWriting: true), today: today)
        let w6 = Money.offerWarnings(Money.Debt(offerDeadline: "2026-10-01"), today: today)
        let warnOK = w0.isEmpty && w1 == [Money.writingWarning] && w2 == ["The offer ends in 3 days (2026-11-04)."]
            && w3.first?.hasPrefix("The offer's deadline (2026-10-31) has passed") == true && w4 == ["The offer ends today (2026-11-01)."]
            && w5.isEmpty && w6.isEmpty
            && Money.writingWarning == "Don't pay a settlement until you have it in writing saying it settles the debt in full."
        let oo = Money.openOffers([Money.Debt(id: 1, balance: 100000, offer: 40000), Money.Debt(id: 2, balance: 50000, offer: 20000, offerDeadline: "2026-10-01"),
                                   Money.Debt(id: 3, balance: 80000, status: "settled", offer: 30000), Money.Debt(id: 4, balance: 60000)],
                                  paid: { $0.id == 1 ? 10000 : 0 }, today: today)
        let openOK = oo.count == 1 && oo.offers == 40000 && oo.saves == 50000
        let sdb = NSTemporaryDirectory() + "heimdall-selftest-settle-\(getpid()).sqlite"
        var raw: OpaquePointer?
        if sqlite3_open(sdb, &raw) == SQLITE_OK {   // a debts table from before settlements existed, with one debt in it
            sqlite3_exec(raw, """
                CREATE TABLE debts (id INTEGER PRIMARY KEY, creditor TEXT NOT NULL, collector TEXT NOT NULL DEFAULT '', acct TEXT NOT NULL DEFAULT '',
                  balance_cents INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'in collections', first_notice TEXT, proof_asked TEXT,
                  last_payment TEXT, limit_years INTEGER, note TEXT NOT NULL DEFAULT '');
                INSERT INTO debts (creditor, collector, balance_cents, first_notice, note) VALUES ('Old Card', 'Acme Recovery', 90000, '2026-09-01', 'kept');
                """, nil, nil, nil)
            sqlite3_close(raw)
        }
        let ss = MoneyStore(path: sdb)
        let old = ss.debts.first
        let migOK = ss.debts.count == 1 && old?.creditor == "Old Card" && old?.balance == 90000 && old?.note == "kept"
            && old?.firstNotice == "2026-09-01" && old?.offer == nil && old?.offerInWriting == false
        if let d = old { ss.setOffer(d, offer: 36000, day: "2026-10-28", deadline: "2026-11-15", from: "collector", inWriting: true, ref: "letter 10/28") }
        let offered = ss.debts.first
        if let d = offered { ss.paySettlement(d, cents: 36000, day: "2026-11-01", account: "chk") }
        let after = ss.debts.first
        let payTx = ss.txns.first { $0.debtID == after?.id }
        let settleOK = offered?.offer == 36000 && offered?.offerFrom == "collector" && offered?.offerRef == "letter 10/28"
            && after?.status == "settled" && after?.offer == 36000 && after?.offerInWriting == true && after?.lastPayment == "2026-11-01"
            && payTx?.cents == -36000 && payTx?.category == "Debt & Fees" && payTx?.desc == "Settlement: Acme Recovery"
            && Money.openOffers(ss.debts, paid: { ss.paid($0) }, today: today).count == 0
        try? FileManager.default.removeItem(atPath: sdb)
        let settlementOK = mathOK && warnOK && openOK && migOK && settleOK
        print("\(settlementOK ? "ok  " : "FAIL") debt-settlement: savings \(mathOK), warnings \(warnOK), open offers \(openOK) \(oo), upgrade keeps old debts \(migOK), paid settlement \(settleOK)")
        if !settlementOK { ok = false }
        // Money → Edit… buttons: a transaction, a debt, an item and a contact can be changed after they're added;
        // links (debt payments), the settlement offer and other rows are left alone; the edit boxes read dates/amounts safely
        let edb = NSTemporaryDirectory() + "heimdall-selftest-edit-\(getpid()).sqlite"
        let es = MoneyStore(path: edb)
        es.addManual(day: "2026-10-01", cents: -1000, desc: "Typo Shop", account: "cash", category: "Food", note: "")
        es.addManual(day: "2026-10-02", cents: -2000, desc: "Other Row", account: "cash", category: "Food", note: "")
        es.addDebt(Money.Debt(creditor: "Wrong Co", collector: "", balance: 50000))
        es.addItem(Money.Item(name: "Lamp", category: "Home", cost: 1500, ask: 3000))
        es.addContact(Money.Contact(name: "Sam Smaple", kind: "person"))
        var et = es.txns.first { $0.desc == "Typo Shop" } ?? Money.Txn()
        et.day = "2026-10-03"; et.cents = 2500; et.desc = "Fixed Shop"; et.account = "Venmo"; et.category = "Income"; et.note = "fixed"
        es.updateTxn(et)
        var ed = es.debts.first ?? Money.Debt()
        es.setOffer(ed, offer: 20000, day: nil, deadline: nil, from: "collector", inWriting: true, ref: "r1")
        es.pay(ed, cents: 1000, day: "2026-10-05", account: "chk")
        ed = es.debts.first ?? Money.Debt()
        ed.creditor = "Right Co"; ed.collector = "Acme"; ed.acct = "1234"; ed.balance = 45000; ed.firstNotice = "2026-09-01"; ed.limitYears = 3; ed.note = "n"
        es.updateDebt(ed)
        var ei = es.items.first ?? Money.Item()
        ei.name = "Desk lamp"; ei.cost = 1200; ei.ask = nil; ei.note = "scratch"; es.updateItem(ei)
        var ec = es.contacts.first ?? Money.Contact()
        ec.name = "Sam Sample"; ec.phone = "555-0100"; ec.lastContact = "2026-10-30"; es.updateContact(ec)
        let t2 = es.txns.first { $0.id == et.id }, eOther = es.txns.first { $0.desc == "Other Row" }, d2 = es.debts.first
        let i2 = es.items.first, c2 = es.contacts.first
        let editOK = t2?.day == "2026-10-03" && t2?.cents == 2500 && t2?.desc == "Fixed Shop" && t2?.account == "Venmo" && t2?.category == "Income" && t2?.note == "fixed"
            && eOther?.cents == -2000 && eOther?.desc == "Other Row" && es.txns.count == 3
            && d2?.creditor == "Right Co" && d2?.collector == "Acme" && d2?.acct == "1234" && d2?.balance == 45000 && d2?.firstNotice == "2026-09-01"
            && d2?.limitYears == 3 && d2?.lastPayment == "2026-10-05" && d2?.offer == 20000 && d2?.offerRef == "r1" && d2.map { es.paid($0) } == 1000
            && i2?.name == "Desk lamp" && i2?.cost == 1200 && i2?.ask == nil && i2?.note == "scratch" && i2?.status == "have"
            && c2?.name == "Sam Sample" && c2?.phone == "555-0100" && c2?.lastContact == "2026-10-30" && es.contacts.count == 1
        let boxOK = Money.optDay("") == .some(nil) && Money.optDay("2026-01-05") == .some("2026-01-05") && Money.optDay("nope") == nil
            && Money.optCents("") == .some(nil) && Money.optCents("$12.50") == .some(1250) && Money.optCents("x") == nil
            && Money.optInt(" 4 ") == .some(4) && Money.optInt("") == .some(nil) && Money.optInt("four") == nil && Money.optInt("-1") == nil
            && Money.plain(-123456) == "1234.56" && Money.plain(nil) == "" && Money.cents(Money.plain(-123456)) == 123456
        try? FileManager.default.removeItem(atPath: edb)
        print("\(editOK && boxOK ? "ok  " : "FAIL") money-edit: rows \(editOK), edit boxes \(boxOK)")
        if !(editOK && boxOK) { ok = false }
        // receipts from the Money pipe: parse its JSON, match one to a bank row (same amount, within 3 days), add the rest once
        let rjson = Data(#"[{"id":7,"uploaded_at":"2026-10-04T10:00:00","filename":"a.jpg","status":"ok","vendor":"Shell","doc_date":"2026-10-03","total":42.10},{"id":8,"uploaded_at":"2026-10-05T10:00:00","filename":"b.jpg","status":"approved","vendor":"Corner Store","doc_date":"2026-10-05","total":"7.25"},{"id":9,"uploaded_at":"2026-10-05T11:00:00","filename":"c.jpg","status":"needs_review","vendor":"","doc_date":null,"total":null}]"#.utf8)
        let recdb = NSTemporaryDirectory() + "heimdall-selftest-receipts-\(getpid()).sqlite"
        let recs_store = MoneyStore(path: recdb)
        recs_store.addManual(day: "2026-10-04", cents: -4210, desc: "SHELL OIL 1234", account: "chk", category: "", note: "")
        recs_store.addManual(day: "2026-09-20", cents: -725, desc: "OLD CORNER", account: "chk", category: "", note: "")
        let recs = ReceiptPipe.parse(rjson) ?? []
        let shell = recs.first { $0.id == 7 }, corner = recs.first { $0.id == 8 }
        let rmatch = shell.flatMap { ReceiptPipe.match($0, in: recs_store.txns) }
        if let s = shell, let t = rmatch { recs_store.linkReceipt(t, s) }
        if let c = corner, ReceiptPipe.match(c, in: recs_store.txns) == nil { recs_store.addFromReceipt(c); recs_store.addFromReceipt(c) }
        let rParsed = recs.count == 3 && recs.filter(\.usable).map(\.id) == [7, 8] && shell?.cents == 4210 && corner?.cents == 725
        let rLinked = rmatch?.desc == "SHELL OIL 1234" && recs_store.txns.count == 3 && recs_store.txns.first { $0.desc == "SHELL OIL 1234" }?.receiptID == 7
        let rAdded: [String] = recs_store.txns.filter { $0.receiptID == 8 }.map { t in "\(t.day) \(t.cents) \(t.source)" }
        let rNoRematch = shell.flatMap { ReceiptPipe.match($0, in: recs_store.txns) } == nil
        let rOK = rParsed && rLinked && rAdded == ["2026-10-05 -725 receipt"] && rNoRematch
        try? FileManager.default.removeItem(atPath: recdb)
        print("\(rOK ? "ok  " : "FAIL") money-receipts: \(recs.count) parsed, matched \(rmatch?.desc ?? "none"), rows \(recs_store.txns.count)")
        if !rOK { ok = false }
        // cloud chat: Anthropic turn order, streamed lines in both formats, request headers, key never echoed (no network)
        let am = CloudChat.anthropicMessages([["role": "system", "content": "S"], ["role": "assistant", "content": "hi"],
                                              ["role": "user", "content": "a"], ["role": "user", "content": "b"], ["role": "assistant", "content": ""]])
        let amOK = am.system == "S" && am.messages.map { $0["role"] ?? "" } == ["user", "assistant", "user"] && am.messages.last?["content"] == "a\n\nb"
        let pOK = CloudChat.parse(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#, anthropic: true) == .text("Hel")
            && CloudChat.parse(line: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#, anthropic: true) == .note("[The model declined this one.]")
            && CloudChat.parse(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, anthropic: true) == .error("Overloaded")
            && CloudChat.parse(line: "event: ping", anthropic: true) == .skip
            && CloudChat.parse(line: #"data: {"choices":[{"delta":{"content":"lo"}}]}"#, anthropic: false) == .text("lo")
            && CloudChat.parse(line: "data: [DONE]", anthropic: false) == .done
        let fake = "sk-test-FAKE-0000000000000000"
        let rq = try? CloudChat.request(CloudChat.provider("anthropic"), model: "claude-opus-5-5", key: fake, history: [["role": "user", "content": "x"]])
        let ccBody = (rq?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let rqURL = rq?.url?.absoluteString == "https://api.anthropic.com/v1/messages"
        let rqHead = rq?.value(forHTTPHeaderField: "x-api-key") == fake && rq?.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21"
        let rqBeta = rq?.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01"
        let rqStream: Bool = (ccBody?["stream"] as? Bool) == true
        let rqFallback: Bool = (ccBody?["fallbacks"] as? String) == "default"
        let rqOK = rqURL && rqHead && rqBeta && rqStream && rqFallback
        let ro = try? CloudChat.request(CloudChat.provider("xai"), model: "m", key: fake, history: [["role": "user", "content": "x"]])
        let roOK = ro?.url?.absoluteString == "https://api.x.ai/v1/chat/completions" && ro?.value(forHTTPHeaderField: "Authorization") == "Bearer " + fake
        let cleanOK = !CloudChat.clean("Incorrect API key provided: \(fake).", key: fake).contains(fake)
        let ccOK = amOK && pOK && rqOK && roOK && cleanOK
        print("\(ccOK ? "ok  " : "FAIL") cloud-chat: order \(amOK), stream lines \(pOK), anthropic request \(rqOK), openai-style request \(roOK), key hidden \(cleanOK)")
        if !ccOK { ok = false }
        // a file <input> in a web panel ("Take photo") opens a picker that takes photos (JPEG, HEIC, PNG) and PDFs, not other files
        let pick = { (ext: String) in UTType(filenameExtension: ext).map { t in WebPanel.pickableTypes.contains { t.conforms(to: $0) } } ?? false }
        let pickOK = pick("jpg") && pick("heic") && pick("png") && pick("pdf") && !pick("zip") && !pick("txt")
        print("\(pickOK ? "ok  " : "FAIL") web-panel-photo-picker")
        if !pickOK { ok = false }
        // Money → Receipts and the Home Assistant tab: address clean-up, status line, Tailscale → home-network fallback
        let wn = WebPanel.normalize
        let webOK = wn(" 100.64.0.7:8448/ ") == "http://100.64.0.7:8448" && wn("http://192.168.1.10:8123//") == "http://192.168.1.10:8123"
            && wn("https://alexus.example.ts.net:8448") == "https://alexus.example.ts.net:8448" && wn("") == nil && wn("file:///etc/passwd") == nil
            && wn("http://-oProxy:1") == nil && wn("http://u:p@host:8123") == nil && wn("ftp://host") == nil && wn("a b") == nil && wn("http://h:99999") == nil
            && WebPanel.describe(200, url: "x").up && WebPanel.describe(401, url: "x").up && !WebPanel.describe(0, url: "x").up && !WebPanel.describe(502, url: "x").up
            && WebPanel.pick(primary: "a", primaryUp: false, fallback: "b", fallbackUp: true) == "b"
            && WebPanel.pick(primary: "a", primaryUp: true, fallback: "b", fallbackUp: true) == "a"
            && WebPanel.pick(primary: "a", primaryUp: false, fallback: "b", fallbackUp: false) == "a"
            && WebPanel.pick(primary: "a", primaryUp: false, fallback: nil, fallbackUp: true) == "a"
            && WebPanel.addresses(saved: "http://192.168.1.10:8123", defaultURL: "http://100.64.0.7:8123", fallback: "http://192.168.1.10:8123") == ["http://192.168.1.10:8123", "http://100.64.0.7:8123"]
            && WebPanel.choose([("http://192.168.1.10:8123", false), ("http://100.64.0.7:8123", true)]) == "http://100.64.0.7:8123"
        print("\(webOK ? "ok  " : "FAIL") web-panels: \(wn(" 100.64.0.7:8448/ ") ?? "nil"), bad addresses refused, fallback picks")
        if !webOK { ok = false }
        let br = { Browser.resolve($0)?.absoluteString ?? "nil" }
        let browserOK = br("example.com") == "https://example.com" && br("https://a.b/c?d=1") == "https://a.b/c?d=1"
            && br("http://100.64.0.7:8123") == "http://100.64.0.7:8123" && br("") == "nil"
            && br("phone grading rubric").hasPrefix("https://www.google.com/search?q=phone%20grading%20rubric")
            && br("file:///etc/passwd").hasPrefix("https://www.google.com/search?") && br("javascript:alert(1)").hasPrefix("https://www.google.com/search?")
            && br("hello").hasPrefix("https://www.google.com/search?q=hello") && br("localhost:3000") == "https://localhost:3000"
        print("\(browserOK ? "ok  " : "FAIL") browser: addresses load, words search Google, file:/javascript: never open")
        if !browserOK { ok = false }
        let ar = { (r: String, run: String, idle: Double, ed: Bool, ul: Bool, en: Bool) in
            Editor.shouldAutoRestart(readyCommit: r, runningCommit: run, idleSeconds: idle, editing: ed, underLauncher: ul, enabled: en) }
        let autoOK = ar("4c1219f", "40e3686", 31, false, true, true) && !ar("4c1219f", "40e3686", 5, false, true, true)
            && !ar("4c1219f", "4c1219f", 999, false, true, true) && !ar("", "40e3686", 999, false, true, true)
            && !ar("4c1219f", "40e3686", 999, true, true, true) && !ar("4c1219f", "40e3686", 999, false, false, true)
            && !ar("4c1219f", "40e3686", 999, false, true, false) && Editor.idleSeconds() >= 0
        print("\(autoOK ? "ok  " : "FAIL") auto-restart: only when idle 30 s, new build, under launcher, not editing, switched on")
        if !autoOK { ok = false }
        let items = Data(#"[{"id":"a","name":"GitHub","login":{"username":"owner","password":"p\"w'x"}},{"id":"b","name":"note"},{"id":"c","name":"empty","login":{"username":"u","password":""}}]"#.utf8)
        let parsed = Vault.parseItems(items)
        let script = Vault.fillScript(username: "a\"b", password: "x');alert(1);//\\")
        let vaultOK = parsed.count == 1 && parsed[0].name == "GitHub" && parsed[0].password == "p\"w'x"
            && Vault.fillable(URL(string: "https://github.com/login")) && Vault.fillable(URL(string: "http://192.168.1.21:8123"))
            && Vault.fillable(URL(string: "http://100.64.0.7:8750")) && !Vault.fillable(URL(string: "http://example.com/login"))
            && !Vault.fillable(URL(string: "file:///etc/passwd")) && !Vault.fillable(nil)
            && script.contains(#"["a\"b"][0]"#) && script.contains(#"["x');alert(1);//\\"][0]"#)
        print("\(vaultOK ? "ok  " : "FAIL") vault: logins parsed, only https/own-network pages filled, passwords can't break the fill script")
        if !vaultOK { ok = false }
        // RFC 6238 test vectors (8 digits), plus the default 6-digit bare-secret form and a bad secret.
        let at = { (t: Double) in Date(timeIntervalSince1970: t) }
        let k1 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", k256 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA"
        let totpOK = Vault.totpCode("otpauth://totp/x?secret=\(k1)&digits=8", at: at(59))?.code == "94287082"
            && Vault.totpCode("otpauth://totp/x?secret=\(k1)&digits=8", at: at(1111111109))?.code == "07081804"
            && Vault.totpCode("otpauth://totp/x?secret=\(k256)&digits=8&algorithm=SHA256", at: at(59))?.code == "46119246"
            && Vault.totpCode("gezd gnbv gy3t qojq gezd gnbv gy3t qojq", at: at(59))?.code == "287082"
            && Vault.totpCode("otpauth://totp/x?secret=\(k1)", at: at(59))?.secondsLeft == 1
            && Vault.totpCode("steam://\(k1)", at: at(59))?.code.count == 5
            && Vault.totpCode("not base32 !!") == nil && Vault.totpCode("") == nil
            && Vault.parseItems(Data(#"[{"id":"t","name":"2fa only","login":{"username":"u","password":"","totp":"\#(k1)"}}]"#.utf8)).first?.totp == k1
            && Vault.fillScript(username: "u", password: "p", code: "123456").contains(#"["123456"][0]"#)
        let haCfg = LocalConfig.resolve("HA_URL=https://alexus.example.ts.net:8443/\nALEXUS_TAILSCALE=100.64.0.7")
        let micOK = haCfg.homeAssistantURL == "https://alexus.example.ts.net:8443" && LocalConfig.resolve("HA_URL=ftp://x").homeAssistantURL == nil
            && WebPanel.micAllowed(type: .microphone, origin: "https", host: "alexus.example.ts.net", shown: "https://alexus.example.ts.net:8443")
            && !WebPanel.micAllowed(type: .camera, origin: "https", host: "alexus.example.ts.net", shown: "https://alexus.example.ts.net:8443")
            && !WebPanel.micAllowed(type: .cameraAndMicrophone, origin: "https", host: "alexus.example.ts.net", shown: "https://alexus.example.ts.net:8443")
            && !WebPanel.micAllowed(type: .microphone, origin: "http", host: "100.64.0.7", shown: "http://100.64.0.7:8123")
            && !WebPanel.micAllowed(type: .microphone, origin: "https", host: "evil.example", shown: "https://alexus.example.ts.net:8443")
        print("\(micOK ? "ok  " : "FAIL") home mic: HA_URL read, mic only on https for the shown host, never the camera")
        if !micOK { ok = false }
        print("\(totpOK ? "ok  " : "FAIL") vault 2FA: codes match RFC 6238 (SHA1, SHA256), bare secrets and steam read, bad secrets refused")
        if !totpOK { ok = false }
        let controlsOK = MainActor.assumeIsolated {
            var sequence: [String] = []
            RagnarokControlDispatch.apply(.lock, lock: { sequence.append("lock") }, show: { sequence.append("show") })
            let locksBeforeWindow = sequence == ["lock", "show"]
            sequence = []
            RagnarokControlDispatch.apply(.open, lock: { sequence.append("lock") }, show: { sequence.append("show") })
            var audit: [String] = []
            let gate = Gate(observeSystem: false, audit: { method, _, detail in audit.append(method + detail) })
            let pending = gate.authenticationGeneration
            gate.busy = true
            gate.lock("test")
            let lockedPending = !gate.unlocked && !gate.busy && !gate.acceptsAuthentication(pending)
                && !gate.automaticallyAuthenticate && audit.last?.contains("already locked") == true
            gate.unlocked = true
            gate.lock("test")
            return locksBeforeWindow && sequence == ["show"] && lockedPending && !gate.unlocked && audit.count == 2
        }
        print("\(controlsOK ? "ok  " : "FAIL") controls: lock precedes window presentation; open does not unlock; lock invalidates pending authentication")
        if !controlsOK { ok = false }
        let feeds = AllFeeds.make()
        let nFeeds = feeds.files.count + feeds.ssh.count
        print("\(nFeeds >= 10 ? "ok  " : "FAIL") feeds: \(nFeeds) set up")
        if nFeeds < 10 { ok = false }
        let handoffJSON = """
        {"id":"20261106-ho","who":"codex","started_who":"claude","handoff_from":"20261106-prev","handed_off_to":"20261106-next","handoff_chain":["grok","antigravity"],"handoffs":[{"from":"claude","to":"codex","reason":"quota reached","tools":4}],"status":"done"}
        """.data(using: .utf8)!
        let decodedRun = try? JSONDecoder().decode(AgentRun.self, from: handoffJSON)
        let handoffOK = decodedRun?.routeLabel == "claude → codex"
            && decodedRun?.handoff_chain == ["grok", "antigravity"]
            && decodedRun?.handoff_from == "20261106-prev"
            && decodedRun?.handed_off_to == "20261106-next"
            && decodedRun?.handoffs?.first?.reason == "quota reached"
        print("\(handoffOK ? "ok  " : "FAIL") agent-handoff: route \(decodedRun?.routeLabel ?? "nil")")
        if !handoffOK { ok = false }
        let hornEv = Parsers.argon("/tmp/brain/12345678/.system_generated/logs/transcript.jsonl",
                                   #"{"type":"SYSTEM_MESSAGE","created_at":"2026-11-06T20:01:00Z","content":"Stop hook blocked termination: 📯 [Alexus Local Referee] Evidence audit flagged claims"}"#)
        let hornOK = hornEv.first?.kind == "hook" && hornEv.first?.title.contains("📯 Gjallarhorn") == true
        print("\(hornOK ? "ok  " : "FAIL") gjallarhorn-parser: \(hornEv.first?.title ?? "nil")")
        if !hornOK { ok = false }
        let humanJSON = """
        {"id":"20261106-hr","who":"claude","status":"done","verdict":"needs you","human_request":"Which port should I bind (5433 or 5432)?","human_replies":[{"at":"2026-11-06T18:30:00Z","request":"Which port?","reply":"Use 5433","approved":true}]}
        """.data(using: .utf8)!
        let decodedHuman = try? JSONDecoder().decode(AgentRun.self, from: humanJSON)
        let humanResumeOK = decodedHuman?.needsHuman == true
            && decodedHuman?.humanPromptText == "Which port should I bind (5433 or 5432)?"
            && decodedHuman?.human_replies?.first?.reply == "Use 5433"
            && decodedHuman?.human_replies?.first?.approved == true
        print("\(humanResumeOK ? "ok  " : "FAIL") agent-human-resume: \(decodedHuman?.humanPromptText ?? "nil")")
        if !humanResumeOK { ok = false }
        let appPathsOK = FileManager.default.fileExists(atPath: AppPaths.bundledBin("ragnarok-agent"))
            && FileManager.default.fileExists(atPath: AppPaths.repoBin("heimdall-edit"))
            && FileManager.default.fileExists(atPath: AppPaths.fidoScript)
            && AppPaths.isHeimdallRepo(AppPaths.heimdallRepo)
            && ReceiptPipe.fallbackURL.hasSuffix(":8448")
            && MainActor.assumeIsolated { WebPanelModel.pipe.fallbackURL == ReceiptPipe.fallbackURL }
        print("\(appPathsOK ? "ok  " : "FAIL") app-paths-and-fallbacks: repo \(AppPaths.heimdallRepo), pipe fallback \(ReceiptPipe.fallbackURL)")
        if !appPathsOK { ok = false }
        check("heal", Parsers.heal("",
            #"{"ts":"2026-11-01T22:20:15Z","heal":"h1","project":"/Users/x/Developer/ragnarok-control-center","who":"claude","step":"done","ok":true,"detail":"merged"}"#), actor: "claude")
        let repTmp = NSTemporaryDirectory() + "heimdall-repair-hist-\(getpid())"
        try? FileManager.default.createDirectory(atPath: repTmp + "/incidents/inc1", withIntermediateDirectories: true)
        var repDB: OpaquePointer?
        if sqlite3_open(repTmp + "/queue.sqlite3", &repDB) == SQLITE_OK, let repDB {
            sqlite3_exec(repDB, """
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE incidents (id TEXT PRIMARY KEY, fingerprint TEXT UNIQUE, severity TEXT, priority INTEGER,
                  classification TEXT, status TEXT, first_seen TEXT, last_seen TEXT, occurrences INTEGER, event TEXT,
                  attempts INTEGER DEFAULT 0, note TEXT DEFAULT '', branch TEXT, commit_id TEXT);
                CREATE TABLE history (ts TEXT, incident TEXT, status TEXT, note TEXT);
                INSERT INTO meta VALUES ('health', '"running"'), ('source_health', '"watching"');
                INSERT INTO incidents VALUES ('inc1','fp1','high',1,'operation policy','applied_unverified',
                  '2026-11-06T01:00:00Z','2026-11-06T02:00:00Z',3,
                  '{"area":"agent-runner","code":2,"message":"spawn failed","actor":"codex","build":"abc1234"}',
                  1,'Merged tested change','codex/doctor-inc1-1','deadbeef');
                INSERT INTO history VALUES ('2026-11-06T02:00:00Z','inc1','applied_unverified','Merged tested change');
                INSERT INTO incidents VALUES ('inc2','fp2','medium',2,'error level','applied_unverified',
                  '2026-11-06T01:00:00Z','2026-11-06T02:00:00Z',1,'{"area":"fixture","message":"m"}',
                  1,'Merged tested change','doctor/inc2-1','cafe');
                INSERT INTO history VALUES ('2026-11-06T01:10:00Z','inc2','diagnosing','grok gave no usable diagnosis; trying claude');
                INSERT INTO history VALUES ('2026-11-06T01:20:00Z','inc2','diagnosing','claude made the diagnosis');
                INSERT INTO history VALUES ('2026-11-06T01:30:00Z','inc2','repairing','claude made the repair');
                INSERT INTO incidents VALUES ('inc3','fp3','low',3,'warning level','queued',
                  '2026-11-06T01:00:00Z','2026-11-06T01:00:00Z',1,'{"area":"fixture","message":"m"}',0,'',NULL,NULL);
                """, nil, nil, nil)
            sqlite3_close(repDB)
        }
        try? #"{"decision":"repair","file":"Sources/Heimdall/Agents.swift","line":42,"reason":"fixed spawn path"}"#
            .write(toFile: repTmp + "/incidents/inc1/diagnosis.json", atomically: true, encoding: .utf8)
        let editsLog = repTmp + "/edits.jsonl"
        let editsSample = """
        {"ts":"2026-11-06T01:00:00Z","edit":"e1","who":"manual","step":"start","ok":true,"detail":"fix repair log"}
        {"ts":"2026-11-06T01:01:00Z","edit":"e1","who":"manual","step":"diff","ok":true,"detail":"1 file changed"}
        {"ts":"2026-11-06T01:02:00Z","edit":"e1","who":"manual","step":"installed","ok":true,"detail":"abc1234: fix repair log"}
        {"ts":"2026-11-06T01:02:05Z","edit":"e1","who":"manual","step":"backup","ok":false,"detail":"no alexus remote"}
        {"ts":"2026-11-06T02:00:00Z","edit":"e2","who":"claude","step":"build","ok":false,"detail":"FAIL compile"}
        """
        try? editsSample.write(toFile: editsLog, atomically: true, encoding: .utf8)
        let healLog = repTmp + "/heal.jsonl"
        let healSample = """
        {"ts":"2026-11-06T03:00:00Z","heal":"h1","project":"\(repTmp)/proj","who":"claude","step":"start","ok":true,"detail":"add tests"}
        {"ts":"2026-11-06T03:01:00Z","heal":"h1","project":"\(repTmp)/proj","who":"claude","step":"done","ok":true,"detail":"merged 1234"}
        """
        try? healSample.write(toFile: healLog, atomically: true, encoding: .utf8)
        let docSnap = RepairHistoryLog.loadDoctor(home: repTmp)
        let parsedEdits = RepairHistoryLog.loadEditRuns(path: editsLog, failedPatchesDir: repTmp)
        let editFailItems = HubModel.editFailures(file: editsLog)
        let editHistItems = HubModel.editHistory(file: editsLog)
        let healHistItems = HubModel.healHistory(repTmp + "/proj", file: healLog)
        try? FileManager.default.removeItem(atPath: repTmp)
        let e1Run = parsedEdits.first { $0.id == "e1" }
        let e2Run = parsedEdits.first { $0.id == "e2" }
        // Each incident is labelled with the AI that really worked it: old "<agent>/doctor-" branch,
        // new "<agent> made the <phase>" history, and no AI named when none ran.
        let workers = Dictionary(uniqueKeysWithValues: docSnap.incidents.map { ($0.id, $0.worker) })
        let workerOK = workers == ["inc1": "codex", "inc2": "claude", "inc3": "doctor"]
        let repairLogOK = docSnap.health == "running" && docSnap.incidents.count == 3 && workerOK
            && docSnap.incidents.first?.area == "agent-runner"
            && docSnap.incidents.first?.diagnosis?.file == "Sources/Heimdall/Agents.swift"
            && docSnap.incidents.first?.history.count == 1
            && e1Run?.succeeded == true && e1Run?.installedCommit == "abc1234" && e1Run?.backupOK == false
            && e2Run?.succeeded == false && e2Run?.failedStep == "build"
            && editFailItems.count == 1 && editFailItems.first?.title == "edit build failed"
            && editHistItems.count == 1 && editHistItems.first?.title.contains("abc1234") == true
            && healHistItems.count == 1 && healHistItems.first?.kind == "receipt"
        print("\(repairLogOK ? "ok  " : "FAIL") repair-history-log: doctor=\(docSnap.incidents.count) edits=\(parsedEdits.count) editFails=\(editFailItems.count) heals=\(healHistItems.count)")
        if !repairLogOK { ok = false }
        if !fileHandleLinesOK() { ok = false }
        print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return ok
    }

    /// A quiet pipe must not block a second pipe that already has a line (the Room watch
    /// used to park every FileHandle.bytes reader). Also: a partial line, a final line
    /// with no newline, and a UTF-8 character split across reads.
    private static func fileHandleLinesOK() -> Bool {
        let bufferOK = fileHandleLineBufferOK()
        let live = fileHandleLiveLines()
        let pass = bufferOK && live.ok
        if pass { print("ok  file-handle-lines") }
        else { print("FAIL file-handle-lines: buffer \(bufferOK) \(live.why)") }
        return pass
    }

    private static func fileHandleLineBufferOK() -> Bool {
        var buf = FileHandleLines.FileHandleLineBuffer()
        if buf.append(Data("par".utf8)) != [] { return false }
        if buf.append(Data("tial\n".utf8)) != ["partial"] { return false }
        if buf.append(Data([0xF0, 0x9F])) != [] { return false }
        if buf.append(Data([0x98, 0x80, 0x0A])) != ["\u{1F600}"] { return false }
        if buf.finish() != nil { return false }
        var tail = FileHandleLines.FileHandleLineBuffer()
        if tail.append(Data("no-newline".utf8)) != [] { return false }
        if tail.finish() != "no-newline" { return false }
        var crlf = FileHandleLines.FileHandleLineBuffer()
        if crlf.append(Data("a\r\nb\r".utf8)) != ["a"] { return false }
        if crlf.finish() != "b" { return false }
        return true
    }

    private final class LineCatch: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        let arrived = DispatchSemaphore(value: 0)
        func add(_ s: String) {
            lock.lock(); lines.append(s); lock.unlock()
            arrived.signal()
        }
        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }; return lines
        }
        func waitCount(_ n: Int, timeout: TimeInterval) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if snapshot().count >= n { return true }
                let left = end.timeIntervalSinceNow
                if left <= 0 { break }
                _ = arrived.wait(timeout: .now() + min(0.05, left))
            }
            return snapshot().count >= n
        }
    }

    /// Bytes still sitting in the pipe. Zero means the reader took the chunk.
    /// `FIONREAD` (`_IOR('f', 127, int)` = 0x4004667f) is not importable from Swift.
    private static func pipeDrained(_ handle: FileHandle, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            var pending: Int32 = 0
            if ioctl(handle.fileDescriptor, 0x4004667f, &pending) == 0, pending == 0 { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private static func fileHandleLiveLines() -> (ok: Bool, why: String) {
        let quiet = Pipe(), ready = Pipe(), piece = Pipe()
        let quietOpened = DispatchSemaphore(value: 0)
        let readyLines = LineCatch(), pieceLines = LineCatch()
        let pieceDone = DispatchSemaphore(value: 0)
        let quietTask = Task.detached {
            for await _ in FileHandleLines.lines(from: quiet.fileHandleForReading, opened: { quietOpened.signal() }) {}
        }
        defer {
            try? quiet.fileHandleForWriting.close()
            try? ready.fileHandleForWriting.close()
            try? piece.fileHandleForWriting.close()
            quietTask.cancel()
        }
        guard quietOpened.wait(timeout: .now() + 2) == .success else {
            return (false, "quiet reader did not open")
        }
        // The line is already in the pipe before the second reader starts.
        ready.fileHandleForWriting.write(Data("queued\n".utf8))
        let readyTask = Task.detached {
            for await line in FileHandleLines.lines(from: ready.fileHandleForReading) {
                readyLines.add(line)
                break
            }
        }
        defer { readyTask.cancel() }
        guard readyLines.waitCount(1, timeout: 2), readyLines.snapshot() == ["queued"] else {
            return (false, "ready line \(readyLines.snapshot()) not in 2s while quiet reader was open")
        }
        let pieceOpened = DispatchSemaphore(value: 0)
        let pieceTask = Task.detached {
            for await line in FileHandleLines.lines(from: piece.fileHandleForReading, opened: { pieceOpened.signal() }) {
                pieceLines.add(line)
            }
            pieceDone.signal()
        }
        defer { pieceTask.cancel() }
        guard pieceOpened.wait(timeout: .now() + 2) == .success else {
            return (false, "piece reader did not open")
        }
        piece.fileHandleForWriting.write(Data("par".utf8))
        guard pipeDrained(piece.fileHandleForReading, timeout: 1), pieceLines.snapshot().isEmpty else {
            return (false, "partial line was delivered early: \(pieceLines.snapshot())")
        }
        piece.fileHandleForWriting.write(Data("tial\n".utf8))
        guard pieceLines.waitCount(1, timeout: 2) else { return (false, "partial line did not complete") }
        // 😀 is F0 9F 98 80. The first two bytes must sit in the reader before the rest arrives.
        piece.fileHandleForWriting.write(Data([0xF0, 0x9F]))
        guard pipeDrained(piece.fileHandleForReading, timeout: 1), pieceLines.snapshot().count == 1 else {
            return (false, "split UTF-8 emitted early: \(pieceLines.snapshot())")
        }
        piece.fileHandleForWriting.write(Data([0x98, 0x80, 0x0A]))
        guard pieceLines.waitCount(2, timeout: 2) else { return (false, "split UTF-8 line did not complete") }
        piece.fileHandleForWriting.write(Data("no-newline".utf8))
        guard pipeDrained(piece.fileHandleForReading, timeout: 1), pieceLines.snapshot().count == 2 else {
            return (false, "no-newline tail delivered before EOF: \(pieceLines.snapshot())")
        }
        try? piece.fileHandleForWriting.close()
        guard pieceDone.wait(timeout: .now() + 2) == .success else {
            return (false, "piece reader did not finish at EOF")
        }
        let got = pieceLines.snapshot()
        guard got == ["partial", "\u{1F600}", "no-newline"] else {
            return (false, "lines \(got)")
        }
        return (true, "")
    }
}

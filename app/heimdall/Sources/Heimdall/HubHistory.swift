import Foundation
import SQLite3
import SwiftUI
import AppKit
import AlexusKit

/// One history per project: git commits, Hub/terminal receipts, project self-heal runs, Heimdall self-edits & doctor
/// incidents, failures (failed receipts, Heimdall edit failures, failed heal runs, failed conveyor jobs), conveyor jobs,
/// Alexus container starts/stops/restarts and health, room tasks and timeline events.
extension HubModel {
    struct Item: Identifiable, Hashable {
        let time: Date; let kind: String; let who: String; let title: String; var detail = ""
        var id: String { "\(time.timeIntervalSince1970)|\(kind)|\(title)" }
    }

    /// kinds: commit · receipt · failure · conveyor · container · room · activity
    nonisolated static let historyKinds = ["all": "All", "code": "Code", "runs": "Runs", "failure": "Failures", "alexus": "Alexus", "ai": "AI"]

    nonisolated static func matches(_ kind: String, _ filter: String) -> Bool {
        switch filter {
        case "code": return kind == "commit"
        case "runs": return kind == "receipt" || kind == "conveyor"
        case "failure": return kind == "failure"
        case "alexus": return kind == "container"
        case "ai": return kind == "room" || kind == "activity" || kind == "conveyor"
        default: return true
        }
    }

    func loadHistory(_ p: Project) {
        historyFor = p.path; history = []; historyLoading = true
        Task {
            let items = await Task.detached { Self.history(p) }.value
            guard historyFor == p.path else { return }
            history = items; historyLoading = false
        }
    }

    nonisolated static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated static func pathMatches(_ candidate: String, projectDir: String) -> Bool {
        guard !candidate.isEmpty, !projectDir.isEmpty else { return false }
        let rawC = (candidate as NSString).expandingTildeInPath
        let rawP = (projectDir as NSString).expandingTildeInPath
        if rawC == rawP || rawC.hasPrefix(rawP + "/") { return true }
        let canC = canonicalPath(rawC)
        let canP = canonicalPath(rawP)
        if canC == canP || canC.hasPrefix(canP + "/") { return true }
        if AppPaths.isHeimdallRepo(rawP) && AppPaths.isHeimdallRepo(rawC) { return true }
        return false
    }

    nonisolated static func history(_ p: Project) -> [Item] {
        var out: [Item] = []
        if p.path.hasPrefix("/") {
            out += commits(p.path)
            out += receipts(p.path)
            out += healHistory(p.path)
            if AppPaths.isHeimdallRepo(p.path) {   // N30: by real path only, not by folder name
                out += editHistory()
                out += editFailures()
                out += doctorHistory()
            }
        }
        out += conveyorJobs(HubView.roomName(p))
        out += containerHistory(p.containers.map(\.name))
        return out
    }

    nonisolated static func iso(_ s: String?) -> Date? {
        guard let s, !s.isEmpty, !s.hasPrefix("0001") else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Docker gives nanoseconds; trim to milliseconds
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let t = s.replacingCharacters(in: r, with: String(s[r].prefix(4))); if let d = f.date(from: t) { return d }
        }
        f.formatOptions = [.withInternetDateTime]; return f.date(from: s)
    }

    nonisolated static func commits(_ dir: String) -> [Item] {
        guard let s = git(dir, ["log", "-40", "--format=%cI%x09%an%x09%h%x09%s"]) else { return [] }
        return s.split(separator: "\n").compactMap { l in
            let f = l.split(separator: "\t", maxSplits: 3).map(String.init)
            guard f.count == 4, let t = iso(f[0]) else { return nil }
            return Item(time: t, kind: "commit", who: f[1], title: f[3], detail: f[2])
        }
    }

    nonisolated static func jsonLines(_ path: String) -> [[String: Any]] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// Hub and Room-terminal receipts whose folder is this project (or inside it).
    nonisolated static func receipts(_ dir: String, file: String = Receipts.file) -> [Item] {
        jsonLines(file).compactMap { d in
            guard let cwd = d["cwd"] as? String, pathMatches(cwd, projectDir: dir), let t = iso(d["ts"] as? String) else { return nil }
            let v = d["verdict"] as? String ?? ""
            let bad = v == "failed" || v == "mismatch"
            let n = (d["changed"] as? [Any])?.count ?? 0
            let q = (d["question"] as? String ?? "").oneLine(140)
            let why = (d["claims"] as? [[String: Any]] ?? []).filter { $0["ok"] as? Bool == false }
                .map { "said \($0["verb"] ?? "") \($0["path"] ?? "") but \($0["why"] ?? "")" }.joined(separator: "; ")
            return Item(time: t, kind: bad ? "failure" : "receipt", who: Actors.normalize(d["provider"] as? String ?? ""),
                        title: (bad ? (v == "failed" ? "failed (exit \(d["exit"] ?? "?")): " : "claims didn't match: ") : "") + q,
                        detail: why.isEmpty ? "\(n) file\(n == 1 ? "" : "s") changed" : why)
        }
    }

    /// Project self-healing runs from ~/.ragnarok/ragnarok-heal.jsonl for this project.
    nonisolated static func healHistory(_ dir: String, file: String = home + "/.ragnarok/ragnarok-heal.jsonl") -> [Item] {
        RepairHistoryLog.loadHealRuns(path: file).compactMap { run in
            guard pathMatches(run.project, projectDir: dir) else { return nil }
            let bad = !run.succeeded
            let instr = run.instruction.isEmpty ? "self-heal run \(run.id)" : run.instruction.oneLine(120)
            let title = bad
                ? "ragnarok-heal \(run.failedStep.isEmpty ? run.status : run.failedStep) failed: \(instr)"
                : "ragnarok-heal (\(run.status)): \(instr)"
            var detailParts: [String] = []
            if !run.detail.isEmpty { detailParts.append(run.detail.oneLine(160)) }
            if !run.diffStat.isEmpty { detailParts.append(run.diffStat.oneLine(120)) }
            if let patch = run.patchPath { detailParts.append("saved patch: \((patch as NSString).abbreviatingWithTildeInPath)") }
            return Item(time: run.updatedAt, kind: bad ? "failure" : "receipt", who: run.actor,
                        title: title, detail: detailParts.joined(separator: " · "))
        }
    }

    /// Heimdall's completed self-edits and launcher verifications (~/.ragnarok/heimdall-edits.jsonl).
    nonisolated static func editHistory(file: String = home + "/.ragnarok/heimdall-edits.jsonl") -> [Item] {
        RepairHistoryLog.loadEditRuns(path: file).compactMap { run in
            guard run.succeeded else { return nil }
            if run.isLauncher {
                return Item(time: run.updatedAt, kind: "receipt", who: "heimdall",
                            title: "launcher \(run.status): \(run.detail.oneLine(140))", detail: "")
            }
            let instr = run.instruction.isEmpty ? "manual edit" : run.instruction.oneLine(120)
            let commitPrefix = run.installedCommit.isEmpty ? "" : "\(run.installedCommit) — "
            return Item(time: run.updatedAt, kind: "receipt", who: run.actor,
                        title: "heimdall-edit installed: \(commitPrefix)\(instr)",
                        detail: run.diffStat.oneLine(180))
        }
    }

    /// Heimdall's own edit/launcher failures (failed steps, rollbacks, fallbacks).
    /// Off-Mac backup push warnings (`step == "backup"`) never block or fail an installed edit.
    nonisolated static func editFailures(file: String = home + "/.ragnarok/heimdall-edits.jsonl") -> [Item] {
        var seen = Set<String>()
        return jsonLines(file).compactMap { d in
            let step = d["step"] as? String ?? ""
            guard step != "backup" else { return nil }
            guard d["ok"] as? Bool == false || step == "rollback" || step == "fallback" || step == "crash",
                  let t = iso(d["ts"] as? String) else { return nil }
            var detail = (d["detail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("\n") {
                let fl = detail.split(separator: "\n").filter { $0.hasPrefix("FAIL") }
                detail = fl.isEmpty ? String(detail.split(separator: "\n").last ?? "") : fl.joined(separator: "; ")
            }
            guard seen.insert(step + detail.prefix(120)).inserted else { return nil }
            return Item(time: t, kind: "failure", who: Actors.normalize(d["who"] as? String ?? ""),
                        title: "\(d["edit"] as? String == "launcher" ? "launcher" : "edit") \(step)\(["rollback", "fallback", "crash"].contains(step) ? "" : " failed")",
                        detail: String(detail.prefix(240)))
        }
    }

    /// Ragnarok Doctor incidents for Heimdall (~/.ragnarok/doctor/queue.sqlite3).
    nonisolated static func doctorHistory(doctorHome: String = home + "/.ragnarok/doctor") -> [Item] {
        let snap = RepairHistoryLog.loadDoctor(home: doctorHome)
        return snap.incidents.map { inc in
            let isFail = ["failed", "needs_attention", "review_rejected", "interrupted"].contains(inc.status)
            let kind = isFail ? "failure" : "receipt"
            let title = "doctor [\(inc.severity)] \(inc.area): \(inc.status.replacingOccurrences(of: "_", with: " ")) (\(inc.occurrences)x)"
            let detail = [inc.message.oneLine(120), inc.diagnosis?.reason.oneLine(120) ?? inc.note].filter { !$0.isEmpty }.joined(separator: " · ")
            return Item(time: inc.lastSeenDate, kind: kind, who: inc.worker, title: title, detail: detail)
        }
    }

    /// Conveyor jobs (main and every lane) whose task text names this project: done, needs the owner, or failed.
    nonisolated static func conveyorJobs(_ name: String) -> [Item] {
        let fm = FileManager.default
        var roots = [home + "/conveyor"]
        roots += ((try? fm.contentsOfDirectory(atPath: home + "/conveyor-lanes")) ?? []).map { home + "/conveyor-lanes/" + $0 }
        var out: [Item] = []
        for r in roots {
            for (folder, state) in [("done", "done"), ("human", "needs you"), ("failed", "failed")] {
                for f in (try? fm.contentsOfDirectory(atPath: r + "/" + folder)) ?? [] where f.hasSuffix(".md") {
                    let path = r + "/" + folder + "/" + f
                    guard let s = try? String(contentsOfFile: path, encoding: .utf8), s.contains("In \(name):") || s.contains(name + "/") || s.contains(name + " ") else { continue }
                    let t = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                    let title = s.split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? f
                    let reason = state == "failed" ? (s.components(separatedBy: "Dead End").dropFirst().first.map { $0.oneLine(200) } ?? "") : ""
                    out.append(Item(time: t, kind: state == "failed" ? "failure" : "conveyor", who: "conveyor",
                                    title: "conveyor job \(state): \(title)", detail: reason.isEmpty ? (path as NSString).abbreviatingWithTildeInPath : reason))
                }
            }
        }
        return out
    }

    /// Started, stopped, restart count and health for each container (docker inspect on Alexus).
    nonisolated static func containerHistory(_ names: [String]) -> [Item] {
        let ns = names.filter(safeName)
        guard !ns.isEmpty else { return [] }
        let fmt = "{{.Name}}\t{{.State.StartedAt}}\t{{.State.FinishedAt}}\t{{.RestartCount}}\t{{.State.Status}}\t{{.State.ExitCode}}\t{{if .State.Health}}{{.State.Health.Status}}\t{{.State.Health.FailingStreak}}{{end}}"
        let (code, out) = run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", sshTarget(),
                                               "docker inspect --format '\(fmt)' " + ns.joined(separator: " ")], timeout: 20)
        guard code == 0 else { return [] }
        return parseInspect(out, now: Date())
    }

    nonisolated static func parseInspect(_ out: String, now: Date) -> [Item] {
        var items: [Item] = []
        for l in out.split(separator: "\n") {
            let f = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { continue }
            let name = f[0].hasPrefix("/") ? String(f[0].dropFirst()) : f[0]
            let restarts = Int(f[3]) ?? 0
            let health = f.count > 6 ? f[6] : ""
            if let s = iso(f[1]) {
                var title = "\(name) started"
                if restarts > 0 { title += " (Docker has restarted it \(restarts) time\(restarts == 1 ? "" : "s"))" }
                items.append(Item(time: s, kind: "container", who: "docker", title: title,
                                  detail: "now \(f[4])" + (health.isEmpty ? "" : ", health \(health)" + (f.count > 7 && f[7] != "0" ? " (\(f[7]) checks failing in a row)" : ""))))
            }
            if let e = iso(f[2]), f[4] != "running" || (iso(f[1]).map { e < $0 } == false) {
                items.append(Item(time: e, kind: f[5] == "0" ? "container" : "failure", who: "docker", title: "\(name) stopped (exit \(f[5]))"))
            }
            if health == "unhealthy" {
                items.append(Item(time: now, kind: "failure", who: "docker", title: "\(name) is unhealthy now",
                                  detail: f.count > 7 ? "\(f[7]) health checks failing in a row" : ""))
            }
        }
        return items
    }
}

// MARK: - Unified Repair History Log Model & Parsers

enum RepairHistoryLog {
    struct DoctorDiagnosis: Equatable, Sendable {
        let decision: String
        let file: String
        let line: Int
        let reason: String
    }

    struct DoctorHistoryStep: Identifiable, Equatable, Sendable {
        let ts: String
        let status: String
        let note: String
        var id: String { "\(ts)|\(status)|\(note)" }
    }

    struct DoctorIncident: Identifiable, Equatable, Sendable {
        let id: String
        let severity: String
        let priority: Int
        let classification: String
        let status: String
        let firstSeen: String
        let lastSeen: String
        let occurrences: Int
        let attempts: Int
        let note: String
        let branch: String
        let commitID: String
        let area: String
        let domain: String
        let code: String
        let message: String
        let actor: String
        let build: String
        let diagnosis: DoctorDiagnosis?
        let repairSummary: String?
        let reviewVerdict: String?
        let reviewReason: String?
        let history: [DoctorHistoryStep]

        var lastSeenDate: Date { HubModel.iso(lastSeen) ?? HubModel.iso(firstSeen) ?? .distantPast }
        /// Which AI really worked this incident. The daemon writes "<agent> made the <phase>" to its history
        /// (newest first here). Incidents from before the agent order have a "<agent>/doctor-…" branch.
        /// When neither says, no AI is named: "doctor".
        var worker: String {
            let agents = ["claude", "grok", "muse", "codex"]
            for step in history {
                let words = step.note.split(separator: " ")
                if words.count == 4, words[1] == "made", words[2] == "the", agents.contains(String(words[0])) { return String(words[0]) }
            }
            if let slash = branch.firstIndex(of: "/"), branch[slash...].hasPrefix("/doctor-"),
               agents.contains(String(branch[..<slash])) { return String(branch[..<slash]) }
            return "doctor"
        }
        var isTerminal: Bool {
            ["no_code_change", "needs_attention", "review_rejected", "failed", "interrupted",
             "installed_unverified", "tested_branch", "applied_unverified"].contains(status)
        }
    }

    struct DoctorSnapshot: Equatable, Sendable {
        var health: String = "Unverified"
        var sourceHealth: String = "Unverified"
        var lastTick: String = ""
        var activePhase: String = ""
        var lastPhaseResult: String = ""
        var sourceGap: String = ""
        var queueOverflow: Int = 0
        var maxAttempts: Int = 1
        var incidents: [DoctorIncident] = []
    }

    struct EditRun: Identifiable, Equatable, Sendable {
        let id: String
        let who: String
        let actor: String
        let by: String
        let isLauncher: Bool
        var startedAt: Date
        var updatedAt: Date
        var instruction: String
        var diffStat: String
        var installedCommit: String
        var status: String
        var succeeded: Bool
        var failedStep: String
        var detail: String
        var backupOK: Bool?
        var backupNote: String
        var patchPath: String?
    }

    struct HealRun: Identifiable, Equatable, Sendable {
        let id: String
        let project: String
        let projectName: String
        let who: String
        let actor: String
        let by: String
        var startedAt: Date
        var updatedAt: Date
        var instruction: String
        var diffStat: String
        var status: String
        var succeeded: Bool
        var failedStep: String
        var detail: String
        var patchPath: String?
    }

    struct ReceiptEntry: Identifiable, Equatable, Sendable {
        let id: String
        let time: Date
        let provider: String
        let cwd: String
        let question: String
        let seconds: Int
        let exitCode: Int
        let changed: [String]
        let claimsTotal: Int
        let claimsFailed: [String]
        let verdict: String
    }

    nonisolated static func actorName(for who: String) -> String {
        switch who {
        case "manual": return "owner"
        case "launcher": return "heimdall"
        case "gemini": return "gemini"
        default: return who.hasPrefix("api:") ? who : Actors.normalize(who)
        }
    }

    /// Reads ~/.ragnarok/doctor/queue.sqlite3 and ~/.ragnarok/doctor/incidents/<id>/*.json without mutating daemon state.
    nonisolated static func loadDoctor(home: String = NSHomeDirectory() + "/.ragnarok/doctor") -> DoctorSnapshot {
        var snap = DoctorSnapshot()
        let configPath = (home as NSString).appendingPathComponent("config.json")
        if let cfgData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
           let maxAtt = cfg["max_attempts"] as? Int {
            snap.maxAttempts = maxAtt
        }
        let dbPath = (home as NSString).appendingPathComponent("queue.sqlite3")
        guard FileManager.default.fileExists(atPath: dbPath) else { return snap }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return snap
        }
        defer { sqlite3_close(db) }

        func col(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, idx) else { return "" }
            return String(cString: c)
        }

        // 1. Read meta table
        var metaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT key, value FROM meta", -1, &metaStmt, nil) == SQLITE_OK {
            while sqlite3_step(metaStmt) == SQLITE_ROW {
                let k = col(metaStmt, 0)
                let raw = col(metaStmt, 1)
                let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]))
                switch k {
                case "health": snap.health = (parsed as? String) ?? raw
                case "source_health": snap.sourceHealth = (parsed as? String) ?? raw
                case "last_tick": snap.lastTick = (parsed as? String) ?? raw
                case "source_gap": snap.sourceGap = (parsed as? String) ?? ""
                case "queue_overflow": snap.queueOverflow = (parsed as? Int) ?? Int(raw) ?? 0
                case "active_phase":
                    if let d = parsed as? [String: Any], let inc = d["incident"] as? String, let ph = d["phase"] as? String {
                        snap.activePhase = "\(inc): \(ph)"
                    }
                case "last_phase_result":
                    if let d = parsed as? [String: Any], let inc = d["incident"] as? String, let ph = d["phase"] as? String {
                        let code = d["exit_code"].map { "\($0)" } ?? "?"
                        snap.lastPhaseResult = "\(inc) · \(ph) (exit \(code))"
                    }
                default: break
                }
            }
        }
        sqlite3_finalize(metaStmt)

        // 2. Read history table grouped by incident
        var histByIncident: [String: [DoctorHistoryStep]] = [:]
        var histStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT ts, incident, status, note FROM history ORDER BY ts DESC", -1, &histStmt, nil) == SQLITE_OK {
            while sqlite3_step(histStmt) == SQLITE_ROW {
                let inc = col(histStmt, 1)
                histByIncident[inc, default: []].append(
                    DoctorHistoryStep(ts: col(histStmt, 0), status: col(histStmt, 2), note: col(histStmt, 3))
                )
            }
        }
        sqlite3_finalize(histStmt)

        // 3. Read incidents table
        var incStmt: OpaquePointer?
        let sql = """
        SELECT id, severity, priority, classification, status, first_seen, last_seen,
               occurrences, attempts, event, note, COALESCE(branch, ''), COALESCE(commit_id, '')
        FROM incidents ORDER BY priority ASC, last_seen DESC
        """
        if sqlite3_prepare_v2(db, sql, -1, &incStmt, nil) == SQLITE_OK {
            while sqlite3_step(incStmt) == SQLITE_ROW {
                let iid = col(incStmt, 0)
                let evRaw = col(incStmt, 9)
                let ev = (try? JSONSerialization.jsonObject(with: Data(evRaw.utf8)) as? [String: Any]) ?? [:]
                let incDir = ((home as NSString).appendingPathComponent("incidents") as NSString).appendingPathComponent(iid)
                var diag: DoctorDiagnosis?
                if let dData = try? Data(contentsOf: URL(fileURLWithPath: (incDir as NSString).appendingPathComponent("diagnosis.json"))),
                   let dObj = try? JSONSerialization.jsonObject(with: dData) as? [String: Any] {
                    diag = DoctorDiagnosis(
                        decision: dObj["decision"] as? String ?? "",
                        file: dObj["file"] as? String ?? "",
                        line: dObj["line"] as? Int ?? 0,
                        reason: dObj["reason"] as? String ?? ""
                    )
                }
                var repSummary: String?
                if let rData = try? Data(contentsOf: URL(fileURLWithPath: (incDir as NSString).appendingPathComponent("repair.json"))),
                   let rObj = try? JSONSerialization.jsonObject(with: rData) as? [String: Any] {
                    repSummary = rObj["summary"] as? String
                }
                var revVerdict: String?
                var revReason: String?
                if let vData = try? Data(contentsOf: URL(fileURLWithPath: (incDir as NSString).appendingPathComponent("review.json"))),
                   let vObj = try? JSONSerialization.jsonObject(with: vData) as? [String: Any] {
                    revVerdict = vObj["verdict"] as? String
                    revReason = vObj["reason"] as? String
                }
                snap.incidents.append(DoctorIncident(
                    id: iid,
                    severity: col(incStmt, 1),
                    priority: Int(sqlite3_column_int(incStmt, 2)),
                    classification: col(incStmt, 3),
                    status: col(incStmt, 4),
                    firstSeen: col(incStmt, 5),
                    lastSeen: col(incStmt, 6),
                    occurrences: Int(sqlite3_column_int(incStmt, 7)),
                    attempts: Int(sqlite3_column_int(incStmt, 8)),
                    note: col(incStmt, 10),
                    branch: col(incStmt, 11),
                    commitID: col(incStmt, 12),
                    area: ev["area"] as? String ?? "app",
                    domain: ev["domain"] as? String ?? "",
                    code: ev["code"].map { "\($0)" } ?? "",
                    message: ev["message"] as? String ?? "",
                    actor: ev["actor"] as? String ?? "Unverified",
                    build: ev["build"] as? String ?? "Unverified",
                    diagnosis: diag,
                    repairSummary: repSummary,
                    reviewVerdict: revVerdict,
                    reviewReason: revReason,
                    history: histByIncident[iid] ?? []
                ))
            }
        }
        sqlite3_finalize(incStmt)
        return snap
    }

    /// Groups ~/.ragnarok/heimdall-edits.jsonl into discrete edit runs and launcher events, newest first.
    nonisolated static func loadEditRuns(
        path: String = NSHomeDirectory() + "/.ragnarok/heimdall-edits.jsonl",
        failedPatchesDir: String = NSHomeDirectory() + "/.ragnarok/failed-edits"
    ) -> [EditRun] {
        let rows = HubModel.jsonLines(path)
        var order: [String] = []
        var byID: [String: EditRun] = [:]
        var launcherSeq = 0
        let fm = FileManager.default

        for d in rows {
            let rawID = d["edit"] as? String ?? "?"
            let who = d["who"] as? String ?? ""
            let by = d["by"] as? String ?? ""
            let step = d["step"] as? String ?? ""
            let ok = d["ok"] as? Bool ?? true
            let detail = (d["detail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let t = HubModel.iso(d["ts"] as? String) ?? .distantPast

            if rawID == "launcher" || who == "launcher" {
                launcherSeq += 1
                let lid = "launcher-\(launcherSeq)-\(Int(t.timeIntervalSince1970))"
                let succeeded = ok && !["rollback", "fallback", "crash"].contains(step)
                let run = EditRun(
                    id: lid, who: "launcher", actor: "heimdall", by: by, isLauncher: true,
                    startedAt: t, updatedAt: t, instruction: "Launcher \(step)", diffStat: "",
                    installedCommit: "", status: step, succeeded: succeeded,
                    failedStep: succeeded ? "" : step, detail: detail,
                    backupOK: nil, backupNote: "", patchPath: nil
                )
                order.append(lid)
                byID[lid] = run
                continue
            }

            if byID[rawID] == nil {
                let patchCandidate = (failedPatchesDir as NSString).appendingPathComponent("\(rawID).patch")
                let patch = fm.fileExists(atPath: patchCandidate) ? patchCandidate : nil
                order.append(rawID)
                byID[rawID] = EditRun(
                    id: rawID, who: who, actor: actorName(for: who), by: by, isLauncher: false,
                    startedAt: t, updatedAt: t, instruction: "", diffStat: "",
                    installedCommit: "", status: step, succeeded: true,
                    failedStep: "", detail: "", backupOK: nil, backupNote: "", patchPath: patch
                )
            }
            guard var run = byID[rawID] else { continue }
            if t > run.updatedAt { run.updatedAt = t }
            switch step {
            case "start":
                if run.instruction.isEmpty && !detail.isEmpty { run.instruction = detail }
                if !ok { run.succeeded = false; run.failedStep = "start"; run.status = "failed"; run.detail = detail }
            case "diff":
                run.diffStat = detail
            case "installed":
                if ok {
                    run.status = "installed"
                    run.succeeded = true
                    run.failedStep = ""
                    let parts = detail.split(separator: ":", maxSplits: 1).map(String.init)
                    if let first = parts.first, first.count <= 12 {
                        run.installedCommit = first.trimmingCharacters(in: .whitespaces)
                    }
                    if run.instruction.isEmpty, parts.count > 1 {
                        run.instruction = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                    run.detail = detail
                } else {
                    run.status = "failed"
                    run.succeeded = false
                    run.failedStep = "install"
                    run.detail = detail
                }
            case "backup":
                run.backupOK = ok
                run.backupNote = detail
            default:
                if !ok {
                    run.succeeded = false
                    run.failedStep = step
                    run.status = "failed"
                    if detail.contains("\n") {
                        let fl = detail.split(separator: "\n").filter { $0.hasPrefix("FAIL") }
                        run.detail = fl.isEmpty ? String(detail.split(separator: "\n").last ?? "") : fl.joined(separator: "; ")
                    } else {
                        run.detail = detail
                    }
                } else if run.status != "installed" {
                    run.status = step
                }
            }
            byID[rawID] = run
        }
        return order.compactMap { byID[$0] }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Groups ~/.ragnarok/ragnarok-heal.jsonl into discrete project self-heal runs, newest first.
    nonisolated static func loadHealRuns(
        path: String = NSHomeDirectory() + "/.ragnarok/ragnarok-heal.jsonl",
        failedPatchesDir: String = NSHomeDirectory() + "/.ragnarok/failed-edits"
    ) -> [HealRun] {
        let rows = HubModel.jsonLines(path)
        var order: [String] = []
        var byID: [String: HealRun] = [:]
        let fm = FileManager.default

        for d in rows {
            let hid = d["heal"] as? String ?? "?"
            let project = d["project"] as? String ?? ""
            let projName = (project as NSString).lastPathComponent
            let who = d["who"] as? String ?? ""
            let by = d["by"] as? String ?? ""
            let step = d["step"] as? String ?? ""
            let ok = d["ok"] as? Bool ?? true
            let detail = (d["detail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let t = HubModel.iso(d["ts"] as? String) ?? .distantPast

            if byID[hid] == nil {
                let patchCandidate = (failedPatchesDir as NSString).appendingPathComponent("\(hid).patch")
                let patch = fm.fileExists(atPath: patchCandidate) ? patchCandidate : nil
                order.append(hid)
                byID[hid] = HealRun(
                    id: hid, project: project, projectName: projName.isEmpty ? project : projName,
                    who: who, actor: actorName(for: who), by: by,
                    startedAt: t, updatedAt: t, instruction: "", diffStat: "",
                    status: step, succeeded: true, failedStep: "", detail: "", patchPath: patch
                )
            }
            guard var run = byID[hid] else { continue }
            if t > run.updatedAt { run.updatedAt = t }
            switch step {
            case "start":
                if run.instruction.isEmpty && !detail.isEmpty { run.instruction = detail }
                if !ok { run.succeeded = false; run.failedStep = "start"; run.status = "failed"; run.detail = detail }
            case "diff":
                run.diffStat = detail
            case "done", "merged", "kept":
                run.status = step
                run.succeeded = ok
                if !detail.isEmpty { run.detail = detail }
            default:
                if !ok {
                    run.succeeded = false
                    run.failedStep = step
                    run.status = "failed"
                    if detail.contains("\n") {
                        let fl = detail.split(separator: "\n").filter { $0.hasPrefix("FAIL") }
                        run.detail = fl.isEmpty ? String(detail.split(separator: "\n").last ?? "") : fl.joined(separator: "; ")
                    } else {
                        run.detail = detail
                    }
                } else if !["done", "merged", "kept"].contains(run.status) {
                    run.status = step
                }
            }
            byID[hid] = run
        }
        return order.compactMap { byID[$0] }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Loads ~/.ragnarok/terminal-receipts.jsonl entries newest first.
    nonisolated static func loadReceipts(path: String = Receipts.file) -> [ReceiptEntry] {
        var seq = 0
        return HubModel.jsonLines(path).compactMap { d in
            guard let t = HubModel.iso(d["ts"] as? String) else { return nil }
            seq += 1
            let changed = (d["changed"] as? [String]) ?? []
            let claims = (d["claims"] as? [[String: Any]]) ?? []
            let badClaims = claims.filter { $0["ok"] as? Bool == false }.map {
                "said \($0["verb"] ?? "") \((($0["path"] as? String ?? "") as NSString).abbreviatingWithTildeInPath) but \($0["why"] ?? "")"
            }
            return ReceiptEntry(
                id: "rcpt-\(seq)-\(Int(t.timeIntervalSince1970))",
                time: t,
                provider: Actors.normalize(d["provider"] as? String ?? ""),
                cwd: d["cwd"] as? String ?? "",
                question: d["question"] as? String ?? "",
                seconds: d["seconds"] as? Int ?? 0,
                exitCode: d["exit"] as? Int ?? 0,
                changed: changed,
                claimsTotal: claims.count,
                claimsFailed: badClaims,
                verdict: d["verdict"] as? String ?? "unknown"
            )
        }.sorted { $0.time > $1.time }
    }
}

// MARK: - Activity → Repair History View

@MainActor
final class RepairHistoryStore: ObservableObject {
    @Published var doctor = RepairHistoryLog.DoctorSnapshot()
    @Published var edits: [RepairHistoryLog.EditRun] = []
    @Published var heals: [RepairHistoryLog.HealRun] = []
    @Published var receipts: [RepairHistoryLog.ReceiptEntry] = []
    @Published var loading = false
    @Published var actionNote = ""

    func refresh() {
        loading = true
        Task {
            let loaded = await Task.detached {
                (
                    doctor: RepairHistoryLog.loadDoctor(),
                    edits: RepairHistoryLog.loadEditRuns(),
                    heals: RepairHistoryLog.loadHealRuns(),
                    receipts: RepairHistoryLog.loadReceipts()
                )
            }.value
            self.doctor = loaded.doctor
            self.edits = loaded.edits
            self.heals = loaded.heals
            self.receipts = loaded.receipts
            self.loading = false
        }
    }

    func retryIncident(_ id: String) {
        actionNote = "Requesting retry for incident \(id)…"
        Task {
            let msg = await Task.detached { () -> String in
                let script = AppPaths.repoBin("ragnarok-doctor")
                let (_, out) = HubModel.run("/usr/bin/python3", [script, "retry", id], timeout: 15)
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "Queued incident \(id) for retry." : trimmed
            }.value
            self.actionNote = msg
            self.refresh()
        }
    }
}

struct RepairHistoryView: View {
    @ObservedObject var alexus: AlexusWorkspace
    @StateObject private var store = RepairHistoryStore()
    @State private var filter = "all"
    @State private var search = ""
    @State private var expanded: Set<String> = []

    private let filters: [(id: String, title: String)] = [
        ("all", "All"),
        ("doctor", "Doctor"),
        ("edits", "Heimdall Edits"),
        ("heal", "Project Heal"),
        ("receipts", "Receipts"),
        ("companion", "Companion")
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if filter == "companion" {
                AlexusPanel(.receipts, workspace: alexus)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        doctorStatusBanner
                        if !store.actionNote.isEmpty {
                            HStack {
                                Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                                Text(store.actionNote).font(.caption).textSelection(.enabled)
                                Spacer()
                                Button("Dismiss") { store.actionNote = "" }.controlSize(.mini)
                            }
                            .padding(8)
                            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                        if filter == "all" || filter == "doctor" { doctorSection }
                        if filter == "all" || filter == "edits" { editsSection }
                        if filter == "all" || filter == "heal" { healSection }
                        if filter == "all" || filter == "receipts" { receiptsSection }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task { store.refresh() }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $filter) {
                ForEach(filters, id: \.id) { item in
                    Text(item.title + badge(for: item.id)).tag(item.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 640)

            TextField("Filter repairs, projects, commits, incidents…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            if store.loading { ProgressView().controlSize(.small) }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func badge(for id: String) -> String {
        switch id {
        case "doctor": return store.doctor.incidents.isEmpty ? "" : " (\(store.doctor.incidents.count))"
        case "edits": return store.edits.isEmpty ? "" : " (\(store.edits.count))"
        case "heal": return store.heals.isEmpty ? "" : " (\(store.heals.count))"
        case "receipts": return store.receipts.isEmpty ? "" : " (\(store.receipts.count))"
        default: return ""
        }
    }

    private func matchesSearch(_ text: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.isEmpty || text.lowercased().contains(q)
    }

    private var doctorStatusBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(store.doctor.health == "running" ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text("Ragnarok Doctor: \(store.doctor.health)")
                    .font(.subheadline.bold())
                Text("Source: \(store.doctor.sourceHealth)")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.doctor.lastTick.isEmpty {
                    Text("Last tick: \(HubView.when(HubModel.iso(store.doctor.lastTick) ?? Date()))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !store.doctor.activePhase.isEmpty {
                    Text("Active: \(store.doctor.activePhase)")
                        .font(.caption.bold()).foregroundStyle(.blue)
                }
                Spacer()
                if !store.doctor.lastPhaseResult.isEmpty {
                    Text("Last phase: \(store.doctor.lastPhaseResult)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            if !store.doctor.sourceGap.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    Text("Source log notice: \(store.doctor.sourceGap)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var doctorSection: some View {
        let items = store.doctor.incidents.filter {
            matchesSearch("\($0.id) \($0.area) \($0.severity) \($0.status) \($0.message) \($0.note) \($0.diagnosis?.reason ?? "")")
        }
        sectionBox("Ragnarok Doctor Incidents (\(items.count))") {
            if items.isEmpty {
                Text("No matching incidents in ~/.ragnarok/doctor/queue.sqlite3.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { inc in
                let isExp = expanded.contains("doc-\(inc.id)")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        statusPill(inc.severity, color: severityColor(inc.severity))
                        statusPill(inc.status.replacingOccurrences(of: "_", with: " "), color: doctorStatusColor(inc.status))
                        Text(inc.area + (inc.code.isEmpty ? "" : " (\(inc.code))"))
                            .font(.callout.bold())
                        Text("· \(inc.occurrences)x · \(inc.attempts)/\(store.doctor.maxAttempts) attempt\(store.doctor.maxAttempts == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(HubView.when(inc.lastSeenDate))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if inc.isTerminal {
                            Button("Retry") { store.retryIncident(inc.id) }
                                .controlSize(.mini)
                                .help("Queue incident \(inc.id) for another repair attempt via bin/ragnarok-doctor retry")
                        }
                        Button(isExp ? "Hide" : "Details") { toggle("doc-\(inc.id)") }
                            .controlSize(.mini)
                    }
                    Text(inc.message.oneLine(220))
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    if let diag = inc.diagnosis {
                        Text("Diagnosis (\(diag.decision)) — \(diag.file)\(diag.line > 0 ? ":\(diag.line)" : ""): \(diag.reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if !inc.note.isEmpty {
                        Text(inc.note).font(.caption).foregroundStyle(.secondary)
                    }
                    if isExp {
                        VStack(alignment: .leading, spacing: 4) {
                            Divider()
                            Text("Incident ID: \(inc.id) · Build: \(inc.build) · Actor: \(inc.actor) · First seen: \(inc.firstSeen)")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            if !inc.branch.isEmpty {
                                Text("Branch: \(inc.branch)" + (inc.commitID.isEmpty ? "" : " · Commit: \(inc.commitID)"))
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let rep = inc.repairSummary, !rep.isEmpty {
                                Text("Repair summary: \(rep)").font(.caption2).textSelection(.enabled)
                            }
                            if let rv = inc.reviewVerdict, !rv.isEmpty {
                                Text("Independent review (\(rv)): \(inc.reviewReason ?? "")").font(.caption2).textSelection(.enabled)
                            }
                            if !inc.history.isEmpty {
                                Text("State transitions:").font(.caption2.bold()).padding(.top, 2)
                                ForEach(inc.history.prefix(8)) { h in
                                    Text("• \(h.ts) — \(h.status): \(h.note)")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder private var editsSection: some View {
        let items = store.edits.filter {
            matchesSearch("\($0.id) \($0.who) \($0.actor) \($0.status) \($0.instruction) \($0.installedCommit) \($0.detail)")
        }
        sectionBox("Heimdall Edits & Launcher Events (\(items.count))") {
            if items.isEmpty {
                Text("No matching Heimdall edit runs.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(60)) { run in
                let isExp = expanded.contains("edit-\(run.id)")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        statusPill(run.succeeded ? run.status : "failed: \(run.failedStep.isEmpty ? run.status : run.failedStep)",
                                   color: run.succeeded ? .green : .red)
                        Text(run.actor).font(.caption.bold()).foregroundStyle(Palette.color(run.actor))
                        if !run.installedCommit.isEmpty {
                            Text(run.installedCommit).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(run.instruction.isEmpty ? run.detail.oneLine(140) : run.instruction.oneLine(140))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if let patch = run.patchPath {
                            Button("Saved patch") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: patch)])
                            }.controlSize(.mini)
                        }
                        Text(HubView.when(run.updatedAt))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if !run.diffStat.isEmpty || !run.backupNote.isEmpty || !run.detail.isEmpty {
                            Button(isExp ? "Hide" : "Details") { toggle("edit-\(run.id)") }.controlSize(.mini)
                        }
                    }
                    if !run.succeeded && !run.detail.isEmpty {
                        Text(run.detail.oneLine(220)).font(.caption2.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if isExp {
                        VStack(alignment: .leading, spacing: 4) {
                            if !run.diffStat.isEmpty {
                                Text(run.diffStat).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if !run.backupNote.isEmpty {
                                Text("Off-Mac backup: \(run.backupNote)")
                                    .font(.caption2)
                                    .foregroundStyle(run.backupOK == true ? Color.secondary : Color.orange)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(6)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            if items.count > 60 {
                Text("Showing newest 60 of \(items.count) edit records.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var healSection: some View {
        let items = store.heals.filter {
            matchesSearch("\($0.id) \($0.projectName) \($0.project) \($0.who) \($0.status) \($0.instruction) \($0.detail)")
        }
        sectionBox("Project Self-Heal Runs (\(items.count))") {
            if items.isEmpty {
                Text("No matching ragnarok-heal runs in ~/.ragnarok/ragnarok-heal.jsonl.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(50)) { run in
                let isExp = expanded.contains("heal-\(run.id)")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        statusPill(run.succeeded ? run.status : "failed: \(run.failedStep.isEmpty ? run.status : run.failedStep)",
                                   color: run.succeeded ? .green : .red)
                        Text(run.projectName).font(.caption.bold())
                        Text(run.actor).font(.caption.bold()).foregroundStyle(Palette.color(run.actor))
                        Text(run.instruction.isEmpty ? run.detail.oneLine(140) : run.instruction.oneLine(140))
                            .font(.caption).lineLimit(1)
                        Spacer()
                        if let patch = run.patchPath {
                            Button("Saved patch") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: patch)])
                            }.controlSize(.mini)
                        }
                        Text(HubView.when(run.updatedAt))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if !run.diffStat.isEmpty || !run.detail.isEmpty {
                            Button(isExp ? "Hide" : "Details") { toggle("heal-\(run.id)") }.controlSize(.mini)
                        }
                    }
                    if !run.detail.isEmpty {
                        Text(run.detail.oneLine(220))
                            .font(.caption2.monospaced())
                            .foregroundStyle(run.succeeded ? Color.secondary : Color.red)
                            .textSelection(.enabled)
                    }
                    if isExp && !run.diffStat.isEmpty {
                        Text(run.diffStat).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(6)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder private var receiptsSection: some View {
        let items = store.receipts.filter {
            matchesSearch("\($0.provider) \($0.cwd) \($0.question) \($0.verdict)")
        }
        sectionBox("Terminal & Hub Verification Receipts (\(items.count))") {
            if items.isEmpty {
                Text("No matching verification receipts in ~/.ragnarok/terminal-receipts.jsonl.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(50)) { r in
                let bad = r.verdict == "failed" || r.verdict == "mismatch"
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        statusPill(r.verdict, color: bad ? .red : (r.verdict == "verified" ? .green : .secondary))
                        Text(r.provider).font(.caption.bold()).foregroundStyle(Palette.color(r.provider))
                        Text((r.cwd as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(r.question.oneLine(120)).font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(r.changed.count) file\(r.changed.count == 1 ? "" : "s") · \(r.seconds)s")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text(HubView.when(r.time))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !r.claimsFailed.isEmpty {
                        Text(r.claimsFailed.joined(separator: "; "))
                            .font(.caption2).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(6)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    private func severityColor(_ s: String) -> Color {
        switch s {
        case "critical": return .red
        case "high": return .orange
        case "medium": return .yellow
        case "low": return .blue
        default: return .secondary
        }
    }

    private func doctorStatusColor(_ s: String) -> Color {
        switch s {
        case "applied_unverified", "installed_unverified", "tested_branch": return .green
        case "no_code_change": return .blue
        case "failed", "review_rejected", "needs_attention", "interrupted": return .red
        default: return .orange
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder private func sectionBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

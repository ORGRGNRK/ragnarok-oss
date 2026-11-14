// files-check: the app's file handling, compiled against Belt.swift,
// Remote.swift and Files.swift (not Views.swift). NO real SSH and NO AI:
// the "remote" belt is a scratch folder on this Mac, reached through a fake
// ssh (CONVEYOR_SSH) that runs the script with local bash. Run checks/files-check.sh.
import Foundation

nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { pass += 1; print("  ok   \(name)") } else { fail += 1; print("  FAIL \(name) \(detail())") }
}
@main
struct FilesCheck {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let scratch = URL(fileURLWithPath: env["SCRATCH"]!)
        let remotePath = env["REMOTE_BELT"]!
        let localBelt = URL(fileURLWithPath: env["LOCAL_BELT"]!)
        let fm = FileManager.default

        // Inputs
        let inDir = scratch.appendingPathComponent("in")
        try fm.createDirectory(at: inDir.appendingPathComponent("other"), withIntermediateDirectories: true)
        try fm.createDirectory(at: inDir.appendingPathComponent("a folder"), withIntermediateDirectories: true)
        let a = inDir.appendingPathComponent("my notes.txt"); try "hello\n".write(to: a, atomically: true, encoding: .utf8)
        let a2 = inDir.appendingPathComponent("other/my notes.txt"); try "second\n".write(to: a2, atomically: true, encoding: .utf8)
        let pdf = inDir.appendingPathComponent("report.pdf"); try Data("%PDF-1.4 fake".utf8).write(to: pdf)
        let big = inDir.appendingPathComponent("big.bin")
        fm.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big); try h.truncate(atOffset: UInt64(101 * 1024 * 1024)); try h.close()

        print("-- TaskFiles")
        check("repeat names get (2)", TaskFiles.uniqueNames([a, a2, pdf]) == ["my notes.txt", "my notes (2).txt", "report.pdf"])
        check("a folder is refused", TaskFiles.problem(with: [inDir.appendingPathComponent("a folder")])?.contains("is a folder") == true)
        check("a 101 MB file is refused, naming the limit", TaskFiles.problem(with: [big])?.contains("limit is 100 MB") == true)
        check("ordinary files pass", TaskFiles.problem(with: [a, pdf]) == nil)
        let sec = TaskFiles.sections(attachments: ["/x/attachments/id/my notes.txt"], outputs: "/x/outputs/id")
        let parsed = TaskFiles.parse("# t\n\nWant: x\n\n" + sec + "\n\n## Legs: 1\n- /not/an/attachment\n")
        check("parse reads what sections writes", parsed.attachments == ["/x/attachments/id/my notes.txt"] && parsed.outputs == "/x/outputs/id",
              "\(parsed)")
        if let legacy = env["LEGACY_TASK"], let t = try? String(contentsOfFile: legacy, encoding: .utf8) {
            let p = TaskFiles.parse(t)
            check("the older Images list still reads as an attachment", p.attachments.count == 1 && p.attachments[0].hasSuffix("/1-app2.png") && p.outputs == nil, "\(p)")
        } else { check("legacy task readable", false) }
        // The belt writes the same sections; the app must read a belt-written task.
        if let cli = env["CLI_TASK"], let t = try? String(contentsOfFile: cli, encoding: .utf8) {
            let p = TaskFiles.parse(t)
            check("parse reads a task written by conveyor add --attach", p.attachments.count == 2 && p.outputs?.contains("/outputs/") == true, "\(p)")
        } else { check("cli task readable", false) }

        print("-- local belt: the app's add goes through conveyor add --attach")
        check("this belt's conveyor-add knows --attach", BeltStore.supportsAttach(localBelt))
        let r = await BeltStore.run(root: localBelt, ["add", "From the app", "--attach", a.path, "--attach", a2.path, "-m", "Want: x"])
        check("conveyor add with the app's arguments exits 0", r.status == 0, r.output)
        let q = (try? fm.contentsOfDirectory(atPath: localBelt.appendingPathComponent("queue").path)) ?? []
        let qt = q.first { $0.contains("from-the-app") }
        let qtext = qt.flatMap { try? String(contentsOf: localBelt.appendingPathComponent("queue/\($0)"), encoding: .utf8) } ?? ""
        let qp = TaskFiles.parse(qtext)
        check("both files listed and present", qp.attachments.count == 2 && qp.attachments.allSatisfy { fm.fileExists(atPath: $0) }, "\(qp)")
        check("output folder exists", qp.outputs.map { fm.fileExists(atPath: $0) } == true)

        print("-- remote belt (fake ssh into a scratch folder)")
        let remote = RemoteBelt(host: "fake@nowhere", path: remotePath)
        check("ssh program is the fake", RemoteBelt.sshProgram.hasSuffix("fake-ssh"))
        let err = await remote.add(title: "Remote files", body: "Want: y", files: [a, a2, pdf])
        check("remote add succeeds", err == nil, err ?? "")
        let rq = (try? fm.contentsOfDirectory(atPath: remotePath + "/queue")) ?? []
        let rtext = rq.first.flatMap { try? String(contentsOfFile: remotePath + "/queue/" + $0, encoding: .utf8) } ?? ""
        let rp = TaskFiles.parse(rtext)
        check("three files listed by REMOTE path", rp.attachments.count == 3 && rp.attachments.allSatisfy { $0.hasPrefix(remotePath + "/attachments/") }, "\(rp)")
        check("uploaded bytes match (space and repeat name)",
              rp.attachments.count == 3 && fm.contentsEqual(atPath: rp.attachments[0], andPath: a.path)
              && fm.contentsEqual(atPath: rp.attachments[1], andPath: a2.path) && rp.attachments[1].hasSuffix("my notes (2).txt")
              && fm.contentsEqual(atPath: rp.attachments[2], andPath: pdf.path))
        check("remote output folder made and named", rp.outputs.map { $0.hasPrefix(remotePath + "/outputs/") && fm.fileExists(atPath: $0) } == true)
        // queue/<id>.md, same id as attachments/<id>/ and outputs/<id>/.
        let rid = rq.first.map { String($0.dropLast(3)) } ?? "?"
        check("one task file, in this belt's queue/", rq.count == 1 && rq[0].hasSuffix(".md"), "\(rq)")
        check("task file named with the attachments/outputs id",
              rp.attachments.allSatisfy { $0.hasPrefix(remotePath + "/attachments/\(rid)/") } && rp.outputs == remotePath + "/outputs/\(rid)", "\(rid) \(rp)")
        check("the belt's own conveyor-add was not used (nothing in the wrong queue)",
              ((try? fm.contentsOfDirectory(atPath: env["WRONG_QUEUE"]!)) ?? ["?"]).isEmpty)
        let rlines = rtext.components(separatedBy: "\n")
        check("header as conveyor-add writes it", rlines.count > 6 && rlines[0] == "# Remote files" && rlines[1] == ""
              && rlines[2].hasPrefix("queued: 20") && rlines[3] == "by: " + NSUserName() && rlines[4] == "" && rlines[5] == "Want: y"
              && rtext.contains("## Outputs") && rtext.hasSuffix("\"$CONVEYOR_OUTPUTS\".\n"), rtext)

        // Quotes, spaces, backticks, $ signs and backslashes reach the file unchanged.
        let tTitle = "Val's \"accounts\" $HOME `x` 100%s"
        let tBody = "Want: it's \"quoted\", `whoami` and $(date) and $PATH stay as typed\n\tC:\\path\\n 50% $1 'single'"
        let terr = await remote.add(title: tTitle, body: tBody, files: [])
        check("remote add with awkward title and body succeeds", terr == nil, terr ?? "")
        let tq = ((try? fm.contentsOfDirectory(atPath: remotePath + "/queue")) ?? []).filter { $0 != rq.first }
        let ttext = tq.first.flatMap { try? String(contentsOfFile: remotePath + "/queue/" + $0, encoding: .utf8) } ?? ""
        let tl = ttext.components(separatedBy: "\n")
        let tid = tq.first.map { String($0.dropLast(3)) } ?? "?"
        check("awkward title and body written exactly", tq.count == 1 && tl.count > 5 && tl[0] == "# " + tTitle
              && ttext.contains("\n\n" + tBody + "\n\n## Outputs\n\noutputs: \(remotePath)/outputs/\(tid)\n"), ttext)
        let all = (try? fm.contentsOfDirectory(atPath: remotePath + "/queue")) ?? []
        check("no temp files left in queue/", all.count == 2 && all.allSatisfy { !$0.hasPrefix(".") }, "\(all)")
        let dup = await remote.ssh(RemoteBelt.addScript(path: remotePath, id: rid, title: "clobber"), stdin: Data("X\n".utf8))
        check("an existing queue/<id>.md is refused, untouched",
              dup.status == 3 && (try? String(contentsOfFile: remotePath + "/queue/\(rid).md", encoding: .utf8)) == rtext
              && ((try? fm.contentsOfDirectory(atPath: remotePath + "/queue")) ?? []).count == 2, "\(dup.status)")
        let gone = await remote.ssh(RemoteBelt.addScript(path: remotePath + "/nope", id: "x", title: "x"), stdin: Data())
        check("a missing belt folder exits 9", gone.status == 9 && RemoteBelt.explain(gone, action: "Adding").contains("doesn't exist"))

        print("-- older local belt: the app writes queue/<id>.md itself")
        let old = URL(fileURLWithPath: env["OLD_LOCAL"]!)
        let werr = BeltStore.writeTask(root: old, id: "20261026-000000-t-abcd", title: tTitle, body: tBody + "\n")
        let wtext = (try? String(contentsOf: old.appendingPathComponent("queue/20261026-000000-t-abcd.md"), encoding: .utf8)) ?? ""
        let wl = wtext.components(separatedBy: "\n")
        check("local task written in the same format", werr == nil && wl[0] == "# " + tTitle && wl[2].hasPrefix("queued: 20")
              && wl[3] == "by: " + NSUserName() && wtext.hasSuffix("\n\n" + tBody + "\n")
              && (try? fm.contentsOfDirectory(atPath: old.appendingPathComponent("queue").path)) == ["20261026-000000-t-abcd.md"], wtext)
        let wdup = BeltStore.writeTask(root: old, id: "20261026-000000-t-abcd", title: "x", body: "y")
        check("local: an existing task is refused, untouched", wdup != nil
              && (try? String(contentsOf: old.appendingPathComponent("queue/20261026-000000-t-abcd.md"), encoding: .utf8)) == wtext)
        if let out = rp.outputs {
            try fm.createDirectory(atPath: out + "/sub dir", withIntermediateDirectories: true)
            try "RESULT\n".write(toFile: out + "/result.txt", atomically: true, encoding: .utf8)
            try "deep\n".write(toFile: out + "/sub dir/x.csv", atomically: true, encoding: .utf8)
            let l = await remote.listOutputs(out)
            check("outputs listed over ssh", l.files == ["result.txt", "sub dir/x.csv"], "\(l)")
            let dest = scratch.appendingPathComponent("Downloads/Conveyor/x")
            let derr = await remote.downloadOutputs(out, to: dest)
            check("download outputs copies them to the Mac", derr == nil
                  && fm.contentsEqual(atPath: dest.appendingPathComponent("result.txt").path, andPath: out + "/result.txt")
                  && fm.contentsEqual(atPath: dest.appendingPathComponent("sub dir/x.csv").path, andPath: out + "/sub dir/x.csv"), derr ?? "")
        } else { check("outputs listed", false); check("download", false) }
        check("a folder outside the belt's outputs/ is refused",
              !remote.ownsOutputs("/etc") && !remote.ownsOutputs(remotePath + "/outputs/../queue") && !remote.ownsOutputs(remotePath + "/outputs/"))
        let bad = await remote.downloadOutputs("/etc", to: scratch.appendingPathComponent("nope"))
        check("download refuses it too", bad != nil && !fm.fileExists(atPath: scratch.appendingPathComponent("nope").path))

        print("-- Check setup on a remote belt, and a folder with no conveyor program")
        func snapshot(_ dir: String) -> [String] {
            (fm.enumerator(atPath: dir)?.allObjects as? [String] ?? []).sorted().map { p in
                let a = try? fm.attributesOfItem(atPath: dir + "/" + p)
                return "\(p) \((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(a?[.size] ?? 0)"
            }
        }
        let before = snapshot(remotePath)
        let doc = await remote.doctor()
        check("remote Check setup runs over ssh, read-only report", doc.contains("(read-only)") && doc.contains("ok    queue/")
              && doc.contains("Seats for this belt are set on that computer") && !doc.contains("/bin/bash"), doc)
        check("remote Check setup changed nothing on the belt", snapshot(remotePath) == before)
        let gonedoc = await RemoteBelt(host: "fake@nowhere", path: remotePath + "/nope").doctor()
        check("remote Check setup on a missing folder says so", gonedoc.contains("doesn't exist"), gonedoc)
        let mirror = scratch.appendingPathComponent("Library/Application Support/Conveyor/remote/fake_x")
        try fm.createDirectory(at: mirror.appendingPathComponent("queue"), withIntermediateDirectories: true)
        let mr = await BeltStore.run(root: mirror, ["doctor"])
        check("running in a remote belt's local copy gives a plain message, not a bash error",
              mr.status == 127 && mr.output.contains("another computer") && !mr.output.contains("/bin/bash"), mr.output)
        let plain = scratch.appendingPathComponent("not-a-belt")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        let pr = await BeltStore.run(root: plain, ["doctor"])
        check("a folder with no conveyor program says so", pr.status == 127 && pr.output.contains("There is no conveyor program"), pr.output)
        let lp = BeltStore.launch(root: mirror, ["run"], env: [:], onOutput: { _ in }, onExit: { _ in })
        check("launch refuses a folder with no conveyor program", lp == nil)

        print("-- planning first (--plan)")
        check("this belt's conveyor-add knows --plan", BeltStore.supportsPlan(localBelt))
        check("an older belt is seen as having no planning", !BeltStore.supportsPlan(URL(fileURLWithPath: remotePath)))
        let pl = await BeltStore.run(root: localBelt, ["add", "Plan from the app", "--plan", "-m", "Want: p"])
        let inPlan = ((try? fm.contentsOfDirectory(atPath: localBelt.appendingPathComponent("plan").path)) ?? []).contains { $0.contains("plan-from-the-app") }
        let inQueue = ((try? fm.contentsOfDirectory(atPath: localBelt.appendingPathComponent("queue").path)) ?? []).contains { $0.contains("plan-from-the-app") }
        check("Plan it first puts the task in plan/, not queue/", pl.status == 0 && inPlan && !inQueue, pl.output)

        let expected = 40
        print("\nfiles-check: \(pass) passed, \(fail) failed (\(pass + fail)/\(expected) ran)")
        exit(fail == 0 && pass + fail == expected ? 0 : 1)

    }
}

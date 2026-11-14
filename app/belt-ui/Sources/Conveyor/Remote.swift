import Foundation

/// A belt on another computer, reached over SSH. The app keeps a copy of its
/// trays and newest logs in a local cache and reads that, so every view works
/// unchanged. Changes (approve, add) are made on the remote belt itself, by
/// the same rules as a local one; the cache is only ever overwritten.
struct RemoteBelt: Equatable {
    let host: String   // as ssh takes it: user@host
    let path: String

    var label: String { "\(host):\(path)" }

    var cache: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = String(label.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return base.appendingPathComponent("Conveyor/remote/\(safe)")
    }

    /// /usr/bin/ssh. CONVEYOR_SSH swaps in another program for tests only
    /// (tests/remote-files: a fake that runs the script with local bash, so
    /// no real remote is ever touched).
    static var sshProgram: String { ProcessInfo.processInfo.environment["CONVEYOR_SSH"] ?? "/usr/bin/ssh" }

    /// Single-quotes a string for the remote shell.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // One shared connection, so polling every few seconds does not open a new
    // SSH session each time. %C keeps the socket path under macOS's limit.
    private var controlPath: String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conveyor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ssh-%C").path
    }

    /// Runs `script` with the remote shell. Never prompts: a host that wants a
    /// password, or a Tailscale re-check, fails within `timeout` instead of
    /// hanging the app.
    func ssh(_ script: String, stdin: Data? = nil, timeout: Double = 20) async -> (status: Int32, out: Data, err: String) {
        let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=600",
                    host, script]
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Self.sshProgram)
                p.arguments = args
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp
                do { try p.run() } catch {
                    cont.resume(returning: (-1, Data(), "Could not start ssh: \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
                if let stdin { inp.fileHandleForWriting.write(stdin) }
                try? inp.fileHandleForWriting.close()
                var errData = Data()
                let g = DispatchGroup()
                g.enter()
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                g.wait()
                p.waitUntilExit()
                let status: Int32 = p.terminationReason == .uncaughtSignal ? 124 : p.terminationStatus
                cont.resume(returning: (status, outData, String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    static func explain(_ r: (status: Int32, out: Data, err: String), action: String) -> String {
        if r.status == 124 {
            return "\(action): no answer within 20 seconds. If Tailscale asks you to re-check, open Terminal, run ssh once, and approve it."
        }
        if r.status == 9 { return "\(action): that folder doesn't exist on the other computer." }
        let text = (String(decoding: r.out, as: UTF8.self) + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(action) failed: \(text.isEmpty ? "exit \(r.status)" : text)"
    }

    /// Is there a belt at `path`?
    func check() async -> String? {
        let r = await ssh("cd \(Self.q(path)) 2>/dev/null || exit 9; test -d queue && test -d human || { echo 'no queue/ or human/ there: not a conveyor folder'; exit 3; }")
        return r.status == 0 ? nil : Self.explain(r, action: "Connecting")
    }

    /// Trays, receipts, and the newest leg's log and stream, into the cache.
    func sync() async -> String? {
        let script = """
        cd \(Self.q(path)) 2>/dev/null || exit 9
        L=$(ls -t logs/*.log 2>/dev/null | grep -v '/notify.log$' | head -1)
        set -- queue running verify human done failed
        [ -d plan ] && set -- plan "$@"
        [ -f logs/receipts.jsonl ] && set -- "$@" logs/receipts.jsonl
        [ -n "$L" ] && set -- "$@" "$L"
        [ -n "$L" ] && [ -f "${L%.log}.jsonl" ] && set -- "$@" "${L%.log}.jsonl"
        tar -cf - "$@" 2>/dev/null
        exit 0
        """
        let r = await ssh(script)
        guard r.status == 0, !r.out.isEmpty else { return Self.explain(r, action: "Reading the belt") }
        let fm = FileManager.default
        let parent = cache.deletingLastPathComponent()
        let fresh = parent.appendingPathComponent(".incoming-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
            let tarFile = fresh.appendingPathComponent(".belt.tar")
            try r.out.write(to: tarFile)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xf", tarFile.path, "-C", fresh.path]
            try tar.run()
            tar.waitUntilExit()
            try fm.removeItem(at: tarFile)
            guard tar.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
            // Swap whole: a reader sees the old copy or the new one, never half.
            let old = parent.appendingPathComponent(".old-\(UUID().uuidString)")
            if fm.fileExists(atPath: cache.path) { try fm.moveItem(at: cache, to: old) }
            try fm.moveItem(at: fresh, to: cache)
            try? fm.removeItem(at: old)
        } catch {
            try? fm.removeItem(at: fresh)
            return "Could not unpack the belt's copy: \(error.localizedDescription)"
        }
        return nil
    }

    /// Ticks the task's `verify: HUMAN` line and moves it human/ -> queue/ on
    /// the remote belt (AGENTS.md: the person's yes, recorded).
    func approve(_ fileName: String) async -> String? {
        let script = """
        cd \(Self.q(path)) 2>/dev/null || exit 9
        f=human/\(Self.q(fileName))
        [ -f "$f" ] || { echo 'it is no longer waiting in human/'; exit 3; }
        python3 - "$f" <<'PY' || exit 4
        import sys
        p = sys.argv[1]
        lines = open(p).read().split("\\n")
        for i, l in enumerate(lines):
            if l.startswith("- [ ]") and ":: verify: HUMAN" in l:
                lines[i] = "- [x]" + l[5:]
                break
        else:
            print("this task has no step waiting for your yes")
            sys.exit(1)
        open(p, "w").write("\\n".join(lines))
        PY
        mv "$f" queue/
        """
        let r = await ssh(script)
        return r.status == 0 ? nil : Self.explain(r, action: "Approving")
    }

    // MARK: Check setup

    /// Read-only: is the belt there, are the tools it needs on that
    /// computer, which AI programs can be found, and which seats its timer
    /// uses. Starts, moves or writes nothing. Seats for a remote belt are set
    /// on that computer (its conveyor.service), not by this app.
    static func doctorScript(path: String) -> String {
        """
        P=\(q(path))
        cd "$P" 2>/dev/null || exit 9
        ok()  { printf '  ok    %s\\n' "$1"; }
        fix() { printf '  FIX   %s\\n' "$1"; }
        echo "conveyor check on $(whoami)@$(hostname 2>/dev/null || uname -n) (read-only)"
        for d in queue running verify human done failed; do [ -d "$d" ] && ok "$d/" || fix "no $d/ folder here"; done
        [ -x conveyor-run.sh ] && ok "conveyor-run.sh" || fix "no conveyor-run.sh here"
        for t in jq curl flock timeout python3; do command -v "$t" >/dev/null 2>&1 && ok "$t" || fix "$t missing"; done
        date -Is >/dev/null 2>&1 && ok "GNU date" || fix "date is not GNU date"
        echo
        echo "AI programs found for $(whoami) (the belt's timer may run as another user):"
        any=0
        for s in claude codex gemini grok; do
          if command -v "$s" >/dev/null 2>&1 || [ -x "$HOME/.grok/bin/$s" ]; then echo "  $s"; any=1; fi
        done
        [ "$any" = 1 ] || echo "  none on this user's PATH"
        echo
        echo "Seats for this belt are set on that computer, not in this app."
        u="$(systemctl cat conveyor.service 2>/dev/null || true)"
        if [ -n "$u" ] && printf '%s\\n' "$u" | grep -qxF "Environment=CONVEYOR_ROOT=$P"; then
          dr="$(printf '%s\\n' "$u" | sed -n 's/^Environment=CONVEYOR_DRIVER_SEAT=//p' | tail -1)"
          vr="$(printf '%s\\n' "$u" | sed -n 's/^Environment=CONVEYOR_VERIFIER_SEAT=//p' | tail -1)"
          us="$(printf '%s\\n' "$u" | sed -n 's/^User=//p' | tail -1)"
          echo "  its timer (conveyor.service${us:+, runs as $us}) uses:"
          echo "  does the work: ${dr:-claude (the belt default)}"
          echo "  checks the work: ${vr:-claude (the belt default)}"
        else
          echo "  (its timer's settings could not be read from here)"
        fi
        exit 0
        """
    }

    func doctor() async -> String {
        let r = await ssh(Self.doctorScript(path: path))
        guard r.status == 0 else { return Self.explain(r, action: "Checking the belt") }
        return String(decoding: r.out, as: UTF8.self)
    }

    // MARK: Files

    /// Remote shell for one upload: the file's bytes arrive on stdin.
    static func uploadScript(path: String, id: String, name: String) -> String {
        "cd \(q(path)) 2>/dev/null || exit 9; mkdir -p \(q("attachments/\(id)")) && cat > \(q("attachments/\(id)/\(name)"))"
    }

    static func outputsScript(path: String, id: String) -> String {
        "cd \(q(path)) 2>/dev/null || exit 9; mkdir -p \(q("outputs/\(id)"))"
    }

    /// Remote shell that writes the task straight into this belt's
    /// queue/<id>.md, the body arriving on stdin. Not the remote
    /// conveyor-add: a belt's copy may ignore CONVEYOR_ROOT (and write to
    /// another folder's queue) and picks its own file name, which would not
    /// match attachments/<id>/ and outputs/<id>/. The header is the one
    /// conveyor-add writes: "# title", blank, queued:, by:, blank, body.
    /// It is written to a hidden temp name in queue/ and then linked into
    /// place, so a watcher never sees half a file, and an existing
    /// queue/<id>.md is never replaced (ln refuses; exit 3).
    static func addScript(path: String, id: String, title: String) -> String {
        let file = q("queue/\(id).md"), tmp = q("queue/.\(id).md.tmp")
        return """
        cd \(q(path)) 2>/dev/null || exit 9
        [ -d queue ] || { echo 'no queue/ folder there: not a conveyor folder'; exit 3; }
        [ -e \(file) ] && { echo 'a task with this name is already in queue/'; exit 3; }
        { printf '# %s\\n\\nqueued: %s\\nby: %s\\n\\n' \(q(title)) "$(date -Is)" "${CONVEYOR_BY:-$(whoami)}" && cat; } > \(tmp) || { rm -f \(tmp); echo 'could not write the task file'; exit 4; }
        ln \(tmp) \(file) 2>/dev/null || { rm -f \(tmp); echo 'a task with this name is already in queue/'; exit 3; }
        rm -f \(tmp)
        echo "queued: $PWD/queue/\(id).md"
        """
    }

    /// Only a folder inside this belt's outputs/ may be listed or downloaded.
    func ownsOutputs(_ dir: String) -> Bool {
        dir.hasPrefix(path + "/outputs/") && !dir.contains("/../") && !dir.hasSuffix("/..")
            && dir.count > path.count + "/outputs/".count
    }

    static func listScript(dir: String) -> String {
        "cd \(q(dir)) 2>/dev/null || exit 0; find . -type f ! -name '.*' | sed 's|^\\./||' | sort | head -500"
    }

    static func downloadScript(dir: String) -> String {
        "cd \(q(dir)) 2>/dev/null || exit 9; tar -cf - ."
    }

    /// Adds a task to the remote belt. Files are uploaded to its
    /// attachments/<id>/ first, an outputs/<id>/ is made, and both are named
    /// in the task by their REMOTE paths (the seat runs there); the task
    /// itself is written to queue/<id>.md by addScript, same id. The app
    /// writes the sections itself because the remote conveyor-add may predate
    /// --attach. Uploads go over the same SSH connection as everything else
    /// (stdin into cat), so names with spaces need no second layer of quoting.
    func add(title: String, body: String, files: [URL]) async -> String? {
        let id = TaskFiles.newID(title: title)
        var listed: [String] = []
        for (src, name) in zip(files, TaskFiles.uniqueNames(files)) {
            guard let data = try? Data(contentsOf: src) else { return "Could not read \(src.lastPathComponent)." }
            let r = await ssh(Self.uploadScript(path: path, id: id, name: name), stdin: data, timeout: 300)
            if r.status != 0 { return Self.explain(r, action: "Uploading \(src.lastPathComponent)") }
            listed.append("\(path)/attachments/\(id)/\(name)")
        }
        let o = await ssh(Self.outputsScript(path: path, id: id))
        if o.status != 0 { return Self.explain(o, action: "Making the output folder") }
        let full = body + "\n\n" + TaskFiles.sections(attachments: listed, outputs: "\(path)/outputs/\(id)") + "\n"
        // queue/<id>.md: the same id as the attachments and outputs folders.
        let r = await ssh(Self.addScript(path: path, id: id, title: title), stdin: Data(full.utf8))
        return r.status == 0 ? nil : Self.explain(r, action: "Adding the task")
    }

    /// Relative paths of the files in a task's remote output folder.
    func listOutputs(_ dir: String) async -> (files: [String], error: String?) {
        guard ownsOutputs(dir) else { return ([], "That output folder is not inside this belt.") }
        let r = await ssh(Self.listScript(dir: dir))
        guard r.status == 0 else { return ([], Self.explain(r, action: "Listing the outputs")) }
        let files = String(decoding: r.out, as: UTF8.self).split(separator: "\n").map(String.init)
        return (files, nil)
    }

    /// Copies a task's remote output folder into `dest` (made fresh) on this Mac.
    func downloadOutputs(_ dir: String, to dest: URL) async -> String? {
        guard ownsOutputs(dir) else { return "That output folder is not inside this belt." }
        let r = await ssh(Self.downloadScript(dir: dir), timeout: 600)
        guard r.status == 0 else { return Self.explain(r, action: "Downloading the outputs") }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let tarFile = fm.temporaryDirectory.appendingPathComponent("conveyor-\(UUID().uuidString).tar")
            try r.out.write(to: tarFile)
            defer { try? fm.removeItem(at: tarFile) }
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xf", tarFile.path, "-C", dest.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            return "Could not unpack the outputs: \(error.localizedDescription)"
        }
        return nil
    }
}

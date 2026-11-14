import Darwin
import Foundation
import SwiftUI

/// The built-in shell: the owner's own zsh (their ~/.zshenv, ~/.zprofile, ~/.zshrc), run in a pseudo-terminal.
/// Every command is logged to ~/.ragnarok/heimdall-shell.jsonl by zsh hooks (time, command, folder, exit code),
/// which the timeline shows as the owner. The normal Terminal receipts hook is switched off inside this shell
/// (RAGNAROK_RECEIPTS_TERMINAL=0) so commands are not logged twice.
/// The Shell tab draws it with a real terminal (SwiftTerm, ShellTerminal.swift): keys, arrows, menus, vim, top all work.
/// `output` is a plain-text copy of the same stream (escape codes stripped) for the AI terminal's zsh panel and the transcript.
@MainActor
final class ShellSession: ObservableObject {
    @Published var output = ""
    @Published var running = false

    nonisolated static let log = ("~/.ragnarok/heimdall-shell.jsonl" as NSString).expandingTildeInPath
    nonisolated static let zdot = ("~/Library/Application Support/Heimdall/zdot" as NSString).expandingTildeInPath
    private var master: Int32 = -1
    private var pid: pid_t = 0
    private var source: DispatchSourceRead?
    private var pending = Data()
    private let maxChars = 300_000

    /// Raw bytes from the shell, for the terminal view. `replay` keeps the last part so a re-created view (tab switch)
    /// shows the screen again instead of a blank one.
    var rawSink: ((ArraySlice<UInt8>) -> Void)?
    private(set) var replay: [UInt8] = []
    private let replayMax = 512 * 1024
    private var cols: UInt16 = 120, rows: UInt16 = 40

    func start() {
        Self.logQueue.async { Scrub.loadValues() }
        guard !running else { return }
        do { try Self.writeZdot() } catch { AppLog.error("shell-setup", error); append("[could not set up the shell: \(error.localizedDescription)]\n"); return }
        if !FileManager.default.fileExists(atPath: Self.log) {
            FileManager.default.createFile(atPath: Self.log, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let sn = ptsname(m) else { append("[could not open a terminal]\n"); return }
        let slave = String(cString: sn)
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(m, TIOCSWINSZ, &ws)

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, slave, O_RDWR, 0)   // after setsid: becomes the controlling terminal
        posix_spawn_file_actions_adddup2(&fa, 0, 1)
        posix_spawn_file_actions_adddup2(&fa, 0, 2)
        posix_spawn_file_actions_addclose(&fa, m)
        posix_spawn_file_actions_addchdir_np(&fa, NSHomeDirectory())   // start in ~, not the app's folder
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var env = ProcessInfo.processInfo.environment
        env["ZDOTDIR"] = Self.zdot
        env["HEIMDALL_SHELL_LOG"] = Self.log
        env["RAGNAROK_RECEIPTS_TERMINAL"] = "0"
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env.removeValue(forKey: "COLUMNS"); env.removeValue(forKey: "LINES")
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["HOME"] = NSHomeDirectory()
        env.removeValue(forKey: "HEIMDALL_LAUNCHER")
        let argv = ["/bin/zsh", "-i"]
        let envp = env.map { "\($0)=\($1)" }
        var child: pid_t = 0
        let rc = withCStrings(argv) { a in withCStrings(envp) { e in posix_spawn(&child, "/bin/zsh", &fa, &attr, a, e) } }
        posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr)
        guard rc == 0 else { close(m); say("[could not start zsh: \(String(cString: strerror(rc)))]\n"); return }
        master = m; pid = child; running = true

        let src = DispatchSource.makeReadSource(fileDescriptor: m, queue: .global(qos: .userInitiated))
        src.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(m, &buf, buf.count)
            if n < 0 && (errno == EINTR || errno == EAGAIN) { return }   // report item 25: not the shell exiting
            let chunk = n > 0 ? Data(buf[0..<n]) : nil
            Task { @MainActor in
                guard let self else { return }
                if let chunk { self.consume(chunk) } else { self.ended() }
            }
        }
        src.resume(); source = src
    }

    func send(_ line: String) {
        guard running else { return }
        write(line + "\n")
    }

    func interrupt() { write("\u{03}") }

    /// Keystrokes from the terminal view, exactly as typed (arrows, Ctrl keys, pastes).
    func sendRaw(_ data: ArraySlice<UInt8>) {
        guard master >= 0 else { return }
        _ = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, data.count) }
    }

    /// The terminal view's size in characters; the shell and whatever runs in it get SIGWINCH and redraw.
    func resize(cols c: Int, rows r: Int) {
        guard c > 0, r > 0 else { return }
        cols = UInt16(min(c, 1000)); rows = UInt16(min(r, 1000))
        guard master >= 0 else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &ws)
    }

    func restart() {
        stop(); say("\n[shell restarted]\n"); start()
    }

    /// A note from Ragnarok itself (not the shell), shown in both the terminal and the plain-text copy.
    private func say(_ t: String) {
        append(t)
        feedRaw(Array(t.replacingOccurrences(of: "\n", with: "\r\n").utf8)[...])
    }

    private func feedRaw(_ b: ArraySlice<UInt8>) {
        replay.append(contentsOf: b)
        if replay.count > replayMax + replayMax / 4 {
            var cut = replay.count - replayMax
            if let nl = replay[cut...].firstIndex(of: 0x0A) { cut = nl + 1 }   // start the kept part on a fresh line
            replay.removeFirst(cut)
        }
        rawSink?(b)
    }

    func stop() {
        source?.cancel(); source = nil
        if pid > 0 {   // report item 25: reap the shell so it doesn't linger as a zombie
            let p = pid; kill(p, SIGHUP)
            DispatchQueue.global().async {
                var s: Int32 = 0
                for _ in 0..<20 { if waitpid(p, &s, WNOHANG) != 0 { return }; usleep(100_000) }
                kill(p, SIGKILL); waitpid(p, &s, 0)
            }
        }
        if master >= 0 { close(master) }
        master = -1; pid = 0; running = false
    }

    private func write(_ s: String) {
        guard master >= 0 else { return }
        let d = Array(s.utf8)
        _ = d.withUnsafeBytes { Darwin.write(master, $0.baseAddress, d.count) }
    }

    private func ended() {
        guard running else { return }
        stop(); say("\n[shell exited — press Restart shell]\n")
    }

    private func consume(_ chunk: Data) {
        feedRaw([UInt8](chunk)[...])
        pending.append(chunk)
        // keep an incomplete UTF-8 character for the next read
        let bytes = [UInt8](pending)
        var cut = bytes.count
        for back in 1...min(3, bytes.count) {
            let b = bytes[bytes.count - back]
            if b & 0xC0 == 0x80 { continue }            // continuation byte: keep looking for the lead byte
            if b >= 0xC0 {
                let need = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : 2)
                if back < need { cut = bytes.count - back }
            }
            break
        }
        let (text, held) = Self.holdIncompleteEscape(escPending + String(decoding: bytes[0..<cut], as: UTF8.self))
        pending = Data(bytes[cut...]); escPending = held   // K3: a color code split across reads is finished next time
        let cleaned = Self.clean(text, keepCR: true)
        append(cleaned)
        Self.logQueue.async { Self.transcribe(cleaned) }   // off the UI: scrubbing may wait for the secret list to load
    }

    /// Everything the shell prints also goes to ~/.ragnarok/heimdall-shell-output.log (0600), so an AI can read what went
    /// wrong without the owner copying it. Scrub.clean (local secret scrubber) runs first; the file rotates at ~1 MB (one old copy).
    /// Typed passwords/PINs aren't in it: programs turn echo off for those, so the terminal never prints them.
    nonisolated static let transcript = ("~/.ragnarok/heimdall-shell-output.log" as NSString).expandingTildeInPath

    nonisolated static let logQueue = DispatchQueue(label: "heimdall.shell.transcript")
    nonisolated static func redact(_ s: String) -> String { Scrub.clean(s) }

    nonisolated static func transcribe(_ text: String) {
        guard !text.isEmpty else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: transcript)[.size] as? Int), size > 1_000_000 {
            try? fm.removeItem(atPath: transcript + ".1"); try? fm.moveItem(atPath: transcript, toPath: transcript + ".1")
        }
        let data = Data(redact(text).utf8)
        appendLine(transcript, data)
    }

    // K4 (break-test): tabs used to rescan the whole output per tab (35 s for 20,000 lines). Now the column and length
    // are tracked as we go, text is built in a local buffer, and trimming happens in big chunks.
    private var column = 0
    private var outLen = 0           // characters in output
    private var escPending = ""
    private var crPending = false

    func clear() { output = ""; outLen = 0; column = 0 }

    private func append(_ t: String) {
        var add = ""; add.reserveCapacity(t.utf8.count + 16)
        for ch in t {
            if crPending && ch != "\r" {
                crPending = false
                if ch != "\n" {   // back to the start of the line: drop it, the new text replaces it
                    if let nl = add.lastIndex(of: "\n") { add = String(add[...nl]) } else {
                        add = ""
                        if let nl = output.lastIndex(of: "\n") { output = String(output[...nl]) } else { output = "" }
                        outLen = output.count
                    }
                    column = 0
                }
            }
            switch ch {
            case "\r":
                crPending = true
            case "\u{08}":
                if !add.isEmpty { add.removeLast() } else if !output.isEmpty { output.removeLast(); outLen -= 1 }
                column = max(0, column - 1)
            case "\t":
                let n = 8 - column % 8; add.append(String(repeating: " ", count: n)); column += n
            case "\n":
                add.append(ch); column = 0
            default:
                add.append(ch); column += 1
            }
        }
        if add.isEmpty { return }
        output.append(add); outLen += add.count
        if outLen > maxChars + maxChars / 4 { output = String(output.suffix(maxChars)); outLen = maxChars }
    }

    /// Splits off a trailing escape sequence that isn't finished yet (it continues in the next read).
    nonisolated static func holdIncompleteEscape(_ s: String) -> (String, String) {
        guard let esc = s.lastIndex(of: "\u{1B}") else { return (s, "") }
        let tail = s[esc...]
        if tail.count > 4096 { return (s, "") }              // not a real sequence; don't hold forever
        let chars = Array(tail.unicodeScalars)
        var complete = false
        if chars.count >= 2 {
            switch chars[1] {
            case "[": complete = chars.dropFirst(2).contains { (0x40...0x7E).contains($0.value) }
            case "]": complete = tail.contains("\u{07}") || tail.contains("\u{1B}\\")
            default: complete = true
            }
        }
        return complete ? (s, "") : (String(s[..<esc]), String(tail))
    }

    /// Strip terminal control sequences (colors, cursor moves, window titles); keep text and newlines.
    nonisolated static func clean(_ s: String, keepCR: Bool = false) -> String {
        var t = s.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{1B}[()*+][0-9A-Za-z]", with: "", options: .regularExpression)   // charset select
        t = t.replacingOccurrences(of: "\u{1B}[78=>@-Z\\\\-_]", with: "", options: .regularExpression)      // incl. save/restore cursor
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        if !keepCR { t = t.replacingOccurrences(of: "\r", with: "") }   // the shell keeps a lone \r: append() treats it as "back to line start"
        return t.replacingOccurrences(of: "\u{07}", with: "")
    }

    /// zsh startup files for this shell: load the owner's own files, then add the logging hooks.
    nonisolated static func writeZdot() throws {
        try FileManager.default.createDirectory(atPath: zdot, withIntermediateDirectories: true)
        let files: [String: String] = [
            ".zshenv": "[[ -r $HOME/.zshenv ]] && source $HOME/.zshenv\n",
            ".zprofile": "[[ -r $HOME/.zprofile ]] && source $HOME/.zprofile\n",
            ".zshrc": #"""
            [[ -r $HOME/.zshrc ]] && source $HOME/.zshrc
            # Heimdall shell: a real terminal now (SwiftTerm), so line editing, arrows and your own prompt stay on.
            # Adds a log line per command and ensures heimdall-debug is in PATH.
            typeset -U path
            path=("$HOME/.local/bin" "$HOME/Developer/ragnarok/app/heimdall/bin" "$HOME/Developer/heimdall/bin" $path)
            export PATH
            zmodload zsh/datetime
            _hs_esc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//[[:cntrl:]]/}; print -rn -- "$s"; }
            # report item 21: secrets in commands are masked before logging; a command starting with a space isn't logged
            _hs_mask() {
              setopt localoptions extendedglob
              local s=$1
              s=${s//(#ib)([a-z0-9_]#(key|token|secret|password|passwd|pass|auth|credential|cookie)[a-z0-9_]#=)(\"[^\"]#\"|\'[^\']#\'|[^[:space:]\&]#)/${match[1]}***}
              s=${s//(#ib)(bearer[[:space:]]##)[^[:space:]\"\']##/${match[1]}***}
              s=${s//(#ib)((-|--)(password|passwd|token|secret|api-key|apikey|key|pass|auth)(=|[[:space:]]##))[^[:space:]-][^[:space:]]#/${match[1]}***}
              s=${s//(#b)(sk-|sk_live_|ghp_|gho_|ghs_|github_pat_|xox[baprs]-|AKIA|AGE-SECRET-KEY-|AGE-PLUGIN-|glpat-|hf_)[A-Za-z0-9_-]##/${match[1]}***}
              print -rn -- "$s"
            }
            _hs_pre() { if [[ $1 == ' '* ]]; then typeset -g _HS_CMD=; else typeset -g _HS_CMD=$(_hs_mask "$1"); fi }
            _hs_post() {
              local e=$?
              [[ -z $_HS_CMD ]] && return 0
              local ts; TZ=UTC strftime -s ts '%Y-%m-%dT%H:%M:%SZ' $EPOCHSECONDS
              print -r -- "{\"ts\":\"$ts\",\"cmd\":\"$(_hs_esc $_HS_CMD)\",\"cwd\":\"$(_hs_esc $PWD)\",\"exit\":$e,\"src\":\"heimdall-shell\"}" >> $HEIMDALL_SHELL_LOG
              _HS_CMD=
              return 0
            }
            typeset -ga preexec_functions precmd_functions
            preexec_functions+=(_hs_pre); precmd_functions+=(_hs_post)

            """#,
        ]
        for (name, body) in files {
            try body.write(toFile: zdot + "/" + name, atomically: true, encoding: .utf8)
        }
    }
}

/// Pass an array of Swift strings as a NULL-terminated C string array.
private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var ptrs = strings.map { strdup($0) }
    ptrs.append(nil)
    defer { ptrs.forEach { free($0) } }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}

struct ShellView: View {
    @EnvironmentObject var shell: ShellSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(shell.running ? .green : .secondary).frame(width: 8, height: 8)
                Text(shell.running ? "Your zsh, logged to ~/.ragnarok/heimdall-shell.jsonl" : "Shell not running")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Debug last error") { shell.send("heimdall-debug last") }
                    .disabled(!shell.running)
                    .help("Analyze last failed shell command with AI pipeline debugging")
                Button("Ctrl-C") { shell.interrupt() }.disabled(!shell.running).help("Stop the running command")
                Button("Restart shell") { shell.restart() }
            }
            .padding(8)
            Divider()
            // a real terminal: click in it and type; arrows, Tab, Ctrl keys, menus, vim/top/less all work
            ShellTerminal(shell: shell)
        }
        .onAppear { shell.start() }
    }
}

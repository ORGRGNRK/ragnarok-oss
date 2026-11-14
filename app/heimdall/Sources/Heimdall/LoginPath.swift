import Foundation

/// The upstream fix for "can't find claude / node / gh" (11-02): Ragnarok is started by launchd (Dock, Launcher), which
/// gives it only PATH=/usr/bin:/bin:/usr/sbin:/sbin. The owner's real PATH is built by their zsh startup files (~/.zprofile:
/// node, ~/.local/bin; ~/.zshrc: .grok/bin, LM Studio). So at launch Ragnarok asks their own login shell for its PATH once
/// and puts it on its own process. Everything it starts (AI terminal, Hub, edits, agents, Belt, LocalAI, bin/ scripts)
/// inherits it, and no feature keeps its own folder list.
enum LoginPath {
    nonisolated(unsafe) private(set) static var source = "not asked yet"
    private static let marker = "__RAGNAROK_LOGIN_PATH__"

    /// Ask once, at startup. Never fails the app: if the shell can't be asked, PATH is left as it was (and `source` says why).
    static func apply() {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        guard let login = ask() else { return }
        let merged = merge(login, current)
        setenv("PATH", merged, 1)
    }

    /// Login + interactive, so both ~/.zprofile and ~/.zshrc run, exactly as in Terminal. The PATH is printed after a
    /// marker so anything their startup files print can't be mistaken for it.
    static func ask(timeout: TimeInterval = 6) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        var env = ProcessInfo.processInfo.environment
        env["RAGNAROK_RECEIPTS_TERMINAL"] = "0"     // not a command the owner typed: keep it out of the Terminal receipts
        env.removeValue(forKey: "HEIMDALL_LAUNCHER")
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { source = "could not start \(shell): \(error.localizedDescription)"; return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); source = "\(shell) took longer than \(Int(timeout)) s"; return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else {
            source = "\(shell) printed no PATH"; return nil
        }
        let path = String(line.dropFirst(marker.count))
        guard !path.isEmpty else { source = "\(shell) printed an empty PATH"; return nil }
        source = "\(shell) -l -i"
        return path
    }

    /// The shell's order first, then anything only the current PATH had; no duplicates, no empty entries.
    static func merge(_ first: String, _ second: String) -> String {
        var seen = Set<String>(), out: [String] = []
        for d in (first + ":" + second).split(separator: ":").map(String.init) where !d.isEmpty && seen.insert(d).inserted {
            out.append(d)
        }
        return out.joined(separator: ":")
    }

    /// Where `name` is on the (fixed) PATH.
    static func which(_ name: String) -> String? {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

import AppKit
import Foundation
import LocalAuthentication

/// The only ways in: a FIDO2 touch on the YubiKey (uTrust spare used automatically when the YubiKey
/// isn't plugged in), or Touch ID backed by the Secure Enclave. No password fallback.
/// Locks again when the screen locks or the Mac sleeps. Every attempt is logged.
@MainActor
final class Gate: ObservableObject {
    static let shared = Gate()
    private(set) var authenticationGeneration = UUID()
    private var context: LAContext?
    private(set) var automaticallyAuthenticate = true
    @Published var unlocked = false
    @Published var busy = false
    @Published var message = "Locked"

    nonisolated static let fidoScript = AppPaths.fidoScript
    nonisolated static let accessLog = ("~/.ragnarok/heimdall-access.jsonl" as NSString).expandingTildeInPath

    private let audit: (String, Bool, String) -> Void

    init(observeSystem: Bool = true, audit: @escaping (String, Bool, String) -> Void = { Gate.log(method: $0, ok: $1, detail: $2) }) {
        self.audit = audit
        guard observeSystem else { return }
        let lock: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.lock("screen locked or Mac slept") } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lock)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lock)
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock)
    }

    func lock(_ why: String) {
        authenticationGeneration = UUID()
        context?.invalidate(); context = nil
        busy = false
        automaticallyAuthenticate = false
        let wasUnlocked = unlocked
        unlocked = false; message = "Locked (\(why))"
        audit("lock", true, why + (wasUnlocked ? "" : " (already locked)"))
    }

    /// A lock invalidates every in-flight hardware/biometric result, even while already locked.
    func acceptsAuthentication(_ generation: UUID) -> Bool {
        authenticationGeneration == generation
    }

    /// Hardware key if one is plugged in, otherwise Touch ID.
    func auto() {
        guard automaticallyAuthenticate else { return }
        let generation = authenticationGeneration
        Task.detached {
            let keyPresent = Self.fidoKeyPresent()
            await MainActor.run {
                guard self.acceptsAuthentication(generation) else { return }
                keyPresent ? self.key() : self.touchID()
            }
        }
    }

    func key() {
        guard !busy else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.fidoScript) else {
            message = "Key check script missing: \(Self.fidoScript)"; return
        }
        let generation = authenticationGeneration
        busy = true; message = "Touch your YubiKey (or the uTrust spare)…"
        Task.detached {
            let (code, out, err) = Self.run(Self.fidoScript, [])
            let ok = code == 0 && out.contains("AUTH_KEY_OK")
            let label = out.split(separator: ":").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            await MainActor.run {
                guard self.acceptsAuthentication(generation) else { return }
                self.busy = false
                if ok { self.unlocked = true; self.message = "Unlocked with \(label)" }
                else if code == 3 { self.message = "No enrolled key plugged in. Plug in the YubiKey or uTrust, or use Touch ID." }
                else { self.message = "Key check failed: \(err.oneLine(120))" }
                Self.log(method: "fido2:\(label.isEmpty ? "none" : label)", ok: ok, detail: ok ? "" : err.oneLine(200))
            }
        }
    }

    func touchID() {
        guard !busy else { return }
        let generation = authenticationGeneration
        let ctx = LAContext()
        context = ctx
        var e: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e) else {
            message = "Touch ID not available: \(e?.localizedDescription ?? "unknown")"; return
        }
        busy = true; message = "Touch ID…"
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "unlock Ragnarok") { ok, err in
            Task { @MainActor in
                guard self.acceptsAuthentication(generation) else { return }
                self.busy = false
                if ok { self.unlocked = true; self.message = "Unlocked with Touch ID (Secure Enclave)" }
                else { self.message = "Touch ID failed: \(err?.localizedDescription ?? "")" }
                Self.log(method: "touchid", ok: ok, detail: err?.localizedDescription ?? "")
            }
        }
    }

    nonisolated static func fidoKeyPresent() -> Bool {
        // report item 28: fido2-token wherever their shell finds it (Homebrew etc.); LoginPath put their PATH on the app
        guard let exe = LoginPath.which("fido2-token") else { return false }
        let (_, out, _) = run(exe, ["-L"])
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        // report item 27: stderr is read at the same time as stdout, so a big stderr can't deadlock it
        let errBuf = RunBuffer(), errDone = DispatchSemaphore(value: 0)
        e.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; errDone.signal() } else { errBuf.add(d) }
        }
        do { try p.run() } catch { e.fileHandleForReading.readabilityHandler = nil; return (-1, "", error.localizedDescription) }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        _ = errDone.wait(timeout: .now() + 5)
        let ed = errBuf.data
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self))
    }

    nonisolated static func log(method: String, ok: Bool, detail: String) {
        let rec: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "method": method, "ok": ok, "detail": detail]
        guard let d = try? JSONSerialization.data(withJSONObject: rec), var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        appendLine(accessLog, Data(line.utf8))
    }
}

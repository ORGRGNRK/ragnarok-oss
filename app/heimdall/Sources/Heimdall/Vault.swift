import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI
import WebKit

/// The owner's Vaultwarden (server set in `bw config server`) inside Ragnarok, through the official Bitwarden CLI (`bw`, Homebrew).
/// Owner, 2026-11-13: "im trying to make it so i dont have to type my passwords where i dont need to".
///
/// The master password is typed ONCE. It is sealed with a Secure Enclave key that only opens with Touch ID
/// (CryptoKit, .biometryCurrentSet: adding a new fingerprint invalidates it), so the file on disk is useless without
/// this Mac's chip and the owner's finger. After Touch ID, `bw unlock` gives a session key that lives in memory only and is
/// forgotten after `idleLock` seconds without use, or when Ragnarok quits. Nothing here prints or logs a secret.
/// `bw` itself must be logged in once from Terminal (`bw login --apikey`); this code never logs in.
enum Vault {
    static let bw = "/opt/homebrew/bin/bw"
    static let dir = NSHomeDirectory() + "/.ragnarok/vault"
    static let keyRef = dir + "/se-key.ref"          // Secure Enclave key (an encrypted reference, only this Mac's chip can use it)
    static let sealed = dir + "/master.sealed"       // JSON: ephemeral public key + AES-GCM box of the master password
    static let idleLock: TimeInterval = 600

    struct Login: Identifiable, Hashable {
        let id: String, name: String, username: String, password: String
        var totp: String = ""          // the 2FA secret (otpauth:// URI, base32, or steam://); a code is made from it at fill time
    }

    // MARK: pure helpers (self-tested)

    /// `bw list items` JSON → logins that have a password or a 2FA secret. Order kept (bw sorts by match).
    nonisolated static func parseItems(_ data: Data) -> [Login] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { it in
            guard let login = it["login"] as? [String: Any] else { return nil }
            let pw = login["password"] as? String ?? "", totp = login["totp"] as? String ?? ""
            guard !pw.isEmpty || !totp.isEmpty else { return nil }
            return Login(id: it["id"] as? String ?? UUID().uuidString, name: it["name"] as? String ?? "(untitled)",
                         username: login["username"] as? String ?? "", password: pw, totp: totp)
        }
    }

    // MARK: 2FA codes (TOTP, RFC 6238), made on this Mac from the vault's secret

    struct TOTPSpec { let key: [UInt8]; let digits: Int; let period: Int; let algorithm: String; let steam: Bool }

    /// Reads what Bitwarden stores in the TOTP box: an otpauth://totp/… URI, a bare base32 secret, or steam://SECRET.
    nonisolated static func totpSpec(_ raw: String) -> TOTPSpec? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("otpauth://") {
            guard let c = URLComponents(string: t), c.host?.lowercased() == "totp" else { return nil }   // hotp (counter) isn't supported
            let q = Dictionary((c.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            guard let key = base32(q["secret"] ?? "") else { return nil }
            let digits = Int(q["digits"] ?? "") ?? 6, period = Int(q["period"] ?? "") ?? 30
            let algo = (q["algorithm"] ?? "SHA1").uppercased()
            guard (6...10).contains(digits), period > 0, ["SHA1", "SHA256", "SHA512"].contains(algo) else { return nil }
            return TOTPSpec(key: key, digits: digits, period: period, algorithm: algo, steam: false)
        }
        if t.lowercased().hasPrefix("steam://") {
            guard let key = base32(String(t.dropFirst(8))) else { return nil }
            return TOTPSpec(key: key, digits: 5, period: 30, algorithm: "SHA1", steam: true)
        }
        guard let key = base32(t) else { return nil }
        return TOTPSpec(key: key, digits: 6, period: 30, algorithm: "SHA1", steam: false)
    }

    nonisolated static func base32(_ s: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let chars = s.uppercased().filter { $0 != " " && $0 != "-" && $0 != "=" }
        guard !chars.isEmpty else { return nil }
        var out: [UInt8] = [], buf = 0, bits = 0
        for ch in chars {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            buf = (buf << 5) | v; bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((buf >> bits) & 0xff)) }
        }
        return out.isEmpty ? nil : out
    }

    /// The code for `date`, and how many seconds it stays good. nil if the secret can't be read.
    nonisolated static func totpCode(_ raw: String, at date: Date = Date()) -> (code: String, secondsLeft: Int)? {
        guard !raw.isEmpty, let spec = totpSpec(raw) else { return nil }
        let now = Int(date.timeIntervalSince1970)
        var counter = UInt64(now / spec.period).bigEndian
        let msg = withUnsafeBytes(of: &counter) { Data($0) }, key = SymmetricKey(data: spec.key)
        let h: [UInt8]
        switch spec.algorithm {
        case "SHA256": h = Array(HMAC<SHA256>.authenticationCode(for: msg, using: key))
        case "SHA512": h = Array(HMAC<SHA512>.authenticationCode(for: msg, using: key))
        default: h = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key))
        }
        let o = Int(h[h.count - 1] & 0x0f)
        let bin = (Int(h[o] & 0x7f) << 24) | (Int(h[o + 1]) << 16) | (Int(h[o + 2]) << 8) | Int(h[o + 3])
        let left = spec.period - now % spec.period
        if spec.steam {
            let a = Array("23456789BCDFGHJKMNPQRTVWXY"); var v = bin, code = ""
            for _ in 0..<5 { code.append(a[v % a.count]); v /= a.count }
            return (code, left)
        }
        var mod = 1; for _ in 0..<spec.digits { mod *= 10 }
        let n = String(bin % mod)
        return (String(repeating: "0", count: spec.digits - n.count) + n, left)
    }

    /// Only fill pages that are safe to type a password into: https, or plain http to localhost / a private address.
    nonisolated static func fillable(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 100 && (64...127).contains(p[1]))
    }

    /// The page script that fills the first visible password field and the text/email field before it, and a 2FA box
    /// (one box, or one box per digit) when `code` is given. On a 2FA-only page the username is left alone.
    /// Values go in as JSON string literals, so a quote or backslash in a password can't break out of the script.
    nonisolated static func fillScript(username: String, password: String, code: String = "") -> String {
        func lit(_ s: String) -> String {
            let d = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            return String(decoding: d, as: UTF8.self)       // ["…"], indexed [0] in the script
        }
        return """
        (function(u, p, c){
          function vis(e){ var r=e.getBoundingClientRect(); return r.width>0 && r.height>0 && !e.disabled && !e.readOnly; }
          function set(e, v){
            var d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
            e.focus(); d.set.call(e, v);
            e.dispatchEvent(new Event('input', {bubbles:true})); e.dispatchEvent(new Event('change', {bubbles:true}));
          }
          var inputs = Array.prototype.slice.call(document.querySelectorAll('input')).filter(vis);
          var pi = inputs.findIndex(function(e){ return e.type === 'password'; });
          function words(e){ return (e.name+' '+e.id+' '+(e.placeholder||'')+' '+(e.getAttribute('aria-label')||'')+' '+(e.autocomplete||'')).toLowerCase(); }
          function otpLike(e){
            if (['text','tel','number',''].indexOf(e.type) < 0) return false;
            if ((e.autocomplete||'') === 'one-time-code') return true;
            var w = words(e);
            if (/zip|postal|promo|coupon|gift|country|area|referr|invite/.test(w)) return false;
            return /otp|totp|2fa|mfa|one.?time|verif|auth.*code|security.?code|passcode|\\btoken\\b|\\bcode\\b|pin\\b/.test(w);
          }
          var otp = null, boxes = [];
          if (c) {
            otp = inputs.find(otpLike) || null;
            var ones = inputs.filter(function(e){ return e.maxLength === 1 && ['text','tel','number',''].indexOf(e.type) >= 0; });
            if (ones.length >= c.length && (!otp || otp.maxLength === 1)) { boxes = ones.slice(0, c.length); otp = null; }
          }
          var user = null;
          if (pi >= 0 || (!otp && !boxes.length)) {
            var cands = (pi >= 0 ? inputs.slice(0, pi) : inputs).filter(function(e){
              if (e === otp || boxes.indexOf(e) >= 0) return false;
              return ['text','email','tel',''].indexOf(e.type) >= 0 || /user|mail|login/i.test(e.name + e.id + (e.autocomplete||''));
            });
            if (cands.length) user = cands[cands.length - 1];
          }
          if (user && u) set(user, u);
          if (pi >= 0 && p) set(inputs[pi], p);
          if (otp) set(otp, c);
          boxes.forEach(function(e, i){ set(e, c[i]); });
          var did = (user ? 'user ' : '') + (pi >= 0 ? 'password' : 'no-password-field');
          return did + ((otp || boxes.length) ? ' code' : '');
        })(\(lit(username))[0], \(lit(password))[0], \(lit(code))[0]);
        """
    }

    // MARK: sealing the master password with the Secure Enclave

    enum VaultError: LocalizedError {
        case noEnclave, notSetUp, cancelled, broken(String)
        var errorDescription: String? {
            switch self {
            case .noEnclave: "This Mac has no Secure Enclave / Touch ID available."
            case .notSetUp: "The vault isn't set up in Ragnarok yet."
            case .cancelled: "Touch ID was cancelled."
            case .broken(let s): s
            }
        }
    }

    nonisolated static func isSetUp() -> Bool {
        FileManager.default.fileExists(atPath: keyRef) && FileManager.default.fileExists(atPath: sealed)
    }

    nonisolated static func seal(_ master: String) throws {
        guard SecureEnclave.isAvailable else { throw VaultError.noEnclave }
        var err: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                       [.privateKeyUsage, .biometryCurrentSet], &err) else {
            throw VaultError.broken("couldn't make the Touch ID rule")
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
        let eph = P256.KeyAgreement.PrivateKey()
        let box = try AES.GCM.seal(Data(master.utf8), using: symmetric(try eph.sharedSecretFromKeyAgreement(with: key.publicKey)))
        guard let combined = box.combined else { throw VaultError.broken("couldn't seal") }
        let doc: [String: String] = ["v": "1", "eph": eph.publicKey.rawRepresentation.base64EncodedString(),
                                     "box": combined.base64EncodedString()]
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writePrivate(key.dataRepresentation, keyRef)
        try writePrivate(try JSONSerialization.data(withJSONObject: doc), sealed)
    }

    /// Touch ID → the master password. The prompt text says why.
    nonisolated static func unseal(reason: String) throws -> String {
        guard isSetUp() else { throw VaultError.notSetUp }
        let ctx = LAContext(); ctx.localizedReason = reason; ctx.localizedFallbackTitle = ""
        do {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: Data(contentsOf: URL(fileURLWithPath: keyRef)),
                                                                     authenticationContext: ctx)
            guard let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sealed))) as? [String: String],
                  let ephD = doc["eph"].flatMap({ Data(base64Encoded: $0) }), let boxD = doc["box"].flatMap({ Data(base64Encoded: $0) })
            else { throw VaultError.broken("the sealed file is damaged; set the vault up again") }
            let eph = try P256.KeyAgreement.PublicKey(rawRepresentation: ephD)
            let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: boxD), using: symmetric(try key.sharedSecretFromKeyAgreement(with: eph)))
            return String(decoding: plain, as: UTF8.self)
        } catch let e as VaultError { throw e
        } catch {
            let ns = error as NSError
            if ns.domain == LAErrorDomain || ns.code == -128 || "\(error)".contains("userCancel") { throw VaultError.cancelled }
            throw VaultError.broken("Touch ID couldn't open the vault key (\(ns.code)). If you added a fingerprint, set the vault up again.")
        }
    }

    nonisolated static func forget() {
        try? FileManager.default.removeItem(atPath: keyRef); try? FileManager.default.removeItem(atPath: sealed)
    }

    nonisolated private static func symmetric(_ s: SharedSecret) -> SymmetricKey {
        s.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("ragnarok-vault-v1".utf8), sharedInfo: Data(), outputByteCount: 32)
    }

    nonisolated private static func writePrivate(_ data: Data, _ path: String) throws {
        let tmp = path + ".tmp"
        try? FileManager.default.removeItem(atPath: tmp)
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp, path) == 0 else { throw VaultError.broken("couldn't write \(path)") }
    }

    // MARK: running bw

    /// Runs bw with the given args. Secrets go in through the environment (never argv, which `ps` can show).
    nonisolated static func run(_ args: [String], env extra: [String: String] = [:]) -> (code: Int32, out: Data, err: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: bw); p.arguments = args
        var env = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "BW_NOINTERACTION": "true"]
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data(), "bw isn't installed (brew install bitwarden-cli)") }
        let out = o.fileHandleForReading.readDataToEndOfFile(), err = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, out, String(decoding: err, as: UTF8.self).oneLine(200))
    }

    /// "unauthenticated" | "locked" | "unlocked" | "missing"
    nonisolated static func status() -> String {
        guard FileManager.default.isExecutableFile(atPath: bw) else { return "missing" }
        let r = run(["status"])
        let d = (try? JSONSerialization.jsonObject(with: r.out)) as? [String: Any]
        return d?["status"] as? String ?? "unauthenticated"
    }
}

@MainActor
final class VaultModel: ObservableObject {
    static let shared = VaultModel()
    @Published var busy = false
    @Published var note = ""
    @Published var choices: [Vault.Login] = []
    @Published var askMaster = false              // first-time setup sheet
    private var session: String?                  // bw session key: memory only
    private var lastUse = Date.distantPast
    private var pendingURL: URL?
    private var pendingFill: ((Vault.Login) -> Void)?

    private func sessionAlive() -> Bool {
        if let _ = session, Date().timeIntervalSince(lastUse) < Vault.idleLock { return true }
        session = nil; return false
    }

    /// Lock now: forget the session key.
    func lock() { session = nil; choices = []; note = "Vault locked." }

    /// Find logins for url and fill one. One match fills at once; several open a picker; none says so.
    func fill(for url: URL?, apply: @escaping (Vault.Login) -> Void) {
        guard Vault.fillable(url), let url else { note = "Only https pages (or your own network) are filled."; return }
        pendingURL = url; pendingFill = apply
        if !Vault.isSetUp() { askMaster = true; return }
        busy = true; note = "Looking in your vault…"
        let alive = sessionAlive(), current = session
        Task.detached {
            do {
                let s: String
                if alive, let current { s = current } else { s = try Self.unlock(master: Vault.unseal(reason: "fill a login from your vault")) }
                let r = Vault.run(["list", "items", "--url", url.absoluteString], env: ["BW_SESSION": s])
                let found = r.code == 0 ? Vault.parseItems(r.out) : []
                await MainActor.run {
                    self.session = s; self.lastUse = Date(); self.busy = false
                    if r.code != 0 { self.note = "The vault didn't answer: \(r.err)"; return }
                    switch found.count {
                    case 0: self.note = "No saved login for \(url.host ?? "this site")."
                    case 1: self.note = "Filled \(found[0].name)."; apply(found[0])
                    default: self.note = ""; self.choices = found
                    }
                }
            } catch {
                await MainActor.run { self.busy = false; self.note = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            }
        }
    }

    func pick(_ l: Vault.Login) { choices = []; note = "Filled \(l.name)."; lastUse = Date(); pendingFill?(l) }

    /// First-time setup: check the master password really unlocks the vault, then seal it with Touch ID.
    func setUp(master: String) {
        busy = true; note = "Checking the password with your vault…"
        Task.detached {
            do {
                let s = try Self.unlock(master: master)
                try Vault.seal(master)
                await MainActor.run {
                    self.session = s; self.lastUse = Date(); self.busy = false; self.askMaster = false
                    self.note = "Vault set up. From now on, Fill asks for Touch ID."
                    if let u = self.pendingURL, let f = self.pendingFill { self.fill(for: u, apply: f) }
                }
            } catch {
                await MainActor.run { self.busy = false; self.note = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            }
        }
    }

    nonisolated private static func unlock(master: String) throws -> String {
        switch Vault.status() {
        case "missing": throw Vault.VaultError.broken("Bitwarden CLI isn't installed (brew install bitwarden-cli).")
        case "unauthenticated": throw Vault.VaultError.broken("Log the vault in once from Terminal: bw login --apikey")
        default: break
        }
        let r = Vault.run(["unlock", "--passwordenv", "RAGNAROK_BW_PW", "--raw"], env: ["RAGNAROK_BW_PW": master])
        let s = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.code == 0, !s.isEmpty else { throw Vault.VaultError.broken("That master password didn't unlock the vault.") }
        return s
    }
}

/// Typed once: the master password, then sealed behind Touch ID.
struct VaultSetupSheet: View {
    @ObservedObject var v: VaultModel = .shared
    @State private var pw = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your vault").font(.headline)
            Text("Type your vault's master password once. Ragnarok locks it with this Mac's Touch ID chip; after this, Fill only asks for your finger. It never leaves this Mac and isn't saved anywhere readable.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Master password", text: $pw).textFieldStyle(.roundedBorder).onSubmit(go)
            if !v.note.isEmpty { Text(v.note).font(.caption).foregroundStyle(v.busy ? Color.secondary : Color.red) }
            HStack {
                Spacer()
                Button("Cancel") { v.askMaster = false; pw = "" }
                Button("Connect", action: go).keyboardShortcut(.defaultAction).disabled(pw.isEmpty || v.busy)
            }
        }.padding(20).frame(width: 420)
    }
    private func go() { let p = pw; pw = ""; v.setUp(master: p) }
}

/// --fillcheck (test mode): a login form in a real WKWebView, filled with a tricky username/password, then read back.
/// Exit 0 only if both boxes hold exactly what was filled and a decoy hidden box was left alone.
@MainActor enum VaultFillCheck {
    static var keep: [AnyObject] = []
    static func run() {
        _ = NSApplication.shared
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = w; win.orderFrontRegardless(); keep = [w, win]
        let html = "<form><input type=hidden name=decoy value=keep><input type=email id=u><input type=password id=p></form>"
        w.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        let user = "sam@example.com", pass = #"a"b'c\d</script>"#
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            w.evaluateJavaScript(Vault.fillScript(username: user, password: pass)) { r, e in
                w.evaluateJavaScript("JSON.stringify([document.getElementById('u').value, document.getElementById('p').value, document.querySelector('[name=decoy]').value])") { v, _ in
                    let got = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
                    let ok = got == [user, pass, "keep"]
                    print("fillcheck: script said \(r ?? e?.localizedDescription ?? "nothing"); \(ok ? "filled correctly" : "WRONG: \(got)")")
                    if !ok { exit(1) }
                    codePages(w)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("fillcheck: timed out"); exit(1) }
    }

    /// A 2FA page (one code box next to a zip box and a username box), then a page with one box per digit.
    static func codePages(_ w: WKWebView) {
        let read = "JSON.stringify(Array.prototype.map.call(document.querySelectorAll('input'), function(e){ return e.value; }))"
        func vals(_ v: Any?) -> [String] { (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? [] }
        w.loadHTMLString("<form><input type=text name=zip><input type=text name=username value=me><input type=text inputmode=numeric autocomplete=one-time-code name=c></form>",
                         baseURL: URL(string: "https://example.test/2fa"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            w.evaluateJavaScript(Vault.fillScript(username: "sam", password: "pw", code: "042917")) { r, _ in
                w.evaluateJavaScript(read) { v, _ in
                    let one = vals(v) == ["", "me", "042917"]
                    print("fillcheck: 2FA page, script said \(r ?? "nothing"); \(one ? "code in the code box only" : "WRONG: \(vals(v))")")
                    if !one { exit(1) }
                    w.loadHTMLString((0..<6).map { _ in "<input type=text maxlength=1>" }.joined(), baseURL: URL(string: "https://example.test/2fa2"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        w.evaluateJavaScript(Vault.fillScript(username: "sam", password: "pw", code: "042917")) { _, _ in
                            w.evaluateJavaScript(read) { v, _ in
                                let six = vals(v) == ["0", "4", "2", "9", "1", "7"]
                                print("fillcheck: digit boxes \(six ? "filled one digit each" : "WRONG: \(vals(v))")")
                                exit(six ? 0 : 1)
                            }
                        }
                    }
                }
            }
        }
    }
}

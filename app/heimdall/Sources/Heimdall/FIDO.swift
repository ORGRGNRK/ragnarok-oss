import AppKit
import CryptoKit
import Foundation
import WebKit

/// Security keys (YubiKey, uTrust) in the Browser tab (owner, 2026-11-14: "add passthrough into my app for my yubikey").
///
/// Why it is built like this: WebKit inside an app only does WebAuthn with an Apple-granted browser entitlement or for
/// sites listed as the app's Associated Domains (needs a paid Apple Developer profile). Chrome and Firefox don't use
/// Apple's stack for USB keys either: they talk to the key directly over USB (CTAP2). This does the same with
/// libfido2 (Yubico's library, `brew install libfido2`), loaded at run time so the app still builds and runs without it.
///
/// Flow: a small script on every page replaces navigator.credentials.get/create for `publicKey` requests and posts
/// them here. This side checks the page's real origin (from WebKit, not from the page), checks the site's rpId belongs
/// to that origin, builds clientDataJSON itself, asks for the key's PIN when needed, waits for the touch, and hands the
/// result back to the page in the shape WebAuthn gives it.
enum FIDO {
    // MARK: libfido2, loaded at run time
    typealias P = OpaquePointer
    private struct Lib {
        let initf: @convention(c) (Int32) -> Void
        let strerr: @convention(c) (Int32) -> UnsafePointer<CChar>?
        let infoNew: @convention(c) (Int) -> P?
        let infoManifest: @convention(c) (P, Int, UnsafeMutablePointer<Int>) -> Int32
        let infoPtr: @convention(c) (P, Int) -> P?
        let infoPath: @convention(c) (P) -> UnsafePointer<CChar>?
        let infoProduct: @convention(c) (P) -> UnsafePointer<CChar>?
        let infoFree: @convention(c) (UnsafeMutablePointer<P?>, Int) -> Void
        let devNew: @convention(c) () -> P?
        let devOpen: @convention(c) (P, UnsafePointer<CChar>) -> Int32
        let devClose: @convention(c) (P) -> Int32
        let devFree: @convention(c) (UnsafeMutablePointer<P?>) -> Void
        let devHasPin: @convention(c) (P) -> Bool
        let devSetTimeout: @convention(c) (P, Int32) -> Int32
        let devCancel: @convention(c) (P) -> Int32
        let aNew: @convention(c) () -> P?
        let aFree: @convention(c) (UnsafeMutablePointer<P?>) -> Void
        let aSetHash: @convention(c) (P, UnsafePointer<UInt8>, Int) -> Int32
        let aSetRp: @convention(c) (P, UnsafePointer<CChar>) -> Int32
        let aAllow: @convention(c) (P, UnsafePointer<UInt8>, Int) -> Int32
        let aSetUp: @convention(c) (P, Int32) -> Int32
        let aSetUv: @convention(c) (P, Int32) -> Int32
        let devGetAssert: @convention(c) (P, P, UnsafePointer<CChar>?) -> Int32
        let aCount: @convention(c) (P) -> Int
        let aAuthPtr: @convention(c) (P, Int) -> UnsafePointer<UInt8>?
        let aAuthLen: @convention(c) (P, Int) -> Int
        let aSigPtr: @convention(c) (P, Int) -> UnsafePointer<UInt8>?
        let aSigLen: @convention(c) (P, Int) -> Int
        let aIdPtr: @convention(c) (P, Int) -> UnsafePointer<UInt8>?
        let aIdLen: @convention(c) (P, Int) -> Int
        let aUidPtr: @convention(c) (P, Int) -> UnsafePointer<UInt8>?
        let aUidLen: @convention(c) (P, Int) -> Int
        let aUserName: @convention(c) (P, Int) -> UnsafePointer<CChar>?
        let cNew: @convention(c) () -> P?
        let cFree: @convention(c) (UnsafeMutablePointer<P?>) -> Void
        let cSetType: @convention(c) (P, Int32) -> Int32
        let cSetHash: @convention(c) (P, UnsafePointer<UInt8>, Int) -> Int32
        let cSetRp: @convention(c) (P, UnsafePointer<CChar>, UnsafePointer<CChar>?) -> Int32
        let cSetUser: @convention(c) (P, UnsafePointer<UInt8>, Int, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
        let cSetRk: @convention(c) (P, Int32) -> Int32
        let cSetUv: @convention(c) (P, Int32) -> Int32
        let cExclude: @convention(c) (P, UnsafePointer<UInt8>, Int) -> Int32
        let devMakeCred: @convention(c) (P, P, UnsafePointer<CChar>?) -> Int32
        let cAuthPtr: @convention(c) (P) -> UnsafePointer<UInt8>?
        let cAuthLen: @convention(c) (P) -> Int
        let cIdPtr: @convention(c) (P) -> UnsafePointer<UInt8>?
        let cIdLen: @convention(c) (P) -> Int
        let cPkPtr: @convention(c) (P) -> UnsafePointer<UInt8>?
        let cPkLen: @convention(c) (P) -> Int
        let cType: @convention(c) (P) -> Int32
    }

    static let libPaths = ["/opt/homebrew/lib/libfido2.1.dylib", "/usr/local/lib/libfido2.1.dylib"]
    private static let lib: Lib? = {
        guard let h = libPaths.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else { return nil }
        func s<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let initf: @convention(c) (Int32) -> Void = s("fido_init"),
              let strerr: @convention(c) (Int32) -> UnsafePointer<CChar>? = s("fido_strerr"),
              let infoNew: @convention(c) (Int) -> P? = s("fido_dev_info_new"),
              let infoManifest: @convention(c) (P, Int, UnsafeMutablePointer<Int>) -> Int32 = s("fido_dev_info_manifest"),
              let infoPtr: @convention(c) (P, Int) -> P? = s("fido_dev_info_ptr"),
              let infoPath: @convention(c) (P) -> UnsafePointer<CChar>? = s("fido_dev_info_path"),
              let infoProduct: @convention(c) (P) -> UnsafePointer<CChar>? = s("fido_dev_info_product_string"),
              let infoFree: @convention(c) (UnsafeMutablePointer<P?>, Int) -> Void = s("fido_dev_info_free"),
              let devNew: @convention(c) () -> P? = s("fido_dev_new"),
              let devOpen: @convention(c) (P, UnsafePointer<CChar>) -> Int32 = s("fido_dev_open"),
              let devClose: @convention(c) (P) -> Int32 = s("fido_dev_close"),
              let devFree: @convention(c) (UnsafeMutablePointer<P?>) -> Void = s("fido_dev_free"),
              let devHasPin: @convention(c) (P) -> Bool = s("fido_dev_has_pin"),
              let devSetTimeout: @convention(c) (P, Int32) -> Int32 = s("fido_dev_set_timeout"),
              let devCancel: @convention(c) (P) -> Int32 = s("fido_dev_cancel"),
              let aNew: @convention(c) () -> P? = s("fido_assert_new"),
              let aFree: @convention(c) (UnsafeMutablePointer<P?>) -> Void = s("fido_assert_free"),
              let aSetHash: @convention(c) (P, UnsafePointer<UInt8>, Int) -> Int32 = s("fido_assert_set_clientdata_hash"),
              let aSetRp: @convention(c) (P, UnsafePointer<CChar>) -> Int32 = s("fido_assert_set_rp"),
              let aAllow: @convention(c) (P, UnsafePointer<UInt8>, Int) -> Int32 = s("fido_assert_allow_cred"),
              let aSetUp: @convention(c) (P, Int32) -> Int32 = s("fido_assert_set_up"),
              let aSetUv: @convention(c) (P, Int32) -> Int32 = s("fido_assert_set_uv"),
              let devGetAssert: @convention(c) (P, P, UnsafePointer<CChar>?) -> Int32 = s("fido_dev_get_assert"),
              let aCount: @convention(c) (P) -> Int = s("fido_assert_count"),
              let aAuthPtr: @convention(c) (P, Int) -> UnsafePointer<UInt8>? = s("fido_assert_authdata_raw_ptr"),
              let aAuthLen: @convention(c) (P, Int) -> Int = s("fido_assert_authdata_raw_len"),
              let aSigPtr: @convention(c) (P, Int) -> UnsafePointer<UInt8>? = s("fido_assert_sig_ptr"),
              let aSigLen: @convention(c) (P, Int) -> Int = s("fido_assert_sig_len"),
              let aIdPtr: @convention(c) (P, Int) -> UnsafePointer<UInt8>? = s("fido_assert_id_ptr"),
              let aIdLen: @convention(c) (P, Int) -> Int = s("fido_assert_id_len"),
              let aUidPtr: @convention(c) (P, Int) -> UnsafePointer<UInt8>? = s("fido_assert_user_id_ptr"),
              let aUidLen: @convention(c) (P, Int) -> Int = s("fido_assert_user_id_len"),
              let aUserName: @convention(c) (P, Int) -> UnsafePointer<CChar>? = s("fido_assert_user_name"),
              let cNew: @convention(c) () -> P? = s("fido_cred_new"),
              let cFree: @convention(c) (UnsafeMutablePointer<P?>) -> Void = s("fido_cred_free"),
              let cSetType: @convention(c) (P, Int32) -> Int32 = s("fido_cred_set_type"),
              let cSetHash: @convention(c) (P, UnsafePointer<UInt8>, Int) -> Int32 = s("fido_cred_set_clientdata_hash"),
              let cSetRp: @convention(c) (P, UnsafePointer<CChar>, UnsafePointer<CChar>?) -> Int32 = s("fido_cred_set_rp"),
              let cSetUser: @convention(c) (P, UnsafePointer<UInt8>, Int, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = s("fido_cred_set_user"),
              let cSetRk: @convention(c) (P, Int32) -> Int32 = s("fido_cred_set_rk"),
              let cSetUv: @convention(c) (P, Int32) -> Int32 = s("fido_cred_set_uv"),
              let cExclude: @convention(c) (P, UnsafePointer<UInt8>, Int) -> Int32 = s("fido_cred_exclude"),
              let devMakeCred: @convention(c) (P, P, UnsafePointer<CChar>?) -> Int32 = s("fido_dev_make_cred"),
              let cAuthPtr: @convention(c) (P) -> UnsafePointer<UInt8>? = s("fido_cred_authdata_raw_ptr"),
              let cAuthLen: @convention(c) (P) -> Int = s("fido_cred_authdata_raw_len"),
              let cIdPtr: @convention(c) (P) -> UnsafePointer<UInt8>? = s("fido_cred_id_ptr"),
              let cIdLen: @convention(c) (P) -> Int = s("fido_cred_id_len"),
              let cPkPtr: @convention(c) (P) -> UnsafePointer<UInt8>? = s("fido_cred_pubkey_ptr"),
              let cPkLen: @convention(c) (P) -> Int = s("fido_cred_pubkey_len"),
              let cType: @convention(c) (P) -> Int32 = s("fido_cred_type")
        else { return nil }
        initf(0)
        return Lib(initf: initf, strerr: strerr, infoNew: infoNew, infoManifest: infoManifest, infoPtr: infoPtr, infoPath: infoPath,
                   infoProduct: infoProduct, infoFree: infoFree, devNew: devNew, devOpen: devOpen, devClose: devClose, devFree: devFree,
                   devHasPin: devHasPin, devSetTimeout: devSetTimeout, devCancel: devCancel, aNew: aNew, aFree: aFree, aSetHash: aSetHash,
                   aSetRp: aSetRp, aAllow: aAllow, aSetUp: aSetUp, aSetUv: aSetUv, devGetAssert: devGetAssert, aCount: aCount,
                   aAuthPtr: aAuthPtr, aAuthLen: aAuthLen, aSigPtr: aSigPtr, aSigLen: aSigLen, aIdPtr: aIdPtr, aIdLen: aIdLen,
                   aUidPtr: aUidPtr, aUidLen: aUidLen, aUserName: aUserName, cNew: cNew, cFree: cFree, cSetType: cSetType,
                   cSetHash: cSetHash, cSetRp: cSetRp, cSetUser: cSetUser, cSetRk: cSetRk, cSetUv: cSetUv, cExclude: cExclude,
                   devMakeCred: devMakeCred, cAuthPtr: cAuthPtr, cAuthLen: cAuthLen, cIdPtr: cIdPtr, cIdLen: cIdLen,
                   cPkPtr: cPkPtr, cPkLen: cPkLen, cType: cType)
    }()
    static var available: Bool { lib != nil }

    // libfido2 values (fido/err.h, fido/param.h, fido/types.h)
    static let optOmit: Int32 = 0, optTrue: Int32 = 2
    static let errPinRequired: Int32 = 0x36, errPinInvalid: Int32 = 0x31, errNoCreds: Int32 = 0x2e, errExcluded: Int32 = 0x19,
               errPinBlocked: Int32 = 0x32, errPinAuthBlocked: Int32 = 0x34, errTimeout: Int32 = 0x3a, errDenied: Int32 = 0x27,
               errCancel: Int32 = 0x2d, errAlg: Int32 = 0x26
    static let es256: Int32 = -7, eddsa: Int32 = -8

    struct Failure: Error { let code: Int32; let text: String }
    private static func check(_ r: Int32, _ what: String) throws {
        guard r == 0 else { throw Failure(code: r, text: what + ": " + (lib?.strerr(r).map { String(cString: $0) } ?? "error \(r)")) }
    }

    /// Plugged-in security keys: (path, product name). No touch, no PIN.
    static func devices() -> [(path: String, name: String)] {
        guard let l = lib, let info = l.infoNew(16) else { return [] }
        var list: P? = info
        defer { l.infoFree(&list, 16) }
        var n = 0
        guard l.infoManifest(info, 16, &n) == 0 else { return [] }
        return (0..<n).compactMap { i in
            guard let d = l.infoPtr(info, i), let p = l.infoPath(d) else { return nil }
            return (String(cString: p), l.infoProduct(d).map { String(cString: $0) } ?? "security key")
        }
    }

    /// The device being used right now, so the Cancel button can stop a wait for a touch.
    nonisolated(unsafe) private static var busyDev: P?
    private static let busyLock = NSLock()
    static func cancel() { busyLock.lock(); if let d = busyDev { _ = lib?.devCancel(d) }; busyLock.unlock() }

    private static func withDevice<T>(_ body: (Lib, P) throws -> T) throws -> T {
        guard let l = lib else { throw Failure(code: -1, text: "libfido2 is not installed (brew install libfido2)") }
        guard let first = devices().first else { throw Failure(code: -2, text: "No security key is plugged in") }
        guard let dev = l.devNew() else { throw Failure(code: -1, text: "out of memory") }
        var d: P? = dev
        defer { l.devFree(&d) }
        try check(l.devOpen(dev, first.path), "Could not open the security key")
        defer { _ = l.devClose(dev) }
        _ = l.devSetTimeout(dev, 60_000)
        busyLock.lock(); busyDev = dev; busyLock.unlock()
        defer { busyLock.lock(); busyDev = nil; busyLock.unlock() }
        return try body(l, dev)
    }

    static func hasPin() -> Bool { (try? withDevice { l, d in l.devHasPin(d) }) ?? false }

    struct Assertion { let credId: Data; let authData: Data; let sig: Data; let userHandle: Data; let userName: String }
    struct Credential { let credId: Data; let authData: Data; let publicKey: Data; let alg: Int32 }

    private static func bytes(_ p: UnsafePointer<UInt8>?, _ n: Int) -> Data { p.map { Data(bytes: $0, count: n) } ?? Data() }

    /// navigator.credentials.get on the key. Blocks until touched, cancelled or 60 s.
    static func getAssertion(rpId: String, hash: Data, allow: [Data], pin: String?) throws -> [Assertion] {
        try withDevice { l, dev in
            guard let a = l.aNew() else { throw Failure(code: -1, text: "out of memory") }
            var ap: P? = a
            defer { l.aFree(&ap) }
            try hash.withUnsafeBytes { try check(l.aSetHash(a, $0.bindMemory(to: UInt8.self).baseAddress!, hash.count), "clientDataHash") }
            try check(l.aSetRp(a, rpId), "rpId")
            for c in allow where !c.isEmpty {
                try c.withUnsafeBytes { try check(l.aAllow(a, $0.bindMemory(to: UInt8.self).baseAddress!, c.count), "allowCredentials") }
            }
            try check(l.aSetUp(a, optTrue), "user presence")
            try check(l.aSetUv(a, optOmit), "user verification")   // with a PIN, libfido2 proves UV through the PIN
            try check(l.devGetAssert(dev, a, pin), "The key said no")
            return (0..<l.aCount(a)).map { i in
                Assertion(credId: bytes(l.aIdPtr(a, i), l.aIdLen(a, i)), authData: bytes(l.aAuthPtr(a, i), l.aAuthLen(a, i)),
                          sig: bytes(l.aSigPtr(a, i), l.aSigLen(a, i)), userHandle: bytes(l.aUidPtr(a, i), l.aUidLen(a, i)),
                          userName: l.aUserName(a, i).map { String(cString: $0) } ?? "")
            }
        }
    }

    /// navigator.credentials.create on the key.
    static func makeCredential(rpId: String, rpName: String, userId: Data, userName: String, displayName: String, hash: Data,
                               alg: Int32, residentKey: Bool, exclude: [Data], pin: String?) throws -> Credential {
        try withDevice { l, dev in
            guard let c = l.cNew() else { throw Failure(code: -1, text: "out of memory") }
            var cp: P? = c
            defer { l.cFree(&cp) }
            try check(l.cSetType(c, alg), "algorithm")
            try hash.withUnsafeBytes { try check(l.cSetHash(c, $0.bindMemory(to: UInt8.self).baseAddress!, hash.count), "clientDataHash") }
            try check(l.cSetRp(c, rpId, rpName), "rp")
            try userId.withUnsafeBytes {
                try check(l.cSetUser(c, $0.bindMemory(to: UInt8.self).baseAddress!, userId.count, userName, displayName, nil), "user")
            }
            try check(l.cSetRk(c, residentKey ? optTrue : optOmit), "resident key")
            try check(l.cSetUv(c, optOmit), "user verification")
            for e in exclude where !e.isEmpty {
                try e.withUnsafeBytes { try check(l.cExclude(c, $0.bindMemory(to: UInt8.self).baseAddress!, e.count), "excludeCredentials") }
            }
            try check(l.devMakeCred(dev, c, pin), "The key said no")
            return Credential(credId: bytes(l.cIdPtr(c), l.cIdLen(c)), authData: bytes(l.cAuthPtr(c), l.cAuthLen(c)),
                              publicKey: bytes(l.cPkPtr(c), l.cPkLen(c)), alg: l.cType(c))
        }
    }

    // MARK: pure helpers (tested in SelfTest, no key needed)

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func unb64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// The origin string WebAuthn puts in clientDataJSON: scheme://host[:port], default ports left out.
    static func origin(scheme: String, host: String, port: Int) -> String {
        let dflt = (scheme == "https" && port == 443) || (scheme == "http" && port == 80) || port == 0
        return "\(scheme)://\(host)" + (dflt ? "" : ":\(port)")
    }

    /// May a page at `host` (scheme `scheme`) use credentials for `rpId`? Same rule browsers use: the rpId is the host
    /// or a parent domain of it, the page is https (or http on localhost), and the rpId is a real domain, not "com".
    static func rpAllowed(rpId: String, host: String, scheme: String) -> Bool {
        let r = rpId.lowercased(), h = host.lowercased()
        let secure = scheme == "https" || (scheme == "http" && (h == "localhost" || h.hasSuffix(".localhost")))
        guard secure, !r.isEmpty, r.contains(".") || r == "localhost", !r.hasPrefix("."), !r.hasSuffix(".") else { return false }
        return h == r || h.hasSuffix("." + r)
    }

    static func clientDataJSON(type: String, challenge: Data, origin: String) -> Data {
        // Field order and escaping as browsers write it; challenge is base64url and origin is a URL, so no quotes inside.
        Data("{\"type\":\"\(type)\",\"challenge\":\"\(b64url(challenge))\",\"origin\":\"\(origin)\",\"crossOrigin\":false}".utf8)
    }

    /// attestationObject with "none" attestation: {"fmt":"none","attStmt":{},"authData":<bytes>} in CBOR.
    static func attestationNone(authData: Data) -> Data {
        var o = Data([0xA3, 0x63]) + Data("fmt".utf8) + Data([0x64]) + Data("none".utf8)
        o += Data([0x67]) + Data("attStmt".utf8) + Data([0xA0])
        o += Data([0x68]) + Data("authData".utf8)
        let n = authData.count
        if n < 24 { o.append(UInt8(0x40 + n)) }
        else if n < 256 { o += Data([0x58, UInt8(n)]) }
        else if n < 65536 { o += Data([0x59, UInt8(n >> 8), UInt8(n & 0xFF)]) }
        else { o += Data([0x5A, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]) }
        return o + authData
    }

    /// SubjectPublicKeyInfo DER for getPublicKey(), from libfido2's raw key (ES256: x||y, 64 bytes; EdDSA: 32 bytes).
    static func spki(_ raw: Data, alg: Int32) -> Data? {
        if alg == es256, raw.count == 64 {
            return Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48,
                         0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04]) + raw
        }
        if alg == eddsa, raw.count == 32 {
            return Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00]) + raw
        }
        return nil
    }

    /// Page side: replaces navigator.credentials.get/create for security-key requests. Everything that matters
    /// (origin, rpId, clientDataJSON) is decided natively; this only moves bytes and builds the result objects.
    static let script = #"""
    (() => {
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.ragnarokFido || !navigator.credentials) return;
      const H = window.webkit.messageHandlers.ragnarokFido;
      const b64 = (buf) => { const u = buf instanceof ArrayBuffer ? new Uint8Array(buf) : new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
        let s = ''; for (const c of u) s += String.fromCharCode(c); return btoa(s).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,''); };
      const unb64 = (s) => { s = s.replace(/-/g,'+').replace(/_/g,'/'); while (s.length % 4) s += '=';
        const b = atob(s), u = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); return u.buffer; };
      const err = (m) => { const [name, ...rest] = String(m).split(': '); return new DOMException(rest.join(': ') || name, name || 'NotAllowedError'); };
      const def = (o, k, v) => Object.defineProperty(o, k, { value: v, enumerable: true, configurable: true });
      const cred = (r, resp) => {
        const c = Object.create(PublicKeyCredential.prototype);
        def(c, 'id', r.id); def(c, 'rawId', unb64(r.id)); def(c, 'type', 'public-key'); def(c, 'authenticatorAttachment', 'cross-platform');
        def(c, 'response', resp); def(c, 'getClientExtensionResults', () => ({}));
        def(c, 'toJSON', () => { const j = { id: r.id, rawId: r.id, type: 'public-key', authenticatorAttachment: 'cross-platform', clientExtensionResults: {}, response: {} };
          for (const k of Object.keys(r)) if (k !== 'id' && k !== 'alg' && k !== 'publicKey') j.response[k] = r[k];
          if (r.publicKey) { j.response.publicKey = r.publicKey; j.response.publicKeyAlgorithm = r.alg; j.response.transports = ['usb']; }
          return j; });
        return c;
      };
      const ask = (kind, pk, signal) => new Promise((ok, no) => {
        if (signal && signal.aborted) return no(new DOMException('aborted', 'AbortError'));
        if (signal) signal.addEventListener('abort', () => { H.postMessage({ kind: 'cancel' }); no(new DOMException('aborted', 'AbortError')); });
        H.postMessage(Object.assign({ kind }, pk)).then(ok, (e) => no(err(e.message || e)));
      });
      const og = navigator.credentials.get.bind(navigator.credentials), oc = navigator.credentials.create.bind(navigator.credentials);
      navigator.credentials.get = function (o) {
        if (!o || !o.publicKey) return og(o);
        if (o.mediation === 'conditional') return new Promise((_, no) => { if (o.signal) o.signal.addEventListener('abort', () => no(new DOMException('aborted', 'AbortError'))); });
        const p = o.publicKey;
        return ask('get', { challenge: b64(p.challenge), rpId: p.rpId || '', userVerification: p.userVerification || 'preferred',
          allow: (p.allowCredentials || []).map(c => b64(c.id)) }, o.signal).then(r => {
          const resp = Object.create(AuthenticatorAssertionResponse.prototype);
          def(resp, 'clientDataJSON', unb64(r.clientDataJSON)); def(resp, 'authenticatorData', unb64(r.authenticatorData));
          def(resp, 'signature', unb64(r.signature)); def(resp, 'userHandle', r.userHandle ? unb64(r.userHandle) : null);
          return cred(r, resp);
        });
      };
      navigator.credentials.create = function (o) {
        if (!o || !o.publicKey) return oc(o);
        const p = o.publicKey, sel = p.authenticatorSelection || {};
        return ask('create', { challenge: b64(p.challenge), rpId: (p.rp && p.rp.id) || '', rpName: (p.rp && p.rp.name) || '',
          userId: b64(p.user.id), userName: p.user.name || '', displayName: p.user.displayName || '',
          algs: (p.pubKeyCredParams || []).map(x => x.alg), exclude: (p.excludeCredentials || []).map(c => b64(c.id)),
          residentKey: sel.residentKey === 'required' || sel.residentKey === 'preferred' || sel.requireResidentKey === true,
          userVerification: sel.userVerification || 'preferred' }, o.signal).then(r => {
          const resp = Object.create(AuthenticatorAttestationResponse.prototype);
          def(resp, 'clientDataJSON', unb64(r.clientDataJSON)); def(resp, 'attestationObject', unb64(r.attestationObject));
          def(resp, 'getTransports', () => ['usb']); def(resp, 'getAuthenticatorData', () => unb64(r.authenticatorData));
          def(resp, 'getPublicKey', () => r.publicKey ? unb64(r.publicKey) : null); def(resp, 'getPublicKeyAlgorithm', () => r.alg);
          return cred(r, resp);
        });
      };
      if (window.PublicKeyCredential) {
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false);
        PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(false);
      }
    })();
    """#
}

/// Receives the page's requests, does the checks and the PIN/touch, replies to the page.
@MainActor
final class FIDOBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "ragnarokFido"
    private var busy = false
    /// Shown in the Browser tab's note line ("Touch your security key…").
    var status: (String) -> Void = { _ in }

    static func install(on c: WKUserContentController, bridge: FIDOBridge) {
        c.addUserScript(WKUserScript(source: FIDO.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        c.addScriptMessageHandler(bridge, contentWorld: .page, name: name)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(nil, "NotAllowedError: bad request"); return
        }
        if kind == "cancel" { FIDO.cancel(); replyHandler(true, nil); return }
        // The origin comes from WebKit (the frame that really sent it), never from the page's own data.
        let o = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, !o.host.isEmpty else { replyHandler(nil, "NotAllowedError: only the main page may use the key"); return }
        let origin = FIDO.origin(scheme: o.protocol, host: o.host, port: o.port)
        let rpId = (body["rpId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? o.host
        guard FIDO.rpAllowed(rpId: rpId, host: o.host, scheme: o.protocol) else {
            replyHandler(nil, "SecurityError: \(o.host) may not use keys for \(rpId)"); return
        }
        guard FIDO.available else {
            status("Security keys need libfido2: run `brew install libfido2`, then try again.")
            replyHandler(nil, "NotAllowedError: libfido2 is not installed"); return
        }
        guard !busy else { replyHandler(nil, "NotAllowedError: already waiting for the key"); return }
        guard let challenge = FIDO.unb64url(body["challenge"] as? String ?? "") else { replyHandler(nil, "TypeError: bad challenge"); return }
        let uv = (body["userVerification"] as? String ?? "preferred") != "discouraged"
        let type = kind == "get" ? "webauthn.get" : "webauthn.create"
        let cdj = FIDO.clientDataJSON(type: type, challenge: challenge, origin: origin)
        let hash = Data(SHA256.hash(data: cdj))
        let host = o.host

        busy = true
        status("Checking for your security key…")
        Task.detached {
            let hasPin = FIDO.hasPin()
            let pin: String? = (uv && hasPin) ? await self.askPin(host: host, again: false) : nil
            if uv && hasPin && pin == nil {
                await self.finish(replyHandler, nil, "NotAllowedError: cancelled"); return
            }
            await self.say("Touch your security key to \(kind == "get" ? "sign in to" : "add it to") \(host)…")
            do {
                if kind == "get" {
                    let allow = (body["allow"] as? [String] ?? []).compactMap(FIDO.unb64url)
                    var list = try FIDO.getAssertion(rpId: rpId, hash: hash, allow: allow, pin: pin)
                    if list.count > 1, let i = await self.pick(list.map { $0.userName.isEmpty ? FIDO.b64url($0.userHandle) : $0.userName }, host: host) {
                        list = [list[i]]
                    }
                    guard let a = list.first else { throw FIDO.Failure(code: FIDO.errNoCreds, text: "no credential") }
                    await self.finish(replyHandler, ["id": FIDO.b64url(a.credId), "clientDataJSON": FIDO.b64url(cdj),
                                                     "authenticatorData": FIDO.b64url(a.authData), "signature": FIDO.b64url(a.sig),
                                                     "userHandle": a.userHandle.isEmpty ? "" : FIDO.b64url(a.userHandle)], nil)
                } else {
                    let algs = (body["algs"] as? [NSNumber] ?? []).map { Int32(truncating: $0) }
                    guard let alg = algs.first(where: { $0 == FIDO.es256 || $0 == FIDO.eddsa }) ?? (algs.isEmpty ? FIDO.es256 : nil) else {
                        throw FIDO.Failure(code: FIDO.errAlg, text: "the site asked for an algorithm security keys don't do")
                    }
                    guard let uid = FIDO.unb64url(body["userId"] as? String ?? ""), !uid.isEmpty else { throw FIDO.Failure(code: -3, text: "bad user id") }
                    let c = try FIDO.makeCredential(rpId: rpId, rpName: body["rpName"] as? String ?? rpId, userId: uid,
                                                    userName: body["userName"] as? String ?? "", displayName: body["displayName"] as? String ?? "",
                                                    hash: hash, alg: alg, residentKey: body["residentKey"] as? Bool ?? false,
                                                    exclude: (body["exclude"] as? [String] ?? []).compactMap(FIDO.unb64url), pin: pin)
                    var r: [String: Any] = ["id": FIDO.b64url(c.credId), "clientDataJSON": FIDO.b64url(cdj),
                                            "attestationObject": FIDO.b64url(FIDO.attestationNone(authData: c.authData)),
                                            "authenticatorData": FIDO.b64url(c.authData), "alg": Int(c.alg)]
                    if let k = FIDO.spki(c.publicKey, alg: c.alg) { r["publicKey"] = FIDO.b64url(k) }
                    await self.finish(replyHandler, r, nil)
                }
            } catch let f as FIDO.Failure {
                await self.finish(replyHandler, nil, Self.explain(f), note: Self.plain(f))
            } catch {
                await self.finish(replyHandler, nil, "NotAllowedError: \(error.localizedDescription)")
            }
        }
    }

    /// WebAuthn error name the page understands.
    nonisolated static func explain(_ f: FIDO.Failure) -> String {
        switch f.code {
        case FIDO.errExcluded: return "InvalidStateError: this key is already registered here"
        case FIDO.errAlg: return "NotSupportedError: \(f.text)"
        default: return "NotAllowedError: \(f.text)"
        }
    }
    /// What the owner reads in the note line.
    nonisolated static func plain(_ f: FIDO.Failure) -> String {
        switch f.code {
        case FIDO.errPinInvalid: return "Wrong PIN. The key counts wrong tries; after 8 it locks."
        case FIDO.errPinBlocked: return "The key's PIN is locked (too many wrong tries). It needs a reset."
        case FIDO.errPinAuthBlocked: return "Too many wrong PINs in a row: unplug the key and plug it back in."
        case FIDO.errNoCreds: return "This key has no login for this site."
        case FIDO.errTimeout, FIDO.errCancel: return "No touch in time; nothing was sent."
        case FIDO.errExcluded: return "This key is already registered on this site."
        case FIDO.errDenied: return "The key said no."
        case -2: return "No security key is plugged in."
        default: return f.text
        }
    }

    private func say(_ s: String) { status(s) }
    private func finish(_ reply: @escaping @MainActor @Sendable (Any?, String?) -> Void, _ v: Any?, _ e: String?, note: String? = nil) {
        busy = false
        status(e == nil ? "" : (note ?? ""))
        reply(v, e)
    }

    private func askPin(host: String, again: Bool) -> String? {
        let a = NSAlert()
        a.messageText = "Security key PIN"
        a.informativeText = "\(host) wants to use your security key. Type the key's PIN; it goes only to the key."
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Continue"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return nil }
        return f.stringValue
    }

    private func pick(_ names: [String], host: String) -> Int? {
        let a = NSAlert()
        a.messageText = "Which account?"
        a.informativeText = "Your key has more than one login for \(host)."
        let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26)); p.addItems(withTitles: names)
        a.accessoryView = p
        a.addButton(withTitle: "Sign in"); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn ? p.indexOfSelectedItem : nil
    }
}

/// `Heimdall --fidocheck`: is libfido2 there, which keys are plugged in. No touch, no PIN.
enum FIDOCheck {
    static func run() -> Never {
        print("libfido2: " + (FIDO.available ? "loaded" : "NOT found in " + FIDO.libPaths.joined(separator: ", ")))
        let d = FIDO.devices()
        print("keys plugged in: \(d.count)")
        for k in d { print("  \(k.name)  (\(k.path))") }
        exit(FIDO.available ? 0 : 1)
    }
}

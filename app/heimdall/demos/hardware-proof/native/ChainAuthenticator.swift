import CryptoKit
import Foundation
import LocalAuthentication
import Security

// Local device enrollment and signing. No password/software-key fallback and no remote enrollment claim.
enum EnrollmentError: Error { case invalidArguments, unavailable, inconsistent, missing, invalidIdentity, verification }
let args = Array(CommandLine.arguments.dropFirst())
let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ragnarok/hardware")
let profile = root.appendingPathComponent("laptop")
let keyURL = profile.appendingPathComponent("secure-enclave.reference")
let publicURL = profile.appendingPathComponent("public.pem")
let metaURL = profile.appendingPathComponent("profile.json")
let context = LAContext()
context.localizedFallbackTitle = ""
context.touchIDAuthenticationAllowableReuseDuration = 0

func emit(_ value: [String: Any], code: Int32 = 0) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
    exit(code)
}
func present(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
}
func identity(_ key: SecureEnclave.P256.Signing.PrivateKey) -> String {
    SHA256.hash(data: key.publicKey.derRepresentation).map { String(format: "%02x", $0) }.joined()
}
func enrollmentExists() -> Bool { present(keyURL) && present(publicURL) && present(metaURL) }
func loadKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
    guard enrollmentExists() else { throw EnrollmentError.missing }
    let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(contentsOf: keyURL), authenticationContext: context)
    let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any]
    guard meta?["key_id"] as? String == identity(key),
          try String(contentsOf: publicURL, encoding: .utf8) == key.publicKey.pemRepresentation else { throw EnrollmentError.invalidIdentity }
    return key
}
func writePrivate(_ data: Data, _ url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw EnrollmentError.inconsistent }
    var offset = 0
    defer { close(fd) }
    try data.withUnsafeBytes { buffer in
        while offset < buffer.count {
            let n = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            guard n > 0 else { throw EnrollmentError.inconsistent }; offset += n
        }
    }
    guard fsync(fd) == 0 else { throw EnrollmentError.inconsistent }
}
func store(_ key: SecureEnclave.P256.Signing.PrivateKey) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true, !fm.fileExists(atPath: profile.path) else { throw EnrollmentError.inconsistent }
    let pending = root.appendingPathComponent(".enrollment-" + UUID().uuidString)
    try fm.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: pending) }
    let metadata: [String: Any] = ["schema_version": 1, "kind": "secure-enclave-p256", "key_id": identity(key),
                                  "biometrics": "current-set", "created_at": ISO8601DateFormatter().string(from: Date())]
    try writePrivate(key.dataRepresentation, pending.appendingPathComponent("secure-enclave.reference"))
    try writePrivate(Data(key.publicKey.pemRepresentation.utf8), pending.appendingPathComponent("public.pem"))
    try writePrivate(JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), pending.appendingPathComponent("profile.json"))
    try fm.moveItem(at: pending, to: profile) // complete profile appears together; existing enrollment is never replaced
}
func payload(_ challenge: String) -> Data { Data(("ragnarok-chain:v1:" + challenge).utf8) }

if args == ["--selfcheck"] {
    do {
        let key = P256.Signing.PrivateKey() // software fixture only; never stored or accepted for enrollment
        let data = payload(String(repeating: "a", count: 32)), signature = try key.signature(for: data)
        let ok = key.publicKey.isValidSignature(signature, for: data) && !key.publicKey.isValidSignature(signature, for: payload(String(repeating: "b", count: 32)))
        emit(["fixture_verified": ok, "hardware_tested": false], code: ok ? 0 : 1)
    } catch { emit(["ok": false, "error": "fixture_failed"], code: 1) }
}
var capabilityError: NSError?
let biometric = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &capabilityError)
if args == ["--capability"] || args == ["--status"] {
    emit(["secure_enclave_available": SecureEnclave.isAvailable, "biometrics_available": biometric,
          "enrolled": enrollmentExists(), "physical_verification": "Unverified"])
}
let enroll = args == ["--enroll"], verify = args == ["--verify"]
let challenge: String
if args.count == 2, args[0] == "--challenge", args[1].range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil {
    challenge = args[1]
} else if enroll || verify { challenge = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
else { emit(["ok": false, "error": "invalid_arguments"], code: 2) }
guard SecureEnclave.isAvailable, biometric else { emit(["ok": false, "error": "hardware_or_biometrics_unavailable"], code: 3) }
if !enroll && !enrollmentExists() { emit(["ok": false, "error": "enrollment_required"], code: 6) }
if enroll && FileManager.default.fileExists(atPath: profile.path) && !enrollmentExists() {
    emit(["ok": false, "error": "existing_profile_incomplete_preserved"], code: 7)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { context.invalidate(); emit(["ok": false, "error": "authentication_timeout"], code: 4) }
context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                       localizedReason: enroll ? "enroll this laptop's Secure Enclave key for Ragnarok" : "authorize Ragnarok using this laptop's enrolled key") { approved, _ in
    guard approved else { emit(["ok": false, "error": "biometric_approval_not_granted"], code: 5) }
    do {
        let existing = enrollmentExists()
        let key: SecureEnclave.P256.Signing.PrivateKey
        if existing { key = try loadKey() }
        else {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                              [.privateKeyUsage, .biometryCurrentSet], &error) else { throw EnrollmentError.unavailable }
            key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access, authenticationContext: context)
        }
        let signature = try key.signature(for: payload(challenge))
        guard key.publicKey.isValidSignature(signature, for: payload(challenge)) else { throw EnrollmentError.verification }
        if enroll && !existing { try store(key) }
        if enroll || verify {
            emit(["ok": true, "enrolled": true, "signature_verified": true, "created": !existing])
        }
        emit(["ok": true, "challenge": challenge, "key_id": identity(key), "signature": signature.derRepresentation.base64EncodedString()])
    } catch {
        emit(["ok": false, "error": "secure_enclave_operation_failed", "code": (error as NSError).code], code: 8)
    }
}
RunLoop.main.run()

import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

// Touch ID approval for one destructive command, signed by the Secure Enclave.
// There is no password fallback. The sheet's reason text is the command being approved.
// A missing sensor, a denial, or a timeout fails closed.

enum AuthError: Error {
    case unavailable, inconsistent, missing, invalidIdentity, verification
}

let context = LAContext()
context.localizedFallbackTitle = ""
context.touchIDAuthenticationAllowableReuseDuration = 0

let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".touchgate/enclave")
let keyURL = root.appendingPathComponent("secure-enclave.reference")
let publicURL = root.appendingPathComponent("public.pem")
let metaURL = root.appendingPathComponent("profile.json")

var args = Array(CommandLine.arguments.dropFirst())
var reasonText = "TouchGate: approve a destructive command"
var challengeArg: String? = nil
var index = 0
var positional: [String] = []
while index < args.count {
    if args[index] == "--reason", index + 1 < args.count {
        reasonText = String(args[index + 1].prefix(180))
        index += 2
        continue
    }
    if args[index] == "--challenge", index + 1 < args.count {
        challengeArg = args[index + 1]
        index += 2
        continue
    }
    positional.append(args[index])
    index += 1
}
args = positional
if reasonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    reasonText = "TouchGate: approve a destructive command"
}

func emit(_ value: [String: Any], code: Int32 = 0) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    var line = data
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
    try? FileHandle.standardOutput.synchronize()
    Darwin.exit(code)
}

func present(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
        return false
    }
    return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
}

func identity(_ key: SecureEnclave.P256.Signing.PrivateKey) -> String {
    SHA256.hash(data: key.publicKey.derRepresentation).map { String(format: "%02x", $0) }.joined()
}

func enrollmentExists() -> Bool {
    present(keyURL) && present(publicURL) && present(metaURL)
}

func payload(_ challenge: String) -> Data {
    Data(("touchgate:v1:" + challenge).utf8)
}

func loadKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
    guard enrollmentExists() else { throw AuthError.missing }
    let key = try SecureEnclave.P256.Signing.PrivateKey(
        dataRepresentation: Data(contentsOf: keyURL),
        authenticationContext: context
    )
    let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any]
    guard meta?["key_id"] as? String == identity(key),
          try String(contentsOf: publicURL, encoding: .utf8) == key.publicKey.pemRepresentation
    else { throw AuthError.invalidIdentity }
    return key
}

func writePrivate(_ data: Data, _ url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw AuthError.inconsistent }
    defer { close(fd) }
    var offset = 0
    try data.withUnsafeBytes { buffer in
        while offset < buffer.count {
            let wrote = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            guard wrote > 0 else { throw AuthError.inconsistent }
            offset += wrote
        }
    }
    guard fsync(fd) == 0 else { throw AuthError.inconsistent }
}

func store(_ key: SecureEnclave.P256.Signing.PrivateKey) throws {
    let files = FileManager.default
    try files.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if files.fileExists(atPath: root.path) {
        throw AuthError.inconsistent
    }
    let pending = root.deletingLastPathComponent().appendingPathComponent(".enrollment-" + UUID().uuidString)
    try files.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: pending) }
    let metadata: [String: Any] = [
        "schema_version": 1,
        "kind": "secure-enclave-p256",
        "key_id": identity(key),
        "biometrics": "current-set",
        "created_at": ISO8601DateFormatter().string(from: Date()),
    ]
    try writePrivate(key.dataRepresentation, pending.appendingPathComponent("secure-enclave.reference"))
    try writePrivate(Data(key.publicKey.pemRepresentation.utf8), pending.appendingPathComponent("public.pem"))
    try writePrivate(JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), pending.appendingPathComponent("profile.json"))
    try files.moveItem(at: pending, to: root)
}

if args == ["--selfcheck"] {
    do {
        let key = P256.Signing.PrivateKey()
        let data = payload(String(repeating: "a", count: 32))
        let signature = try key.signature(for: data)
        let ok = key.publicKey.isValidSignature(signature, for: data)
            && !key.publicKey.isValidSignature(signature, for: payload(String(repeating: "b", count: 32)))
        emit(["fixture_verified": ok, "hardware_tested": false], code: ok ? 0 : 1)
    } catch {
        emit(["ok": false, "error": "fixture_failed"], code: 1)
    }
}

var capabilityError: NSError?
let biometric = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &capabilityError)
if args == ["--capability"] || args == ["--status"] {
    emit([
        "secure_enclave_available": SecureEnclave.isAvailable,
        "biometrics_available": biometric,
        "enrolled": enrollmentExists(),
    ])
}

let challenge: String
if let given = challengeArg, given.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil {
    challenge = given
} else {
    emit(["ok": false, "error": "invalid_arguments"], code: 2)
}
guard SecureEnclave.isAvailable, biometric else {
    emit(["ok": false, "error": "hardware_or_biometrics_unavailable"], code: 3)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
    context.invalidate()
    emit(["ok": false, "error": "authentication_timeout"], code: 4)
}

context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reasonText) { approved, _ in
    guard approved else { emit(["ok": false, "error": "biometric_approval_not_granted"], code: 5) }
    do {
        let existing = enrollmentExists()
        let key: SecureEnclave.P256.Signing.PrivateKey
        if existing {
            key = try loadKey()
        } else {
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage, .biometryCurrentSet],
                &accessError
            ) else { throw AuthError.unavailable }
            key = try SecureEnclave.P256.Signing.PrivateKey(
                compactRepresentable: false,
                accessControl: access,
                authenticationContext: context
            )
            try store(key)
        }
        let signature = try key.signature(for: payload(challenge))
        guard key.publicKey.isValidSignature(signature, for: payload(challenge)) else { throw AuthError.verification }
        emit([
            "ok": true,
            "challenge": challenge,
            "key_id": identity(key),
            "signature": signature.derRepresentation.base64EncodedString(),
        ])
    } catch {
        emit(["ok": false, "error": "secure_enclave_operation_failed", "code": (error as NSError).code], code: 8)
    }
}

RunLoop.main.run()

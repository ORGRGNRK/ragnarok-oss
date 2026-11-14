import Foundation

/// Everything machine- or person-specific lives in ~/.ragnarok/local.conf (not in git), as KEY=value lines.
/// The file is only read, never run. A missing file, missing key or odd-looking value keeps the generic default.
///   ALEXUS_HOST=alexus.local         home-network address of the server ("Alexus")
///   ALEXUS_USER=<you>                login used for ssh (read-only tails, room, Hub); default: the Mac login name
///   ALEXUS_TAILSCALE=alexus          address when away from home (bin/room tries it second)
///   OLLAMA_URL=http://alexus.local:11434   defaults to http://<ALEXUS_HOST>:11434
///   HA_URL=https://...               Home Assistant address
///   OWNER_NAME=Sam                   what the app and its AIs call you; default: first name of the Mac account
///   MY_NAMES=Sam Doe,Cash App*sam    comma-separated: how your own name shows on bank lines (Money: own transfers)
///   VAULT_URL=https://vault.example.com   Vaultwarden server for the Vault tab
/// bin/local-config.sh reads the same file for the shell scripts; the Python helpers read it themselves.
enum LocalConfig {
    nonisolated static let path = ("~/.ragnarok/local.conf" as NSString).expandingTildeInPath

    struct Values: Equatable {
        var alexusHost = "alexus.local"
        var alexusUser = LocalConfig.loginUser
        var alexusTailscale = "alexus"
        var ollamaURL: String? = nil
        var homeAssistantURL: String? = nil   // HA_URL: e.g. the https Tailscale Serve address (the Assist mic needs https)
        var ownerName = LocalConfig.defaultOwnerName
        var myNames: [String] = []
        var vaultURL: String? = nil
        var ssh: String { alexusUser + "@" + alexusHost }
        var ollama: String { ollamaURL ?? "http://\(alexusHost):11434" }
        var alexusHome: String { "/home/" + alexusUser }
    }

    /// What the app and its AIs call the owner (OWNER_NAME).
    nonisolated static var owner: String { current.ownerName }
    /// The Mac login name if it is a valid ssh user, else "user".
    nonisolated static var loginUser: String { validUser(NSUserName()) ? NSUserName() : "user" }
    /// First word of the Mac account's full name, else "you".
    nonisolated static var defaultOwnerName: String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return validName(first) ? first : "you"
    }
    nonisolated static func validName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || " .'-".unicodeScalars.contains($0) }
    }

    nonisolated static let current: Values = {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return Values() }
        return resolve(text)
    }()

    /// KEY=value lines; blank lines and # comments skipped; surrounding quotes dropped; nothing is expanded or run.
    nonisolated static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.count >= 2, let f = val.first, f == val.last, f == "\"" || f == "'" { val = String(val.dropFirst().dropLast()) }
            out[key] = val
        }
        return out
    }

    /// Host: letters, digits, dot, dash, colon (IPv6), not starting with "-" (ssh would read it as an option).
    nonisolated static func validHost(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 253 && !s.hasPrefix("-")
            && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || ".-:".unicodeScalars.contains($0) }
    }
    nonisolated static func validUser(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, s.count <= 32, CharacterSet.lowercaseLetters.contains(f) || f == "_" else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0)) }
    }
    nonisolated static func validURL(_ s: String) -> Bool {
        guard let u = URL(string: s), let h = u.host, validHost(h) else { return false }
        return ["http", "https"].contains(u.scheme ?? "")
    }

    nonisolated static func resolve(_ text: String) -> Values {
        let kv = parse(text)
        var v = Values()
        if let h = kv["ALEXUS_HOST"], validHost(h) { v.alexusHost = h }
        if let u = kv["ALEXUS_USER"], validUser(u) { v.alexusUser = u }
        if let t = kv["ALEXUS_TAILSCALE"], validHost(t) { v.alexusTailscale = t }
        if var o = kv["OLLAMA_URL"] {
            while o.hasSuffix("/") { o.removeLast() }
            if validURL(o) { v.ollamaURL = o }
        }
        if var h = kv["HA_URL"] {
            while h.hasSuffix("/") { h.removeLast() }
            if validURL(h) { v.homeAssistantURL = h }
        }
        if let n = kv["OWNER_NAME"], validName(n) { v.ownerName = n }
        if let m = kv["MY_NAMES"] {
            v.myNames = m.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count <= 80 }
        }
        if var u = kv["VAULT_URL"] {
            while u.hasSuffix("/") { u.removeLast() }
            if validURL(u) { v.vaultURL = u }
        }
        return v
    }
}

/// Central path resolver so Ragnarok.app works as a self-contained app bundle while still finding live checkouts.
enum AppPaths {
    nonisolated static let home = NSHomeDirectory()

    /// The live Heimdall source directory (checks HEIMDALL_REPO, monorepo app/heimdall, then ~/Developer/heimdall).
    nonisolated static let heimdallRepo: String = {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["HEIMDALL_REPO"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty, fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        }
        let candidates = [
            home + "/Developer/ragnarok/app/heimdall",
            home + "/Developer/heimdall"
        ]
        for c in candidates where fm.fileExists(atPath: c) {
            return URL(fileURLWithPath: c).resolvingSymlinksInPath().path
        }
        return home + "/Developer/ragnarok/app/heimdall"
    }()

    /// Default working folder for new agent runs and Room tasks.
    nonisolated static let defaultWorkFolder: String = {
        let fm = FileManager.default
        for c in [home + "/Developer/ragnarok", home + "/Developer"] where fm.fileExists(atPath: c) {
            return c
        }
        return home
    }()

    /// Prefer the script bundled inside Ragnarok.app/Contents/Resources/bin/<name>, falling back to the repo's bin/<name>.
    nonisolated static func bundledBin(_ name: String) -> String {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path,
           fm.fileExists(atPath: bundled) {
            return bundled
        }
        let repoPath = heimdallRepo + "/bin/" + name
        if fm.fileExists(atPath: repoPath) { return repoPath }
        return home + "/Developer/heimdall/bin/" + name
    }

    /// Prefer the live repo's bin/<name> for git/worktree-mutating tools (heimdall-edit, ragnarok-heal, ragnarok-bundle),
    /// falling back to the app bundle's copy if the repo isn't checked out at the default path.
    nonisolated static func repoBin(_ name: String) -> String {
        let fm = FileManager.default
        let repoPath = heimdallRepo + "/bin/" + name
        if fm.fileExists(atPath: repoPath) { return repoPath }
        let legacyPath = home + "/Developer/heimdall/bin/" + name
        if fm.fileExists(atPath: legacyPath) { return legacyPath }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path,
           fm.fileExists(atPath: bundled) {
            return bundled
        }
        return repoPath
    }

    /// Resolve alexus-core's fido-auth.sh from monorepo, legacy symlink, or bundled Resources/alexus-core/bin.
    nonisolated static let fidoScript: String = {
        let fm = FileManager.default
        var candidates = [
            home + "/Developer/ragnarok/agents/alexus-core/bin/fido-auth.sh",
            home + "/Developer/alexus-core/bin/fido-auth.sh"
        ]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("alexus-core/bin/fido-auth.sh").path {
            candidates.append(bundled)
        }
        for c in candidates where fm.fileExists(atPath: c) { return c }
        return candidates[0]
    }()

    /// Resolve the recall scripts directory.
    nonisolated static let recallScriptsDir: String = {
        let fm = FileManager.default
        for c in [home + "/Developer/scripts/recall", home + "/Developer/ragnarok/scripts/recall"] where fm.fileExists(atPath: c) {
            return URL(fileURLWithPath: c).resolvingSymlinksInPath().path
        }
        return home + "/Developer/scripts/recall"
    }()

    /// True if `path` refers to the Heimdall app folder itself (resolving symlinks and case).
    nonisolated static func isHeimdallRepo(_ path: String) -> Bool {
        let canon = URL(fileURLWithPath: path).resolvingSymlinksInPath().path.lowercased()
        let repoCanon = URL(fileURLWithPath: heimdallRepo).resolvingSymlinksInPath().path.lowercased()
        let legacyCanon = URL(fileURLWithPath: home + "/Developer/heimdall").resolvingSymlinksInPath().path.lowercased()
        return canon == repoCanon || canon == legacyCanon || path.lowercased() == (home + "/Developer/heimdall").lowercased()
    }
}

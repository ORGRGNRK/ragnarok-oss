import Foundation
import SwiftUI

/// Models for the Alexus chat: what Ollama on Alexus already has, what its graphics card can hold,
/// and pulling a new one that fits. Sizes come from the Ollama registry (real layer sizes), not guesses.
/// Card check (over ssh as ALEXUS_USER): nvidia-smi when the NVIDIA driver is in; without it Ollama runs on the
/// CPU, so the budget is free RAM and the card is reported as not in use.
@MainActor
final class Models: ObservableObject {
    struct Local: Hashable { let name: String; let size: Int64 }
    struct Candidate: Hashable { let name: String; let size: Int64 }

    @Published var local: [Local] = []
    @Published var hardware = "Checking Alexus's graphics card…"
    @Published var budget: Int64 = 0                 // largest model (bytes) that fits where Ollama runs
    @Published var candidates: [Candidate] = []      // fit the budget and not downloaded yet
    @Published var pulling: String?
    @Published var progress = ""

    /// Well-known chat models to offer; each is checked against the registry, missing ones are dropped.
    nonisolated static let wanted = ["llama3.2:3b", "llama3.1:8b", "qwen3:4b", "qwen3:8b", "qwen3:14b", "qwen2.5:7b", "qwen2.5:14b",
                         "gemma3:4b", "gemma3:12b", "mistral:7b", "mistral-nemo:12b", "phi4:14b", "deepseek-r1:8b",
                         "deepseek-r1:14b", "llava:7b"]
    /// Published video memory of cards we may meet, used only while the NVIDIA driver is missing.
    nonisolated static let cardSpecGB: [String: Int] = ["GTX 1080 Ti": 11, "GTX 1080": 8, "GTX 1070": 8, "GTX 1060": 6,
                                                        "RTX 3060": 12, "RTX 3080": 10, "RTX 3090": 24, "RTX 4090": 24]
    nonisolated static let host = (ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? LocalConfig.current.ollama)

    nonisolated static func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }

    func refresh() {
        Task.detached {
            // 1. downloaded models
            let (_, tags, _) = Gate.run("/usr/bin/curl", ["-sS", "-m", "10", Self.host + "/api/tags"])
            let models = ((try? JSONSerialization.jsonObject(with: Data(tags.utf8))) as? [String: Any])?["models"] as? [[String: Any]] ?? []
            let local = models.compactMap { m -> Local? in
                guard let n = m["name"] as? String else { return nil }
                return Local(name: n, size: (m["size"] as? NSNumber)?.int64Value ?? 0)
            }.filter { !$0.name.contains("embed") }.sorted { $0.name < $1.name }

            // 2. hardware where Ollama runs
            let probe = #"nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits 2>/dev/null || echo "NODRIVER|$(lspci | grep -iE 'vga|3d' | head -1 | sed 's/.*: //')|$(awk '/MemAvailable/{print $2}' /proc/meminfo)""#
            let (code, hw, err) = Gate.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", LocalConfig.current.ssh, probe])
            var budget: Int64 = 0, text: String
            let line = hw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
            if code != 0 || line.isEmpty {
                text = "Couldn't check Alexus's graphics card: \(err.oneLine(120))"
            } else if line.hasPrefix("NODRIVER|") {
                let p = line.components(separatedBy: "|")
                let card = p.count > 1 ? p[1] : "graphics card"
                let freeKB = Int64(p.count > 2 ? p[2] : "") ?? 0
                if let specGB = Self.cardSpecGB.first(where: { card.contains($0.key) })?.value {
                    // driver missing, so video memory can't be measured: use the card's published size
                    budget = max(0, Int64(specGB) * 1_073_741_824 - 1200 * 1_048_576)
                    text = "Alexus's graphics card (\(card)) isn't being used yet because its driver isn't installed, so chats run slower on the main processor. Models up to \(Self.gb(budget)) will fit on the card once it's set up."
                } else {
                    budget = Int64(Double(freeKB * 1024) * 0.7)  // unknown card: what actually runs it today is the CPU
                    text = "Alexus's graphics card (\(card)) isn't being used, so chats run on the main processor. Models up to \(Self.gb(budget)) will fit in its memory."
                }
            } else {
                let p = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let totalMiB = Int64(p.count > 1 ? p[1] : "") ?? 0
                budget = max(0, (totalMiB - 1200) * 1_048_576)  // ~1.2 GB headroom for context and the CUDA runtime
                text = "Alexus's graphics card: \(p.first ?? "GPU") with \(totalMiB / 1024) GB. Models up to \(Self.gb(budget)) fit on it."
            }

            // 3. registry sizes for the wanted list, in parallel
            let have = Set(local.map { $0.name })
            let sizes = await withTaskGroup(of: Candidate?.self) { group in
                for w in Self.wanted where !have.contains(w) {
                    group.addTask {
                        let parts = w.split(separator: ":"); guard parts.count == 2 else { return nil }
                        let (_, out, _) = Gate.run("/usr/bin/curl", ["-sS", "-m", "10", "-H", "Accept: application/vnd.docker.distribution.manifest.v2+json",
                                                                    "https://registry.ollama.ai/v2/library/\(parts[0])/manifests/\(parts[1])"])
                        guard let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                              let layers = d["layers"] as? [[String: Any]] else { return nil }
                        return Candidate(name: w, size: layers.reduce(0) { $0 + ((($1["size"] as? NSNumber)?.int64Value) ?? 0) })
                    }
                }
                var r: [Candidate] = []
                for await c in group { if let c { r.append(c) } }
                return r
            }
            let fits = sizes.filter { budget > 0 && $0.size <= budget }.sorted { $0.size > $1.size }
            let (t, b) = (text, budget)
            await MainActor.run { self.local = local; self.hardware = t; self.budget = b; self.candidates = fits }
        }
    }

    /// Pull onto Alexus with live progress, then refresh the lists.
    func pull(_ name: String) {
        guard pulling == nil else { return }
        pulling = name; progress = "Starting download…"
        Task {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-sS", "-N", "-H", "Content-Type: application/json", "-d", #"{"model":"\#(name)","stream":true}"#, Self.host + "/api/pull"]
            let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
            var last = ""
            do {
                try p.run()
                for await line in FileHandleLines.lines(from: o.fileHandleForReading) {
                    guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if let e = d["error"] as? String { last = "error: \(e)"; progress = last; continue }
                    let status = d["status"] as? String ?? ""
                    if let total = (d["total"] as? NSNumber)?.doubleValue, total > 0, let done = (d["completed"] as? NSNumber)?.doubleValue {
                        progress = "\(status) \(Int(done / total * 100))% of \(Self.gb(Int64(total)))"
                    } else { progress = status }
                    last = status
                }
                p.waitUntilExit()
            } catch { AppLog.error("model-download", error, context: name); last = "error: \(error.localizedDescription)" }
            progress = last == "success" ? "\(name) is downloaded and ready" : "Download of \(name) stopped: \(last)"
            ChatModel.write("models", "seal", progress)   // shows in the timeline
            pulling = nil
            refresh()
        }
    }
}

import Foundation
import SwiftUI

/// Loads local and server models for agent runners (Ollama on Alexus, local Ollama, LM Studio).
@MainActor
final class LocalModelLoader: ObservableObject {
    struct Model: Identifiable, Hashable {
        let slug: String
        let label: String
        var id: String { slug }
    }

    @Published private(set) var alexusModels: [Model] = []
    @Published private(set) var localOllamaModels: [Model] = []
    @Published private(set) var lmStudioModels: [Model] = []
    @Published private(set) var isLoading = false
    @Published private(set) var status = ""

    static let fallbackAlexus: [Model] = [
        Model(slug: "qwen2.5-coder:7b", label: "Qwen 2.5 Coder (7B)"),
        Model(slug: "qwen2.5-coder:3b", label: "Qwen 2.5 Coder (3B)"),
        Model(slug: "llama3.2:3b", label: "Llama 3.2 (3B)"),
        Model(slug: "qwen2.5vl:3b", label: "Qwen 2.5 VL (3B)")
    ]

    static let fallbackOllama: [Model] = [
        Model(slug: "llama3.3", label: "Llama 3.3"),
        Model(slug: "qwen2.5-coder", label: "Qwen 2.5 Coder"),
        Model(slug: "deepseek-r1", label: "DeepSeek R1")
    ]

    static let fallbackLMStudio: [Model] = [
        Model(slug: "", label: "Default (Active Model)")
    ]

    func refresh(provider: String) {
        switch provider {
        case "alexus":
            refreshAlexus()
        case "ollama":
            refreshLocalOllama()
        case "lmstudio":
            refreshLMStudio()
        default:
            break
        }
    }

    func refreshAlexus() {
        let endpoint = LocalConfig.current.ollama
        guard !isLoading else { return }
        isLoading = true
        status = "Loading models from Alexus (\(endpoint))…"
        Task.detached(priority: .utility) {
            let models = Self.fetchOllama(base: endpoint)
            await MainActor.run {
                self.isLoading = false
                if let models, !models.isEmpty {
                    self.alexusModels = models
                    self.status = "Loaded \(models.count) model\(models.count == 1 ? "" : "s") from Alexus server."
                } else {
                    self.alexusModels = Self.fallbackAlexus
                    self.status = "Couldn't reach Alexus at \(endpoint). Showing fallback models."
                }
            }
        }
    }

    func refreshLocalOllama() {
        guard !isLoading else { return }
        isLoading = true
        status = "Checking local Ollama on this Mac…"
        Task.detached(priority: .utility) {
            let models = Self.fetchOllama(base: "http://127.0.0.1:11434")
            await MainActor.run {
                self.isLoading = false
                if let models, !models.isEmpty {
                    self.localOllamaModels = models
                    self.status = "Loaded \(models.count) model\(models.count == 1 ? "" : "s") from local Ollama."
                } else {
                    self.localOllamaModels = Self.fallbackOllama
                    self.status = "Local Ollama not responding on port 11434. Showing standard models."
                }
            }
        }
    }

    func refreshLMStudio() {
        guard !isLoading else { return }
        isLoading = true
        status = "Checking LM Studio models…"
        Task.detached(priority: .utility) {
            var list: [Model] = []
            let (code, out, _) = Gate.run("/usr/bin/curl", ["-sS", "-m", "3", "http://127.0.0.1:1234/v1/models"])
            if code == 0, let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
               let data = d["data"] as? [[String: Any]] {
                let ids = data.compactMap { $0["id"] as? String }.filter { !$0.contains("embed") }.sorted()
                list = ids.map { Model(slug: $0, label: $0) }
            }
            if list.isEmpty {
                let disk = ((try? FileManager.default.contentsOfDirectory(atPath: LocalModels.lmDisk)) ?? []).flatMap { pub in
                    ((try? FileManager.default.contentsOfDirectory(atPath: LocalModels.lmDisk + "/" + pub)) ?? [])
                        .filter { !$0.hasPrefix(".") }
                        .map { "\(pub)/\($0)" }
                }.sorted()
                list = disk.map { Model(slug: $0, label: $0) }
            }
            let models = list
            await MainActor.run {
                self.isLoading = false
                if !models.isEmpty {
                    self.lmStudioModels = models
                    self.status = "Found \(models.count) LM Studio model\(models.count == 1 ? "" : "s")."
                } else {
                    self.lmStudioModels = Self.fallbackLMStudio
                    self.status = "No active LM Studio model found."
                }
            }
        }
    }

    nonisolated private static func fetchOllama(base: String) -> [Model]? {
        let b = LocalModels.base(base)
        let (code, out, _) = Gate.run("/usr/bin/curl", ["-sS", "-m", "4", b + "/api/tags"])
        guard code == 0, let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let models = d["models"] as? [[String: Any]] else {
            return nil
        }
        let slugs = models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
            .filter { !$0.contains("embed") }
            .sorted()
        guard !slugs.isEmpty else { return nil }
        return slugs.map { slug in
            let label = Self.friendlyLabel(slug)
            return Model(slug: slug, label: label)
        }
    }

    nonisolated private static func friendlyLabel(_ slug: String) -> String {
        switch slug {
        case "qwen2.5-coder:7b": return "Qwen 2.5 Coder (7B)"
        case "qwen2.5-coder:3b": return "Qwen 2.5 Coder (3B)"
        case "llama3.2:3b": return "Llama 3.2 (3B)"
        case "qwen2.5vl:3b": return "Qwen 2.5 VL (3B)"
        default: return slug
        }
    }
}

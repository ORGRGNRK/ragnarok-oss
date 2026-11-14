import Foundation
import MLXLMCommon
import Tokenizers

// mlx-swift-lm 3.x no longer bundles a tokenizer or downloader. It defines the
// `MLXLMCommon.TokenizerLoader` / `MLXLMCommon.Tokenizer` / `MLXLMCommon.Downloader`
// protocols and lets the app plug in implementations. This file provides:
//
//  * `TransformersTokenizerLoader` — loads tokenizer.json / tokenizer_config.json
//    (including the Jinja chat template) from the local model folder using
//    huggingface/swift-transformers. Equivalent to what the optional
//    `#huggingFaceTokenizerLoader()` macro in MLXHuggingFace expands to, written out
//    by hand so we need neither swift-syntax macros nor the HuggingFace Hub client.
//  * `OfflineDownloader` — a Downloader that refuses to download. The app only ever
//    passes a `ModelConfiguration(directory:)`, for which mlx-swift-lm never calls the
//    downloader; this guarantees no network access even if that ever changed.

struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream)
    }
}

struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers names this `decode(tokens:)`; mlx-swift-lm uses `decode(tokenIds:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

struct OfflineDownloader: MLXLMCommon.Downloader {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        throw LocalModelError.networkDisabled(id)
    }
}

enum LocalModelError: LocalizedError {
    case networkDisabled(String)
    case directoryNotFound(String)
    case notADirectory(String)
    case missingFiles(path: String, files: [String])
    case noWeights(String)

    var errorDescription: String? {
        switch self {
        case .networkDisabled(let id):
            return "LocalAI never downloads models (requested '\(id)'). Point Settings at a local MLX model folder."
        case .directoryNotFound(let path):
            return """
                Model directory not found:
                \(path)

                Open Settings (⌘,) and set "Model directory" to a local MLX-format model folder \
                (it must contain config.json, tokenizer.json, tokenizer_config.json and *.safetensors).
                """
        case .notADirectory(let path):
            return "The model path points to a file, not a folder:\n\(path)\n\nChoose the model's folder in Settings (⌘,)."
        case .missingFiles(let path, let files):
            return """
                The model folder is missing required files: \(files.joined(separator: ", "))
                \(path)

                Make sure this is an MLX-format model (e.g. from LM Studio's MLX downloads or mlx-community).
                """
        case .noWeights(let path):
            return "No *.safetensors weight files found in:\n\(path)\n\nMake sure the model finished downloading and is in MLX format (not GGUF)."
        }
    }
}

/// Facts about a model folder gathered before handing it to MLX.
struct ModelDirectoryInfo {
    var url: URL
    var weightBytes: Int64
    var modelType: String?

    var displayName: String { url.lastPathComponent }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: weightBytes, countStyle: .file)
    }
}

enum ModelLocator {
    static func validate(_ url: URL) throws -> ModelDirectoryInfo {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw LocalModelError.directoryNotFound(url.path)
        }
        guard isDir.boolValue else {
            throw LocalModelError.notADirectory(url.path)
        }

        let required = ["config.json", "tokenizer.json", "tokenizer_config.json"]
        let missing = required.filter {
            !fm.fileExists(atPath: url.appendingPathComponent($0).path)
        }
        if !missing.isEmpty {
            throw LocalModelError.missingFiles(path: url.path, files: missing)
        }

        let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let weights = contents.filter { $0.hasSuffix(".safetensors") }
        if weights.isEmpty {
            throw LocalModelError.noWeights(url.path)
        }
        var bytes: Int64 = 0
        for name in weights {
            let attrs = try? fm.attributesOfItem(atPath: url.appendingPathComponent(name).path)
            if let size = attrs?[.size] as? NSNumber {
                bytes += size.int64Value
            }
        }

        var modelType: String?
        if let data = try? Data(contentsOf: url.appendingPathComponent("config.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            modelType = json["model_type"] as? String
        }

        return ModelDirectoryInfo(url: url, weightBytes: bytes, modelType: modelType)
    }
}

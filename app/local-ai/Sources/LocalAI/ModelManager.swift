import Foundation
import MLX
import MLXLLM
import MLXLMCommon

enum ModelLoadState: Equatable {
    case idle
    case loading(stage: String, fraction: Double)
    case loaded(name: String, detail: String)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// Owns the MLX `ModelContainer` and its load lifecycle.
@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var state: ModelLoadState = .idle
    @Published private(set) var loadedModelURL: URL?

    /// The loaded model (nil until loading succeeds).
    private(set) var container: ModelContainer?

    private var progressTicker: Task<Void, Never>?

    var isReady: Bool { container != nil }

    // MARK: - One-time MLX setup

    /// Must run before any other MLX call (it may set the metallib override path).
    static func configureMLX() {
        // Point MLX at the compiled Metal shader library inside our .app.
        // MLX would also find it on its own via NSBundle.allBundles (it looks for
        // <resources>/mlx-swift_Cmlx.bundle/<resources>/default.metallib), but setting it
        // explicitly makes the hand-assembled bundle deterministic. When run from
        // Xcode/DerivedData none of these exist and MLX's automatic lookup is used.
        if let resources = Bundle.main.resourceURL {
            let candidates = [
                resources.appendingPathComponent(
                    "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
                resources.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib"),
                resources.appendingPathComponent("mlx.metallib"),
            ]
            if let found = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) {
                GPU.metallib = found
            }
        }

        // 8 GB unified memory: keep MLX's buffer cache small so the ~4.3 GB of
        // 4-bit 7B weights + KV cache leave room for macOS and the UI.
        Memory.cacheLimit = 512 * 1024 * 1024
    }

    // MARK: - Local model discovery (the "get models" for the MLX backend)

    /// MLX model folders (config.json + *.safetensors) in LM Studio's model dirs,
    /// as `~/...` paths. Looks at most two levels deep (<publisher>/<model>).
    nonisolated static func discoverLocalModels() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".lmstudio/models"),
            home.appendingPathComponent(".cache/lm-studio/models"),
        ]
        func isModel(_ url: URL) -> Bool {
            guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path),
                let items = try? fm.contentsOfDirectory(atPath: url.path)
            else { return false }
            return items.contains { $0.hasSuffix(".safetensors") }
        }
        var found: [String] = []
        for root in roots {
            guard let publishers = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for publisher in publishers {
                if isModel(publisher) { found.append(AppSettings.abbreviatedPath(publisher)); continue }
                guard let models = try? fm.contentsOfDirectory(
                    at: publisher, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                else { continue }
                for model in models where isModel(model) {
                    found.append(AppSettings.abbreviatedPath(model))
                }
            }
        }
        return Array(Set(found)).sorted()
    }

    // MARK: - Loading

    func loadIfNeeded(path: String) {
        guard container == nil, !state.isLoading else { return }
        if case .failed = state { return }  // don't retry automatically; user clicks Retry
        load(path: path)
    }

    func load(path: String) {
        guard !state.isLoading else { return }
        Task { await performLoad(path: path) }
    }

    private func performLoad(path: String) async {
        // Release any previously loaded model first — two 7B models won't fit in 8 GB.
        container = nil
        loadedModelURL = nil
        Memory.clearCache()

        let url = AppSettings.resolvedURL(forPath: path)
        state = .loading(stage: "Checking \(AppSettings.abbreviatedPath(url))…", fraction: 0.02)

        let info: ModelDirectoryInfo
        do {
            info = try ModelLocator.validate(url)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        // Qwen chat models end turns with <|im_end|>; make sure it always stops
        // generation even if generation_config.json is absent from the folder.
        var extraEOS: Set<String> = []
        if let type = info.modelType?.lowercased(), type.hasPrefix("qwen") {
            extraEOS = ["<|im_end|>", "<|endoftext|>"]
        }
        let configuration = ModelConfiguration(directory: url, extraEOSTokens: extraEOS)

        let start = Date()
        startProgressTicker(info: info, start: start)

        do {
            // A `.directory` configuration is resolved locally; the downloader is never
            // consulted (OfflineDownloader would throw if it were).
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: OfflineDownloader(),
                using: TransformersTokenizerLoader(),
                configuration: configuration
            ) { _ in }

            stopProgressTicker()
            container = loaded
            loadedModelURL = url
            let seconds = Date().timeIntervalSince(start)
            let memory = ByteCountFormatter.string(
                fromByteCount: Int64(Memory.activeMemory), countStyle: .memory)
            state = .loaded(
                name: info.displayName,
                detail: String(format: "loaded in %.1fs · %@ in use", seconds, memory))
        } catch {
            stopProgressTicker()
            container = nil
            state = .failed(
                "Failed to load model at \(url.path):\n\(error.localizedDescription)")
        }
    }

    /// MLX doesn't report weight-loading progress for local folders, so show an
    /// estimate based on the weight size (it fills asymptotically and completes when
    /// loading really finishes).
    private func startProgressTicker(info: ModelDirectoryInfo, start: Date) {
        stopProgressTicker()
        // Rough guess: ~1 GB/s from SSD into unified memory, minimum 3 s.
        let expected = Swift.max(3.0, Double(info.weightBytes) / 1_000_000_000.0)
        let sizeText = info.formattedSize
        let name = info.displayName
        state = .loading(stage: "Loading \(name) (\(sizeText))…", fraction: 0.05)

        progressTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled, self.state.isLoading else { return }
                let elapsed = Date().timeIntervalSince(start)
                // 0.05 → ~0.95, half way at `expected` seconds.
                let fraction = 0.05 + 0.9 * (elapsed / (elapsed + expected))
                self.state = .loading(
                    stage: "Loading \(name) (\(sizeText)) — weights & tokenizer… \(Int(elapsed))s",
                    fraction: fraction)
            }
        }
    }

    private func stopProgressTicker() {
        progressTicker?.cancel()
        progressTicker = nil
    }
}

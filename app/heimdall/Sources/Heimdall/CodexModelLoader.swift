import Foundation
import SwiftUI

/// Loads the model catalog from the signed-in Codex CLI, separately from API-key-backed CloudChat providers.
/// Only slugs and display names leave this process; the CLI's raw catalog can also contain prompt instructions.
@MainActor
final class CodexModelLoader: ObservableObject {
    struct Model: Decodable, Identifiable, Hashable {
        let slug: String
        let displayName: String
        let visibility: String
        var id: String { slug }
        var label: String { displayName.isEmpty ? slug : displayName }

        enum CodingKeys: String, CodingKey { case slug, displayName, visibility }
    }

    private struct Catalog: Decodable { let models: [Model] }

    @Published private(set) var models: [Model] = []
    @Published private(set) var isLoading = false
    @Published private(set) var status = "Load models from your Codex account."

    func refresh() {
        guard !isLoading else { return }
        guard let codex = LoginPath.which("codex") else {
            status = "Codex CLI isn't installed or isn't on the app's PATH."
            return
        }
        isLoading = true
        status = "Loading Codex models…"
        Task.detached(priority: .utility) {
            let (code, output) = HubModel.run(codex, ["debug", "models"], timeout: 45)
            let catalog = Self.decode(output)
            await MainActor.run {
                self.isLoading = false
                guard code == 0, let catalog else {
                    self.status = code == 124 ? "Loading Codex models timed out." : "Couldn't load the Codex model list. Check Codex sign-in and try again."
                    return
                }
                self.models = catalog.models
                    .filter { $0.visibility == "list" && !$0.slug.isEmpty }
                    .sorted { $0.slug.localizedStandardCompare($1.slug) == .orderedAscending }
                self.status = self.models.isEmpty
                    ? "Codex returned no selectable models."
                    : "Loaded \(self.models.count) model\(self.models.count == 1 ? "" : "s") from Codex."
            }
        }
    }

    nonisolated private static func decode(_ output: String) -> Catalog? {
        // The CLI may print a warning before its JSON catalog. Parse one JSON line and discard every field
        // except the typed model identifiers/display names needed by the picker.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard line.first == "{" else { continue }
            if let result = try? decoder.decode(Catalog.self, from: Data(line.utf8)) { return result }
        }
        return nil
    }
}

import Foundation
import SwiftData

/// The app's history database and the `save_record` target.
/// Stored at ~/Library/Application Support/CLI Tools/history.store.
@MainActor
final class HistoryStore: RecordStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    nonisolated static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("CLI Tools/history.store")
    }

    /// `inMemory` is for debug snapshots and `url` for tests, so they never touch the real history.
    init(inMemory: Bool = false, url: URL = HistoryStore.defaultURL) {
        let schema = Schema([Lookup.self, CommandRun.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: url)
        }
        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Couldn't open the history database: \(error)")
        }
    }

    func save(record type: String, parent: String?, fields: [String: String]) throws -> String {
        switch type {
        case "lookup":
            let lookup = Lookup(
                query: fields["query"] ?? "",
                modelResponse: fields["model_response"] ?? "",
                modelFirstLine: fields["model_first_line"] ?? "",
                verification: fields["verification"] ?? ""
            )
            context.insert(lookup)
            try context.save()
            return lookup.id.uuidString

        case "command_run":
            guard let parent, let id = UUID(uuidString: parent),
                  let lookup = try context.fetch(FetchDescriptor<Lookup>(predicate: #Predicate { $0.id == id })).first
            else { throw RecordError.missingParent(parent ?? "") }
            let result = fields["result"].flatMap { $0.isEmpty ? nil : $0 }
            let run = CommandRun(command: fields["command"] ?? "", verification: fields["verification"] ?? "", result: result)
            context.insert(run)
            run.lookup = lookup
            try context.save()
            return run.id.uuidString

        default:
            throw RecordError.unknownType(type)
        }
    }

    enum RecordError: LocalizedError {
        case unknownType(String)
        case missingParent(String)

        var errorDescription: String? {
            switch self {
            case .unknownType(let t): "Unknown record type “\(t)”. Use “lookup” or “command_run”."
            case .missingParent(let p): "No saved lookup with ID “\(p)” to attach this command to."
            }
        }
    }
}

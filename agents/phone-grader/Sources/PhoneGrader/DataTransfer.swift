import SwiftUI
import UniformTypeIdentifiers
import PhoneGraderCore
#if os(macOS)
import AppKit
#endif

// Moving data between the Mac and iPhone/iPad by hand (AirDrop / Files / share sheet).
// No sync: export a file on one device, import it on the other.
//
// history.json is exported byte-for-byte (the same JSON the Mac app keeps in
// ~/Library/Application Support/PhoneGrader). Import MERGES into the local history:
//   • same record # and same created time  → the imported copy replaces the local one
//   • same record # but a different phone   → added under a new record #
//   • new record #                          → added
// A backup of the local history.json is written next to it before every import.
// Photos are not included in the export (records keep their text, grade, prices and sale data).

struct HistoryImportResult {
    var added = 0, updated = 0, renumbered = 0
    var backup: URL?
    var summary: String {
        "Imported: \(added) added, \(updated) updated, \(renumbered) added under a new record #."
            + (backup.map { " Previous history backed up as \($0.lastPathComponent)." } ?? "")
    }
}

extension HistoryStore {
    func importMerging(_ data: Data) throws -> HistoryImportResult {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let incoming = try dec.decode([HistoryRecord].self, from: data)
        load()
        var res = HistoryImportResult()
        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.history.path) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let b = Paths.support.appendingPathComponent("history.json.bak-import-\(f.string(from: Date()))")
            try fm.copyItem(at: Paths.history, to: b)
            res.backup = b
        }
        var all = records
        var next = (Set(all.map(\.id)).union(incoming.map(\.id)).max() ?? 0) + 1
        let photoExists = { (n: String) in fm.fileExists(atPath: Paths.photos.appendingPathComponent(n).path) }
        for var r in incoming {
            if let i = all.firstIndex(where: { $0.id == r.id }) {
                if abs(all[i].createdAt.timeIntervalSince(r.createdAt)) < 1 {
                    let local = all[i].photoFiles
                    r.photoFiles = r.photoFiles.filter(photoExists)
                    if r.photoFiles.isEmpty { r.photoFiles = local }
                    all[i] = r; res.updated += 1
                } else {
                    r.id = next; next += 1; r.photoFiles = []
                    all.append(r); res.renumbered += 1
                }
            } else {
                r.photoFiles = r.photoFiles.filter(photoExists)
                all.append(r); res.added += 1
            }
        }
        replaceAll(all.sorted { $0.createdAt > $1.createdAt })
        return res
    }
}

/// Lazily-written export files for ShareLink (share sheet on iOS, share menu on the Mac).
struct HistoryExportFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { _ in
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("phonegrader-history-\(f.string(from: Date())).json")
            try? FileManager.default.removeItem(at: u)
            if FileManager.default.fileExists(atPath: Paths.history.path) {
                try FileManager.default.copyItem(at: Paths.history, to: u)
            } else {
                try Data("[]".utf8).write(to: u)
            }
            return SentTransferredFile(u)
        }
    }
}

/// The Atlas price list currently in use (imported one if present, else the bundled one).
struct PriceListExportFile: Transferable {
    static var current: URL? {
        FileManager.default.fileExists(atPath: Paths.importedLadder.path) ? Paths.importedLadder : Paths.bundled("atlas-ladder", "json")
    }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { _ in
            guard let src = PriceListExportFile.current else { throw CocoaError(.fileNoSuchFile) }
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-ladder.json")
            try? FileManager.default.removeItem(at: u)
            try FileManager.default.copyItem(at: src, to: u)
            return SentTransferredFile(u)
        }
    }
}

/// Settings → Data. Same section on the Mac and on iPhone/iPad.
struct DataTransferSection: View {
    @EnvironmentObject var state: AppState
    enum Mode { case history, priceList }
    @State private var mode: Mode = .history
    @State private var importing = false
    @State private var message = ""

    var body: some View {
        Section("Data — move between Mac and iPhone/iPad (no sync)") {
            ShareLink(item: HistoryExportFile(), preview: SharePreview("PhoneGrader history.json")) {
                Label("Export history (history.json)…", systemImage: "square.and.arrow.up")
            }
            Button { mode = .history; importing = true } label: {
                Label("Import history.json (merge)…", systemImage: "square.and.arrow.down")
            }
            ShareLink(item: PriceListExportFile(), preview: SharePreview("atlas-ladder.json")) {
                Label("Export price list in use (atlas-ladder.json)…", systemImage: "square.and.arrow.up")
            }
            Button { mode = .priceList; importing = true } label: {
                Label("Import price list (atlas-ladder.json)…", systemImage: "square.and.arrow.down")
            }
            #if os(macOS)
            Button("Show data folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.history]) }
            #endif
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            Text("Export on one device, AirDrop or save to Files, import on the other. Import merges by record # (a backup is kept). Photos, parts log and settings/keys are not included.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .failure(let e): message = e.localizedDescription
            case .success(let u):
                do {
                    switch mode {
                    case .history:
                        let d = try withSecurityScope(u) { try Data(contentsOf: u) }
                        message = try state.history.importMerging(d).summary
                    case .priceList:
                        let l = try withSecurityScope(u) { try state.importLadder(from: u) }
                        message = "Imported \(l.rows.count) price rows, delivery Friday \(l.deliveryFriday)."
                    }
                } catch { message = "Import refused: \(error.localizedDescription) (nothing changed)" }
            }
        }
    }
}

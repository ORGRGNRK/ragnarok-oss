import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PhoneGraderCore

enum Paths {
    static var support: URL {
        let u = dataOverride.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhoneGrader", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var photos: URL {
        let u = support.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// PHONEGRADER_DATA_DIR points history, notes and (in that mode) the parts log at another folder — used by tests / the MCP smoke tests.
    static var dataOverride: String? {
        guard let raw = getenv("PHONEGRADER_DATA_DIR") else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
    static var businessNotes: URL { support.appendingPathComponent("business-notes.json") }
    static var history: URL { support.appendingPathComponent("history.json") }
    static var importedLadder: URL { support.appendingPathComponent("atlas-ladder.imported.json") }
    static var userQuotes: URL { support.appendingPathComponent("buyer-quotes.json") }

    /// Bundled resource (app: Contents/Resources; `swift run`: ./Resources).
    static func bundled(_ name: String, _ ext: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(name).\(ext)")
        return FileManager.default.fileExists(atPath: cwd.path) ? cwd : nil
    }
}

struct HistoryRecord: Codable, Identifiable, Equatable {
    var id: Int
    var createdAt: Date
    var phoneModel: String
    var storageGb: Int?
    var carrierLock: String
    var checklist: [ChecklistEntry]
    var notes: String?
    var grade: GradeResult?
    var backend: String
    var photoFiles: [String]
    var askingPrice: Int?
    /// Legacy (pre-Oct 16 buffer picker: quickFlip/needsFix). Kept so old records decode and keep it.
    var flipKind: String?
    var floor: Double?
    var floorStatus: String?
    var floorQuotable: Bool?
    var maxBuy: Double?
    var loopStatus: String?
    var listingTitle: String?
    var listingDescription: String?
    // Preserve historical remote metadata when older JSON is re-saved. Never used for new writes.
    var airtableRecordId: String?
    var airtableSyncedAt: Date?
    var gradeLogRecordId: String?
    var gradeLogSyncedAt: Date?
    /// Paid IMEI checks (SICKW) — receipt with the full raw response. Optional for older history files.
    var imeiChecks: [ImeiCheckReceipt]?
    var imei: String?
    var serial: String?
    var color: String?
    /// Full max-buy breakdown (floor, gas inputs, parts, profit, max buy). Private: never in the QR receipt.
    var dealBreakdown: DealBreakdown?
    /// Parts used on this phone (types only go into the receipt; aftermarket back glass adds a disclosure).
    var repairs: RepairParts?
    var batteryCycles: Int?
    /// Listing price history, sold price/date, purchase price, listing stats. Private. Absent on older records.
    var sale: SaleTracking?
    /// Append-only memory notes for this phone. Absent on older records.
    var notesLog: [MemoryNote]?
}

/// Business-level append-only notes log (business-notes.json next to history.json).
enum BusinessNotesStore {
    static var all: [MemoryNote] {
        guard let d = try? Data(contentsOf: Paths.businessNotes) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([MemoryNote].self, from: d)) ?? []
    }
    @discardableResult static func add(_ text: String, at: Date = Date()) throws -> [MemoryNote] {
        let n = try MemoryNotes.appending(all, text, at: at)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(n).write(to: Paths.businessNotes, options: .atomic)
        return n
    }
}

extension HistoryRecord {
    /// Only grading facts go into the QR receipt — no Atlas floor, max buy, profit, raw responses or keys.
    var receiptInput: ReceiptInput {
        ReceiptInput(recordId: id, date: createdAt, model: phoneModel, storageGb: storageGb, color: color,
                     carrier: CarrierLock(rawValue: carrierLock)?.label ?? carrierLock,
                     imei: imei ?? imeiChecks?.last?.imei, serial: serial, grade: grade, checklist: checklist,
                     sickw: imeiChecks ?? [], backend: backend.isEmpty ? nil : backend, listingPrice: askingPrice,
                     repairs: repairs ?? dealBreakdown?.parts, batteryCycles: batteryCycles)
    }
    /// The one buyer-facing fact model for this phone (Listing text, QR, share photo).
    var facts: PhoneFacts { PhoneFacts(receiptInput) }
    /// Actual profit = soldPrice − purchasePrice − partsCost − gasCost (parts/gas from the saved deal breakdown).
    var actualProfit: Double? { sale?.actualProfit(partsCost: dealBreakdown?.partsCost, gasCost: dealBreakdown?.gasCost) }
    /// Economic cash conversion cycle; parts logged against this phone give real dates and costs.
    func cashCycle(parts: [PartPurchase], now: Date = Date()) -> CashCycle {
        let linked = parts.filter { $0.recordId == id }.map { (date: $0.date, cost: $0.cost) }
        return CashCycle(recordId: id, sale: sale ?? SaleTracking(), parts: linked,
                         placeholderParts: dealBreakdown?.partsCost, gas: dealBreakdown?.gasCost, now: now)
    }
    /// A phone you actually bought or sold (graded-only phones are not in the cash cycle).
    var inCashCycle: Bool { sale.map { $0.purchasePrice != nil || $0.boughtAt != nil || $0.isSold } ?? false }
    /// Mutate sale tracking; keeps askingPrice in sync with the listing price.
    mutating func applySale(_ f: (inout SaleTracking) -> Void) {
        var s = sale ?? SaleTracking(); f(&s)
        sale = s.isEmpty ? nil : s
        if let p = s.listingPrice { askingPrice = p }
    }
    func listingText(location: String) -> (title: String, description: String) {
        facts.listing(location: location)
    }
}

/// A history.json that does not decode is kept, copied aside, and reported.
/// It is not replaced with an empty list.
enum HistoryDecode {
    static var logURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ragnarok/ragnarok-app-errors.jsonl")

    static func env(_ name: String) -> String {
        guard let raw = getenv(name) else { return "" }
        return String(cString: raw)
    }

    static func scrub(_ text: String) -> String {
        var out = text
        let patterns = [
            ("anthropic-key", #"sk-ant-[A-Za-z0-9_-]{20,}"#),
            ("openai-key", #"sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}"#),
            ("xai-key", #"xai-[A-Za-z0-9]{20,}"#),
            ("bearer", #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"#),
            ("assignment", #"(?i)\b(?:password|secret|token|api_key|apikey)\s*[:=]\s*\S{6,}"#),
        ]
        for (name, pattern) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ns.length), withTemplate: "[hidden:\(name)]")
        }
        return out
    }

    static func backup(_ file: URL, _ data: Data) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = file.deletingLastPathComponent().appendingPathComponent("history.json.corrupt-\(stamp)")
        do {
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    static func writeLog(_ message: String, backup: URL?) {
        var row: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "level": "error",
            "area": "phone-grader-history",
            "message": message,
            "schema_version": 2,
            "actor": "phone-grader",
            "os_user": NSUserName(),
            "origin": "phone-grader",
            "run_id": "Unverified",
            "build": "Unverified",
        ]
        if let backup { row["backup"] = backup.path }
        guard var line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let path = logURL.path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    static func push(message: String, backup: URL?) {
        let sink = env("RAGNAROK_ERROR_SINK")
        if sink == "off" { return }
        let dev = NSHomeDirectory() + "/Developer/ragnarok/app/heimdall/bin/ragnarok-error-log"
        let script = env("RAGNAROK_ERROR_LOG").isEmpty ? dev : env("RAGNAROK_ERROR_LOG")
        guard FileManager.default.isExecutableFile(atPath: script) else { return }
        let payload: [String: Any] = [
            "source": "phone-grader", "area": "history-json", "message": message,
            "who": "phone-grader", "backup": backup?.path ?? "",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let run = {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script]
            let input = Pipe()
            p.standardInput = input
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do {
                try p.run()
                input.fileHandleForWriting.write(body)
                try? input.fileHandleForWriting.close()
                p.waitUntilExit()
            } catch {
                return
            }
        }
        if sink.hasPrefix("/") {
            run()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: run)
        }
    }
}

/// Local history: a JSON file in Application Support (the bot used SQLite; one
/// file is enough for a single-user desktop app and is trivially inspectable).
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []
    @Published private(set) var decodeError: String?
    private var blocked = false

    init() { load() }

    func load() {
        blocked = false
        decodeError = nil
        guard let d = try? Data(contentsOf: Paths.history) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        do {
            records = try dec.decode([HistoryRecord].self, from: d)
        } catch {
            blocked = true
            let copy = HistoryDecode.backup(Paths.history, d)
            let exact = HistoryDecode.scrub(String(describing: error))
            decodeError = exact
            HistoryDecode.writeLog(exact, backup: copy)
            HistoryDecode.push(message: exact, backup: copy)
        }
    }

    private func save() {
        if blocked { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(records) { try? d.write(to: Paths.history, options: .atomic) }
    }

    var saleSummary: SaleSummary {
        SaleSummary(records.compactMap { r in r.sale.map { ($0, r.dealBreakdown?.partsCost, r.dealBreakdown?.gasCost) } })
    }

    var cashCycleSummary: CashCycleSummary {
        let parts = PartsLogStore.all
        return CashCycleSummary(records.filter(\.inCashCycle).map { $0.cashCycle(parts: parts) })
    }

    var nextId: Int { load(); return (records.map(\.id).max() ?? 0) + 1 }

    func upsert(_ r: HistoryRecord) {
        load()      // the CLI and the app share history.json — merge with what's on disk first
        if blocked { return }
        if let i = records.firstIndex(where: { $0.id == r.id }) { records[i] = r } else { records.insert(r, at: 0) }
        records.sort { $0.createdAt > $1.createdAt }
        save()
    }

    /// A retry identity must reach disk before any remote write. Unlike general UI saves, errors propagate.
    func persistGradeLogIdentity(recordId: Int, identity: String) throws {
        load()
        if blocked {
            throw GradeLog.failure(decodeError ?? "History file could not be read. Nothing was sent.")
        }
        guard let index = records.firstIndex(where: { $0.id == recordId }) else {
            throw GradeLog.failure("Local history record was removed; nothing was sent.")
        }
        var updated = records
        updated[index].gradeLogRecordId = identity
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(updated).write(to: Paths.history, options: .atomic)
        records = updated
    }

    /// Used by the history import (DataTransfer.swift).
    func replaceAll(_ r: [HistoryRecord]) {
        records = r
        save()
    }

    func delete(_ r: HistoryRecord) {
        load()
        if blocked { return }
        for f in r.photoFiles { try? FileManager.default.removeItem(at: Paths.photos.appendingPathComponent(f)) }
        records.removeAll { $0.id == r.id }
        save()
    }

    func savePhotos(_ photos: [PhotoItem], id: Int) -> [String] {
        photos.enumerated().compactMap { i, p in
            let name = "\(id)-\(i + 1).jpg"
            do { try p.jpeg.write(to: Paths.photos.appendingPathComponent(name)); return name } catch { return nil }
        }
    }
}

struct PhotoItem: Identifiable, Equatable {
    let id = UUID()
    let jpeg: Data          // re-encoded JPEG (grader.js hardcodes image/jpeg)
    let thumbnail: PlatformImage
    let name: String

    #if os(macOS)
    /// Load any image file, downscale to ≤2048px long edge, re-encode as JPEG.
    static func load(url: URL) -> PhotoItem? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, 2048 / max(w, h))
        let tw = Int(w * scale), th = Int(h * scale)
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return PhotoItem(jpeg: jpeg, thumbnail: NSImage(cgImage: scaled, size: NSSize(width: tw, height: th)),
                         name: url.lastPathComponent)
    }
    #else
    static func load(url: URL) -> PhotoItem? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return load(data: d, name: url.lastPathComponent)
    }
    /// Camera / library / Files: apply EXIF orientation, downscale to ≤2048px long edge, re-encode as JPEG.
    static func load(data: Data, name: String) -> PhotoItem? {
        guard let cg = PlatformImaging.upright(data, maxPixel: 2048), let jpeg = PlatformImaging.jpeg(cg, quality: 0.85) else { return nil }
        return PhotoItem(jpeg: jpeg, thumbnail: UIImage(cgImage: cg), name: name)
    }
    #endif
}

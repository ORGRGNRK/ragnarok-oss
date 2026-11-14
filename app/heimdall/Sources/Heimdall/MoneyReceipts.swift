import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Money tab's receipt pipeline: a separate copy of ragnarok-pipe on Alexus (port 8449, its own database), made once
/// by bin/ragnarok-pipe-money-setup. Photos go up, the local vision model reads vendor/date/total, and each receipt can be
/// added to Transactions or matched to a bank transaction already there. Login: this Mac's keychain (ragnarok-pipe-money).
/// Requests go through curl (the app's own URLSession sees Alexus's LAN address as offline, see Chat.swift); the login is
/// passed on curl's stdin, never on its command line.
enum ReceiptPipe {
    nonisolated static let service = "ragnarok-pipe-money", user = "ragnarok"

    struct Receipt: Identifiable, Hashable {
        var id = 0; var uploaded = ""; var filename = ""; var status = ""; var vendor = ""
        var day: String? = nil; var cents: Int? = nil
        var possibleDup: Int? = nil; var markedDup: Int? = nil; var dateFlags: [String] = []
        var usable: Bool { (status == "ok" || status == "approved") && cents != nil && markedDup == nil }
    }

    /// Port 8449 on Alexus's Tailscale address (the app's one plain-http exception), same as the Receipts page; falls back to 8448.
    nonisolated static let defaultURL = "http://\(LocalConfig.current.alexusTailscale):8449"
    nonisolated static let fallbackURL = "http://\(LocalConfig.current.alexusTailscale):8448"
    /// The address the Receipts page uses (editable there, saved as moneyPipeURL), else the default.
    nonisolated static var base: String { WebPanel.normalize(UserDefaults.standard.string(forKey: "moneyPipeURL") ?? "") ?? defaultURL }

    nonisolated static func password() -> String? {
        for svc in [service, "ragnarok-pipe"] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", svc, "-a", user, "-w"]
            let out = Foundation.Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0 && !s.isEmpty { return s }
        }
        return nil
    }

    /// curl with the login on stdin. Returns (HTTP status or 0 if unreachable, body).
    nonisolated static func call(_ path: String, extra: [String] = [], timeout: Int = 20) -> (Int, Data) {
        guard let pw = password() else { return (-1, Data()) }
        let res = curl(base + path, pw: pw, extra: extra, timeout: timeout)
        if res.0 == 0 && base == defaultURL && fallbackURL != defaultURL {
            return curl(fallbackURL + path, pw: pw, extra: extra, timeout: timeout)
        }
        return res
    }

    nonisolated private static func curl(_ fullURL: String, pw: String, extra: [String], timeout: Int) -> (Int, Data) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-m", "\(timeout)", "-K", "-", "-w", "\n%{http_code}"] + extra + [fullURL]
        let inP = Foundation.Pipe(), out = Foundation.Pipe(); p.standardInput = inP; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (0, Data()) }
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        try? inP.fileHandleForWriting.write(contentsOf: Data("user = \"\(esc(user)):\(esc(pw))\"\n".utf8))
        try? inP.fileHandleForWriting.close()
        var d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let nl = d.lastIndex(of: UInt8(ascii: "\n")) else { return (0, d) }
        let code = Int(String(decoding: d[(nl + 1)...], as: UTF8.self)) ?? 0
        d = d[..<nl]
        return (code, Data(d))
    }

    /// /api/documents JSON → receipts. Totals may come as numbers or strings.
    nonisolated static func parse(_ data: Data) -> [Receipt]? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.map { d in
            var cents: Int?
            if let n = d["total"] as? NSNumber { cents = Int((n.doubleValue * 100).rounded()) }
            else if let s = d["total"] as? String { cents = Money.cents(s) }
            return Receipt(id: (d["id"] as? NSNumber)?.intValue ?? 0, uploaded: d["uploaded_at"] as? String ?? "",
                           filename: d["filename"] as? String ?? "", status: d["status"] as? String ?? "",
                           vendor: d["vendor"] as? String ?? "", day: (d["doc_date"] as? String).flatMap { Money.day($0) },
                           cents: cents.map(abs), possibleDup: (d["possible_duplicate_of"] as? NSNumber)?.intValue,
                           markedDup: (d["marked_duplicate_of"] as? NSNumber)?.intValue,
                           dateFlags: (d["date_flags"] as? [Any])?.map { "\($0)" } ?? [])
        }
    }

    /// A bank transaction this receipt probably is: money out of the same amount, within 3 days, not already tied to a receipt.
    nonisolated static func match(_ r: Receipt, in txns: [Money.Txn]) -> Money.Txn? {
        guard let c = r.cents, let day = r.day else { return nil }
        let lo = Money.add(day, days: -3) ?? day, hi = Money.add(day, days: 3) ?? day
        return txns.filter { $0.receiptID == nil && $0.cents == -c && $0.day >= lo && $0.day <= hi && $0.source != "receipt" }
            .min { abs(Money.days(from: day, to: $0.day) ?? 99) < abs(Money.days(from: day, to: $1.day) ?? 99) }
    }
}


/// Above the pipe's own page: receipts that aren't in Money yet. Link one to the bank transaction it matches (same amount,
/// within 3 days), or add it as a transaction (cash, or a bank file not imported yet). Uploading and fixing stay on the
/// pipe's page below, so there's one place for each.
struct ReceiptsMatchPanel: View {
    @EnvironmentObject var m: MoneyStore
    @State private var receipts: [ReceiptPipe.Receipt] = []
    @State private var status = ""
    @State private var busy = false
    /// Starts true; load() checks the keychain off the main thread and flips it to false (code -1) if no login is saved.
    /// Never call password() here: its waitUntilExit spins the run loop inside a SwiftUI graph update and aborts the app.
    @State private var setUp = true

    var body: some View {
        let todo = receipts.filter { r in r.usable && !m.txns.contains { $0.receiptID == r.id } }
        let inMoney = receipts.filter { r in m.txns.contains { $0.receiptID == r.id } }.count
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Not in your transactions yet").font(.headline)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).disabled(!setUp || busy).help("Refresh")
                if busy { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if setUp { Text("\(inMoney) linked or added · \(todo.count) to do").font(.caption).foregroundStyle(.secondary) }
            }
            if !setUp {
                Text("The Money receipt pipeline isn't set up yet. Run once in a terminal: ~/Developer/heimdall/bin/ragnarok-pipe-money-setup (it makes a separate copy of the pipe on Alexus on port 8449 and saves its login in your keychain).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Check again") { setUp = true; Task { await load() } }.controlSize(.small)
            } else if todo.isEmpty {
                Text(receipts.isEmpty ? "No receipts yet. Upload photos on the pipe's page below." : "Every finished receipt is in your transactions.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(todo) { r in
                            HStack {
                                Text(r.day ?? "—").font(.caption.monospaced()).frame(width: 82, alignment: .leading)
                                Text(r.vendor.isEmpty ? r.filename : r.vendor).lineLimit(1)
                                if r.possibleDup != nil { Text("maybe a duplicate").font(.caption2).foregroundStyle(.orange) }
                                if !r.dateFlags.isEmpty { Text("check the date").font(.caption2).foregroundStyle(.orange) }
                                Spacer()
                                Text(r.cents.map(Money.fmt) ?? "—").monospacedDigit()
                                if let t = ReceiptPipe.match(r, in: m.txns) {
                                    Button("Link to \(t.day) \(String(t.desc.prefix(22)))") { m.linkReceipt(t, r) }.controlSize(.small)
                                        .help("A bank transaction with the same amount within 3 days. Linking keeps one transaction, with the receipt attached.")
                                } else {
                                    Button("Add to transactions") { m.addFromReceipt(r) }.controlSize(.small)
                                        .help("No bank transaction with this amount yet: adds it as money out (cash, or not imported yet).")
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 170)
            }
        }
        .padding(10)
        .task { if setUp { await load(); while !Task.isCancelled { try? await Task.sleep(for: .seconds(15)); await load() } } }
    }

    private func load() async {
        busy = true
        let (code, data) = await Task.detached { ReceiptPipe.call("/api/documents?limit=500") }.value
        busy = false
        switch code {
        case 200: if let r = ReceiptPipe.parse(data) { receipts = r; status = "" } else { status = "unexpected answer from the pipe" }
        case 401: status = "the pipe refused the saved login; run the setup again"
        case -1: setUp = false
        default: status = "can't reach \(ReceiptPipe.base)" + (code > 0 ? " (HTTP \(code))" : "")
        }
    }
}

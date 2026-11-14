import SwiftUI
import SQLite3
import AppKit
import UniformTypeIdentifiers

/// The Money tab: where the money goes. Transactions (imported from bank/card CSV exports, or typed in), inventory
/// (what's owned or for sale, what it cost, what it sold for) and contacts (customers, vendors, leads).
/// Everything is in one private file on this Mac, ~/.ragnarok/money.sqlite (0600). Nothing is sent anywhere.
/// The pure parts (CSV reading, amounts, dates, categories, repeating charges, totals) are static and in the selftest.
enum Money {
    nonisolated static let path = NSHomeDirectory() + "/.ragnarok/money.sqlite"
    nonisolated static let categories = ["Income", "Food", "Groceries", "Transport", "Subscriptions", "Phone & Internet",
                                         "Housing & Bills", "Shopping", "Debt & Fees", "Business", "Transfers", "Other"]

    struct Txn: Identifiable, Hashable {
        var id = 0; var day = ""; var cents = 0; var desc = ""; var account = ""; var category = ""; var note = ""
        var contactID: Int? = nil; var itemID: Int? = nil; var source = "manual"; var debtID: Int? = nil
        var receiptID: Int? = nil   // the Money receipt pipe's id for the photo of this purchase
    }
    struct Item: Identifiable, Hashable {
        var id = 0; var name = ""; var category = ""; var status = "have"   // have · listed · sold
        var cost = 0; var ask: Int? = nil; var sold: Int? = nil; var bought: String? = nil; var soldDay: String? = nil; var note = ""
    }
    struct Contact: Identifiable, Hashable {
        var id = 0; var name = ""; var kind = "person"   // customer · vendor · lead · person
        var phone = ""; var email = ""; var note = ""; var lastContact: String? = nil
    }
    /// A debt: who it was with, who is collecting now, what they say is owed, and the dates that matter.
    struct Debt: Identifiable, Hashable {
        var id = 0; var creditor = ""; var collector = ""; var acct = ""; var balance = 0
        var status = "in collections"   // in collections · asked for proof · proven · disputed · paying · settled · paid
        var firstNotice: String? = nil  // the collector's first letter or call
        var proofAsked: String? = nil   // when you asked them in writing to prove it
        var lastPayment: String? = nil  // your last payment to anyone on this debt (the lawsuit clock usually runs from here)
        var limitYears: Int? = nil      // your state's time limit for lawsuits on this kind of debt, if you know it
        var note = ""
        // settlement: "pay this much and we call it done" (kept after it's paid, for the record)
        var offer: Int? = nil           // what they'll accept, cents
        var offerDay: String? = nil     // when they offered it
        var offerDeadline: String? = nil
        var offerFrom = ""              // "collector" · "original creditor" · ""
        var offerInWriting = false
        var offerRef = ""               // e.g. "letter dated 2026-10-28, ref 55-A"
    }
    nonisolated static let offerSources = ["", "collector", "original creditor"]
    nonisolated static let writingWarning = "Don't pay a settlement until you have it in writing saying it settles the debt in full."

    /// What a settlement saves: what's left on the debt (what they claim, less payments already made) minus the offer,
    /// and that as a whole percent of what's left. Nil with no offer or nothing left; never below zero.
    nonisolated static func savings(left: Int, offer: Int?) -> (cents: Int, percent: Int)? {
        guard let o = offer, o > 0, left > 0 else { return nil }
        let s = max(0, left - o)
        return (s, Int((Double(s) * 100 / Double(left)).rounded()))
    }
    /// Whole days from a to b (yyyy-MM-dd), negative when b is earlier.
    nonisolated static func days(from a: String, to b: String) -> Int? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        guard let x = f.date(from: a), let y = f.date(from: b) else { return nil }
        return Int((y.timeIntervalSince(x) / 86400).rounded())
    }
    /// Warnings to show next to a settlement offer, most important first. Deadline ones only while the debt is open.
    nonisolated static func offerWarnings(_ d: Debt, today: String) -> [String] {
        guard d.offer != nil else { return [] }
        var w: [String] = []
        if !d.offerInWriting { w.append(writingWarning) }
        if !["paid", "settled"].contains(d.status), let dl = d.offerDeadline, let n = days(from: today, to: dl) {
            if n < 0 { w.append("The offer's deadline (\(dl)) has passed. Ask them in writing whether it still stands before paying.") }
            else if n == 0 { w.append("The offer ends today (\(dl)).") }
            else if n <= 7 { w.append("The offer ends in \(n) day\(n == 1 ? "" : "s") (\(dl)).") }
        }
        return w
    }
    /// Open offers: on debts not yet paid or settled, whose deadline (if any) hasn't passed. Count, total of the offers,
    /// and what they'd save together. `paid` gives what's already been paid on a debt.
    nonisolated static func openOffers(_ debts: [Debt], paid: (Debt) -> Int, today: String) -> (count: Int, offers: Int, saves: Int) {
        let open = debts.filter { d in d.offer != nil && !["paid", "settled"].contains(d.status) && !(d.offerDeadline.map { $0 < today } ?? false) }
        return (open.count, open.reduce(0) { $0 + ($1.offer ?? 0) },
                open.reduce(0) { $0 + (savings(left: max(0, $1.balance - paid($1)), offer: $1.offer)?.cents ?? 0) })
    }
    nonisolated static let debtStatuses = ["in collections", "asked for proof", "proven", "disputed", "paying", "settled", "paid"]

    /// yyyy-MM-dd + n days (or years) → yyyy-MM-dd.
    nonisolated static func add(_ day: String, days: Int = 0, years: Int = 0) -> String? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return nil }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(byAdding: DateComponents(year: years, day: days), to: d).map { f.string(from: $0) }
    }
    /// Last day of the 30 days after the first notice, when asking for proof in writing pauses collection (federal rule).
    nonisolated static func proofWindowEnds(_ d: Debt) -> String? { d.firstNotice.flatMap { add($0, days: 30) } }
    /// Rough end of the lawsuit time limit: last payment + your state's years. An estimate; the rules vary by state and debt.
    nonisolated static func limitEnds(_ d: Debt) -> String? {
        guard let y = d.limitYears, y > 0 else { return nil }
        return d.lastPayment.flatMap { add($0, years: y) }
    }

    /// One parsed CSV line, before it is saved.
    struct Row: Hashable { var day: String; var cents: Int; var desc: String }

    // MARK: amounts and dates

    /// "$1,234.56", "-12.00", "(12.00)", "$-5", "12" → cents. Nil for anything that isn't a plain amount.
    nonisolated static func cents(_ raw: String) -> Int? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        var neg = false
        if t.hasPrefix("(") && t.hasSuffix(")") { neg = true; t = String(t.dropFirst().dropLast()) }
        t = t.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("-") { neg.toggle(); t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        guard !t.isEmpty, t.filter({ $0 == "." }).count <= 1, t.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let d = Double(t) else { return nil }
        let c = Int((d * 100).rounded())
        return neg ? -c : c
    }

    /// Bank date spellings → "yyyy-MM-dd". Time parts are dropped. Nil if it isn't a date between 1990 and 2100.
    nonisolated static func day(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: "T") , t.count > 10, t.first?.isNumber == true { t = String(t[..<r.lowerBound]) }
        if t.contains("/") || t.contains("-"), let sp = t.firstIndex(of: " ") { t = String(t[..<sp]) }
        guard !t.isEmpty else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.isLenient = false
        let out = DateFormatter(); out.locale = f.locale; out.timeZone = f.timeZone; out.dateFormat = "yyyy-MM-dd"
        for fmt in ["yyyy-MM-dd", "yyyy/MM/dd", "M/d/yyyy", "M-d-yyyy", "M/d/yy", "MMM d, yyyy", "d MMM yyyy", "MMM d yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: t), (1990...2100).contains(Calendar(identifier: .gregorian).component(.year, from: d)) {
                return out.string(from: d)
            }
        }
        return nil
    }

    nonisolated static func fmt(_ c: Int) -> String {
        let n = NumberFormatter(); n.numberStyle = .currency; n.currencyCode = "USD"; n.locale = Locale(identifier: "en_US")
        return n.string(from: NSNumber(value: Double(c) / 100)) ?? "\(c)"
    }

    // MARK: CSV

    /// RFC 4180-ish: commas, "quoted, fields", "" inside quotes, CRLF. Blank lines dropped.
    nonisolated static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", inQ = false
        var it = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")).makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return it.next() }
        while let c = next() {
            if inQ {
                if c == "\"" { if let n = next() { if n == "\"" { field.append("\"") } else { inQ = false; pending = n } } else { inQ = false } }
                else { field.append(c) }
            } else if c == "\"" && field.isEmpty { inQ = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" { row.append(field); field = ""; if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }; row = [] }
            else { field.append(c) }
        }
        row.append(field)
        if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
        return rows
    }

    struct Parsed { var rows: [Row]; var skipped: Int; var note: String; var mostlyPositive: Bool; var failed = 0 }

    /// Status values that mean the money never moved (Cash App "FAILED", Revolut "REVERTED", ...): left out of imports.
    nonisolated static let notHappened: Set<String> = ["failed", "declined", "canceled", "cancelled", "sender_canceled", "recipient_canceled",
                                                        "reverted", "rejected", "refused", "void", "voided", "reversed"]
    /// Columns that say who/what a transaction was, best first. Per row the first one that isn't empty is used, so a
    /// Cash App row shows the person ("Name of sender/receiver"), else its note (the shop), else its type.
    nonisolated static let descKeys: [(String, Bool)] = [   // (header, also match headers containing it)
        ("name of sender/receiver", false), ("counterparty", true), ("payee", true), ("merchant", true), ("description", true),
        ("name", false), ("details", true), ("narrative", true), ("memo", true), ("notes", false), ("note", false),
        ("transaction type", false), ("type", false)]

    /// Any bank's CSV export → rows. Columns are found by header names (date / description / amount, or debit + credit);
    /// with no header row they're found by what the values look like. flip = the file shows charges as positive numbers.
    nonisolated static func parse(_ text: String, flip: Bool) -> Parsed {
        let all = csvRows(text)
        guard !all.isEmpty else { return Parsed(rows: [], skipped: 0, note: "The file is empty.", mostlyPositive: false) }
        func find(_ h: [String], _ keys: [String]) -> Int? {
            for k in keys { if let i = h.firstIndex(where: { $0 == k }) { return i } }
            for k in keys { if let i = h.firstIndex(where: { $0.contains(k) }) { return i } }
            return nil
        }
        var dateI: Int?, descI: Int?, amtI: Int?, debI: Int?, credI: Int?, statI: Int?, feeI: Int?, start = 0, note = ""
        var descIs: [Int] = []
        // the header is the first of the first 10 lines that names a date column and has no date values in it
        for (n, r) in all.prefix(10).enumerated() {
            let h = r.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            guard let d = find(h, ["date", "posted", "transaction date", "posting date"]), !h.contains(where: { day($0) != nil }) else { continue }
            dateI = d
            debI = find(h, ["debit", "withdrawal", "money out", "paid out"])
            credI = find(h, ["credit", "deposit", "money in", "paid in"])
            amtI = find(h, ["net amount", "amount", "value", "total"])   // Net Amount (after fees) when the file has it
            statI = h.firstIndex(where: { $0 == "status" || $0 == "state" })
            // a separate Fee column and no Net Amount (Revolut): the fee is taken off too, so totals match the balance
            if let a = amtI, !h[a].contains("net") { feeI = h.firstIndex(where: { $0 == "fee" || $0 == "fees" }) }
            for (k, partial) in descKeys {
                for (i, x) in h.enumerated() where (x == k || (partial && x.contains(k))) && !descIs.contains(i)
                    && ![dateI, amtI, debI, credI, statI, feeI].contains(i) { descIs.append(i) }
            }
            start = n + 1; break
        }
        let body = Array(all.dropFirst(start))
        if dateI == nil {   // no header: guess by content from the first 20 rows
            let sample = body.prefix(20), width = sample.map(\.count).max() ?? 0
            func share(_ i: Int, _ ok: (String) -> Bool) -> Double {
                let v = sample.compactMap { $0.indices.contains(i) ? $0[i] : nil }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                return v.isEmpty ? 0 : Double(v.filter(ok).count) / Double(v.count)
            }
            dateI = (0..<width).first { share($0) { day($0) != nil } > 0.8 }
            amtI = (0..<width).first { $0 != dateI && share($0) { cents($0) != nil } > 0.8 }
            descI = (0..<width).filter { $0 != dateI && $0 != amtI }.max { a, b in
                sample.map { $0.indices.contains(a) ? $0[a].count : 0 }.reduce(0, +) < sample.map { $0.indices.contains(b) ? $0[b].count : 0 }.reduce(0, +) }
            descIs = descI.map { [$0] } ?? []
            note = "No header row; columns were guessed from the values."
        }
        guard let di = dateI, amtI != nil || debI != nil || credI != nil else {
            return Parsed(rows: [], skipped: body.count, note: "Couldn't find a date and an amount column in this file.", mostlyPositive: false)
        }
        var rows: [Row] = [], skipped = 0, failed = 0
        let split = amtI == nil || (debI != nil && credI != nil)
        for r in body {
            func col(_ i: Int?) -> String { guard let i, r.indices.contains(i) else { return "" }; return r[i].trimmingCharacters(in: .whitespaces) }
            guard let d = day(col(di)) else { skipped += 1; continue }
            if statI != nil, notHappened.contains(col(statI).lowercased()) { failed += 1; continue }
            var c: Int?
            if split {
                let deb = cents(col(debI)).map { -abs($0) }, cred = cents(col(credI)).map { abs($0) }
                c = (deb == nil && cred == nil) ? nil : (cred ?? 0) + (deb ?? 0)
            } else { c = cents(col(amtI)).map { $0 - abs(cents(col(feeI)) ?? 0) } }
            guard var amount = c else { skipped += 1; continue }
            if flip && !split { amount = -amount }
            let desc = descIs.lazy.map { col($0) }.first { !$0.isEmpty } ?? "(no description)"
            rows.append(Row(day: d, cents: amount, desc: String(desc.prefix(300))))
        }
        let pos = rows.filter { $0.cents > 0 }.count
        let mostlyPositive = !split && !flip && rows.count >= 4 && Double(pos) / Double(rows.count) > 0.7
        if failed > 0 { note += (note.isEmpty ? "" : " ") + "\(failed) failed or canceled transactions left out (no money moved)." }
        return Parsed(rows: rows, skipped: skipped, note: note, mostlyPositive: mostlyPositive, failed: failed)
    }

    // MARK: categories

    /// "POS DEBIT 1234 STARBUCKS #0921 SEATTLE WA" → "starbucks seattle wa": the part that names who was paid.
    nonisolated static func merchant(_ desc: String) -> String {
        var s = desc.lowercased()
        for p in ["pos debit", "debit card purchase", "purchase authorized on", "pos purchase", "recurring payment", "card purchase",
                  "checkcard", "purchase", "sq *", "sq*", "tst*", "tst *", "pp*", "paypal *"] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        let words = s.split { !($0.isLetter || $0 == "&" || $0 == "'" || $0 == ".") }.map(String.init)
            .filter { $0.count > 1 || $0 == "&" }
        return words.prefix(3).joined(separator: " ")
    }

    /// Built-in guesses, checked in order (so "amazon prime" is a subscription before "amazon" is shopping).
    nonisolated static let defaultRules: [(String, String)] = [
        ("payment thank you", "Transfers"), ("autopay", "Transfers"), ("transfer", "Transfers"), ("zelle", "Transfers"),
        ("venmo", "Transfers"), ("cash app", "Transfers"), ("apple cash", "Transfers"),
        ("payroll", "Income"), ("direct dep", "Income"),
        ("overdraft", "Debt & Fees"), ("late fee", "Debt & Fees"), ("interest charge", "Debt & Fees"), ("finance charge", "Debt & Fees"),
        ("affirm", "Debt & Fees"), ("klarna", "Debt & Fees"), ("afterpay", "Debt & Fees"), (" loan", "Debt & Fees"), (" fee", "Debt & Fees"),
        ("netflix", "Subscriptions"), ("spotify", "Subscriptions"), ("hulu", "Subscriptions"), ("disney", "Subscriptions"),
        ("apple.com/bill", "Subscriptions"), ("icloud", "Subscriptions"), ("youtube", "Subscriptions"), ("google", "Subscriptions"),
        ("openai", "Subscriptions"), ("chatgpt", "Subscriptions"), ("anthropic", "Subscriptions"), ("claude", "Subscriptions"),
        ("github", "Subscriptions"), ("cursor", "Subscriptions"), ("adobe", "Subscriptions"), ("patreon", "Subscriptions"),
        ("amazon prime", "Subscriptions"), ("prime video", "Subscriptions"), ("x corp", "Subscriptions"), ("1password", "Subscriptions"),
        ("verizon", "Phone & Internet"), ("t-mobile", "Phone & Internet"), ("at&t", "Phone & Internet"), ("comcast", "Phone & Internet"),
        ("xfinity", "Phone & Internet"), ("spectrum", "Phone & Internet"), ("mint mobile", "Phone & Internet"), (" visible", "Phone & Internet"),
        (" rent", "Housing & Bills"), ("apartment", "Housing & Bills"), ("pg&e", "Housing & Bills"), ("electric", "Housing & Bills"),
        (" water", "Housing & Bills"), ("insurance", "Housing & Bills"),
        ("doordash", "Food"), ("uber eats", "Food"), ("grubhub", "Food"), ("mcdonald", "Food"), ("starbucks", "Food"),
        ("taco bell", "Food"), ("chick-fil-a", "Food"), ("chipotle", "Food"), ("wendy", "Food"), ("burger", "Food"),
        ("pizza", "Food"), ("coffee", "Food"), ("restaurant", "Food"), ("in-n-out", "Food"), ("jack in the box", "Food"),
        ("safeway", "Groceries"), ("kroger", "Groceries"), ("trader joe", "Groceries"), ("whole foods", "Groceries"),
        ("aldi", "Groceries"), ("vons", "Groceries"), ("ralphs", "Groceries"), ("grocery", "Groceries"), ("costco", "Groceries"),
        ("walmart", "Groceries"), ("target", "Shopping"),
        (" shell", "Transport"), ("chevron", "Transport"), (" arco", "Transport"), ("exxon", "Transport"), ("fuel", "Transport"),
        ("uber", "Transport"), ("lyft", "Transport"), ("parking", "Transport"), ("dmv", "Transport"), ("autozone", "Transport"),
        ("amazon", "Shopping"), ("ebay", "Shopping"), ("best buy", "Shopping"), ("etsy", "Shopping"), ("apple store", "Shopping"),
    ]

    /// "My names": the owner's own names and own-account wording. Money to or from these is moving between their own accounts
    /// (Transfers), not income or spending. Editable in Money → Where it goes → My names; saved in the settings table.
    /// Only their own names belong here, never other people's (family included): those are real money in or out.
    nonisolated static let defaultMyNames = LocalConfig.current.myNames
                                             + ["Top-up by", "Add Cash", "Cash Out", "Savings"]   // generic own-account wording; your names: MY_NAMES
    nonisolated static func isMe(_ desc: String, _ me: [String]) -> Bool {
        let d = desc.lowercased()
        return me.contains { let p = $0.trimmingCharacters(in: .whitespaces).lowercased(); return p.count >= 3 && d.contains(p) }
    }
    /// One pattern per line → the list (blank lines dropped, duplicates removed, case kept).
    nonisolated static func names(_ text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for l in text.components(separatedBy: .newlines) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.count >= 3, seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }

    /// Account names grouped without caring about case: "cash app" and "Cash app" are one account, shown as "Cash App".
    nonisolated static func accountKey(_ a: String) -> String { a.trimmingCharacters(in: .whitespaces).lowercased() }
    nonisolated static func accountLabel(_ variants: [String]) -> String {
        let v = variants.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let mixed = v.first(where: { s in s.dropFirst().contains { $0.isUppercase } }) { return mixed }   // "TD Bank" kept as written
        return (v.first ?? "").capitalized
    }

    /// Your own rules first (from changing a category with "remember"), then your names (Transfers), then the built-in
    /// ones; money in with no match is Income.
    nonisolated static func categorize(_ desc: String, cents: Int, rules: [(String, String)], me: [String] = []) -> String {
        let d = " " + desc.lowercased()
        for (p, c) in rules where !p.isEmpty && d.contains(p.lowercased()) { return c }
        if isMe(desc, me) { return "Transfers" }
        for (p, c) in defaultRules where d.contains(p) {
            if c == "Income" && cents < 0 { continue }
            return c
        }
        return cents > 0 ? "Income" : "Other"
    }

    // MARK: totals

    struct Summary { var income = 0; var spent = 0; var transfersIn = 0; var transfersOut = 0
        var byCategory: [(String, Int)] = []; var byMerchant: [(String, Int)] = [] }

    /// Money in, money out and where it went. Transfers between your own accounts are left out of in/out.
    nonisolated static func summary(_ t: [Txn]) -> Summary {
        var s = Summary(), cat: [String: Int] = [:], mer: [String: Int] = [:]
        for x in t where x.category == "Transfers" { if x.cents > 0 { s.transfersIn += x.cents } else { s.transfersOut -= x.cents } }
        for x in t where x.category != "Transfers" {
            if x.cents > 0 { s.income += x.cents } else {
                s.spent += -x.cents
                cat[x.category.isEmpty ? "Other" : x.category, default: 0] += -x.cents
                mer[merchant(x.desc).isEmpty ? x.desc.lowercased() : merchant(x.desc), default: 0] += -x.cents
            }
        }
        s.byCategory = cat.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        s.byMerchant = mer.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) }
        return s
    }

    struct Repeat: Hashable { var merchant: String; var monthly: Int; var months: Int; var last: String }

    /// Charges from the same place in 2+ different months at about the same amount (within 20%): subscriptions, bills, habits.
    nonisolated static func repeating(_ t: [Txn]) -> [Repeat] {
        var groups: [String: [Txn]] = [:]
        for x in t where x.cents < 0 && x.category != "Transfers" {
            let m = merchant(x.desc); if !m.isEmpty { groups[m, default: []].append(x) }
        }
        var out: [Repeat] = []
        for (m, xs) in groups {
            let amounts = xs.map { -$0.cents }.sorted()
            let median = amounts[amounts.count / 2]
            let close = xs.filter { abs(-$0.cents - median) <= max(median / 5, 100) }
            let months = Set(close.map { String($0.day.prefix(7)) })
            guard months.count >= 2 else { continue }
            out.append(Repeat(merchant: m, monthly: median, months: months.count, last: close.map(\.day).max() ?? ""))
        }
        return out.sorted { $0.monthly > $1.monthly }
    }

    /// Duplicate-import key: same day, amount, description and account; n = how many identical ones came before it in
    /// the same file, so two real $5 coffees on one day both count, but importing the file again adds nothing.
    nonisolated static func dedupe(_ r: Row, account: String, n: Int) -> String {
        "\(r.day)|\(r.cents)|\(r.desc.lowercased())|\(account.lowercased())|\(n)"
    }
}

extension MoneyStore {
    /// `Heimdall --money-repair [--apply]`: for every imported file still on disk (same name, in ~/Downloads, ~/Desktop or
    /// ~/Documents), re-read it with today's parser and replace its rows; then sort the other rows with "my names".
    /// Without --apply it only says what would change. Prints counts only, never descriptions or account numbers.
    static func repairCLI(apply: Bool) -> Int32 {
        let m = MoneyStore()
        guard m.db != nil else { print("can't open \(Money.path)"); return 1 }
        let fm = FileManager.default, home = NSHomeDirectory()
        var bad = false
        for src in Set(m.txns.map(\.source)).sorted() where src.lowercased().hasSuffix(".csv") {
            if src.contains("20261027-062835-create-a-csv") { print("\(src): skipped (not to be opened)"); continue }
            guard let path = ["Downloads", "Desktop", "Documents"].map({ "\(home)/\($0)/\(src)" }).first(where: { fm.fileExists(atPath: $0) }),
                  let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? (try? String(contentsOfFile: path, encoding: .isoLatin1)) else {
                print("\(src): original file not found; left as it is"); continue
            }
            switch m.rebuild(source: src, text: text, apply: apply) {
            case .failure(let e): print("\(src): \(e.text)"); bad = true
            case .success(let r):
                print("\(src): rows \(r.before) → \(r.after)\(apply ? " (\(r.dupes) already there from another file)" : ""), no description \(r.noDescBefore) → \(r.noDescAfter), failed/canceled left out \(r.failedLeftOut), hand-picked categories \(apply ? "kept \(r.handKept), lost \(r.handLost)" : "\(r.handKept)")")
            }
        }
        let n = apply ? m.recategorize(from: [], to: m.myNames) : m.txns.filter {
            $0.debtID == nil && $0.itemID == nil && $0.category == Money.categorize($0.desc, cents: $0.cents, rules: m.rules)
                && Money.categorize($0.desc, cents: $0.cents, rules: m.rules, me: m.myNames) != $0.category }.count
        print("other rows re-sorted with my names: \(n)\(apply ? "" : " (would be)")")
        return bad ? 1 : 0
    }
}

// MARK: the database

/// Thin SQLite wrapper (the system's libsqlite3). Values are always bound, never pasted into SQL.
final class MoneyDB {
    enum V { case t(String), i(Int), n }
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fresh = !FileManager.default.fileExists(atPath: path)
        if fresh { FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { return nil }
        _ = exec("""
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS transactions (id INTEGER PRIMARY KEY, day TEXT NOT NULL, cents INTEGER NOT NULL,
          description TEXT NOT NULL, account TEXT NOT NULL DEFAULT '', category TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
          contact_id INTEGER, item_id INTEGER, source TEXT NOT NULL DEFAULT 'manual', dedupe TEXT UNIQUE, added TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'have', cost_cents INTEGER NOT NULL DEFAULT 0, ask_cents INTEGER, sold_cents INTEGER,
          bought TEXT, sold TEXT, note TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS contacts (id INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'person',
          phone TEXT NOT NULL DEFAULT '', email TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '', last_contact TEXT);
        CREATE TABLE IF NOT EXISTS rules (pattern TEXT PRIMARY KEY, category TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS debts (id INTEGER PRIMARY KEY, creditor TEXT NOT NULL, collector TEXT NOT NULL DEFAULT '',
          acct TEXT NOT NULL DEFAULT '', balance_cents INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'in collections',
          first_notice TEXT, proof_asked TEXT, last_payment TEXT, limit_years INTEGER, note TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS tx_day ON transactions(day);
        """)
        if !rows("PRAGMA table_info(transactions)").contains(where: { ($0[1] as? String) == "debt_id" }) {
            _ = exec("ALTER TABLE transactions ADD COLUMN debt_id INTEGER")   // payments on a debt
        }
        if !rows("PRAGMA table_info(transactions)").contains(where: { ($0[1] as? String) == "receipt_id" }) {
            _ = exec("ALTER TABLE transactions ADD COLUMN receipt_id INTEGER")   // receipt photo on the Money receipt pipe
        }
        // settlement offers on debts (added later; existing debts get empty ones)
        let have = Set(rows("PRAGMA table_info(debts)").compactMap { $0[1] as? String })
        for (col, type) in [("offer_cents", "INTEGER"), ("offer_day", "TEXT"), ("offer_deadline", "TEXT"),
                            ("offer_from", "TEXT NOT NULL DEFAULT ''"), ("offer_in_writing", "INTEGER NOT NULL DEFAULT 0"),
                            ("offer_ref", "TEXT NOT NULL DEFAULT ''")] where !have.contains(col) {
            _ = exec("ALTER TABLE debts ADD COLUMN \(col) \(type)")
        }
    }
    deinit { sqlite3_close(db) }

    func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func prepare(_ sql: String, _ args: [V]) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .t(let s): sqlite3_bind_text(st, n, s, -1, Self.transient)
            case .i(let v): sqlite3_bind_int64(st, n, Int64(v))
            case .n: sqlite3_bind_null(st, n)
            }
        }
        return st
    }

    /// Runs a write; returns how many rows it changed (0 for an ignored duplicate), or -1 on error.
    @discardableResult func run(_ sql: String, _ args: [V] = []) -> Int {
        guard let st = prepare(sql, args) else { return -1 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_DONE ? Int(sqlite3_changes(db)) : -1
    }

    func rows(_ sql: String, _ args: [V] = []) -> [[Any?]] {
        guard let st = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [[Any?]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(st)).map { i -> Any? in
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: return Int(sqlite3_column_int64(st, i))
                case SQLITE_NULL: return nil
                default: return sqlite3_column_text(st, i).map { String(cString: $0) }
                }
            })
        }
        return out
    }
    func lastID() -> Int { Int(sqlite3_last_insert_rowid(db)) }
}

final class MoneyStore: ObservableObject {
    @Published var txns: [Money.Txn] = []
    @Published var items: [Money.Item] = []
    @Published var contacts: [Money.Contact] = []
    @Published var debts: [Money.Debt] = []
    @Published var rules: [(String, String)] = []
    @Published var myNames: [String] = Money.defaultMyNames
    @Published var message = ""
    let db: MoneyDB?

    init(path: String = Money.path) {
        db = MoneyDB(path: path)
        if db == nil { message = "Couldn't open \(path)." }
        reload()
    }

    nonisolated static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    nonisolated static func today() -> String { String(now().prefix(10)) }

    func reload() {
        guard let db else { return }
        rules = db.rows("SELECT pattern, category FROM rules ORDER BY length(pattern) DESC").map { ($0[0] as? String ?? "", $0[1] as? String ?? "") }
        if let v = db.rows("SELECT value FROM settings WHERE key = 'my_names'").first?.first as? String { myNames = Money.names(v) }
        txns = db.rows("SELECT id, day, cents, description, account, category, note, contact_id, item_id, source, debt_id, receipt_id FROM transactions ORDER BY day DESC, id DESC").map {
            Money.Txn(id: $0[0] as? Int ?? 0, day: $0[1] as? String ?? "", cents: $0[2] as? Int ?? 0, desc: $0[3] as? String ?? "",
                      account: $0[4] as? String ?? "", category: $0[5] as? String ?? "", note: $0[6] as? String ?? "",
                      contactID: $0[7] as? Int, itemID: $0[8] as? Int, source: $0[9] as? String ?? "", debtID: $0[10] as? Int, receiptID: $0[11] as? Int) }
        debts = db.rows("SELECT id, creditor, collector, acct, balance_cents, status, first_notice, proof_asked, last_payment, limit_years, note, offer_cents, offer_day, offer_deadline, offer_from, offer_in_writing, offer_ref FROM debts ORDER BY status IN ('paid','settled'), balance_cents DESC").map {
            Money.Debt(id: $0[0] as? Int ?? 0, creditor: $0[1] as? String ?? "", collector: $0[2] as? String ?? "", acct: $0[3] as? String ?? "",
                       balance: $0[4] as? Int ?? 0, status: $0[5] as? String ?? "in collections", firstNotice: $0[6] as? String,
                       proofAsked: $0[7] as? String, lastPayment: $0[8] as? String, limitYears: $0[9] as? Int, note: $0[10] as? String ?? "",
                       offer: $0[11] as? Int, offerDay: $0[12] as? String, offerDeadline: $0[13] as? String, offerFrom: $0[14] as? String ?? "",
                       offerInWriting: ($0[15] as? Int ?? 0) != 0, offerRef: $0[16] as? String ?? "") }
        items = db.rows("SELECT id, name, category, status, cost_cents, ask_cents, sold_cents, bought, sold, note FROM items ORDER BY status = 'sold', id DESC").map {
            Money.Item(id: $0[0] as? Int ?? 0, name: $0[1] as? String ?? "", category: $0[2] as? String ?? "", status: $0[3] as? String ?? "have",
                       cost: $0[4] as? Int ?? 0, ask: $0[5] as? Int, sold: $0[6] as? Int, bought: $0[7] as? String, soldDay: $0[8] as? String,
                       note: $0[9] as? String ?? "") }
        contacts = db.rows("SELECT id, name, kind, phone, email, note, last_contact FROM contacts ORDER BY name COLLATE NOCASE").map {
            Money.Contact(id: $0[0] as? Int ?? 0, name: $0[1] as? String ?? "", kind: $0[2] as? String ?? "person", phone: $0[3] as? String ?? "",
                          email: $0[4] as? String ?? "", note: $0[5] as? String ?? "", lastContact: $0[6] as? String) }
    }

    /// Saves parsed rows; returns (added, already there). Each gets a category from the rules.
    @discardableResult func save(_ rows: [Money.Row], account: String, source: String) -> (added: Int, dupes: Int) {
        guard let db else { return (0, 0) }
        _ = db.exec("BEGIN")
        let r = insert(db, rows, account: account, source: source)
        _ = db.exec("COMMIT")
        reload()
        return r
    }
    /// otherFiles: a row that only matches one already there from another file still goes in (rebuild only). Several
    /// Cash App accounts can share one account name, so the same shop, day and amount in two of them are two payments.
    /// $0 rows (Cash App's "Account Notifications", in every export) are still dropped as repeats.
    private func insert(_ db: MoneyDB, _ rows: [Money.Row], account: String, source: String, otherFiles: Bool = false) -> (added: Int, dupes: Int) {
        var seen: [String: Int] = [:], added = 0, dupes = 0
        for r in rows {
            let base = Money.dedupe(r, account: account, n: 0)
            let n = seen[base, default: 0]; seen[base] = n + 1
            let changed = db.run("INSERT OR IGNORE INTO transactions (day, cents, description, account, category, source, dedupe, added) VALUES (?,?,?,?,?,?,?,?)",
                                 [.t(r.day), .i(r.cents), .t(r.desc), .t(account), .t(Money.categorize(r.desc, cents: r.cents, rules: rules, me: myNames)),
                                  .t(source), .t(Money.dedupe(r, account: account, n: n)), .t(Self.now())])
            if changed > 0 { added += 1; continue }
            if otherFiles, r.cents != 0,
               db.run("INSERT OR IGNORE INTO transactions (day, cents, description, account, category, source, dedupe, added) VALUES (?,?,?,?,?,?,?,?)",
                      [.t(r.day), .i(r.cents), .t(r.desc), .t(account), .t(Money.categorize(r.desc, cents: r.cents, rules: rules, me: myNames)),
                       .t(source), .t(Money.dedupe(r, account: account, n: n) + "|" + source.lowercased()), .t(Self.now())]) > 0 { added += 1 }
            else { dupes += 1 }
        }
        return (added, dupes)
    }

    func addManual(day: String, cents: Int, desc: String, account: String, category: String, note: String) {
        guard let db else { return }
        db.run("INSERT INTO transactions (day, cents, description, account, category, note, source, added) VALUES (?,?,?,?,?,?,'manual',?)",
               [.t(day), .i(cents), .t(desc), .t(account), .t(category.isEmpty ? Money.categorize(desc, cents: cents, rules: rules, me: myNames) : category),
                .t(note), .t(Self.now())])
        reload()
    }

    /// Changes one transaction's category; with remember, every transaction from the same place gets it too, now and on later imports.
    func setCategory(_ t: Money.Txn, _ cat: String, remember: Bool) {
        guard let db else { return }
        db.run("UPDATE transactions SET category = ? WHERE id = ?", [.t(cat), .i(t.id)])
        let m = Money.merchant(t.desc)
        if remember, m.count >= 3 {
            db.run("INSERT INTO rules (pattern, category) VALUES (?, ?) ON CONFLICT(pattern) DO UPDATE SET category = excluded.category", [.t(m), .t(cat)])
            for x in txns where Money.merchant(x.desc) == m { db.run("UPDATE transactions SET category = ? WHERE id = ?", [.t(cat), .i(x.id)]) }
        }
        reload()
    }

    /// Saves "my names" and re-sorts the transactions that still have the category the app gave them (a category you
    /// picked by hand, a remembered rule, debt payments and inventory sales are left alone). Returns how many changed.
    @discardableResult func setMyNames(_ new: [String]) -> Int {
        guard let db else { return 0 }
        let old = myNames
        db.run("INSERT INTO settings (key, value) VALUES ('my_names', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.t(new.joined(separator: "\n"))])
        myNames = new
        let n = recategorize(from: old, to: new)
        reload()
        return n
    }

    /// Rows whose category is exactly what the app would have given them with the `from` names get the `to` result.
    @discardableResult func recategorize(from: [String], to: [String]) -> Int {
        guard let db else { return 0 }
        var n = 0
        _ = db.exec("BEGIN")
        for t in txns where t.debtID == nil && t.itemID == nil && t.source != "inventory" && t.source != "debt" {
            let was = Money.categorize(t.desc, cents: t.cents, rules: rules, me: from)
            let now = Money.categorize(t.desc, cents: t.cents, rules: rules, me: to)
            if t.category == was && now != was { n += max(0, db.run("UPDATE transactions SET category = ? WHERE id = ?", [.t(now), .i(t.id)])) }
        }
        _ = db.exec("COMMIT")
        reload()
        return n
    }

    /// Repair: re-read one imported file with today's parser and replace the rows that came from it (same account name).
    /// Refused if any of those rows has a note, contact, item or debt linked to it. A category changed by hand is carried
    /// over to the new row with the same day and amount when there is exactly one. Returns a summary, or an error.
    struct RepairError: Error { let text: String }
    struct Rebuilt { var before = 0, after = 0, dupes = 0, noDescBefore = 0, noDescAfter = 0, failedLeftOut = 0, handKept = 0, handLost = 0 }
    func rebuild(source: String, text: String, apply: Bool) -> Result<Rebuilt, RepairError> {
        guard let db else { return .failure(RepairError(text: "no database")) }
        let old = txns.filter { $0.source == source }
        guard !old.isEmpty else { return .failure(RepairError(text: "no rows came from \(source)")) }
        if old.contains(where: { !$0.note.isEmpty || $0.contactID != nil || $0.itemID != nil || $0.debtID != nil || $0.receiptID != nil }) {
            return .failure(RepairError(text: "some rows from \(source) have notes or links; not replaced"))
        }
        let accounts = Set(old.map(\.account))
        guard accounts.count == 1, let account = accounts.first else { return .failure(RepairError(text: "rows from \(source) have more than one account name")) }
        let p = Money.parse(text, flip: false)
        guard !p.rows.isEmpty else { return .failure(RepairError(text: "the file gave no rows: \(p.note)")) }
        // hand-picked = not what the app would have given, with or without "my names" (older builds had none)
        let hand = old.filter { $0.category != Money.categorize($0.desc, cents: $0.cents, rules: rules)
                                && $0.category != Money.categorize($0.desc, cents: $0.cents, rules: rules, me: myNames) }
        var r = Rebuilt(before: old.count, noDescBefore: old.filter { $0.desc == "(no description)" }.count, failedLeftOut: p.failed)
        guard apply else {
            r.after = p.rows.count; r.noDescAfter = p.rows.filter { $0.desc == "(no description)" }.count; r.handKept = hand.count
            return .success(r)
        }
        // one transaction: the old rows go and the new ones come in together, or nothing changes
        guard db.exec("BEGIN") else { return .failure(RepairError(text: "couldn't start a transaction")) }
        guard db.run("DELETE FROM transactions WHERE source = ?", [.t(source)]) >= 0 else { _ = db.exec("ROLLBACK"); return .failure(RepairError(text: "delete failed")) }
        let ins = insert(db, p.rows, account: account, source: source, otherFiles: true)
        guard db.exec("COMMIT") else { _ = db.exec("ROLLBACK"); reload(); return .failure(RepairError(text: "save failed; nothing changed")) }
        reload()
        r.after = ins.added; r.dupes = ins.dupes
        r.noDescAfter = txns.filter { $0.source == source && $0.desc == "(no description)" }.count
        for h in hand {
            let match = txns.filter { $0.source == source && $0.day == h.day && $0.cents == h.cents }
            if match.count == 1 { db.run("UPDATE transactions SET category = ? WHERE id = ?", [.t(h.category), .i(match[0].id)]); r.handKept += 1 }
            else { r.handLost += 1 }
        }
        reload()
        return .success(r)
    }

    /// Accounts grouped without caring about case: key → label shown, e.g. "cash app" → "Cash App".
    var accountLabels: [String: String] {
        Dictionary(grouping: txns.map(\.account).filter { !$0.isEmpty }, by: Money.accountKey).mapValues { Money.accountLabel(Array(Set($0)).sorted()) }
    }

    func setNote(_ t: Money.Txn, _ note: String) { db?.run("UPDATE transactions SET note = ? WHERE id = ?", [.t(note), .i(t.id)]); reload() }
    /// A receipt with no bank transaction yet (cash, or a bank file not imported): money out, its category guessed from the shop.
    /// The dedupe key stops the same receipt being added twice.
    func addFromReceipt(_ r: ReceiptPipe.Receipt) {
        guard let db, let c = r.cents, !txns.contains(where: { $0.receiptID == r.id }) else { return }
        let desc = r.vendor.isEmpty ? "Receipt \(r.id)" : r.vendor
        let day = r.day ?? String(r.uploaded.prefix(10))
        db.run("INSERT OR IGNORE INTO transactions (day, cents, description, account, category, note, source, receipt_id, dedupe, added) VALUES (?,?,?,'receipt',?,'','receipt',?,?,?)",
               [.t(day), .i(-c), .t(desc), .t(Money.categorize(desc, cents: -c, rules: rules, me: myNames)), .i(r.id),
                .t("receipt|\(ReceiptPipe.base)|\(r.id)"), .t(Self.now())])
        reload()
    }
    /// Ties a receipt to the bank transaction it is (one transaction, with the photo attached).
    func linkReceipt(_ t: Money.Txn, _ r: ReceiptPipe.Receipt) { db?.run("UPDATE transactions SET receipt_id = ? WHERE id = ?", [.i(r.id), .i(t.id)]); reload() }
    func link(_ t: Money.Txn, contact: Int?) { db?.run("UPDATE transactions SET contact_id = ? WHERE id = ?", [contact.map { .i($0) } ?? .n, .i(t.id)]); reload() }

    func addItem(_ i: Money.Item) {
        db?.run("INSERT INTO items (name, category, status, cost_cents, ask_cents, bought, note) VALUES (?,?,?,?,?,?,?)",
                [.t(i.name), .t(i.category), .t(i.status), .i(i.cost), i.ask.map { .i($0) } ?? .n, .t(i.bought ?? Self.today()), .t(i.note)])
        reload()
    }
    func setStatus(_ i: Money.Item, _ status: String) { db?.run("UPDATE items SET status = ? WHERE id = ?", [.t(status), .i(i.id)]); reload() }

    /// Marks it sold; with addIncome, also records the money coming in as a transaction linked to the item.
    func sell(_ i: Money.Item, cents: Int, day: String, addIncome: Bool) {
        guard let db else { return }
        db.run("UPDATE items SET status = 'sold', sold_cents = ?, sold = ? WHERE id = ?", [.i(cents), .t(day), .i(i.id)])
        if addIncome {
            db.run("INSERT INTO transactions (day, cents, description, account, category, item_id, source, added) VALUES (?,?,?,'','Income',?,'inventory',?)",
                   [.t(day), .i(cents), .t("Sold: " + i.name), .i(i.id), .t(Self.now())])
        }
        reload()
    }

    func addDebt(_ d: Money.Debt) {
        db?.run("INSERT INTO debts (creditor, collector, acct, balance_cents, status, first_notice, last_payment, limit_years, note) VALUES (?,?,?,?,?,?,?,?,?)",
                [.t(d.creditor), .t(d.collector), .t(d.acct), .i(d.balance), .t(d.status), d.firstNotice.map { .t($0) } ?? .n,
                 d.lastPayment.map { .t($0) } ?? .n, d.limitYears.map { .i($0) } ?? .n, .t(d.note)])
        reload()
    }
    func setDebtStatus(_ d: Money.Debt, _ s: String) {
        db?.run("UPDATE debts SET status = ? WHERE id = ?", [.t(s), .i(d.id)])
        if s == "asked for proof" && d.proofAsked == nil { db?.run("UPDATE debts SET proof_asked = ? WHERE id = ?", [.t(Self.today()), .i(d.id)]) }
        reload()
    }
    func setDebtNote(_ d: Money.Debt, _ note: String) { db?.run("UPDATE debts SET note = ? WHERE id = ?", [.t(note), .i(d.id)]); reload() }
    /// What has been paid on a debt: its linked payments (money out, so negative) as a positive number.
    func paid(_ d: Money.Debt) -> Int { -txns.filter { $0.debtID == d.id }.reduce(0) { $0 + $1.cents } }
    /// Saves (or clears, with offer nil) a debt's settlement offer.
    func setOffer(_ d: Money.Debt, offer: Int?, day: String?, deadline: String?, from: String, inWriting: Bool, ref: String) {
        db?.run("UPDATE debts SET offer_cents = ?, offer_day = ?, offer_deadline = ?, offer_from = ?, offer_in_writing = ?, offer_ref = ? WHERE id = ?",
                [offer.map { .i(abs($0)) } ?? .n, day.map { .t($0) } ?? .n, deadline.map { .t($0) } ?? .n, .t(from), .i(inWriting ? 1 : 0), .t(ref), .i(d.id)])
        reload()
    }
    /// Paid the settlement: the payment goes in as a linked Debt & Fees transaction, the debt is marked settled, the offer stays.
    func paySettlement(_ d: Money.Debt, cents: Int, day: String, account: String) {
        pay(d, cents: cents, day: day, account: account, what: "Settlement")
        setDebtStatus(d, "settled")
    }
    /// Records a payment as a Debt & Fees transaction linked to the debt, and moves its last-payment date.
    func pay(_ d: Money.Debt, cents: Int, day: String, account: String, what: String = "Payment") {
        guard let db else { return }
        db.run("INSERT INTO transactions (day, cents, description, account, category, debt_id, source, added) VALUES (?,?,?,?,'Debt & Fees',?,'debt',?)",
               [.t(day), .i(-abs(cents)), .t(what + ": " + (d.collector.isEmpty ? d.creditor : d.collector)), .t(account), .i(d.id), .t(Self.now())])
        db.run("UPDATE debts SET last_payment = ? WHERE id = ? AND (last_payment IS NULL OR last_payment < ?)", [.t(day), .i(d.id), .t(day)])
        reload()
    }

    // MARK: edit an existing row (Edit… buttons). Only the row's own fields change; links (debt, item, contact) stay.
    /// Changes a transaction's date, amount, description, account, category and note. A category different from before
    /// counts as picked by hand (re-sorting from "my names" leaves it alone, same as the category picker).
    func updateTxn(_ t: Money.Txn) {
        db?.run("UPDATE transactions SET day = ?, cents = ?, description = ?, account = ?, category = ?, note = ? WHERE id = ?",
                [.t(t.day), .i(t.cents), .t(t.desc), .t(t.account), .t(t.category), .t(t.note), .i(t.id)])
        reload()
    }
    /// Changes a debt's own details (who, last 4, amount claimed, status, dates, state limit, note). Its payments,
    /// settlement offer and settled/paid history are kept.
    func updateDebt(_ d: Money.Debt) {
        db?.run("UPDATE debts SET creditor = ?, collector = ?, acct = ?, balance_cents = ?, status = ?, first_notice = ?, proof_asked = ?, last_payment = ?, limit_years = ?, note = ? WHERE id = ?",
                [.t(d.creditor), .t(d.collector), .t(d.acct), .i(abs(d.balance)), .t(d.status), d.firstNotice.map { .t($0) } ?? .n,
                 d.proofAsked.map { .t($0) } ?? .n, d.lastPayment.map { .t($0) } ?? .n, d.limitYears.map { .i($0) } ?? .n, .t(d.note), .i(d.id)])
        reload()
    }
    /// Changes an inventory item (name, category, status, paid, asking, sold for, dates, note).
    func updateItem(_ i: Money.Item) {
        db?.run("UPDATE items SET name = ?, category = ?, status = ?, cost_cents = ?, ask_cents = ?, sold_cents = ?, bought = ?, sold = ?, note = ? WHERE id = ?",
                [.t(i.name), .t(i.category), .t(i.status), .i(abs(i.cost)), i.ask.map { .i(abs($0)) } ?? .n, i.sold.map { .i(abs($0)) } ?? .n,
                 i.bought.map { .t($0) } ?? .n, i.soldDay.map { .t($0) } ?? .n, .t(i.note), .i(i.id)])
        reload()
    }
    /// Changes a contact (name, kind, phone, email, note, last contact).
    func updateContact(_ c: Money.Contact) {
        db?.run("UPDATE contacts SET name = ?, kind = ?, phone = ?, email = ?, note = ?, last_contact = ? WHERE id = ?",
                [.t(c.name), .t(c.kind), .t(c.phone), .t(c.email), .t(c.note), c.lastContact.map { .t($0) } ?? .n, .i(c.id)])
        reload()
    }

    func addContact(_ c: Money.Contact) {
        db?.run("INSERT INTO contacts (name, kind, phone, email, note, last_contact) VALUES (?,?,?,?,?,?)",
                [.t(c.name), .t(c.kind), .t(c.phone), .t(c.email), .t(c.note), c.lastContact.map { .t($0) } ?? .n])
        reload()
    }
    func touch(_ c: Money.Contact) { db?.run("UPDATE contacts SET last_contact = ? WHERE id = ?", [.t(Self.today()), .i(c.id)]); reload() }
    func setContactNote(_ c: Money.Contact, _ note: String) { db?.run("UPDATE contacts SET note = ? WHERE id = ?", [.t(note), .i(c.id)]); reload() }
}

// MARK: views

struct MoneyView: View {
    @StateObject private var m = MoneyStore()
    @State private var page = "overview"
    @State private var importing: (url: URL, text: String)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $page) {
                    Text("Where it goes").tag("overview"); Text("Transactions").tag("txns")
                    // Debts / Inventory / Contacts show once they have rows (all empty on 11-02; the tables stay)
                    if !m.debts.isEmpty { Text("Debts").tag("debts") }
                    if !m.items.isEmpty { Text("Inventory").tag("items") }
                    if !m.contacts.isEmpty { Text("Contacts").tag("contacts") }
                    Text("Receipts").tag("receipts")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 680)
                Spacer()
                Text(m.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Import bank CSV…") { pickCSV() }
                    .help("Download your transactions as CSV from your bank or card's website, then pick the file here")
            }.padding(10)
            Divider()
            switch page {
            case "txns": TxnsPage().environmentObject(m)
            case "debts": DebtsPage().environmentObject(m)
            case "items": ItemsPage().environmentObject(m)
            case "contacts": ContactsPage().environmentObject(m)
            case "receipts": ReceiptsPage()
            default: OverviewPage(importCSV: pickCSV).environmentObject(m)
            }
        }
        .sheet(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })) {
            if let i = importing { ImportSheet(url: i.url, text: i.text) { importing = nil }.environmentObject(m) }
        }
    }

    private func pickCSV() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .plainText]; p.allowsMultipleSelection = false
        p.message = "Pick a CSV export of your transactions"
        guard p.runModal() == .OK, let u = p.url else { return }
        guard let t = (try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: .isoLatin1)) else {
            m.message = "Couldn't read \(u.lastPathComponent)"; return
        }
        importing = (u, t)
    }
}

/// Preview before anything is saved: the account name, whether charges are positive in this file, and the first rows.
struct ImportSheet: View {
    @EnvironmentObject var m: MoneyStore
    let url: URL, text: String
    var done: () -> Void
    @State private var account = ""
    @State private var flip = false
    @State private var guessed = false

    var body: some View {
        let p = Money.parse(text, flip: flip)
        VStack(alignment: .leading, spacing: 10) {
            Text("Import \(url.lastPathComponent)").font(.headline)
            TextField("Which account is this? (e.g. Chase checking, Apple Card)", text: $account).textFieldStyle(.roundedBorder)
            Toggle("Charges show as positive numbers in this file (most credit cards)", isOn: $flip)
            if guessed { Text("Most amounts in this file are positive, so it was switched on for you. Check the rows below.").font(.caption).foregroundStyle(.orange) }
            Text("\(p.rows.count) transactions found" + (p.skipped > 0 ? ", \(p.skipped) lines skipped (not a transaction)" : "") + (p.note.isEmpty ? "" : ". " + p.note))
                .font(.caption).foregroundStyle(.secondary)
            List(p.rows.prefix(12), id: \.self) { r in
                HStack {
                    Text(r.day).font(.caption.monospaced())
                    Text(r.desc).font(.caption).lineLimit(1)
                    Spacer()
                    Text(Money.fmt(r.cents)).font(.caption.monospacedDigit()).foregroundStyle(r.cents < 0 ? .primary : Color.green)
                    Text(Money.categorize(r.desc, cents: r.cents, rules: m.rules, me: m.myNames)).font(.caption2).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                }
            }.frame(minHeight: 260)
            Text("Money out should be negative (−), money in positive. Importing the same file twice adds nothing.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done() }
                Button("Import \(p.rows.count)") {
                    let r = m.save(p.rows, account: account.trimmingCharacters(in: .whitespaces), source: url.lastPathComponent)
                    m.message = "Imported \(r.added) from \(url.lastPathComponent)" + (r.dupes > 0 ? " (\(r.dupes) were already there)" : "")
                    done()
                }.keyboardShortcut(.defaultAction).disabled(p.rows.isEmpty)
            }
        }
        .padding(16).frame(width: 640)
        .onAppear { if Money.parse(text, flip: false).mostlyPositive { flip = true; guessed = true } }
    }
}

struct OverviewPage: View {
    @EnvironmentObject var m: MoneyStore
    var importCSV: () -> Void
    @State private var span = "30"
    @State private var editingNames = false

    var body: some View {
        let cutoff = span == "all" ? "" : String(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(Int(span) ?? 30) * 86_400)).prefix(10))
        let t = m.txns.filter { $0.day >= cutoff }
        let s = Money.summary(t)
        let reps = Money.repeating(m.txns)
        let tied = m.items.filter { $0.status != "sold" }.reduce(0) { $0 + $1.cost }
        let profit = m.items.filter { $0.status == "sold" }.reduce(0) { $0 + ($1.sold ?? 0) - $1.cost }
        let owed = m.debts.filter { !["paid", "settled"].contains($0.status) }.reduce(0) { $0 + max(0, $1.balance - m.paid($1)) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if m.txns.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No transactions yet.").font(.headline)
                        Text("On your bank's website, find \"Download transactions\" (or \"Export\") and choose CSV. Then use Import bank CSV… at the top right for each file. It stays on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Picker("", selection: $span) {
                    Text("Last 30 days").tag("30"); Text("90 days").tag("90"); Text("Year").tag("365"); Text("Everything").tag("all")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                HStack(spacing: 24) {
                    stat("In", s.income, .green); stat("Out", -s.spent, .primary); stat("Left over", s.income - s.spent, s.income >= s.spent ? .green : .red)
                    stat("Debts left", owed, owed > 0 ? .red : .secondary)
                    stat("Tied up in inventory", tied, .secondary); stat("Inventory profit (sold)", profit, profit >= 0 ? .green : .red)
                }
                HStack(spacing: 8) {
                    Text("Moved between my own accounts: \(Money.fmt(s.transfersOut)) out, \(Money.fmt(s.transfersIn)) in. Transfers aren't counted as in, out or left over.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("My names…") { editingNames = true }.controlSize(.small)
                        .help("Your own names and own-account wording. Money to or from them counts as a transfer, not income or spending.")
                }
                section("Where it went") { bars(s.byCategory, total: s.spent) }
                section("Top places") { bars(s.byMerchant, total: s.spent) }
                section("Repeating charges (about \(Money.fmt(reps.reduce(0) { $0 + $1.monthly }))/month)") {
                    if reps.isEmpty { Text("None found yet. Needs at least two months of transactions.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(reps.prefix(25), id: \.self) { r in
                        HStack {
                            Text(r.merchant.capitalized).font(.callout)
                            Text("\(r.months) months · last \(r.last)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Money.fmt(r.monthly)).font(.callout.monospacedDigit())
                        }
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $editingNames) { MyNamesSheet { editingNames = false }.environmentObject(m) }
    }

    private func stat(_ label: String, _ c: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Money.fmt(c)).font(.title3.monospacedDigit().bold()).foregroundStyle(color)
        }
    }
    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); c() }
    }
    @ViewBuilder private func bars(_ rows: [(String, Int)], total: Int) -> some View {
        if rows.isEmpty { Text("Nothing in this period.").font(.caption).foregroundStyle(.secondary) }
        ForEach(rows.prefix(12), id: \.0) { r in
            HStack(spacing: 8) {
                Text(r.0.isEmpty ? "Other" : r.0).font(.callout).frame(width: 170, alignment: .leading).lineLimit(1)
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(2, 280 * CGFloat(r.1) / CGFloat(max(total, 1))), height: 12)
                Text(Money.fmt(r.1)).font(.callout.monospacedDigit())
                Text(total > 0 ? "\(Int((Double(r.1) / Double(total) * 100).rounded()))%" : "").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TxnsPage: View {
    @EnvironmentObject var m: MoneyStore
    @State private var search = ""
    @State private var cat = "all"
    @State private var acct = "all"
    @State private var remember = true
    @State private var adding = false
    @State private var editing: Money.Txn?

    var body: some View {
        let q = search.lowercased()
        let labels = m.accountLabels
        let shown = m.txns.filter { (cat == "all" || $0.category == cat) && (acct == "all" || Money.accountKey($0.account) == acct) && (q.isEmpty || $0.desc.lowercased().contains(q) || $0.note.lowercased().contains(q) || $0.account.lowercased().contains(q)) }
        VStack(spacing: 6) {
            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("", selection: $cat) { Text("All categories").tag("all"); ForEach(Money.categories, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 170)
                Picker("", selection: $acct) {
                    Text("All accounts").tag("all"); ForEach(labels.sorted { $0.value < $1.value }, id: \.key) { Text($0.value).tag($0.key) }
                }.labelsHidden().frame(width: 150)
                Toggle("Changing a category applies to the same place everywhere", isOn: $remember).font(.caption)
                Spacer()
                Text("\(shown.count) · \(Money.fmt(shown.reduce(0) { $0 + $1.cents }))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Add…") { adding = true }
            }.padding(.horizontal, 10).padding(.top, 8)
            Table(shown) {
                TableColumn("Date") { t in Text(t.day).font(.caption.monospaced()) }.width(86)
                TableColumn("Description") { t in Text(t.desc).lineLimit(1).help(t.desc + (t.account.isEmpty ? "" : " · " + (labels[Money.accountKey(t.account)] ?? t.account))) }
                TableColumn("Account") { t in Text(labels[Money.accountKey(t.account)] ?? t.account).font(.caption).lineLimit(1) }.width(90)
                TableColumn("Amount") { t in Text(Money.fmt(t.cents)).monospacedDigit().foregroundStyle(t.cents < 0 ? Color.primary : Color.green) }.width(100)
                TableColumn("Category") { t in
                    Picker("", selection: Binding(get: { t.category }, set: { m.setCategory(t, $0, remember: remember) })) {
                        ForEach(Money.categories, id: \.self) { Text($0).tag($0) }
                        if !Money.categories.contains(t.category) { Text(t.category.isEmpty ? "—" : t.category).tag(t.category) }
                    }.labelsHidden()
                }.width(150)
                TableColumn("Contact") { t in
                    Picker("", selection: Binding(get: { t.contactID ?? 0 }, set: { m.link(t, contact: $0 == 0 ? nil : $0) })) {
                        Text("—").tag(0); ForEach(m.contacts) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                }.width(130)
                TableColumn("Note") { t in NoteField(text: t.note) { m.setNote(t, $0) } }
                TableColumn("") { t in Button("Edit…") { editing = t }.controlSize(.mini).help("Change the date, amount, description, account, category or note") }.width(54)
            }
        }
        .sheet(isPresented: $adding) { AddTxnSheet { adding = false }.environmentObject(m) }
        .background(EmptyView().sheet(item: $editing) { t in EditTxnSheet(t: t) { editing = nil }.environmentObject(m) })
    }
}

/// Money → Where it goes → My names…: one name or pattern per line. Saving re-sorts the transactions the app sorted
/// (not ones you changed by hand). Only your own names: other people, family included, are real money in or out.
struct MyNamesSheet: View {
    @EnvironmentObject var m: MoneyStore
    var done: () -> Void
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("My names and own accounts").font(.headline)
            Text("One per line. A transaction whose description contains one of these (any capitals) is money moving between your own accounts: it goes under Transfers and isn't counted as income or spending. Put only your own names here, not other people's.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 180).border(Color.secondary.opacity(0.3))
            HStack {
                Button("Defaults") { text = Money.defaultMyNames.joined(separator: "\n") }
                Spacer()
                Button("Cancel") { done() }
                Button("Save") {
                    let n = m.setMyNames(Money.names(text))
                    m.message = "My names saved; \(n) transaction\(n == 1 ? "" : "s") re-sorted"
                    done()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 460)
        .onAppear { text = m.myNames.joined(separator: "\n") }
    }
}

/// A text field that saves when you press Return or click away.
struct NoteField: View {
    var text: String
    var save: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $draft).textFieldStyle(.plain).focused($focused)
            .onAppear { draft = text }.onChange(of: text) { _, v in if !focused { draft = v } }
            .onSubmit { if draft != text { save(draft) } }
            .onChange(of: focused) { _, f in if !f && draft != text { save(draft) } }
    }
}

struct AddTxnSheet: View {
    @EnvironmentObject var m: MoneyStore
    var done: () -> Void
    @State private var day = MoneyStore.today()
    @State private var amount = ""
    @State private var out = true
    @State private var desc = ""
    @State private var account = ""
    @State private var cat = ""
    @State private var note = ""
    var body: some View {
        let c = Money.cents(amount).map { out ? -abs($0) : abs($0) }
        Form {
            TextField("Date (yyyy-mm-dd)", text: $day)
            Picker("", selection: $out) { Text("Money out").tag(true); Text("Money in").tag(false) }.pickerStyle(.segmented)
            TextField("Amount", text: $amount)
            TextField("What / who", text: $desc)
            TextField("Account (cash, Venmo…)", text: $account)
            Picker("Category", selection: $cat) { Text("Guess").tag(""); ForEach(Money.categories, id: \.self) { Text($0).tag($0) } }
            TextField("Note", text: $note)
            HStack {
                Spacer(); Button("Cancel") { done() }
                Button("Add") { if let c, let d = Money.day(day) { m.addManual(day: d, cents: c, desc: desc, account: account, category: cat, note: note); done() } }
                    .keyboardShortcut(.defaultAction).disabled(c == nil || Money.day(day) == nil || desc.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(16).frame(width: 420)
    }
}

struct ItemsPage: View {
    @EnvironmentObject var m: MoneyStore
    @State private var name = ""
    @State private var cost = ""
    @State private var ask = ""
    @State private var cat = ""
    @State private var selling: Money.Item?
    @State private var soldFor = ""
    @State private var addIncome = true
    @State private var editing: Money.Item?

    var body: some View {
        let open = m.items.filter { $0.status != "sold" }
        VStack(spacing: 6) {
            HStack {
                TextField("Item", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                TextField("Category", text: $cat).textFieldStyle(.roundedBorder).frame(width: 110)
                TextField("Paid", text: $cost).textFieldStyle(.roundedBorder).frame(width: 80)
                TextField("Asking", text: $ask).textFieldStyle(.roundedBorder).frame(width: 80)
                Button("Add") {
                    m.addItem(Money.Item(name: name, category: cat, cost: abs(Money.cents(cost) ?? 0), ask: Money.cents(ask).map(abs)))
                    name = ""; cost = ""; ask = ""
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (!cost.isEmpty && Money.cents(cost) == nil))
                Spacer()
                Text("\(open.count) not sold · \(Money.fmt(open.reduce(0) { $0 + $1.cost })) tied up").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.top, 8)
            Table(m.items) {
                TableColumn("Item") { i in Text(i.name).lineLimit(1) }
                TableColumn("Category") { i in Text(i.category).foregroundStyle(.secondary) }.width(110)
                TableColumn("Status") { i in
                    Picker("", selection: Binding(get: { i.status }, set: { s in if s == "sold" { selling = i; soldFor = i.ask.map { String(format: "%.2f", Double($0) / 100) } ?? "" } else { m.setStatus(i, s) } })) {
                        Text("Have").tag("have"); Text("Listed").tag("listed"); Text("Sold").tag("sold")
                    }.labelsHidden().disabled(i.status == "sold")
                }.width(100)
                TableColumn("Paid") { i in Text(Money.fmt(i.cost)).monospacedDigit() }.width(90)
                TableColumn("Asking") { i in Text(i.ask.map(Money.fmt) ?? "").monospacedDigit() }.width(90)
                TableColumn("Sold for") { i in Text(i.sold.map(Money.fmt) ?? "").monospacedDigit() }.width(90)
                TableColumn("Profit") { i in
                    if let s = i.sold { Text(Money.fmt(s - i.cost)).monospacedDigit().foregroundStyle(s >= i.cost ? Color.green : Color.red) }
                }.width(90)
                TableColumn("Bought / sold") { i in Text([i.bought, i.soldDay].compactMap { $0 }.joined(separator: " → ")).font(.caption.monospaced()) }.width(170)
                TableColumn("") { i in Button("Edit…") { editing = i }.controlSize(.mini) }.width(54)
            }
        }
        .background(EmptyView().sheet(item: $editing) { i in EditItemSheet(i: i) { editing = nil }.environmentObject(m) })
        .sheet(item: $selling) { i in
            VStack(alignment: .leading, spacing: 10) {
                Text("Sold: \(i.name)").font(.headline)
                TextField("Sold for", text: $soldFor).textFieldStyle(.roundedBorder)
                Toggle("Also add it to Transactions as money in", isOn: $addIncome)
                HStack {
                    Spacer(); Button("Cancel") { selling = nil }
                    Button("Mark sold") { if let c = Money.cents(soldFor) { m.sell(i, cents: abs(c), day: MoneyStore.today(), addIncome: addIncome); selling = nil } }
                        .keyboardShortcut(.defaultAction).disabled(Money.cents(soldFor) == nil)
                }
            }.padding(16).frame(width: 360)
        }
    }
}

struct ContactsPage: View {
    @EnvironmentObject var m: MoneyStore
    @State private var new = Money.Contact()
    @State private var editing: Money.Contact?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("Name", text: $new.name).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Picker("", selection: $new.kind) { ForEach(["customer", "vendor", "lead", "person"], id: \.self) { Text($0.capitalized).tag($0) } }
                    .labelsHidden().frame(width: 110)
                TextField("Phone", text: $new.phone).textFieldStyle(.roundedBorder).frame(width: 130)
                TextField("Email", text: $new.email).textFieldStyle(.roundedBorder).frame(width: 180)
                Button("Add") { m.addContact(new); new = Money.Contact() }.disabled(new.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }.padding(.horizontal, 10).padding(.top, 8)
            Table(m.contacts) {
                TableColumn("Name") { c in Text(c.name) }
                TableColumn("Kind") { c in Text(c.kind.capitalized).foregroundStyle(.secondary) }.width(80)
                TableColumn("Phone / email") { c in Text([c.phone, c.email].filter { !$0.isEmpty }.joined(separator: " · ")).textSelection(.enabled) }
                TableColumn("Money with them") { c in
                    let t = m.txns.filter { $0.contactID == c.id }
                    Text(t.isEmpty ? "" : "\(Money.fmt(t.reduce(0) { $0 + $1.cents })) · \(t.count)").monospacedDigit()
                }.width(130)
                TableColumn("Last contact") { c in
                    HStack { Text(c.lastContact ?? "—").font(.caption.monospaced()); Button("Today") { m.touch(c) }.controlSize(.mini) }
                }.width(150)
                TableColumn("Note") { c in NoteField(text: c.note) { m.setContactNote(c, $0) } }
                TableColumn("") { c in Button("Edit…") { editing = c }.controlSize(.mini) }.width(54)
            }
        }
        .sheet(item: $editing) { c in EditContactSheet(c: c) { editing = nil }.environmentObject(m) }
    }
}

struct DebtsPage: View {
    @EnvironmentObject var m: MoneyStore
    @State private var new = Money.Debt()
    @State private var bal = ""
    @State private var notice = ""
    @State private var lastPaid = ""
    @State private var years = ""
    @State private var paying: Money.Debt?
    @State private var payAmt = ""
    @State private var payAcct = ""
    @State private var offering: Money.Debt?
    @State private var settling: Money.Debt?
    @State private var editing: Money.Debt?

    var body: some View {
        let open = m.debts.filter { !["paid", "settled"].contains($0.status) }
        let today = MoneyStore.today()
        let offers = Money.openOffers(m.debts, paid: { m.paid($0) }, today: today)
        let unwritten = open.filter { $0.offer != nil && !$0.offerInWriting }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Original company", text: $new.creditor).textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                TextField("Collector now", text: $new.collector).textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                TextField("Last 4", text: $new.acct).textFieldStyle(.roundedBorder).frame(width: 60)
                TextField("They say you owe", text: $bal).textFieldStyle(.roundedBorder).frame(width: 120)
                TextField("First notice (date)", text: $notice).textFieldStyle(.roundedBorder).frame(width: 130)
                TextField("Your last payment (date)", text: $lastPaid).textFieldStyle(.roundedBorder).frame(width: 160)
                TextField("State limit (yrs)", text: $years).textFieldStyle(.roundedBorder).frame(width: 110)
                Button("Add") {
                    var d = new; d.balance = abs(Money.cents(bal) ?? 0)
                    d.firstNotice = Money.day(notice); d.lastPayment = Money.day(lastPaid); d.limitYears = Int(years)
                    m.addDebt(d); new = Money.Debt(); bal = ""; notice = ""; lastPaid = ""; years = ""
                }.disabled(new.creditor.trimmingCharacters(in: .whitespaces).isEmpty || Money.cents(bal) == nil
                           || (!notice.isEmpty && Money.day(notice) == nil) || (!lastPaid.isEmpty && Money.day(lastPaid) == nil)
                           || (!years.isEmpty && Int(years) == nil))
            }.padding(.horizontal, 10).padding(.top, 8)
            Text("\(open.count) open · \(Money.fmt(open.reduce(0) { $0 + max(0, $1.balance - m.paid($1)) })) left · \(Money.fmt(m.debts.reduce(0) { $0 + m.paid($1) })) paid so far. "
                 + "Dates: the proof window is 30 days from the first notice; the lawsuit limit is an estimate from your last payment and the years you enter. Check your state's rules.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10)
            if offers.count > 0 || unwritten > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    if offers.count > 0 {
                        Text("Settlement offers: \(offers.count) open, \(Money.fmt(offers.offers)) to pay in full for less. You'd save \(Money.fmt(offers.saves)) in all.")
                            .font(.caption.bold())
                    }
                    if unwritten > 0 {
                        Text("⚠︎ \(unwritten) offer\(unwritten == 1 ? " isn't" : "s aren't") in writing yet. " + Money.writingWarning)
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(.horizontal, 10)
            }
            Table(m.debts) {
                TableColumn("Who") { d in
                    VStack(alignment: .leading) {
                        Text(d.creditor + (d.acct.isEmpty ? "" : " ··" + d.acct)).lineLimit(1)
                        if !d.collector.isEmpty { Text("collector: " + d.collector).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                TableColumn("Owed") { d in Text(Money.fmt(d.balance)).monospacedDigit() }.width(90)
                TableColumn("Paid") { d in Text(Money.fmt(m.paid(d))).monospacedDigit() }.width(80)
                TableColumn("Left") { d in Text(Money.fmt(max(0, d.balance - m.paid(d)))).monospacedDigit().bold() }.width(90)
                TableColumn("Status") { d in
                    Picker("", selection: Binding(get: { d.status }, set: { m.setDebtStatus(d, $0) })) {
                        ForEach(Money.debtStatuses, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }.width(140)
                TableColumn("Ask for proof by") { d in
                    if let e = Money.proofWindowEnds(d) {
                        Text(e).font(.caption.monospaced()).foregroundStyle(d.proofAsked == nil && e >= today ? Color.orange : Color.secondary)
                            .help(d.proofAsked.map { "Asked on " + $0 } ?? (e >= today ? "Still inside the 30 days" : "The 30 days have passed; you can still ask"))
                    }
                }.width(110)
                TableColumn("Lawsuit limit ~") { d in
                    if let e = Money.limitEnds(d) { Text(e).font(.caption.monospaced()).foregroundStyle(e < today ? Color.green : Color.secondary)
                        .help(e < today ? "Probably past the limit. A payment may restart it in some states; check before paying." : "Estimate") }
                }.width(110)
                TableColumn("Settlement") { d in
                    let left = max(0, d.balance - m.paid(d)), warns = Money.offerWarnings(d, today: today)
                    VStack(alignment: .leading, spacing: 2) {
                        if let o = d.offer {
                            let sv = Money.savings(left: left, offer: o)
                            Text("\(Money.fmt(o))" + (sv.map { " · save \(Money.fmt($0.cents)) (\($0.percent)%)" } ?? "")).font(.caption.monospacedDigit()).lineLimit(1)
                            if let w = warns.first {
                                Text("⚠︎ " + w).font(.caption2).foregroundStyle(.orange).lineLimit(2).help(warns.joined(separator: "\n"))
                            } else if d.offerInWriting {
                                Text("in writing" + (d.offerRef.isEmpty ? "" : " · " + d.offerRef)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        HStack(spacing: 4) {
                            Button("Edit…") { editing = d }.controlSize(.mini).help("Change who it's with, last 4, the amount they say you owe, dates, state limit or note")
                            Button("Payment…") { paying = d; payAmt = ""; payAcct = "" }.controlSize(.mini)
                            Button(d.offer == nil ? "Offer…" : "Edit offer…") { offering = d }.controlSize(.mini)
                            if d.offer != nil && !["paid", "settled"].contains(d.status) {
                                Button("Paid settlement…") { settling = d }.controlSize(.mini)
                            }
                        }
                    }
                }.width(min: 260, ideal: 300)
                TableColumn("Note") { d in NoteField(text: d.note) { m.setDebtNote(d, $0) } }
            }
        }
        .sheet(item: $paying) { d in
            VStack(alignment: .leading, spacing: 10) {
                Text("Payment to \(d.collector.isEmpty ? d.creditor : d.collector)").font(.headline)
                TextField("Amount", text: $payAmt).textFieldStyle(.roundedBorder)
                TextField("Paid from (account)", text: $payAcct).textFieldStyle(.roundedBorder)
                if let e = Money.limitEnds(d), e < today {
                    Text("This debt may be past your state's lawsuit limit. In some states a payment restarts it. Check before paying.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("It's added to Transactions as Debt & Fees, linked to this debt.").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Spacer(); Button("Cancel") { paying = nil }
                    Button("Record") { if let c = Money.cents(payAmt) { m.pay(d, cents: c, day: today, account: payAcct); paying = nil } }
                        .keyboardShortcut(.defaultAction).disabled(Money.cents(payAmt) == nil)
                }
            }.padding(16).frame(width: 380)
        }
        .background(EmptyView().sheet(item: $offering) { d in OfferSheet(d: d) { offering = nil }.environmentObject(m) })
        .background(EmptyView().sheet(item: $settling) { d in SettleSheet(d: d) { settling = nil }.environmentObject(m) })
        .background(EmptyView().sheet(item: $editing) { d in EditDebtSheet(d: d) { editing = nil }.environmentObject(m) })
    }
}

/// Debts → Offer…: a settlement offer ("pay this much and it's done"). Every field is optional except the amount.
struct OfferSheet: View {
    @EnvironmentObject var m: MoneyStore
    let d: Money.Debt
    var done: () -> Void
    @State private var amt = ""
    @State private var day = ""
    @State private var deadline = ""
    @State private var from = ""
    @State private var writing = false
    @State private var ref = ""
    var body: some View {
        let left = max(0, d.balance - m.paid(d))
        let o = Money.cents(amt).map(abs)
        let preview = Money.Debt(status: d.status, offer: o, offerDeadline: Money.day(deadline), offerInWriting: writing)
        let badDates = (!day.isEmpty && Money.day(day) == nil) || (!deadline.isEmpty && Money.day(deadline) == nil)
        VStack(alignment: .leading, spacing: 10) {
            Text("Settlement offer: \(d.collector.isEmpty ? d.creditor : d.collector)").font(.headline)
            Text("They say you owe \(Money.fmt(d.balance))" + (left == d.balance ? "." : "; \(Money.fmt(left)) is left after what you've paid."))
                .font(.caption).foregroundStyle(.secondary)
            TextField("They'll accept (amount)", text: $amt).textFieldStyle(.roundedBorder)
            if let sv = Money.savings(left: left, offer: o) {
                Text("You'd save \(Money.fmt(sv.cents)) (\(sv.percent)% off what's left).").font(.callout.bold())
            }
            HStack {
                TextField("Offered on (date)", text: $day).textFieldStyle(.roundedBorder)
                TextField("Offer ends (date)", text: $deadline).textFieldStyle(.roundedBorder)
            }
            Picker("Offered by", selection: $from) {
                Text("—").tag(""); Text("the collector").tag("collector"); Text("the original creditor").tag("original creditor")
            }
            Toggle("Offer is in writing", isOn: $writing)
            TextField("Note or reference (e.g. letter dated …)", text: $ref).textFieldStyle(.roundedBorder)
            ForEach(Money.offerWarnings(preview, today: MoneyStore.today()), id: \.self) {
                Text("⚠︎ " + $0).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if d.offer != nil {
                    Button("Remove offer") { m.setOffer(d, offer: nil, day: nil, deadline: nil, from: "", inWriting: false, ref: ""); done() }
                }
                Spacer(); Button("Cancel") { done() }
                Button("Save") {
                    m.setOffer(d, offer: o, day: Money.day(day), deadline: Money.day(deadline), from: from, inWriting: writing,
                               ref: ref.trimmingCharacters(in: .whitespaces))
                    done()
                }.keyboardShortcut(.defaultAction).disabled(o == nil || o == 0 || badDates)
            }
        }
        .padding(16).frame(width: 420)
        .onAppear {
            amt = d.offer.map { String(format: "%.2f", Double($0) / 100) } ?? ""; day = d.offerDay ?? ""; deadline = d.offerDeadline ?? ""
            from = d.offerFrom; writing = d.offerInWriting; ref = d.offerRef
        }
    }
}

/// Debts → Paid settlement…: records the payment (linked Debt & Fees transaction), marks the debt settled, keeps the offer.
struct SettleSheet: View {
    @EnvironmentObject var m: MoneyStore
    let d: Money.Debt
    var done: () -> Void
    @State private var amt = ""
    @State private var acct = ""
    @State private var day = ""
    var body: some View {
        let today = MoneyStore.today()
        VStack(alignment: .leading, spacing: 10) {
            Text("Paid the settlement: \(d.collector.isEmpty ? d.creditor : d.collector)").font(.headline)
            TextField("Amount paid", text: $amt).textFieldStyle(.roundedBorder)
            TextField("Paid on (date)", text: $day).textFieldStyle(.roundedBorder)
            TextField("Paid from (account)", text: $acct).textFieldStyle(.roundedBorder)
            ForEach(Money.offerWarnings(d, today: today), id: \.self) {
                Text("⚠︎ " + $0).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let e = Money.limitEnds(d), e < today {
                Text("This debt may be past your state's lawsuit limit. In some states a payment restarts it. Check before paying.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("It's added to Transactions as Debt & Fees, linked to this debt, and the debt is marked settled. The offer is kept for the record.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(); Button("Cancel") { done() }
                Button("Record") {
                    if let c = Money.cents(amt), let dd = Money.day(day) { m.paySettlement(d, cents: c, day: dd, account: acct); done() }
                }.keyboardShortcut(.defaultAction).disabled(Money.cents(amt) == nil || Money.cents(amt) == 0 || Money.day(day) == nil)
            }
        }
        .padding(16).frame(width: 400)
        .onAppear { amt = d.offer.map { String(format: "%.2f", Double($0) / 100) } ?? ""; day = today }
    }
}

// MARK: Edit… sheets (Transactions, Debts, Inventory, Contacts)

extension Money {
    /// 12345 → "123.45" for an edit box (no $ or commas, so it reads back the same).
    nonisolated static func plain(_ cents: Int?) -> String { cents.map { String(format: "%.2f", Double(abs($0)) / 100) } ?? "" }
    /// An optional date box: empty = none (ok), a date = yyyy-mm-dd, anything else = bad (nil outer).
    nonisolated static func optDay(_ s: String) -> String?? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        if let d = Money.day(t) { return .some(d) }
        return .none
    }
    /// An optional whole-number box: empty = none, a number = it, anything else = bad (nil outer).
    nonisolated static func optInt(_ s: String) -> Int?? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        if let n = Int(t), n >= 0 { return .some(n) }
        return .none
    }
    /// An optional amount box: empty = none, a number = cents, anything else = bad (nil outer).
    nonisolated static func optCents(_ s: String) -> Int?? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        if let c = Money.cents(t) { return .some(abs(c)) }
        return .none
    }
}

struct EditTxnSheet: View {
    @EnvironmentObject var m: MoneyStore
    let t: Money.Txn
    var done: () -> Void
    @State private var day = ""
    @State private var amount = ""
    @State private var out = true
    @State private var desc = ""
    @State private var account = ""
    @State private var cat = ""
    @State private var note = ""
    var body: some View {
        let c = Money.cents(amount).map { out ? -abs($0) : abs($0) }
        Form {
            Text("Edit transaction").font(.headline)
            TextField("Date (yyyy-mm-dd)", text: $day)
            Picker("", selection: $out) { Text("Money out").tag(true); Text("Money in").tag(false) }.pickerStyle(.segmented)
            TextField("Amount", text: $amount)
            TextField("What / who", text: $desc)
            TextField("Account", text: $account)
            Picker("Category", selection: $cat) {
                ForEach(Money.categories, id: \.self) { Text($0).tag($0) }
                if !Money.categories.contains(cat) { Text(cat.isEmpty ? "—" : cat).tag(cat) }
            }
            TextField("Note", text: $note)
            if t.debtID != nil || t.itemID != nil {
                Text(t.debtID != nil ? "This is a payment linked to a debt; changing the amount changes what's paid on it." : "This is linked to an inventory sale.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Spacer(); Button("Cancel") { done() }
                Button("Save") {
                    if let c, let d = Money.day(day) {
                        var x = t; x.day = d; x.cents = c; x.desc = desc.trimmingCharacters(in: .whitespaces); x.account = account.trimmingCharacters(in: .whitespaces)
                        x.category = cat; x.note = note; m.updateTxn(x); m.message = "Transaction saved"; done()
                    }
                }.keyboardShortcut(.defaultAction).disabled(c == nil || Money.day(day) == nil || desc.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 420)
        .onAppear { day = t.day; amount = Money.plain(t.cents); out = t.cents < 0; desc = t.desc; account = t.account; cat = t.category; note = t.note }
    }
}

struct EditDebtSheet: View {
    @EnvironmentObject var m: MoneyStore
    let d: Money.Debt
    var done: () -> Void
    @State private var x = Money.Debt()
    @State private var bal = ""
    @State private var notice = ""
    @State private var asked = ""
    @State private var lastPaid = ""
    @State private var years = ""
    var body: some View {
        let n = Money.optDay(notice), a = Money.optDay(asked), l = Money.optDay(lastPaid)
        let y = Money.optInt(years)
        let ok = !x.creditor.trimmingCharacters(in: .whitespaces).isEmpty && Money.cents(bal) != nil && n != nil && a != nil && l != nil && y != nil
        Form {
            Text("Edit debt").font(.headline)
            TextField("Original company", text: $x.creditor)
            TextField("Collector now", text: $x.collector)
            TextField("Last 4", text: $x.acct)
            TextField("They say you owe", text: $bal)
            Picker("Status", selection: $x.status) { ForEach(Money.debtStatuses, id: \.self) { Text($0).tag($0) } }
            TextField("First notice (date)", text: $notice)
            TextField("Asked for proof on (date)", text: $asked)
            TextField("Your last payment (date)", text: $lastPaid)
            TextField("State limit (years)", text: $years)
            TextField("Note", text: $x.note)
            Text("Payments and any settlement offer stay as they are. Dates: yyyy-mm-dd, or leave empty.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("Cancel") { done() }
                Button("Save") {
                    guard ok, let b = Money.cents(bal), let n, let a, let l, let y else { return }
                    var s = x; s.creditor = s.creditor.trimmingCharacters(in: .whitespaces); s.collector = s.collector.trimmingCharacters(in: .whitespaces)
                    s.balance = abs(b); s.firstNotice = n; s.proofAsked = a; s.lastPayment = l; s.limitYears = y
                    m.updateDebt(s); m.message = "Debt saved"; done()
                }.keyboardShortcut(.defaultAction).disabled(!ok)
            }
        }
        .padding(16).frame(width: 420)
        .onAppear { x = d; bal = Money.plain(d.balance); notice = d.firstNotice ?? ""; asked = d.proofAsked ?? ""; lastPaid = d.lastPayment ?? ""; years = d.limitYears.map(String.init) ?? "" }
    }
}

struct EditItemSheet: View {
    @EnvironmentObject var m: MoneyStore
    let i: Money.Item
    var done: () -> Void
    @State private var x = Money.Item()
    @State private var cost = ""
    @State private var ask = ""
    @State private var sold = ""
    @State private var bought = ""
    @State private var soldDay = ""
    var body: some View {
        let a = Money.optCents(ask), sc = Money.optCents(sold), b = Money.optDay(bought), sd = Money.optDay(soldDay)
        let ok = !x.name.trimmingCharacters(in: .whitespaces).isEmpty && (cost.isEmpty || Money.cents(cost) != nil) && a != nil && sc != nil && b != nil && sd != nil
        Form {
            Text("Edit item").font(.headline)
            TextField("Item", text: $x.name)
            TextField("Category", text: $x.category)
            Picker("Status", selection: $x.status) { Text("Have").tag("have"); Text("Listed").tag("listed"); Text("Sold").tag("sold") }
            TextField("Paid", text: $cost)
            TextField("Asking", text: $ask)
            TextField("Sold for", text: $sold)
            TextField("Bought (date)", text: $bought)
            TextField("Sold (date)", text: $soldDay)
            TextField("Note", text: $x.note)
            Text("Changing this doesn't change a sale already added to Transactions; edit that one there.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("Cancel") { done() }
                Button("Save") {
                    guard ok, let a, let sc, let b, let sd else { return }
                    var s = x; s.name = s.name.trimmingCharacters(in: .whitespaces); s.cost = abs(Money.cents(cost) ?? 0); s.ask = a; s.sold = sc; s.bought = b; s.soldDay = sd
                    m.updateItem(s); m.message = "Item saved"; done()
                }.keyboardShortcut(.defaultAction).disabled(!ok)
            }
        }
        .padding(16).frame(width: 400)
        .onAppear { x = i; cost = Money.plain(i.cost); ask = Money.plain(i.ask); sold = Money.plain(i.sold); bought = i.bought ?? ""; soldDay = i.soldDay ?? "" }
    }
}

struct EditContactSheet: View {
    @EnvironmentObject var m: MoneyStore
    let c: Money.Contact
    var done: () -> Void
    @State private var x = Money.Contact()
    @State private var last = ""
    var body: some View {
        let l = Money.optDay(last)
        let ok = !x.name.trimmingCharacters(in: .whitespaces).isEmpty && l != nil
        Form {
            Text("Edit contact").font(.headline)
            TextField("Name", text: $x.name)
            Picker("Kind", selection: $x.kind) { ForEach(["customer", "vendor", "lead", "person"], id: \.self) { Text($0.capitalized).tag($0) } }
            TextField("Phone", text: $x.phone)
            TextField("Email", text: $x.email)
            TextField("Last contact (date)", text: $last)
            TextField("Note", text: $x.note)
            HStack {
                Spacer(); Button("Cancel") { done() }
                Button("Save") {
                    guard ok, let l else { return }
                    var s = x; s.name = s.name.trimmingCharacters(in: .whitespaces); s.lastContact = l
                    m.updateContact(s); m.message = "Contact saved"; done()
                }.keyboardShortcut(.defaultAction).disabled(!ok)
            }
        }
        .padding(16).frame(width: 380)
        .onAppear { x = c; last = c.lastContact ?? "" }
    }
}

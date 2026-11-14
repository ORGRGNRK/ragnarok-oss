import Foundation
// Runs each parser on the last 200 lines of the real logs and prints what it found.
func lastLines(_ path: String, _ n: Int) -> [String] {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return Array(s.split(separator: "\n").suffix(n)).map(String.init)
}
let home = NSHomeDirectory()
func newest(_ pattern: String) -> String? {
    Glob.expand((pattern as NSString).expandingTildeInPath).max { a, b in
        ((try? FileManager.default.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast) <
        ((try? FileManager.default.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast) }
}
let cases: [(String, String, Parsers.Parser)] = [
    ("claude", "~/.claude/projects/*/*.jsonl", Parsers.claude),
    ("argon", "~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl", Parsers.argon),
    ("grok", "~/.grok/sessions/*/*/chat_history.jsonl", Parsers.grok),
    ("mac-receipts", "~/.ragnarok/receipts-spool.jsonl", Parsers.macReceipts),
]
var failed = false
for (name, pat, p) in cases {
    guard let f = newest(pat) else { print("\(name): NO FILE"); failed = true; continue }
    let evs = lastLines(f, 200).flatMap { p(f, $0) }
    var by: [String: Int] = [:]; for e in evs { by["\(e.actor)/\(e.kind)", default: 0] += 1 }
    print("\(name): \(evs.count) events from \((f as NSString).lastPathComponent)  \(by.sorted { $0.key < $1.key })")
    if evs.isEmpty { failed = true }
    if let e = evs.last { print("   last: [\(e.actor)] \(e.title.oneLine(110))") }
}
// Alexus formats, from sample lines piped in on stdin: first line ai_ssh receipt, rest audit
let input = (String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
if let first = input.first {
    let r = Parsers.alexusReceipts("x", first); print("alexus-receipts: \(r.map { "[\($0.actor)] \($0.title.oneLine(90))" })"); if r.isEmpty { failed = true }
}
for l in input.dropFirst() { let a = Parsers.audit("x", l); print("audit: \(a.map { "[\($0.actor)] \($0.title.oneLine(90))" })") }
let z = Parsers.ownerShell("x", #"{"ts":"2026-10-31T16:00:00Z","cmd":"ls -la","cwd":"/Users/sam","exit":0,"src":"zsh"}"#)
print("owner-shell: \(z.map { "[\($0.actor)] \($0.title)" })"); if z.isEmpty { failed = true }
exit(failed ? 1 : 0)

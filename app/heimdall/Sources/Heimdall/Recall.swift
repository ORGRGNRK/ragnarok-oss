import Foundation

/// Converse-style memory for the terminal: find the parts of the owner's own files that match their message by
/// meaning, and hand them to whichever AI answers. Same logic as ragnarok-relay's converse.py recall():
/// the owner's search-fast.py embeds the question with nomic-embed-text (Ollama on Alexus) and searches the
/// index built by recall/build-corpus.sh (their compile.py + build-matrix.py over ~/Developer, redacted).
/// Missing index, stale index or Alexus down = no notes; the message still goes through.
enum Recall {
    nonisolated static let home = NSHomeDirectory()
    nonisolated static let python = AppPaths.recallScriptsDir + "/.venv/bin/python"
    nonisolated static let script = AppPaths.recallScriptsDir + "/search-fast.py"
    nonisolated static let corpus = home + "/Library/Application Support/Heimdall/corpus/chunks.jsonl"
    nonisolated static let embedURL = LocalConfig.current.ollama + "/v1/embeddings"
    nonisolated static let fallbackEmbedURL = "http://\(LocalConfig.current.alexusTailscale):11434/v1/embeddings"

    struct Hit: Equatable { let score: Double; let label: String; let text: String }

    nonisolated static var ready: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: python) && fm.fileExists(atPath: script)
            && fm.fileExists(atPath: corpus.replacingOccurrences(of: ".jsonl", with: ".vectors.npy"))
    }

    /// converse.py skips logs and raw jsonl dumps: they match everything and say little.
    nonisolated static func keep(path: String?) -> Bool {
        guard let p = path else { return true }
        return !p.contains("/logs/") && !p.hasSuffix(".jsonl")
    }

    /// Parse search-fast.py's JSON line into hits (filtered like converse).
    nonisolated static func parse(_ json: Data) -> [Hit] {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              o["ok"] as? Bool == true, let hits = o["hits"] as? [[String: Any]] else { return [] }
        return hits.compactMap { h in
            let path = h["path"] as? String
            guard keep(path: path), let text = h["text"] as? String, !text.isEmpty else { return nil }
            let label = path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? (h["name"] as? String ?? "note")
            return Hit(score: h["score"] as? Double ?? 0, label: label, text: text)
        }
    }

    /// The block converse.py puts in front of the model. `perHit` trims each excerpt (Apple's small window).
    nonisolated static func block(_ hits: [Hit], perHit: Int = 1200) -> String? {
        guard !hits.isEmpty else { return nil }
        let body = hits.map { h in
            let t = h.text.count > perHit ? String(h.text.prefix(perHit)) + " …" : h.text
            return String(format: "[%.2f] ", h.score) + h.label + "\n" + t
        }.joined(separator: "\n\n---\n\n")
        return "## FROM THEIR OWN NOTES AND FILES (found by meaning, most relevant first)\n\n"
            + "These are real excerpts from their computer. Use them. If they do not answer it, say so.\n\n" + body
    }

    nonisolated static let recallCLI = AppPaths.bundledBin("heimdall-recall")

    /// Run bin/heimdall-recall (the same lookup the terminal AIs can run themselves). nil if it can't run.
    nonisolated static func cli(_ args: [String], timeout: Double = 30) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: recallCLI) else { return nil }
        return await withCheckedContinuation { cont in
            let p = Process(); p.executableURL = URL(fileURLWithPath: recallCLI); p.arguments = args
            var env = ProcessInfo.processInfo.environment; env["RECALL_EMBED_URL"] = embedURL; env.removeValue(forKey: "HEIMDALL_LAUNCHER")
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            p.terminationHandler = { proc in
                timer.cancel()
                let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: proc.terminationStatus == 0 && !s.isEmpty ? s : nil)
            }
            do { try p.run(); DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer) }
            catch { cont.resume(returning: nil) }
        }
    }

    /// Past failures related to the message, or nil when none are on record.
    nonisolated static func failures(for question: String, k: Int = 3) async -> String? {
        guard let s = await cli(["--failures", String(question.prefix(1000)), String(k)], timeout: 10), s.hasPrefix("## ") else { return nil }
        return s
    }

    /// Run search-fast.py (k=6, like converse). Never throws; nil when there's nothing to add.
    nonisolated static func notes(for question: String, perHit: Int = 1200, k: Int = 6) async -> String? {
        guard ready, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let hit = await runSearch(question: question, perHit: perHit, k: k, url: embedURL) { return hit }
        if fallbackEmbedURL != embedURL {
            return await runSearch(question: question, perHit: perHit, k: k, url: fallbackEmbedURL)
        }
        return nil
    }

    nonisolated private static func runSearch(question: String, perHit: Int, k: Int, url: String) async -> String? {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = ["-I", script, corpus, String(question.prefix(2000)), String(k)]
            var env = ProcessInfo.processInfo.environment
            env["RECALL_EMBED_URL"] = url
            env.removeValue(forKey: "HEIMDALL_LAUNCHER")
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            // Alexus slow or down: give up after 15 s rather than hold the message.
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            p.terminationHandler = { proc in
                timer.cancel()
                let d = out.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: proc.terminationStatus == 0 ? block(parse(d), perHit: perHit) : nil)
            }
            do { try p.run(); DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timer) }
            catch { cont.resume(returning: nil) }
        }
    }
}

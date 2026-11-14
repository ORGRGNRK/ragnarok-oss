import Foundation

/// Minimal Markdown splitter: separates fenced code blocks (``` / ~~~) from prose.
/// Prose is later rendered with SwiftUI's inline Markdown support. Handles an
/// unterminated fence (common while a reply is still streaming).
struct MarkdownSegment: Identifiable, Equatable {
    enum Kind: Equatable {
        case text(String)
        case code(language: String, code: String)
    }

    let id: Int
    let kind: Kind
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var fence = ""
        var language = ""

        func flushText() {
            let text = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(MarkdownSegment(id: segments.count, kind: .text(text)))
            }
            textLines.removeAll()
        }

        func flushCode() {
            segments.append(
                MarkdownSegment(
                    id: segments.count,
                    kind: .code(language: language, code: codeLines.joined(separator: "\n"))))
            codeLines.removeAll()
        }

        let lines = source.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inCode {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    flushText()
                    fence = String(trimmed.prefix(3))
                    language = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces).first ?? ""
                    inCode = true
                } else {
                    textLines.append(line)
                }
            } else {
                // A closing fence is a line made only of 3+ fence characters.
                let fenceChar: Character = fence.first ?? "`"
                if trimmed.count >= 3 && trimmed.allSatisfy({ $0 == fenceChar }) {
                    flushCode()
                    inCode = false
                    language = ""
                } else {
                    codeLines.append(line)
                }
            }
        }

        if inCode {
            flushCode()  // still streaming, or the model forgot the closing fence
        } else {
            flushText()
        }
        return segments
    }

    /// Converts a prose block to an AttributedString using inline Markdown
    /// (bold, italics, `code`, links) while preserving line breaks. Headings are
    /// turned into bold lines since inline parsing ignores them.
    static func attributed(_ text: String) -> AttributedString {
        let processed = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return line }
            let hashes = trimmed.prefix(while: { $0 == "#" })
            guard hashes.count <= 6 else { return line }
            let rest = trimmed.dropFirst(hashes.count)
            guard rest.first == " " else { return line }
            let title = rest.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? line : "**\(title)**"
        }.joined(separator: "\n")

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let result = try? AttributedString(markdown: processed, options: options) {
            return result
        }
        return AttributedString(text)
    }
}

import Foundation

public struct DiagnosticReport: Identifiable, Equatable {
    public let id = UUID()
    public var rawMarkdown: String
    public var stageOrCommand: String
    public var exitCode: String
    public var location: String
    public var classification: String
    public var rootCause: String
    public var patch: String
    public var fixCommand: String
    public var verifyCommand: String
    public var preventativeGuard: String

    public init(
        rawMarkdown: String = "",
        stageOrCommand: String = "",
        exitCode: String = "",
        location: String = "",
        classification: String = "",
        rootCause: String = "",
        patch: String = "",
        fixCommand: String = "",
        verifyCommand: String = "",
        preventativeGuard: String = ""
    ) {
        self.rawMarkdown = rawMarkdown
        self.stageOrCommand = stageOrCommand
        self.exitCode = exitCode
        self.location = location
        self.classification = classification
        self.rootCause = rootCause
        self.patch = patch
        self.fixCommand = fixCommand
        self.verifyCommand = verifyCommand
        self.preventativeGuard = preventativeGuard
    }

    public static func fromEvents(_ output: String) -> DiagnosticReport? {
        for line in output.components(separatedBy: "\n").reversed() where line.hasPrefix("PIPELINE_EVENT ") {
            guard let data = String(line.dropFirst(15)).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "diagnosis",
                  let text = event["response"] as? String else { continue }
            let report = parse(from: text)
            guard !report.stageOrCommand.isEmpty, !report.rootCause.isEmpty else { return nil }
            return report
        }
        return nil
    }

    public static func parse(from markdown: String) -> DiagnosticReport {
        var report = DiagnosticReport(rawMarkdown: markdown)

        let sections = markdown.components(separatedBy: "### ")
        for sec in sections {
            let trimmed = sec.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let lines = trimmed.components(separatedBy: "\n")
            guard let header = lines.first else { continue }
            let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            if header.contains("Failure Signature") || header.contains("1.") {
                for line in lines {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.localizedCaseInsensitiveContains("Command") || l.localizedCaseInsensitiveContains("Stage") {
                        report.stageOrCommand = extractValue(from: l)
                    } else if l.localizedCaseInsensitiveContains("Exit Code") || l.localizedCaseInsensitiveContains("Signal") {
                        report.exitCode = extractValue(from: l)
                    } else if l.localizedCaseInsensitiveContains("Location") || l.localizedCaseInsensitiveContains("Failure Point") {
                        report.location = extractValue(from: l)
                    } else if l.localizedCaseInsensitiveContains("Classification") || l.localizedCaseInsensitiveContains("Error Type") {
                        report.classification = extractValue(from: l)
                    }
                }
            } else if header.contains("Root Cause") || header.contains("2.") {
                report.rootCause = body
            } else if header.contains("Remediation") || header.contains("Patch") || header.contains("3.") {
                report.patch = body
            } else if header.contains("Executable Fix") || header.contains("4.") {
                report.fixCommand = extractCodeBlock(from: body)
            } else if header.contains("Verification") || header.contains("5.") {
                report.verifyCommand = extractCodeBlock(from: body)
            } else if header.contains("Preventative") || header.contains("6.") {
                report.preventativeGuard = body
            }
        }

        if report.stageOrCommand.isEmpty && !report.rawMarkdown.isEmpty {
            report.rootCause = report.rawMarkdown
        }

        return report
    }

    private static func extractValue(from line: String) -> String {
        guard let colonIdx = line.firstIndex(of: ":") else { return "" }
        let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return val.replacingOccurrences(of: "`", with: "")
    }

    private static func extractCodeBlock(from text: String) -> String {
        if let start = text.range(of: "```") {
            let afterStart = text[start.upperBound...]
            let codeStart: Substring
            if let newline = afterStart.firstIndex(of: "\n") {
                codeStart = afterStart[afterStart.index(after: newline)...]
            } else {
                codeStart = afterStart
            }
            if let end = codeStart.range(of: "```") {
                return String(codeStart[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(codeStart).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

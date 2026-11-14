import Foundation
import SwiftData

/// One pipeline run: what was asked, what the model said, and what verification found.
/// Saved for every lookup, including ones that fail verification.
@Model
final class Lookup {
    var id: UUID = UUID()
    var date: Date = Date.now
    var query: String = ""
    var modelResponse: String = ""
    var modelFirstLine: String = ""
    /// The verification script's full output (STATUS / Tool / Path / Summary / manual excerpt).
    var verification: String = ""
    /// OK, NOT_FOUND or INVALID, from the STATUS line.
    var status: String = ""
    var tool: String?
    var path: String?
    var summary: String?

    @Relationship(deleteRule: .cascade, inverse: \CommandRun.lookup)
    var runs: [CommandRun] = []

    init(query: String, modelResponse: String, modelFirstLine: String, verification: String) {
        let lines = KeyLines(text: verification)
        self.query = query
        self.modelResponse = modelResponse
        self.modelFirstLine = modelFirstLine
        self.verification = verification
        status = lines.value("STATUS") ?? "UNKNOWN"
        tool = lines.value("Tool")
        path = lines.value("Path")
        // whatis pads names into a column: "ls(1)                    - list directory contents"
        summary = lines.value("Summary").map { $0.replacing(/[ ]{2,}/, with: " ") }
    }

    var sortedRuns: [CommandRun] { runs.sorted { $0.date < $1.date } }
}

/// A command the user asked to run with a lookup's tool, whether it ran or was blocked.
@Model
final class CommandRun {
    var id: UUID = UUID()
    var date: Date = Date.now
    var command: String = ""
    /// SAFE or BLOCKED, from the verify step.
    var verdict: String = ""
    var reason: String?
    /// 0, 1, …, TIMEOUT, OUTPUT_LIMIT or NOT_RUN from the run step; nil when the command was blocked.
    var exit: String?
    var duration: String?
    var output: String?
    var verification: String = ""
    var result: String?
    var lookup: Lookup?

    init(command: String, verification: String, result: String?) {
        let checked = KeyLines(text: verification)
        self.command = command
        self.verification = verification
        self.result = result
        verdict = checked.value("STATUS") ?? "UNKNOWN"
        reason = checked.value("Reason")
        if let result {
            let ran = KeyLines(text: result)
            exit = ran.value("EXIT")
            duration = ran.value("Duration")
            output = ran.block(after: "Output") ?? ran.value("Reason")
        }
    }

    var succeeded: Bool { exit == "0" }
}

import XCTest
@testable import ToolCallParsing

final class FunctionCallSyntaxTests: XCTestCase {
    let tools: Set<String> = ["read_file", "list_dir", "write_file", "run_command", "get_time"]

    private func args(_ c: ParsedToolCall) -> [String: String] {
        c.arguments.compactMapValues { $0 as? String }
    }

    /// Exact reply observed from Qwen2.5-Coder-7B (rendered as text, not executed).
    let observed = "```sh\nrun_command({\"command\": \"python3 number.py\"})\n```"

    func testObservedFencedFunctionCallWithJSON() {
        let r = ToolCallTextParser.parse(observed, allowedNames: tools)
        XCTAssertEqual(r.calls.map(\.name), ["run_command"])
        XCTAssertEqual(args(r.calls[0])["command"], "python3 number.py")
        XCTAssertEqual(r.remainingText, "")
    }

    func testUnfencedFunctionCallWithJSON() {
        let r = ToolCallTextParser.parse(
            #"Running it now: run_command({"command": "python3 number.py"})"#, allowedNames: tools)
        XCTAssertEqual(r.calls.map(\.name), ["run_command"])
        XCTAssertEqual(r.remainingText, "Running it now:")
    }

    func testKeywordArguments() {
        let r = ToolCallTextParser.parse(
            #"write_file(path="a.py", content='print("hi")\nprint(2)')"#, allowedNames: tools)
        XCTAssertEqual(r.calls.map(\.name), ["write_file"])
        XCTAssertEqual(args(r.calls[0])["path"], "a.py")
        XCTAssertEqual(args(r.calls[0])["content"], "print(\"hi\")\nprint(2)")
    }

    func testSinglePositionalMapsToPrimaryArgument() {
        let r = ToolCallTextParser.parse(
            "```\nrun_command(\"python3 number.py\")\nread_file('number.py')\nlist_dir()\n```",
            allowedNames: tools)
        XCTAssertEqual(r.calls.map(\.name), ["run_command", "read_file", "list_dir"])
        XCTAssertEqual(args(r.calls[0])["command"], "python3 number.py")
        XCTAssertEqual(args(r.calls[1])["path"], "number.py")
        XCTAssertEqual(r.remainingText, "")
    }

    func testUnregisteredOrNonCallIsIgnored() {
        for text in [
            #"os.system("rm -rf x")"#,
            #"my_run_command("ls")"#,
            #"obj.read_file("a.txt")"#,
            "Use read_file(path) to read a file.",
            "print(range(5))",
        ] {
            XCTAssertTrue(ToolCallTextParser.parse(text, allowedNames: tools).calls.isEmpty, text)
        }
    }

    func testSnippetOnlyDetection() {
        // A tool call the parser can't run (broken JSON) is a snippet, never a final answer.
        XCTAssertTrue(
            ToolCallTextParser.isOnlyToolSnippet(
                "```sh\nrun_command({\"command\": \"python3 number.py\"\n```", allowedNames: tools))
        XCTAssertTrue(ToolCallTextParser.isOnlyToolSnippet(observed, allowedNames: tools))
        XCTAssertFalse(
            ToolCallTextParser.isOnlyToolSnippet(
                "`range` produces a sequence of integers, e.g. range(5) gives 0 through 4, and it is commonly used in for loops.",
                allowedNames: tools))
        XCTAssertFalse(
            ToolCallTextParser.isOnlyToolSnippet(
                "The script printed 1 to 5 and finished without errors; number.py is in your workspace.",
                allowedNames: tools))
    }
}

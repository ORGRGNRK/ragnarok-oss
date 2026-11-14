import XCTest
@testable import ToolCallParsing

final class ToolCallTextParserTests: XCTestCase {
    let tools: Set<String> = ["read_file", "list_dir", "write_file", "run_command", "get_time"]

    private func args(_ c: ParsedToolCall) -> [String: String] {
        c.arguments.compactMapValues { $0 as? String }
    }

    /// The exact reply observed from Qwen2.5-Coder-7B (MLX) that was rendered as a code block.
    func testObservedFailingFencedReply() {
        let reply = """
            ```json
            {"name": "write_file", "arguments": {"path": "numbers.py", "content": "for i in range(1, 6): print(i)"}}
            ```
            """
        let r = ToolCallTextParser.parse(reply, allowedNames: tools)
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls.first?.name, "write_file")
        XCTAssertEqual(args(r.calls[0])["path"], "numbers.py")
        XCTAssertEqual(args(r.calls[0])["content"], "for i in range(1, 6): print(i)")
        XCTAssertEqual(r.remainingText, "")
    }

    func testExtraTrailingBraceAndPersonaPrefix() {
        let reply = """
            ALEXUS: ```json
            {"name": "write_file", "arguments": {"path": "numbers.py", "content": "for i in range(1, 6): print(i)"}}}
            ```
            """
        let r = ToolCallTextParser.parse(reply, allowedNames: tools)
        XCTAssertEqual(r.calls.map(\.name), ["write_file"])
        XCTAssertEqual(args(r.calls[0])["content"], "for i in range(1, 6): print(i)")
        XCTAssertFalse(r.remainingText.contains("{"))
        XCTAssertFalse(r.remainingText.contains("}"))
    }

    func testHermesTagAndMultipleCalls() {
        let reply = """
            <tool_call>
            {"name": "list_dir", "arguments": {"path": "."}}
            </tool_call>
            <tool_call>{"name": "run_command", "arguments": {"command": "python3 numbers.py"}}</tool_call>
            """
        let r = ToolCallTextParser.parse(reply, allowedNames: tools)
        XCTAssertEqual(r.calls.map(\.name), ["list_dir", "run_command"])
        XCTAssertEqual(args(r.calls[1])["command"], "python3 numbers.py")
        XCTAssertEqual(r.remainingText, "")
    }

    func testBareJSONWithToolParametersAndStringArguments() {
        let r1 = ToolCallTextParser.parse(
            #"Sure. {"tool": "read_file", "parameters": {"path": "a.txt"}}"#, allowedNames: tools)
        XCTAssertEqual(r1.calls.map(\.name), ["read_file"])
        XCTAssertEqual(args(r1.calls[0])["path"], "a.txt")
        XCTAssertEqual(r1.remainingText, "Sure.")

        let r2 = ToolCallTextParser.parse(
            #"{"name": "read_file", "arguments": "{\"path\": \"b.txt\"}"}"#, allowedNames: tools)
        XCTAssertEqual(args(r2.calls[0])["path"], "b.txt")
    }

    func testRawNewlinesInsideContent() {
        let reply = "```\n{\"name\": \"write_file\", \"arguments\": {\"path\": \"x.py\", \"content\": \"a = 1\nprint(a)\"}}\n```"
        let r = ToolCallTextParser.parse(reply, allowedNames: tools)
        XCTAssertEqual(args(r.calls[0])["content"], "a = 1\nprint(a)")
    }

    func testUnknownToolOrOrdinaryJSONIsNotACall() {
        let reply = """
            Here is config:
            ```json
            {"name": "my-package", "version": "1.0.0", "arguments": {}}
            ```
            """
        let r = ToolCallTextParser.parse(reply, allowedNames: tools)
        XCTAssertTrue(r.calls.isEmpty)
        XCTAssertEqual(r.remainingText, reply)
    }

    func testBracesInsideStringsDoNotConfuseScanner() {
        let reply = #"{"name": "write_file", "arguments": {"path": "f.py", "content": "d = {}\nprint(f'{d}')"}}"#
        let r = ToolCallTextParser.parse(reply, allowedNames: tools)
        XCTAssertEqual(args(r.calls[0])["content"], "d = {}\nprint(f'{d}')")
    }
}

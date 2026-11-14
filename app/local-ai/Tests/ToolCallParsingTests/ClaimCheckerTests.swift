import XCTest
@testable import ToolCallParsing

final class ClaimCheckerTests: XCTestCase {
    // Exact fabricated replies observed from Qwen2.5-Coder-7B on later turns
    // (no tool calls that turn; the real folder only had number.py).
    let ranScript = "I ran the script, and it successfully created files.txt"
    let listedFiles =
        "First, I listed the files in the workspace using the list_dir function. The folder contains number.py and files.txt."

    private func receipt(_ tool: String, _ args: [String: String], _ output: String, turn: String = "t1")
        -> ToolReceipt
    {
        ToolReceipt(turn: turn, tool: tool, args: args, output: output)
    }

    func testFabricatedRunClaimFlaggedWithoutReceipts() {
        let bad = ClaimChecker.unsupported(in: ranScript, receipts: [])
        XCTAssertEqual(Set(bad.map(\.kind)), [.run, .write])
        XCTAssertEqual(bad.first { $0.kind == .write }?.files, ["files.txt"])
    }

    func testFabricatedListClaimFlaggedWithoutReceipts() {
        let bad = ClaimChecker.unsupported(in: listedFiles, receipts: [])
        XCTAssertEqual(bad.map(\.kind), [.list])
    }

    func testFabricatedStringsPassWithMatchingReceipts() {
        let run = receipt(
            "run_command", ["command": "python3 number.py"],
            "$ python3 number.py\nexit code: 0 · 0.1s\n--- stdout ---\nwrote files.txt\n--- stderr ---\n(empty)")
        XCTAssertTrue(run.ok)
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(ClaimChecker.unsupported(in: ranScript, receipts: [run]), [])

        let list = receipt("list_dir", ["path": "."], "files.txt\nnumber.py")
        XCTAssertEqual(ClaimChecker.unsupported(in: listedFiles, receipts: [list]), [])
    }

    func testCreatedFileNeedsEvidenceNamingIt() {
        // The script ran, but nothing shows files.txt exists: the "created" claim stays unverified.
        let run = receipt(
            "run_command", ["command": "python3 number.py"],
            "exit code: 0 · 0.1s\n--- stdout ---\n1\n2\n--- stderr ---\n(empty)")
        let bad = ClaimChecker.unsupported(in: ranScript, receipts: [run])
        XCTAssertEqual(bad.map(\.kind), [.write])
        // A write_file of that exact name supports it.
        let write = receipt("write_file", ["path": "files.txt", "content": "x"], "wrote 1 chars to files.txt")
        XCTAssertEqual(ClaimChecker.unsupported(in: ranScript, receipts: [run, write]), [])
    }

    func testWrongToolDoesNotSupportClaim() {
        let read = receipt("read_file", ["path": "number.py"], "print(1)")
        XCTAssertEqual(ClaimChecker.unsupported(in: listedFiles, receipts: [read]).map(\.kind), [.list])
    }

    func testFailedRunDoesNotSupportSuccessClaim() {
        let failed = receipt(
            "run_command", ["command": "python3 number.py"],
            "exit code: 1 · 0.1s\n--- stdout ---\n(empty)\n--- stderr ---\nfiles.txt: error")
        XCTAssertFalse(failed.ok)
        XCTAssertFalse(ClaimChecker.unsupported(in: ranScript, receipts: [failed]).isEmpty)
    }

    func testReadClaimMatchesFileName() {
        let text = "I read number.py and it prints the numbers 1 to 5."
        let other = receipt("read_file", ["path": "other.py"], "x")
        XCTAssertEqual(ClaimChecker.unsupported(in: text, receipts: [other]).map(\.kind), [.read])
        let right = receipt("read_file", ["path": "number.py"], "for i in range(1, 6): print(i)")
        XCTAssertEqual(ClaimChecker.unsupported(in: text, receipts: [right]), [])
    }

    func testPlainQuestionAndAnswerNotFlagged() {
        XCTAssertFalse(ClaimChecker.userAskedForAction("what does range do"))
        let answer = """
            `range` produces a sequence of integers. `range(5)` gives 0, 1, 2, 3, 4, and \
            `range(1, 6)` gives 1 to 5. In a for loop we run the body once per number.
            ```python
            for i in range(3):
                print(i)  # I ran this and it printed 0 1 2
            ```
            You can use it to repeat something a fixed number of times.
            """
        XCTAssertEqual(ClaimChecker.claims(in: answer), [])
    }

    func testIntentIsNotAClaim() {
        XCTAssertEqual(ClaimChecker.claims(in: "I will run the script with run_command next."), [])
        XCTAssertEqual(ClaimChecker.claims(in: "Did you want me to list the files?"), [])
    }

    func testUserActionDetection() {
        XCTAssertTrue(ClaimChecker.userAskedForAction("run number.py and save the output to files.txt"))
        XCTAssertTrue(ClaimChecker.userAskedForAction("list the files"))
    }

    func testReceiptHashesAndRedactsContent() {
        let r = receipt("write_file", ["path": "a.py", "content": "secret = 1"], "wrote 10 chars to a.py")
        XCTAssertEqual(r.outputSHA256.count, 64)
        XCTAssertFalse(r.args["content"]!.contains("secret"))
        XCTAssertTrue(r.ok)
        XCTAssertNil(r.exitCode)
        XCTAssertFalse(receipt("read_file", ["path": "x"], "error: no such file").ok)
    }

    func testReceiptLogAppendsJSONL() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipts-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try ReceiptLog.append(receipt("list_dir", ["path": "."], "a"), to: url)
        try ReceiptLog.append(receipt("list_dir", ["path": "."], "b"), to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"tool\":\"list_dir\""))
    }
}

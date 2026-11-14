import Foundation
import XCTest
@testable import PhoneGraderCore

/// Backend picker plumbing with MOCK backends only — never calls the claude CLI, Anthropic, Apple or a server.
final class GradingBackendTests: XCTestCase {
    struct Mock: GradingBackend {
        var label: String
        var seesPhotos: Bool = true
        var result: Result<GradeResult, Error>
        func grade(_ input: GradeInput) async throws -> GradeResult { try result.get() }
    }
    let g = GradeResult(overall_grade: "A", categories: [GradeCategory(name: "Screen", grade: "A", notes: "ok")],
                        concerns: [], photos_needed: [], summary: "Clean")
    let input = GradeInput(photos: [Data([1])], checklist: [], phoneModel: "iPhone 16 Pro", notes: nil, rubric: "R")

    func testPrimaryWins() async throws {
        let (r, used) = try await GradeDispatcher.run(input, primary: Mock(label: "mock", result: .success(g)))
        XCTAssertEqual(r, g); XCTAssertEqual(used, "mock")
    }
    func testFallbackUsedAndBothErrorsReported() async throws {
        let bad = Mock(label: "cli", result: .failure(GradingError.backend("sub lapsed")))
        let (_, used) = try await GradeDispatcher.run(input, primary: bad, fallback: Mock(label: "local", result: .success(g)))
        XCTAssertEqual(used, "local (fallback)")
        do {
            _ = try await GradeDispatcher.run(input, primary: bad, fallback: Mock(label: "local", result: .failure(GradingError.noText)))
            XCTFail("should throw")
        } catch { XCTAssertTrue(error.localizedDescription.contains("sub lapsed")); XCTAssertTrue(error.localizedDescription.contains("local fallback also failed")) }
    }
    func testTextOnlyBackendIsMarkedHonestly() async throws {
        let (r, _) = try await GradeDispatcher.run(input, primary: Mock(label: "apple", seesPhotos: false, result: .success(g)))
        XCTAssertEqual(r.concerns.first, TextOnlyGrading.disclaimer)
        XCTAssertFalse(r.photos_needed.isEmpty)
        XCTAssertEqual(r.overall_grade, "A")
    }
    func testTextOnlyPromptIncludesOCRDeviceAndHonesty() {
        var i = input
        i.checklist = [ChecklistEntry(Checklist.battery, "91")]
        i.photoText = ["Battery Health\nMaximum Capacity 91%", "  "]
        i.deviceInfo = "model iPhone 16 Pro; 128GB"
        let p = TextOnlyGrading.prompt(i)
        XCTAssertTrue(p.contains("Photo 1 on-screen text (OCR): Battery Health"))
        XCTAssertFalse(p.contains("Photo 2 on-screen"))
        XCTAssertTrue(p.contains("Auto-read device info: model iPhone 16 Pro"))
        XCTAssertTrue(p.contains("you cannot see the photos"))
        XCTAssertTrue(p.contains("Phone model: iPhone 16 Pro"))
    }

    // Any backend's grade: unknown iCloud/IMEI still means no buy number.
    func testChecklistGateBlocksRegardlessOfGrade() {
        let deal = DealRule.compute(floor: 560, floorQuotable: true, source: .atlasLadder, costs: DealCosts())
        XCTAssertTrue(deal.actionable)
        let unknown = DealRule.applyChecklistGate(deal, checklist: [])
        XCTAssertFalse(unknown.actionable); XCTAssertEqual(unknown.headline, "BLOCKED — no buy number")
        XCTAssertTrue(unknown.detail.contains("IMEI not verified")); XCTAssertTrue(unknown.detail.contains("iCloud"))
        let locked = DealRule.applyChecklistGate(deal, checklist: [ChecklistEntry(Checklist.icloud, "FAIL"), ChecklistEntry(Checklist.imei, "PASS")])
        XCTAssertFalse(locked.actionable); XCTAssertTrue(locked.detail.contains("Activation Lock is ON"))
        let ok = DealRule.applyChecklistGate(deal, checklist: [ChecklistEntry(Checklist.icloud, "PASS"), ChecklistEntry(Checklist.imei, "PASS")])
        XCTAssertTrue(ok.actionable); XCTAssertEqual(ok.maxBuy, 516)   // 560 − $4 gas (20mi÷24MPG×$4.80) − $40 profit
    }

    // OpenAI-compatible shapes
    func testOpenAIModelsAndVisionHeuristic() {
        let d = Data(#"{"object":"list","data":[{"id":"qwen2.5-vl-7b-instruct"},{"id":"llama-3.2-3b-instruct"},{"id":"gemma-3-12b"}]}"#.utf8)
        XCTAssertEqual(OpenAICompat.parseModels(d), ["qwen2.5-vl-7b-instruct", "llama-3.2-3b-instruct", "gemma-3-12b"])
        XCTAssertTrue(OpenAICompat.looksVisionCapable("qwen2.5-vl-7b-instruct"))
        XCTAssertTrue(OpenAICompat.looksVisionCapable("qwen2.5vl:7b"))
        XCTAssertTrue(OpenAICompat.looksVisionCapable("llava:13b"))
        XCTAssertFalse(OpenAICompat.looksVisionCapable("llama-3.2-3b-instruct"))
        XCTAssertEqual(OpenAICompat.parseModels(Data("nope".utf8)), [])
        XCTAssertEqual(OpenAICompat.endpoint("http://127.0.0.1:1234/v1/", "models")?.absoluteString, "http://127.0.0.1:1234/v1/models")
    }
    func testOpenAIChatBody() throws {
        let b = OpenAICompat.chatBody(model: "m", system: "S", prompt: "P", images: [Data([0xFF, 0xD8])], schema: Grader.schemaObject, maxTokens: 100)
        let msgs = b["messages"] as! [[String: Any]]
        let parts = msgs[1]["content"] as! [[String: Any]]
        XCTAssertEqual(parts[0]["type"] as? String, "image_url")
        XCTAssertEqual((parts[0]["image_url"] as! [String: Any])["url"] as? String, "data:image/jpeg;base64,/9g=")
        XCTAssertEqual(parts[1]["text"] as? String, "P")
        XCTAssertEqual((b["response_format"] as! [String: Any])["type"] as? String, "json_schema")
        let t = OpenAICompat.chatBody(model: "m", system: "S", prompt: "P", images: [], schema: nil, maxTokens: 100)
        XCTAssertEqual((t["messages"] as! [[String: Any]])[1]["content"] as? String, "P")
        XCTAssertNil(t["response_format"])
    }
    func testOpenAIChatParsing() throws {
        let ok = Data(#"{"choices":[{"message":{"role":"assistant","content":"{\"a\":1}"},"finish_reason":"stop"}]}"#.utf8)
        XCTAssertEqual(try OpenAICompat.parseChat(ok), OpenAICompat.Reply(text: #"{"a":1}"#, truncated: false))
        let cut = Data(#"{"choices":[{"message":{"content":"{"},"finish_reason":"length"}]}"#.utf8)
        XCTAssertTrue(try OpenAICompat.parseChat(cut).truncated)
        XCTAssertThrowsError(try OpenAICompat.parseChat(Data(#"{"error":{"message":"model not loaded"}}"#.utf8))) {
            XCTAssertTrue($0.localizedDescription.contains("model not loaded"))
        }
    }

    // claude CLI failure text → plain reason, full output kept
    func testClaudeCLIReasons() {
        let lapsed = #"{"type":"result","subtype":"success","is_error":true,"result":"Your subscription has expired. Please upgrade your plan to continue.","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}"#
        let r = ClaudeCLIOutput.reason(exitCode: 1, stdout: lapsed, stderr: "")
        XCTAssertTrue(r.hasPrefix("Your Claude subscription isn't active"))
        XCTAssertTrue(r.contains("Please upgrade your plan to continue."))
        XCTAssertTrue(r.contains("\"output_tokens\":0"))           // full output, not truncated
        XCTAssertTrue(ClaudeCLIOutput.reason(exitCode: 1, stdout: #"{"is_error":true,"result":"Claude AI usage limit reached|1760000000"}"#, stderr: "")
            .hasPrefix("Claude usage limit reached"))
        XCTAssertTrue(ClaudeCLIOutput.reason(exitCode: 1, stdout: #"{"is_error":true,"result":"Credit balance is too low"}"#, stderr: "")
            .hasPrefix("Your Claude account is out of credit"))
        XCTAssertTrue(ClaudeCLIOutput.reason(exitCode: 1, stdout: "", stderr: "Invalid API key · Please run /login").contains("isn't logged in"))
        let unknown = ClaudeCLIOutput.reason(exitCode: 3, stdout: "", stderr: String(repeating: "x", count: 900))
        XCTAssertTrue(unknown.hasPrefix("claude CLI failed (exit 3)"))
        XCTAssertTrue(unknown.contains(String(repeating: "x", count: 900)))
    }
}

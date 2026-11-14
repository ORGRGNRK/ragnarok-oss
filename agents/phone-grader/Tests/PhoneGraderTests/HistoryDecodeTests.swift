import XCTest
@testable import PhoneGrader

@MainActor
final class HistoryDecodeTests: XCTestCase {
    private var previousData = ""
    private var previousLog: URL?

    override func setUp() {
        previousData = HistoryDecode.env("PHONEGRADER_DATA_DIR")
        previousLog = HistoryDecode.logURL
        setenv("RAGNAROK_ERROR_SINK", "off", 1)
    }

    override func tearDown() {
        if previousData.isEmpty { unsetenv("PHONEGRADER_DATA_DIR") }
        else { setenv("PHONEGRADER_DATA_DIR", previousData, 1) }
        if let previousLog { HistoryDecode.logURL = previousLog }
        unsetenv("RAGNAROK_ERROR_SINK")
    }

    func testEmptyFileIsAnEmptyHistory() throws {
        let dir = try makeDir()
        setenv("PHONEGRADER_DATA_DIR", dir.path, 1)
        try Data("[]".utf8).write(to: dir.appendingPathComponent("history.json"))
        let store = HistoryStore()
        XCTAssertNil(store.decodeError)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testCorruptHistoryIsBackedUpLoggedAndNotReplaced() throws {
        let dir = try makeDir()
        setenv("PHONEGRADER_DATA_DIR", dir.path, 1)
        let log = dir.appendingPathComponent("errors.jsonl")
        HistoryDecode.logURL = log
        let file = dir.appendingPathComponent("history.json")
        let good = Data(#"[{"id":1,"createdAt":"2026-11-12T12:00:00Z","phoneModel":"Pixel","carrierLock":"unknown","checklist":[],"backend":"test","photoFiles":[]}]"#.utf8)
        try good.write(to: file)
        let store = HistoryStore()
        XCTAssertEqual(store.records.count, 1)
        XCTAssertNil(store.decodeError)
        try Data("{".utf8).write(to: file)
        store.load()
        XCTAssertEqual(store.records.count, 1, "a bad file must not clear the phones already loaded")
        let err = try XCTUnwrap(store.decodeError)
        XCTAssertFalse(err.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        XCTAssertTrue(names.contains { $0.hasPrefix("history.json.corrupt-") })
        let logged = try String(contentsOf: log, encoding: .utf8)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(logged.utf8)) as? [String: Any])
        XCTAssertEqual(row["area"] as? String, "phone-grader-history")
        XCTAssertEqual(row["message"] as? String, err)
        XCTAssertEqual(try Data(contentsOf: file), Data("{".utf8))
        store.upsert(store.records[0])
        XCTAssertEqual(try Data(contentsOf: file), Data("{".utf8), "a save must not replace the broken file")
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-hist-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

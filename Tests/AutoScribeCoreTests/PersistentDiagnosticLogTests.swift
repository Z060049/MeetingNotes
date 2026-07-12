import AutoScribeCore
import XCTest

final class PersistentDiagnosticLogTests: XCTestCase {
    func testWritesDiagnosticLineToConfiguredDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = PersistentDiagnosticLog(logDirectory: directory)
        log.log("recording started", level: .warning, date: Date(timeIntervalSince1970: 0))

        let contents = try String(contentsOf: log.logURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[Warning] recording started"))
    }

    func testRotatesLogAfterConfiguredSizeLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = PersistentDiagnosticLog(logDirectory: directory, maxBytes: 1)
        log.log("first")
        log.log("second")

        let current = try String(contentsOf: log.logURL, encoding: .utf8)
        let archivedURL = directory.appendingPathComponent("AutoScribe.previous.log")
        let archived = try String(contentsOf: archivedURL, encoding: .utf8)
        XCTAssertTrue(current.contains("second"))
        XCTAssertTrue(archived.contains("first"))
    }
}

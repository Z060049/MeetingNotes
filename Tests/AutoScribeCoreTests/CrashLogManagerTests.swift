import AutoScribeCore
import XCTest

final class CrashLogManagerTests: XCTestCase {
    func testNextLaunchCreatesIncidentForUnexpectedExit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = root.appendingPathComponent("state", isDirectory: true)
        let reports = root.appendingPathComponent("reports", isDirectory: true)
        let systemReports = root.appendingPathComponent("system", isDirectory: true)
        let logURL = root.appendingPathComponent("AutoScribe.log")
        try FileManager.default.createDirectory(at: systemReports, withIntermediateDirectories: true)
        try "State changed to Processing.\n".write(to: logURL, atomically: true, encoding: .utf8)

        let firstSession = makeManager(
            state: state,
            reports: reports,
            systemReports: systemReports,
            logURL: logURL
        )
        XCTAssertNil(firstSession.startSession(initialState: "Idle"))
        firstSession.updateState("Processing")
        try "sample crash".write(
            to: systemReports.appendingPathComponent("AutoScribe-2026-07-12.ips"),
            atomically: true,
            encoding: .utf8
        )

        let nextSession = makeManager(
            state: state,
            reports: reports,
            systemReports: systemReports,
            logURL: logURL
        )
        let incidentURL = try XCTUnwrap(nextSession.startSession(initialState: "Idle"))
        let report = try String(
            contentsOf: incidentURL.appendingPathComponent("unexpected-exit.txt"),
            encoding: .utf8
        )

        XCTAssertTrue(report.contains("Last app state: Processing"))
        XCTAssertTrue(report.contains("State changed to Processing."))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: incidentURL.appendingPathComponent("AutoScribe-2026-07-12.ips").path
            )
        )
    }

    func testCleanShutdownDoesNotCreateIncident() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = makeManager(
            state: root.appendingPathComponent("state"),
            reports: root.appendingPathComponent("reports"),
            systemReports: root.appendingPathComponent("system"),
            logURL: root.appendingPathComponent("AutoScribe.log")
        )
        XCTAssertNil(manager.startSession(initialState: "Idle"))
        manager.recordTerminationRequest(state: "Idle")
        manager.markCleanShutdown(finalState: "Idle")

        let nextSession = makeManager(
            state: root.appendingPathComponent("state"),
            reports: root.appendingPathComponent("reports"),
            systemReports: root.appendingPathComponent("system"),
            logURL: root.appendingPathComponent("AutoScribe.log")
        )
        XCTAssertNil(nextSession.startSession(initialState: "Idle"))
    }

    func testTerminationWithoutQuitRequestCreatesIncidentImmediately() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = makeManager(
            state: root.appendingPathComponent("state"),
            reports: root.appendingPathComponent("reports"),
            systemReports: root.appendingPathComponent("system"),
            logURL: root.appendingPathComponent("AutoScribe.log")
        )
        XCTAssertNil(manager.startSession(initialState: "Recording"))

        XCTAssertNotNil(manager.markCleanShutdown(finalState: "Processing"))
    }

    private func makeManager(
        state: URL,
        reports: URL,
        systemReports: URL,
        logURL: URL
    ) -> CrashLogManager {
        CrashLogManager(
            stateDirectory: state,
            reportDirectory: reports,
            systemCrashDirectory: systemReports,
            persistentLogURL: logURL
        )
    }
}

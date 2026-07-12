import AutoScribeCore
import XCTest

final class RecordingRecoveryTests: XCTestCase {
    func testRecordingWorkspaceUsesStableApplicationSupportDirectory() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!

        let workspace = FileManager.default.autoScribeRecordingWorkspace(for: id)

        XCTAssertTrue(workspace.path.contains("Library/Application Support/AutoScribe/Recording Recovery"))
        XCTAssertEqual(workspace.lastPathComponent, id.uuidString)
    }
}

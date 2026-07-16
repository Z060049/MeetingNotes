import MeetingNotesCore
import XCTest

final class SystemAudioRecorderFactoryTests: XCTestCase {
    func testScreenCaptureKitIsTheOnlyAutomaticBackend() {
        let names = SystemAudioRecorderFactory.preferredBackendNames

        if #available(macOS 13.0, *) {
            XCTAssertEqual(names, [SystemAudioBackend.screenCaptureKit.rawValue])
        } else {
            XCTAssertTrue(names.isEmpty)
        }
    }
}

import MeetingNotesCore
import XCTest

final class SettingsStoreTests: XCTestCase {
    func testDefaultSettingsMatchMVPValidationDefaults() {
        let settings = AppSettings()

        XCTAssertEqual(settings.processingMode, .api)
        XCTAssertEqual(settings.outputDirectory.path, FileManager.default.defaultMeetingNotesOutputDirectory.path)
        XCTAssertEqual(settings.inactivityTimeoutSeconds, 180)
        XCTAssertEqual(settings.summaryDepth, .standard)
        XCTAssertTrue(settings.shouldShowConsentReminder)
        XCTAssertFalse(settings.hasAcceptedConsentChecklist)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertFalse(settings.hasRequestedScreenCapturePermission)
        XCTAssertFalse(settings.isAwaitingScreenCaptureRelaunch)
    }

    func testSaveAndLoadSettings() {
        let suiteName = "MeetingNotesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        let expected = AppSettings(
            processingMode: .api,
            outputDirectory: URL(fileURLWithPath: "/tmp/meetingnotes-output", isDirectory: true),
            inactivityTimeoutSeconds: 120,
            summaryDepth: .detailed,
            shouldShowConsentReminder: false,
            hasAcceptedConsentChecklist: true,
            hasCompletedOnboarding: true,
            hasRequestedScreenCapturePermission: true,
            isAwaitingScreenCaptureRelaunch: true
        )

        store.save(expected)

        XCTAssertEqual(store.load(), expected)
    }
}

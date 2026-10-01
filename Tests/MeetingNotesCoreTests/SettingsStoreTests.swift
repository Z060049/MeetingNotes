import MeetingNotesCore
import XCTest

final class SettingsStoreTests: XCTestCase {
    func testDefaultSettingsMatchMVPValidationDefaults() {
        let settings = AppSettings()

        XCTAssertEqual(settings.outputDirectory.path, FileManager.default.defaultMeetingNotesOutputDirectory.path)
        XCTAssertTrue(settings.shouldPromptAfterSilence)
        XCTAssertEqual(settings.inactivityTimeoutSeconds, 180)
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
            outputDirectory: URL(fileURLWithPath: "/tmp/meetingnotes-output", isDirectory: true),
            shouldPromptAfterSilence: false,
            inactivityTimeoutSeconds: 120,
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

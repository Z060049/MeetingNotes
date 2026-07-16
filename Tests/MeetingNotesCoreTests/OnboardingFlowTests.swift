import MeetingNotesCore
import XCTest

final class OnboardingFlowTests: XCTestCase {
    func testNewUserStartsAtWelcome() {
        let flow = OnboardingFlowState(
            settings: AppSettings(),
            permissions: PermissionSnapshot(
                microphone: .notDetermined,
                screenCapture: .notDetermined
            )
        )

        XCTAssertEqual(flow.step, .welcome)
    }

    func testAcceptedConsentResumesAtFirstMissingPermission() {
        var settings = AppSettings()
        settings.hasAcceptedConsentChecklist = true

        let microphoneFlow = OnboardingFlowState(
            settings: settings,
            permissions: PermissionSnapshot(
                microphone: .denied,
                screenCapture: .denied
            )
        )
        XCTAssertEqual(microphoneFlow.step, .microphone)

        let systemAudioFlow = OnboardingFlowState(
            settings: settings,
            permissions: PermissionSnapshot(
                microphone: .authorized,
                screenCapture: .denied
            )
        )
        XCTAssertEqual(systemAudioFlow.step, .systemAudio)
    }

    func testPendingRelaunchTakesPriority() {
        var settings = AppSettings()
        settings.hasAcceptedConsentChecklist = true
        settings.isAwaitingScreenCaptureRelaunch = true

        let flow = OnboardingFlowState(
            settings: settings,
            permissions: PermissionSnapshot(
                microphone: .authorized,
                screenCapture: .restartRequired
            )
        )

        XCTAssertEqual(flow.step, .restart)
    }

    func testGrantedPermissionsResumeAtReady() {
        var settings = AppSettings()
        settings.hasAcceptedConsentChecklist = true

        let flow = OnboardingFlowState(
            settings: settings,
            permissions: PermissionSnapshot(
                microphone: .authorized,
                screenCapture: .authorized
            )
        )

        XCTAssertEqual(flow.step, .ready)
    }

    func testFlowNavigation() {
        var flow = OnboardingFlowState(
            settings: AppSettings(),
            permissions: PermissionSnapshot(
                microphone: .notDetermined,
                screenCapture: .notDetermined
            )
        )

        flow.advance()
        XCTAssertEqual(flow.step, .consent)
        flow.goBack()
        XCTAssertEqual(flow.step, .welcome)
        flow.move(to: .systemAudio)
        XCTAssertEqual(flow.step, .systemAudio)
    }

    @MainActor
    func testControllerBlocksRecordingUntilOnboardingCompletes() {
        let suiteName = "MeetingNotesOnboardingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = MeetingNotesController(
            settingsStore: SettingsStore(defaults: defaults),
            permissionService: FakePermissionService(
                microphone: .authorized,
                screenCapture: .authorized
            )
        )

        controller.startRecording()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNotNil(controller.lastError)
        XCTAssertFalse(controller.isSetupComplete)
    }
}

private final class FakePermissionService: PermissionServicing {
    private let microphone: PermissionState
    private let screenCapture: PermissionState

    init(microphone: PermissionState, screenCapture: PermissionState) {
        self.microphone = microphone
        self.screenCapture = screenCapture
    }

    func microphoneState() -> PermissionState {
        microphone
    }

    func screenCaptureState(
        hasRequestedAccess: Bool,
        isAwaitingRelaunch: Bool
    ) -> PermissionState {
        if screenCapture == .authorized {
            return .authorized
        }
        return isAwaitingRelaunch ? .restartRequired : screenCapture
    }

    func requestMicrophoneAccess() async -> Bool {
        microphone == .authorized
    }

    func requestScreenCaptureAccess() -> Bool {
        screenCapture == .authorized
    }

    func openMicrophoneSettings() {}
    func openScreenCaptureSettings() {}
}

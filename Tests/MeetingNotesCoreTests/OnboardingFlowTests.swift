import MeetingNotesCore
import XCTest

final class OnboardingFlowTests: XCTestCase {
    func testNewUserStartsAtWelcome() {
        let flow = OnboardingFlowState(
            settings: AppSettings(),
            permissions: PermissionSnapshot(
                microphone: .notDetermined,
                screenCapture: .notDetermined
            ),
            isProcessingReady: false
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
            ),
            isProcessingReady: false
        )
        XCTAssertEqual(microphoneFlow.step, .processing)

        settings.hasSelectedProcessingMode = true

        let systemAudioFlow = OnboardingFlowState(
            settings: settings,
            permissions: PermissionSnapshot(
                microphone: .authorized,
                screenCapture: .denied
            ),
            isProcessingReady: true
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
            ),
            isProcessingReady: false
        )

        XCTAssertEqual(flow.step, .restart)
    }

    func testGrantedPermissionsResumeAtReady() {
        var settings = AppSettings()
        settings.hasAcceptedConsentChecklist = true
        settings.hasSelectedProcessingMode = true

        let flow = OnboardingFlowState(
            settings: settings,
            permissions: PermissionSnapshot(
                microphone: .authorized,
                screenCapture: .authorized
            ),
            isProcessingReady: true
        )

        XCTAssertEqual(flow.step, .ready)
    }

    func testSelectedModeResumesAtProcessingUntilItsSetupIsReady() {
        var settings = AppSettings()
        settings.hasAcceptedConsentChecklist = true
        settings.hasSelectedProcessingMode = true

        let flow = OnboardingFlowState(
            settings: settings,
            permissions: PermissionSnapshot(
                microphone: .authorized,
                screenCapture: .authorized
            ),
            isProcessingReady: false
        )

        XCTAssertEqual(flow.step, .processing)
    }

    func testFlowNavigation() {
        var flow = OnboardingFlowState(
            settings: AppSettings(),
            permissions: PermissionSnapshot(
                microphone: .notDetermined,
                screenCapture: .notDetermined
            ),
            isProcessingReady: false
        )

        flow.advance()
        XCTAssertEqual(flow.step, .consent)
        flow.advance()
        XCTAssertEqual(flow.step, .processing)
        flow.goBack()
        XCTAssertEqual(flow.step, .consent)
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

    @MainActor
    func testAPIModeRequiresStoredGroqKey() {
        let suiteName = "MeetingNotesAPISetupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.save(
            AppSettings(
                processingMode: .api,
                hasAcceptedConsentChecklist: true,
                hasCompletedOnboarding: true,
                hasSelectedProcessingMode: true
            )
        )
        let credentials = FakeCredentialStore()
        let controller = MeetingNotesController(
            settingsStore: store,
            permissionService: FakePermissionService(
                microphone: .authorized,
                screenCapture: .authorized
            ),
            credentialStore: credentials
        )

        XCTAssertFalse(controller.isSetupComplete)
        try? controller.saveGroqAPIKey("gsk_test")
        XCTAssertTrue(controller.isSetupComplete)
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

private final class FakeCredentialStore: APICredentialStoring, @unchecked Sendable {
    private var value: String?

    func apiKey() throws -> String? { value }
    func saveAPIKey(_ apiKey: String) throws { value = apiKey }
    func deleteAPIKey() throws { value = nil }
}

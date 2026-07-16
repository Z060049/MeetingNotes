import Foundation

public enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    case welcome
    case consent
    case microphone
    case systemAudio
    case restart
    case ready
}

public struct OnboardingFlowState: Equatable, Sendable {
    public private(set) var step: OnboardingStep

    public init(
        settings: AppSettings,
        permissions: PermissionSnapshot
    ) {
        if settings.isAwaitingScreenCaptureRelaunch {
            step = .restart
        } else if !settings.hasAcceptedConsentChecklist {
            step = .welcome
        } else if !permissions.microphone.isAuthorized {
            step = .microphone
        } else if !permissions.screenCapture.isAuthorized {
            step = .systemAudio
        } else {
            step = .ready
        }
    }

    public mutating func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            return
        }
        step = next
    }

    public mutating func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else {
            return
        }
        step = previous
    }

    public mutating func move(to step: OnboardingStep) {
        self.step = step
    }
}

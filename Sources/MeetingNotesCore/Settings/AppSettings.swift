import Foundation

public struct AppSettings: Equatable, Sendable {
    public var outputDirectory: URL
    public var shouldPromptAfterSilence: Bool
    public var inactivityTimeoutSeconds: TimeInterval
    public var shouldShowConsentReminder: Bool
    public var hasAcceptedConsentChecklist: Bool
    public var hasCompletedOnboarding: Bool
    public var hasRequestedScreenCapturePermission: Bool
    public var isAwaitingScreenCaptureRelaunch: Bool

    public init(
        outputDirectory: URL = FileManager.default.defaultMeetingNotesOutputDirectory,
        shouldPromptAfterSilence: Bool = true,
        inactivityTimeoutSeconds: TimeInterval = 180,
        shouldShowConsentReminder: Bool = true,
        hasAcceptedConsentChecklist: Bool = false,
        hasCompletedOnboarding: Bool = false,
        hasRequestedScreenCapturePermission: Bool = false,
        isAwaitingScreenCaptureRelaunch: Bool = false
    ) {
        self.outputDirectory = outputDirectory
        self.shouldPromptAfterSilence = shouldPromptAfterSilence
        self.inactivityTimeoutSeconds = inactivityTimeoutSeconds
        self.shouldShowConsentReminder = shouldShowConsentReminder
        self.hasAcceptedConsentChecklist = hasAcceptedConsentChecklist
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.hasRequestedScreenCapturePermission = hasRequestedScreenCapturePermission
        self.isAwaitingScreenCaptureRelaunch = isAwaitingScreenCaptureRelaunch
    }
}

public final class SettingsStore: @unchecked Sendable {
    private enum Key {
        static let outputDirectory = "outputDirectory"
        static let shouldPromptAfterSilence = "shouldPromptAfterSilence"
        static let inactivityTimeoutSeconds = "inactivityTimeoutSeconds"
        static let shouldShowConsentReminder = "shouldShowConsentReminder"
        static let hasAcceptedConsentChecklist = "hasAcceptedConsentChecklist"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hasRequestedScreenCapturePermission = "hasRequestedScreenCapturePermission"
        static let isAwaitingScreenCaptureRelaunch = "isAwaitingScreenCaptureRelaunch"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        var settings = AppSettings()

        if let path = defaults.string(forKey: Key.outputDirectory), !path.isEmpty {
            settings.outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }

        if defaults.object(forKey: Key.shouldPromptAfterSilence) != nil {
            settings.shouldPromptAfterSilence = defaults.bool(forKey: Key.shouldPromptAfterSilence)
        }

        let timeout = defaults.double(forKey: Key.inactivityTimeoutSeconds)
        if timeout > 0 {
            settings.inactivityTimeoutSeconds = timeout
        }

        if defaults.object(forKey: Key.shouldShowConsentReminder) != nil {
            settings.shouldShowConsentReminder = defaults.bool(forKey: Key.shouldShowConsentReminder)
        }

        settings.hasAcceptedConsentChecklist = defaults.bool(forKey: Key.hasAcceptedConsentChecklist)
        settings.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        settings.hasRequestedScreenCapturePermission = defaults.bool(
            forKey: Key.hasRequestedScreenCapturePermission
        )
        settings.isAwaitingScreenCaptureRelaunch = defaults.bool(
            forKey: Key.isAwaitingScreenCaptureRelaunch
        )

        return settings
    }

    public func save(_ settings: AppSettings) {
        defaults.set(settings.outputDirectory.path, forKey: Key.outputDirectory)
        defaults.set(settings.shouldPromptAfterSilence, forKey: Key.shouldPromptAfterSilence)
        defaults.set(settings.inactivityTimeoutSeconds, forKey: Key.inactivityTimeoutSeconds)
        defaults.set(settings.shouldShowConsentReminder, forKey: Key.shouldShowConsentReminder)
        defaults.set(settings.hasAcceptedConsentChecklist, forKey: Key.hasAcceptedConsentChecklist)
        defaults.set(settings.hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding)
        defaults.set(
            settings.hasRequestedScreenCapturePermission,
            forKey: Key.hasRequestedScreenCapturePermission
        )
        defaults.set(
            settings.isAwaitingScreenCaptureRelaunch,
            forKey: Key.isAwaitingScreenCaptureRelaunch
        )
    }
}

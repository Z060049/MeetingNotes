import Foundation

public enum SummaryDepth: String, CaseIterable, Codable, Sendable {
    case brief
    case standard
    case detailed
}

public enum WhisperModelSize: String, CaseIterable, Codable, Sendable {
    case tiny = "tiny"
    case base = "base"
    case baseEn = "base.en"
    case small = "small"
    case medium = "medium"

    public var displayName: String {
        switch self {
        case .tiny:   return "Tiny (~39 MB) – Fastest"
        case .base:   return "Base (~74 MB)"
        case .baseEn: return "Base English (~74 MB) – Recommended"
        case .small:  return "Small (~244 MB) – Better accuracy"
        case .medium: return "Medium (~769 MB) – Best accuracy"
        }
    }

    public var modelIdentifier: String { rawValue }
}

public struct AppSettings: Equatable, Sendable {
    public var processingMode: ProcessingMode
    public var outputDirectory: URL
    public var inactivityTimeoutSeconds: TimeInterval
    public var summaryDepth: SummaryDepth
    public var shouldShowConsentReminder: Bool
    public var hasAcceptedConsentChecklist: Bool
    public var hasCompletedOnboarding: Bool
    public var hasRequestedScreenCapturePermission: Bool
    public var isAwaitingScreenCaptureRelaunch: Bool
    public var whisperModel: WhisperModelSize
    public var localLLMModel: String

    public init(
        processingMode: ProcessingMode = .api,
        outputDirectory: URL = FileManager.default.defaultMeetingNotesOutputDirectory,
        inactivityTimeoutSeconds: TimeInterval = 180,
        summaryDepth: SummaryDepth = .standard,
        shouldShowConsentReminder: Bool = true,
        hasAcceptedConsentChecklist: Bool = false,
        hasCompletedOnboarding: Bool = false,
        hasRequestedScreenCapturePermission: Bool = false,
        isAwaitingScreenCaptureRelaunch: Bool = false,
        whisperModel: WhisperModelSize = .baseEn,
        localLLMModel: String = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    ) {
        self.processingMode = processingMode
        self.outputDirectory = outputDirectory
        self.inactivityTimeoutSeconds = inactivityTimeoutSeconds
        self.summaryDepth = summaryDepth
        self.shouldShowConsentReminder = shouldShowConsentReminder
        self.hasAcceptedConsentChecklist = hasAcceptedConsentChecklist
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.hasRequestedScreenCapturePermission = hasRequestedScreenCapturePermission
        self.isAwaitingScreenCaptureRelaunch = isAwaitingScreenCaptureRelaunch
        self.whisperModel = whisperModel
        self.localLLMModel = localLLMModel
    }
}

public final class SettingsStore: @unchecked Sendable {
    private enum Key {
        static let processingMode = "processingMode"
        static let outputDirectory = "outputDirectory"
        static let inactivityTimeoutSeconds = "inactivityTimeoutSeconds"
        static let summaryDepth = "summaryDepth"
        static let shouldShowConsentReminder = "shouldShowConsentReminder"
        static let hasAcceptedConsentChecklist = "hasAcceptedConsentChecklist"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hasRequestedScreenCapturePermission = "hasRequestedScreenCapturePermission"
        static let isAwaitingScreenCaptureRelaunch = "isAwaitingScreenCaptureRelaunch"
        static let whisperModel = "whisperModel"
        static let localLLMModel = "localLLMModel"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        var settings = AppSettings()

        if let rawMode = defaults.string(forKey: Key.processingMode),
           let mode = ProcessingMode(rawValue: rawMode) {
            settings.processingMode = mode
        }

        if let path = defaults.string(forKey: Key.outputDirectory), !path.isEmpty {
            settings.outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }

        let timeout = defaults.double(forKey: Key.inactivityTimeoutSeconds)
        if timeout > 0 {
            settings.inactivityTimeoutSeconds = timeout
        }

        if let rawDepth = defaults.string(forKey: Key.summaryDepth),
           let depth = SummaryDepth(rawValue: rawDepth) {
            settings.summaryDepth = depth
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

        if let rawWhisper = defaults.string(forKey: Key.whisperModel),
           let whisper = WhisperModelSize(rawValue: rawWhisper) {
            settings.whisperModel = whisper
        }

        if let llmModel = defaults.string(forKey: Key.localLLMModel), !llmModel.isEmpty {
            settings.localLLMModel = llmModel
        }

        return settings
    }

    public func save(_ settings: AppSettings) {
        defaults.set(settings.processingMode.rawValue, forKey: Key.processingMode)
        defaults.set(settings.outputDirectory.path, forKey: Key.outputDirectory)
        defaults.set(settings.inactivityTimeoutSeconds, forKey: Key.inactivityTimeoutSeconds)
        defaults.set(settings.summaryDepth.rawValue, forKey: Key.summaryDepth)
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
        defaults.set(settings.whisperModel.rawValue, forKey: Key.whisperModel)
        defaults.set(settings.localLLMModel, forKey: Key.localLLMModel)
    }
}

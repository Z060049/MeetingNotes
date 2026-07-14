import Foundation

public struct CapturedAudioFile: Equatable, Sendable {
    public let source: AudioSource
    public let url: URL
    /// Offset from the recording session start to when this source began capture.
    public let captureStartOffset: TimeInterval
    public let segmentIndex: Int
    public let deviceUID: String?

    public init(
        source: AudioSource,
        url: URL,
        captureStartOffset: TimeInterval = 0,
        segmentIndex: Int = 0,
        deviceUID: String? = nil
    ) {
        self.source = source
        self.url = url
        self.captureStartOffset = captureStartOffset
        self.segmentIndex = segmentIndex
        self.deviceUID = deviceUID
    }
}

public struct AudioCaptureResult: Equatable, Sendable {
    public let session: RecordingSession
    public let files: [CapturedAudioFile]
    public let diagnostics: [String]

    public init(session: RecordingSession, files: [CapturedAudioFile], diagnostics: [String] = []) {
        self.session = session
        self.files = files
        self.diagnostics = diagnostics
    }
}

public enum AudioCaptureError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case systemAudioBackendUnavailable(String)
    case coreAudioError(operation: String, status: OSStatus)
    case captureStartupTimedOut(String)
    case unsupportedInputRoute(String)
    case noDisplayAvailable
    case writerUnavailable

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "Audio capture is already running."
        case .notRecording:
            "Audio capture is not running."
        case .microphonePermissionDenied:
            "Microphone permission was denied."
        case .systemAudioPermissionDenied:
            "System audio capture permission was denied."
        case .systemAudioBackendUnavailable(let message):
            message
        case .coreAudioError(let operation, let status):
            "\(operation) failed with Core Audio status \(status)."
        case .captureStartupTimedOut(let message):
            message
        case .unsupportedInputRoute(let message):
            message
        case .noDisplayAvailable:
            "No display was available for system audio capture."
        case .writerUnavailable:
            "The audio writer was not available."
        }
    }
}

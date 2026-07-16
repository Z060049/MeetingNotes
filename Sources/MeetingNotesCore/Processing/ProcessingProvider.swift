import Foundation

public protocol ProcessingProvider: Sendable {
    /// Process a captured recording into a `ProcessingResult`.
    ///
    /// - Parameter onTranscriptReady: Called with the unmodified transcription
    ///   before deduplication and summarization. Use this hook to persist a true
    ///   raw fallback. The closure is always called on an arbitrary async context
    ///   and must be safe to call from any thread.
    func process(
        capture: AudioCaptureResult,
        settings: AppSettings,
        onTranscriptReady: (@Sendable (Transcript) async -> Void)?
    ) async throws -> ProcessingResult
}

public enum ProcessingProviderError: Error, LocalizedError {
    case missingAPIKey
    case unsupportedLocalMode
    case invalidResponse
    case apiError(String)
    case quotaExceeded(String)
    case localModelNotReady(String)
    case localProcessingError(String)
    case localUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your Groq API key in MeetingNotes Settings before processing recordings."
        case .unsupportedLocalMode:
            "Local processing is planned after the API-first MVP."
        case .invalidResponse:
            "The processing provider returned an invalid response that MeetingNotes could not parse."
        case .apiError(let message):
            message
        case .quotaExceeded(let message):
            message
        case .localModelNotReady(let message):
            message
        case .localProcessingError(let message):
            message
        case .localUnsupported(let message):
            message
        }
    }
}

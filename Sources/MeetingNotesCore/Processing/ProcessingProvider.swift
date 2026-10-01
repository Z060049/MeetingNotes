import Foundation

public protocol ProcessingProvider: Sendable {
    /// Transcribe a captured recording without summarization or cleanup.
    func transcribe(capture: AudioCaptureResult) async throws -> Transcript
}

public enum ProcessingProviderError: Error, LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(String)
    case quotaExceeded(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your Groq API key in MeetingNotes Settings before processing recordings."
        case .invalidResponse:
            "The processing provider returned an invalid response that MeetingNotes could not parse."
        case .apiError(let message):
            message
        case .quotaExceeded(let message):
            message
        }
    }
}

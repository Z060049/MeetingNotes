import Foundation

/// A `ProcessingProvider` that runs entirely on-device using WhisperKit for
/// transcription and either Apple Intelligence or MLX for summarization.
///
/// Inject via `AutoScribeController(processingProvider:)` or let the controller
/// build it automatically when `AppSettings.processingMode == .local`.
public final class LocalProcessingProvider: ProcessingProvider, @unchecked Sendable {

    private let transcriptionService: WhisperKitTranscriptionService
    private let summarizationService: LocalSummarizationService

    public init(
        transcriptionService: WhisperKitTranscriptionService,
        summarizationService: LocalSummarizationService
    ) {
        self.transcriptionService = transcriptionService
        self.summarizationService = summarizationService
    }

    // MARK: - ProcessingProvider

    public func process(
        capture: AudioCaptureResult,
        settings: AppSettings
    ) async throws -> ProcessingResult {
        guard settings.processingMode == .local else {
            throw ProcessingProviderError.localProcessingError(
                "LocalProcessingProvider called while mode is not .local."
            )
        }

        // Step 1 — ensure Whisper model is loaded
        if !transcriptionService.isReady {
            try await transcriptionService.prepareModel(settings.whisperModel)
        }

        // Step 2 — transcribe all audio files
        let rawTranscript = try await transcriptionService.transcribe(
            files: capture.files,
            modelSize: settings.whisperModel
        )

        let deduplicated = TranscriptDeduplicator.deduplicate(rawTranscript)
        let cleaned = TranscriptDeduplicator.collapseRepeatedSentences(deduplicated)

        guard !cleaned.segments.isEmpty else {
            throw ProcessingProviderError.localProcessingError(
                "No speech was detected in the recording. Check that your microphone is working."
            )
        }

        // Free Whisper from memory before loading the LLM to avoid unified-memory pressure.
        transcriptionService.releaseModel()

        // Step 3 — summarize using the active tier
        let summary = try await summarizationService.summarize(
            transcript: cleaned,
            depth: settings.summaryDepth,
            mlxModelID: settings.localLLMModel
        )

        return ProcessingResult(transcript: cleaned, summary: summary)
    }
}

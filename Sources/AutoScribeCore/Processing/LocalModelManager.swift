import Combine
import Foundation

/// Observable coordinator for local model state.
///
/// Owned by `AutoScribeController` and observed by `SettingsView`. Holds the
/// `WhisperKitTranscriptionService` and `LocalSummarizationService` instances
/// and exposes download actions and status to SwiftUI.
public final class LocalModelManager: ObservableObject, @unchecked Sendable {

    // MARK: - Sub-services (internal use by LocalProcessingProvider)

    public let transcriptionService: WhisperKitTranscriptionService
    public let summarizationService: LocalSummarizationService

    // MARK: - Published state forwarded from sub-services

    @Published public private(set) var whisperDownloadState: ModelDownloadState = .notDownloaded
    @Published public private(set) var mlxDownloadState: ModelDownloadState = .notDownloaded

    /// The summarization backend active on this device. Starts as `.mlx` and
    /// may update asynchronously to `.appleIntelligence` after startup.
    @Published public private(set) var summarizationTier: SummarizationTier = .mlx

    private var whiskerObserver: AnyCancellable?
    private var mlxObserver: AnyCancellable?
    private var tierObserver: AnyCancellable?

    public init() {
        let transcription = WhisperKitTranscriptionService()
        let summarization = LocalSummarizationService()

        self.transcriptionService = transcription
        self.summarizationService = summarization

        // Mirror sub-service @Published state to our own published properties
        // so callers only need to observe LocalModelManager.
        whiskerObserver = transcription.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.whisperDownloadState = transcription.downloadState
                self?.objectWillChange.send()
            }
        }

        mlxObserver = summarization.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.mlxDownloadState = summarization.mlxDownloadState
                self?.summarizationTier = summarization.tier
                self?.objectWillChange.send()
            }
        }
    }

    // MARK: - Actions

    /// Called at app startup to restore download state without re-downloading.
    public func checkDownloadStatus(whisperModel: WhisperModelSize, mlxModelID: String) {
        transcriptionService.checkIfDownloaded(whisperModel)
        summarizationService.checkIfMLXDownloaded(modelID: mlxModelID)
    }

    /// Loads (and downloads if needed) the selected Whisper model.
    public func prepareWhisperModel(_ size: WhisperModelSize) async throws {
        try await transcriptionService.prepareModel(size)
    }

    /// Downloads and loads the MLX language model for summarization (Tier 2 only).
    public func prepareMLXModel(modelID: String) async throws {
        try await summarizationService.prepareMLXModel(modelID: modelID)
    }

    // MARK: - Convenience state

    public var isWhisperReady: Bool { transcriptionService.isReady }
    public var isMLXReady: Bool { summarizationService.isMLXReady }

    /// Returns true when both models needed for the current tier are ready to process.
    public func isReadyToProcess(settings: AppSettings) -> Bool {
        guard isWhisperReady else { return false }
        switch summarizationTier {
        case .appleIntelligence: return true
        case .mlx:               return isMLXReady
        case .unavailable:       return false
        }
    }
}

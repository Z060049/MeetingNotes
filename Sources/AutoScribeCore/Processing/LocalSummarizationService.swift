import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

#if arch(arm64)
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import Hub
#endif

// MARK: - Tier

/// Indicates which backend will perform summarization on this device.
public enum SummarizationTier: String, Sendable, Equatable {
    /// Apple Intelligence (FoundationModels framework), available on macOS 26+ Apple Silicon.
    case appleIntelligence = "Apple Intelligence"
    /// On-device model inference via MLX, available on Apple Silicon macOS 14+.
    case mlx = "On-device Model (MLX)"
    /// Neither tier is supported (Intel Mac without Apple Intelligence).
    case unavailable = "Unavailable"
}

// MARK: - Service

/// Produces a `MeetingSummary` from a `Transcript` using fully local inference.
///
/// Tier selection at runtime:
///   - **Tier 1 (macOS 26+ Apple Silicon):** Apple Intelligence via `FoundationModels`.
///     Zero downloads required; model is built into the OS.
///   - **Tier 2 (macOS 14–25, Apple Silicon):** MLX-based LLM downloaded once by the user.
///   - **Unavailable (Intel Mac):** Throws `localUnsupported`.
public final class LocalSummarizationService: ObservableObject, @unchecked Sendable {

    @Published public private(set) var mlxDownloadState: ModelDownloadState = .notDownloaded

    /// Starts as `.mlx` (or `.unavailable` on Intel) and may upgrade to
    /// `.appleIntelligence` asynchronously after the FoundationModels service
    /// responds. Kept off the main thread to avoid startup hangs when the
    /// entitlement or service is unavailable.
    @Published public private(set) var tier: SummarizationTier

    #if arch(arm64)
    private var mlxContainer: ModelContainer?
    private var loadedMLXModelID: String?
    #endif

    public init() {
        #if arch(arm64)
        self.tier = .mlx
        // Check Apple Intelligence availability off the main thread.
        // SystemLanguageModel.default can block/hang without the entitlement.
        Task.detached(priority: .background) {
            let resolved = Self.detectAppleIntelligenceTier()
            await MainActor.run { [weak self] in self?.tier = resolved }
        }
        #else
        self.tier = .unavailable
        #endif
    }

    // MARK: - Tier detection

    /// Called from a background task — never call on the main thread.
    public static func detectAppleIntelligenceTier() -> SummarizationTier {
        #if arch(arm64)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if isAppleIntelligenceAvailable() {
                return .appleIntelligence
            }
        }
        #endif
        return .mlx
        #else
        return .unavailable
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    public static func isAppleIntelligenceAvailable() -> Bool {
        let model = SystemLanguageModel.default
        if case .available = model.availability {
            return true
        }
        return false
    }
    #endif

    // MARK: - MLX model management

    // Persisted set of model IDs whose files are confirmed on disk.
    private static let mlxDownloadedKey = "com.autoscribe.downloadedMLXModels"
    private var downloadedMLXModels: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.mlxDownloadedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.mlxDownloadedKey) }
    }

    /// Restores ready state at app launch without touching the network.
    public func checkIfMLXDownloaded(modelID: String) {
        if downloadedMLXModels.contains(modelID) {
            mlxDownloadState = .ready
        }
    }

    /// Downloads model files only — no MLX loading into memory.
    /// The container is loaded lazily the first time summarization is needed.
    public func prepareMLXModel(modelID: String) async throws {
        guard tier == .mlx else { return }

        #if arch(arm64)
        if downloadedMLXModels.contains(modelID) || (loadedMLXModelID == modelID && mlxContainer != nil) {
            await setMLXState(.ready)
            return
        }

        await setMLXState(.downloading(progress: 0.0))

        do {
            // HubApi.snapshot fetches files to the local HuggingFace cache with no
            // MLX/CoreML work — safe on low-RAM devices.
            _ = try await HubApi().snapshot(from: modelID) { [weak self] progress in
                Task { await self?.setMLXState(.downloading(progress: progress.fractionCompleted)) }
            }
            var saved = downloadedMLXModels
            saved.insert(modelID)
            downloadedMLXModels = saved
            await setMLXState(.ready)
        } catch {
            let message = "Could not download language model '\(modelID)': \(error.localizedDescription)"
            await setMLXState(.failed(message))
            throw ProcessingProviderError.localModelNotReady(message)
        }
        #endif
    }

    public var isMLXReady: Bool {
        mlxDownloadState == .ready
    }

    // MARK: - Summarization

    /// Summarises a transcript using whichever tier is active on this device.
    public func summarize(
        transcript: Transcript,
        depth: SummaryDepth,
        mlxModelID: String
    ) async throws -> MeetingSummary {
        switch tier {
        case .appleIntelligence:
            return try await summarizeWithAppleIntelligence(transcript: transcript, depth: depth)
        case .mlx:
            return try await summarizeWithMLX(transcript: transcript, depth: depth, modelID: mlxModelID)
        case .unavailable:
            throw ProcessingProviderError.localUnsupported(
                "Local processing requires Apple Silicon. Please switch to API mode or use an Apple Silicon Mac."
            )
        }
    }

    // MARK: - Apple Intelligence path

    private func summarizeWithAppleIntelligence(
        transcript: Transcript,
        depth: SummaryDepth
    ) async throws -> MeetingSummary {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession()
            let prompt = buildPrompt(transcript: transcript, depth: depth)
            do {
                let response = try await session.respond(to: prompt)
                return try parseSummaryFromText(response.content)
            } catch {
                throw ProcessingProviderError.localProcessingError(
                    "Apple Intelligence summarization failed: \(error.localizedDescription)"
                )
            }
        }
        #endif
        // Fallback if FoundationModels unavailable at runtime despite tier detection
        throw ProcessingProviderError.localUnsupported(
            "Apple Intelligence is not available on this system. Please switch to API mode."
        )
    }

    // MARK: - MLX path

    private func summarizeWithMLX(
        transcript: Transcript,
        depth: SummaryDepth,
        modelID: String
    ) async throws -> MeetingSummary {
        #if arch(arm64)
        // Lazy-load: files are on disk but container not yet in memory
        if mlxContainer == nil || loadedMLXModelID != modelID {
            guard downloadedMLXModels.contains(modelID) else {
                throw ProcessingProviderError.localModelNotReady(
                    "MLX language model is not downloaded. Open Settings and tap Download."
                )
            }
            await setMLXState(.loading)
            do {
                let config = ModelConfiguration(id: modelID)
                let container = try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: config
                ) { _ in }
                mlxContainer = container
                loadedMLXModelID = modelID
                await setMLXState(.ready)
            } catch {
                let message = "Could not load language model '\(modelID)': \(error.localizedDescription)"
                await setMLXState(.failed(message))
                throw ProcessingProviderError.localModelNotReady(message)
            }
        }

        guard let container = mlxContainer else {
            throw ProcessingProviderError.localModelNotReady(
                "MLX language model failed to load."
            )
        }

        let prompt = buildPrompt(transcript: transcript, depth: depth)

        do {
            // Some local models do not reliably emit an end-of-sequence token.
            // Always enforce an application-level limit so summarization cannot
            // generate indefinitely.
            let generationParameters = GenerateParameters(
                maxTokens: maximumOutputTokens(for: depth),
                temperature: 0
            )
            let session = ChatSession(
                container,
                generateParameters: generationParameters
            )
            let output = try await session.respond(to: prompt)
            return try parseSummaryFromText(output)
        } catch {
            throw ProcessingProviderError.localProcessingError(
                "MLX summarization failed: \(error.localizedDescription)"
            )
        }
        #else
        throw ProcessingProviderError.localUnsupported(
            "MLX requires Apple Silicon. Please switch to API mode."
        )
        #endif
    }

    private func maximumOutputTokens(for depth: SummaryDepth) -> Int {
        switch depth {
        case .brief: 384
        case .standard: 640
        case .detailed: 1_024
        }
    }

    // MARK: - Prompt building

    private func buildPrompt(transcript: Transcript, depth: SummaryDepth) -> String {
        let depthInstruction: String
        switch depth {
        case .brief:    depthInstruction = "Keep each list to 2-3 items maximum."
        case .standard: depthInstruction = "Keep each list to 4-6 items."
        case .detailed: depthInstruction = "Be thorough; include all significant details."
        }

        return """
        You are a meeting notes assistant. Create a \(depth.rawValue) meeting summary from the following transcript.

        Rules:
        - Return ONLY valid JSON — no markdown fences, no explanation, no preamble.
        - \(depthInstruction)
        - If a section has nothing to report, use an empty array [].

        Required JSON format:
        {
          "title": "Brief descriptive meeting title",
          "keyPoints": ["point 1", "point 2"],
          "decisions": ["decision 1"],
          "actionItems": ["action item 1"],
          "followUps": ["follow-up question 1"]
        }

        Transcript:
        \(transcript.plainText)
        """
    }

    // MARK: - JSON parsing

    private func parseSummaryFromText(_ text: String) throws -> MeetingSummary {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract first JSON object if the model added preamble
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        guard let data = cleaned.data(using: .utf8) else {
            throw ProcessingProviderError.localProcessingError(
                "Local model returned non-UTF-8 text."
            )
        }

        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: data)
        } catch {
            throw ProcessingProviderError.localProcessingError(
                "Local model did not return valid meeting-summary JSON: \(error.localizedDescription)\n\nRaw output: \(cleaned.prefix(500))"
            )
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func setMLXState(_ state: ModelDownloadState) {
        mlxDownloadState = state
    }
}

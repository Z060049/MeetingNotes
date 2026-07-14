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

    // MARK: - Title generation

    /// Generates a short title (4–6 words) for use in filenames.
    /// Uses the same active tier but with a strict 40-token cap so it returns fast.
    /// Never throws — returns "recording" on any failure.
    public func generateTitle(transcript: Transcript, mlxModelID: String) async -> String {
        let prompt = """
        Reply with only a title of 4-6 words for this conversation. \
        Use plain words, no punctuation, no quotes.

        Transcript:
        \(transcript.textForSummarization.prefix(400))
        """

        do {
            switch tier {
            case .appleIntelligence:
                return try await generateTitleWithAppleIntelligence(prompt: prompt)
            case .mlx:
                return try await generateTitleWithMLX(prompt: prompt, modelID: mlxModelID)
            case .unavailable:
                return "recording"
            }
        } catch {
            return "recording"
        }
    }

    private func generateTitleWithAppleIntelligence(prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            return sanitizeTitle(response.content)
        }
        #endif
        return "recording"
    }

    private func generateTitleWithMLX(prompt: String, modelID: String) async throws -> String {
        #if arch(arm64)
        if mlxContainer == nil || loadedMLXModelID != modelID {
            guard downloadedMLXModels.contains(modelID) else { return "recording" }
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
                return "recording"
            }
        }

        guard let container = mlxContainer else { return "recording" }
        let params = GenerateParameters(maxTokens: 40, temperature: 0)
        let session = ChatSession(container, generateParameters: params)
        let output = try await session.respond(to: prompt)
        return sanitizeTitle(output)
        #else
        return "recording"
        #endif
    }

    private func sanitizeTitle(_ raw: String) -> String {
        let stripped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ":", with: "")
        // Keep only the first line in case the model emits extra text
        let firstLine = stripped.components(separatedBy: "\n").first ?? stripped
        let words = firstLine.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? "recording" : words
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
                return parsePlainTextSummary(response.content, fallbackTitle: "Meeting")
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
            return parsePlainTextSummary(output, fallbackTitle: "Meeting")
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
        case .brief: 768
        case .standard: 1_536
        case .detailed: 2_560
        }
    }

    // MARK: - Prompt building

    private func buildPrompt(transcript: Transcript, depth: SummaryDepth) -> String {
        let bulletLimit: String
        switch depth {
        case .brief:    bulletLimit = "Write at most 3 bullets under KEY POINTS."
        case .standard: bulletLimit = "Write at most 5 bullets under KEY POINTS."
        case .detailed: bulletLimit = "Write at most 8 bullets under KEY POINTS."
        }

        return """
        You are a meeting notes assistant. Summarize the transcript using the exact section headers below.
        Write one short bullet per line starting with "- ". Use "- none" if a section has nothing to report.
        Stop after FOLLOW UPS. Do not add any other text.
        \(bulletLimit)

        TITLE: <4-6 word title>
        KEY POINTS:
        - <key point>
        DECISIONS:
        - <decision or none>
        ACTION ITEMS:
        - <action item or none>
        FOLLOW UPS:
        - <follow-up question or none>

        Transcript:
        \(transcript.textForSummarization)

        TITLE:
        """
    }

    // MARK: - Plain-text section parsing

    /// Parses the model's plain-text section output into a `MeetingSummary`.
    /// Never throws — always returns something usable regardless of model output quality.
    private func parsePlainTextSummary(_ text: String, fallbackTitle: String) -> MeetingSummary {
        let lines = text.components(separatedBy: "\n")

        var title = ""
        var keyPoints: [String] = []
        var decisions: [String] = []
        var actionItems: [String] = []
        var followUps: [String] = []

        enum Section { case title, keyPoints, decisions, actionItems, followUps, none }
        var currentSection: Section = .title

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Section header detection
            let upper = line.uppercased()
            if upper.hasPrefix("TITLE:") {
                currentSection = .title
                let value = line.dropFirst("TITLE:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && !value.hasPrefix("<") { title = value }
                continue
            }
            if upper.hasPrefix("KEY POINTS") { currentSection = .keyPoints; continue }
            if upper.hasPrefix("DECISIONS")  { currentSection = .decisions;  continue }
            if upper.hasPrefix("ACTION ITEMS") { currentSection = .actionItems; continue }
            if upper.hasPrefix("FOLLOW UPS") || upper.hasPrefix("FOLLOW-UPS") {
                currentSection = .followUps; continue
            }

            // Bullet lines
            if line.hasPrefix("- ") || line.hasPrefix("• ") {
                let content = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                // Skip placeholder or "none" entries
                let lower = content.lowercased()
                if lower == "none" || lower.hasPrefix("<") || content.isEmpty { continue }

                switch currentSection {
                case .keyPoints:   keyPoints.append(content)
                case .decisions:   decisions.append(content)
                case .actionItems: actionItems.append(content)
                case .followUps:   followUps.append(content)
                case .title, .none: break
                }
            } else if currentSection == .title && title.isEmpty && !line.hasPrefix("<") {
                // Handles models that omit the "TITLE:" label and just write the title
                title = line
            }
        }

        let resolvedTitle = title.isEmpty ? fallbackTitle : title
        return MeetingSummary(
            title: resolvedTitle,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            followUps: followUps
        )
    }

    // MARK: - Private helpers

    @MainActor
    private func setMLXState(_ state: ModelDownloadState) {
        mlxDownloadState = state
    }
}

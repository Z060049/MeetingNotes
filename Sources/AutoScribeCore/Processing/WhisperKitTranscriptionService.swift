import Foundation
import WhisperKit

/// Shared download/load state for a locally-stored model.
public enum ModelDownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)

    public var isReady: Bool { self == .ready }

    public var progressValue: Double? {
        if case .downloading(let p) = self { return p }
        return nil
    }
}

/// Wraps WhisperKit for on-device speech-to-text transcription.
///
/// Model download and loading happen explicitly via `prepareModel(_:)` before
/// any call to `transcribe(files:modelSize:)`. The pipeline is loaded lazily
/// at first transcription so that restarts are fast — the state machine tracks
/// whether model files are present on disk independently of whether the model
/// is loaded into memory.
public final class WhisperKitTranscriptionService: ObservableObject, @unchecked Sendable {
    @Published public private(set) var downloadState: ModelDownloadState = .notDownloaded

    private var pipeline: WhisperKit?
    private var onDiskSize: WhisperModelSize?  // files present on disk
    private var loadedSize: WhisperModelSize?  // pipeline loaded in memory
    private var modelFolderURL: URL?           // returned by WhisperKit.download()

    // Persisted set of model rawValues confirmed downloaded to disk.
    private static let udKey = "com.autoscribe.downloadedWhisperModels"
    private static let udFolderKey = "com.autoscribe.whisperModelFolderURL"
    private var downloadedOnDisk: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.udKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.udKey) }
    }
    private var persistedFolderURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Self.udFolderKey) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: Self.udFolderKey) }
    }

    public init() {}

    // MARK: - Model management

    /// Restores ready state at app launch without touching the network.
    /// Returns immediately if the model was previously downloaded on this machine.
    public func checkIfDownloaded(_ size: WhisperModelSize) {
        guard downloadedOnDisk.contains(size.rawValue) else { return }
        onDiskSize = size

        if let url = persistedFolderURL, FileManager.default.fileExists(atPath: url.path) {
            modelFolderURL = url
        } else {
            // Reconstruct the path from WhisperKit's known folder layout.
            // WhisperKit.download() stores to Documents/huggingface/models/argmaxinc/whisperkit-coreml/<model>
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let reconstructed = documents
                .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(size.rawValue)")
            if FileManager.default.fileExists(atPath: reconstructed.path) {
                modelFolderURL = reconstructed
                persistedFolderURL = reconstructed
            }
        }

        downloadState = .ready
    }

    /// Downloads (if needed) and marks the model as ready. The pipeline is
    /// loaded lazily at the first call to `transcribe`.
    public func prepareModel(_ size: WhisperModelSize) async throws {
        if onDiskSize == size || (loadedSize == size && pipeline != nil) {
            await setDownloadState(.ready)
            return
        }

        await setDownloadState(.downloading(progress: 0.0))

        do {
            await setDownloadState(.loading)
            // Use the static download API — no pipeline instantiation, no CoreML
            // compilation, no memory spike. Just fetches model files to the cache.
            let folderURL = try await WhisperKit.download(variant: size.modelIdentifier)
            onDiskSize = size
            modelFolderURL = folderURL
            var saved = downloadedOnDisk
            saved.insert(size.rawValue)
            downloadedOnDisk = saved
            persistedFolderURL = folderURL
            await setDownloadState(.ready)
            await setDownloadState(.ready)
        } catch {
            let message = "Could not download Whisper model '\(size.rawValue)': \(error.localizedDescription)"
            await setDownloadState(.failed(message))
            throw ProcessingProviderError.localModelNotReady(message)
        }
    }

    /// Files are on disk (ready state). Pipeline may still need to be loaded
    /// in memory — that happens lazily inside `transcribe`.
    public var isReady: Bool { downloadState == .ready }

    /// Releases the in-memory pipeline to free RAM before a large MLX model loads.
    public func releaseModel() {
        pipeline = nil
        loadedSize = nil
    }

    // MARK: - Transcription

    /// Transcribes all eligible audio files from a recording session.
    ///
    /// If the model files are on disk but the pipeline hasn't been loaded into
    /// memory yet (e.g. after a restart), this loads the pipeline first.
    public func transcribe(
        files: [CapturedAudioFile],
        modelSize: WhisperModelSize
    ) async throws -> Transcript {
        // Lazy-load the pipeline if files are on disk but not yet in memory.
        if pipeline == nil || loadedSize != modelSize {
            guard onDiskSize == modelSize else {
                throw ProcessingProviderError.localModelNotReady(
                    "Whisper model '\(modelSize.displayName)' is not downloaded. Open Settings → Download."
                )
            }
            await setDownloadState(.loading)
            do {
                let computeOptions = ModelComputeOptions(
                    audioEncoderCompute: .cpuOnly,
                    textDecoderCompute: .cpuOnly
                )
                let pipe: WhisperKit
                if let folderURL = modelFolderURL {
                    print("[WhisperKit] Loading from folder: \(folderURL.path)")
                    pipe = try await WhisperKit(
                        modelFolder: folderURL.path,
                        computeOptions: computeOptions,
                        verbose: true,
                        logLevel: .debug,
                        prewarm: false,
                        load: true,
                        download: false
                    )
                    print("[WhisperKit] Loaded successfully")
                } else {
                    print("[WhisperKit] No folder URL, using model identifier with download:true")
                    pipe = try await WhisperKit(
                        model: modelSize.modelIdentifier,
                        computeOptions: computeOptions,
                        verbose: true,
                        logLevel: .debug,
                        prewarm: false,
                        load: true,
                        download: true
                    )
                    print("[WhisperKit] Loaded successfully via model identifier")
                }
                pipeline = pipe
                loadedSize = modelSize
                await setDownloadState(.ready)
            } catch {
                let message = "Could not load Whisper model '\(modelSize.rawValue)': \(error.localizedDescription)"
                await setDownloadState(.failed(message))
                throw ProcessingProviderError.localModelNotReady(message)
            }
        }

        guard let pipeline else {
            throw ProcessingProviderError.localModelNotReady("Pipeline unavailable.")
        }

        var segments: [TranscriptSegment] = []

        for file in files {
            guard AudioTranscriptionPolicy.decision(for: file).shouldTranscribe else { continue }
            // Use the silence-trimmed URL when available; fall back to the original
            // file when trimmedSilence finds no active frames above threshold.
            // Skipping outright was too aggressive for quiet mics — Whisper will
            // simply return nothing for truly silent audio, and the filler-token
            // filter below handles any hallucinated output.
            var transcriptionAudio = AudioLevelAnalyzer.TrimmedAudio(
                url: file.url,
                startOffset: 0
            )
            if let trimmed = try? AudioLevelAnalyzer.trimmedSilence(url: file.url) {
                transcriptionAudio = trimmed
            }
            let uploadURL = transcriptionAudio.url
            let timelineOffset = file.captureStartOffset + transcriptionAudio.startOffset
            defer {
                if uploadURL != file.url {
                    try? FileManager.default.removeItem(at: uploadURL)
                }
            }

            do {
                let options = DecodingOptions(
                    temperature: 0.0,
                    usePrefillPrompt: true,
                    skipSpecialTokens: true
                )
                let results = try await pipeline.transcribe(
                    audioPath: uploadURL.path,
                    decodeOptions: options
                )

                // Emit one TranscriptSegment per WhisperKit sub-segment so that
                // each segment carries a real start-time offset.  This enables
                // timestamp-aware echo deduplication in TranscriptDeduplicator.
                var addedAny = false
                for result in results {
                    for seg in result.segments {
                        let segText = Self.sanitizedWhisperText(seg.text)
                        guard !segText.isEmpty, !Self.isWhisperFillerToken(segText) else { continue }
                        segments.append(TranscriptSegment(
                            speaker: file.source.rawValue,
                            startTime: timelineOffset + TimeInterval(seg.start),
                            endTime: timelineOffset + TimeInterval(seg.end),
                            text: segText
                        ))
                        addedAny = true
                    }
                }

                // Fallback: if this WhisperKit build doesn't populate segments but
                // does set result.text, use that without a timestamp so the
                // text-only deduplication path still works.
                if !addedAny {
                    let fallbackText = results
                        .map(\.text)
                        .joined(separator: " ")
                    let sanitizedFallback = Self.sanitizedWhisperText(fallbackText)
                    if !sanitizedFallback.isEmpty, !Self.isWhisperFillerToken(sanitizedFallback) {
                        segments.append(TranscriptSegment(
                            speaker: file.source.rawValue,
                            startTime: timelineOffset,
                            text: sanitizedFallback
                        ))
                    }
                }
            } catch {
                // Log and continue — a failed file should not abort the whole session.
                segments.append(TranscriptSegment(
                    speaker: file.source.rawValue,
                    text: "[Transcription error: \(error.localizedDescription)]"
                ))
            }
        }

        return Transcript(segments: segments)
    }

    // MARK: - Private

    static func sanitizedWhisperText(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutControlTokens: String
        if let regex = try? NSRegularExpression(pattern: #"<\|[^|>]*\|>"#) {
            withoutControlTokens = regex.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: " "
            )
        } else {
            withoutControlTokens = text
        }

        return withoutControlTokens
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true for Whisper tokens that signal silence or non-speech events
    /// rather than real transcript content (e.g. `[BLANK_AUDIO]`, `[silence]`).
    private static func isWhisperFillerToken(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower == "[blank_audio]"
            || lower == "[silence]"
            || lower.hasPrefix("[ silence")
    }

    @MainActor
    private func setDownloadState(_ state: ModelDownloadState) {
        downloadState = state
    }
}

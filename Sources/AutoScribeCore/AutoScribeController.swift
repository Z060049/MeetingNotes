import Combine
import Foundation

public struct ProcessingFailure: Sendable {
    public let message: String
    public let savedAudioURL: URL?

    public init(message: String, savedAudioURL: URL?) {
        self.message = message
        self.savedAudioURL = savedAudioURL
    }
}

public final class AutoScribeController: ObservableObject {
    @Published public private(set) var state: AppState = .idle
    @Published public private(set) var settings: AppSettings
    @Published public private(set) var lastError: String?
    @Published public private(set) var diagnostics: [DiagnosticEvent] = []
    @Published public private(set) var latestOutputURL: URL?

    /// Manages on-device Whisper and LLM models. Observe this in Settings for
    /// download state and actions.
    @Published public private(set) var localModelManager: LocalModelManager

    public let silenceDetected = PassthroughSubject<Void, Never>()
    public let processingFailed = PassthroughSubject<ProcessingFailure, Never>()

    private let settingsStore: SettingsStore
    private let audioCaptureService: DualAudioCaptureService
    private let markdownExporter: MarkdownExporter
    private var processingProvider: ProcessingProvider
    private var inactivityMonitor: InactivityMonitor?
    private var isStartingRecording = false

    @MainActor public var isRecordingOrStarting: Bool {
        state.isRecording || isStartingRecording
    }

    public init(
        settingsStore: SettingsStore = SettingsStore(),
        audioCaptureService: DualAudioCaptureService = DualAudioCaptureService(),
        markdownExporter: MarkdownExporter = MarkdownExporter(),
        processingProvider: ProcessingProvider? = nil
    ) {
        self.settingsStore = settingsStore
        self.audioCaptureService = audioCaptureService
        self.markdownExporter = markdownExporter
        let loadedSettings = settingsStore.load()
        self.settings = loadedSettings
        let manager = LocalModelManager()
        self.localModelManager = manager
        self.processingProvider = processingProvider ?? Self.makeProvider(
            for: loadedSettings,
            localModelManager: manager
        )
        Task { @MainActor in
            self.addDiagnostic("Controller initialized. Output folder: \(self.settings.outputDirectory.path)")
            self.reportRecoverableRecordings()
        }
        manager.checkDownloadStatus(whisperModel: loadedSettings.whisperModel, mlxModelID: loadedSettings.localLLMModel)
    }

    // MARK: - Provider factory

    private static func makeProvider(
        for settings: AppSettings,
        localModelManager: LocalModelManager
    ) -> ProcessingProvider {
        switch settings.processingMode {
        case .api:
            return OpenAIProcessingProvider { EnvironmentConfiguration.openAIAPIKey() }
        case .local:
            return LocalProcessingProvider(
                transcriptionService: localModelManager.transcriptionService,
                summarizationService: localModelManager.summarizationService
            )
        }
    }

    // MARK: - Settings

    @MainActor public func updateSettings(_ settings: AppSettings) {
        let previousMode = self.settings.processingMode
        self.settings = settings
        settingsStore.save(settings)
        if settings.processingMode != previousMode {
            processingProvider = Self.makeProvider(for: settings, localModelManager: localModelManager)
            addDiagnostic("Processing provider switched to \(settings.processingMode.rawValue) mode.")
        }
        addDiagnostic("Settings saved. Timeout: \(Int(settings.inactivityTimeoutSeconds))s, output: \(settings.outputDirectory.path)")
    }

    @MainActor public func acceptConsentChecklist() {
        var updated = settings
        updated.hasAcceptedConsentChecklist = true
        updateSettings(updated)
        addDiagnostic("Consent checklist accepted.")
    }

    @MainActor public func toggleRecording() {
        if state.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @MainActor public func startRecording() {
        addDiagnostic("Start recording requested.")
        guard !isStartingRecording else {
            addDiagnostic("Recording startup is already in progress.", level: .warning)
            return
        }

        guard settings.hasAcceptedConsentChecklist else {
            setState(.failed("Please accept the recording consent checklist before starting."))
            return
        }

        let sessionID = UUID()
        let session = RecordingSession(
            id: sessionID,
            processingMode: settings.processingMode,
            outputDirectory: settings.outputDirectory,
            temporaryDirectory: FileManager.default.autoScribeRecordingWorkspace(for: sessionID)
        )

        latestOutputURL = nil
        addDiagnostic("Recording session \(Self.shortSessionID(session.id)) started.")
        addDiagnostic("Recording output folder: \(settings.outputDirectory.path)")
        addDiagnostic("Recording mode: \(settings.processingMode.rawValue), silence prompt after: \(Int(settings.inactivityTimeoutSeconds))s")
        addDiagnostic("Audio capture startup in progress.")
        isStartingRecording = true
        lastError = nil

        Task {
            do {
                await configureInactivityMonitor()
                await MainActor.run {
                    self.addDiagnostic("Starting audio capture in \(session.temporaryDirectory.path)")
                }
                let warnings = try await audioCaptureService.start(session: session)
                await MainActor.run {
                    self.isStartingRecording = false
                    self.setState(.recording(session))
                    self.addDiagnostic("Audio capture started.")
                    for warning in warnings {
                        self.addDiagnostic(warning, level: .warning)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isStartingRecording = false
                    self.fail(error)
                }
            }
        }
    }

    @MainActor public func stopRecording() {
        addDiagnostic("Stop recording requested.")
        Task {
            do {
                let result = try await audioCaptureService.stop()
                inactivityMonitor?.stop()
                inactivityMonitor = nil
                addDiagnostic("Audio capture stopped. Files: \(result.files.map { $0.url.lastPathComponent }.joined(separator: ", "))")
                for diagnostic in result.diagnostics {
                    addDiagnostic(diagnostic)
                }
                for file in result.files {
                    addDiagnostic("\(file.source.rawValue) file size: \(Self.fileSizeDescription(for: file.url))")
                }
                await process(result)
            } catch {
                fail(error)
            }
        }
    }

    @MainActor public func discardRecording() async -> Bool {
        addDiagnostic("Discard recording requested during app termination.", level: .warning)
        do {
            let result = try await audioCaptureService.stop()
            inactivityMonitor?.stop()
            inactivityMonitor = nil
            cleanupTemporaryFiles(for: result.session)
            setState(.idle)
            addDiagnostic("Recording discarded.")
            return true
        } catch {
            fail(error)
            return false
        }
    }

    @MainActor private func process(_ capture: AudioCaptureResult) async {
        setState(.processing(capture.session))
        addDiagnostic("Processing session \(Self.shortSessionID(capture.session.id)).")
        addDiagnostic("Processing started with \(capture.files.count) audio file(s).")
        addDiagnostic("Processing mode: \(settings.processingMode.rawValue).")
        logTranscriptionDecisions(for: capture.files)

        do {
            let result = try await processingProvider.process(capture: capture, settings: settings)
            addDiagnostic("Processing complete. Exporting Markdown.")
            let outputURL = try markdownExporter.export(
                result: result,
                session: capture.session,
                to: settings.outputDirectory
            )
            cleanupTemporaryFiles(for: capture.session)
            latestOutputURL = outputURL
            setState(.complete(outputURL))
            addDiagnostic("Markdown saved to \(outputURL.path)")
            addDiagnostic("Validation output: duration \(Self.durationDescription(capture.session.duration)), path \(outputURL.path)")
        } catch {
            let savedURL = preserveUnprocessedAudio(capture)
            cleanupTemporaryFiles(for: capture.session)
            inactivityMonitor?.stop()
            inactivityMonitor = nil

            let base = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            var message = base
            if let savedURL {
                message += " Your recording was saved to \(savedURL.path) so you can process it later."
            }
            lastError = message
            setState(.failed(message))
            addDiagnostic(message, level: .error)
            processingFailed.send(ProcessingFailure(message: message, savedAudioURL: savedURL))
        }
    }

    private func preserveUnprocessedAudio(_ capture: AudioCaptureResult) -> URL? {
        guard !capture.files.isEmpty else {
            return nil
        }

        let folderName = "\(Self.filenameDateFormatter.string(from: capture.session.startedAt))_unprocessed"
        let destination = settings.outputDirectory.appendingPathComponent(folderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in capture.files {
                let target = destination.appendingPathComponent(file.url.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: file.url, to: target)
            }
            return destination
        } catch {
            Task { @MainActor in
                self.addDiagnostic("Could not save unprocessed audio: \(error.localizedDescription)", level: .warning)
            }
            return nil
        }
    }

    @MainActor private func configureInactivityMonitor() async {
        let cutoff = settings.inactivityTimeoutSeconds
        let monitor = InactivityMonitor(timeout: cutoff) { [weak self] in
            Task { @MainActor in
                self?.addDiagnostic("No audio detected for \(Int(cutoff))s. Prompting to stop.", level: .warning)
                self?.silenceDetected.send()
            }
        }

        audioCaptureService.setOnAudioLevel { [weak monitor] _, level in
            monitor?.recordAudioLevel(level)
        }

        monitor.start()
        inactivityMonitor = monitor
        addDiagnostic("Silence monitor started (prompt after \(Int(cutoff))s).")
    }

    @MainActor public func keepRecordingAfterSilence() {
        inactivityMonitor?.restart()
        addDiagnostic("Continuing recording after silence prompt.")
    }

    private func cleanupTemporaryFiles(for session: RecordingSession) {
        do {
            try FileManager.default.removeItem(at: session.temporaryDirectory)
            Task { @MainActor in
                self.addDiagnostic("Temporary files cleaned up.")
            }
        } catch {
            Task { @MainActor in
                self.addDiagnostic("Temporary cleanup skipped: \(error.localizedDescription)", level: .warning)
            }
        }
    }

    @MainActor private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        setState(.failed(message))
        addDiagnostic(message, level: .error)
        inactivityMonitor?.stop()
        inactivityMonitor = nil
    }

    @MainActor public func addDiagnostic(_ message: String, level: DiagnosticEvent.Level = .info) {
        let event = DiagnosticEvent(level: level, message: message)
        diagnostics.append(event)
        PersistentDiagnosticLog.shared.log(message, level: level, date: event.date)
        if diagnostics.count > 100 {
            diagnostics.removeFirst(diagnostics.count - 100)
        }
    }

    @MainActor public func clearDiagnostics() {
        diagnostics.removeAll()
    }

    @MainActor public func validationReportText() -> String {
        let outputPath = latestOutputURL?.path ?? "None"
        let error = lastError ?? "None"
        let diagnosticsText = diagnostics.map(\.formatted).joined(separator: "\n")

        return """
        AutoScribe Validation Report
        Generated: \(Self.reportDateFormatter.string(from: Date()))
        State: \(state.title)
        Output folder: \(settings.outputDirectory.path)
        Latest output: \(outputPath)
        Processing mode: \(settings.processingMode.rawValue)
        Summary depth: \(settings.summaryDepth.rawValue)
        Silence prompt after: \(Int(settings.inactivityTimeoutSeconds))s
        Last error: \(error)
        Persistent log: \(PersistentDiagnosticLog.shared.logURL.path)
        Crash reports: \(CrashLogManager.shared.reportDirectoryURL.path)
        Recording recovery: \(FileManager.default.autoScribeRecordingRecoveryDirectory.path)

        Diagnostics:
        \(diagnosticsText)
        """
    }

    @MainActor private func setState(_ state: AppState) {
        self.state = state
        CrashLogManager.shared.updateState(state.title)
        addDiagnostic("State changed to \(state.title).")
    }

    @MainActor private func reportRecoverableRecordings() {
        let directory = FileManager.default.autoScribeRecordingRecoveryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), !entries.isEmpty else {
            return
        }

        addDiagnostic(
            "Found \(entries.count) recoverable recording workspace(s) at \(directory.path).",
            level: .warning
        )
    }

    @MainActor private func logTranscriptionDecisions(for files: [CapturedAudioFile]) {
        for file in files {
            let decision = AudioTranscriptionPolicy.decision(for: file)
            let action = decision.shouldTranscribe ? "sent to transcription" : "skipped"
            let size = decision.fileSizeBytes.map { "\($0) bytes" } ?? "unknown size"
            addDiagnostic("\(file.source.rawValue) transcription \(action): \(decision.reason) (\(size))")
        }
    }

    private static func fileSizeDescription(for url: URL) -> String {
        guard let size = AudioTranscriptionPolicy.fileSizeBytes(for: url) else {
            return "unknown"
        }
        return "\(size) bytes"
    }

    private static func shortSessionID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func durationDescription(_ interval: TimeInterval) -> String {
        "\(Int(interval.rounded()))s"
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()

    private static let reportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

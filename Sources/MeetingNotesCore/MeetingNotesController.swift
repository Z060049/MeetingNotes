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

public final class MeetingNotesController: ObservableObject {
    @Published public private(set) var state: AppState = .idle
    @Published public private(set) var settings: AppSettings
    @Published public private(set) var lastError: String?
    @Published public private(set) var diagnostics: [DiagnosticEvent] = []
    @Published public private(set) var latestOutputURL: URL?
    @Published public private(set) var latestRawTranscriptURL: URL?
    @Published public private(set) var routeTransitionMessage: String?
    @Published public private(set) var permissionSnapshot: PermissionSnapshot

    /// Manages on-device Whisper and LLM models. Observe this in Settings for
    /// download state and actions.
    @Published public private(set) var localModelManager: LocalModelManager

    public let silenceDetected = PassthroughSubject<Void, Never>()
    public let processingFailed = PassthroughSubject<ProcessingFailure, Never>()
    public let onboardingRequested = PassthroughSubject<Void, Never>()

    private let settingsStore: SettingsStore
    private let permissionService: PermissionServicing
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
        permissionService: PermissionServicing = SystemPermissionService(),
        audioCaptureService: DualAudioCaptureService = DualAudioCaptureService(),
        markdownExporter: MarkdownExporter = MarkdownExporter(),
        processingProvider: ProcessingProvider? = nil
    ) {
        self.settingsStore = settingsStore
        self.permissionService = permissionService
        self.audioCaptureService = audioCaptureService
        self.markdownExporter = markdownExporter
        var loadedSettings = settingsStore.load()
        if loadedSettings.isAwaitingScreenCaptureRelaunch {
            loadedSettings.isAwaitingScreenCaptureRelaunch = false
            settingsStore.save(loadedSettings)
        }
        self.permissionSnapshot = PermissionSnapshot(
            microphone: permissionService.microphoneState(),
            screenCapture: permissionService.screenCaptureState(
                hasRequestedAccess: loadedSettings.hasRequestedScreenCapturePermission,
                isAwaitingRelaunch: loadedSettings.isAwaitingScreenCaptureRelaunch
            )
        )
        self.settings = loadedSettings
        let manager = LocalModelManager()
        self.localModelManager = manager
        self.processingProvider = processingProvider ?? Self.makeProvider(
            for: loadedSettings,
            localModelManager: manager
        )
        audioCaptureService.onRouteTransition = { [weak self] status in
            Task { @MainActor in
                self?.handleRouteTransition(status)
            }
        }
        Task { @MainActor in
            self.addDiagnostic("Controller initialized. Output folder: \(self.settings.outputDirectory.path)")
            self.reportRecoverableRecordings()
        }
        manager.checkDownloadStatus(whisperModel: loadedSettings.whisperModel, mlxModelID: loadedSettings.localLLMModel)
    }

    public var isSetupComplete: Bool {
        settings.hasAcceptedConsentChecklist
            && settings.hasCompletedOnboarding
            && permissionSnapshot.isReady
    }

    @MainActor private func handleRouteTransition(
        _ status: DualAudioCaptureService.TransitionStatus
    ) {
        switch status {
        case .switching(let previous, let current):
            routeTransitionMessage = "Switching audio device…"
            addDiagnostic(
                "Audio route transition: \(previous.description) → \(current.description)",
                level: .warning
            )
        case .restored(let route):
            routeTransitionMessage = nil
            addDiagnostic("Audio route reconnected: \(route.description)")
        case .degraded(let message):
            routeTransitionMessage = message
            addDiagnostic(message, level: .warning)
        }
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

    @MainActor public func refreshPermissionStatus() {
        permissionSnapshot = PermissionSnapshot(
            microphone: permissionService.microphoneState(),
            screenCapture: permissionService.screenCaptureState(
                hasRequestedAccess: settings.hasRequestedScreenCapturePermission,
                isAwaitingRelaunch: settings.isAwaitingScreenCaptureRelaunch
            )
        )
    }

    @MainActor public func requestMicrophoneAccess() async {
        _ = await permissionService.requestMicrophoneAccess()
        refreshPermissionStatus()
        addDiagnostic("Microphone permission status: \(permissionSnapshot.microphone.rawValue).")
    }

    @MainActor public func requestScreenCaptureAccess() {
        _ = permissionService.requestScreenCaptureAccess()
        var updated = settings
        updated.hasRequestedScreenCapturePermission = true
        updated.isAwaitingScreenCaptureRelaunch = true
        updated.hasCompletedOnboarding = false
        updateSettings(updated)
        refreshPermissionStatus()
        addDiagnostic("Screen capture permission requested; app relaunch required.")
    }

    @MainActor public func openMicrophoneSettings() {
        permissionService.openMicrophoneSettings()
    }

    @MainActor public func openScreenCaptureSettings() {
        permissionService.openScreenCaptureSettings()
    }

    @MainActor public func completeOnboarding() {
        refreshPermissionStatus()
        guard settings.hasAcceptedConsentChecklist, permissionSnapshot.isReady else {
            addDiagnostic("Onboarding completion blocked because permissions are incomplete.", level: .warning)
            return
        }
        var updated = settings
        updated.hasCompletedOnboarding = true
        updated.isAwaitingScreenCaptureRelaunch = false
        updateSettings(updated)
        addDiagnostic("Permission onboarding completed.")
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

        refreshPermissionStatus()
        guard isSetupComplete else {
            lastError = "Finish setup and grant Microphone and Screen & System Audio Recording access before starting."
            addDiagnostic(lastError ?? "Permission setup required.", level: .warning)
            onboardingRequested.send()
            return
        }

        let sessionID = UUID()
        let session = RecordingSession(
            id: sessionID,
            processingMode: settings.processingMode,
            outputDirectory: settings.outputDirectory,
            temporaryDirectory: FileManager.default.meetingNotesRecordingWorkspace(for: sessionID)
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
                routeTransitionMessage = nil
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
            routeTransitionMessage = nil
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

        // Capture values needed inside the Sendable closure.
        let outputDirectory = settings.outputDirectory
        let currentSettings = settings
        let session = capture.session

        // shortTitle is set while the unmodified transcript is persisted and read
        // after process() returns.
        // We use an actor-isolated box so the closure can write it safely.
        let titleBox = TitleBox()

        let onTranscriptReady: @Sendable (Transcript) async -> Void = { [weak self] transcript in
            guard let self else { return }

            // 1. Generate a short title (~4–6 words, 40 token cap).
            let shortTitle: String
            switch currentSettings.processingMode {
            case .local:
                shortTitle = await self.localModelManager.summarizationService.generateTitle(
                    transcript: transcript,
                    mlxModelID: currentSettings.localLLMModel
                )
            case .api:
                if let apiKey = EnvironmentConfiguration.openAIAPIKey(), !apiKey.isEmpty {
                    let provider = OpenAIProcessingProvider { apiKey }
                    shortTitle = await provider.generateTitle(transcript: transcript, apiKey: apiKey)
                } else {
                    shortTitle = "recording"
                }
            }

            await titleBox.set(shortTitle)

            // 2. Write the pre-deduplication transcript immediately as a true raw
            // fallback. The final summary document receives the cleaned transcript.
            do {
                let rawURL = try self.markdownExporter.exportRawTranscription(
                    transcript: transcript,
                    shortTitle: shortTitle,
                    session: session,
                    to: outputDirectory
                )
                await MainActor.run { [weak self] in
                    self?.latestRawTranscriptURL = rawURL
                    self?.addDiagnostic("Unmodified raw transcript saved to \(rawURL.path)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.addDiagnostic(
                        "Could not write raw transcript: \(error.localizedDescription)",
                        level: .warning
                    )
                }
            }
        }

        do {
            // Run transcription (and the onTranscriptReady callback which writes
            // the raw transcript file). Summarization errors are caught separately
            // below so the summary file is always written.
            let result: ProcessingResult
            do {
                result = try await processingProvider.process(
                    capture: capture,
                    settings: settings,
                    onTranscriptReady: onTranscriptReady
                )
                addDiagnostic("Processing complete. Exporting summary Markdown.")
            } catch {
                // Summarization or model-load failed. If we have a raw transcript
                // on disk (written by onTranscriptReady), produce a minimal summary
                // file so the user always gets both files.
                let shortTitle = await titleBox.value ?? "recording"
                let base = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                addDiagnostic("Summarization failed (\(base)). Writing minimal summary file.", level: .warning)

                // Build a fallback ProcessingResult using an empty transcript if
                // we never got one (e.g. Whisper itself failed — very rare).
                let emptyTranscript = Transcript(segments: [])
                let fallbackSummary = MeetingSummary(
                    title: shortTitle,
                    keyPoints: [],
                    decisions: [],
                    actionItems: [],
                    followUps: []
                )
                result = ProcessingResult(transcript: emptyTranscript, summary: fallbackSummary)
            }

            // Use the same shortTitle generated during onTranscriptReady so both
            // files share the same filename prefix.
            let shortTitle = await titleBox.value
            let outputURL: URL
            if let shortTitle {
                outputURL = try markdownExporter.exportSummary(
                    result: result,
                    shortTitle: shortTitle,
                    session: capture.session,
                    to: settings.outputDirectory
                )
            } else {
                outputURL = try markdownExporter.export(
                    result: result,
                    session: capture.session,
                    to: settings.outputDirectory
                )
            }

            cleanupTemporaryFiles(for: capture.session)
            latestOutputURL = outputURL
            setState(.complete(outputURL))
            addDiagnostic("Summary saved to \(outputURL.path)")
            addDiagnostic("Validation output: duration \(Self.durationDescription(capture.session.duration)), path \(outputURL.path)")
        } catch {
            // Only reaches here if transcription itself failed (Whisper error,
            // no speech detected, etc.) — summarization errors are handled above.
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

    /// A simple actor-isolated box for passing the generated title out of
    /// the `onTranscriptReady` closure back into the enclosing `process()` scope.
    private actor TitleBox {
        private(set) var value: String?
        func set(_ v: String) { value = v }
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
        routeTransitionMessage = nil
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
        MeetingNotes Validation Report
        Generated: \(Self.reportDateFormatter.string(from: Date()))
        State: \(state.title)
        Output folder: \(settings.outputDirectory.path)
        Latest output: \(outputPath)
        Processing mode: \(settings.processingMode.rawValue)
        Summary depth: \(settings.summaryDepth.rawValue)
        Silence prompt after: \(Int(settings.inactivityTimeoutSeconds))s
        Onboarding complete: \(settings.hasCompletedOnboarding)
        Microphone permission: \(permissionSnapshot.microphone.rawValue)
        Screen & system audio permission: \(permissionSnapshot.screenCapture.rawValue)
        Last error: \(error)
        Persistent log: \(PersistentDiagnosticLog.shared.logURL.path)
        Crash reports: \(CrashLogManager.shared.reportDirectoryURL.path)
        Recording recovery: \(FileManager.default.meetingNotesRecordingRecoveryDirectory.path)

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
        let directory = FileManager.default.meetingNotesRecordingRecoveryDirectory
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

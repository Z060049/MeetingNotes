import Foundation

public final class DualAudioCaptureService: @unchecked Sendable {
    public enum TransitionStatus: Sendable, Equatable {
        case switching(from: AudioRouteInspector.Route, to: AudioRouteInspector.Route)
        case restored(AudioRouteInspector.Route)
        case degraded(String)
    }

    private let microphoneRecorder: MicrophoneRecording
    private let systemAudioRecorders: [SystemAudioRecording]
    private let routeMonitor: AudioRouteChangeMonitoring
    private let coordinator: CaptureCoordinator
    private let transitionLock = NSLock()
    private var routeTransitionTask: Task<Void, Never>?

    public var onRouteTransition: (@Sendable (TransitionStatus) -> Void)? {
        didSet {
            let handler = onRouteTransition
            Task { await coordinator.setTransitionHandler(handler) }
        }
    }

    public init(
        microphoneRecorder: MicrophoneRecording = MicrophoneRecorder(),
        systemAudioRecorders: [SystemAudioRecording] = SystemAudioRecorderFactory.makePreferredRecorders(),
        routeMonitor: AudioRouteChangeMonitoring = AudioRouteChangeMonitor()
    ) {
        self.microphoneRecorder = microphoneRecorder
        self.systemAudioRecorders = systemAudioRecorders
        self.routeMonitor = routeMonitor
        self.coordinator = CaptureCoordinator(
            microphoneRecorder: microphoneRecorder,
            systemAudioRecorders: systemAudioRecorders
        )
        installAudioLevelHandlers()
    }

    public func setOnAudioLevel(_ handler: ((AudioSource, Float) -> Void)?) {
        microphoneRecorder.onAudioLevel = { level in
            handler?(.microphone, level)
        }
        for recorder in systemAudioRecorders {
            recorder.onAudioLevel = { level in
                handler?(.systemAudio, level)
            }
        }
    }

    public func start(session: RecordingSession) async throws -> [String] {
        let warnings = try await coordinator.start(session: session)
        routeMonitor.start { [weak self] previous, current in
            self?.scheduleRouteChange(from: previous, to: current)
        }
        return warnings
    }

    public func stop() async throws -> AudioCaptureResult {
        routeMonitor.stop()
        let pendingTask = transitionLock.withLock { () -> Task<Void, Never>? in
            let task = routeTransitionTask
            routeTransitionTask = nil
            task?.cancel()
            return task
        }
        await pendingTask?.value
        return try await coordinator.stop()
    }

    func handleRouteChangeForTesting(
        from previous: AudioRouteInspector.Route,
        to current: AudioRouteInspector.Route
    ) async {
        await coordinator.routeChanged(from: previous, to: current)
    }

    private func scheduleRouteChange(
        from previous: AudioRouteInspector.Route,
        to current: AudioRouteInspector.Route
    ) {
        transitionLock.withLock {
            let previousTask = routeTransitionTask
            previousTask?.cancel()
            routeTransitionTask = Task { [weak self] in
                await previousTask?.value
                guard let self else { return }
                await self.coordinator.routeChanged(from: previous, to: current)
            }
        }
    }

    private func installAudioLevelHandlers() {
        setOnAudioLevel(nil)
        microphoneRecorder.onInterruption = { [weak self] message in
            guard let self else { return }
            Task {
                await self.coordinator.recorderInterrupted(message)
            }
        }
    }
}

private actor CaptureCoordinator {
    private struct ActiveSegment {
        let file: CapturedAudioFile
        let route: AudioRouteInspector.Route
    }

    private let microphoneRecorder: MicrophoneRecording
    private let systemAudioRecorders: [SystemAudioRecording]

    private var currentSession: RecordingSession?
    private var activeMicrophone: ActiveSegment?
    private var activeSystemAudio: ActiveSegment?
    private var activeSystemAudioRecorder: SystemAudioRecording?
    private var completedFiles: [CapturedAudioFile] = []
    private var diagnostics: [String] = []
    private var microphoneSegmentIndex = 0
    private var systemAudioSegmentIndex = 0
    private var transitionHandler: (@Sendable (DualAudioCaptureService.TransitionStatus) -> Void)?

    init(
        microphoneRecorder: MicrophoneRecording,
        systemAudioRecorders: [SystemAudioRecording]
    ) {
        self.microphoneRecorder = microphoneRecorder
        self.systemAudioRecorders = systemAudioRecorders
    }

    func setTransitionHandler(
        _ handler: (@Sendable (DualAudioCaptureService.TransitionStatus) -> Void)?
    ) {
        transitionHandler = handler
    }

    func start(session: RecordingSession) async throws -> [String] {
        guard currentSession == nil else {
            throw AudioCaptureError.alreadyRecording
        }
        try FileManager.default.createDirectory(
            at: session.temporaryDirectory,
            withIntermediateDirectories: true
        )

        currentSession = session
        completedFiles = []
        diagnostics = []
        microphoneSegmentIndex = 0
        systemAudioSegmentIndex = 0

        let route = AudioRouteInspector.currentRoute()
        var warnings = ["Active audio route: \(route.description)"]
        if route.usesBluetoothInput || route.usesBluetoothOutput {
            warnings.append("Bluetooth audio route detected. Hot-swap monitoring enabled.")
        }

        do {
            try await startMicrophoneSegment(route: route)
            guard await microphoneRecorder.waitForFirstBuffer(timeoutSeconds: 2) else {
                throw AudioCaptureError.captureStartupTimedOut(
                    "Microphone capture did not produce a writable audio buffer within 2 seconds."
                )
            }
            warnings.append("Microphone capture started.")
        } catch {
            currentSession = nil
            throw error
        }

        do {
            try await startSystemAudioSegment(route: route)
            if let recorder = activeSystemAudioRecorder {
                warnings.append("System audio capture started with \(recorder.backendName).")
            }
        } catch {
            warnings.append(
                "System audio capture unavailable: \(error.localizedDescription). Microphone recording continued."
            )
        }
        return warnings
    }

    func routeChanged(
        from previous: AudioRouteInspector.Route,
        to current: AudioRouteInspector.Route
    ) async {
        guard currentSession != nil else { return }
        guard !Task.isCancelled else { return }
        transitionHandler?(.switching(from: previous, to: current))
        diagnostics.append("Audio route changing from \(previous.description) to \(current.description).")

        let inputChanged = previous.input?.uid != current.input?.uid
        let outputChanged = previous.output?.uid != current.output?.uid
        var fullyRestored = true

        if inputChanged {
            await finalizeMicrophoneSegment()
            guard !Task.isCancelled, currentSession != nil else { return }
            if current.input != nil {
                do {
                    try await reconnectMicrophone(preferredRoute: current)
                } catch is CancellationError {
                    return
                } catch {
                    fullyRestored = false
                    let message = "Microphone did not reconnect: \(error.localizedDescription)"
                    diagnostics.append(message)
                    transitionHandler?(.degraded(message))
                }
            } else {
                fullyRestored = false
                let message = "No microphone is currently available; system audio continues."
                diagnostics.append(message)
                transitionHandler?(.degraded(message))
            }
        }

        if outputChanged {
            await finalizeSystemAudioSegment()
            guard !Task.isCancelled, currentSession != nil else { return }
            if current.output != nil {
                do {
                    try await reconnectSystemAudio(preferredRoute: current)
                } catch is CancellationError {
                    return
                } catch {
                    fullyRestored = false
                    let message = "System audio did not reconnect: \(error.localizedDescription)"
                    diagnostics.append(message)
                    transitionHandler?(.degraded(message))
                }
            } else {
                fullyRestored = false
                let message = "No output device is currently available; microphone capture continues."
                diagnostics.append(message)
                transitionHandler?(.degraded(message))
            }
        }

        guard currentSession != nil, !Task.isCancelled else { return }
        if fullyRestored {
            diagnostics.append("Audio route restored: \(current.description).")
            transitionHandler?(.restored(current))
        }
    }

    func recorderInterrupted(_ message: String) {
        guard currentSession != nil else { return }
        diagnostics.append(message)
    }

    func stop() async throws -> AudioCaptureResult {
        guard var session = currentSession else {
            throw AudioCaptureError.notRecording
        }

        // Clear the session first. A route-change task that resumes after an
        // await will see nil and will not start another segment.
        currentSession = nil
        await finalizeMicrophoneSegment()
        await finalizeSystemAudioSegment()

        session = session.finished
        session.audioSources = Set(completedFiles.map(\.source))
        let files = completedFiles.sorted {
            if $0.captureStartOffset == $1.captureStartOffset {
                return $0.segmentIndex < $1.segmentIndex
            }
            return $0.captureStartOffset < $1.captureStartOffset
        }

        completedFiles = []
        activeMicrophone = nil
        activeSystemAudio = nil
        activeSystemAudioRecorder = nil
        return AudioCaptureResult(session: session, files: files, diagnostics: diagnostics)
    }

    private func startMicrophoneSegment(route: AudioRouteInspector.Route) async throws {
        guard let session = currentSession else { throw AudioCaptureError.notRecording }
        microphoneSegmentIndex += 1
        let index = microphoneSegmentIndex
        let offset = max(0, Date().timeIntervalSince(session.startedAt))
        let filename = String(format: "microphone-%04d.wav", index)
        let url = try await microphoneRecorder.start(
            in: session.temporaryDirectory,
            filename: filename,
            deviceUID: route.input?.uid,
            deviceName: route.input?.name
        )
        guard currentSession?.id == session.id, !Task.isCancelled else {
            _ = try? await microphoneRecorder.stop()
            throw CancellationError()
        }
        activeMicrophone = ActiveSegment(
            file: CapturedAudioFile(
                source: .microphone,
                url: url,
                captureStartOffset: offset,
                segmentIndex: index,
                deviceUID: route.input?.uid
            ),
            route: route
        )
        diagnostics.append("Microphone segment \(filename) started at \(offset)s on \(route.input?.diagnosticDescription ?? "unknown").")
    }

    private func startSystemAudioSegment(route: AudioRouteInspector.Route) async throws {
        guard let session = currentSession else { throw AudioCaptureError.notRecording }
        systemAudioSegmentIndex += 1
        let index = systemAudioSegmentIndex
        let offset = max(0, Date().timeIntervalSince(session.startedAt))
        let filename = String(format: "system-audio-%04d.wav", index)

        var lastError: Error?
        var failedBackends: [String] = []
        for recorder in systemAudioRecorders {
            do {
                let url = try await recorder.start(in: session.temporaryDirectory, filename: filename)
                guard currentSession?.id == session.id, !Task.isCancelled else {
                    _ = try? await recorder.stop()
                    throw CancellationError()
                }
                activeSystemAudioRecorder = recorder
                activeSystemAudio = ActiveSegment(
                    file: CapturedAudioFile(
                        source: .systemAudio,
                        url: url,
                        captureStartOffset: offset,
                        segmentIndex: index,
                        deviceUID: route.output?.uid
                    ),
                    route: route
                )
                if !failedBackends.isEmpty {
                    diagnostics.append(
                        "System audio fallback selected \(recorder.backendName) after \(failedBackends.joined(separator: "; "))."
                    )
                }
                diagnostics.append("System audio segment \(url.lastPathComponent) started at \(offset)s with \(recorder.backendName).")
                return
            } catch {
                lastError = error
                let failure = "\(recorder.backendName) unavailable: \(error.localizedDescription)"
                failedBackends.append(failure)
                diagnostics.append("\(failure) during route setup.")
            }
        }
        throw lastError ?? AudioCaptureError.systemAudioBackendUnavailable(
            "No system audio backend was available."
        )
    }

    private func reconnectMicrophone(
        preferredRoute: AudioRouteInspector.Route
    ) async throws {
        var lastError: Error?
        // Core Audio announces a Bluetooth default route before AVFoundation
        // necessarily publishes an openable capture device for it.
        if preferredRoute.usesBluetoothInput {
            try await Task.sleep(nanoseconds: 750_000_000)
        }
        for attempt in 1...5 {
            guard currentSession != nil, !Task.isCancelled else { throw CancellationError() }
            let route = attempt == 1 ? preferredRoute : AudioRouteInspector.currentRoute()
            do {
                try await startMicrophoneSegment(route: route)
                guard await microphoneRecorder.waitForFirstBuffer(timeoutSeconds: 2) else {
                    await finalizeMicrophoneSegment()
                    throw AudioCaptureError.captureStartupTimedOut(
                        "The replacement microphone produced no audio."
                    )
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 5 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError ?? AudioCaptureError.unsupportedInputRoute(
            "The replacement microphone could not be opened."
        )
    }

    private func reconnectSystemAudio(
        preferredRoute: AudioRouteInspector.Route
    ) async throws {
        var lastError: Error?
        for attempt in 1...3 {
            guard currentSession != nil, !Task.isCancelled else { throw CancellationError() }
            let route = attempt == 1 ? preferredRoute : AudioRouteInspector.currentRoute()
            do {
                try await startSystemAudioSegment(route: route)
                return
            } catch {
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError ?? AudioCaptureError.systemAudioBackendUnavailable(
            "System audio could not reconnect."
        )
    }

    private func finalizeMicrophoneSegment() async {
        guard let active = activeMicrophone else { return }
        activeMicrophone = nil
        do {
            _ = try await microphoneRecorder.stop()
            completedFiles.append(active.file)
            diagnostics.append("Microphone segment \(active.file.url.lastPathComponent) finalized.")
        } catch {
            if FileManager.default.fileExists(atPath: active.file.url.path) {
                completedFiles.append(active.file)
            }
            diagnostics.append("Microphone segment finalization warning: \(error.localizedDescription)")
        }
    }

    private func finalizeSystemAudioSegment() async {
        guard let active = activeSystemAudio,
              let recorder = activeSystemAudioRecorder else { return }
        activeSystemAudio = nil
        activeSystemAudioRecorder = nil
        do {
            _ = try await recorder.stop()
            completedFiles.append(active.file)
            if let summary = recorder.diagnosticSummary {
                diagnostics.append(summary)
            }
            diagnostics.append("System audio segment \(active.file.url.lastPathComponent) finalized.")
        } catch {
            if FileManager.default.fileExists(atPath: active.file.url.path) {
                completedFiles.append(active.file)
            }
            diagnostics.append("System audio segment finalization warning: \(error.localizedDescription)")
        }
    }
}

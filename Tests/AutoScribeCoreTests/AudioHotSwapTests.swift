import CoreAudio
import Foundation
import XCTest
@testable import AutoScribeCore

final class AudioHotSwapTests: XCTestCase {
    func testCoreAudioBluetoothUIDMatchesAVCaptureUIDWithoutDirectionSuffix() {
        let index = MicrophoneRecorder.bestMatchingDeviceIndex(
            requestedUID: "2C-18-09-F0-D9-98:input",
            requestedName: "YIYANG’s AirPods Pro",
            candidates: [
                (uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
                (uid: "2C-18-09-F0-D9-98", name: "YIYANG’s AirPods Pro")
            ]
        )

        XCTAssertEqual(index, 1)
    }

    func testRequestedDeviceDoesNotSilentlyFallBackToDefault() {
        let index = MicrophoneRecorder.bestMatchingDeviceIndex(
            requestedUID: "airpods:input",
            requestedName: "AirPods",
            candidates: [(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")]
        )

        XCTAssertNil(index)
    }

    func testInputAndOutputChangeCreatesTimelineAlignedSegments() async throws {
        let microphone = FakeMicrophoneRecorder()
        let systemAudio = FakeSystemAudioRecorder()
        let monitor = FakeRouteMonitor()
        let service = DualAudioCaptureService(
            microphoneRecorder: microphone,
            systemAudioRecorders: [systemAudio],
            routeMonitor: monitor
        )
        let directory = temporaryDirectory()
        _ = try await service.start(session: session(directory: directory))

        let builtIn = route(input: "built-in-input", output: "built-in-output")
        let airPods = route(input: "airpods-input", output: "airpods-output")
        await service.handleRouteChangeForTesting(from: builtIn, to: airPods)
        let result = try await service.stop()

        XCTAssertEqual(microphone.startCount, 2)
        XCTAssertEqual(microphone.stopCount, 2)
        XCTAssertEqual(systemAudio.startCount, 2)
        XCTAssertEqual(systemAudio.stopCount, 2)
        XCTAssertEqual(result.files.count, 4)

        let microphoneFiles = result.files.filter { $0.source == .microphone }
        XCTAssertEqual(microphoneFiles.map(\.segmentIndex), [1, 2])
        XCTAssertEqual(
            microphoneFiles.map { $0.url.lastPathComponent },
            ["microphone-0001.wav", "microphone-0002.wav"]
        )
        XCTAssertLessThanOrEqual(
            microphoneFiles[0].captureStartOffset,
            microphoneFiles[1].captureStartOffset
        )
    }

    func testInputOnlyChangeDoesNotRestartSystemAudio() async throws {
        let microphone = FakeMicrophoneRecorder()
        let systemAudio = FakeSystemAudioRecorder()
        let service = DualAudioCaptureService(
            microphoneRecorder: microphone,
            systemAudioRecorders: [systemAudio],
            routeMonitor: FakeRouteMonitor()
        )
        let directory = temporaryDirectory()
        _ = try await service.start(session: session(directory: directory))

        await service.handleRouteChangeForTesting(
            from: route(input: "input-1", output: "output-1"),
            to: route(input: "input-2", output: "output-1")
        )
        _ = try await service.stop()

        XCTAssertEqual(microphone.startCount, 2)
        XCTAssertEqual(systemAudio.startCount, 1)
    }

    func testOutputOnlyChangeDoesNotRestartMicrophone() async throws {
        let microphone = FakeMicrophoneRecorder()
        let systemAudio = FakeSystemAudioRecorder()
        let service = DualAudioCaptureService(
            microphoneRecorder: microphone,
            systemAudioRecorders: [systemAudio],
            routeMonitor: FakeRouteMonitor()
        )
        let directory = temporaryDirectory()
        _ = try await service.start(session: session(directory: directory))

        await service.handleRouteChangeForTesting(
            from: route(input: "input-1", output: "output-1"),
            to: route(input: "input-1", output: "output-2")
        )
        _ = try await service.stop()

        XCTAssertEqual(microphone.startCount, 1)
        XCTAssertEqual(systemAudio.startCount, 2)
    }

    func testReconnectFailurePreservesUnaffectedSource() async throws {
        let microphone = FakeMicrophoneRecorder(failStartingAt: 2)
        let systemAudio = FakeSystemAudioRecorder()
        let service = DualAudioCaptureService(
            microphoneRecorder: microphone,
            systemAudioRecorders: [systemAudio],
            routeMonitor: FakeRouteMonitor()
        )
        let directory = temporaryDirectory()
        _ = try await service.start(session: session(directory: directory))

        await service.handleRouteChangeForTesting(
            from: route(input: "input-1", output: "output-1"),
            to: route(input: "input-2", output: "output-1")
        )
        let result = try await service.stop()

        XCTAssertEqual(systemAudio.startCount, 1)
        XCTAssertTrue(result.files.contains { $0.source == .systemAudio })
        XCTAssertTrue(result.diagnostics.contains { $0.contains("Microphone did not reconnect") })
    }

    func testStopDuringReconnectCancelsRestartAndFinalizesOnce() async throws {
        let microphone = FakeMicrophoneRecorder(delayOnStartNumber: 2)
        let systemAudio = FakeSystemAudioRecorder()
        let monitor = FakeRouteMonitor()
        let service = DualAudioCaptureService(
            microphoneRecorder: microphone,
            systemAudioRecorders: [systemAudio],
            routeMonitor: monitor
        )
        let directory = temporaryDirectory()
        _ = try await service.start(session: session(directory: directory))

        monitor.emit(
            from: route(input: "input-1", output: "output-1"),
            to: route(input: "input-2", output: "output-1")
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        let result = try await service.stop()

        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertEqual(systemAudio.stopCount, 1)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(result.files.isEmpty)
    }

    func testTemporaryNoDeviceKeepsUnaffectedStreamAndLaterRecovers() async throws {
        let microphone = FakeMicrophoneRecorder()
        let systemAudio = FakeSystemAudioRecorder()
        let service = DualAudioCaptureService(
            microphoneRecorder: microphone,
            systemAudioRecorders: [systemAudio],
            routeMonitor: FakeRouteMonitor()
        )
        let directory = temporaryDirectory()
        _ = try await service.start(session: session(directory: directory))

        let initial = route(input: "built-in-input", output: "built-in-output")
        let missingInput = route(input: nil, output: "built-in-output")
        await service.handleRouteChangeForTesting(from: initial, to: missingInput)
        await service.handleRouteChangeForTesting(
            from: missingInput,
            to: route(input: "airpods-input", output: "built-in-output")
        )
        let result = try await service.stop()

        XCTAssertEqual(microphone.startCount, 2)
        XCTAssertEqual(systemAudio.startCount, 1)
        XCTAssertTrue(result.diagnostics.contains { $0.contains("No microphone") })
        XCTAssertEqual(result.files.filter { $0.source == .microphone }.count, 2)
    }

    func testDuplicateRouteNotificationsDoNotRestartEitherSource() async throws {
        let microphone = FakeMicrophoneRecorder()
        let systemAudio = FakeSystemAudioRecorder()
        let service = DualAudioCaptureService(
            microphoneRecorder: microphone,
            systemAudioRecorders: [systemAudio],
            routeMonitor: FakeRouteMonitor()
        )
        let directory = temporaryDirectory()
        _ = try await service.start(session: session(directory: directory))

        let unchanged = route(input: "airpods-input", output: "airpods-output")
        for _ in 0..<5 {
            await service.handleRouteChangeForTesting(from: unchanged, to: unchanged)
        }
        _ = try await service.stop()

        XCTAssertEqual(microphone.startCount, 1)
        XCTAssertEqual(systemAudio.startCount, 1)
    }

    func testRepeatedBuiltInAirPodsAndWiredTransitionsUseUniqueFiles() async throws {
        let microphone = FakeMicrophoneRecorder()
        let systemAudio = FakeSystemAudioRecorder()
        let service = DualAudioCaptureService(
            microphoneRecorder: microphone,
            systemAudioRecorders: [systemAudio],
            routeMonitor: FakeRouteMonitor()
        )
        let directory = temporaryDirectory()
        _ = try await service.start(session: session(directory: directory))

        let builtIn = route(input: "built-in-input", output: "built-in-output")
        let airPods = route(input: "airpods-input", output: "airpods-output")
        let wired = route(input: "wired-input", output: "wired-output")
        await service.handleRouteChangeForTesting(from: builtIn, to: airPods)
        await service.handleRouteChangeForTesting(from: airPods, to: wired)
        await service.handleRouteChangeForTesting(from: wired, to: builtIn)
        let result = try await service.stop()

        let names = result.files.map { $0.url.lastPathComponent }
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(microphone.startCount, 4)
        XCTAssertEqual(systemAudio.startCount, 4)
        XCTAssertEqual(result.files.count, 8)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoScribeHotSwapTests")
            .appendingPathComponent(UUID().uuidString)
    }

    private func session(directory: URL) -> RecordingSession {
        RecordingSession(
            startedAt: Date().addingTimeInterval(-1),
            processingMode: .local,
            outputDirectory: directory,
            temporaryDirectory: directory
        )
    }

    private func route(input: String?, output: String?) -> AudioRouteInspector.Route {
        AudioRouteInspector.Route(
            input: input.map {
                AudioRouteInspector.Device(
                    id: 1,
                    uid: $0,
                    name: $0,
                    transportType: $0.contains("airpods")
                        ? kAudioDeviceTransportTypeBluetooth
                        : kAudioDeviceTransportTypeBuiltIn
                )
            },
            output: output.map {
                AudioRouteInspector.Device(
                    id: 2,
                    uid: $0,
                    name: $0,
                    transportType: $0.contains("airpods")
                        ? kAudioDeviceTransportTypeBluetooth
                        : kAudioDeviceTransportTypeBuiltIn
                )
            }
        )
    }
}

private final class FakeRouteMonitor: AudioRouteChangeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: AudioRouteChangeMonitor.Handler?

    var isRunning: Bool {
        lock.withLock { handler != nil }
    }

    func start(handler: @escaping AudioRouteChangeMonitor.Handler) {
        lock.withLock {
            self.handler = handler
        }
    }

    func stop() {
        lock.withLock {
            handler = nil
        }
    }

    func emit(
        from previous: AudioRouteInspector.Route,
        to current: AudioRouteInspector.Route
    ) {
        lock.withLock { handler }?(previous, current)
    }
}

private final class FakeMicrophoneRecorder: MicrophoneRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var activeURL: URL?
    private var starts = 0
    private var stops = 0
    private let failStartingAt: Int?
    private let delayOnStartNumber: Int?

    var onAudioLevel: ((Float) -> Void)?
    var onInterruption: (@Sendable (String) -> Void)?

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    init(failStartingAt: Int? = nil, delayOnStartNumber: Int? = nil) {
        self.failStartingAt = failStartingAt
        self.delayOnStartNumber = delayOnStartNumber
    }

    func start(
        in directory: URL,
        filename: String,
        deviceUID: String?,
        deviceName: String?
    ) async throws -> URL {
        let number = lock.withLock { () -> Int in
            starts += 1
            return starts
        }
        if number == delayOnStartNumber {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if let failStartingAt, number >= failStartingAt {
            throw AudioCaptureError.unsupportedInputRoute("simulated reconnect failure")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try Data([0]).write(to: url)
        lock.withLock { activeURL = url }
        return url
    }

    func waitForFirstBuffer(timeoutSeconds: TimeInterval) async -> Bool {
        true
    }

    func stop() async throws -> URL {
        try lock.withLock {
            guard let url = activeURL else { throw AudioCaptureError.notRecording }
            activeURL = nil
            stops += 1
            return url
        }
    }
}

private final class FakeSystemAudioRecorder: SystemAudioRecording, @unchecked Sendable {
    let backendName = "Fake System Audio"
    var diagnosticSummary: String? { nil }
    var onAudioLevel: ((Float) -> Void)?

    private let lock = NSLock()
    private var activeURL: URL?
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func start(in directory: URL, filename: String) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try Data([0]).write(to: url)
        lock.withLock {
            starts += 1
            activeURL = url
        }
        return url
    }

    func stop() async throws -> URL {
        try lock.withLock {
            guard let url = activeURL else { throw AudioCaptureError.notRecording }
            activeURL = nil
            stops += 1
            return url
        }
    }
}

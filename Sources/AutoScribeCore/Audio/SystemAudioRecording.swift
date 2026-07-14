import Foundation

public protocol SystemAudioRecording: AnyObject, Sendable {
    var backendName: String { get }
    var diagnosticSummary: String? { get }
    var onAudioLevel: ((Float) -> Void)? { get set }

    func start(in directory: URL, filename: String) async throws -> URL
    func stop() async throws -> URL
}

public extension SystemAudioRecording {
    var diagnosticSummary: String? {
        nil
    }

    func start(in directory: URL) async throws -> URL {
        try await start(in: directory, filename: "system-audio.wav")
    }
}

public enum SystemAudioBackend: String, CaseIterable, Sendable {
    case coreAudioTap = "Core Audio Tap"
    case screenCaptureKit = "ScreenCaptureKit"
}

public enum SystemAudioRecorderFactory {
    public static func makePreferredRecorders() -> [SystemAudioRecording] {
        var recorders: [SystemAudioRecording] = []

        if #available(macOS 14.2, *) {
            recorders.append(CoreAudioTapSystemAudioRecorder())
        }

        if #available(macOS 13.0, *) {
            recorders.append(SystemAudioRecorder())
        }

        return recorders
    }

    public static var preferredBackendNames: [String] {
        var names: [String] = []

        if #available(macOS 14.2, *) {
            names.append(SystemAudioBackend.coreAudioTap.rawValue)
        }

        if #available(macOS 13.0, *) {
            names.append(SystemAudioBackend.screenCaptureKit.rawValue)
        }

        return names
    }
}

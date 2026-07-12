import Foundation

public enum AppState: Equatable, Sendable {
    case idle
    case recording(RecordingSession)
    case processing(RecordingSession)
    case complete(URL)
    case failed(String)

    public var title: String {
        switch self {
        case .idle:
            "Idle"
        case .recording:
            "Recording"
        case .processing:
            "Processing"
        case .complete:
            "Complete"
        case .failed:
            "Error"
        }
    }

    public var menuBarSymbolName: String {
        switch self {
        case .idle:
            "mic"
        case .recording:
            "record.circle.fill"
        case .processing:
            "waveform"
        case .complete:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    public var isRecording: Bool {
        if case .recording = self {
            return true
        }
        return false
    }

    public var isProcessing: Bool {
        if case .processing = self {
            return true
        }
        return false
    }
}

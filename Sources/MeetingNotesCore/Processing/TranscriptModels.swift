import Foundation

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let speaker: String
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?
    public let text: String

    public init(
        speaker: String = "Speaker",
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        text: String
    ) {
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public let segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
    }

    public var plainText: String {
        segments.map { segment in
            if let startTime = segment.startTime {
                return "[\(Self.timestamp(startTime))] \(segment.speaker): \(segment.text)"
            }
            return "\(segment.speaker): \(segment.text)"
        }
        .joined(separator: "\n")
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

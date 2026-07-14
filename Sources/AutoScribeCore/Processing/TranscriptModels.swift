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

    /// A cleaned, label-free version of the transcript for use in LLM prompts.
    ///
    /// Removes speaker labels and WhisperKit artifacts (e.g. `>>`) that
    /// confuse small models into copying the transcript instead of summarizing.
    public var textForSummarization: String {
        let whisperArtifacts = [">> ", ">>"]
        return segments
            .map { segment in
                var text = segment.text
                for artifact in whisperArtifacts {
                    text = text.replacingOccurrences(of: artifact, with: "")
                }
                // Strip "[silence]" and similar Whisper filler tokens
                text = text.replacingOccurrences(of: "[silence]", with: "", options: .caseInsensitive)
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
    public let title: String
    public let keyPoints: [String]
    public let decisions: [String]
    public let actionItems: [String]
    public let followUps: [String]

    public init(
        title: String,
        keyPoints: [String],
        decisions: [String],
        actionItems: [String],
        followUps: [String]
    ) {
        self.title = title
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.followUps = followUps
    }
}

public struct ProcessingResult: Equatable, Sendable {
    public let transcript: Transcript
    public let summary: MeetingSummary

    public init(transcript: Transcript, summary: MeetingSummary) {
        self.transcript = transcript
        self.summary = summary
    }
}

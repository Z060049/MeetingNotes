@testable import MeetingNotesCore
import XCTest

final class GroqTranscriptionResponseTests: XCTestCase {
    func testVerboseJSONSegmentsUseCaptureAndTrimOffsets() throws {
        let response = Data("""
        {
          "text": "First segment. Second segment.",
          "segments": [
            {"start": 0.5, "end": 1.75, "text": " First segment. "},
            {"start": 2.0, "end": 3.25, "text": "Second segment."}
          ]
        }
        """.utf8)

        let segments = try GroqProcessingProvider.decodeTranscriptionSegments(
            from: response,
            source: .microphone,
            timelineOffset: 42.3
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speaker, AudioSource.microphone.rawValue)
        XCTAssertEqual(segments[0].startTime ?? 0, 42.8, accuracy: 0.0001)
        XCTAssertEqual(segments[0].endTime ?? 0, 44.05, accuracy: 0.0001)
        XCTAssertEqual(segments[0].text, "First segment.")
        XCTAssertEqual(segments[1].startTime ?? 0, 44.3, accuracy: 0.0001)
        XCTAssertEqual(segments[1].endTime ?? 0, 45.55, accuracy: 0.0001)
    }

    func testVerboseJSONWithoutSegmentsFallsBackToUntimestampedText() throws {
        let response = Data("""
        {"text": "Fallback transcription."}
        """.utf8)

        let segments = try GroqProcessingProvider.decodeTranscriptionSegments(
            from: response,
            source: .systemAudio,
            timelineOffset: 12
        )

        XCTAssertEqual(segments, [
            TranscriptSegment(
                speaker: AudioSource.systemAudio.rawValue,
                text: "Fallback transcription."
            )
        ])
    }

    func testEachRouteSegmentUsesItsOwnSourceAndTimelineOffset() throws {
        let response = Data("""
        {
          "text": "Route segment.",
          "segments": [
            {"start": 1.0, "end": 2.0, "text": "Route segment."}
          ]
        }
        """.utf8)

        let microphone = try GroqProcessingProvider.decodeTranscriptionSegments(
            from: response,
            source: .microphone,
            timelineOffset: 10
        )
        let systemAudio = try GroqProcessingProvider.decodeTranscriptionSegments(
            from: response,
            source: .systemAudio,
            timelineOffset: 75
        )

        XCTAssertEqual(microphone.first?.speaker, AudioSource.microphone.rawValue)
        XCTAssertEqual(microphone.first?.startTime, 11)
        XCTAssertEqual(systemAudio.first?.speaker, AudioSource.systemAudio.rawValue)
        XCTAssertEqual(systemAudio.first?.startTime, 76)
    }

    func testChatCompletionExtractsMessageContent() throws {
        let response = Data("""
        {"choices":[{"message":{"role":"assistant","content":"Meeting summary JSON"}}]}
        """.utf8)

        XCTAssertEqual(
            try GroqProcessingProvider.decodeChatCompletionText(from: response),
            "Meeting summary JSON"
        )
    }
}

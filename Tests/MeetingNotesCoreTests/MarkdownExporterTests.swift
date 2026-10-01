import MeetingNotesCore
import XCTest

final class MarkdownExporterTests: XCTestCase {
    func testRawTranscriptIncludesMetadataAndBothAudioSources() {
        let session = makeSession(audioSources: [.microphone, .systemAudio])
        let transcript = Transcript(segments: [
            TranscriptSegment(speaker: "Microphone", startTime: 0, text: "Hello"),
            TranscriptSegment(speaker: "System Audio", startTime: 2, text: "Hi there")
        ])

        let document = MarkdownExporter().renderRawTranscription(
            transcript: transcript,
            shortTitle: "recording",
            session: session
        )

        XCTAssertTrue(document.filename.hasSuffix("_recording_transcript.md"))
        XCTAssertTrue(document.contents.contains("processing_mode: API"))
        XCTAssertTrue(document.contents.contains("audio_sources: Microphone, System Audio"))
        XCTAssertTrue(document.contents.contains("# recording (Raw Transcript)"))
        XCTAssertTrue(document.contents.contains("[00:00] Hello"))
        XCTAssertTrue(document.contents.contains("[00:02] Hi there"))
        XCTAssertFalse(document.contents.contains("## Summary"))
        XCTAssertFalse(document.contents.contains("## Action Items"))
    }

    func testRawTranscriptShowsNotCapturedForMissingSystemAudio() {
        let session = makeSession(audioSources: [.microphone])
        let transcript = Transcript(segments: [
            TranscriptSegment(speaker: "Microphone", text: "Only the microphone was captured.")
        ])

        let document = MarkdownExporter().renderRawTranscription(
            transcript: transcript,
            shortTitle: "recording",
            session: session
        )

        XCTAssertTrue(document.contents.contains("Only the microphone was captured."))
        XCTAssertTrue(document.contents.contains("### System Audio"))
        XCTAssertTrue(document.contents.contains("Not captured for this recording."))
    }

    func testRawTranscriptSanitizesFilenameTitle() {
        let document = MarkdownExporter().renderRawTranscription(
            transcript: Transcript(segments: []),
            shortTitle: "Recording: Q&A",
            session: makeSession(audioSources: [])
        )

        XCTAssertTrue(document.filename.hasSuffix("_recording--q-a_transcript.md"))
    }

    private func makeSession(audioSources: Set<AudioSource>) -> RecordingSession {
        RecordingSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            audioSources: audioSources,
            processingMode: .api,
            outputDirectory: URL(fileURLWithPath: "/tmp/meetingnotes"),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/meetingnotes-temp")
        )
    }
}

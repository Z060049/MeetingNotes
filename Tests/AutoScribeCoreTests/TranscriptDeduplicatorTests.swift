import AutoScribeCore
import XCTest

final class TranscriptDeduplicatorTests: XCTestCase {
    private func micText(in transcript: Transcript) -> String? {
        transcript.segments.first { $0.speaker == AudioSource.microphone.rawValue }?.text
    }

    func testRemovesNearIdenticalMicrophoneSentence() {
        let transcript = Transcript(segments: [
            TranscriptSegment(
                speaker: AudioSource.microphone.rawValue,
                text: "Let's talk about the roadmap. The idea is good, we can make it go viral."
            ),
            TranscriptSegment(
                speaker: AudioSource.systemAudio.rawValue,
                text: "The idea is good, we can make it go viral!"
            )
        ])

        let result = TranscriptDeduplicator.deduplicate(transcript)

        let mic = micText(in: result)
        XCTAssertNotNil(mic)
        XCTAssertTrue(mic!.contains("Let's talk about the roadmap"))
        XCTAssertFalse(mic!.lowercased().contains("go viral"))
    }

    func testKeepsDistinctMicrophoneSentences() {
        let transcript = Transcript(segments: [
            TranscriptSegment(
                speaker: AudioSource.microphone.rawValue,
                text: "What do you think about the budget? I have my own opinion here."
            ),
            TranscriptSegment(
                speaker: AudioSource.systemAudio.rawValue,
                text: "The weather today is completely unrelated to anything."
            )
        ])

        let result = TranscriptDeduplicator.deduplicate(transcript)

        let mic = micText(in: result)
        XCTAssertEqual(mic, "What do you think about the budget? I have my own opinion here.")
    }

    func testMicrophoneOnlyTranscriptIsUnchanged() {
        let transcript = Transcript(segments: [
            TranscriptSegment(
                speaker: AudioSource.microphone.rawValue,
                text: "This is the only stream we captured today."
            )
        ])

        let result = TranscriptDeduplicator.deduplicate(transcript)

        XCTAssertEqual(result, transcript)
    }

    func testCollapsesRepeatedHallucinatedSentences() {
        let transcript = Transcript(segments: [
            TranscriptSegment(
                speaker: AudioSource.systemAudio.rawValue,
                text: "This is a test. This is a test. This is a test. This is a test. Real content here."
            )
        ])

        let result = TranscriptDeduplicator.collapseRepeatedSentences(transcript)

        let text = result.segments.first?.text ?? ""
        let occurrences = text.components(separatedBy: "This is a test.").count - 1
        XCTAssertEqual(occurrences, 1)
        XCTAssertTrue(text.contains("Real content here."))
    }

    func testCollapsePreservesNonConsecutiveRepeats() {
        let transcript = Transcript(segments: [
            TranscriptSegment(
                speaker: AudioSource.systemAudio.rawValue,
                text: "Yes. No. Yes."
            )
        ])

        let result = TranscriptDeduplicator.collapseRepeatedSentences(transcript)

        let text = result.segments.first?.text ?? ""
        XCTAssertEqual(text.components(separatedBy: "Yes.").count - 1, 2)
        XCTAssertTrue(text.contains("No."))
    }

    func testRemovesMicSentenceThatSpansTwoSystemAudioSentences() {
        // Whisper sometimes joins what system audio splits into two sentences.
        // The mic captures "A. B." as one sentence "A, B." which fails
        // per-sentence similarity but should be caught by bigram coverage.
        let transcript = Transcript(segments: [
            TranscriptSegment(
                speaker: AudioSource.microphone.rawValue,
                text: "The first version is single player mode because we haven't collected many transcripts yet, but as we collect more we can tell you how your patterns compare to other builders out there. Something only I said."
            ),
            TranscriptSegment(
                speaker: AudioSource.systemAudio.rawValue,
                text: "The first version is single player mode because we haven't collected many transcripts yet. But as we collect more we can tell you how your patterns compare to other builders out there."
            )
        ])

        let result = TranscriptDeduplicator.deduplicate(transcript)

        let mic = micText(in: result)
        XCTAssertNotNil(mic)
        XCTAssertTrue(mic!.contains("Something only I said"), "unique mic content should be kept")
        XCTAssertFalse(mic!.contains("single player mode"), "speaker bleed spanning two sys-audio sentences should be removed")
    }

    // MARK: - Timestamp-aware deduplication

    func testTimestampAwareRemovesEchoWithMatchingTimeAndText() {
        // Mic picks up the speaker echo ~2 seconds after system audio.
        // Text is nearly identical; timing confirms it is speaker bleed.
        let transcript = Transcript(segments: [
            TranscriptSegment(
                speaker: AudioSource.systemAudio.rawValue,
                startTime: 10.0,
                text: "The feature ships next Friday."
            ),
            TranscriptSegment(
                speaker: AudioSource.microphone.rawValue,
                startTime: 11.5,
                text: "The feature ships next Friday."
            ),
            TranscriptSegment(
                speaker: AudioSource.microphone.rawValue,
                startTime: 14.0,
                text: "Sounds good, I will update the board."
            )
        ])

        let result = TranscriptDeduplicator.deduplicate(transcript)

        let micTexts = result.segments
            .filter { $0.speaker == AudioSource.microphone.rawValue }
            .map(\.text)

        XCTAssertFalse(micTexts.contains("The feature ships next Friday."),
                       "echo within the time window should be removed")
        XCTAssertTrue(micTexts.contains("Sounds good, I will update the board."),
                      "genuine mic speech outside the window should be kept")
    }

    func testTimestampAwareKeepsMicSegmentWhenNoNearbySystemAudio() {
        // The mic has speech at t=30 but system audio only has content near t=5.
        // Even though the texts happen to be similar, timing rules it out as echo.
        let transcript = Transcript(segments: [
            TranscriptSegment(
                speaker: AudioSource.systemAudio.rawValue,
                startTime: 5.0,
                text: "Let's wrap up the meeting."
            ),
            TranscriptSegment(
                speaker: AudioSource.microphone.rawValue,
                startTime: 30.0,   // far outside echoWindow
                text: "Let's wrap up the meeting."
            )
        ])

        let result = TranscriptDeduplicator.deduplicate(transcript)

        let mic = result.segments.first { $0.speaker == AudioSource.microphone.rawValue }
        XCTAssertNotNil(mic, "mic segment far from any system-audio activity should be kept")
        XCTAssertEqual(mic?.text, "Let's wrap up the meeting.")
    }

    func testTimestampAwareKeepsMicSegmentWithDifferentTextNearSystemAudio() {
        // Mic and system audio overlap in time, but the user is saying something
        // different — not an echo.
        let transcript = Transcript(segments: [
            TranscriptSegment(
                speaker: AudioSource.systemAudio.rawValue,
                startTime: 8.0,
                text: "We need to finish the prototype this week."
            ),
            TranscriptSegment(
                speaker: AudioSource.microphone.rawValue,
                startTime: 8.5,
                text: "I completely disagree with that timeline."
            )
        ])

        let result = TranscriptDeduplicator.deduplicate(transcript)

        let mic = result.segments.first { $0.speaker == AudioSource.microphone.rawValue }
        XCTAssertNotNil(mic, "mic segment with different content should be kept even when timing overlaps")
        XCTAssertEqual(mic?.text, "I completely disagree with that timeline.")
    }

    func testCollapseHandlesConsecutiveIdenticalFineGrainedSegments() {
        // WhisperKit sometimes emits the same hallucinated phrase as several
        // consecutive fine-grained segments.
        let transcript = Transcript(segments: [
            TranscriptSegment(speaker: AudioSource.systemAudio.rawValue, startTime: 0.0, text: "This is a test."),
            TranscriptSegment(speaker: AudioSource.systemAudio.rawValue, startTime: 1.0, text: "This is a test."),
            TranscriptSegment(speaker: AudioSource.systemAudio.rawValue, startTime: 2.0, text: "This is a test."),
            TranscriptSegment(speaker: AudioSource.systemAudio.rawValue, startTime: 3.0, text: "Real content here.")
        ])

        let result = TranscriptDeduplicator.collapseRepeatedSentences(transcript)

        let texts = result.segments.map(\.text)
        XCTAssertEqual(texts.filter { $0 == "This is a test." }.count, 1,
                       "consecutive identical fine-grained segments should collapse to one")
        XCTAssertTrue(texts.contains("Real content here."))
    }

    func testCollapsePreservesNonConsecutiveFineGrainedSegments() {
        // Non-consecutive repeats (a different segment from the same speaker in
        // between) must not be collapsed.
        let transcript = Transcript(segments: [
            TranscriptSegment(speaker: AudioSource.systemAudio.rawValue, startTime: 0.0, text: "Yes."),
            TranscriptSegment(speaker: AudioSource.systemAudio.rawValue, startTime: 1.0, text: "No."),
            TranscriptSegment(speaker: AudioSource.systemAudio.rawValue, startTime: 2.0, text: "Yes.")
        ])

        let result = TranscriptDeduplicator.collapseRepeatedSentences(transcript)

        let texts = result.segments.map(\.text)
        XCTAssertEqual(texts.filter { $0 == "Yes." }.count, 2,
                       "non-consecutive identical segments should be preserved")
        XCTAssertTrue(texts.contains("No."))
    }

    // MARK: - Text-only deduplication (existing behaviour, no timestamps)

    func testFullyDuplicatedMicrophoneSegmentIsDropped() {
        let transcript = Transcript(segments: [
            TranscriptSegment(
                speaker: AudioSource.microphone.rawValue,
                text: "Go viral if the idea is good. Just add story and a twist."
            ),
            TranscriptSegment(
                speaker: AudioSource.systemAudio.rawValue,
                text: "Go viral if the idea is good. Just add story and a twist."
            )
        ])

        let result = TranscriptDeduplicator.deduplicate(transcript)

        XCTAssertNil(micText(in: result))
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.speaker, AudioSource.systemAudio.rawValue)
    }
}

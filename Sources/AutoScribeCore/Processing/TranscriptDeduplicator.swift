import Foundation

/// Removes microphone sentences that echo the system-audio transcript.
///
/// When a user records with speakers, the speaker output bleeds into the
/// microphone, producing near-identical sentences in both streams. This keeps
/// the system-audio transcript as the source of truth and drops the duplicated
/// sentences from the microphone transcript.
///
/// ## Deduplication strategy
///
/// **Timestamp-aware path** (local / WhisperKit processing):
/// WhisperKit emits one `TranscriptSegment` per sub-segment, each with a
/// `startTime`.  Because the microphone echo of a speaker's voice arrives within
/// a few seconds of the original system-audio capture, we treat two segments as
/// an echo when both of these conditions hold:
///   1. Their `startTime` values are within `echoWindow` seconds of each other.
///   2. Their normalised texts have a similarity ≥ `timestampedThreshold`
///      (relaxed relative to the text-only threshold because the timing evidence
///      is already strong).
/// A mic segment with *no* system-audio segment nearby in time is guaranteed to
/// be genuine speech and is kept unconditionally.
///
/// **Text-only path** (API / OpenAI Whisper, no timestamps):
/// Falls back to the original sentence-level Jaccard + Levenshtein + bigram
/// coverage approach when no timing data is present.
public enum TranscriptDeduplicator {
    public struct DeduplicationReport: Equatable, Sendable {
        public let microphoneSentencesBefore: Int
        public let microphoneSentencesAfter: Int
        public let removedBySimilarity: Int
        public let removedByCoverage: Int

        public var removedSentenceCount: Int {
            microphoneSentencesBefore - microphoneSentencesAfter
        }
    }

    public struct DeduplicationResult: Equatable, Sendable {
        public let transcript: Transcript
        public let report: DeduplicationReport
    }

    public static let defaultThreshold: Double = 0.82

    /// Maximum seconds between a system-audio segment and its microphone echo.
    /// Acoustic delay from speaker to mic is typically < 500 ms; we use a
    /// generous window to absorb Whisper chunking jitter.
    public static let echoWindow: TimeInterval = 5.0

    // MARK: - Public API

    public static func deduplicate(_ transcript: Transcript, threshold: Double = defaultThreshold) -> Transcript {
        deduplicateWithReport(transcript, threshold: threshold).transcript
    }

    public static func deduplicateWithReport(
        _ transcript: Transcript,
        threshold: Double = defaultThreshold
    ) -> DeduplicationResult {
        let systemSegments = transcript.segments.filter { $0.speaker == AudioSource.systemAudio.rawValue }
        let beforeCount = microphoneSentenceCount(in: transcript)
        guard !systemSegments.isEmpty else {
            return DeduplicationResult(
                transcript: transcript,
                report: DeduplicationReport(
                    microphoneSentencesBefore: beforeCount,
                    microphoneSentencesAfter: beforeCount,
                    removedBySimilarity: 0,
                    removedByCoverage: 0
                )
            )
        }

        let deduplicated: (transcript: Transcript, similarity: Int, coverage: Int)
        if systemSegments.contains(where: { $0.startTime != nil }) {
            deduplicated = deduplicateTimestamped(
                transcript,
                systemSegments: systemSegments,
                threshold: threshold
            )
        } else {
            deduplicated = deduplicateTextOnly(
                transcript,
                systemSegments: systemSegments,
                threshold: threshold
            )
        }

        return DeduplicationResult(
            transcript: deduplicated.transcript,
            report: DeduplicationReport(
                microphoneSentencesBefore: beforeCount,
                microphoneSentencesAfter: microphoneSentenceCount(in: deduplicated.transcript),
                removedBySimilarity: deduplicated.similarity,
                removedByCoverage: deduplicated.coverage
            )
        )
    }

    /// Collapses runs of consecutive identical sentences within each segment
    /// (e.g. a Whisper hallucination of "This is a test." repeated many times).
    /// Non-consecutive legitimate repeats are preserved.
    ///
    /// Also handles fine-grained WhisperKit output where each hallucinated phrase
    /// arrives as a separate `TranscriptSegment`: consecutive segments from the
    /// same speaker with identical text are collapsed to one.
    public static func collapseRepeatedSentences(_ transcript: Transcript) -> Transcript {
        var result: [TranscriptSegment] = []

        for segment in transcript.segments {
            // Within-segment: collapse consecutive identical sentences
            let originalSentences = sentences(in: segment.text)
            guard !originalSentences.isEmpty else {
                result.append(segment)
                continue
            }

            var kept: [String] = []
            var previousNormalized: String?
            for sentence in originalSentences {
                let normalized = normalize(sentence)
                if let previousNormalized, normalized == previousNormalized, !normalized.isEmpty {
                    continue
                }
                kept.append(sentence)
                previousNormalized = normalized
            }

            let rejoined = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rejoined.isEmpty else { continue }

            let collapsed = TranscriptSegment(
                speaker: segment.speaker,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: rejoined
            )

            // Cross-segment: drop if the immediately preceding output segment from
            // the same speaker is identical (catches fine-grained hallucination runs).
            if let prev = result.last,
               prev.speaker == collapsed.speaker,
               normalize(prev.text) == normalize(collapsed.text),
               !normalize(collapsed.text).isEmpty {
                continue
            }

            result.append(collapsed)
        }

        return Transcript(segments: result)
    }

    // MARK: - Timestamp-aware path

    private static func deduplicateTimestamped(
        _ transcript: Transcript,
        systemSegments: [TranscriptSegment],
        threshold: Double
    ) -> (transcript: Transcript, similarity: Int, coverage: Int) {
        // When timestamp proximity corroborates an echo we accept a slightly lower
        // text-similarity bar — the timing evidence compensates.
        let timestampedThreshold = max(threshold - 0.15, 0.60)

        // Pre-build text-only structures for any mic segments that lack a timestamp.
        let referenceSentences = systemSegments
            .flatMap { sentences(in: $0.text) }
            .map { normalize($0) }
            .filter { !$0.isEmpty }
        let referenceBigrams = Set(bigrams(of: referenceSentences.joined(separator: " ")))

        var result: [TranscriptSegment] = []
        var removedBySimilarity = 0
        var removedByCoverage = 0

        for segment in transcript.segments {
            guard segment.speaker == AudioSource.microphone.rawValue else {
                result.append(segment)
                continue
            }

            let normalizedMic = normalize(segment.text)
            guard !normalizedMic.isEmpty else { continue }

            if segment.startTime != nil {
                // Compare against the combined nearby window rather than requiring
                // Whisper to split microphone and system audio at identical points.
                let nearbySystemSegments = systemSegments.filter { sys in
                    guard sys.startTime != nil else { return false }
                    return intervalsAreNearby(segment, sys, window: echoWindow)
                }

                if nearbySystemSegments.isEmpty {
                    // No system-audio activity near this timestamp → genuine mic content.
                    result.append(segment)
                    continue
                }

                let nearbySentences = nearbySystemSegments
                    .flatMap { sentences(in: $0.text) }
                    .map { normalize($0) }
                    .filter { !$0.isEmpty }
                let nearbyText = nearbySystemSegments
                    .map { normalize($0.text) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let nearbyBigrams = Set(bigrams(of: nearbyText))

                var keptSentences: [String] = []
                for sentence in sentences(in: segment.text) {
                    let normalized = normalize(sentence)
                    guard !normalized.isEmpty else { continue }

                    switch timestampedEchoReason(
                        microphoneText: normalized,
                        nearbySystemSentences: nearbySentences,
                        nearbySystemText: nearbyText,
                        nearbySystemBigrams: nearbyBigrams,
                        threshold: timestampedThreshold
                    ) {
                    case .similarity:
                        removedBySimilarity += 1
                    case .coverage:
                        removedByCoverage += 1
                    case nil:
                        keptSentences.append(sentence)
                    }
                }

                let rejoined = keptSentences
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rejoined.isEmpty {
                    result.append(TranscriptSegment(
                        speaker: segment.speaker,
                        startTime: segment.startTime,
                        endTime: segment.endTime,
                        text: rejoined
                    ))
                }

            } else {
                // Mic segment has no timestamp (unusual in the timestamped path but
                // possible for error segments): use text-only check as a safety net.
                let matchesSentence = referenceSentences.contains { similarity(normalizedMic, $0) >= threshold }
                let coversBigrams = bigramCoverage(of: normalizedMic, in: referenceBigrams) >= 0.60
                if matchesSentence {
                    removedBySimilarity += sentences(in: segment.text).count
                } else if coversBigrams {
                    removedByCoverage += sentences(in: segment.text).count
                } else {
                    result.append(segment)
                }
            }
        }

        return (Transcript(segments: result), removedBySimilarity, removedByCoverage)
    }

    // MARK: - Text-only path (API / no timestamps)

    private static func deduplicateTextOnly(
        _ transcript: Transcript,
        systemSegments: [TranscriptSegment],
        threshold: Double
    ) -> (transcript: Transcript, similarity: Int, coverage: Int) {
        let referenceSentences = systemSegments
            .flatMap { sentences(in: $0.text) }
            .map { normalize($0) }
            .filter { !$0.isEmpty }

        // Build a bigram set from the entire system audio text so we can catch
        // speaker bleed that spans multiple system-audio sentence boundaries.
        // The per-sentence similarity check misses cases where Whisper merged
        // two consecutive system-audio sentences into one long mic sentence.
        let fullReferenceText = referenceSentences.joined(separator: " ")
        let referenceBigrams = Set(bigrams(of: fullReferenceText))

        var result: [TranscriptSegment] = []
        var removedBySimilarity = 0
        var removedByCoverage = 0

        for segment in transcript.segments {
            guard segment.speaker == AudioSource.microphone.rawValue else {
                result.append(segment)
                continue
            }

            let originalSentences = sentences(in: segment.text)
            let keptSentences = originalSentences.filter { sentence in
                let normalized = normalize(sentence)
                if normalized.isEmpty { return false }
                let matchesSentence = referenceSentences.contains { similarity(normalized, $0) >= threshold }
                if matchesSentence {
                    removedBySimilarity += 1
                    return false
                }

                // Secondary check: if most of this sentence's bigrams appear
                // anywhere in the system audio, it is speaker bleed even if no
                // single reference sentence matched it closely enough.
                if bigramCoverage(of: normalized, in: referenceBigrams) >= 0.60 {
                    removedByCoverage += 1
                    return false
                }
                return true
            }

            let rejoined = keptSentences.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rejoined.isEmpty else { continue }

            result.append(TranscriptSegment(
                speaker: segment.speaker,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: rejoined
            ))
        }

        return (Transcript(segments: result), removedBySimilarity, removedByCoverage)
    }

    // MARK: - Text helpers

    private enum EchoReason {
        case similarity
        case coverage
    }

    private static func timestampedEchoReason(
        microphoneText: String,
        nearbySystemSentences: [String],
        nearbySystemText: String,
        nearbySystemBigrams: Set<String>,
        threshold: Double
    ) -> EchoReason? {
        let wordCount = microphoneText.split(separator: " ").count
        guard wordCount >= 3 else {
            // One- and two-word responses ("yes", "sounds good") are too easy
            // to remove incorrectly when both sides speak at once.
            return nil
        }

        if nearbySystemSentences.contains(where: {
            similarity(microphoneText, $0) >= threshold
                || $0 == microphoneText
        }) {
            return .similarity
        }

        // Exact phrase containment catches short fragments that Whisper splits
        // away from a larger sentence on the other stream.
        if nearbySystemText.contains(microphoneText) {
            return .similarity
        }

        let coverage = bigramCoverage(
            of: microphoneText,
            in: nearbySystemBigrams
        )
        if wordCount >= 4, coverage >= 0.60 {
            return .coverage
        }

        return nil
    }

    private static func intervalsAreNearby(
        _ lhs: TranscriptSegment,
        _ rhs: TranscriptSegment,
        window: TimeInterval
    ) -> Bool {
        guard let lhsStart = lhs.startTime, let rhsStart = rhs.startTime else {
            return false
        }
        let lhsEnd = max(lhsStart, lhs.endTime ?? lhsStart)
        let rhsEnd = max(rhsStart, rhs.endTime ?? rhsStart)
        return lhsStart <= rhsEnd + window && rhsStart <= lhsEnd + window
    }

    private static func microphoneSentenceCount(in transcript: Transcript) -> Int {
        transcript.segments
            .filter { $0.speaker == AudioSource.microphone.rawValue }
            .reduce(0) { $0 + sentences(in: $1.text).count }
    }

    static func sentences(in text: String) -> [String] {
        var results: [String] = []
        var current = ""

        for character in text {
            if character == "\n" || character == "\r" {
                appendIfNotEmpty(current, to: &results)
                current = ""
                continue
            }

            current.append(character)
            if character == "." || character == "!" || character == "?" {
                appendIfNotEmpty(current, to: &results)
                current = ""
            }
        }

        appendIfNotEmpty(current, to: &results)
        return results
    }

    private static func appendIfNotEmpty(_ value: String, to results: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            results.append(trimmed)
        }
    }

    static func normalize(_ sentence: String) -> String {
        let lowercased = sentence.lowercased()
        let scalars = lowercased.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }

        // Word-overlap (Jaccard) check: handles cases where speaker bleed adds
        // a short prefix/suffix word that inflates Levenshtein distance.
        let lhsWords = Set(lhs.split(separator: " ").map(String.init))
        let rhsWords = Set(rhs.split(separator: " ").map(String.init))
        let unionCount = lhsWords.union(rhsWords).count
        if unionCount > 0 {
            let jaccardSimilarity = Double(lhsWords.intersection(rhsWords).count) / Double(unionCount)
            if jaccardSimilarity >= defaultThreshold { return jaccardSimilarity }
        }

        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let maxLength = max(lhsChars.count, rhsChars.count)
        guard maxLength > 0 else { return 1 }

        // Length pre-filter: skip Levenshtein if lengths differ by more than 30%.
        let minLength = min(lhsChars.count, rhsChars.count)
        if Double(maxLength - minLength) / Double(maxLength) > 0.30 { return 0 }

        let distance = levenshtein(lhsChars, rhsChars)
        return 1 - Double(distance) / Double(maxLength)
    }

    /// Returns consecutive word pairs from a normalized string.
    static func bigrams(of text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return [] }
        return (0..<words.count - 1).map { "\(words[$0]) \(words[$0 + 1])" }
    }

    /// Fraction of `sentence`'s bigrams that appear in `referenceBigrams`.
    /// Returns 0 when the sentence has fewer than 2 words.
    static func bigramCoverage(of sentence: String, in referenceBigrams: Set<String>) -> Double {
        let sentenceBigrams = bigrams(of: sentence)
        guard !sentenceBigrams.isEmpty else { return 0 }
        let covered = sentenceBigrams.filter { referenceBigrams.contains($0) }.count
        return Double(covered) / Double(sentenceBigrams.count)
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return previous[rhs.count]
    }
}

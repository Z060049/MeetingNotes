import Foundation

public struct MarkdownDocument: Equatable, Sendable {
    public let filename: String
    public let contents: String

    public init(filename: String, contents: String) {
        self.filename = filename
        self.contents = contents
    }
}

public final class MarkdownExporter: @unchecked Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: - Raw transcript export

    /// Writes the unmodified Groq transcript as the recording's only output file.
    @discardableResult
    public func exportRawTranscription(
        transcript: Transcript,
        shortTitle: String,
        session: RecordingSession,
        to directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = renderRawTranscription(transcript: transcript, shortTitle: shortTitle, session: session)
        let outputURL = directory.appendingPathComponent(document.filename)
        try document.contents.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    public func renderRawTranscription(
        transcript: Transcript,
        shortTitle: String,
        session: RecordingSession
    ) -> MarkdownDocument {
        let sanitized = sanitizedTitle(shortTitle)
        let filename = "\(Self.filenameDateFormatter.string(from: session.startedAt))_\(sanitized)_transcript.md"
        let sources = session.audioSources.map(\.rawValue).sorted().joined(separator: ", ")

        let contents = """
        ---
        title: \(shortTitle)
        date: \(Self.metadataDateFormatter.string(from: session.startedAt))
        duration: \(Self.durationFormatter.string(from: session.duration) ?? "Unknown")
        processing_mode: \(session.processingMode.rawValue)
        audio_sources: \(sources)
        ---

        # \(shortTitle) (Raw Transcript)

        ## Transcript

        \(Self.transcriptBySource(transcript, session: session))
        """

        return MarkdownDocument(filename: filename, contents: contents)
    }

    private func sanitizedTitle(_ title: String) -> String {
        let fallback = "meeting"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = title.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        return sanitized.isEmpty ? fallback : sanitized
    }

    private static func transcriptBySource(_ transcript: Transcript, session: RecordingSession) -> String {
        let sections = AudioSource.allCases.map { source in
            transcriptSection(for: source, transcript: transcript, session: session)
        }

        return sections.joined(separator: "\n\n")
    }

    private static func transcriptSection(
        for source: AudioSource,
        transcript: Transcript,
        session: RecordingSession
    ) -> String {
        let matchingSegments = transcript.segments.filter { $0.speaker == source.rawValue }
        let heading = "### \(source.rawValue)"

        guard !matchingSegments.isEmpty else {
            if session.audioSources.contains(source) {
                return """
                \(heading)

                No transcript was generated for this captured source.
                """
            }

            return """
            \(heading)

            Not captured for this recording.
            """
        }

        let body = matchingSegments
            .map { segment in
                if let startTime = segment.startTime {
                    return "[\(Self.timestamp(startTime))] \(segment.text)"
                }
                return segment.text
            }
            .joined(separator: "\n")

        return """
        \(heading)

        \(body)
        """
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()

    private static let metadataDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

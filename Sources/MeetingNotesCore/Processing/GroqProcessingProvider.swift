import Foundation

public final class GroqProcessingProvider: ProcessingProvider, @unchecked Sendable {
    private static let baseURL = "https://api.groq.com/openai/v1"

    private let apiKeyProvider: @Sendable () throws -> String?
    private let session: URLSession
    private let transcriptionModel: String
    private let summaryModel: String

    public init(
        apiKeyProvider: @escaping @Sendable () throws -> String?,
        session: URLSession? = nil,
        transcriptionModel: String = "whisper-large-v3-turbo",
        summaryModel: String = "openai/gpt-oss-20b"
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session ?? Self.makeDefaultSession()
        self.transcriptionModel = transcriptionModel
        self.summaryModel = summaryModel
    }

    /// Transcribing long meetings can keep the connection open for minutes while
    /// the server processes audio. `URLSession.shared`'s 60s request timeout is
    /// far too short and silently fails long recordings, so use generous limits.
    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1_800
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    public func process(
        capture: AudioCaptureResult,
        settings: AppSettings,
        onTranscriptReady: (@Sendable (Transcript) async -> Void)? = nil
    ) async throws -> ProcessingResult {
        guard settings.processingMode == .api else {
            throw ProcessingProviderError.unsupportedLocalMode
        }
        guard let apiKey = try apiKeyProvider(), !apiKey.isEmpty else {
            throw ProcessingProviderError.missingAPIKey
        }

        let transcript = try await transcribe(capture: capture, apiKey: apiKey)
        await onTranscriptReady?(transcript)

        let deduplication = TranscriptDeduplicator.deduplicateWithReport(transcript)
        let cleaned = TranscriptDeduplicator.collapseRepeatedSentences(deduplication.transcript)
        let report = deduplication.report
        PersistentDiagnosticLog.shared.log(
            "Transcript deduplication: mic sentences \(report.microphoneSentencesBefore) → "
                + "\(report.microphoneSentencesAfter), removed \(report.removedSentenceCount) "
                + "(similarity: \(report.removedBySimilarity), coverage: \(report.removedByCoverage), "
                + "embedded spans: \(report.removedEmbeddedSpans)); affected mic segments: "
                + "\(report.affectedMicrophoneSegmentIndices)."
        )

        let summary = try await summarize(transcript: cleaned, depth: settings.summaryDepth, apiKey: apiKey)
        return ProcessingResult(transcript: cleaned, summary: summary)
    }

    public func generateTitle(transcript: Transcript, apiKey: String) async -> String {
        let messages = [
            ChatMessage(
                role: "user",
                content: """
                Reply with only a title of 4-6 words for this conversation. \
                Use plain words, no punctuation, no quotes.

                Transcript:
                \(transcript.textForSummarization.prefix(400))
                """
            )
        ]

        do {
            let data = try await chatCompletion(
                messages: messages,
                apiKey: apiKey,
                responseFormat: nil,
                maxCompletionTokens: 40
            )
            guard let text = try ChatCompletionTextExtractor.extractText(from: data) else {
                return "recording"
            }
            return sanitizeTitle(text)
        } catch {
            return "recording"
        }
    }

    private func sanitizeTitle(_ raw: String) -> String {
        let stripped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ":", with: "")
        let firstLine = stripped.components(separatedBy: "\n").first ?? stripped
        let words = firstLine.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? "recording" : words
    }

    private func transcribe(capture: AudioCaptureResult, apiKey: String) async throws -> Transcript {
        var segments: [TranscriptSegment] = []

        for file in capture.files {
            guard AudioTranscriptionPolicy.decision(for: file).shouldTranscribe else {
                continue
            }

            let trimmedAudio = try? AudioLevelAnalyzer.trimmedSilence(url: file.url)
            let sourceURL = trimmedAudio?.url ?? file.url
            let baseOffset = file.captureStartOffset + (trimmedAudio?.startOffset ?? 0)
            defer {
                if sourceURL != file.url {
                    try? FileManager.default.removeItem(at: sourceURL)
                }
            }

            // Downsample and split into upload-sized chunks so long meetings do
            // not exceed the API's file-size limit or upload timeout.
            let chunks = (try? TranscriptionUploadPreparer.prepareChunks(from: sourceURL))
                ?? [PreparedTranscriptionAudio(url: sourceURL, startOffset: 0, isTemporary: false)]
            defer {
                for chunk in chunks where chunk.isTemporary {
                    try? FileManager.default.removeItem(at: chunk.url)
                }
            }

            for chunk in chunks {
                let response = try await transcribe(fileURL: chunk.url, apiKey: apiKey)
                segments.append(contentsOf: Self.transcriptSegments(
                    from: response,
                    source: file.source,
                    timelineOffset: baseOffset + chunk.startOffset
                ))
            }
        }

        return Transcript(segments: segments)
    }

    private func transcribe(fileURL: URL, apiKey: String) async throws -> TranscriptionResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let bodyFileURL = try Self.writeMultipartBody(
            boundary: boundary,
            fields: [
                ("model", transcriptionModel),
                ("response_format", "verbose_json"),
                ("timestamp_granularities[]", "segment"),
                ("temperature", "0")
            ],
            fileFieldName: "file",
            fileURL: fileURL,
            fileContentType: AudioTranscriptionPolicy.contentType(for: fileURL)
        )
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        let (data, response) = try await session.upload(for: request, fromFile: bodyFileURL)
        try validate(response: response, data: data)

        do {
            return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        } catch {
            throw ProcessingProviderError.invalidResponse
        }
    }

    private func summarize(transcript: Transcript, depth: SummaryDepth, apiKey: String) async throws -> MeetingSummary {
        let messages = [
            ChatMessage(
                role: "user",
                content: """
                Create a \(depth.rawValue) meeting summary from this transcript.
                Write each keyPoint as a concise insight in your own words; do not copy transcript sentences verbatim.

                Transcript:
                \(transcript.textForSummarization)
                """
            )
        ]
        let responseFormat = ChatResponseFormat(
            type: "json_schema",
            jsonSchema: ChatJSONSchema(
                name: "meeting_summary",
                strict: true,
                schema: SummarySchema.object
            )
        )
        let data = try await chatCompletion(
            messages: messages,
            apiKey: apiKey,
            responseFormat: responseFormat,
            maxCompletionTokens: 2_048
        )

        guard let text = try ChatCompletionTextExtractor.extractText(from: data) else {
            throw ProcessingProviderError.apiError("Groq summary response did not contain output text.")
        }
        guard let jsonData = text.data(using: .utf8) else {
            throw ProcessingProviderError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: jsonData)
        } catch {
            throw ProcessingProviderError.apiError(
                "Groq summary response was not valid meeting-summary JSON: \(error.localizedDescription)"
            )
        }
    }

    private func chatCompletion(
        messages: [ChatMessage],
        apiKey: String,
        responseFormat: ChatResponseFormat?,
        maxCompletionTokens: Int
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: summaryModel,
                messages: messages,
                responseFormat: responseFormat,
                maxCompletionTokens: maxCompletionTokens
            )
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProcessingProviderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.processingError(statusCode: httpResponse.statusCode, responseBody: data)
        }
    }

    public static func processingError(statusCode: Int, responseBody: Data) -> ProcessingProviderError {
        let parsed = parseErrorBody(responseBody)
        let rawFallback = String(data: responseBody, encoding: .utf8) ?? "Groq request failed."

        switch statusCode {
        case 401, 403:
            return .apiError("Groq rejected the API key. Update it in MeetingNotes Settings and try again.")
        case 429:
            return .quotaExceeded(
                parsed?.message ?? "Groq's rate limit was reached. Wait for the free-tier limit to reset and try again."
            )
        default:
            return .apiError(parsed?.message ?? rawFallback)
        }
    }

    static func decodeChatCompletionText(from data: Data) throws -> String? {
        try ChatCompletionTextExtractor.extractText(from: data)
    }

    static func decodeTranscriptionSegments(
        from data: Data,
        source: AudioSource,
        timelineOffset: TimeInterval
    ) throws -> [TranscriptSegment] {
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return transcriptSegments(from: response, source: source, timelineOffset: timelineOffset)
    }

    private static func transcriptSegments(
        from response: TranscriptionResponse,
        source: AudioSource,
        timelineOffset: TimeInterval
    ) -> [TranscriptSegment] {
        guard let responseSegments = response.segments, !responseSegments.isEmpty else {
            return [TranscriptSegment(speaker: source.rawValue, text: response.text)]
        }

        return responseSegments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                speaker: source.rawValue,
                startTime: timelineOffset + segment.start,
                endTime: timelineOffset + segment.end,
                text: text
            )
        }
    }

    private static func parseErrorBody(_ data: Data) -> (message: String?, type: String?, code: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return nil
        }
        return (
            message: error["message"] as? String,
            type: error["type"] as? String,
            code: error["code"] as? String
        )
    }

    private static func writeMultipartBody(
        boundary: String,
        fields: [(name: String, value: String)],
        fileFieldName: String,
        fileURL: URL,
        fileContentType: String
    ) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingnotes-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        let writeHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? writeHandle.close() }

        func write(_ string: String) throws {
            try writeHandle.write(contentsOf: Data(string.utf8))
        }

        for field in fields {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            try write("\(field.value)\r\n")
        }

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        try write("Content-Type: \(fileContentType)\r\n\r\n")

        let readHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? readHandle.close() }
        while let chunk = try readHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try writeHandle.write(contentsOf: chunk)
        }

        try write("\r\n--\(boundary)--\r\n")
        return tempURL
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
    let segments: [TranscriptionSegmentResponse]?
}

private struct TranscriptionSegmentResponse: Decodable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let responseFormat: ChatResponseFormat?
    let maxCompletionTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case maxCompletionTokens = "max_completion_tokens"
    }
}

private struct ChatResponseFormat: Encodable {
    let type: String
    let jsonSchema: ChatJSONSchema

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

private struct ChatJSONSchema: Encodable {
    let name: String
    let strict: Bool
    let schema: SummarySchema
}

private struct SummarySchema: Encodable {
    let type: String
    let additionalProperties: Bool
    let required: [String]
    let properties: [String: SummarySchemaProperty]

    static let object = SummarySchema(
        type: "object",
        additionalProperties: false,
        required: ["title", "keyPoints", "decisions", "actionItems", "followUps"],
        properties: [
            "title": .string,
            "keyPoints": .stringArray,
            "decisions": .stringArray,
            "actionItems": .stringArray,
            "followUps": .stringArray
        ]
    )
}

private enum SummarySchemaProperty: Encodable {
    case string
    case stringArray

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string:
            try container.encode("string", forKey: .type)
        case .stringArray:
            try container.encode("array", forKey: .type)
            try container.encode(StringItemSchema(type: "string"), forKey: .items)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case items
    }
}

private struct StringItemSchema: Encodable {
    let type: String
}

private struct ChatCompletionTextExtractor {
    static func extractText(from data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let choices = dictionary["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

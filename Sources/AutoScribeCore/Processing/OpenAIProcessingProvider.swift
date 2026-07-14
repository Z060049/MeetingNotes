import Foundation

public final class OpenAIProcessingProvider: ProcessingProvider, @unchecked Sendable {
    private let apiKeyProvider: @Sendable () throws -> String?
    private let session: URLSession
    private let transcriptionModel: String
    private let summaryModel: String

    public init(
        apiKeyProvider: @escaping @Sendable () throws -> String?,
        session: URLSession = .shared,
        transcriptionModel: String = "whisper-1",
        summaryModel: String = "gpt-4o-mini"
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.transcriptionModel = transcriptionModel
        self.summaryModel = summaryModel
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
        let deduplicated = TranscriptDeduplicator.deduplicate(transcript)
        let cleaned = TranscriptDeduplicator.collapseRepeatedSentences(deduplicated)

        // Notify the controller that the transcript is ready before summarization.
        await onTranscriptReady?(cleaned)

        let summary = try await summarize(transcript: cleaned, depth: settings.summaryDepth, apiKey: apiKey)
        return ProcessingResult(transcript: cleaned, summary: summary)
    }

    /// Generates a short title (4–6 words) for use in filenames via a minimal API call.
    /// Never throws — returns "recording" on failure.
    public func generateTitle(transcript: Transcript, apiKey: String) async -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": summaryModel,
            "input": """
            Reply with only a title of 4-6 words for this conversation. \
            Use plain words, no punctuation, no quotes.

            Transcript:
            \(transcript.textForSummarization.prefix(400))
            """,
            "max_output_tokens": 40
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return "recording" }
        request.httpBody = body

        do {
            let (data, _) = try await session.data(for: request)
            guard let text = try? ResponsesAPITextExtractor.extractText(from: data) else { return "recording" }
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

            // Fall back to the original file when no active frames are found above
            // threshold — skipping outright was too aggressive for quiet mics.
            let uploadURL = (try? AudioLevelAnalyzer.trimmedSilence(url: file.url)) ?? file.url
            defer {
                if uploadURL != file.url {
                    try? FileManager.default.removeItem(at: uploadURL)
                }
            }

            let response = try await transcribe(fileURL: uploadURL, apiKey: apiKey)
            segments.append(TranscriptSegment(speaker: file.source.rawValue, text: response.text))
        }

        return Transcript(segments: segments)
    }

    private func transcribe(fileURL: URL, apiKey: String) async throws -> TranscriptionResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let bodyFileURL = try Self.writeMultipartBody(
            boundary: boundary,
            fields: [
                ("model", transcriptionModel),
                ("response_format", "json"),
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
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = SummaryRequest(
            model: summaryModel,
            input: """
            Create a \(depth.rawValue) meeting summary from this transcript.
            Return only JSON matching the requested schema. Do not wrap the JSON in markdown.
            Write each keyPoint as a concise insight in your own words — do not copy transcript sentences verbatim.

            Transcript:
            \(transcript.textForSummarization)
            """,
            text: SummaryTextOptions(
                format: SummaryJSONSchema(
                    type: "json_schema",
                    name: "meeting_summary",
                    strict: true,
                    schema: SummarySchema.object
                )
            )
        )

        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        guard let text = try ResponsesAPITextExtractor.extractText(from: data) else {
            throw ProcessingProviderError.apiError("OpenAI summary response did not contain output text.")
        }

        let cleanedText = Self.cleanJSONText(text)
        guard let jsonData = cleanedText.data(using: .utf8) else {
            throw ProcessingProviderError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: jsonData)
        } catch {
            throw ProcessingProviderError.apiError("OpenAI summary response was not valid meeting-summary JSON: \(error.localizedDescription)")
        }
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
        let rawFallback = String(data: responseBody, encoding: .utf8) ?? "OpenAI request failed."

        let isQuota = statusCode == 429
            && (parsed?.type == "insufficient_quota" || parsed?.code == "insufficient_quota")
        if isQuota {
            return .quotaExceeded("OpenAI reports your account is out of credits/quota. Add credits to your OpenAI account and try again.")
        }

        return .apiError(parsed?.message ?? rawFallback)
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
            .appendingPathComponent("autoscribe-upload-\(UUID().uuidString)")
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

    private static func cleanJSONText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct SummaryRequest: Encodable {
    let model: String
    let input: String
    let text: SummaryTextOptions
}

private struct SummaryTextOptions: Encodable {
    let format: SummaryJSONSchema
}

private struct SummaryJSONSchema: Encodable {
    let type: String
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
            "title": SummarySchemaProperty.string,
            "keyPoints": SummarySchemaProperty.stringArray,
            "decisions": SummarySchemaProperty.stringArray,
            "actionItems": SummarySchemaProperty.stringArray,
            "followUps": SummarySchemaProperty.stringArray
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

private struct ResponsesAPITextExtractor {
    static func extractText(from data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            return nil
        }

        if let outputText = dictionary["output_text"] as? String {
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let output = dictionary["output"] as? [[String: Any]] else {
            return nil
        }

        for item in output {
            guard let content = item["content"] as? [[String: Any]] else {
                continue
            }

            for contentItem in content {
                if let text = contentItem["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let text = contentItem["output_text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }
}


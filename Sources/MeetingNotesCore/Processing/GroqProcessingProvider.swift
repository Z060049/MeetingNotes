import Foundation

public final class GroqProcessingProvider: ProcessingProvider, @unchecked Sendable {
    private static let baseURL = "https://api.groq.com/openai/v1"

    private let apiKeyProvider: @Sendable () throws -> String?
    private let session: URLSession
    private let transcriptionModel: String

    public init(
        apiKeyProvider: @escaping @Sendable () throws -> String?,
        session: URLSession? = nil,
        transcriptionModel: String = "whisper-large-v3-turbo"
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session ?? Self.makeDefaultSession()
        self.transcriptionModel = transcriptionModel
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

    public func transcribe(capture: AudioCaptureResult) async throws -> Transcript {
        guard let apiKey = try apiKeyProvider(), !apiKey.isEmpty else {
            throw ProcessingProviderError.missingAPIKey
        }

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

        guard !segments.isEmpty else {
            throw ProcessingProviderError.apiError(
                "No speech was detected in the recording. Check the captured audio and try again."
            )
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

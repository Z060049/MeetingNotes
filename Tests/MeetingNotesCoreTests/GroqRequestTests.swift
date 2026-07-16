@testable import MeetingNotesCore
import Foundation
import XCTest

final class GroqRequestTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testTitleUsesGroqChatCompletionsEndpointAndModel() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let requestExpectation = expectation(description: "Groq request")

        MockURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.groq.com/openai/v1/chat/completions"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gsk_test")
            requestExpectation.fulfill()

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data("""
            {"choices":[{"message":{"role":"assistant","content":"Weekly Product Planning"}}]}
            """.utf8)
            return (response, data)
        }

        let provider = GroqProcessingProvider(
            apiKeyProvider: { "gsk_test" },
            session: session
        )
        let title = await provider.generateTitle(
            transcript: Transcript(segments: [
                TranscriptSegment(speaker: "Speaker", text: "We planned the next product release.")
            ]),
            apiKey: "gsk_test"
        )

        await fulfillment(of: [requestExpectation], timeout: 1)
        XCTAssertEqual(title, "Weekly Product Planning")
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

import MeetingNotesCore
import XCTest

final class ProcessingErrorMappingTests: XCTestCase {
    func testMapsRateLimitToQuotaExceeded() {
        let body = Data("""
        {"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}
        """.utf8)

        let error = GroqProcessingProvider.processingError(statusCode: 429, responseBody: body)

        guard case .quotaExceeded(let message) = error else {
            return XCTFail("expected quotaExceeded, got \(error)")
        }
        XCTAssertTrue(message.lowercased().contains("credits") || message.lowercased().contains("quota"))
    }

    func testMapsGenericErrorToParsedMessage() {
        let body = Data("""
        {"error":{"message":"Invalid request payload.","type":"invalid_request_error"}}
        """.utf8)

        let error = GroqProcessingProvider.processingError(statusCode: 400, responseBody: body)

        guard case .apiError(let message) = error else {
            return XCTFail("expected apiError, got \(error)")
        }
        XCTAssertEqual(message, "Invalid request payload.")
    }

    func testNonJSONBodyFallsBackToRawText() {
        let body = Data("Service Unavailable".utf8)

        let error = GroqProcessingProvider.processingError(statusCode: 503, responseBody: body)

        guard case .apiError(let message) = error else {
            return XCTFail("expected apiError, got \(error)")
        }
        XCTAssertEqual(message, "Service Unavailable")
    }

    func testMapsRejectedKeyToActionableMessage() {
        let error = GroqProcessingProvider.processingError(statusCode: 401, responseBody: Data())

        guard case .apiError(let message) = error else {
            return XCTFail("expected apiError, got \(error)")
        }
        XCTAssertTrue(message.contains("API key"))
    }
}

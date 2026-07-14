@testable import AutoScribeCore
import XCTest

final class WhisperTextSanitizerTests: XCTestCase {
    func testRemovesWhisperControlAndTimestampTokens() {
        let input = "<|startoftranscript|><|0. 00|> Hello from the meeting. <|4. 56|>"

        let result = WhisperKitTranscriptionService.sanitizedWhisperText(input)

        XCTAssertEqual(result, "Hello from the meeting.")
        XCTAssertFalse(result.contains("<|"))
    }

    func testNormalizesWhitespaceAfterRemovingTokens() {
        let input = " First<|1.00|>\n\tsecond   phrase "

        let result = WhisperKitTranscriptionService.sanitizedWhisperText(input)

        XCTAssertEqual(result, "First second phrase")
    }
}

import MeetingNotesCore
import XCTest

final class EnvironmentConfigurationTests: XCTestCase {
    func testParsesSimpleAssignment() {
        let contents = "GROQ_API_KEY=gsk_test_123"
        XCTAssertEqual(
            EnvironmentConfiguration.value(forKey: "GROQ_API_KEY", inEnvFileContents: contents),
            "gsk_test_123"
        )
    }

    func testIgnoresCommentsAndBlankLinesAndOtherKeys() {
        let contents = """
        # comment line
        OTHER_KEY=ignored

        GROQ_API_KEY=gsk_real_key
        """
        XCTAssertEqual(
            EnvironmentConfiguration.value(forKey: "GROQ_API_KEY", inEnvFileContents: contents),
            "gsk_real_key"
        )
    }

    func testStripsSurroundingQuotesAndExportPrefix() {
        let contents = "export GROQ_API_KEY = \"gsk_quoted_key\""
        XCTAssertEqual(
            EnvironmentConfiguration.value(forKey: "GROQ_API_KEY", inEnvFileContents: contents),
            "gsk_quoted_key"
        )
    }

    func testReturnsNilWhenKeyMissingOrEmpty() {
        XCTAssertNil(EnvironmentConfiguration.value(forKey: "GROQ_API_KEY", inEnvFileContents: "NOPE=1"))
        XCTAssertNil(EnvironmentConfiguration.value(forKey: "GROQ_API_KEY", inEnvFileContents: "GROQ_API_KEY="))
    }

    func testKeychainCredentialTakesPriority() {
        XCTAssertEqual(
            EnvironmentConfiguration.groqAPIKey(
                credentialStore: StubCredentialStore(apiKey: "gsk_keychain")
            ),
            "gsk_keychain"
        )
    }
}

private struct StubCredentialStore: APICredentialStoring {
    let apiKeyValue: String?

    init(apiKey: String?) {
        apiKeyValue = apiKey
    }

    func apiKey() throws -> String? { apiKeyValue }
    func saveAPIKey(_ apiKey: String) throws {}
    func deleteAPIKey() throws {}
}

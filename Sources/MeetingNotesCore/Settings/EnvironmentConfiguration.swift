import Foundation

public enum EnvironmentConfiguration {
    public static let groqAPIKeyName = "GROQ_API_KEY"

    public static func groqAPIKey(
        credentialStore: APICredentialStoring = KeychainAPICredentialStore()
    ) -> String? {
        do {
            if let keychainValue = try credentialStore.apiKey(), !keychainValue.isEmpty {
                return keychainValue
            }
        } catch {
            // Development environment and .env files remain a fallback if
            // Keychain is temporarily unavailable.
        }
        return groqAPIKeyFromEnvironment()
    }

    public static func groqAPIKeyFromEnvironment() -> String? {
        if let value = ProcessInfo.processInfo.environment[groqAPIKeyName],
           !value.isEmpty {
            return value
        }

        for url in candidateEnvFileURLs() {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               let value = value(forKey: groqAPIKeyName, inEnvFileContents: contents) {
                return value
            }
        }

        return nil
    }

    static func candidateEnvFileURLs() -> [URL] {
        var urls: [URL] = []
        let fileManager = FileManager.default

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(".env"))
        }

        urls.append(URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(".env"))

        let home = fileManager.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent("Documents/MeetingNotes/.env"))
        urls.append(home.appendingPathComponent(".meetingnotes/.env"))

        return urls
    }

    public static func value(forKey key: String, inEnvFileContents contents: String) -> String? {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            var assignment = line
            if assignment.hasPrefix("export ") {
                assignment = String(assignment.dropFirst("export ".count))
            }

            guard let separatorIndex = assignment.firstIndex(of: "=") else {
                continue
            }

            let name = assignment[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            guard name == key else {
                continue
            }

            let value = stripSurroundingQuotes(
                String(assignment[assignment.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
            )
            return value.isEmpty ? nil : value
        }

        return nil
    }

    private static func stripSurroundingQuotes(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        let isDoubleQuoted = value.hasPrefix("\"") && value.hasSuffix("\"")
        let isSingleQuoted = value.hasPrefix("'") && value.hasSuffix("'")
        guard isDoubleQuoted || isSingleQuoted else {
            return value
        }

        return String(value.dropFirst().dropLast())
    }
}

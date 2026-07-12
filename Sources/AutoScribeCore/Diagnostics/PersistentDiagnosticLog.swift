import Foundation

public final class PersistentDiagnosticLog: @unchecked Sendable {
    public static let shared = PersistentDiagnosticLog()

    public let logURL: URL

    private let archivedLogURL: URL
    private let maxBytes: UInt64
    private let fileManager: FileManager
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    public init(
        logDirectory: URL? = nil,
        maxBytes: UInt64 = 1_000_000,
        fileManager: FileManager = .default
    ) {
        let directory = logDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AutoScribe", isDirectory: true)
        self.logURL = directory.appendingPathComponent("AutoScribe.log")
        self.archivedLogURL = directory.appendingPathComponent("AutoScribe.previous.log")
        self.maxBytes = maxBytes
        self.fileManager = fileManager
        self.formatter = ISO8601DateFormatter()
    }

    public func log(
        _ message: String,
        level: DiagnosticEvent.Level = .info,
        date: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try rotateIfNeeded()

            let line = "\(formatter.string(from: date)) [\(level.rawValue)] \(message)\n"
            let data = Data(line.utf8)
            if !fileManager.fileExists(atPath: logURL.path) {
                try data.write(to: logURL, options: .atomic)
                return
            }

            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            fputs("AutoScribe diagnostic logging failed: \(error)\n", stderr)
        }
    }

    private func rotateIfNeeded() throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value >= maxBytes else {
            return
        }

        try? fileManager.removeItem(at: archivedLogURL)
        try fileManager.moveItem(at: logURL, to: archivedLogURL)
    }
}

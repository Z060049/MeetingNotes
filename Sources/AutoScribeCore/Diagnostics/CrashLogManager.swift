import Foundation

public final class CrashLogManager: @unchecked Sendable {
    public static let shared = CrashLogManager()

    public let reportDirectoryURL: URL

    private struct SessionMarker: Codable {
        var launchedAt: Date
        var updatedAt: Date
        var state: String
        var terminationRequested: Bool
        var cleanShutdown: Bool
    }

    private let markerURL: URL
    private let systemCrashDirectoryURL: URL
    private let persistentLogURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let timestampFormatter = ISO8601DateFormatter()

    public convenience init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let stateDirectory = applicationSupport
            .appendingPathComponent("AutoScribe/Diagnostics", isDirectory: true)
        let logDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AutoScribe", isDirectory: true)
        self.init(
            stateDirectory: stateDirectory,
            reportDirectory: logDirectory.appendingPathComponent("Crash Reports", isDirectory: true),
            systemCrashDirectory: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            persistentLogURL: logDirectory.appendingPathComponent("AutoScribe.log"),
            fileManager: fileManager
        )
    }

    public init(
        stateDirectory: URL,
        reportDirectory: URL,
        systemCrashDirectory: URL,
        persistentLogURL: URL,
        fileManager: FileManager = .default
    ) {
        self.markerURL = stateDirectory.appendingPathComponent("active-session.json")
        self.reportDirectoryURL = reportDirectory
        self.systemCrashDirectoryURL = systemCrashDirectory
        self.persistentLogURL = persistentLogURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func startSession(initialState: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        try? fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let previousMarker = loadMarker()
        let incidentURL: URL?
        if let previousMarker, !previousMarker.cleanShutdown {
            incidentURL = writeIncident(for: previousMarker)
        } else {
            incidentURL = nil
        }

        let now = Date()
        saveMarker(SessionMarker(
            launchedAt: now,
            updatedAt: now,
            state: initialState,
            terminationRequested: false,
            cleanShutdown: false
        ))
        return incidentURL
    }

    public func updateState(_ state: String) {
        updateMarker {
            $0.state = state
        }
    }

    public func recordTerminationRequest(state: String) {
        updateMarker {
            $0.state = state
            $0.terminationRequested = true
        }
    }

    @discardableResult
    public func markCleanShutdown(finalState: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard var marker = loadMarker() else {
            return nil
        }

        marker.state = finalState
        marker.updatedAt = Date()
        let incidentURL = marker.terminationRequested ? nil : writeIncident(for: marker)
        marker.cleanShutdown = true
        saveMarker(marker)
        return incidentURL
    }

    private func updateMarker(_ update: (inout SessionMarker) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var marker = loadMarker() else {
            return
        }
        update(&marker)
        marker.updatedAt = Date()
        saveMarker(marker)
    }

    private func loadMarker() -> SessionMarker? {
        guard let data = try? Data(contentsOf: markerURL) else {
            return nil
        }
        return try? JSONDecoder().decode(SessionMarker.self, from: data)
    }

    private func saveMarker(_ marker: SessionMarker) {
        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(marker)
            try data.write(to: markerURL, options: .atomic)
        } catch {
            PersistentDiagnosticLog.shared.log(
                "Could not update crash session marker: \(error.localizedDescription)",
                level: .warning
            )
        }
    }

    private func writeIncident(for marker: SessionMarker) -> URL? {
        let folderName = timestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let incidentDirectory = reportDirectoryURL
            .appendingPathComponent("\(folderName)-\(UUID().uuidString.prefix(8))", isDirectory: true)

        do {
            try fileManager.createDirectory(at: incidentDirectory, withIntermediateDirectories: true)
            let systemReport = newestSystemCrashReport(since: marker.launchedAt)
            let report = """
            AutoScribe Unexpected Exit Report
            Detected: \(timestampFormatter.string(from: Date()))
            Previous launch: \(timestampFormatter.string(from: marker.launchedAt))
            Last update: \(timestampFormatter.string(from: marker.updatedAt))
            Last app state: \(marker.state)
            Termination requested: \(marker.terminationRequested)
            OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            App version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
            System crash report: \(systemReport?.lastPathComponent ?? "none found")
            Persistent log: \(persistentLogURL.path)

            Recent persistent log:
            \(recentPersistentLog())
            """
            try report.write(
                to: incidentDirectory.appendingPathComponent("unexpected-exit.txt"),
                atomically: true,
                encoding: .utf8
            )

            if let systemReport {
                try? fileManager.copyItem(
                    at: systemReport,
                    to: incidentDirectory.appendingPathComponent(systemReport.lastPathComponent)
                )
            }
            return incidentDirectory
        } catch {
            PersistentDiagnosticLog.shared.log(
                "Could not create unexpected-exit report: \(error.localizedDescription)",
                level: .warning
            )
            return nil
        }
    }

    private func newestSystemCrashReport(since date: Date) -> URL? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: systemCrashDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return files
            .filter {
                $0.lastPathComponent.hasPrefix("AutoScribe")
                    && ($0.pathExtension == "ips" || $0.pathExtension == "crash")
            }
            .compactMap { url -> (URL, Date)? in
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                guard let modified, modified >= date else {
                    return nil
                }
                return (url, modified)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    private func recentPersistentLog() -> String {
        guard let data = try? Data(contentsOf: persistentLogURL) else {
            return "No persistent log was available."
        }
        let suffix = data.suffix(64 * 1024)
        return String(decoding: suffix, as: UTF8.self)
    }
}

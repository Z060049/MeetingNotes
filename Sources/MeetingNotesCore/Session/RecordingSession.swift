import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone = "Microphone"
    case systemAudio = "System Audio"
}

public enum ProcessingMode: String, Codable, CaseIterable, Sendable {
    case api = "API"
}

public struct RecordingSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var audioSources: Set<AudioSource>
    public var processingMode: ProcessingMode
    public var outputDirectory: URL
    public var temporaryDirectory: URL

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        audioSources: Set<AudioSource> = Set(AudioSource.allCases),
        processingMode: ProcessingMode = .api,
        outputDirectory: URL = FileManager.default.defaultMeetingNotesOutputDirectory,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingNotes", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioSources = audioSources
        self.processingMode = processingMode
        self.outputDirectory = outputDirectory
        self.temporaryDirectory = temporaryDirectory
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    public var finished: RecordingSession {
        var copy = self
        copy.endedAt = Date()
        return copy
    }
}

public extension FileManager {
    var defaultMeetingNotesOutputDirectory: URL {
        homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("MeetingNotes", isDirectory: true)
    }

    var meetingNotesRecordingRecoveryDirectory: URL {
        let applicationSupport = urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("MeetingNotes", isDirectory: true)
            .appendingPathComponent("Recording Recovery", isDirectory: true)
    }

    func meetingNotesRecordingWorkspace(for sessionID: UUID) -> URL {
        meetingNotesRecordingRecoveryDirectory
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }
}

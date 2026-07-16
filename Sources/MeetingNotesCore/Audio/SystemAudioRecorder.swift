import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

@available(macOS 13.0, *)
public final class SystemAudioRecorder: NSObject, SystemAudioRecording, SCStreamOutput, @unchecked Sendable {
    public let backendName = SystemAudioBackend.screenCaptureKit.rawValue

    private let queue = DispatchQueue(label: "com.meetingnotes.system-audio")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var hasStartedSession = false
    private let statsLock = NSLock()
    private var buffersReceived = 0
    private var framesReceived = 0
    private var bytesReceived = 0
    private var writeErrors = 0

    public var onAudioLevel: ((Float) -> Void)?

    public var diagnosticSummary: String? {
        statsLock.withLock {
            "ScreenCaptureKit buffers: \(buffersReceived), frames: \(framesReceived), bytes: \(bytesReceived), write errors: \(writeErrors)"
        }
    }

    public func start(in directory: URL, filename: String = "system-audio.m4a") async throws -> URL {
        guard stream == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let url = directory
            .appendingPathComponent(filename)
            .deletingPathExtension()
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: configuration.sampleRate,
                AVNumberOfChannelsKey: configuration.channelCount,
                AVEncoderBitRateKey: 128_000
            ]
        )
        writerInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(writerInput) else {
            throw AudioCaptureError.writerUnavailable
        }

        writer.add(writerInput)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        self.stream = stream
        self.writer = writer
        self.writerInput = writerInput
        self.outputURL = url
        self.hasStartedSession = false
        resetStats()

        do {
            try await stream.startCapture()
            return url
        } catch {
            clearState()
            throw error
        }
    }

    public func stop() async throws -> URL {
        guard let stream, let outputURL else {
            throw AudioCaptureError.notRecording
        }

        try await stream.stopCapture()
        if let writerInput {
            writerInput.markAsFinished()
        }

        if let writer, writer.status == .writing {
            await writer.finishWriting()
        }

        clearState()
        return outputURL
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let writer,
              let writerInput else {
            return
        }

        let frameCount = sampleBuffer.numSamples
        let byteCount = sampleBuffer.dataBuffer.map(CMBlockBufferGetDataLength) ?? 0
        recordBuffer(frameCount: frameCount, byteCount: byteCount, writeFailed: false)

        if writer.status == .unknown {
            guard writer.startWriting() else {
                recordWriteError()
                return
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            hasStartedSession = true
        }

        if writer.status == .writing, writerInput.isReadyForMoreMediaData {
            if writerInput.append(sampleBuffer) {
                onAudioLevel?(sampleBuffer.estimatedAudioLevel)
            } else {
                recordWriteError()
            }
        }
    }

    private func resetStats() {
        statsLock.withLock {
            buffersReceived = 0
            framesReceived = 0
            bytesReceived = 0
            writeErrors = 0
        }
    }

    private func recordBuffer(frameCount: Int, byteCount: Int, writeFailed: Bool) {
        statsLock.withLock {
            buffersReceived += 1
            framesReceived += frameCount
            bytesReceived += byteCount
            if writeFailed {
                writeErrors += 1
            }
        }
    }

    private func recordWriteError() {
        statsLock.withLock {
            writeErrors += 1
        }
    }

    private func clearState() {
        stream = nil
        writer = nil
        writerInput = nil
        outputURL = nil
        hasStartedSession = false
    }
}

private extension CMSampleBuffer {
    var estimatedAudioLevel: Float {
        guard numSamples > 0 else {
            return 0
        }
        return 0.1
    }
}

import AVFoundation
import MeetingNotesCore
import XCTest

final class TranscriptionUploadPreparerTests: XCTestCase {
    func testDownsamplesToSixteenKilohertzMonoM4A() throws {
        let source = try makeToneWAV(seconds: 3, sampleRate: 44_100, channels: 2)
        defer { try? FileManager.default.removeItem(at: source) }

        let chunks = try TranscriptionUploadPreparer.prepareChunks(from: source)
        defer {
            for chunk in chunks where chunk.isTemporary {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }

        XCTAssertEqual(chunks.count, 1, "A short recording should produce a single chunk.")
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertTrue(chunk.isTemporary)
        XCTAssertEqual(chunk.startOffset, 0, accuracy: 0.0001)
        XCTAssertEqual(chunk.url.pathExtension.lowercased(), "m4a")

        let converted = try AVAudioFile(forReading: chunk.url)
        XCTAssertEqual(converted.fileFormat.sampleRate, TranscriptionUploadPreparer.targetSampleRate, accuracy: 1)
        XCTAssertEqual(converted.fileFormat.channelCount, 1)

        let originalSize = try fileSize(source)
        let convertedSize = try fileSize(chunk.url)
        XCTAssertLessThan(convertedSize, originalSize, "16 kHz mono AAC should be smaller than 44.1 kHz stereo PCM.")
        XCTAssertGreaterThan(convertedSize, 0)
    }

    func testFallsBackToOriginalForUnreadableInput() throws {
        // A non-audio file cannot be opened by AVAudioFile; prepareChunks throws
        // from the reader, which the caller handles by uploading the original.
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-audio-\(UUID().uuidString).wav")
        try Data(repeating: 0, count: 128).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        XCTAssertThrowsError(try TranscriptionUploadPreparer.prepareChunks(from: bogus))
    }

    // MARK: - Helpers

    private func makeToneWAV(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-\(UUID().uuidString).wav")

        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let totalFrames = AVAudioFrameCount(seconds * sampleRate)
        let blockFrames: AVAudioFrameCount = 8_192
        var written: AVAudioFrameCount = 0
        var phase: Float = 0
        let increment = Float(2.0 * Double.pi * 440.0 / sampleRate)

        while written < totalFrames {
            let count = min(blockFrames, totalFrames - written)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
            buffer.frameLength = count
            for channel in 0..<Int(channels) {
                let samples = buffer.floatChannelData![channel]
                var localPhase = phase
                for frame in 0..<Int(count) {
                    samples[frame] = 0.25 * sin(localPhase)
                    localPhase += increment
                }
            }
            phase += increment * Float(count)
            try file.write(from: buffer)
            written += count
        }

        return url
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}

import AVFoundation
import AutoScribeCore
import XCTest

final class AudioLevelAnalyzerTests: XCTestCase {
    private let sampleRate: Double = 16_000

    private func makeWAV(leadingSilenceSeconds: Double, toneSeconds: Double, trailingSilenceSeconds: Double) throws -> URL {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyzer-test-\(UUID().uuidString).wav")

        let file = try AVAudioFile(forWriting: url, settings: settings)
        let writeFormat = file.processingFormat

        func write(seconds: Double, amplitude: Float) throws {
            let frames = AVAudioFrameCount(seconds * sampleRate)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: frames) else {
                return
            }
            buffer.frameLength = frames
            let channel = buffer.floatChannelData![0]
            for frame in 0..<Int(frames) {
                channel[frame] = amplitude == 0 ? 0 : amplitude * sinf(Float(frame) * 0.1)
            }
            try file.write(from: buffer)
        }

        try write(seconds: leadingSilenceSeconds, amplitude: 0)
        try write(seconds: toneSeconds, amplitude: 0.5)
        try write(seconds: trailingSilenceSeconds, amplitude: 0)
        return url
    }

    func testSilentFileIsDetectedAndTrimReturnsNil() throws {
        let url = try makeWAV(leadingSilenceSeconds: 1.0, toneSeconds: 0, trailingSilenceSeconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = AudioLevelAnalyzer.analyze(url: url)
        XCTAssertEqual(analysis?.isSilent, true)
        XCTAssertNil(try AudioLevelAnalyzer.trimmedSilence(url: url))
    }

    func testTrimsLeadingAndTrailingSilence() throws {
        let url = try makeWAV(leadingSilenceSeconds: 2.0, toneSeconds: 1.0, trailingSilenceSeconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = AudioLevelAnalyzer.analyze(url: url)
        XCTAssertEqual(analysis?.isSilent, false)

        let trimmedAudio = try XCTUnwrap(try AudioLevelAnalyzer.trimmedSilence(url: url))
        XCTAssertNotEqual(trimmedAudio.url, url)
        XCTAssertGreaterThan(trimmedAudio.startOffset, 1.4)
        XCTAssertLessThan(trimmedAudio.startOffset, 2.0)
        defer { try? FileManager.default.removeItem(at: trimmedAudio.url) }

        let original = try AVAudioFile(forReading: url)
        let trimmed = try AVAudioFile(forReading: trimmedAudio.url)
        XCTAssertLessThan(trimmed.length, original.length)
        // Tone is 1s; with ~0.3s padding each side the trimmed clip should be well under the 5s original.
        XCTAssertLessThan(Double(trimmed.length) / sampleRate, 2.5)
    }
}

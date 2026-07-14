import AVFoundation
import Foundation

/// Analyzes recorded audio files for actual signal level and trims leading and
/// trailing silence. Used to avoid sending silent or mostly-silent audio to
/// speech-to-text, which otherwise hallucinates filler text.
public enum AudioLevelAnalyzer {
    public static let defaultSilenceThreshold: Float = 0.01

    public struct Analysis: Equatable, Sendable {
        public let peakRMS: Float
        public let isSilent: Bool
    }

    public struct TrimmedAudio: Equatable, Sendable {
        public let url: URL
        /// Seconds removed from the beginning of the original file.
        public let startOffset: TimeInterval

        public init(url: URL, startOffset: TimeInterval) {
            self.url = url
            self.startOffset = startOffset
        }
    }

    /// Window size (in frames) used to evaluate RMS while scanning for signal.
    private static let windowFrames: AVAudioFrameCount = 4_096
    private static let frameStride = 16

    public static func analyze(url: URL, threshold: Float = defaultSilenceThreshold) -> Analysis? {
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }

        let format = file.processingFormat
        guard format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return nil
        }

        var peak: Float = 0
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                return nil
            }
            if buffer.frameLength == 0 {
                break
            }
            peak = max(peak, rms(of: buffer))
        }

        return Analysis(peakRMS: peak, isSilent: peak < threshold)
    }

    /// Returns audio with leading/trailing silence removed and its original
    /// timeline offset. If the
    /// input has no signal above the threshold, returns `nil` (caller skips).
    /// If nothing needs trimming, returns the original URL with a zero offset.
    public static func trimmedSilence(
        url: URL,
        threshold: Float = defaultSilenceThreshold,
        padding: TimeInterval = 0.3
    ) throws -> TrimmedAudio? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, format.channelCount > 0 else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return nil
        }

        var firstActiveFrame: AVAudioFramePosition?
        var lastActiveFrame: AVAudioFramePosition = 0
        var position: AVAudioFramePosition = 0

        while file.framePosition < file.length {
            try file.read(into: buffer)
            let framesRead = AVAudioFramePosition(buffer.frameLength)
            if framesRead == 0 {
                break
            }

            if rms(of: buffer) >= threshold {
                if firstActiveFrame == nil {
                    firstActiveFrame = position
                }
                lastActiveFrame = position + framesRead
            }
            position += framesRead
        }

        guard let firstActiveFrame else {
            return nil
        }

        let padFrames = AVAudioFramePosition(padding * format.sampleRate)
        let start = max(0, firstActiveFrame - padFrames)
        let end = min(totalFrames, lastActiveFrame + padFrames)
        let trimmedCount = end - start
        guard trimmedCount > 0 else {
            return nil
        }

        // Nothing meaningful to trim: keep the original file.
        if start == 0 && end == totalFrames {
            return TrimmedAudio(url: url, startOffset: 0)
        }

        let trimmedURL = try writeTrimmed(
            from: file,
            format: format,
            start: start,
            frameCount: AVAudioFrameCount(trimmedCount)
        )
        return TrimmedAudio(
            url: trimmedURL,
            startOffset: TimeInterval(start) / format.sampleRate
        )
    }

    private static func writeTrimmed(
        from file: AVAudioFile,
        format: AVAudioFormat,
        start: AVAudioFramePosition,
        frameCount: AVAudioFrameCount
    ) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoscribe-trimmed-\(UUID().uuidString).wav")

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        file.framePosition = start
        var remaining = frameCount
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            throw AudioCaptureError.writerUnavailable
        }

        while remaining > 0 {
            let chunk = min(windowFrames, remaining)
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 {
                break
            }
            try outputFile.write(from: buffer)
            remaining -= buffer.frameLength
        }

        return outputURL
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        var sampledCount = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            var frame = 0
            while frame < frameCount {
                let sample = samples[frame]
                sum += sample * sample
                sampledCount += 1
                frame += frameStride
            }
        }

        let mean = sum / Float(max(sampledCount, 1))
        return sqrt(mean)
    }
}

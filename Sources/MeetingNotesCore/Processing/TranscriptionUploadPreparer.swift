import AVFoundation
import Foundation

/// A segment of audio ready to upload to a speech-to-text API.
public struct PreparedTranscriptionAudio: Equatable, Sendable {
    /// The file to upload.
    public let url: URL
    /// Seconds from the start of the input file at which this segment begins,
    /// used to shift returned transcript timestamps back onto the real timeline.
    public let startOffset: TimeInterval
    /// Whether the file is a temporary artifact the caller should delete after use.
    public let isTemporary: Bool

    public init(url: URL, startOffset: TimeInterval, isTemporary: Bool) {
        self.url = url
        self.startOffset = startOffset
        self.isTemporary = isTemporary
    }
}

/// Prepares recorded audio for transcription upload.
///
/// Long meetings produce files that are both too large for hosted transcription
/// APIs (Groq caps uploads at 25 MB on the free tier) and too slow to upload in
/// one request. This downsamples audio to 16 kHz mono AAC — the format speech
/// models want anyway — and splits it into fixed-duration chunks so each upload
/// stays well under the size limit. Transcript timestamps are stitched back
/// together using each chunk's `startOffset`.
public enum TranscriptionUploadPreparer {
    /// Speech models operate at 16 kHz; higher rates waste bandwidth.
    public static let targetSampleRate: Double = 16_000
    /// Low bitrate mono AAC is plenty for speech (~0.24 MB per minute).
    public static let targetBitRate = 32_000
    /// Chunk length. At ~0.24 MB/min a 20-minute chunk is ~5 MB, comfortably
    /// under the 25 MB free-tier limit with room for VBR overshoot.
    public static let chunkDuration: TimeInterval = 20 * 60

    /// Downsamples `url` to 16 kHz mono AAC and splits it into `chunkDuration`
    /// segments. Returns temporary `.m4a` files the caller must delete.
    ///
    /// If conversion is not possible for any reason, returns a single element
    /// pointing at the original file so transcription can still be attempted.
    public static func prepareChunks(from url: URL) throws -> [PreparedTranscriptionAudio] {
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        let totalFrames = inputFile.length

        guard totalFrames > 0, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            return [PreparedTranscriptionAudio(url: url, startOffset: 0, isTemporary: false)]
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return [PreparedTranscriptionAudio(url: url, startOffset: 0, isTemporary: false)]
        }

        let encoderSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: targetBitRate
        ]

        let framesPerChunk = AVAudioFramePosition(chunkDuration * targetSampleRate)
        let readBufferFrames: AVAudioFrameCount = 16_384

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: readBufferFrames) else {
            throw AudioCaptureError.writerUnavailable
        }

        var chunks: [PreparedTranscriptionAudio] = []
        var currentFile: AVAudioFile?
        var framesInChunk: AVAudioFramePosition = 0
        var chunkIndex = 0
        var inputExhausted = false

        func openChunk() throws {
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("meetingnotes-tx-\(UUID().uuidString).m4a")
            currentFile = try AVAudioFile(forWriting: chunkURL, settings: encoderSettings)
            chunks.append(PreparedTranscriptionAudio(
                url: chunkURL,
                startOffset: Double(chunkIndex) * chunkDuration,
                isTemporary: true
            ))
            framesInChunk = 0
        }

        do {
            try openChunk()

            while !inputExhausted {
                let ratio = targetSampleRate / inputFormat.sampleRate
                let outCapacity = AVAudioFrameCount(Double(readBufferFrames) * ratio) + 4_096
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
                    throw AudioCaptureError.writerUnavailable
                }

                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                    if inputExhausted {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputBuffer.frameLength = 0
                    do {
                        try inputFile.read(into: inputBuffer)
                    } catch {
                        inputExhausted = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    if inputBuffer.frameLength == 0 {
                        inputExhausted = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return inputBuffer
                }

                if let conversionError {
                    throw conversionError
                }

                if outputBuffer.frameLength > 0 {
                    try currentFile?.write(from: outputBuffer)
                    framesInChunk += AVAudioFramePosition(outputBuffer.frameLength)

                    if framesInChunk >= framesPerChunk, !inputExhausted {
                        chunkIndex += 1
                        try openChunk()
                    }
                }

                if status == .endOfStream {
                    break
                }
            }
        } catch {
            // Clean up partial chunk files and fall back to the original.
            for chunk in chunks where chunk.isTemporary {
                try? FileManager.default.removeItem(at: chunk.url)
            }
            return [PreparedTranscriptionAudio(url: url, startOffset: 0, isTemporary: false)]
        }

        // Drop any trailing empty chunk that received no frames.
        if let last = chunks.last, last.isTemporary {
            let size = (try? FileManager.default.attributesOfItem(atPath: last.url.path)[.size] as? Int) ?? nil
            if (size ?? 0) == 0 {
                try? FileManager.default.removeItem(at: last.url)
                chunks.removeLast()
            }
        }

        return chunks.isEmpty
            ? [PreparedTranscriptionAudio(url: url, startOffset: 0, isTemporary: false)]
            : chunks
    }
}

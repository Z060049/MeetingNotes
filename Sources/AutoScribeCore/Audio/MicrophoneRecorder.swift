import AVFoundation
import CoreMedia
import Foundation

public protocol MicrophoneRecording: AnyObject, Sendable {
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onInterruption: (@Sendable (String) -> Void)? { get set }

    func start(
        in directory: URL,
        filename: String,
        deviceUID: String?,
        deviceName: String?
    ) async throws -> URL
    func waitForFirstBuffer(timeoutSeconds: TimeInterval) async -> Bool
    func stop() async throws -> URL
}

/// Restartable microphone capture bound to an explicit device.
///
/// `AVAudioEngine.inputNode` can raise an uncaught Objective-C exception when
/// the default input disappears during a route switch. AVCaptureSession reports
/// device loss as an interruption/runtime error, allowing the coordinator to
/// finalize the current segment and reconnect safely.
public final class MicrophoneRecorder: NSObject, MicrophoneRecording, @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "com.autoscribe.microphone-capture")
    private let stateLock = NSLock()

    private var session: AVCaptureSession?
    private var dataOutput: AVCaptureAudioDataOutput?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var didReceiveFirstBuffer = false
    private var writeError: Error?

    public var onAudioLevel: ((Float) -> Void)?
    public var onInterruption: (@Sendable (String) -> Void)?

    public override init() {
        super.init()
    }

    public func start(
        in directory: URL,
        filename: String = "microphone.wav",
        deviceUID: String? = nil,
        deviceName: String? = nil
    ) async throws -> URL {
        guard await requestMicrophoneAccess() else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)

        return try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: AudioCaptureError.writerUnavailable)
                    return
                }

                do {
                    guard self.outputURL == nil else {
                        throw AudioCaptureError.alreadyRecording
                    }

                    let device = try Self.captureDevice(uid: deviceUID, name: deviceName)
                    let input = try AVCaptureDeviceInput(device: device)
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        throw AudioCaptureError.unsupportedInputRoute(
                            "The selected microphone could not be added to the capture session."
                        )
                    }
                    session.addInput(input)

                    let output = AVCaptureAudioDataOutput()
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw AudioCaptureError.writerUnavailable
                    }
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.captureQueue)
                    session.commitConfiguration()

                    self.stateLock.lock()
                    self.outputURL = url
                    self.session = session
                    self.dataOutput = output
                    self.didReceiveFirstBuffer = false
                    self.writeError = nil
                    self.stateLock.unlock()

                    self.installSessionObservers(session)
                    session.startRunning()
                    guard session.isRunning else {
                        self.removeSessionObservers()
                        self.clearState()
                        throw AudioCaptureError.captureStartupTimedOut(
                            "The selected microphone did not start."
                        )
                    }

                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func waitForFirstBuffer(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if stateLock.withLock({ didReceiveFirstBuffer }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return stateLock.withLock { didReceiveFirstBuffer }
    }

    public func stop() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: AudioCaptureError.notRecording)
                    return
                }

                self.stateLock.lock()
                guard let url = self.outputURL else {
                    self.stateLock.unlock()
                    continuation.resume(throwing: AudioCaptureError.notRecording)
                    return
                }
                let session = self.session
                let writer = self.writer
                let writerInput = self.writerInput
                let writeError = self.writeError
                self.stateLock.unlock()

                self.removeSessionObservers()
                self.dataOutput?.setSampleBufferDelegate(nil, queue: nil)
                session?.stopRunning()
                writerInput?.markAsFinished()

                guard let writer else {
                    self.clearState()
                    if let writeError {
                        continuation.resume(throwing: writeError)
                    } else {
                        continuation.resume(returning: url)
                    }
                    return
                }

                writer.finishWriting { [weak self] in
                    let status = writer.status
                    let error = writer.error ?? writeError
                    self?.clearState()
                    if status == .failed || status == .cancelled {
                        continuation.resume(throwing: error ?? AudioCaptureError.writerUnavailable)
                    } else {
                        continuation.resume(returning: url)
                    }
                }
            }
        }
    }

    private func configureWriter(for sampleBuffer: CMSampleBuffer, url: URL) throws {
        guard writer == nil else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw AudioCaptureError.writerUnavailable
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: streamDescription.pointee.mSampleRate,
            AVNumberOfChannelsKey: Int(streamDescription.pointee.mChannelsPerFrame),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw AudioCaptureError.writerUnavailable
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? AudioCaptureError.writerUnavailable
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        self.writer = writer
        self.writerInput = input
    }

    private func markFirstBufferReceived() {
        stateLock.withLock {
            didReceiveFirstBuffer = true
        }
    }

    private func clearState() {
        stateLock.lock()
        session = nil
        dataOutput = nil
        writer = nil
        writerInput = nil
        outputURL = nil
        writeError = nil
        stateLock.unlock()
    }

    private func installSessionObservers(_ session: AVCaptureSession) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
    }

    private func removeSessionObservers() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        onInterruption?("Microphone capture was interrupted by an audio-device change.")
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?
            .localizedDescription ?? "unknown capture error"
        onInterruption?("Microphone capture reported: \(message)")
    }

    private static func captureDevice(uid: String?, name: String?) throws -> AVCaptureDevice {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        if uid != nil || name != nil {
            if let index = bestMatchingDeviceIndex(
                requestedUID: uid,
                requestedName: name,
                candidates: devices.map { (uid: $0.uniqueID, name: $0.localizedName) }
            ) {
                return devices[index]
            }
            throw AudioCaptureError.unsupportedInputRoute(
                "The selected microphone is not ready in AVFoundation yet."
            )
        }
        if let defaultDevice = AVCaptureDevice.default(for: .audio) {
            return defaultDevice
        }
        throw AudioCaptureError.unsupportedInputRoute("No microphone input device is available.")
    }

    static func bestMatchingDeviceIndex(
        requestedUID: String?,
        requestedName: String?,
        candidates: [(uid: String, name: String)]
    ) -> Int? {
        if let requestedUID,
           let index = candidates.firstIndex(where: { $0.uid == requestedUID }) {
            return index
        }
        if let requestedUID {
            let normalized = normalizedDeviceIdentifier(requestedUID)
            if let index = candidates.firstIndex(where: {
                normalizedDeviceIdentifier($0.uid) == normalized
            }) {
                return index
            }
        }
        if let requestedName,
           let index = candidates.firstIndex(where: {
               $0.name.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
           }) {
            return index
        }
        return nil
    }

    private static func normalizedDeviceIdentifier(_ value: String) -> String {
        var value = value.lowercased()
        for suffix in [":input", ":output"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return String(value.filter { $0.isLetter || $0.isNumber })
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

extension MicrophoneRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        stateLock.lock()
        guard let url = outputURL else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        do {
            try configureWriter(for: sampleBuffer, url: url)
            guard let writerInput, writerInput.isReadyForMoreMediaData else { return }
            guard writerInput.append(sampleBuffer) else {
                throw writer?.error ?? AudioCaptureError.writerUnavailable
            }
            markFirstBufferReceived()
            onAudioLevel?(Self.audioLevel(in: sampleBuffer))
        } catch {
            stateLock.lock()
            writeError = error
            stateLock.unlock()
            onAudioLevel?(0)
        }
    }

    private static func audioLevel(in sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0
        }

        var neededSize = 0
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, neededSize > 0 else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: neededSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let audioBufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: neededSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr else {
            return 0
        }

        var sum: Double = 0
        var sampleCount = 0
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            if isFloat, asbd.pointee.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let values = data.assumingMemoryBound(to: Float.self)
                for index in stride(from: 0, to: count, by: 16) {
                    let value = Double(values[index])
                    sum += value * value
                    sampleCount += 1
                }
            } else if asbd.pointee.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let values = data.assumingMemoryBound(to: Int16.self)
                for index in stride(from: 0, to: count, by: 16) {
                    let value = Double(values[index]) / Double(Int16.max)
                    sum += value * value
                    sampleCount += 1
                }
            }
        }
        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(sum / Double(sampleCount)))
    }
}

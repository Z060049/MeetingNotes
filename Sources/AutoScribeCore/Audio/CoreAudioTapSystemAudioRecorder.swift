import AVFoundation
import CoreAudio
import Foundation

@available(macOS 14.2, *)
public final class CoreAudioTapSystemAudioRecorder: SystemAudioRecording, @unchecked Sendable {
    public let backendName = SystemAudioBackend.coreAudioTap.rawValue
    public var onAudioLevel: ((Float) -> Void)?

    private let ioQueue = DispatchQueue(label: "com.autoscribe.core-audio-tap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?
    private var outputURL: URL?
    private let statsLock = NSLock()
    private var buffersReceived = 0
    private var framesReceived = 0
    private var bytesReceived = 0
    private var writeErrors = 0

    public var diagnosticSummary: String? {
        statsLock.lock()
        defer { statsLock.unlock() }
        return "Core Audio Tap buffers: \(buffersReceived), frames: \(framesReceived), bytes: \(bytesReceived), write errors: \(writeErrors)"
    }

    public init() {}

    public func start(in directory: URL, filename: String = "system-audio.wav") async throws -> URL {
        guard outputURL == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)

        do {
            let tapUUID = UUID()
            let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            tapDescription.uuid = tapUUID
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted

            var tapID = AudioObjectID(kAudioObjectUnknown)
            try Self.check(
                AudioHardwareCreateProcessTap(tapDescription, &tapID),
                operation: "AudioHardwareCreateProcessTap"
            )
            self.tapID = tapID

            var streamDescription = try Self.streamDescription(forTap: tapID)
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw AudioCaptureError.systemAudioBackendUnavailable("Core Audio tap returned an unsupported audio format.")
            }

            let aggregateDeviceID = try Self.createAggregateDevice(tapUUID: tapUUID)
            self.aggregateDeviceID = aggregateDeviceID

            let settings: [String: Any] = [
                AVFormatIDKey: streamDescription.mFormatID,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount)
            ]
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: format.isInterleaved
            )
            self.audioFile = file
            self.audioFormat = format
            self.outputURL = url
            resetStats()

            var ioProcID: AudioDeviceIOProcID?
            let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, ioQueue) { [weak self] _, inputData, _, _, _ in
                self?.handle(inputData: inputData)
            }
            try Self.check(ioStatus, operation: "AudioDeviceCreateIOProcIDWithBlock for aggregate device \(aggregateDeviceID)")
            guard let ioProcID else {
                throw AudioCaptureError.systemAudioBackendUnavailable("Core Audio did not return an IO process identifier.")
            }
            self.ioProcID = ioProcID

            try Self.check(AudioDeviceStart(aggregateDeviceID, ioProcID), operation: "AudioDeviceStart for aggregate device \(aggregateDeviceID)")
            return url
        } catch {
            cleanup()
            throw error
        }
    }

    public func stop() async throws -> URL {
        guard let outputURL else {
            throw AudioCaptureError.notRecording
        }

        cleanup()
        return outputURL
    }

    private func handle(inputData: UnsafePointer<AudioBufferList>) {
        guard let audioFormat, let audioFile else {
            return
        }

        let bytes = Self.byteCount(in: inputData)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            bufferListNoCopy: inputData,
            deallocator: nil
        ) else {
            return
        }

        do {
            try audioFile.write(from: buffer)
            recordBuffer(frameCount: Int(buffer.frameLength), byteCount: bytes, writeFailed: false)
            onAudioLevel?(buffer.rootMeanSquarePower)
        } catch {
            recordBuffer(frameCount: Int(buffer.frameLength), byteCount: bytes, writeFailed: true)
            onAudioLevel?(0)
        }
    }

    private func resetStats() {
        statsLock.lock()
        buffersReceived = 0
        framesReceived = 0
        bytesReceived = 0
        writeErrors = 0
        statsLock.unlock()
    }

    private func recordBuffer(frameCount: Int, byteCount: Int, writeFailed: Bool) {
        statsLock.lock()
        buffersReceived += 1
        framesReceived += frameCount
        bytesReceived += byteCount
        if writeFailed {
            writeErrors += 1
        }
        statsLock.unlock()
    }

    private func cleanup() {
        if let ioProcID, aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }

        if aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }

        ioProcID = nil
        aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        audioFile = nil
        audioFormat = nil
        outputURL = nil
    }

    private static func streamDescription(forTap tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription),
            operation: "AudioObjectGetPropertyData(kAudioTapPropertyFormat)"
        )

        return streamDescription
    }

    private static func createAggregateDevice(tapUUID: UUID) throws -> AudioDeviceID {
        let outputDeviceID = try defaultOutputDeviceID()
        let outputDeviceUID = try deviceUID(for: outputDeviceID)
        let outputDeviceName = deviceName(for: outputDeviceID) ?? "unknown"
        let outputDescription = "\(outputDeviceName) (uid: \(outputDeviceUID))"
        let aggregateUID = "com.autoscribe.dev.system-audio.\(UUID().uuidString)"

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AutoScribe System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID),
            operation: "AudioHardwareCreateAggregateDevice for output \(outputDescription)"
        )
        return aggregateDeviceID
    }

    private static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
            operation: "AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultSystemOutputDevice)"
        )
        return deviceID
    }

    private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid),
            operation: "AudioObjectGetPropertyData(kAudioDevicePropertyDeviceUID) for output device \(deviceID)"
        )
        return uid as String
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)

        guard status == noErr else {
            return nil
        }

        return name as String
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            if status == kAudioHardwareIllegalOperationError {
                throw AudioCaptureError.systemAudioPermissionDenied
            }
            throw AudioCaptureError.coreAudioError(operation: operation, status: status)
        }
    }

    private static func byteCount(in audioBufferList: UnsafePointer<AudioBufferList>) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        return buffers.reduce(0) { total, buffer in
            total + Int(buffer.mDataByteSize)
        }
    }
}

private extension AVAudioPCMBuffer {
    var rootMeanSquarePower: Float {
        guard let channelData = floatChannelData, frameLength > 0 else {
            return 0
        }

        let frameCount = Int(frameLength)
        let channelCount = Int(format.channelCount)
        let frameStride = 16
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

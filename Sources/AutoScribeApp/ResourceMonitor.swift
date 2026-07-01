import AutoScribeCore
import Combine
import Foundation

@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var cpuPercent: Double = 0
    @Published private(set) var peakCPUPercent: Double = 0
    @Published private(set) var averageCPUPercent: Double = 0
    @Published private(set) var memoryBytes: UInt64 = 0
    @Published private(set) var peakMemoryBytes: UInt64 = 0

    private var timer: Timer?
    private var cpuSum: Double = 0
    private var sampleCount: Int = 0

    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
        resetStats()
        sample()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func resetStats() {
        cpuPercent = 0
        peakCPUPercent = 0
        averageCPUPercent = 0
        memoryBytes = 0
        peakMemoryBytes = 0
        cpuSum = 0
        sampleCount = 0
    }

    private func sample() {
        let usage = ResourceUsageSampler.sample()
        cpuPercent = usage.cpuPercent
        memoryBytes = usage.memoryBytes

        peakCPUPercent = max(peakCPUPercent, usage.cpuPercent)
        peakMemoryBytes = max(peakMemoryBytes, usage.memoryBytes)
        cpuSum += usage.cpuPercent
        sampleCount += 1
        averageCPUPercent = sampleCount > 0 ? cpuSum / Double(sampleCount) : 0
    }

    var cpuText: String {
        String(format: "%.1f%%", cpuPercent)
    }

    var averageCPUText: String {
        String(format: "%.1f%%", averageCPUPercent)
    }

    var peakCPUText: String {
        String(format: "%.1f%%", peakCPUPercent)
    }

    var memoryText: String {
        Self.megabytes(memoryBytes)
    }

    var peakMemoryText: String {
        Self.megabytes(peakMemoryBytes)
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

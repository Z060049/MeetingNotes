import AppKit
import AutoScribeCore
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var controller: AutoScribeController
    @StateObject private var resourceMonitor = ResourceMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Diagnostics")
                    .font(.headline)
                Spacer()
                Button("Copy Validation Report") {
                    copyValidationReport()
                }
                Button("Copy") {
                    copyDiagnostics()
                }
                Button("Open Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([PersistentDiagnosticLog.shared.logURL])
                }
                Button("Crash Reports") {
                    try? FileManager.default.createDirectory(
                        at: CrashLogManager.shared.reportDirectoryURL,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(CrashLogManager.shared.reportDirectoryURL)
                }
                Button("Clear") {
                    controller.clearDiagnostics()
                }
            }

            resourceMonitorSection

            if controller.diagnostics.isEmpty {
                Text("No diagnostic events yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(controller.diagnostics) { event in
                            Text(event.formatted)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: event.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(height: 160)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var resourceMonitorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("CPU / Memory testing", isOn: Binding(
                    get: { resourceMonitor.isRunning },
                    set: { isOn in isOn ? resourceMonitor.start() : resourceMonitor.stop() }
                ))
                .font(.caption)
                .toggleStyle(.switch)

                Spacer()

                if resourceMonitor.isRunning {
                    Button("Reset") {
                        resourceMonitor.resetStats()
                    }
                    .font(.caption)
                }
            }

            if resourceMonitor.isRunning {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU   cur \(resourceMonitor.cpuText)   avg \(resourceMonitor.averageCPUText)   max \(resourceMonitor.peakCPUText)")
                    Text("Mem   cur \(resourceMonitor.memoryText)   peak \(resourceMonitor.peakMemoryText)")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                Text("Tip: to capture recording usage, turn this on, close this window, record/speak, then reopen to read avg/max (keeping the window open adds CPU).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyDiagnostics() {
        let text = controller.diagnostics.map(\.formatted).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyValidationReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.validationReportText(), forType: .string)
    }

    private func color(for level: DiagnosticEvent.Level) -> Color {
        switch level {
        case .info:
            .primary
        case .warning:
            .orange
        case .error:
            .red
        }
    }
}

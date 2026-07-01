import AppKit
import AutoScribeCore
import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var controller: AutoScribeController
    @State private var showingSettings = false
    @State private var showingDiagnostics = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !controller.settings.hasAcceptedConsentChecklist {
                ConsentChecklistView(controller: controller)
            } else {
                controls
            }

            if let error = controller.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("Settings") {
                showingSettings = true
            }

            DisclosureGroup("Debug", isExpanded: $showingDiagnostics) {
                DiagnosticsView(controller: controller)
                    .padding(.top, 6)
            }

            Button("Quit AutoScribe") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 460)
        .sheet(isPresented: $showingSettings) {
            SettingsView(controller: controller)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: controller.state.menuBarSymbolName)
                .foregroundStyle(controller.state.isRecording ? .red : .primary)
            VStack(alignment: .leading) {
                Text("AutoScribe")
                    .font(.headline)
                Text(controller.state.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(controller.state.isRecording ? "Stop Recording" : "Start Recording") {
                controller.toggleRecording()
            }
            .keyboardShortcut(.defaultAction)

            if case .complete(let url) = controller.state {
                Text("Saved: \(url.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button("Open Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

}

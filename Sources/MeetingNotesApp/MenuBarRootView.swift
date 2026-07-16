import AppKit
import MeetingNotesCore
import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var controller: MeetingNotesController
    private let onOpenOnboarding: () -> Void
    private let onPreferredSizeChange: () -> Void
    @State private var showingSettings = false
    @State private var showingDiagnostics = false

    init(
        controller: MeetingNotesController,
        onOpenOnboarding: @escaping () -> Void = {},
        onPreferredSizeChange: @escaping () -> Void = {}
    ) {
        _controller = ObservedObject(wrappedValue: controller)
        self.onOpenOnboarding = onOpenOnboarding
        self.onPreferredSizeChange = onPreferredSizeChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if controller.isSetupComplete {
                controls
            } else {
                setupRequired
            }

            if let routeMessage = controller.routeTransitionMessage {
                Label(routeMessage, systemImage: "wave.3.right")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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

            Button("Quit MeetingNotes") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                controller: controller,
                onOpenOnboarding: {
                    showingSettings = false
                    onOpenOnboarding()
                }
            )
        }
        .onChange(of: showingDiagnostics) {
            onPreferredSizeChange()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: controller.state.menuBarSymbolName)
                .foregroundStyle(controller.state.isRecording ? .red : .primary)
            VStack(alignment: .leading) {
                Text("MeetingNotes")
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

    private var setupRequired: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Finish setup before recording", systemImage: "checklist")
                .font(.headline)
            Text("Choose a processing mode, finish its setup, and grant Microphone and Screen & System Audio Recording access.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Finish Setup") {
                onOpenOnboarding()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

}

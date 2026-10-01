import AppKit
import MeetingNotesCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: MeetingNotesController
    private let onOpenOnboarding: () -> Void
    private let onClose: () -> Void

    @State private var settings: AppSettings
    @State private var statusMessage: String?
    @State private var groqAPIKey = ""
    @State private var groqKeyError: String?

    init(
        controller: MeetingNotesController,
        onOpenOnboarding: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.onOpenOnboarding = onOpenOnboarding
        self.onClose = onClose
        _settings = State(initialValue: controller.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2)
                .bold()

            GroupBox("Groq Transcription") {
                groqSection.padding(4)
            }

            GroupBox("Recording") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Prompt to stop after silence",
                        isOn: $settings.shouldPromptAfterSilence
                    )
                    HStack {
                        Text("After")
                        TextField("Seconds", value: $settings.inactivityTimeoutSeconds, format: .number)
                            .frame(width: 80)
                        Text("seconds of silence")
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!settings.shouldPromptAfterSilence)
                    Toggle("Show consent reminder before capture", isOn: $settings.shouldShowConsentReminder)
                }
                .padding(4)
            }

            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Each recording creates one unmodified raw transcript Markdown file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(settings.outputDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Button("Choose Folder") {
                        chooseOutputFolder()
                    }
                }
                .padding(4)
            }

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    permissionRow("Microphone", state: controller.permissionSnapshot.microphone)
                    permissionRow(
                        "Screen & System Audio Recording",
                        state: controller.permissionSnapshot.screenCapture
                    )
                    Button("Review Permissions") {
                        onOpenOnboarding()
                    }
                }
                .padding(4)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            settings = controller.settings
            statusMessage = nil
        }
    }

    private var groqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Groq transcribes audio in the cloud using whisper-large-v3-turbo. No summary is generated.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if controller.hasGroqAPIKey {
                HStack {
                    Label("API key saved in Keychain", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Remove") {
                        do {
                            try controller.deleteGroqAPIKey()
                            groqKeyError = nil
                        } catch {
                            groqKeyError = error.localizedDescription
                        }
                    }
                }
            } else {
                HStack {
                    SecureField("Paste GROQ_API_KEY", text: $groqAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Key") {
                        do {
                            try controller.saveGroqAPIKey(groqAPIKey)
                            groqAPIKey = ""
                            groqKeyError = nil
                        } catch {
                            groqKeyError = error.localizedDescription
                        }
                    }
                    .disabled(groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Link("Create a Groq API key", destination: URL(string: "https://console.groq.com/keys")!)
                .font(.caption)

            if let groqKeyError {
                Text(groqKeyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func permissionRow(_ title: String, state: PermissionState) -> some View {
        HStack {
            Image(systemName: state.isAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(state.isAuthorized ? .green : .orange)
            Text(title)
            Spacer()
            Text(state.isAuthorized ? "Granted" : "Needs attention")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDirectory = url
        }
    }

    private func save() {
        settings.inactivityTimeoutSeconds = max(10, settings.inactivityTimeoutSeconds)
        controller.updateSettings(settings)
        statusMessage = "Settings saved."
        onClose()
    }
}

import AppKit
import MeetingNotesCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: MeetingNotesController
    @ObservedObject private var localModelManager: LocalModelManager
    private let onOpenOnboarding: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var settings: AppSettings
    @State private var statusMessage: String?
    @State private var whisperError: String?
    @State private var mlxError: String?
    @State private var groqAPIKey = ""
    @State private var groqKeyError: String?

    init(
        controller: MeetingNotesController,
        onOpenOnboarding: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.localModelManager = controller.localModelManager
        self.onOpenOnboarding = onOpenOnboarding
        _settings = State(initialValue: controller.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2)
                .bold()

            GroupBox("Processing") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Mode", selection: $settings.processingMode) {
                        Text("Groq API (Recommended)").tag(ProcessingMode.api)
                        Text("Local").tag(ProcessingMode.local)
                    }
                    .pickerStyle(.segmented)

                    if settings.processingMode == .local {
                        localModeSection
                    } else {
                        groqModeSection
                    }
                }
                .padding(4)
            }

            // MARK: Summary depth
            GroupBox("Transcription") {
                Picker("Summary Depth", selection: $settings.summaryDepth) {
                    ForEach(SummaryDepth.allCases, id: \.self) { depth in
                        Text(depth.rawValue.capitalized).tag(depth)
                    }
                }
                .padding(4)
            }

            // MARK: Inactivity
            GroupBox("Recording") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Prompt after silence")
                        TextField("Seconds", value: $settings.inactivityTimeoutSeconds, format: .number)
                            .frame(width: 80)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Show consent reminder before capture", isOn: $settings.shouldShowConsentReminder)
                }
                .padding(4)
            }

            // MARK: Output folder
            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 6) {
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
                    permissionRow(
                        "Microphone",
                        state: controller.permissionSnapshot.microphone
                    )
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
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Local mode section

    @ViewBuilder
    private var localModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Summarization tier badge
            HStack(spacing: 6) {
                Image(systemName: tierIconName)
                    .foregroundStyle(tierIconColor)
                Text(localModelManager.summarizationTier.rawValue)
                    .font(.callout.weight(.medium))
            }

            if localModelManager.summarizationTier == .unavailable {
                Text("Local processing requires Apple Silicon. Switch to API mode or use an Apple Silicon Mac.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // MLX model download (Tier 2 only)
            if localModelManager.summarizationTier == .mlx {
                mlxModelRow
            }

            Divider()

            // Whisper model picker + download
            whisperModelRow
        }
    }

    private var groqModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Groq processes audio and transcript text in the cloud. Its free tier is rate-limited.")
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

    @ViewBuilder
    private var whisperModelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speech recognition model (Whisper)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Whisper model", selection: $settings.whisperModel) {
                ForEach(WhisperModelSize.allCases, id: \.self) { size in
                    Text(size.displayName).tag(size)
                }
            }

            HStack(spacing: 8) {
                whisperStateView
                if localModelManager.whisperDownloadState != .ready {
                    Button("Download") {
                        Task {
                            whisperError = nil
                            do {
                                try await controller.localModelManager.prepareWhisperModel(settings.whisperModel)
                            } catch {
                                whisperError = error.localizedDescription
                            }
                        }
                    }
                    .disabled(isWhisperDownloading)
                }
            }

            if let err = whisperError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var mlxModelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Language model for summaries (MLX)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("HuggingFace model ID", text: $settings.localLLMModel)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Text("Default: Qwen2.5-0.5B (~300 MB). For better quality try Qwen2.5-1.5B-Instruct-4bit (~900 MB).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                mlxStateView
                if localModelManager.mlxDownloadState != .ready {
                    Button("Download (~\(mlxModelSizeHint))") {
                        Task {
                            mlxError = nil
                            do {
                                try await controller.localModelManager.prepareMLXModel(modelID: settings.localLLMModel)
                            } catch {
                                mlxError = error.localizedDescription
                            }
                        }
                    }
                    .disabled(isMLXDownloading)
                }
            }

            if let err = mlxError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - State views

    @ViewBuilder
    private var whisperStateView: some View {
        stateLabel(for: localModelManager.whisperDownloadState, label: "Whisper")
    }

    @ViewBuilder
    private var mlxStateView: some View {
        stateLabel(for: localModelManager.mlxDownloadState, label: "Model")
    }

    @ViewBuilder
    private func stateLabel(for state: ModelDownloadState, label: String) -> some View {
        switch state {
        case .notDownloaded:
            Label("Not downloaded", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("\(label) ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let msg):
            Label("Failed", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .help(msg)
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

    // MARK: - Helpers

    private var tierIconName: String {
        switch localModelManager.summarizationTier {
        case .appleIntelligence: return "brain"
        case .mlx:               return "cpu"
        case .unavailable:       return "exclamationmark.triangle"
        }
    }

    private var tierIconColor: Color {
        switch localModelManager.summarizationTier {
        case .appleIntelligence: return .accentColor
        case .mlx:               return .orange
        case .unavailable:       return .red
        }
    }

    private var isWhisperDownloading: Bool {
        if case .downloading = localModelManager.whisperDownloadState { return true }
        if case .loading = localModelManager.whisperDownloadState { return true }
        return false
    }

    private var isMLXDownloading: Bool {
        if case .downloading = localModelManager.mlxDownloadState { return true }
        if case .loading = localModelManager.mlxDownloadState { return true }
        return false
    }

    private var mlxModelSizeHint: String {
        let id = settings.localLLMModel.lowercased()
        if id.contains("0.5b") { return "~300 MB" }
        if id.contains("1.5b") { return "~900 MB" }
        if id.contains("3b")   { return "~1.8 GB" }
        if id.contains("phi-3.5") || id.contains("phi-3-mini") { return "~2 GB" }
        return "large"
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
        settings.hasSelectedProcessingMode = true
        controller.updateSettings(settings)
        statusMessage = "Settings saved."
        dismiss()
    }
}

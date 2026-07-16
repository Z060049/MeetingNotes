import MeetingNotesCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: MeetingNotesController
    @ObservedObject private var localModelManager: LocalModelManager
    let onFinish: () -> Void
    let onRestart: () -> Void

    @State private var flow: OnboardingFlowState
    @State private var understandsConsent = false
    @State private var understandsIndicator = false
    @State private var selectedProcessingMode: ProcessingMode
    @State private var groqAPIKey = ""
    @State private var processingError: String?

    init(
        controller: MeetingNotesController,
        onFinish: @escaping () -> Void,
        onRestart: @escaping () -> Void
    ) {
        self.controller = controller
        self.localModelManager = controller.localModelManager
        self.onFinish = onFinish
        self.onRestart = onRestart
        _selectedProcessingMode = State(initialValue: controller.settings.processingMode)
        _flow = State(
            initialValue: OnboardingFlowState(
                settings: controller.settings,
                permissions: controller.permissionSnapshot,
                isProcessingReady: controller.isProcessingSetupReady
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, 24)

            Group {
                switch flow.step {
                case .welcome:
                    welcomeStep
                case .consent:
                    consentStep
                case .processing:
                    processingStep
                case .microphone:
                    microphoneStep
                case .systemAudio:
                    systemAudioStep
                case .restart:
                    restartStep
                case .ready:
                    readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 56)
            .padding(.vertical, 24)

            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 720, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: controller.permissionSnapshot) {
            if flow.step == .restart,
               controller.permissionSnapshot.screenCapture.isAuthorized {
                flow.move(to: .ready)
            }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= flow.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.22))
                    .frame(width: step == flow.step ? 24 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: flow.step)
        .accessibilityLabel("Onboarding step \(flow.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    private var welcomeStep: some View {
        stepLayout(
            symbol: "waveform.and.mic",
            title: "Your meeting notes, from any meeting app",
            message: "MeetingNotes records your voice and your Mac's audio, then turns the conversation into searchable Markdown notes."
        ) {
            VStack(spacing: 10) {
                benefitRow(symbol: "rectangle.3.group.bubble", text: "Works with Zoom, Google Meet, Teams, and more")
                benefitRow(symbol: "cpu", text: "Choose fast Groq API or private local processing")
                benefitRow(symbol: "doc.text", text: "Creates summaries, action items, and transcripts")
            }
            .frame(maxWidth: 470)
        }
    }

    private var consentStep: some View {
        stepLayout(
            symbol: "person.2.badge.gearshape",
            title: "Record responsibly",
            message: "Recording laws vary by location. Only record conversations when you have the required consent."
        ) {
            VStack(spacing: 12) {
                Toggle("I understand I am responsible for obtaining consent.", isOn: $understandsConsent)
                Toggle("I understand MeetingNotes shows when recording is active.", isOn: $understandsIndicator)
            }
            .toggleStyle(.checkbox)
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 500)
        }
    }

    private var microphoneStep: some View {
        stepLayout(
            symbol: "mic.fill",
            title: "Allow microphone access",
            message: "MeetingNotes uses the microphone to capture your side of the conversation."
        ) {
            permissionCard(
                title: "Microphone",
                state: controller.permissionSnapshot.microphone
            )
        }
    }

    private var processingStep: some View {
        stepLayout(
            symbol: "cpu",
            title: "Choose how to process notes",
            message: "You can change this later in Settings."
        ) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    processingModeCard(
                        mode: .api,
                        title: "Groq API (Recommended)",
                        detail: "Fast cloud processing with a rate-limited free tier.",
                        symbol: "cloud",
                        disabled: false
                    )
                    processingModeCard(
                        mode: .local,
                        title: "Local",
                        detail: "Private, no API key. Downloads models once.",
                        symbol: "lock.macwindow",
                        disabled: localModelManager.summarizationTier == .unavailable
                    )
                }

                if selectedProcessingMode == .local {
                    localProcessingSetup
                } else {
                    groqProcessingSetup
                }

                if let processingError {
                    Text(processingError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 590)
        }
        .onAppear {
            if !controller.settings.hasSelectedProcessingMode {
                controller.selectProcessingMode(selectedProcessingMode)
            }
        }
    }

    private func processingModeCard(
        mode: ProcessingMode,
        title: String,
        detail: String,
        symbol: String,
        disabled: Bool
    ) -> some View {
        Button {
            processingError = nil
            selectedProcessingMode = mode
            controller.selectProcessingMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                    Text(title).fontWeight(.semibold)
                    Spacer()
                    if selectedProcessingMode == mode {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(
                selectedProcessingMode == mode
                    ? Color.accentColor.opacity(0.12)
                    : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selectedProcessingMode == mode ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    @ViewBuilder
    private var localProcessingSetup: some View {
        if localModelManager.summarizationTier == .unavailable {
            Text("Local processing requires Apple Silicon. Choose Groq API on this Mac.")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    modelStateRow("Speech model", state: localModelManager.whisperDownloadState)
                    if localModelManager.summarizationTier == .mlx {
                        modelStateRow("Summary model", state: localModelManager.mlxDownloadState)
                    } else {
                        Label("Apple Intelligence ready", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Spacer()
                if !controller.isProcessingSetupReady {
                    Button("Download Models") {
                        downloadLocalModels()
                    }
                    .disabled(isDownloadingModels)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var groqProcessingSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.hasGroqAPIKey {
                HStack {
                    Label("Groq API key saved in Keychain", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Replace") {
                        try? controller.deleteGroqAPIKey()
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
                            processingError = nil
                        } catch {
                            processingError = error.localizedDescription
                        }
                    }
                    .disabled(groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Link("Create a Groq API key", destination: URL(string: "https://console.groq.com/keys")!)
                .font(.caption)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var systemAudioStep: some View {
        stepLayout(
            symbol: "macbook.and.iphone",
            title: "Capture the meeting audio",
            message: "Screen & System Audio Recording lets MeetingNotes hear people speaking through Zoom, Meet, Teams, or any other app. MeetingNotes does not save screen video."
        ) {
            VStack(spacing: 14) {
                HStack(spacing: 18) {
                    Label("Meeting app", systemImage: "person.2.wave.2")
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Label("MeetingNotes", systemImage: "doc.text")
                }
                .font(.headline)
                permissionCard(
                    title: "Screen & System Audio Recording",
                    state: controller.permissionSnapshot.screenCapture
                )
            }
        }
    }

    private var restartStep: some View {
        stepLayout(
            symbol: "arrow.clockwise.circle.fill",
            title: "Restart required",
            message: "After enabling MeetingNotes in Screen & System Audio Recording, restart the app so macOS applies the permission."
        ) {
            VStack(spacing: 14) {
                Label("System Settings → Privacy & Security → Screen & System Audio Recording", systemImage: "gear")
                    .font(.callout)
                    .padding(14)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                Text("On the next launch, MeetingNotes will verify access automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 520)
        }
    }

    private var readyStep: some View {
        stepLayout(
            symbol: "checkmark.circle.fill",
            title: "MeetingNotes is ready",
            message: "Start and stop recordings from the MeetingNotes icon in your menu bar."
        ) {
            VStack(spacing: 10) {
                permissionCard(title: "Microphone", state: controller.permissionSnapshot.microphone)
                permissionCard(
                    title: "Screen & System Audio Recording",
                    state: controller.permissionSnapshot.screenCapture
                )
            }
            .frame(maxWidth: 480)
        }
    }

    private var footer: some View {
        HStack {
            if flow.step != .welcome && flow.step != .restart {
                Button("Back") {
                    flow.goBack()
                }
            }

            Spacer()

            switch flow.step {
            case .welcome:
                primaryButton("Continue") {
                    flow.advance()
                }
            case .consent:
                primaryButton("Accept and Continue") {
                    controller.acceptConsentChecklist()
                    flow.advance()
                }
                .disabled(!understandsConsent || !understandsIndicator)
            case .processing:
                primaryButton("Continue") {
                    flow.advance()
                }
                .disabled(!controller.isProcessingSetupReady)
            case .microphone:
                microphoneAction
            case .systemAudio:
                systemAudioAction
            case .restart:
                Button("Open System Settings") {
                    controller.openScreenCaptureSettings()
                }
                primaryButton("Restart MeetingNotes") {
                    onRestart()
                }
            case .ready:
                if controller.permissionSnapshot.isReady && controller.isProcessingSetupReady {
                    primaryButton("Finish") {
                        controller.completeOnboarding()
                        if controller.isSetupComplete {
                            onFinish()
                        }
                    }
                } else {
                    primaryButton("Review Setup") {
                        if !controller.isProcessingSetupReady {
                            flow.move(to: .processing)
                        } else {
                            flow.move(
                                to: controller.permissionSnapshot.microphone.isAuthorized
                                    ? .systemAudio
                                    : .microphone
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var microphoneAction: some View {
        switch controller.permissionSnapshot.microphone {
        case .authorized:
            primaryButton("Continue") {
                flow.advance()
            }
        case .notDetermined:
            primaryButton("Allow Microphone") {
                Task {
                    await controller.requestMicrophoneAccess()
                }
            }
        case .denied, .restartRequired:
            primaryButton("Open System Settings") {
                controller.openMicrophoneSettings()
            }
        }
    }

    @ViewBuilder
    private var systemAudioAction: some View {
        if controller.permissionSnapshot.screenCapture.isAuthorized {
            primaryButton("Continue") {
                flow.move(to: .ready)
            }
        } else {
            primaryButton("Enable System Audio") {
                controller.requestScreenCaptureAccess()
                flow.move(to: .restart)
            }
        }
    }

    private func stepLayout<Content: View>(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 112, height: 112)
                Image(systemName: symbol)
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            Text(title)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 570)

            content()
        }
    }

    private func permissionCard(title: String, state: PermissionState) -> some View {
        HStack {
            Image(systemName: state.isAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(state.isAuthorized ? .green : .orange)
            Text(title)
                .fontWeight(.medium)
            Spacer()
            Text(permissionLabel(state))
                .foregroundStyle(state.isAuthorized ? .green : .secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 500)
    }

    private func benefitRow(symbol: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            Text(text)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func permissionLabel(_ state: PermissionState) -> String {
        switch state {
        case .notDetermined:
            "Not granted"
        case .denied:
            "Open Settings"
        case .authorized:
            "Granted"
        case .restartRequired:
            "Restart required"
        }
    }

    private func primaryButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }

    private func downloadLocalModels() {
        processingError = nil
        Task {
            do {
                try await localModelManager.prepareWhisperModel(controller.settings.whisperModel)
                if localModelManager.summarizationTier == .mlx {
                    try await localModelManager.prepareMLXModel(modelID: controller.settings.localLLMModel)
                }
            } catch {
                processingError = error.localizedDescription
            }
        }
    }

    private func modelStateRow(_ title: String, state: ModelDownloadState) -> some View {
        HStack(spacing: 6) {
            switch state {
            case .notDownloaded:
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                Text("\(title): not downloaded")
            case .downloading(let progress):
                ProgressView(value: progress).frame(width: 70)
                Text("\(title): \(Int(progress * 100))%")
            case .loading:
                ProgressView().controlSize(.small)
                Text("\(title): loading")
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(title): ready")
            case .failed:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                Text("\(title): failed")
            }
        }
        .font(.caption)
    }

    private var isDownloadingModels: Bool {
        if case .downloading = localModelManager.whisperDownloadState { return true }
        if case .loading = localModelManager.whisperDownloadState { return true }
        if case .downloading = localModelManager.mlxDownloadState { return true }
        if case .loading = localModelManager.mlxDownloadState { return true }
        return false
    }
}

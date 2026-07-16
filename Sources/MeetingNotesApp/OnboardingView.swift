import MeetingNotesCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: MeetingNotesController
    let onFinish: () -> Void
    let onRestart: () -> Void

    @State private var flow: OnboardingFlowState
    @State private var understandsConsent = false
    @State private var understandsIndicator = false

    init(
        controller: MeetingNotesController,
        onFinish: @escaping () -> Void,
        onRestart: @escaping () -> Void
    ) {
        self.controller = controller
        self.onFinish = onFinish
        self.onRestart = onRestart
        _flow = State(
            initialValue: OnboardingFlowState(
                settings: controller.settings,
                permissions: controller.permissionSnapshot
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
                benefitRow(symbol: "lock.macwindow", text: "Designed for local, private processing")
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
                if controller.permissionSnapshot.isReady {
                    primaryButton("Finish") {
                        controller.completeOnboarding()
                        onFinish()
                    }
                } else {
                    primaryButton("Review Permissions") {
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
}

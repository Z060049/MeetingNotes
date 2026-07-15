import AppKit
import MeetingNotesCore
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = MeetingNotesController()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverHostingController: NSHostingController<MenuBarRootView>?
    private var cancellables = Set<AnyCancellable>()
    private var isShowingSilenceAlert = false
    private var isShowingProcessingAlert = false
    private var previousState: AppState = .idle
    private var pendingTerminationAfterSave = false
    private let automaticTerminationReason = "MeetingNotes must remain active as a menu-bar recording app."

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(automaticTerminationReason)
        PersistentDiagnosticLog.shared.log(
            "Application launched. Automatic termination disabled. OS: \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        if let incidentURL = CrashLogManager.shared.startSession(initialState: controller.state.title) {
            PersistentDiagnosticLog.shared.log(
                "Previous session ended unexpectedly. Crash report saved to \(incidentURL.path).",
                level: .error
            )
        }
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        configureStatusItem()
        configurePopover()
        bindState()
        bindPopoverContentSize()
        bindSilencePrompt()
        bindProcessingFailure()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        PersistentDiagnosticLog.shared.log("Termination requested while state is \(controller.state.title).")
        CrashLogManager.shared.recordTerminationRequest(state: controller.state.title)

        if controller.isRecordingOrStarting {
            return handleTerminationWhileRecording(sender)
        }

        if controller.state.isProcessing {
            return handleTerminationWhileProcessing()
        }

        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        PersistentDiagnosticLog.shared.log("Application will terminate normally.")
        if let incidentURL = CrashLogManager.shared.markCleanShutdown(finalState: controller.state.title) {
            PersistentDiagnosticLog.shared.log(
                "Termination occurred without a recorded quit request. Report saved to \(incidentURL.path).",
                level: .warning
            )
        }
        ProcessInfo.processInfo.enableAutomaticTermination(automaticTerminationReason)
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageOnly
        self.statusItem = statusItem
        updateStatusItem(for: controller.state)
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit MeetingNotes",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func configurePopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        let hostingController = NSHostingController(
            rootView: MenuBarRootView(
                controller: controller,
                onPreferredSizeChange: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.resizePopoverToFit()
                    }
                }
            )
        )
        // Explicitly control the popover size. Letting preferredContentSize update
        // an NSPopover while it is transient/closed can temporarily set its height
        // to zero as SwiftUI replaces state-dependent content.
        hostingController.sizingOptions = []
        popover.contentViewController = hostingController
        self.popoverHostingController = hostingController
        self.popover = popover
        resizePopoverToFit()
    }

    private func bindState() {
        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.handleStateTransition(to: state)
                self.updateStatusItem(for: state)
                if self.popover?.isShown == true {
                    self.resizePopoverToFit()
                }
            }
            .store(in: &cancellables)
    }

    private func bindPopoverContentSize() {
        Publishers.Merge(
            controller.$routeTransitionMessage.map { _ in () },
            controller.$lastError.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            guard self?.popover?.isShown == true else { return }
            self?.resizePopoverToFit()
            DispatchQueue.main.async { [weak self] in
                self?.resizePopoverToFit()
            }
        }
        .store(in: &cancellables)
    }

    private func handleStateTransition(to state: AppState) {
        defer { previousState = state }
        if case .processing = previousState, case .complete = state {
            playCompletionSound()
        }

        if pendingTerminationAfterSave {
            switch state {
            case .complete, .failed:
                pendingTerminationAfterSave = false
                PersistentDiagnosticLog.shared.log("Pending termination continuing after recording finalization.")
                NSApp.reply(toApplicationShouldTerminate: true)
            default:
                break
            }
        }
    }

    private func handleTerminationWhileRecording(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A recording is still in progress"
        alert.informativeText = "Stop and save the recording before quitting, continue recording, or discard it."
        alert.addButton(withTitle: "Stop and Save")
        alert.addButton(withTitle: "Continue Recording")
        alert.addButton(withTitle: "Quit and Discard")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            pendingTerminationAfterSave = true
            controller.stopRecording()
            return .terminateLater
        case .alertSecondButtonReturn:
            PersistentDiagnosticLog.shared.log("Termination cancelled; recording continues.")
            return .terminateCancel
        default:
            Task { @MainActor in
                let discarded = await controller.discardRecording()
                PersistentDiagnosticLog.shared.log(
                    discarded
                        ? "Recording discarded after confirmed quit."
                        : "Recording discard failed; quitting with recovery workspace retained.",
                    level: discarded ? .info : .warning
                )
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    private func handleTerminationWhileProcessing() -> NSApplication.TerminateReply {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MeetingNotes is processing a recording"
        alert.informativeText = "Quitting now may interrupt the transcript. Recovery audio will remain available."
        alert.addButton(withTitle: "Continue Processing")
        alert.addButton(withTitle: "Quit Now")

        if alert.runModal() == .alertFirstButtonReturn {
            PersistentDiagnosticLog.shared.log("Termination cancelled; processing continues.")
            return .terminateCancel
        }

        PersistentDiagnosticLog.shared.log(
            "User confirmed termination during processing; recovery workspace retained.",
            level: .warning
        )
        return .terminateNow
    }

    private func playCompletionSound() {
        // Gentle chime to signal transcription is done, akin to Cursor's task-complete sound.
        NSSound(named: "Glass")?.play()
    }

    private func bindSilencePrompt() {
        controller.silenceDetected
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.presentSilencePrompt()
                }
            }
            .store(in: &cancellables)
    }

    @MainActor private func presentSilencePrompt() {
        guard controller.state.isRecording, !isShowingSilenceAlert else {
            return
        }
        isShowingSilenceAlert = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Still recording?"
        alert.informativeText = "MeetingNotes hasn't detected any audio for 3 minutes. Do you want to stop recording?"
        alert.addButton(withTitle: "Stop Recording")
        alert.addButton(withTitle: "Keep Recording")
        let response = alert.runModal()
        isShowingSilenceAlert = false

        if response == .alertFirstButtonReturn {
            controller.stopRecording()
        } else {
            controller.keepRecordingAfterSilence()
        }
    }

    private func bindProcessingFailure() {
        controller.processingFailed
            .receive(on: RunLoop.main)
            .sink { [weak self] failure in
                MainActor.assumeIsolated {
                    self?.presentProcessingFailure(failure)
                }
            }
            .store(in: &cancellables)
    }

    @MainActor private func presentProcessingFailure(_ failure: ProcessingFailure) {
        guard !isShowingProcessingAlert else {
            return
        }
        isShowingProcessingAlert = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't process this recording"
        alert.informativeText = failure.message
        if failure.savedAudioURL != nil {
            alert.addButton(withTitle: "Open Folder")
        }
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        isShowingProcessingAlert = false

        if response == .alertFirstButtonReturn, let url = failure.savedAudioURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func updateStatusItem(for state: AppState) {
        let label = "MeetingNotes: \(state.title)"
        statusItem?.button?.title = ""
        statusItem?.button?.toolTip = label
        statusItem?.button?.image = NSImage(
            systemSymbolName: state.menuBarSymbolName,
            accessibilityDescription: label
        )
    }

    private func resizePopoverToFit() {
        guard let popover, let hostingController = popoverHostingController else {
            return
        }

        hostingController.view.invalidateIntrinsicContentSize()
        hostingController.view.needsLayout = true
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.sizeThatFits(
            in: NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
        )
        let height = min(max(fittingSize.height, 220), 720)
        popover.contentSize = NSSize(width: 460, height: height)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            resizePopoverToFit()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Re-measure after AppKit installs the hosting view in the popover
            // window; its first off-window fitting size can be incomplete.
            Task { @MainActor [weak self] in
                self?.resizePopoverToFit()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

MainActor.assumeIsolated {
    let appDelegate = AppDelegate()
    NSApplication.shared.delegate = appDelegate
    NSApplication.shared.run()
}

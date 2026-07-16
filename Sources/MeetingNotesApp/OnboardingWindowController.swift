import AppKit
import MeetingNotesCore
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let controller: MeetingNotesController

    init(controller: MeetingNotesController) {
        self.controller = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to MeetingNotes"
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]

        super.init(window: window)

        window.contentViewController = NSHostingController(
            rootView: OnboardingView(
                controller: controller,
                onFinish: { [weak self] in
                    self?.close()
                },
                onRestart: {
                    AppRelauncher.relaunch()
                }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        controller.refreshPermissionStatus()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private enum AppRelauncher {
    static func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "sleep 1; /usr/bin/open \"$1\"",
            "meetingnotes-relaunch",
            bundlePath
        ]

        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
            NSApp.terminate(nil)
        }
    }
}

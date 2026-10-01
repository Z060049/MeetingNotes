import AppKit
import MeetingNotesCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        controller: MeetingNotesController,
        onOpenOnboarding: @escaping () -> Void
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MeetingNotes Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]

        super.init(window: window)

        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                controller: controller,
                onOpenOnboarding: { [weak self] in
                    self?.close()
                    onOpenOnboarding()
                },
                onClose: { [weak self] in
                    self?.close()
                }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else {
            return
        }
        showWindow(nil)
        window.center()
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        PersistentDiagnosticLog.shared.log(
            "Settings window presented (visible=\(window.isVisible), key=\(window.isKeyWindow))."
        )
    }
}

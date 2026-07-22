import AppKit
import SwiftUI

@MainActor
final class SettingsController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 330),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Verse"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

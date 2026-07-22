import AppKit

/// Nearly invisible menu bar item — the notch UI is the product.
/// Exists only for Settings / Quit, and to measure where the status item
/// region begins (used to cap the wing width at launch).
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let settings: SettingsController

    init(model: AppModel) {
        self.model = model
        self.settings = SettingsController(model: model)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "quote.opening", accessibilityDescription: "Verse")
            image?.isTemplate = true
            image?.accessibilityDescription = "Verse"
            button.image = image
            button.alphaValue = 0.55
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Verse", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        model.openSettings = { [weak self] in self?.settings.show() }
    }

    /// Screen X where the status-item region begins (this item's left edge).
    /// Measured at launch to cap the wing width.
    func buttonScreenMinX() -> CGFloat? {
        statusItem.button?.window?.frame.minX
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

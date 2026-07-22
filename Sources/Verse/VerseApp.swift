import AppKit

@main
enum VerseMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate // NSApplication.delegate is unowned(unsafe);
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { // keep it alive for the app's lifetime
            app.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panelController: NotchPanelController!
    private var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model

        statusItemController = StatusItemController(model: model)
        panelController = NotchPanelController(
            model: model,
            statusItemMinX: statusItemController.buttonScreenMinX()
        )

        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }
}

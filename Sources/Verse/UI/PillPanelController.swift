import AppKit
import SwiftUI

/// A panel that can take clicks (the pill is interactive) but never steals key
/// focus from the user's real work.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that passes clicks through everywhere except the current visible
/// shape (pill or popup), so the transparent rest of the full-screen panel never
/// blocks the apps behind it.
///
/// It also owns the pill DRAG at the AppKit level: SwiftUI's DragGesture proved
/// unreliable under the tap/contextMenu stack (the drag never fired on real
/// hardware), and raw mouse tracking cannot be eaten by gesture composition.
/// A press that lands on the pill arms tracking; once it moves past 3pt the
/// events are consumed (SwiftUI's pending taps never complete) and the deltas
/// drive the model. Presses in the popup state are never armed, so the popup's
/// own SwiftUI gestures (scrubber, seek) are untouched.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    /// Interactive shape in this view's OWN coordinates. NSHostingView is
    /// FLIPPED (verified empirically 2026-07-25: a click on the pill arrives
    /// with y measured from the TOP), so this rect is in panel top-left space
    /// — the same space `PillLayout.pillFrame`/`popupRect` produce, no
    /// conversion. (Using AppKit bottom-left rects here was the bug that made
    /// every pill click/drag fall through to the desktop.)
    var interactiveRect: @MainActor () -> CGRect = { .zero }

    /// True while the pill (not the popup) is showing — only then may a press
    /// arm the drag tracker.
    var isPillState: @MainActor () -> Bool = { false }
    /// While the popup is open, presses inside THIS rect (the header's note
    /// glyph — the card's grab handle) also arm the drag tracker.
    var popupGrabRect: @MainActor () -> CGRect = { .zero }
    var onPillDragBegan: @MainActor () -> Void = {}
    /// Total translation since mouse-down, in panel TOP-LEFT space.
    var onPillDragMoved: @MainActor (CGSize) -> Void = { _ in }
    var onPillDragEnded: @MainActor () -> Void = {}

    private var pressWindowPoint: NSPoint?
    private var dragging = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview.map { convert(point, from: $0) } ?? point
        guard interactiveRect().contains(p) else { return nil }
        return super.hitTest(point)
    }

    /// First click should act even when the panel isn't key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // convert(from: nil) respects isFlipped — viewPoint is top-left space,
        // matching interactiveRect.
        let viewPoint = convert(event.locationInWindow, from: nil)
        let armed = isPillState()
            ? interactiveRect().contains(viewPoint)
            : popupGrabRect().contains(viewPoint)
        if armed {
            pressWindowPoint = event.locationInWindow
            dragging = false
        }
        super.mouseDown(with: event)   // SwiftUI still sees the press (taps)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressWindowPoint else {
            super.mouseDragged(with: event)
            return
        }
        let loc = event.locationInWindow
        let dx = loc.x - press.x
        let dy = loc.y - press.y     // window space is bottom-left; flip for panel space
        if !dragging, abs(dx) > 3 || abs(dy) > 3 {
            dragging = true
            onPillDragBegan()
        }
        if dragging {
            onPillDragMoved(CGSize(width: dx, height: -dy))
            // Consumed: SwiftUI stops receiving the sequence while dragging.
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging
        dragging = false
        pressWindowPoint = nil
        if wasDragging {
            onPillDragEnded()        // consume — no tap must fire off a drag
        } else {
            super.mouseUp(with: event)
        }
    }
}

/// Owns the single full-screen transparent panel that hosts the floating pill.
/// The panel spans `screen.frame`; the pill/popup are positioned *inside* the
/// SwiftUI hierarchy by `model.pillAnchor` (the window itself never moves), and
/// `PassThroughHostingView` lets every click outside the visible shape fall
/// through to whatever app is behind it.
@MainActor
final class PillPanelController {
    private let panel: PillPanel
    private let model: AppModel
    private let layout = PillLayout()

    private var escMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var scrollMonitor: Any?

    /// `pillAnchor` at drag start — the base the drag's total translation
    /// applies to.
    private var dragAnchorBase: CGPoint?

    init(model: AppModel) {
        self.model = model
        let screen = Self.targetScreen()

        panel = PillPanel(
            contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // shadows drawn in SwiftUI on the shapes
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true

        let hosting = PassThroughHostingView(rootView: RootPillView(model: model))
        hosting.interactiveRect = { [weak self, weak model] in
            guard let self, let model else { return .zero }
            return self.interactiveRect(for: model)
        }
        // AppKit-level pill drag (see PassThroughHostingView). The base anchor
        // is captured at drag start; every move applies the TOTAL translation
        // to it, so there is no per-event accumulation drift.
        hosting.isPillState = { [weak model] in model?.uiState == .pill }
        // Grab handle while expanded: a generous zone around the header's
        // note glyph (top-right of the card, panel top-left space).
        hosting.popupGrabRect = { [weak self, weak model] in
            guard let self, let model, model.uiState == .popup else { return .zero }
            let popup = self.popupPanelRect()
            return CGRect(x: popup.maxX - 54, y: popup.minY + 4, width: 50, height: 42)
        }
        hosting.onPillDragBegan = { [weak self, weak model] in
            guard let self, let model else { return }
            self.dragAnchorBase = model.pillAnchor
            model.isDraggingPill = true
        }
        hosting.onPillDragMoved = { [weak self, weak model] delta in
            guard let self, let model, let base = self.dragAnchorBase else { return }
            model.pillAnchor = CGPoint(x: base.x + delta.width, y: base.y + delta.height)
            model.clampPillAnchor()
        }
        hosting.onPillDragEnded = { [weak self, weak model] in
            guard let self, let model else { return }
            self.dragAnchorBase = nil
            model.isDraggingPill = false
            model.snapPillToRail()
            model.endFirstRunDemo()   // the first drag retires the demo
        }
        panel.contentView = hosting

        configureGeometry(for: screen)
        panel.orderFrontRegardless()
        installMonitors()

        model.moveToScreen = { [weak self] screen in self?.move(to: screen) }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenParametersChanged() }
        }
    }

    deinit {
        for m in [escMonitor, localMouseMonitor, globalMouseMonitor, scrollMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
    }

    // MARK: - Geometry

    /// Panel = whole screen; max pill width + visible-area clamp follow the
    /// screen. The pill's ACTUAL width is dynamic (model-owned, revision A).
    private func configureGeometry(for screen: NSScreen?) {
        guard let screen else { return }
        panel.setFrame(screen.frame, display: true)

        let visible = PillLayout.visibleRectInPanelSpace(screen: screen)
        model.pillVisibleRect = visible
        model.pillMaxWidth = layout.pillMaxWidth(screen: screen)
        model.currentScreenID = screen.displayID

        // Read BEFORE anything writes the anchor: was the stored position
        // captured on some OTHER display (or by a build that recorded none)?
        let anchorIsForeign =
            model.hasStoredPillAnchor && model.pillAnchorScreenID != screen.displayID

        if !model.hasStoredPillAnchor {
            if model.isFirstRunDemo {
                // First-run moment: the demo pill appears center-screen and
                // settles wherever the user drops it.
                model.pillAnchorMode = .center
                model.pillAnchor = CGPoint(
                    x: visible.midX, y: visible.midY - layout.pillHeight / 2
                )
            } else {
                let placement = PillLayout.defaultAnchor(visible: visible)
                model.pillAnchorMode = placement.mode
                model.pillAnchor = placement.anchor
            }
        }
        // Side parking (2026-07-25): anchors persisted by earlier builds can be
        // `.center` — snap them to the nearer rail once. The first-run demo
        // keeps its center spot until the user's first drop.
        if model.hasStoredPillAnchor, model.pillAnchorMode == .center, !model.isFirstRunDemo {
            let f = layout.pillFrame(anchor: model.pillAnchor, mode: .center, width: model.pillWidth)
            let side = PillLayout.snapSide(forCenterX: f.midX, visible: visible)
            model.pillAnchorMode = side
            model.pillAnchor = CGPoint(
                x: PillLayout.railX(side: side, visible: visible, edgeMargin: layout.edgeMargin),
                y: f.minY
            )
        }
        // Panel space is per-screen, so a foreign anchor's x means a different
        // spot here — and when it lands inside this screen the clamp below is a
        // no-op, which is exactly how the pill used to reappear stranded
        // mid-screen. Re-park it on its own rail instead; the side and the
        // parked height are the parts of the choice that transfer.
        if anchorIsForeign { reparkOnRail(visible: visible) }
        model.clampPillAnchor()
        model.notePillAnchorScreen(screen.displayID)
    }

    /// Move the pill back onto the rail it is anchored to, within `visible`.
    /// The y is left to `clampPillAnchor()`.
    private func reparkOnRail(visible: CGRect) {
        guard model.pillAnchorMode != .center else { return }
        model.pillAnchor = CGPoint(
            x: PillLayout.railX(
                side: model.pillAnchorMode, visible: visible, edgeMargin: layout.edgeMargin
            ),
            y: model.pillAnchor.y
        )
    }

    /// The pill's current frame in panel space, derived from anchor/mode/width.
    private func pillPanelFrame() -> CGRect {
        layout.pillFrame(
            anchor: model.pillAnchor, mode: model.pillAnchorMode, width: model.pillWidth
        )
    }

    /// Interactive shape in the hosting view's FLIPPED (panel top-left)
    /// coordinates — pill/popup frames are used directly, no conversion.
    /// The pill (or idle ball) is always present — revision A removed `.hidden`.
    private func interactiveRect(for model: AppModel) -> CGRect {
        switch model.uiState {
        case .pill:
            return pillPanelFrame()
        case .popup:
            return pillPanelFrame().union(popupPanelRect())
        }
    }

    /// Popup rect in panel (top-left) space.
    private func popupPanelRect() -> CGRect {
        layout.popupRect(pillFrame: pillPanelFrame(), visible: model.pillVisibleRect)
    }

    /// Popup rect in SCREEN (AppKit bottom-left) coordinates — the one place
    /// that genuinely needs the flip, because `NSEvent.mouseLocation` (used by
    /// the click-outside monitors) reports global bottom-left points.
    private func popupScreenRect() -> CGRect {
        let popup = popupPanelRect()
        return PillLayout.hitRect(
            topLeft: popup.origin, size: popup.size, panelHeight: panel.frame.height
        ).offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    // MARK: - Dismissal / browse monitors (pattern: the old scroll monitor)

    private func installMonitors() {
        // Esc collapses the popup (even when pinned — it is an explicit dismiss).
        // `MainActor.assumeIsolated` returns Void (returning the non-Sendable
        // NSEvent out of it would cross an isolation boundary); the swallow
        // decision travels back via a Sendable Bool.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEsc = event.keyCode == 53
            var swallow = false
            MainActor.assumeIsolated {
                guard let self, self.model.uiState == .popup, isEsc else { return }
                self.collapse()
                swallow = true
            }
            return swallow ? nil : event
        }

        // Click outside the popup collapses it, unless pinned. Local monitor
        // handles clicks that land on our panel (e.g. the pill region beside
        // the popup); the global monitor handles clicks on other apps.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.collapseIfClickOutsidePopup() }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapseIfClickOutsidePopup() }
        }

        // Scroll inside the popup → browse the full lyrics list.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let onPanel = event.window is PillPanel
            MainActor.assumeIsolated {
                guard let self, self.model.uiState == .popup, onPanel else { return }
                if self.model.browsing { self.model.restartBrowseTimer() }
                else { self.model.enterBrowse() }
            }
            return event
        }
    }

    private func collapseIfClickOutsidePopup() {
        guard model.uiState == .popup, !model.pinned else { return }
        if !popupScreenRect().contains(NSEvent.mouseLocation) { collapse() }
    }

    /// Exhale back into the pill (the spring lives on RootPillView's uiState).
    private func collapse() {
        model.uiState = .pill
        model.exitBrowse()
    }

    // MARK: - Multi-screen

    /// UserDefaults key for the display the user explicitly parked the pill on
    /// (a `CGDirectDisplayID`). Absent until a screen is picked from the menu.
    private static let screenIDKey = "verse.screenID"

    /// Move the panel to `screen` (pill "Screen" menu) and remember the choice.
    func move(to screen: NSScreen) {
        // The card is anchored to the pill on the OLD screen; collapsing is the
        // honest way to re-anchor it (the next click reopens it in place).
        if model.uiState == .popup { collapse() }

        if let id = screen.displayID {
            UserDefaults.standard.set(id, forKey: Self.screenIDKey)
        }
        // The anchor belongs to the old screen's panel space, so
        // `configureGeometry` re-parks it on the new screen's rail and records
        // the move — same path a foreign anchor takes at launch.
        configureGeometry(for: screen)
        panel.orderFrontRegardless()
    }

    /// Displays attached/removed, rearranged, or resized (and dock/menu-bar
    /// changes, which post the same notification). Re-resolves the host screen
    /// — a disconnected preferred display falls back without being forgotten,
    /// so re-plugging it brings the pill home.
    private func screenParametersChanged() {
        guard let screen = Self.targetScreen() else { return }
        // These notifications fire in bursts and often with nothing relevant
        // changed; only re-lay-out when the panel's screen or usable area moved.
        let visible = PillLayout.visibleRectInPanelSpace(screen: screen)
        guard screen.displayID != model.currentScreenID
                || screen.frame != panel.frame
                || visible != model.pillVisibleRect
        else { return }
        configureGeometry(for: screen)
    }

    /// The screen the pill lives on: the user's picked display when attached,
    /// else the display its parked position was captured on, else the one with
    /// the active menu bar, else the first attached display.
    static func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let fallback = NSScreen.main ?? screens.first
        let defaults = UserDefaults.standard
        guard let chosen = ScreenPicker.resolve(
            preferred: (defaults.object(forKey: screenIDKey) as? NSNumber)?.uint32Value,
            anchored: defaults.string(forKey: "verse.pillAnchor")
                .flatMap(PillAnchorRecord.parse)?.screenID,
            candidates: screens.compactMap(\.displayID),
            active: NSScreen.main?.displayID
        ) else { return fallback }
        return screens.first { $0.displayID == chosen } ?? fallback
    }
}

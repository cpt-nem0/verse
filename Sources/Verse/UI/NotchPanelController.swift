import AppKit
import SwiftUI

/// Static geometry computed once at launch.
struct NotchLayout {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var leftWingWidth: CGFloat
    var rightWingWidth: CGFloat     // fixed — never resizes per line
    var expandedSize: CGSize

    /// The lyric-free gap in the middle of the compact bar: the physical notch
    /// plus 12pt of black on each side, so text never hugs the notch edges.
    var notchGap: CGFloat { notchWidth + 24 }

    var compactWidth: CGFloat { leftWingWidth + notchGap + rightWingWidth }

    /// The wings are asymmetric, but the physical notch is centered on screen.
    /// The compact shape must shift right by this much so its notch gap lands
    /// exactly on the physical notch.
    var compactOffset: CGFloat { (rightWingWidth - leftWingWidth) / 2 }

    var panelSize: CGSize {
        CGSize(width: max(expandedSize.width, compactWidth + 2 * abs(compactOffset)) + 80,
               height: expandedSize.height + 40)
    }

    static func compute(statusItemMinX: CGFloat?) -> NotchLayout {
        let screen = NotchLayout.targetScreen()
        var notchWidth: CGFloat = 196
        var notchHeight: CGFloat = 32

        if let screen {
            let inset = screen.safeAreaInsets.top
            if inset > 0 { notchHeight = inset }
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notchWidth = max(right.minX - left.maxX, 120)
            } else {
                // No physical notch: emulate a compact island.
                notchHeight = NSStatusBar.system.thickness + 8
            }
        }

        // Equal wings on both sides, sized so the compact bar matches the
        // expanded panel's width — hover-expand then grows straight down with
        // zero horizontal movement. Capped by the menu bar status items.
        // (notchWidth + 24 mirrors `notchGap` — wings shrink to make room.)
        let expandedWidth: CGFloat = 520
        var wing = ((expandedWidth - (notchWidth + 24)) / 2).rounded()
        if let screen, let statusMinX = statusItemMinX {
            let notchRightX = screen.frame.midX + notchWidth / 2
            let available = statusMinX - notchRightX
            if available > 60 { wing = min(wing, (available * 0.40).rounded()) }
        }
        wing = max(wing, 120)

        return NotchLayout(
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            leftWingWidth: wing,
            rightWingWidth: wing,
            expandedSize: CGSize(width: expandedWidth, height: 244)
        )
    }

    static func targetScreen() -> NSScreen? {
        // Prefer the built-in (notched) display.
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}

/// Hosting view that passes clicks through everywhere except the current
/// visible shape, so the transparent parts of the panel never block the
/// menu bar.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: @MainActor () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview.map { convert(point, from: $0) } ?? point
        guard interactiveRect().contains(p) else { return nil }
        return super.hitTest(point)
    }

    /// First click should act even when the panel isn't key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController {
    private let panel: NotchPanel
    private let model: AppModel
    private let layout: NotchLayout
    private var scrollMonitor: Any?

    init(model: AppModel, statusItemMinX: CGFloat?) {
        self.model = model
        let layout = NotchLayout.compute(statusItemMinX: statusItemMinX)
        self.layout = layout
        // Chunk width budget: each wing loses 16pt outer + 12pt inner padding.
        model.wingTextWidth = layout.leftWingWidth - 28

        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: layout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window shadow — it draws a border-like glow around the compact
        // wings that breaks the illusion of being part of the notch. Vibe mode
        // gets a SwiftUI shadow on its shape instead.
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true

        let root = RootNotchView(model: model, layout: layout)
        let hosting = PassThroughHostingView(rootView: root)
        hosting.interactiveRect = { [weak model] in
            guard let model else { return .zero }
            return Self.interactiveRect(for: model.uiState, layout: layout)
        }
        panel.contentView = hosting

        position()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.position() }
        }

        // Scroll inside the expanded panel → browse the full lyrics list.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak model] event in
            MainActor.assumeIsolated {
                if let model, model.uiState == .expanded, event.window is NotchPanel {
                    if model.browsing {
                        model.restartBrowseTimer()
                    } else {
                        model.enterBrowse()
                    }
                }
            }
            return event
        }
    }

    private func position() {
        guard let screen = NotchLayout.targetScreen() else { return }
        let size = layout.panelSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }

    /// Visible shape in hosting-view coordinates (origin bottom-left).
    private static func interactiveRect(for state: NotchUIState, layout: NotchLayout) -> CGRect {
        let panelSize = layout.panelSize
        switch state {
        case .hidden:
            // Keep the physical notch area hoverable? No — invisible when idle.
            return .zero
        case .compact:
            return CGRect(
                x: (panelSize.width - layout.compactWidth) / 2 + layout.compactOffset,
                y: panelSize.height - layout.notchHeight,
                width: layout.compactWidth,
                height: layout.notchHeight
            )
        case .expanded:
            return CGRect(
                x: (panelSize.width - layout.expandedSize.width) / 2,
                y: panelSize.height - layout.expandedSize.height,
                width: layout.expandedSize.width,
                height: layout.expandedSize.height
            )
        }
    }
}

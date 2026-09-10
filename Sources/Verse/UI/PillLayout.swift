import AppKit

/// Which edge of the pill stays fixed while its width follows the lyric.
/// Side parking (2026-07-25): the pill lives on the LEFT or RIGHT rail only —
/// `.leading` (parked left, grows rightward) or `.trailing` (parked right,
/// grows leftward). `.center` survives for the first-run demo's pre-drop spot;
/// no drag-drop ever produces it.
enum PillAnchorMode: String {
    case leading, center, trailing
}

/// The persisted pill position (`verse.pillAnchor`): anchor mode, the
/// panel-space anchor point, and the display that point belongs to.
///
/// The display is load-bearing. Panel space is PER-SCREEN, so an anchor on its
/// own is ambiguous: restoring one screen's coordinates on another parks the
/// pill at an arbitrary spot, and when those coordinates happen to fall inside
/// the new screen the clamp cannot catch it. Records written before
/// multi-screen support have three fields and no display; `screenID` is then
/// `nil` and the panel controller re-parks rather than trusting them.
struct PillAnchorRecord: Equatable {
    var mode: PillAnchorMode
    var anchor: CGPoint
    var screenID: CGDirectDisplayID?

    /// "mode,x,y,displayID" — or "mode,x,y" while the display is unknown.
    var stringValue: String {
        let base = "\(mode.rawValue),\(anchor.x),\(anchor.y)"
        guard let screenID else { return base }
        return "\(base),\(screenID)"
    }

    /// Parses both forms; an unparsable display field reads as unknown.
    static func parse(_ raw: String) -> PillAnchorRecord? {
        let parts = raw.split(separator: ",")
        guard parts.count == 3 || parts.count == 4,
              let mode = PillAnchorMode(rawValue: String(parts[0])),
              let x = Double(parts[1]), let y = Double(parts[2])
        else { return nil }
        return PillAnchorRecord(
            mode: mode,
            anchor: CGPoint(x: x, y: y),
            screenID: parts.count == 4 ? CGDirectDisplayID(parts[3]) : nil
        )
    }
}

/// Geometry for the floating pill + popup. Every screen-space calculation lives
/// here as a *pure* function so the coordinate math can be exercised by the
/// `--checks` runner without a live `NSScreen`.
///
/// ## Coordinate spaces (READ THIS FIRST)
///
/// Two spaces are in play and they disagree on where `Y = 0` is. Mixing them
/// up is the single easiest way to break the pill's placement, so every
/// conversion below is spelled out.
///
/// * **AppKit / screen space** — origin BOTTOM-left, `Y` grows UP.
///   `NSScreen.frame` and `NSScreen.visibleFrame` live here, and so do the
///   points delivered to `PassThroughHostingView.hitTest(_:)`.
/// * **SwiftUI panel space** — origin TOP-left, `Y` grows DOWN. The full-screen
///   panel's content view spans `screen.frame`; SwiftUI lays the pill out in
///   this space, so `AppModel.pillAnchor` (anchored-edge x + pill top y) is a
///   panel-space point.
///
/// The panel's top edge sits at AppKit `y = frame.maxY`, so converting a `Y`
/// between the two spaces is a flip about that edge:
///
///     swiftUIy = frame.maxY - appKitY          // and the reverse is identical
///
/// `X` only needs the panel's left edge subtracted (`frame.minX`), since both
/// spaces agree that `X` grows rightward.
struct PillLayout {
    var pillHeight: CGFloat = 30
    /// Wide enough that typical lyric lines render whole (fit-to-width only
    /// kicks in for genuinely long lines).
    var popupSize = CGSize(width: 560, height: 264)
    var edgeMargin: CGFloat = 12

    /// Idle-ball diameter — equals `pillHeight`, so the capsule reads as a circle.
    static let ballDiameter: CGFloat = 30

    /// Instrumental breaks contract all the way to the BALL (user decision
    /// 2026-07-25): a circle with rising note glyphs inside.
    var instrumentalWidth: CGFloat = 30

    /// The widest the pill may grow on a given screen — `min(38% of width, 460)`.
    /// Lines wider than this (minus padding) are chunked.
    func pillMaxWidth(screen: NSScreen) -> CGFloat {
        min(screen.frame.width * 0.38, 460)
    }

    /// Revision A dynamic width: the capsule hugs the displayed text.
    /// `textWidth + 32` (16pt horizontal padding each side), never narrower
    /// than the ball, never wider than `maxWidth`.
    static func pillWidth(forTextWidth textWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        min(max(textWidth + 32, ballDiameter), maxWidth)
    }

    // MARK: - Screen space → panel space

    /// `visible` (AppKit bottom-left, excludes menu bar + dock) expressed in
    /// SwiftUI panel space (top-left), given the panel spans `frame`.
    ///
    /// - The visible area's LEFT edge is `visible.minX - frame.minX` in from
    ///   the panel's left edge.
    /// - The visible area's TOP edge (AppKit `visible.maxY`) is
    ///   `frame.maxY - visible.maxY` down from the panel's top edge — this is
    ///   exactly the menu bar height when the screen has one.
    static func visibleRectInPanelSpace(frame: CGRect, visible: CGRect) -> CGRect {
        CGRect(
            x: visible.minX - frame.minX,
            y: frame.maxY - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }

    static func visibleRectInPanelSpace(screen: NSScreen) -> CGRect {
        visibleRectInPanelSpace(frame: screen.frame, visible: screen.visibleFrame)
    }

    // MARK: - Default placement

    /// First-launch anchor: parked on the RIGHT rail, just below the menu bar.
    static func defaultAnchor(visible: CGRect, edgeMargin: CGFloat = 12) -> (anchor: CGPoint, mode: PillAnchorMode) {
        (CGPoint(x: visible.maxX - edgeMargin, y: visible.minY + 8), .trailing)
    }

    // MARK: - Anchor math (side parking, 2026-07-25)

    /// AssistiveTouch-style pick-and-drop: the nearer screen half at drag-end
    /// decides the pill's side. There is no center parking.
    static func snapSide(forCenterX x: CGFloat, visible: CGRect) -> PillAnchorMode {
        x < visible.midX ? .leading : .trailing
    }

    /// The anchored-edge x for a parked side — the "rail" the pill grows from.
    static func railX(side: PillAnchorMode, visible: CGRect, edgeMargin: CGFloat) -> CGFloat {
        side == .leading ? visible.minX + edgeMargin : visible.maxX - edgeMargin
    }

    /// The pill's LEFT edge for a given anchored-edge x. The anchored edge is
    /// the one that must not move as `width` changes.
    static func leftEdge(anchorX: CGFloat, mode: PillAnchorMode, width: CGFloat) -> CGFloat {
        switch mode {
        case .leading: return anchorX
        case .center: return anchorX - width / 2
        case .trailing: return anchorX - width
        }
    }

    /// Inverse of `leftEdge`: the anchor x that puts the pill's left edge at
    /// `left` under `mode` — used to convert between modes without moving the
    /// pill (drag-end reclassification).
    static func anchorX(forLeftEdge left: CGFloat, mode: PillAnchorMode, width: CGFloat) -> CGFloat {
        switch mode {
        case .leading: return left
        case .center: return left + width / 2
        case .trailing: return left + width
        }
    }

    /// The pill's frame (panel space, top-left) for an anchor point + mode + width.
    func pillFrame(anchor: CGPoint, mode: PillAnchorMode, width: CGFloat) -> CGRect {
        CGRect(
            x: Self.leftEdge(anchorX: anchor.x, mode: mode, width: width),
            y: anchor.y,
            width: width,
            height: pillHeight
        )
    }

    /// Clamp an anchor so the WHOLE pill (at `width`, under `mode`) stays inside
    /// `visible` with `edgeMargin` breathing room: clamp the derived left edge,
    /// then convert back to an anchor x. Pure.
    func clampedAnchor(
        _ anchor: CGPoint, mode: PillAnchorMode, width: CGFloat, visible: CGRect
    ) -> CGPoint {
        let left = Self.leftEdge(anchorX: anchor.x, mode: mode, width: width)
        let minLeft = visible.minX + edgeMargin
        let maxLeft = visible.maxX - width - edgeMargin
        let clampedLeft = clampValue(left, minLeft, max(minLeft, maxLeft))
        let minY = visible.minY + edgeMargin
        let maxY = visible.maxY - pillHeight - edgeMargin
        return CGPoint(
            x: Self.anchorX(forLeftEdge: clampedLeft, mode: mode, width: width),
            y: clampValue(anchor.y, minY, max(minY, maxY))
        )
    }

    // MARK: - Panel space → AppKit bottom-left space

    /// A panel-space top-left rect (`topLeft` + `size`) expressed in AppKit
    /// bottom-left coordinates. NOT for view hit-testing — NSHostingView is
    /// flipped, so `hitTest` points arrive in panel top-left space already
    /// (verified empirically 2026-07-25). This flip is for GLOBAL screen
    /// points (`NSEvent.mouseLocation`, window frames): add the panel's
    /// screen origin after flipping. `panelHeight` = the panel's height.
    ///
    /// Only `Y` flips: the shape's TOP edge is `topLeft.y` down from the panel
    /// top, so its BOTTOM edge is `panelHeight - topLeft.y - size.height` up
    /// from the panel bottom — which is the AppKit rect origin.
    static func hitRect(topLeft: CGPoint, size: CGSize, panelHeight: CGFloat) -> CGRect {
        CGRect(
            x: topLeft.x,
            y: panelHeight - topLeft.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Popup placement

    /// The popup rect in panel space (top-left), anchored to the pill's current
    /// frame. It grows DOWN from the pill's top edge when the pill sits in the
    /// visible area's top half, else UP from the pill's bottom edge;
    /// horizontally centered on the pill and clamped to `visible` + `edgeMargin`
    /// on every edge. Pure.
    func popupRect(pillFrame: CGRect, visible: CGRect) -> CGRect {
        let size = popupSize
        let minX = visible.minX + edgeMargin
        let maxX = visible.maxX - size.width - edgeMargin
        let x = clampValue(pillFrame.midX - size.width / 2, minX, max(minX, maxX))

        let midY = visible.minY + visible.height / 2
        let growsDown = pillFrame.minY < midY
        let rawY = growsDown ? pillFrame.minY : (pillFrame.maxY - size.height)
        let minY = visible.minY + edgeMargin
        let maxY = visible.maxY - size.height - edgeMargin
        let y = clampValue(rawY, minY, max(minY, maxY))

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// File-local numeric clamp (kept off `Comparable` to avoid touching shared code).
private func clampValue(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    min(max(v, lo), hi)
}

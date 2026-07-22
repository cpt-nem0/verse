import SwiftUI

/// Bottom-rounded rectangle that reads as a continuation of the physical notch:
/// top edge flush with the screen edge, top corners flaring concavely outward
/// (like the notch itself), convex rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topFlare: CGFloat = 6

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = min(topFlare, rect.height / 3)
        let r = min(bottomRadius, (rect.height - f) / 2, rect.width / 2 - f)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Top-right concave flare into the screen edge.
        p.addArc(
            center: CGPoint(x: rect.maxX, y: rect.minY + f),
            radius: f, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r))
        p.addArc(
            center: CGPoint(x: rect.maxX - f - r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX + f + r, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.minX + f + r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.minY + f))
        // Top-left concave flare.
        p.addArc(
            center: CGPoint(x: rect.minX, y: rect.minY + f),
            radius: f, startAngle: .degrees(0), endAngle: .degrees(270), clockwise: true
        )
        p.closeSubpath()
        return p
    }
}

/// The state machine: hidden ↔ compact wings ↔ expanded vibe mode.
/// The compact lyric MORPHS into the vibe-mode current line via a shared
/// matchedGeometryEffect element — one liquid piece, not two crossfading views.
struct RootNotchView: View {
    @ObservedObject var model: AppModel
    let layout: NotchLayout

    @Namespace private var morph
    @State private var expandWork: DispatchWorkItem?
    @State private var collapseWork: DispatchWorkItem?

    private var isExpanded: Bool { model.uiState == .expanded }

    private var shapeSize: CGSize {
        switch model.uiState {
        case .hidden:
            return CGSize(width: layout.notchWidth, height: layout.notchHeight)
        case .compact:
            return CGSize(width: layout.compactWidth, height: layout.notchHeight)
        case .expanded:
            return layout.expandedSize
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if model.uiState != .hidden {
                shell
                    // Compact wings are asymmetric (small art wing left, lyric
                    // wing right) — shift so the gap sits exactly on the notch.
                    .offset(x: isExpanded ? 0 : layout.compactOffset)
                    .transition(.opacity)
            }
        }
        .frame(
            width: layout.panelSize.width,
            height: layout.panelSize.height,
            alignment: .top
        )
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.uiState)
    }

    private var shape: NotchShape {
        NotchShape(bottomRadius: isExpanded ? 26 : 9)
    }

    private var shell: some View {
        ZStack(alignment: .top) {
            shape
                .fill(isExpanded ? model.palette.background : Color.black)
                .shadow(color: .black.opacity(isExpanded ? 0.45 : 0), radius: 18, y: 6)

            // Content is clipped to the animating shape so vibe mode is
            // progressively revealed as the shape melts open — it never pops
            // in at full size.
            ZStack(alignment: .top) {
                if isExpanded {
                    VibeModeView(model: model, layout: layout, morph: morph)
                        .transition(.opacity)
                } else {
                    CompactWingView(model: model, layout: layout, morph: morph)
                        .transition(.opacity)
                }
            }
            .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: shapeSize.width, height: shapeSize.height)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoverEntered() } else { hoverExited() }
        }
    }

    // MARK: - Hover intent

    private func hoverEntered() {
        collapseWork?.cancel(); collapseWork = nil
        guard model.uiState == .compact else { return }
        expandWork?.cancel()
        let work = DispatchWorkItem { [weak model] in
            Task { @MainActor in
                if let model, model.uiState == .compact { model.uiState = .expanded }
            }
        }
        expandWork = work
        let delay = model.hoverIntentDelay ? 0.15 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hoverExited() {
        expandWork?.cancel(); expandWork = nil
        guard model.uiState == .expanded, !model.pinned, !model.scrubbing else { return }
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak model] in
            Task { @MainActor in
                guard let model else { return }
                if model.uiState == .expanded, !model.pinned, !model.scrubbing {
                    model.uiState = .compact
                    model.exitBrowse()
                }
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

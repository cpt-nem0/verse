import SwiftUI
import AppKit

/// Root of the floating-pill hierarchy: positions the pill and the popup card
/// inside the full-screen panel. Expansion is state-driven — the always-mounted
/// card scales/fades about the pill's spot when `uiState` flips (no SwiftUI
/// transitions, no matched geometry: both proved unreliable/streaky here).
///
/// ## Side parking (2026-07-25, supersedes revision A's thirds rule)
///
/// `model.pillAnchor` is the ANCHOR point (anchored-edge x + top y) on the
/// LEFT or RIGHT rail. The pill's offset is continuous math of
/// anchor/mode/width (`PillLayout.leftEdge`), and offset + width share one
/// spring — the anchored (rail) edge stays visually stationary while the
/// capsule grows inward. Drops glide to the nearer rail (`snapToRail`).
///
/// ## Battery (Task 9)
///
/// The per-frame `TimelineView` mounts ONLY while something animates: idle
/// (ball, no music) renders a static `PillView` with no timeline at all, and
/// live timelines honor `model.frameInterval` (30fps cap in Low Power Mode).
struct RootPillView: View {
    @ObservedObject var model: AppModel

    /// Quick press-bounce on double-click (1 → 0.94 → 1 spring).
    @State private var bounceScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topLeading) {
            shell
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Motion.spring(0.42, 0.86), value: model.uiState)
    }

    private var isPopup: Bool { model.uiState == .popup }

    // MARK: - The morphing shell (container transform)

    /// ONE glass shape shared by both states: its frame literally animates
    /// between the pill capsule and the popup card (position, size, corner
    /// radius, shadow all spring together on `uiState`), while the two
    /// contents crossfade inside and the clip progressively reveals the card.
    /// This is what makes expand read as "the pill itself grows".
    private var shell: some View {
        let pillFrame = model.pillLayout.pillFrame(
            anchor: model.pillAnchor, mode: model.pillAnchorMode, width: model.pillWidth
        )
        let popupRect = model.pillLayout.popupRect(pillFrame: pillFrame, visible: model.pillVisibleRect)
        let frame = isPopup ? popupRect : pillFrame
        let radius: CGFloat = isPopup ? 20 : model.pillLayout.pillHeight / 2

        return ZStack(alignment: .topLeading) {
            pillBody
                .opacity(isPopup ? 0 : 1)
                .allowsHitTesting(!isPopup)
            if model.now != nil {
                PopupView(model: model, active: isPopup)
                    .opacity(isPopup ? 1 : 0)
                    .allowsHitTesting(isPopup)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .background(
            ZStack {
                GlassBackground()
                Color.black.opacity(model.pillOpacity)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isPopup ? 0.4 : 0.25),
                radius: isPopup ? 20 : 10, y: isPopup ? 8 : 3)
        // First-run caption rides OUTSIDE the clip (overlays after clipShape
        // are not clipped), hanging just below the demo pill.
        .overlay(alignment: .top) {
            if model.isFirstRunDemo && model.now == nil {
                Text("Drag me somewhere comfy — click to open")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize()
                    .offset(y: frame.height + 10)
            }
        }
        .scaleEffect(bounceScale)
        .contentShape(Rectangle())
        .contextMenu { PillContextMenu(model: model) }
        // In popup state the shell's own taps are OFF (`.subviews`) so the
        // card's buttons/scrubber receive every click; in pill state the
        // shell claims taps for expand / double-click play-pause.
        .gesture(
            ExclusiveGesture(
                TapGesture(count: 2).onEnded {
                    guard model.uiState == .pill, model.now != nil else { return }
                    model.togglePlayPause()
                    triggerBounce()
                },
                TapGesture(count: 1).onEnded { expand() }
            ),
            including: isPopup ? .subviews : .all
        )
        .offset(x: frame.minX, y: frame.minY)
        .animation(model.isDraggingPill ? nil : Motion.spring(0.45, 0.92), value: model.pillAnchor)
        .animation(Motion.spring(0.45, 0.92), value: model.pillWidth)
    }

    /// The pill itself, with a TimelineView mounted only when needed:
    /// - first-run demo (no music yet): demo loop timeline
    /// - idle ball: STATIC view, no timeline, zero per-frame work
    /// - playing/paused song: the live lyric timeline
    @ViewBuilder
    private var pillBody: some View {
        if model.isFirstRunDemo && model.now == nil {
            TimelineView(.animation(minimumInterval: model.frameInterval)) { context in
                DemoPill(model: model, wall: context.date.timeIntervalSinceReferenceDate)
            }
        } else if model.showsIdleBall {
            PillView(model: model, t: 0, wall: 0)
        } else {
            TimelineView(.animation(minimumInterval: model.frameInterval)) { context in
                PillView(
                    model: model,
                    t: model.lyricPosition(),
                    wall: context.date.timeIntervalSinceReferenceDate
                )
            }
        }
    }

    // MARK: - Actions

    private func expand() {
        guard model.uiState == .pill, model.now != nil else { return }
        model.uiState = .popup
        // Load-bearing (Task 3 review): opening the popup re-anchors the clock,
        // recovering from the poller's TCC-denial give-up state.
        model.resyncNow()
    }

    private func triggerBounce() {
        guard !Motion.reduce else { return }   // scale choreography off under Reduce Motion
        bounceScale = 0.94
        withAnimation(Motion.spring(0.3, 0.5)) { bounceScale = 1 }
    }

}

/// First-run moment: the pill loops a demo line center-screen with a one-time
/// caption underneath ("drag me"). Same material recipe as the real pill; all
/// timing derives from `wall`, so it is a pure per-frame render.
private struct DemoPill: View {
    @ObservedObject var model: AppModel
    let wall: TimeInterval

    private static let loopLength: TimeInterval = 4.5
    private static let demoWords: [WordTiming] = LyricsTimeline.synthesizeWords(
        text: AppModel.demoText, start: 0.4, end: 4.1
    )

    var body: some View {
        let loop = (wall - model.demoStartWall).truncatingRemainder(dividingBy: Self.loopLength)
        LyricLineRenderer(
            words: Self.demoWords, text: AppModel.demoText,
            start: 0.4, end: 4.1,
            theme: model.theme, style: .pill(model.palette), t: loop
        )
        .padding(.horizontal, 16)
        .frame(width: model.pillWidth, height: model.pillLayout.pillHeight)
        // Chrome + the "drag me" caption live on RootPillView's shell.
    }
}

/// Right-click menu on the pill.
struct PillContextMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu("Theme") {
            Picker("Theme", selection: $model.theme) {
                ForEach(LyricTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.inline)   // 4 options, checkmark on the current theme
        }

        // Single-display Macs get no submenu at all — nothing to choose.
        if NSScreen.screens.count > 1 {
            Menu("Screen") {
                Picker("Screen", selection: screenSelection) {
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        Text(screen.localizedName).tag(screen.displayID)
                    }
                }
                .pickerStyle(.inline)   // checkmark on the panel's current screen
            }
        }

        Menu("Lyric timing") {
            Button("−0.5s") { model.adjustSyncOffset(by: -0.5) }
            Button("−0.1s") { model.adjustSyncOffset(by: -0.1) }
            Button("Reset")  { model.syncOffset = 0 }
            Button("+0.1s") { model.adjustSyncOffset(by: 0.1) }
            Button("+0.5s") { model.adjustSyncOffset(by: 0.5) }
        }

        Divider()
        Button("Hide until next song") { model.hideUntilNextTrack() }
        Divider()
        Button("Settings…") { model.openSettings?() }
        Button("Quit Verse") { NSApp.terminate(nil) }
    }

    /// Reads the panel's current display, writes a move to the picked one
    /// (the panel controller owns the actual geometry change).
    private var screenSelection: Binding<CGDirectDisplayID?> {
        Binding(
            get: { model.currentScreenID },
            set: { picked in
                guard let screen = NSScreen.screens.first(where: { $0.displayID == picked })
                else { return }
                model.moveToScreen?(screen)
            }
        )
    }
}

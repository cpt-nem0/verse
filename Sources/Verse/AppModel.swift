import AppKit
import SwiftUI
import Combine

enum LyricTheme: String, CaseIterable, Identifiable {
    case lightWipe = "lightWipe"    // default
    case typeOn = "typeOn"          // most expressive
    case spotlight = "spotlight"
    case tracer = "tracer"          // most minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lightWipe: return "Light wipe"
        case .typeOn: return "Type-on"
        case .spotlight: return "Spotlight"
        case .tracer: return "Tracer"
        }
    }
}

enum InstrumentalStyle: String, CaseIterable, Identifiable {
    case breathingDots, countdown, bigArt
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .breathingDots: return "Breathing dots"
        case .countdown: return "Countdown"
        case .bigArt: return "Album art"
        }
    }
}

/// The pill's two visual states. Design revision A removed `.hidden`: the pill
/// never leaves the screen — with no music it contracts into the idle BALL
/// (a content state decided by `PillDisplay`, not a window state).
enum PillUIState { case pill, popup }

@MainActor
final class AppModel: ObservableObject {
    // MARK: - Published state
    @Published private(set) var now: NowPlayingState?
    @Published private(set) var content: LyricsContent = .none
    @Published private(set) var compactChunks: [LyricChunk] = []
    @Published private(set) var palette: Palette = .fallback
    @Published var uiState: PillUIState = .pill
    @Published var pinned = false
    @Published var browsing = false          // scroll-to-browse full list in vibe mode
    @Published var scrubbing = false
    /// User chose "Hide until next song": the pill contracts to the idle ball
    /// while this track keeps playing, and re-inflates when the track changes.
    /// Reset in `apply()`.
    @Published var hiddenUntilTrackChange = false

    // MARK: - Settings (persisted)
    @Published var theme: LyricTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "verse.theme") }
    }
    @Published var instrumentalStyle: InstrumentalStyle {
        didSet { UserDefaults.standard.set(instrumentalStyle.rawValue, forKey: "verse.instrumental") }
    }
    /// Seconds added to the playback position for lyric timing only (scrubber
    /// shows the true position). Positive → lyrics appear earlier; compensates
    /// for Bluetooth latency and imperfect community timestamps.
    @Published var syncOffset: Double {
        didSet { UserDefaults.standard.set(syncOffset, forKey: "verse.syncOffset") }
    }
    /// Opacity of the black wash over the glass (pill AND popup share the
    /// shell chrome): lower = more transparent/glassy, higher = more solid.
    @Published var pillOpacity: Double {
        didSet { UserDefaults.standard.set(pillOpacity, forKey: "verse.pillOpacity") }
    }
    /// Web music players in browsers (YT Music web…) — accepted only when the
    /// tab publishes music-shaped metadata (artist AND album). The coordinator
    /// reads the persisted value directly.
    @Published var webPlayers: Bool {
        didSet { UserDefaults.standard.set(webPlayers, forKey: "verse.webPlayers") }
    }

    // MARK: - Geometry (set by the panel controller at launch / on screen change)
    /// Font used to MEASURE pill text (chunks, titles) — must match the pill's
    /// lyric render size (`LyricRenderStyle.pill`, 13pt medium) or the dynamic
    /// width would over/underflow.
    let pillFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    /// Measurement font for echo (bracketed) lines: serif italic at 75% of 13pt,
    /// mirroring `PillView`'s echo styling.
    /// Italic variant of `pillFont` for measuring chunks that contain merged
    /// ad-lib (italic) runs.
    let pillItalicFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 13, weight: .medium)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 13) ?? base
    }()

    let echoFont: NSFont = {
        let size: CGFloat = 13 * 0.75
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        var descriptor = base.fontDescriptor
        if let serif = descriptor.withDesign(.serif) { descriptor = serif }
        descriptor = descriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }()

    /// Widest the pill may grow on this screen (set by the panel controller).
    var pillMaxWidth: CGFloat = 460

    /// Chunking budget: only lines wider than this split into sequential chunks
    /// (revision A — the pill hugs shorter lines whole).
    var pillTextWidth: CGFloat { pillMaxWidth - 32 }

    /// Pure geometry helpers (pill/popup size, clamping, coordinate flips).
    let pillLayout = PillLayout()

    /// The pill's ANCHOR point in SwiftUI panel space: x of the anchored edge
    /// (per `pillAnchorMode`) + the pill's TOP y. Revision A: as the width
    /// follows the lyric, the anchored edge never moves — so the anchor, not a
    /// top-left corner, is what's persisted (key `verse.pillAnchor`).
    @Published var pillAnchor: CGPoint {
        didSet { persistAnchor() }
    }

    /// Which pill edge `pillAnchor.x` pins (reclassified from the pill center's
    /// screen third at drag-end). Persisted alongside the anchor.
    @Published var pillAnchorMode: PillAnchorMode {
        didSet { persistAnchor() }
    }

    /// Current capsule width — revision A dynamic: follows the displayed text
    /// via `refreshPillWidth()` (per line-change, not per frame). Views animate
    /// changes with a spring; hit-testing reads the target value.
    @Published var pillWidth: CGFloat = PillLayout.ballDiameter

    /// The current screen's visible area (excludes menu bar + dock) expressed in
    /// panel space. Written by the panel controller; read for live drag-clamping
    /// and popup placement. Not `@Published` — every mutation of `pillAnchor`
    /// that depends on it is applied imperatively right after it changes.
    var pillVisibleRect: CGRect = .zero

    /// False until the very first launch persists an anchor; lets the panel
    /// controller drop the pill at its default spot only once.
    private(set) var hasStoredPillAnchor = false

    /// The display the panel currently occupies — checkmarked in the pill's
    /// "Screen" menu. Written by the panel controller.
    @Published var currentScreenID: CGDirectDisplayID?

    /// The display whose panel space `pillAnchor`'s coordinates belong to,
    /// persisted as the record's 4th field. `nil` for anchors written before
    /// multi-screen support — unknown counts as foreign, so the controller
    /// re-parks instead of restoring coordinates from who-knows-where.
    private(set) var pillAnchorScreenID: CGDirectDisplayID?

    /// Set by the panel controller: move the panel (and the pill) to a display.
    var moveToScreen: (@MainActor (NSScreen) -> Void)?

    /// True while the AppKit drag tracker is moving the pill — views suspend
    /// the anchor spring so the pill follows the pointer 1:1.
    @Published var isDraggingPill = false

    /// AssistiveTouch-style drop (2026-07-25): glide to the nearer side rail,
    /// keeping the drop height. Called by the panel's drag tracker at mouse-up.
    func snapPillToRail() {
        guard pillVisibleRect.width > 0 else { return }
        let frame = pillLayout.pillFrame(anchor: pillAnchor, mode: pillAnchorMode, width: pillWidth)
        let side = PillLayout.snapSide(forCenterX: frame.midX, visible: pillVisibleRect)
        withAnimation(Motion.spring(0.45, 0.82)) {
            pillAnchorMode = side
            pillAnchor = CGPoint(
                x: PillLayout.railX(side: side, visible: pillVisibleRect, edgeMargin: pillLayout.edgeMargin),
                y: frame.minY
            )
            clampPillAnchor()
        }
    }

    // MARK: - Motion / battery / first-run (Task 9)

    /// TimelineView frame cap: `nil` = uncapped (ProMotion); 1/30 s in Low
    /// Power Mode so the per-frame lyric work eases off on battery.
    @Published var frameInterval: Double?

    /// True from the very first launch until the first real track or the first
    /// drag — while true (and nothing plays) the pill sits center-screen
    /// looping a demo line with a "drag me" caption.
    @Published private(set) var isFirstRunDemo: Bool

    /// Wall-clock start of the demo (caption fades 8s in).
    let demoStartWall: TimeInterval = Date.timeIntervalSinceReferenceDate

    /// True when the pill shows the static idle ball — no animation is running,
    /// so RootPillView mounts NO TimelineView at all (CPU ~0 when idle).
    var showsIdleBall: Bool { now == nil || hiddenUntilTrackChange }

    // MARK: - Engine
    let clock = PlaybackClock()
    private lazy var coordinator = NowPlayingCoordinator(clock: clock)
    private let lyricsService = LyricsService()
    private let paletteCache = PaletteCache()
    private var lyricsTask: Task<Void, Never>?
    private var currentTrackKey: String?
    private var browseTimer: Timer?

    /// Lyric time frozen at the moment playback paused, so the wipe/spotlight
    /// stops mid-word instead of drifting on the interpolating clock. `nil`
    /// while playing. See `lyricPosition()`.
    private var pausedLyricPosition: TimeInterval?

    var openSettings: (@MainActor () -> Void)?

    init() {
        let defaults = UserDefaults.standard
        theme = LyricTheme(rawValue: defaults.string(forKey: "verse.theme") ?? "") ?? .lightWipe
        instrumentalStyle = InstrumentalStyle(
            rawValue: defaults.string(forKey: "verse.instrumental") ?? "") ?? .breathingDots
        syncOffset = defaults.double(forKey: "verse.syncOffset")
        pillOpacity = defaults.object(forKey: "verse.pillOpacity") as? Double ?? 0.35
        webPlayers = defaults.object(forKey: "verse.webPlayers") as? Bool ?? true

        // Restore the saved anchor ("mode,x,y"). didSet does NOT fire for these
        // initial assignments, so `hasStoredPillAnchor` is set by hand — the
        // panel controller uses it to place the pill at its default spot only
        // when nothing was persisted yet.
        var restoredAnchor = CGPoint.zero
        var restoredMode = PillAnchorMode.center
        var restoredScreen: CGDirectDisplayID?
        var restored = false
        if let saved = defaults.string(forKey: "verse.pillAnchor"),
           let record = PillAnchorRecord.parse(saved) {
            restoredAnchor = record.anchor
            restoredMode = record.mode
            restoredScreen = record.screenID
            restored = true
        }
        pillAnchor = restoredAnchor
        pillAnchorMode = restoredMode
        pillAnchorScreenID = restoredScreen
        hasStoredPillAnchor = restored
        // Pre-revision-A key (top-left "x,y") is dead — a fresh default is fine.
        defaults.removeObject(forKey: "verse.pillOrigin")

        isFirstRunDemo = !defaults.bool(forKey: "verse.launched")
        frameInterval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 30.0 : nil
    }

    /// The built-in line the first-run demo loops.
    static let demoText = "and the city hums along in gold"

    /// The first real track or the first drag ends the demo permanently.
    func endFirstRunDemo() {
        guard isFirstRunDemo else { return }
        isFirstRunDemo = false
        UserDefaults.standard.set(true, forKey: "verse.launched")
        refreshPillWidth()   // demo pill → ball (or the live track's width)
    }

    private func persistAnchor() {
        hasStoredPillAnchor = true
        UserDefaults.standard.set(
            PillAnchorRecord(
                mode: pillAnchorMode, anchor: pillAnchor, screenID: pillAnchorScreenID
            ).stringValue,
            forKey: "verse.pillAnchor"
        )
    }

    /// The panel controller vouches that `pillAnchor` is expressed in `id`'s
    /// panel space (it re-parked the pill if the stored anchor came from
    /// another display), so the record can name that display.
    func notePillAnchorScreen(_ id: CGDirectDisplayID?) {
        guard pillAnchorScreenID != id else { return }
        pillAnchorScreenID = id
        persistAnchor()
    }

    /// Clamp `pillAnchor` so the whole pill (at its current width and anchor
    /// mode) stays inside the visible area with the layout's edge margin.
    /// Assigning `pillAnchor` persists it.
    func clampPillAnchor() {
        guard pillVisibleRect.width > 0 else { return }
        let clamped = pillLayout.clampedAnchor(
            pillAnchor, mode: pillAnchorMode, width: pillWidth, visible: pillVisibleRect
        )
        if clamped != pillAnchor { pillAnchor = clamped }
    }

    // MARK: - Dynamic pill width (revision A)

    /// "♪ Title — Artist" shown pre-first-line / for plain / missing lyrics.
    var pillTitleText: String {
        guard let now else { return "" }
        return "♪ \(TitleCleaner.clean(now.title)) — \(now.artist)"
    }

    /// Recompute the pill's target width from what it is displaying right now.
    /// Called on model-side changes (track/lyrics/pause) and by the view when
    /// the displayed chunk changes (a per-line event, never per frame). While a
    /// short `<3s` gap shows `.blank`, the previous width is kept.
    func refreshPillWidth() {
        // First-run demo (no music yet): size to the demo line.
        if isFirstRunDemo && now == nil {
            applyPillWidth(fittedPillWidth(text: Self.demoText, font: pillFont))
            return
        }
        let display = PillDisplay.at(
            t: lyricPosition(), content: content, chunks: compactChunks,
            duration: now?.duration ?? 0,
            trackLoaded: now != nil, hiddenUntilTrackChange: hiddenUntilTrackChange
        )
        let target: CGFloat?
        switch display {
        case .ball:
            target = PillLayout.ballDiameter
        case .instrumental(let tiny):
            target = tiny ? PillLayout.ballDiameter : pillLayout.instrumentalWidth
        case .title:
            target = fittedPillWidth(text: pillTitleText, font: pillFont)
        case .chunk(let chunk):
            // As-rendered width (regular vs italic per word) PLUS layout
            // slack: SwiftUI lays text out on pixel boundaries, so a width
            // even 0.5pt under the measurement triggers "…" truncation that
            // eats whole characters (the "Pool House" bug — measured 269.34,
            // laid out 270.0).
            target = PillLayout.pillWidth(
                forTextWidth: LyricChunker.width(
                    of: chunk.words, font: pillFont, italicFont: pillItalicFont) + Self.textLayoutSlack,
                maxWidth: pillMaxWidth
            )
        case .echo(let chunk):
            target = fittedPillWidth(text: chunk.text, font: echoFont)
        case .blank:
            target = nil    // hold the last width through brief inter-line gaps
        }
        if let target { applyPillWidth(target) }
    }

    private func applyPillWidth(_ target: CGFloat) {
        guard abs(target - pillWidth) > 0.5 else { return }
        pillWidth = target
        clampPillAnchor()   // a wider pill may need nudging off an edge
    }

    /// Headroom between NSFont measurement and SwiftUI's pixel-aligned layout
    /// — without it, sub-point rounding triggers ellipsis truncation.
    static let textLayoutSlack: CGFloat = 6

    private func fittedPillWidth(text: String, font: NSFont) -> CGFloat {
        PillLayout.pillWidth(
            forTextWidth: LyricChunker.width(of: text, font: font) + Self.textLayoutSlack,
            maxWidth: pillMaxWidth
        )
    }

    // MARK: - Lifecycle

    func start() {
        coordinator.onUpdate = { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        coordinator.start()
        observeFullscreen()
        observeMotionAndPower()
        refreshPillWidth()   // demo width on first run; ball width otherwise
    }

    /// Reduce Motion + Low Power Mode observers. The accessibility notification
    /// arrives on the main thread; the power one arrives on a BACKGROUND thread
    /// — both hop to the main actor before touching model state.
    private func observeMotionAndPower() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Motion.reduce is read live by the views; publishing a change
            // makes every observer re-evaluate its animations.
            Task { @MainActor in self?.objectWillChange.send() }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil        // ⚠️ delivered on a background thread
        ) { [weak self] _ in
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { @MainActor in self?.frameInterval = lowPower ? 1.0 / 30.0 : nil }
        }
    }

    func stop() {
        coordinator.stop()
        lyricsTask?.cancel()
    }

    private func apply(_ state: NowPlayingState?) {
        guard let state else {
            now = nil
            currentTrackKey = nil
            content = .none
            compactChunks = []
            pausedLyricPosition = nil
            hiddenUntilTrackChange = false
            // Revision A: music stopping contracts the pill to the idle ball —
            // it never leaves the screen. Only an open popup needs collapsing.
            if uiState == .popup { uiState = .pill }
            refreshPillWidth()
            return
        }

        let trackChanged = state.trackKey != currentTrackKey
        let artworkArrived = now?.artwork == nil && state.artwork != nil
        now = state

        // The first real track retires the first-run demo for good.
        endFirstRunDemo()

        // A new song clears a "hide until next song" request (ball → pill).
        if trackChanged { hiddenUntilTrackChange = false }

        // Freeze lyric time on pause (capture once), release on resume. Capturing
        // here — after the coordinator has pushed the paused position into the
        // clock — pins the wipe to exactly where the vocal stopped.
        if state.isPlaying {
            pausedLyricPosition = nil
        } else if pausedLyricPosition == nil {
            pausedLyricPosition = clock.position()
        }

        if trackChanged {
            currentTrackKey = state.trackKey
            content = .none
            compactChunks = []
            fetchLyrics(for: state)
        }
        if trackChanged || artworkArrived {
            palette = paletteCache.palette(
                for: "\(state.artist)|\(state.album)",
                artwork: state.artwork
            )
        }
        refreshPillWidth()
    }

    private func fetchLyrics(for state: NowPlayingState) {
        lyricsTask?.cancel()
        let key = state.trackKey
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.lyricsService.lyrics(for: state)
            guard !Task.isCancelled, self.currentTrackKey == key else { return }
            self.content = result
            if case .synced(let timeline) = result {
                // The chunker measures each word in the font it will render
                // in (regular vs italic ad-libs), so splits are exact; keep a
                // small margin for rounding only.
                self.compactChunks = LyricChunker.chunks(
                    for: timeline,
                    maxWidth: self.pillTextWidth - 4,
                    font: self.pillFont,
                    italicFont: self.pillItalicFont
                )
            } else {
                self.compactChunks = []
            }
            self.refreshPillWidth()
        }
    }

    // MARK: - Derived

    var timeline: LyricsTimeline? {
        if case .synced(let t) = content { return t }
        return nil
    }

    func position() -> TimeInterval { clock.position() }

    /// Playback position shifted by the user's lyric-timing offset — use this
    /// for anything lyric-synced; use `position()` for the scrubber. Returns the
    /// frozen pause position while paused so the theme animation holds mid-word.
    func lyricPosition() -> TimeInterval { (pausedLyricPosition ?? clock.position()) + syncOffset }

    /// True when a song is loaded but paused (distinct from stopped/`nil`).
    var isPaused: Bool { now != nil && now?.isPlaying == false }

    // MARK: - Transport

    func togglePlayPause() { coordinator.togglePlayPause() }
    func nextTrack() { coordinator.nextTrack() }
    func previousTrack() { coordinator.previousTrack() }

    /// Contract the pill to the idle ball until the current track ends /
    /// changes (context-menu item). Revision A: "hide" means ball, not gone.
    func hideUntilNextTrack() {
        hiddenUntilTrackChange = true
        if uiState == .popup { uiState = .pill }
        refreshPillWidth()
    }

    /// Right-click "Lyric timing" nudges — clamped to the same ±1s the settings
    /// slider uses so the two controls always agree.
    func adjustSyncOffset(by delta: Double) {
        syncOffset = min(1, max(-1, syncOffset + delta))
    }

    func seek(to seconds: TimeInterval) {
        guard let duration = now?.duration, duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        coordinator.seek(to: clamped)
        // Seeking while paused must move the frozen lyric with the scrubber.
        if pausedLyricPosition != nil { pausedLyricPosition = clamped }
    }

    /// Re-anchor the playback clock against ground truth right now, instead
    /// of waiting for the next scheduled poll. Intended to be called when
    /// the popup opens.
    func resyncNow() { coordinator.resyncNow() }

    func openSourcePlayer() {
        guard let id = now?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: - Browse mode (scroll inside the panel → full lyrics list)

    func enterBrowse() {
        guard uiState == .popup, timeline != nil else { return }
        browsing = true
        restartBrowseTimer()
    }

    func restartBrowseTimer() {
        browseTimer?.invalidate()
        browseTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.browsing = false }
        }
    }

    func exitBrowse() {
        browseTimer?.invalidate()
        browsing = false
    }

    // MARK: - Pinned auto-collapse when a fullscreen app/video starts

    private func observeFullscreen() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pinned else { return }
                if Self.frontmostSpaceIsFullscreen() {
                    self.pinned = false
                    self.uiState = .pill
                    self.exitBrowse()
                }
            }
        }
    }

    private static func frontmostSpaceIsFullscreen() -> Bool {
        guard let screen = NSScreen.main,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]]
        else { return false }
        let screenFrame = screen.frame
        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"]
            else { continue }
            // A layer-0 window covering the full screen (incl. menu bar area)
            // means a fullscreen space is frontmost.
            if w >= screenFrame.width && h >= screenFrame.height - 1 {
                return true
            }
        }
        return false
    }
}

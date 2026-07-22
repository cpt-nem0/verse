import AppKit
import SwiftUI
import Combine

enum LyricTheme: String, CaseIterable, Identifiable {
    case typeOn = "typeOn"          // most expressive
    case spotlight = "spotlight"
    case lightWipe = "lightWipe"    // default
    case tracer = "tracer"          // most minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .typeOn: return "Type-on"
        case .spotlight: return "Spotlight"
        case .lightWipe: return "Light wipe"
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

enum NotchUIState { case hidden, compact, expanded }

@MainActor
final class AppModel: ObservableObject {
    // MARK: - Published state
    @Published private(set) var now: NowPlayingState?
    @Published private(set) var content: LyricsContent = .none
    @Published private(set) var compactChunks: [LyricChunk] = []
    @Published private(set) var palette: Palette = .fallback
    @Published var uiState: NotchUIState = .hidden
    @Published var pinned = false
    @Published var browsing = false          // scroll-to-browse full list in vibe mode
    @Published var scrubbing = false

    // MARK: - Settings (persisted)
    @Published var theme: LyricTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "verse.theme") }
    }
    @Published var hoverIntentDelay: Bool {  // 150ms hover-intent before expanding
        didSet { UserDefaults.standard.set(hoverIntentDelay, forKey: "verse.hoverIntent") }
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

    // MARK: - Geometry (set once by the panel controller at launch)
    var wingTextWidth: CGFloat = 240
    let compactFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    // MARK: - Engine
    let clock = PlaybackClock()
    private lazy var coordinator = NowPlayingCoordinator(clock: clock)
    private let lyricsService = LyricsService()
    private let paletteCache = PaletteCache()
    private var lyricsTask: Task<Void, Never>?
    private var currentTrackKey: String?
    private var browseTimer: Timer?

    var openSettings: (@MainActor () -> Void)?

    init() {
        let defaults = UserDefaults.standard
        theme = LyricTheme(rawValue: defaults.string(forKey: "verse.theme") ?? "") ?? .lightWipe
        hoverIntentDelay = defaults.object(forKey: "verse.hoverIntent") as? Bool ?? true
        instrumentalStyle = InstrumentalStyle(
            rawValue: defaults.string(forKey: "verse.instrumental") ?? "") ?? .breathingDots
        syncOffset = defaults.double(forKey: "verse.syncOffset")
    }

    // MARK: - Lifecycle

    func start() {
        coordinator.onUpdate = { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        coordinator.start()
        observeFullscreen()
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
            if uiState != .hidden { uiState = .hidden }
            return
        }

        let trackChanged = state.trackKey != currentTrackKey
        let artworkArrived = now?.artwork == nil && state.artwork != nil
        now = state
        if uiState == .hidden { uiState = .compact }

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
                self.compactChunks = LyricChunker.chunks(
                    for: timeline,
                    maxWidth: self.wingTextWidth - 8,
                    font: self.compactFont
                )
            } else {
                self.compactChunks = []
            }
        }
    }

    // MARK: - Derived

    var timeline: LyricsTimeline? {
        if case .synced(let t) = content { return t }
        return nil
    }

    func position() -> TimeInterval { clock.position() }

    /// Playback position shifted by the user's lyric-timing offset — use this
    /// for anything lyric-synced; use `position()` for the scrubber.
    func lyricPosition() -> TimeInterval { clock.position() + syncOffset }

    // MARK: - Transport

    func togglePlayPause() { coordinator.togglePlayPause() }
    func nextTrack() { coordinator.nextTrack() }
    func previousTrack() { coordinator.previousTrack() }

    func seek(to seconds: TimeInterval) {
        guard let duration = now?.duration, duration > 0 else { return }
        coordinator.seek(to: min(max(seconds, 0), duration))
    }

    func openSourcePlayer() {
        guard let id = now?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: - Browse mode (scroll inside the panel → full lyrics list)

    func enterBrowse() {
        guard uiState == .expanded, timeline != nil else { return }
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
                    self.uiState = self.now == nil ? .hidden : .compact
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

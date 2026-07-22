import Foundation

/// Picks the best available now-playing source and exposes a single interface.
/// Preference: MediaRemote adapter (system-wide) → AppleScript polling fallback.
final class NowPlayingCoordinator {
    private var provider: NowPlayingProvider?
    private let clock: PlaybackClock

    /// v1: only dedicated music apps drive the notch. System now-playing can't
    /// distinguish a music site from any other tab, so browser audio
    /// (YouTube, video calls, …) is ignored entirely.
    private static let allowedSources: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
    ]

    /// Delivered on the main queue.
    var onUpdate: ((NowPlayingState?) -> Void)?

    init(clock: PlaybackClock) {
        self.clock = clock
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let chosen: NowPlayingProvider
            if let adapter = AdapterNowPlayingProvider(), adapter.selfTest() {
                chosen = adapter
                NSLog("Verse: using MediaRemote adapter")
            } else {
                chosen = AppleScriptNowPlayingProvider()
                NSLog("Verse: using AppleScript fallback")
            }
            chosen.onUpdate = { [weak self] rawState, elapsed, rate in
                guard let self else { return }
                let state = rawState.flatMap {
                    Self.allowedSources.contains($0.bundleIdentifier) ? $0 : nil
                }
                self.clock.update(
                    elapsed: elapsed,
                    playing: state?.isPlaying ?? false,
                    rate: rate == 0 ? 1 : rate,
                    duration: state?.duration ?? 0
                )
                DispatchQueue.main.async { self.onUpdate?(state) }
            }
            self.provider = chosen
            chosen.start()
        }
    }

    func stop() { provider?.stop() }

    func togglePlayPause() { provider?.togglePlayPause() }
    func nextTrack() { provider?.nextTrack() }
    func previousTrack() { provider?.previousTrack() }

    func seek(to seconds: TimeInterval) {
        clock.jump(to: seconds) // instant UI response
        provider?.seek(to: seconds)
    }
}

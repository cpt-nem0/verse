import AppKit

/// Snapshot of what the system is currently playing.
struct NowPlayingState: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var isPlaying: Bool
    var bundleIdentifier: String
    var artwork: NSImage?

    /// Stable identity for "did the song change?" checks and cache keys.
    var trackKey: String {
        "\(artist.lowercased())|\(title.lowercased())|\(album.lowercased())|\(Int(duration.rounded()))"
    }

    var sourceName: String {
        switch bundleIdentifier {
        case "com.spotify.client": return "Spotify"
        case "com.apple.Music": return "Music"
        default:
            return bundleIdentifier.split(separator: ".").last.map(String.init)?.capitalized ?? "Player"
        }
    }

    static func == (lhs: NowPlayingState, rhs: NowPlayingState) -> Bool {
        lhs.trackKey == rhs.trackKey
            && lhs.isPlaying == rhs.isPlaying
            && (lhs.artwork == nil) == (rhs.artwork == nil)
    }
}

/// Interpolates playback position between sparse provider updates
/// using a local monotonic clock, so animation is smooth at 120Hz.
final class PlaybackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var baseElapsed: TimeInterval = 0
    private var baseUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var rate: Double = 0
    private var duration: TimeInterval = 0

    func update(elapsed: TimeInterval, playing: Bool, rate: Double = 1.0, duration: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        baseElapsed = elapsed
        baseUptime = ProcessInfo.processInfo.systemUptime
        self.rate = playing ? max(rate, 0.01) : 0
        self.duration = duration
    }

    /// Nudge the local clock immediately after a seek so the UI doesn't
    /// wait for the next provider poll to jump.
    func jump(to elapsed: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        baseElapsed = elapsed
        baseUptime = ProcessInfo.processInfo.systemUptime
    }

    func position() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let p = baseElapsed + (now - baseUptime) * rate
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
}

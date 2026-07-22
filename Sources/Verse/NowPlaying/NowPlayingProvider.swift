import Foundation

/// A source of now-playing information + transport control.
protocol NowPlayingProvider: AnyObject {
    /// Called on an arbitrary queue whenever the now-playing state changes.
    /// `nil` means nothing is playing / no media session.
    var onUpdate: ((NowPlayingState?, _ elapsed: TimeInterval, _ playbackRate: Double) -> Void)? { get set }

    func start()
    func stop()

    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    /// Seek to an absolute position in seconds.
    func seek(to seconds: TimeInterval)
}

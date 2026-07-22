import AppKit

/// Fallback provider: polls Spotify / Apple Music over AppleScript.
/// Used when the MediaRemote adapter is unavailable or fails its self-test.
/// Polls sparsely (2s); the PlaybackClock interpolates in between.
final class AppleScriptNowPlayingProvider: NowPlayingProvider {
    var onUpdate: ((NowPlayingState?, TimeInterval, Double) -> Void)?

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "verse.applescript", qos: .utility)
    private var artworkCache: (key: String, image: NSImage)?
    private enum Player: String {
        case spotify = "Spotify"
        case music = "Music"
        var bundleID: String {
            self == .spotify ? "com.spotify.client" : "com.apple.Music"
        }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func runningPlayer() -> Player? {
        let running = NSWorkspace.shared.runningApplications
        func isRunning(_ id: String) -> Bool {
            running.contains { $0.bundleIdentifier == id }
        }
        // Prefer whichever is actually playing; check Spotify first.
        for p in [Player.spotify, .music] where isRunning(p.bundleID) {
            if runScript("tell application \"\(p.rawValue)\" to player state as string")?.contains("playing") == true {
                return p
            }
        }
        for p in [Player.spotify, .music] where isRunning(p.bundleID) { return p }
        return nil
    }

    private func poll() {
        guard let player = runningPlayer() else {
            onUpdate?(nil, 0, 0)
            return
        }
        let sep = "\u{1F}"
        let script = """
        tell application "\(player.rawValue)"
            if player state is stopped then return "STOPPED"
            set t to current track
            set out to (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)"
            set out to out & (duration of t) & "\(sep)" & (player position) & "\(sep)" & (player state as string)
            \(player == .spotify ? "set out to out & \"\(sep)\" & (artwork url of t)" : "set out to out & \"\(sep)\"")
            return out
        end tell
        """
        guard let raw = runScript(script), raw != "STOPPED" else {
            onUpdate?(nil, 0, 0)
            return
        }
        let parts = raw.components(separatedBy: sep)
        guard parts.count >= 6 else { return }

        var duration = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
        if player == .spotify { duration /= 1000 } // Spotify reports milliseconds
        let elapsed = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        let playing = parts[5].contains("playing")

        let artKey = "\(parts[1])|\(parts[0])|\(parts[2])"
        var artwork: NSImage?
        if let cached = artworkCache, cached.key == artKey {
            artwork = cached.image
        } else if parts.count >= 7, let url = URL(string: parts[6]),
                  url.scheme?.hasPrefix("http") == true,
                  let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data) {
            artwork = image
            artworkCache = (artKey, image)
        }

        let state = NowPlayingState(
            title: parts[0], artist: parts[1], album: parts[2],
            duration: duration, isPlaying: playing,
            bundleIdentifier: player.bundleID, artwork: artwork
        )
        onUpdate?(state, elapsed, playing ? 1.0 : 0)
    }

    /// NSAppleScript is main-thread-bound; hop there for execution.
    @discardableResult
    private func runScript(_ source: String) -> String? {
        var result: String?
        let work = {
            var error: NSDictionary?
            if let script = NSAppleScript(source: source) {
                let out = script.executeAndReturnError(&error)
                if error == nil { result = out.stringValue }
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return result
    }

    // MARK: - Transport

    private func tellCurrentPlayer(_ command: String) {
        queue.async { [weak self] in
            guard let self, let player = self.runningPlayer() else { return }
            self.runScript("tell application \"\(player.rawValue)\" to \(command)")
            self.poll()
        }
    }

    func togglePlayPause() { tellCurrentPlayer("playpause") }
    func nextTrack()       { tellCurrentPlayer("next track") }
    func previousTrack()   { tellCurrentPlayer("previous track") }
    func seek(to seconds: TimeInterval) {
        tellCurrentPlayer("set player position to \(seconds)")
    }
}

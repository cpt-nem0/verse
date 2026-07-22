import AppKit

/// Now-playing via the community `mediaremote-adapter` approach:
/// `/usr/bin/perl` (which is allowed to load MediaRemote on macOS 15.4+)
/// runs a small script that loads a bundled helper framework and streams
/// JSON updates on stdout.
///
/// Requires `mediaremote-adapter.pl` and `MediaRemoteAdapter.framework`
/// in the app bundle's Resources (the Makefile puts them there).
final class AdapterNowPlayingProvider: NowPlayingProvider {
    var onUpdate: ((NowPlayingState?, TimeInterval, Double) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var mergedPayload: [String: Any] = [:]
    private var artworkCache: (key: String, image: NSImage)?
    private let queue = DispatchQueue(label: "verse.adapter", qos: .userInitiated)

    private let scriptURL: URL
    private let frameworkURL: URL

    /// Returns nil when the adapter resources are missing from the bundle.
    init?() {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl")
        let framework = resources.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else { return nil }
        scriptURL = script
        frameworkURL = framework
    }

    /// Synchronously verify the adapter works on this system (exit code 0).
    func selfTest() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [scriptURL.path, frameworkURL.path, "test"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    func start() {
        queue.async { [weak self] in self?.launchStream() }
    }

    private func launchStream() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [scriptURL.path, frameworkURL.path, "stream", "--debounce=100"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil // EOF
                return
            }
            self.queue.async { self.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            // Relaunch after a short delay if we were not deliberately stopped.
            self.queue.asyncAfter(deadline: .now() + 2) {
                if self.process != nil { self.launchStream() }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("Verse: failed to launch mediaremote-adapter: \(error)")
        }
    }

    func stop() {
        queue.sync {
            let p = process
            process = nil
            p?.terminate()
        }
    }

    // MARK: - Stream parsing

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "data" else { continue }

            let isDiff = obj["diff"] as? Bool ?? false
            let payload = obj["payload"] as? [String: Any] ?? [:]

            if isDiff {
                for (k, v) in payload {
                    if v is NSNull { mergedPayload.removeValue(forKey: k) }
                    else { mergedPayload[k] = v }
                }
            } else {
                mergedPayload = payload.filter { !($0.value is NSNull) }
            }
            publish()
        }
    }

    private func publish() {
        guard let title = mergedPayload["title"] as? String, !title.isEmpty else {
            onUpdate?(nil, 0, 0)
            return
        }
        let artist = mergedPayload["artist"] as? String ?? ""
        let album = mergedPayload["album"] as? String ?? ""
        let duration = anyToDouble(mergedPayload["duration"]) ?? 0
        var elapsed = anyToDouble(mergedPayload["elapsedTime"]) ?? 0
        let playing = mergedPayload["playing"] as? Bool ?? false
        let rate = anyToDouble(mergedPayload["playbackRate"]) ?? 1.0

        // The payload's `timestamp` (epoch seconds) marks when elapsedTime was
        // measured; project forward so merged/stale diffs stay accurate.
        if playing, let ts = anyToDouble(mergedPayload["timestamp"]), ts > 1_000_000_000 {
            let drift = Date().timeIntervalSince1970 - ts
            if drift > 0, drift < 3600 { elapsed += drift * max(rate, 0.01) }
        }
        let bundleID = mergedPayload["bundleIdentifier"] as? String ?? ""

        var artwork: NSImage?
        let artKey = "\(artist)|\(title)|\(album)"
        if let cached = artworkCache, cached.key == artKey {
            artwork = cached.image
        } else if let b64 = mergedPayload["artworkData"] as? String,
                  let data = Data(base64Encoded: b64),
                  let image = NSImage(data: data) {
            artwork = image
            artworkCache = (artKey, image)
        }

        let state = NowPlayingState(
            title: title, artist: artist, album: album,
            duration: duration, isPlaying: playing,
            bundleIdentifier: bundleID, artwork: artwork
        )
        onUpdate?(state, elapsed, playing ? rate : 0)
    }

    private func anyToDouble(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: - Transport

    private func runCommand(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [scriptURL.path, frameworkURL.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func togglePlayPause() { runCommand(["send", "2"]) }
    func nextTrack()       { runCommand(["send", "4"]) }
    func previousTrack()   { runCommand(["send", "5"]) }
    func seek(to seconds: TimeInterval) {
        runCommand(["seek", String(Int(seconds * 1_000_000))])
    }
}

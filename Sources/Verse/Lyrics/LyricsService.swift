import Foundation
import CryptoKit

/// Fetches synced lyrics from LRCLIB (https://lrclib.net) and caches them
/// on disk so repeat plays work offline.
final class LyricsService {
    private let session: URLSession
    private let cacheDir: URL

    init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Verse/1.0 (macOS notch lyrics; https://lrclib.net)"
        ]
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cacheDir = appSupport.appendingPathComponent("Verse/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    struct LRCLibRecord: Codable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?

        var hasAnyLyrics: Bool {
            instrumental == true
                || !(syncedLyrics ?? "").isEmpty
                || !(plainLyrics ?? "").isEmpty
        }
        var hasSynced: Bool { !(syncedLyrics ?? "").isEmpty }
    }

    func lyrics(for state: NowPlayingState) async -> LyricsContent {
        let record: LRCLibRecord?
        if let cached = cachedRecord(for: state.trackKey) {
            record = cached
        } else {
            record = await fetchRecord(for: state)
            if let record { cache(record, for: state.trackKey) }
        }

        guard let record else { return .none }
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics, !synced.isEmpty,
           let timeline = LRCParser.parse(synced) {
            return .synced(timeline)
        }
        if let plain = record.plainLyrics, !plain.isEmpty {
            return .plain(plain)
        }
        return .none
    }

    // MARK: - Network

    /// LRCLIB is occasionally flaky (504s), and player titles often carry
    /// suffixes LRCLIB doesn't index ("(feat. X)", "- Remastered"). Try exact
    /// gets and searches over title variants, and retry the whole sequence
    /// with backoff before giving up.
    private func fetchRecord(for state: NowPlayingState) async -> LRCLibRecord? {
        let titles = Self.titleVariants(state.title)
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: attempt == 1 ? 2_000_000_000 : 5_000_000_000)
            }
            if Task.isCancelled { return nil }

            for title in titles {
                if let record = await exactGet(title: title, state: state), record.hasAnyLyrics {
                    return record
                }
            }
            for title in titles {
                if let record = await searchBest(title: title, state: state) {
                    return record
                }
            }
        }
        return nil
    }

    private func exactGet(title: String, state: NowPlayingState) async -> LRCLibRecord? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: state.artist),
            URLQueryItem(name: "album_name", value: state.album),
            URLQueryItem(name: "duration", value: String(Int(state.duration.rounded())))
        ]
        return await getJSON(LRCLibRecord.self, from: components.url)
    }

    private func searchBest(title: String, state: NowPlayingState) async -> LRCLibRecord? {
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: state.artist)
        ]
        guard let results = await getJSON([LRCLibRecord].self, from: search.url) else { return nil }

        // Prefer synced lyrics, then the closest duration.
        let usable = results.filter { $0.hasAnyLyrics }
        let pool = usable.contains { $0.hasSynced } ? usable.filter { $0.hasSynced } : usable
        return pool.min { a, b in
            abs((a.duration ?? 0) - state.duration) < abs((b.duration ?? 0) - state.duration)
        }
    }

    /// [original title, title stripped of "(feat. X)" / "- Remastered" noise].
    static func titleVariants(_ title: String) -> [String] {
        var cleaned = title
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+-\s+(feat\.?|ft\.?|featuring|remaster|single version|radio edit|bonus track|deluxe|mono|stereo|live).*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == title ? [title] : [title, cleaned]
    }

    private func getJSON<T: Decodable>(_ type: T.Type, from url: URL?) async -> T? {
        guard let url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Disk cache

    private func cacheURL(for trackKey: String) -> URL {
        let digest = SHA256.hash(data: Data(trackKey.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        return cacheDir.appendingPathComponent("\(name).json")
    }

    private func cachedRecord(for trackKey: String) -> LRCLibRecord? {
        guard let data = try? Data(contentsOf: cacheURL(for: trackKey)) else { return nil }
        return try? JSONDecoder().decode(LRCLibRecord.self, from: data)
    }

    private func cache(_ record: LRCLibRecord, for trackKey: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: cacheURL(for: trackKey))
    }
}

import Foundation

struct WordTiming: Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct LyricLine: Equatable, Identifiable {
    let id: Int
    let start: TimeInterval
    var end: TimeInterval
    let text: String
    /// Word-level timings. Real (from enhanced LRC) when available,
    /// otherwise synthesized: distributed across the line's duration,
    /// weighted by word length — always present for non-empty lines,
    /// so no theme is ever disabled by missing word data.
    var words: [WordTiming]

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// A display unit for the compact wing: either a whole line, or one piece
/// of a long line broken at word boundaries. Each chunk carries its own
/// time window and word timings, so every theme animates per-chunk.
struct LyricChunk: Equatable, Identifiable {
    let id: String // "lineIndex-chunkIndex"
    let lineIndex: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let words: [WordTiming]
}

enum LyricsContent {
    case synced(LyricsTimeline)
    case plain(String)     // unsynced lyrics: static display, no animation
    case instrumental
    case none              // no lyrics found: show track title in the wing
}

/// The synced-lyrics engine: answers "what line/word/chunk is active at time t".
struct LyricsTimeline {
    let lines: [LyricLine]

    /// Index of the active line at time `t`, or nil before the first line.
    func lineIndex(at t: TimeInterval) -> Int? {
        if lines.isEmpty || t < lines[0].start { return nil }
        // Binary search for the last line whose start <= t.
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].start <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// True in the gap before the first line or inside an empty timed line —
    /// i.e. an instrumental break where no stale text should show.
    func isInstrumentalBreak(at t: TimeInterval) -> Bool {
        guard let i = lineIndex(at: t) else { return true }
        return lines[i].isEmpty
    }

    /// Time of the next line start after `t` (for break countdowns).
    func nextLineStart(after t: TimeInterval) -> TimeInterval? {
        lines.first(where: { $0.start > t && !$0.isEmpty })?.start
    }

    // MARK: - Synthesized word timings

    /// Distribute word timings across [start, end], weighted by word length.
    /// Used when the LRC has line-level timestamps only.
    static func synthesizeWords(text: String, start: TimeInterval, end: TimeInterval) -> [WordTiming] {
        let tokens = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let duration = max(end - start, 0.3)
        // Weight = character count + 1 so tiny words still get a beat.
        let weights = tokens.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        var cursor = start
        var result: [WordTiming] = []
        for (word, weight) in zip(tokens, weights) {
            let span = duration * (weight / total)
            result.append(WordTiming(text: word, start: cursor, end: cursor + span))
            cursor += span
        }
        return result
    }
}

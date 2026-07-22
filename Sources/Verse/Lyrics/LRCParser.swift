import Foundation

/// Parses .lrc content: standard line-level `[mm:ss.xx]` tags (multiple tags
/// per line supported) and, when present, enhanced word-level `<mm:ss.xx>` tags.
enum LRCParser {
    static func parse(_ lrc: String) -> LyricsTimeline? {
        struct RawLine { let start: TimeInterval; let text: String; let words: [WordTiming]? }
        var raw: [RawLine] = []

        for line in lrc.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Collect all leading [..] tags; skip metadata tags like [ar:...]
            var rest = Substring(trimmed)
            var timestamps: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...]
                if let t = parseTimestamp(tag) { timestamps.append(t) }
            }
            guard !timestamps.isEmpty else { continue }

            let content = String(rest).trimmingCharacters(in: .whitespaces)
            let words = parseEnhancedWords(content)
            let plainText = words.map { $0.map(\.text).joined(separator: " ") } ?? content

            for t in timestamps {
                raw.append(RawLine(start: t, text: plainText, words: words))
            }
        }

        guard !raw.isEmpty else { return nil }
        raw.sort { $0.start < $1.start }

        var lines: [LyricLine] = []
        for (i, r) in raw.enumerated() {
            let nextStart = i + 1 < raw.count ? raw[i + 1].start : r.start + 6
            let end = max(nextStart, r.start + 0.5)
            let words: [WordTiming]
            if let real = r.words, !real.isEmpty {
                words = real
            } else {
                words = LyricsTimeline.synthesizeWords(text: r.text, start: r.start, end: min(end, r.start + 8))
            }
            lines.append(LyricLine(id: i, start: r.start, end: end, text: r.text, words: words))
        }
        return LyricsTimeline(lines: lines)
    }

    /// "mm:ss.xx" (or mm:ss / mm:ss.xxx) → seconds
    private static func parseTimestamp(_ tag: String) -> TimeInterval? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        return minutes * 60 + seconds
    }

    /// Enhanced LRC: "<00:12.34> word <00:12.80> word …" → word timings.
    /// Returns nil when the line has no inline tags (the common case).
    private static func parseEnhancedWords(_ content: String) -> [WordTiming]? {
        guard content.contains("<") else { return nil }
        // Extended delimiters: bare-slash regex literals need a feature flag
        // in Swift 5 language mode.
        let pattern = #/<(\d+):(\d+(?:[.,]\d+)?)>([^<]*)/#
        var stamped: [(start: TimeInterval, text: String)] = []
        for match in content.matches(of: pattern) {
            guard let m = Double(match.output.1),
                  let s = Double(match.output.2.replacingOccurrences(of: ",", with: "."))
            else { continue }
            let text = String(match.output.3).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            stamped.append((m * 60 + s, text))
        }
        guard stamped.count >= 2 else { return nil }

        var words: [WordTiming] = []
        for (i, item) in stamped.enumerated() {
            let end = i + 1 < stamped.count ? stamped[i + 1].start : item.start + 1.0
            // A stamped segment may contain several words; split them evenly.
            let subwords = item.text.split(separator: " ").map(String.init)
            let span = (end - item.start) / Double(max(subwords.count, 1))
            for (j, w) in subwords.enumerated() {
                let s = item.start + span * Double(j)
                words.append(WordTiming(text: w, start: s, end: s + span))
            }
        }
        return words
    }
}

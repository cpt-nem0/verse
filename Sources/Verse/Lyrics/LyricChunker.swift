import AppKit

/// Splits lines that are too wide for the compact wing into chunks at natural
/// word boundaries. Chunks crossfade; each gets its own animation pass with a
/// time window proportional to its share of the line's word timings.
/// The wing itself NEVER resizes per line.
enum LyricChunker {
    static func chunks(
        for timeline: LyricsTimeline,
        maxWidth: CGFloat,
        font: NSFont
    ) -> [LyricChunk] {
        var chunks: [LyricChunk] = []
        for line in timeline.lines {
            guard !line.isEmpty else { continue }
            let groups = splitWords(line.words, maxWidth: maxWidth, font: font)
            for (ci, group) in groups.enumerated() {
                guard let first = group.first, let last = group.last else { continue }
                // Chunk window: from its first word's start to the next chunk's
                // first word (or the line end for the last chunk).
                let nextStart = ci + 1 < groups.count ? groups[ci + 1].first!.start : line.end
                chunks.append(LyricChunk(
                    id: "\(line.id)-\(ci)",
                    lineIndex: line.id,
                    start: first.start,
                    end: max(nextStart, last.end),
                    text: group.map(\.text).joined(separator: " "),
                    words: group
                ))
            }
        }
        return chunks.sorted { $0.start < $1.start }
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func splitWords(
        _ words: [WordTiming],
        maxWidth: CGFloat,
        font: NSFont
    ) -> [[WordTiming]] {
        guard !words.isEmpty else { return [] }
        var groups: [[WordTiming]] = []
        var current: [WordTiming] = []
        for word in words {
            let candidate = (current.map(\.text) + [word.text]).joined(separator: " ")
            if !current.isEmpty && width(of: candidate, font: font) > maxWidth {
                groups.append(current)
                current = [word]
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Active chunk at time t (nil during instrumental gaps).
    static func activeChunk(in chunks: [LyricChunk], at t: TimeInterval) -> LyricChunk? {
        guard !chunks.isEmpty else { return nil }
        var lo = 0, hi = chunks.count - 1
        if t < chunks[0].start { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if chunks[mid].start <= t { lo = mid } else { hi = mid - 1 }
        }
        let chunk = chunks[lo]
        return t <= chunk.end ? chunk : nil
    }
}

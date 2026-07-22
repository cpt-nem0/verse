import SwiftUI

/// State 1: borderless black wings on either side of the physical notch.
/// The lyric reads across BOTH wings like a book spread: the current chunk
/// fills the left wing (trailing, flowing into the notch), and the next chunk
/// continues on the right wing. Chunks advance in pairs within a line.
/// Fixed widths — never resizes per line. No album art here — it lives in
/// the expanded header.
struct CompactWingView: View {
    @ObservedObject var model: AppModel
    let layout: NotchLayout
    var morph: Namespace.ID

    /// What the wings display at one instant: the pair of chunks and the
    /// pair's time window (used for a time-driven crossfade).
    private struct DisplayPair {
        var left: LyricChunk?
        var right: LyricChunk?
        var start: TimeInterval = 0
        var end: TimeInterval = 0
    }

    var body: some View {
        TimelineView(.animation) { _ in
            let t = model.lyricPosition()
            let pair = activePair(t: t)
            HStack(spacing: 0) {
                leftWing(t: t, pair: pair)
                    .frame(width: layout.leftWingWidth, height: layout.notchHeight)

                // The physical notch (plus breathing room) sits here;
                // keep it pure black.
                Color.clear
                    .frame(width: layout.notchGap, height: layout.notchHeight)

                rightWing(t: t, pair: pair)
                    .frame(width: layout.rightWingWidth, height: layout.notchHeight)
            }
            // Stable container carries the compact↔expanded morph, with an
            // explicit source so only one side of the morph is source at once.
            .matchedGeometryEffect(id: "currentLyric", in: morph, isSource: model.uiState != .expanded)
        }
    }

    /// The pair of chunks (left wing, right wing) on display at time t.
    /// Pairs are formed within a line: chunks (0,1), then (2,3), …
    /// Both nil during instrumental gaps — never show a stale line.
    private func activePair(t: TimeInterval) -> DisplayPair {
        guard case .synced = model.content,
              let active = LyricChunker.activeChunk(in: model.compactChunks, at: t)
        else { return DisplayPair() }
        let lineChunks = model.compactChunks.filter { $0.lineIndex == active.lineIndex }
        let idx = lineChunks.firstIndex(of: active) ?? 0
        let pairStart = idx - idx % 2
        let left = lineChunks.indices.contains(pairStart) ? lineChunks[pairStart] : nil
        let right = lineChunks.indices.contains(pairStart + 1) ? lineChunks[pairStart + 1] : nil
        return DisplayPair(
            left: left,
            right: right,
            start: left?.start ?? 0,
            end: (right ?? left)?.end ?? 0
        )
    }

    // MARK: - Left wing: first chunk of the pair
    // (No album art in compact — it lives in the expanded header.)

    @ViewBuilder
    private func leftWing(t: TimeInterval, pair: DisplayPair) -> some View {
        // Trailing-aligned so the text flows into the notch and continues
        // on the right wing.
        chunkView(pair.left, t: t, pair: pair)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 16)
            .padding(.trailing, 12)
    }

    // MARK: - Right wing: second chunk of the pair (or fallback title)

    @ViewBuilder
    private func rightWing(t: TimeInterval, pair: DisplayPair) -> some View {
        ZStack(alignment: .leading) {
            switch model.content {
            case .synced:
                chunkView(pair.right, t: t, pair: pair)
            case .plain, .none, .instrumental:
                // No synced lyrics: show the track title, static.
                Text(model.now.map { "\($0.title) — \($0.artist)" } ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shared chunk renderer

    /// Renders one chunk with a crossfade computed purely from playback time.
    /// No SwiftUI transitions here: `.id` + `.transition` swaps driven by
    /// `.animation(value:)` glitch inside TimelineView's per-frame re-renders
    /// (outgoing views get stranded mid-transition). Deriving opacity from `t`
    /// is glitch-proof and equally smooth.
    @ViewBuilder
    private func chunkView(_ chunk: LyricChunk?, t: TimeInterval, pair: DisplayPair) -> some View {
        if let chunk {
            LyricLineRenderer(
                words: chunk.words,
                text: chunk.text,
                start: chunk.start,
                end: chunk.end,
                theme: model.theme,
                style: .compact(),
                t: t
            )
            .opacity(pairFade(t: t, pair: pair))
        }
    }

    /// 0→1 in the pair window's first 0.25s, 1→0 in its last 0.25s — adjacent
    /// pairs read as a soft swap; the line's last pair fades out into the gap.
    private func pairFade(t: TimeInterval, pair: DisplayPair) -> Double {
        guard pair.end > pair.start else { return 0 }
        let ramp = min(0.25, (pair.end - pair.start) / 2)
        let fadeIn = (t - pair.start) / ramp
        let fadeOut = (pair.end - t) / ramp
        return max(0, min(1, min(fadeIn, fadeOut)))
    }

}

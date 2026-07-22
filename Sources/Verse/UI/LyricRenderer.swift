import SwiftUI

/// Colors + font for one rendering context (compact wing vs vibe mode).
struct LyricRenderStyle {
    var font: Font
    var bright: Color
    var dim: Color
    var accent: Color
    var isCompact: Bool

    static func compact() -> LyricRenderStyle {
        LyricRenderStyle(
            font: .system(size: 11, weight: .medium),
            bright: .white,
            dim: .white.opacity(0.32),
            accent: .white,
            isCompact: true
        )
    }

    static func vibe(_ palette: Palette) -> LyricRenderStyle {
        LyricRenderStyle(
            font: .system(size: 21.5, weight: .semibold, design: .serif),
            bright: palette.bright,
            dim: palette.bright.opacity(0.32),
            accent: palette.accent,
            isCompact: false
        )
    }
}

/// One renderer, four themes. The same animation language drives BOTH states.
/// Time is sampled per-frame by the caller (inside a TimelineView) and passed
/// in as `t`, so this view is pure.
struct LyricLineRenderer: View {
    let words: [WordTiming]
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let theme: LyricTheme
    let style: LyricRenderStyle
    let t: TimeInterval

    var body: some View {
        switch theme {
        case .lightWipe: wipe
        case .spotlight: spotlight
        case .typeOn: typeOn
        case .tracer: tracer
        }
    }

    // MARK: - Shared timing

    /// 0→1 sweep progress. Derived from word timings weighted by word length,
    /// which equals a constant-speed sweep for synthesized (line-level) data
    /// and snaps to word boundaries when real word-level data exists.
    private var sweepProgress: Double {
        guard !words.isEmpty else {
            let d = max(end - start, 0.3)
            return min(max((t - start) / d, 0), 1)
        }
        let totalChars = words.reduce(0) { $0 + Double($1.text.count + 1) }
        var done = 0.0
        for w in words {
            if t >= w.end {
                done += Double(w.text.count + 1)
            } else if t > w.start {
                let frac = (t - w.start) / max(w.end - w.start, 0.05)
                done += Double(w.text.count + 1) * frac
                break
            } else {
                break
            }
        }
        return min(max(done / max(totalChars, 1), 0), 1)
    }

    private var activeWordIndex: Int? {
        guard t >= start else { return nil }
        for (i, w) in words.enumerated() where t >= w.start && t < w.end { return i }
        return t >= end ? words.count - 1 : nil
    }

    // MARK: - Theme 3 (default): light wipe
    // Whole line at ~32% brightness; a wave of full brightness sweeps
    // left→right, synced to the vocal. Animated gradient text mask.

    private var wipe: some View {
        let p = sweepProgress
        let feather = 0.10
        return ZStack {
            lineText.foregroundStyle(style.dim)
            lineText
                .foregroundStyle(style.bright)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: max(p - feather, 0)),
                            .init(color: .clear, location: min(p + feather, 1)),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
        }
    }

    // MARK: - Theme 2: word spotlight
    // All words muted; exactly one bright word at a time, slight scale pop.

    private var spotlight: some View {
        let active = activeWordIndex
        return wordHStack { i, word in
            Text(word.text)
                .font(style.font)
                .foregroundStyle(i == active ? style.bright : style.dim)
                .scaleEffect(i == active ? 1.06 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: active == i)
        }
    }

    // MARK: - Theme 1: type-on
    // Line starts empty; each word rises in as it's sung. The FULL line is
    // laid out invisibly first (every word always occupies its slot), so
    // spacing and centering never shift as words appear.

    private var typeOn: some View {
        wordHStack { _, word in
            let revealed = t >= word.start
            Text(word.text)
                .font(style.font)
                .foregroundStyle(style.bright)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 5)
                .animation(.easeOut(duration: 0.28), value: revealed)
        }
    }

    // MARK: - Theme 4: underline tracer
    // Text fully lit and static; a hairline dash slides beneath, tracking
    // playback. Zero motion in the text itself.

    private var tracer: some View {
        let p = sweepProgress
        return lineText
            .foregroundStyle(style.bright)
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geo in
                    let dash: CGFloat = max(geo.size.width * 0.12, 18)
                    Capsule()
                        .fill(style.accent)
                        .frame(width: dash, height: 1.8)
                        .offset(x: (geo.size.width - dash) * p, y: 4)
                }
                .frame(height: 2)
            }
    }

    // MARK: - Helpers

    private var lineText: some View {
        Text(text)
            .font(style.font)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func wordHStack<W: View>(
        @ViewBuilder word: @escaping (Int, WordTiming) -> W
    ) -> some View {
        HStack(spacing: spaceWidth) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                word(i, w)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var spaceWidth: CGFloat {
        // Approximate the natural space width for the style's font size.
        style.isCompact ? 3.2 : 5.5
    }
}

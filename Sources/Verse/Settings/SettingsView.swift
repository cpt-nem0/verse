import SwiftUI
import ServiceManagement

/// Settings: theme picker ordered expressive → minimal with a live singing
/// preview, launch-at-login, and the two behavior options.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Theme — expressive → minimal
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Picker("", selection: $model.theme) {
                    ForEach(LyricTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Text("expressive")
                    Spacer()
                    Text("minimal")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

                ThemePreview(theme: model.theme, palette: model.palette)
                    .frame(height: 64)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Wait a beat before expanding (hover intent)", isOn: $model.hoverIntentDelay)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                HStack {
                    Text("During instrumentals")
                    Spacer()
                    Picker("", selection: $model.instrumentalStyle) {
                        ForEach(InstrumentalStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Lyric timing")
                        Spacer()
                        Slider(value: $model.syncOffset, in: -1.0...1.0, step: 0.05)
                            .frame(width: 150)
                        Text(String(format: "%+.2fs", model.syncOffset))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("Lyrics trailing the music? Drag right.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Toggle("Launch Verse at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            .font(.system(size: 12))

            Spacer(minLength: 0)

            Text("Verse — lyrics in your notch")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(20)
        .frame(width: 380, height: 380)
    }
}

/// Live singing preview: loops a demo line through the selected theme.
struct ThemePreview: View {
    let theme: LyricTheme
    let palette: Palette

    private static let demoText = "And the stars look very different today"
    private static let loopLength: TimeInterval = 4.5
    private static let demoWords: [WordTiming] = LyricsTimeline.synthesizeWords(
        text: demoText, start: 0.4, end: 3.9
    )

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.loopLength)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.background)
                LyricLineRenderer(
                    words: Self.demoWords,
                    text: Self.demoText,
                    start: 0.4,
                    end: 3.9,
                    theme: theme,
                    style: previewStyle,
                    t: t
                )
                .padding(.horizontal, 14)
            }
        }
    }

    private var previewStyle: LyricRenderStyle {
        LyricRenderStyle(
            font: .system(size: 15, weight: .semibold, design: .serif),
            bright: palette.bright,
            dim: palette.bright.opacity(0.32),
            accent: palette.accent,
            isCompact: false
        )
    }
}

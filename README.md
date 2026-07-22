# Verse — lyrics in your notch

A macOS menu bar app that displays time-synced lyrics for the currently
playing song, anchored to the MacBook notch. Invisible when idle, tiny when
playing, beautiful when you want it. Text never moves — only light moves
through it.

## Build & run

Requirements: macOS 14+, Xcode command line tools, `cmake` (`brew install cmake`), `git`.

```sh
chmod +x build.sh   # first time only
./build.sh run
```

That's it. The build script:

1. clones and builds [`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter)
   (BSD-3) — the community workaround for MediaRemote being restricted since
   macOS 15.4: `/usr/bin/perl` is Apple-entitled to load the framework, so a
   tiny helper streams now-playing JSON to Verse;
2. builds the Swift package (`swift build -c release`);
3. assembles and ad-hoc signs `build/Verse.app`.

On first launch macOS may ask permission for Verse to control Spotify /
Music — that's the AppleScript fallback path and click-to-seek.

## How it works

- **Two states.** Compact "wings" extend the physical notch: album art on the
  left, the current lyric line on the right (fixed width, never resizes per
  line; long lines break into chunks that crossfade). Hover ~150ms and it
  melts open into **vibe mode** — a karaoke panel tinted with the album art's
  dominant color at ~12% lightness, three serif lines, click any line to seek,
  scrubber, transport, pin. Scroll inside to browse the full lyric; it snaps
  back after 4s.
- **The morph.** The compact lyric line morphs into the vibe-mode current line
  via `matchedGeometryEffect` — one shared element, not two crossfading views.
  (Font interpolation sans→serif is a crossfade layered inside the shared
  frame; SwiftUI can't tween typefaces.)
- **Four themes**, one setting, both states, ordered expressive → minimal:
  **Type-on** (words rise in as sung, layout pre-fixed so nothing shifts),
  **Word spotlight** (one bright word at a time, slight pop),
  **Light wipe** (default — brightness wave sweeps the line via an animated
  gradient mask), **Underline tracer** (static text, sliding hairline in the
  accent color).
- **Timestamp fallback.** LRCLIB is usually line-level only; word timings are
  synthesized across each line's duration, weighted by word length, so every
  theme always works. Real word-level data snaps to word boundaries when present.
- **Now playing.** MediaRemote adapter (system-wide, any player) with an
  AppleScript fallback for Spotify / Apple Music. Position is polled sparsely
  and interpolated with a local monotonic clock for 120Hz-smooth animation.
- **Lyrics.** [LRCLIB](https://lrclib.net) matched on track + artist + album +
  duration, cached in `~/Library/Application Support/Verse/lyrics` so repeat
  plays are offline. No synced lyrics → track title in the wing; unsynced
  plain lyrics → static text in vibe mode; instrumentals → breathing dots.

## Project layout

```
Sources/Verse/
  VerseApp.swift              entry point + app delegate
  AppModel.swift              central state machine + settings
  NowPlaying/                 adapter provider, AppleScript fallback,
                              coordinator, interpolating clock
  Lyrics/                     LRCLIB client + cache, LRC parser (line- and
                              word-level), timeline engine, wing chunker
  Color/Palette.swift         dominant-color extraction → derived palette
  UI/                         notch panel + pass-through hit testing,
                              compact wings, vibe mode, 4 theme renderers
  Settings/                   settings window with live singing preview
```

## Notes

- The notch panel is a borderless non-activating `NSPanel` above the menu
  bar, joined to all Spaces including fullscreen. Clicks pass through
  everywhere except the visible shape.
- Pinned mode auto-collapses when a fullscreen space becomes frontmost.
- Deliberately excluded from v1 (restraint): volume, like/favorite,
  shuffle/repeat, lyrics search, notchless floating-pill mode, word-data editor.
- No notch? It still runs, using an island-shaped fallback sized off the
  menu bar (the polished notchless mode is planned for v1.x).

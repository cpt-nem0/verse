# Verse — lyrics in a floating pill

A macOS app that displays time-synced lyrics for the currently playing song in
a slim, draggable glass pill that is always on top and never in the way. Click
the pill and it unfurls into a translucent karaoke popup. Design philosophy:
calm when idle, tiny when playing, beautiful when you want it.

**Design authority:** `docs/superpowers/specs/2026-07-23-verse-pill-revamp-design.md`
(including its "Design revision A" section, which supersedes conflicting lines).
This file summarizes the product; when they disagree, the spec wins.

## Product summary

- **Name:** Verse. Tagline: "Verse — lyrics in a pill."
- **Platform:** macOS 14+ (any Mac — no notch dependency; the old notch-docked
  mode was removed in 2.0 and lives only in git history).
- **Core loop:** song plays → the idle ball inflates into the lyric pill →
  the current line animates through it per the active theme → click opens the
  glass popup (3-line karaoke, scrubber, transport) → Esc/click-outside exhales
  it back into the pill → music stops → the pill contracts to the ball.

## The pill

One line of text in a capsule, ~13pt, horizontal padding 16pt, height 30pt.

- **Material (revision A):** translucent BLACK glass — `NSVisualEffectView`
  (hudWindow, behind-window blending) under a neutral black wash (~0.6), a
  hairline white border (0.08), and a soft black shadow (0.25 / radius 10 / y 3).
  NO album-hue wash and NO accent glow on the material: the album palette
  colors only the lyric text (and popup content tints). Raycast-like, techie.
- **Dynamic width (revision A):** the capsule hugs the current line —
  `clamp(textWidth + 32, 30, min(38% of screen width, 460))`, spring-animated
  per line change (never per frame; the model measures and publishes the
  target). Lines wider than the max are split into sequential chunks at word
  boundaries with time-driven crossfades. Paused freezes the width with the
  frozen lyric.
- **Idle ball (revision A):** when NO music plays the pill does not disappear —
  it contracts into a 30pt circular ball with a translucent `music.note` glyph
  (white 40%). Draggable; left/double clicks are inert until a track loads;
  right-click menu always works. "Hide until next song" also contracts to the
  ball until the track changes. No TimelineView is mounted while idle (CPU ~0).
- **Edge-anchored growth (revision A):** width changes respect where the user
  parked the pill. The pill center's screen third at drag-end picks the anchor:
  left third → left edge fixed (grows rightward), right third → right edge
  fixed (grows leftward), middle → centered symmetric. The persisted position
  (`verse.pillAnchor`, "mode,x,y,displayID" — `PillAnchorRecord`; the 3-field
  form written before multi-screen support still parses, with an unknown
  display) is the anchor point, so the anchored edge never moves as lines
  change. Clamped to `NSScreen.visibleFrame` (never under the menu bar or
  dock). The displayID is load-bearing: panel space is per-screen, so an
  anchor restored on a display it wasn't captured on is re-parked on its rail
  (keeping the parked height) instead of trusting coordinates that would strand
  the pill mid-screen.
- **States:** pre-first-line / plain / no lyrics → "♪ Title — Artist" dimmed
  (title cleaned of feat/remaster noise); singing → the active theme's
  animation; echo lines (text fully inside `(…)`/`[…]`) → italic serif at 75%
  size / 55% brightness, soft time-fade, no karaoke animation; instrumental
  break >3s → capsule contracts (~44pt; ~30pt past 15s) with 2–3 small
  music-note glyphs rising ~9pt and fading on a staggered ~2.2s loop
  (revision A — replaces breathing dots in the pill); paused → wipe freezes
  mid-word, pill dims to 60% with a ~3s breathing pulse.
- **Gestures:** drag anywhere (3pt threshold, manual global-space drag,
  position persists); click → popup; double-click → play/pause with a press
  bounce (ExclusiveGesture — double-click never opens the popup); right-click →
  context menu (Theme submenu, Screen submenu, Lyric timing ±0.1/±0.5/reset,
  Hide until next song, Settings…, Quit).
- **Screen (multi-display):** the Screen submenu appears only with 2+ displays
  and lists `NSScreen.localizedName`, checkmarked on the panel's current
  screen; picking one moves the panel there, re-parks the pill on the same
  rail, and persists that display's `CGDirectDisplayID` under
  `verse.screenID`. `ScreenPicker.resolve` (pure) decides the host screen at
  launch and on `didChangeScreenParameters`: explicitly picked display, else
  the display the parked anchor was captured on, else `NSScreen.main`, else the
  first screen — the explicit preference is never cleared, so re-plugging that
  display brings the pill back to it.

## The popup

A 400×248 glass card anchored to the pill: grows downward from the pill's top
when the pill is in the screen's top half, upward from its bottom otherwise;
horizontally centered on the pill, clamped to the visible frame. The pill's
lyric line morphs into the popup's current line (`matchedGeometryEffect`, one
shared element — never a crossfade of two).

- **Material:** same neutral dark glass as the pill (blur + black 0.6, radius
  20, hairline border, soft shadow). Album color appears only in content tints.
- **Header:** 36px album art (radius 9, click → open the source player),
  cleaned title (13.5 semibold, bright tint), artist (11, muted), icon-only
  source glyph at right.
- **Lyrics:** exactly 3 serif lines — previous/next small italic ~35% opacity,
  current line large (base 21.5) with the theme animation and fit-to-width
  scaling (FittedFont, floor 60% — never per-word ellipsis). Echo current line
  renders italic 75%/55% with no animation. Click any line to seek (instant).
  Scroll → full-lyrics browse list, snaps back after 4s idle.
- **Scrubber:** 3px, thickens on hover, draggable, tabular timestamps.
- **Transport row:** prev / play-pause / next centered; settings glyph left;
  pin right (pin keeps the popup open on outside clicks; pinned auto-collapses
  when a fullscreen app starts).
- **Dismiss:** click outside (unless pinned) or Esc → exhale morph back into
  the pill. Opening the popup re-syncs the playback clock immediately.

## The four themes

One theme setting drives the line animation in BOTH the pill and the popup.
Ordered expressive → minimal (this ordering IS the settings UI — a segmented
control with a live animated preview):

1. **Type-on** (expressive): words fade/rise in as sung; full line laid out
   invisibly first so centering never shifts.
2. **Word spotlight:** all words muted; exactly one bright word at a time with
   a slight scale pop (~1.06).
3. **Light wipe** (DEFAULT): whole line at ~32% brightness; a wave of full
   brightness sweeps left→right synced to the vocal (animated gradient mask).
4. **Underline tracer** (minimal): text fully lit and static; a hairline
   accent dash slides beneath the line. Zero motion in the text itself.

### Timestamp fallback (all themes)

LRCLIB usually provides line-level timestamps only. Word timings are
synthesized by distributing the line duration across words weighted by length —
sweeps read constant-speed with line-level data and snap to word boundaries
when real word-level data exists. Never disable a theme for missing word data.

## Engineering rules

- **Animation:** springs everywhere, nothing over ~450ms. Content crossfades
  inside `TimelineView` must be playback-time-driven, NOT SwiftUI transitions
  (`.id`/`.transition` swaps strand outgoing views mid-transition in per-frame
  re-renders — see `PillView.chunkFade`). State-change animations (uiState
  morph, width springs) are regular SwiftUI springs routed through
  `Motion.spring`, which collapses every spring to a ≤200ms fade when the
  system Reduce Motion setting is on; scale choreography (bounce, breathing,
  rising notes) turns off entirely under Reduce Motion.
- **Battery:** all TimelineViews honor `AppModel.frameInterval` (30fps cap in
  Low Power Mode); the idle ball mounts no TimelineView at all.
- **Complex SwiftUI expressions** can hit type-checker timeouts — hoist math
  into typed helper functions (precedent: `BreathingDots`, `RisingNotes`).
- **Coordinate spaces:** AppKit screen space is bottom-left; the SwiftUI panel
  space is top-left. Every conversion lives in `PillLayout` (documented there);
  don't do ad-hoc flips.

## Technical architecture

- **UI:** one full-screen transparent non-activating `NSPanel` (`.borderless +
  .nonactivatingPanel`, level statusBar+1, `.canJoinAllSpaces/.stationary/
  .fullScreenAuxiliary`) hosts the SwiftUI hierarchy. The pill is positioned by
  a model-owned anchor point — drag moves the view, never the window.
  `PassThroughHostingView.hitTest` keeps only the pill/popup shape clickable;
  everything else passes through. Esc/click-outside dismissal via local+global
  event monitors.
- **Allowed sources (2026-07-25 expansion):** native music apps by bundle ID
  (Spotify, Apple Music, YouTube Music desktop, TIDAL, Deezer, Amazon Music,
  Plexamp, VOX, Swinsian — `NowPlayingCoordinator.musicApps`), plus WEB
  players in known browsers when the tab publishes music-shaped metadata
  (artist AND album via MediaSession — plain videos don't), gated by the
  "Web players" settings toggle (`verse.webPlayers`, default on). Position
  re-anchor polling remains Spotify/Apple Music only
  (`scriptableSources`); other sources ride adapter timestamps.
- **Now playing:** MediaRemote adapter (community `mediaremote-adapter`
  helper — MediaRemote is restricted since macOS 15.4) with an AppleScript
  polling fallback. `PlaybackClock` interpolates between sparse updates;
  `PositionPoller` re-anchors it every ~2s while playing (osascript, background
  queue, corrects only drifts >0.3s, self-stops after repeated failures) and
  immediately on popup open.
- **Lyrics:** LRCLIB (https://lrclib.net) — synced .lrc matched on
  title/artist/album/duration with title-variant cleaning (`TitleCleaner`),
  retries, and a disk cache (repeat plays render offline/instantly). Fallbacks:
  plain lyrics → static text; nothing → title in the pill + empty state in the
  popup. Echo detection flags `(…)`/`[…]` lines and inline spans at parse time.
- **Color:** dominant-hue extraction from album art (`Palette`), cached per
  album. Revision A: the palette tints TEXT and popup content only — the glass
  material is always neutral black.
- **Menu bar item:** minimal NSStatusItem (Settings…/Quit only).
- **Settings:** theme segmented control with live preview, instrumental style
  (popup indicator), lyric timing slider (same value as the right-click
  nudges), launch at login.

## Build & test

- `./build.sh` → build Verse.app into ./build; `./build.sh run` → build+launch;
  `./build.sh install` → copy to /Applications; `./build.sh clean`. Requires
  Xcode CLT + cmake (clones/builds mediaremote-adapter on first run).
- **Tests:** no XCTest on this machine. Logic checks live in
  `Sources/Verse/Checks/` (debug-only) and run via
  `swift run Verse --checks` → expect `ALL CHECKS PASSED`. Add a
  `*Checks.swift` file + register it in `Checks.swift` for any new pure logic.
  `VerseChecks.runIfRequested()` must stay the first statement of the entry
  point.
- Zero compiler warnings is the bar for every commit.

## Restraint (deliberately excluded)

No hover-expand (click is the trigger), no notch-docked mode, no volume
slider, no like/favorite, no shuffle/repeat, no lyrics search, no share
cards, no BPM effects, no fifth theme, no browser sources. Every control not
added keeps the pill calmer. (Peek hotkey was cut from 2.0 scope.)

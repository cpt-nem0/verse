# Verse — lyrics in your notch

A macOS menu bar app that displays time-synced lyrics for the currently playing song, anchored to the MacBook notch. Design philosophy: invisible when idle, tiny when playing, beautiful when you want it. Text never moves — only light moves through it.

This file is the complete design spec, finalized in a design session. Follow it closely; the visual decisions here are locked unless the user says otherwise.

## Product summary

- **Name:** Verse. Tagline: "Verse — lyrics in your notch."
- **Platform:** macOS (Apple Silicon MacBooks with notch as primary target; notchless fallback mode planned later, not v1).
- **Core loop:** song plays → notch grows "wings" showing the current lyric line (compact state) → hover expands into "vibe mode," a full karaoke panel tinted with the album art color → mouse leaves, it springs back.

## The two states

### State 1 — Compact ("wings")

A borderless black extension on either side of the physical notch so notch + app read as one continuous shape.

- The lyric reads across BOTH wings like a book spread: the current chunk fills the left wing (trailing-aligned, flowing into the notch), and the next chunk continues on the right wing (leading-aligned). Chunks advance in pairs within a line, ~11pt, animated per the active theme (see Themes). No album art in compact — it lives in the expanded header. The notch gap keeps 12pt of black padding on each side of the physical notch.
- **Fixed wing width** regardless of line length — never resize per line (seasick). Wings are EQUAL width on both sides, sized so the compact bar matches the expanded panel's width — hover-expand grows straight down with zero horizontal movement. Capped at ~40% of the space between the notch and the menu bar status items/clock, measured at launch. Art dot sits snug against the notch (trailing-aligned in its wing).
- Lines longer than the wing: do NOT marquee-scroll. Break into chunks at natural word boundaries, crossfade between chunks, each chunk gets its own animation pass.
- Instrumental breaks: fade the lyric out; the album art dot stays with a slow breathing pulse. Never show a stale line.
- Idle (nothing playing): the app is fully invisible. Notch untouched.

### State 2 — Expanded ("vibe mode")

On hover, the compact wing melts open into a panel (~500–520px wide) that appears to grow out of the notch, with large bottom corner radius (~24–26px).

- **Background:** album art's dominant color darkened to ~12% lightness. Dark enough to blend with the pure-black physical notch, tinted enough to feel alive. All other colors in the panel derive from this hue (bright tint for current lyric, ~35% opacity mid-tone for neighbor lines, muted tint for secondary UI).
- **Header row:** album art (~40px, rounded 10px, clickable → opens the source player), track title + "Artist · Album", small source badge (e.g. Spotify icon + name) on the right.
- **Lyrics area:** exactly 3 lines in serif (New York / system serif).
  - Previous line above: small (~14pt), italic, ~35% opacity.
  - Current line center: large (~21–22pt), animated per the active theme.
  - Next line below: small, italic, ~35% opacity.
  - Clamp every line to one row (ellipsis) so panel height never jumps.
  - **Click any line to seek** playback to that line's timestamp. This is a signature feature — must feel instant.
  - Scroll inside the panel → temporarily switches to a full-lyrics list view; snaps back to 3-line follow mode after 4s of no scrolling.
- **Scrubber:** thin (3px) progress bar, thickens on hover, draggable. Tabular-numeral timestamps on both ends.
- **Control row:** transport (prev / play-pause / next) centered. Left corner: theme/settings icon. Right corner: pin icon.
- **Pin:** keeps the panel open (for singing along / cooking). Pinned mode auto-collapses when a fullscreen app or video starts.
- **Collapse:** ~600ms after mouse leaves (unless pinned), soft spring back into the compact wing.
- **Line transitions:** lines slide up with a spring on each timestamp.

### Signature transition

The compact lyric line must MORPH into the vibe-mode current line on expand — shared element via `matchedGeometryEffect`: position moves, font grows and changes sans → serif. This single shared element is what makes the app feel liquid. Do not fade-out/fade-in two separate views.

## The four themes

One theme setting drives the word/line animation in BOTH states (compact and expanded). Same animation language everywhere.

Ordered from most expressive to most minimal (this ordering IS the settings UI — a segmented control from "expressive" to "minimal" with a live animated preview in the settings window):

1. **Type-on** (expressive): the line starts empty; each word fades/rises in (small translateY + opacity) at the moment it's sung; the whole line dissolves before the next. CRITICAL: lay out the FULL line invisibly first so spacing is fixed, then reveal words in place — never let the line's centering shift as words appear.
2. **Word spotlight:** all words rendered muted/grey; the currently sung word turns white (full-bright tint in vibe mode) with a slight scale pop (~1.06). Only the current word is bright — inverse highlight, exactly one bright word at a time.
3. **Light wipe** (DEFAULT): entire line visible at ~30–35% brightness; a wave of full brightness sweeps left-to-right through the text synced to the vocal. Implement as an animated gradient text mask.
4. **Underline tracer** (minimal): text stays fully lit and static; a 1.5–2px hairline in the album accent color slides beneath the line tracking playback. Zero motion in the text itself.

### Timestamp fallback (applies to all themes)

- LRCLIB usually provides line-level timestamps only; word-level is rare.
- **Wipe:** with line-level data, sweep at constant speed across the line's duration. With word-level data, snap the sweep to word boundaries. Same visual either way.
- **Spotlight / type-on:** with line-level data only, distribute word timings evenly across the line duration, weighted by word length. Must look intentional; never disable a theme because word data is missing.
- **Tracer:** constant-speed slide across line duration; snap to words when available.

## Open decisions (ask the user before implementing these two)

1. Hover-expand behavior: instant open vs ~150ms hover-intent delay (recommended: 150ms delay to avoid accidental triggers).
2. Instrumental-break display in expanded view: breathing three-dot indicator (recommended, Apple Music style) vs countdown to next line vs enlarged album art.

## Technical architecture

- **UI:** SwiftUI inside a borderless, non-activating `NSPanel` (`.nonactivatingPanel`, `.borderless`), window level above the menu bar (`.statusBar` + 1 or `.screenSaver`), `collectionBehavior` including `.canJoinAllSpaces`, `.stationary`, `.fullScreenAuxiliary`. Ignore mouse events outside the visible shape.
- **Notch geometry:** read `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea` + `auxiliaryTopRightArea` to compute the notch frame and position the panel exactly.
- **Allowed sources (v1):** only dedicated music apps drive the notch — Spotify (`com.spotify.client`) and Apple Music (`com.apple.Music`). Browser audio is ignored entirely (system now-playing can't distinguish YT Music from any other tab; browser support is a later feature).
- **Now playing detection:** the private MediaRemote framework is restricted since macOS 15.4. Use the community approach current at build time (check how BoringNotch / MediaRemoteAdapter handle it — typically a helper process or adapter). Fallbacks: Spotify and Apple Music AppleScript APIs (`tell application "Spotify" ...`) for track metadata + playback position. Poll position sparingly; interpolate between polls with a local clock for smooth animation.
- **Lyrics:** LRCLIB (https://lrclib.net) — free, open API returning synced .lrc. Match on track name + artist + album + duration. Cache lyrics locally (song ID → lrc) so repeat plays are offline. Handle: no lyrics found (show track title only in the wing), plain unsynced lyrics (show static line, no animation).
- **Color extraction:** dominant color from album artwork (k-means or CIAreaAverage on downsampled art), then transform: background = hue at ~12% lightness, foreground tints derived from same hue. Cache per album.
- **Animation:** SwiftUI springs throughout (`.spring(response:dampingFraction:)`), `matchedGeometryEffect` for the compact↔expanded morph. Target 120Hz ProMotion smoothness; avoid offscreen rendering and re-layout during animation (animate masks/opacity/transforms, not text layout).
- **Menu bar item:** minimal NSStatusItem for settings/quit (the notch UI itself is the product; keep the status item nearly invisible).
- **Settings window:** theme picker as expressive→minimal segmented control with a live singing preview, launch-at-login toggle, the two open-decision behaviors once decided.

## Restraint (deliberately excluded from v1)

No volume slider, no like/favorite, no shuffle/repeat, no lyrics search, no notchless floating-pill mode (planned v1.x), no word-by-word data editor. Every control not added makes the panel calmer.

## Build order suggestion

1. NSPanel positioned at the notch + compact wing with static text.
2. Now-playing pipeline (metadata + position interpolation).
3. LRCLIB fetch + cache + line sync.
4. Theme 3 (light wipe) in compact state.
5. Vibe mode layout + album color extraction.
6. The matchedGeometryEffect morph.
7. Remaining three themes (shared timing engine, four renderers).
8. Click-to-seek, scrubber, pin, scroll-to-browse.
9. Settings window with live preview.
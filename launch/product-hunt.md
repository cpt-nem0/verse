# Verse — Product Hunt launch kit

Everything ready to paste into the PH submission form. Gallery images in
this folder (`ph-slide-1..5.png`, 1270×760 — slide 1 is the thumbnail-maker).

## Name

Verse

## Tagline (pick one, 60-char limit)

1. `Lyrics in a pill — floating, time-synced, always on top` (55)
2. `Your Mac sings along — time-synced lyrics in a glass pill` (57)
3. `Time-synced lyrics in a tiny glass pill on your Mac` (51)

## Description (260-char limit)

> Verse floats a slim glass pill above everything on your Mac and sings the
> current line of whatever's playing — Spotify, Apple Music, YouTube Music
> and more. Click it and it unfurls into a karaoke card. Free, open source,
> works on every Mac. (247)

## Links

- Website: https://verse.3am.quest
- GitHub: https://github.com/cpt-nem0/verse

## Topics

Mac · Music · Open Source · Design Tools · Productivity

## Maker's first comment (post immediately after launch goes live)

> Hey Product Hunt 👋
>
> I built Verse for the 3am version of me — headphones on, something
> playing, mouthing words I only half know. Every lyrics app wanted a whole
> window for that. I wanted one line, exactly when it's sung, and otherwise
> nothing.
>
> So Verse is a pill. A slim piece of black glass that floats over
> everything, hugs the current lyric, and gets out of the way — it contracts
> to a tiny dot when the music stops. Click it and it unfurls into a karaoke
> card with a scrubber. Drag it anywhere, park it on any screen.
>
> Some details I obsessed over:
> — Four line-animation themes, from type-on to a minimal underline tracer
> — Album art tints only the text; the glass stays black (Raycast vibes)
> — Echoes and ad-libs (the parenthesis parts) render soft and italic
> — Lyrics come from LRCLIB's open catalog and cache offline
>
> It's free, MIT-licensed, and works on any Mac on macOS 14+. The website
> demo is the actual product recreated in CSS — grab the pill and drag it
> around the page.
>
> One line to install: `brew install --cask cpt-nem0/tap/verse`
>
> Would love your feedback — especially which theme you end up on.

## Launch-day checklist

- [ ] Release v2.1.0 published (multi-screen build) and cask sha bumped
- [ ] verse.3am.quest loads, OG card renders (paste the link in a private
      Slack/X DM to check the preview)
- [ ] Schedule launch for 12:01 AM Pacific (PH day resets then; full 24h of
      voting)
- [ ] Post maker's comment within the first 10 minutes
- [ ] Reply to every comment — comment velocity matters as much as votes
- [ ] Cross-post: X thread with the pill-drag screen recording, r/macapps,
      Hacker News "Show HN" (space HN a day or two after PH)
- [ ] Pin the PH badge + install one-liner on the GitHub README after launch

## Post-launch

- At ~75 GitHub stars: notarize (Apple Developer, $99/yr) and submit to
  homebrew/cask — token `verse` is unclaimed. Drop the quarantine postflight
  from the official cask.

# Suggestions

What people using Replay suggest: a backlog of lower priority than
[ROADMAP.md](ROADMAP.md) (what's planned) and [ISSUES.md](ISSUES.md) (what's
broken). A suggestion stays here until it's planned (it moves to the roadmap),
done, or turned down (it goes, with a word why in the history).

One line each: `[area] the suggestion (who, when)`. A longer note can follow,
indented under it.

## Editor

- [retina] Fonts and the node graph could be crisper on macOS Retina: today they look stretched up 2x from the
  normal scale (bilinear) rather than drawn at the display's density. Everything else works there: events land
  where they should. (a macOS user, 2026-10)
  Checked 2026-10-21: right. The window is made without `SDL_WINDOW_HIGH_PIXEL_DENSITY`
  (replay.c), so macOS gives us a 1x backbuffer and stretches it. Moved to
  [ISSUES.md](ISSUES.md) ([HiDPI]) with the fix it needs.

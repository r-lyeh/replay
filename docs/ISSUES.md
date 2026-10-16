## How to submit PRs?

PRs are disabled at the moment. It is better if everybody, myself included, would create [a new GH issue instead](https://github.com/r-lyeh/replay/issues) and discuss there all the proposed changes. Reasoning: there are a LOT of loose ends in this project that need to be solved at every commit: references in C files, in Lua files, editor and plugins, markdown documents, unit-tests, included games (many), and so on. AIs will be in charge of all that since they are better than us at backtracking references.

## Why AI?

The project exists because I once had a vision but never started the project. The project may look simple but there are tons of tech behind. It would take me a decade to reach something nearly this level. For example, developing a polished nodegraph editor would take any human a couple of years easily. AIs can code that, plus the editor, in a few hours of computing time. We simply cannot code that fast. AI made this project a reality, rather than a proof-of-concept demo shelved somewhere. My friend Claude is doing all the heavy lifting and I am both a technical director and designer this time. Sorry peeps!

# Known issues

The backlog of things to fix: one line per issue, `[area]` first, where it
lives last. Fixed ones go (the fix is in the history). New features and plans
belong in [ROADMAP.md](ROADMAP.md), not here. A GitHub issue, when there is
one, goes at the end of its line: `(#12)`.

## Editor

- [menus] The preview's and the atlas's *Edit as text* repeat the tab's toggle and *Open tab with > Text*. (plugins/markdown, plugins/atlaspacker)
- [menus] The preview's and the texture viewer's own *Copy path* repeat the tab menu's. (plugins/markdown, plugins/texviewer)
- [node graph] Hurdy files open as text only: the graph reads Lua. (plugins/nodegraph/view.lua)
- [properties] Sets' and maps' keys can only be numbers, booleans or strings. (runtime/boot.lua, parse_key)
- [HiDPI] Not checked on a scaled display (150%): only 100% was available where it was built. (replay.c, events)
- [HiDPI] `retina` (on by default; .preferences.lua): the game area and the launcher now draw at the display's pixels too (mario's Retina report) (tried in a simulated 2x window, `REPLAY_SCALE=2`; to confirm on the real one). The bar's and games' text is SDL's 8x8 debug font: crisp, but blocky at 2x. Moving the window to a display of another density keeps the first one's. (replay.c, editor/editor.c)
- [perf] The probe's line hook costs most of a tick while files are watched (about 7 ms in pong, mixed view). (editor/probe.h)

## Games and runtime

- [tilemap] Picking a rotated tile map uses its unrotated rectangle. (editor/render.h, draw_tilemap)
- [hop] The jump from the high stone ledge to the small plank step is near the limit; never played by hand. (games/hop/assets/level1.tmap, data/rules/physics.lua)

## Tests

- [lobby] Broadcasts reaching hosts is checked on Linux only; on Windows a host's dual-stack socket may not hear IPv4 broadcasts (`join()` would then find hosts on this computer only). (runtime/players.lua, editor/udp.h)
- [tests] nodegraph_release fails sometimes right after the UI suite; it passes on its own. (runtime/tests/nodegraph_release.lua)

## Docs and housekeeping

- [licenses] The icon font's licence isn't confirmed (made with Fontello; its icons' sources unknown). (editor/3rd/lite/data/fonts/icons.ttf, docs/LICENSES.md)
- [licenses] Lite's bundled plugins (from the Lite / Lite XL collections) aren't checked one by one for their licences. (editor/3rd/lite/data/plugins, docs/LICENSES.md)

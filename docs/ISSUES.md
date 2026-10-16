# Known issues

The backlog of things to fix: one line per issue, `[area]` first, where it
lives last. Fixed ones go (the fix is in the history). New features and plans
belong in [ROADMAP.md](ROADMAP.md), not here. A GitHub issue, when there is
one, goes at the end of its line: `(#12)`.

## Editor

- [menus] The preview's and the atlas's *Edit as text* repeat the tab's toggle and *Open tab with > Text*. (plugins/mdviewer, plugins/atlaspacker)
- [menus] The preview's and the texture viewer's own *Copy path* repeat the tab menu's. (plugins/mdviewer, plugins/texviewer)
- [menus] The tree's right-click menu and the main menu are drawn in C, not by canvas.menu: a look of their own (close, not the same). (editor/tab.h, editor/bar.h)
- [menus] The tree's right-click menu takes one submenu only, so it has *Open tab with >* but no *Open beside with >*. (editor/tab.h, pick lists)
- [breakpoints] A breakpoint on a line that runs at load (top-level code) never stops; it's drawn hollow. Running the load in a coroutine would fix it. (runtime/probe.lua, editor/probe.h)
- [node graph] hurdy files open as text only: the graph reads Lua. (plugins/nodegraph/view.lua)
- [properties] Sets' and maps' keys can only be numbers, booleans or strings. (runtime/boot.lua, parse_key)
- [HiDPI] Not checked on a scaled display (150%): only 100% was available where it was built. (play.c, events)
- [perf] The probe's line hook costs most of a tick while files are watched (about 7 ms in pong, mixed view). (editor/probe.h)

## Games and runtime

- [tilemap] A game's tile map can't use a `plugin:` tileset (drawn as a magenta outline): copy the picture into the game's assets/. (editor/render.h, draw_tilemap)
- [tilemap] Picking a rotated tile map uses its unrotated rectangle. (editor/render.h, draw_tilemap)
- [hop] The jump from the high stone ledge to the small plank step is near the limit; never played by hand. (games/hop/assets/level1.tmap, data/rules/physics.lua)

## Tests

- [tests] The online and seats suites (real UDP on localhost) fail now and then on timing. (the suites' runner, runtime/tests/netUdp.lua)
- [tests] nodegraph_release fails sometimes right after the UI suite; it passes on its own. (runtime/tests/nodegraph_release.lua)
- [tests] The suites' runner isn't in the repo yet. (suites.sh)

## Docs and housekeeping

- [licenses] The icon font's licence isn't confirmed (made with Fontello; its icons' sources unknown). (3rd/lite/data/fonts/icons.ttf, docs/LICENSES.md)
- [licenses] lite's bundled plugins (from the lite / Lite XL collections) aren't checked one by one for their licences. (3rd/lite/data/plugins, docs/LICENSES.md)
- [device] games/asteroids/screen.lua is an old file of mine (its window size, now config/window.lua): delete it by hand.

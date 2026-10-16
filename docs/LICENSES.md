# Licenses

Every licence in this repository: Replay's own, then each third-party part,
where it lives and what it asks. A new dependency or asset gets its line here
when it comes in. (A summary, not legal advice: the licence files themselves
are what count.)

## Replay

| What | Where | Licence |
|---|---|---|
| Replay's own code, docs and tools | everything not listed below | your choice of [μLicense](https://github.com/r-lyeh/uLicense), [Unlicense](https://unlicense.org/), [0-BSD](https://opensource.org/licenses/0BSD) or [MIT-0](https://github.com/aws/mit-0) ([LICENSE.μ](../LICENSE.μ)). None asks for attribution |
| The demo games' pictures (asteroids, lcd, hop's level), the docs' screenshots and the markdown viewer's emoji | `games/*/assets/`, `docs/images/`, `plugins/markdown/emoji/` | Replay's, as above (drawn by scripts made for Replay) |
| The tilemap editor's tileset | `plugins/tilemap/tiles.png`, `tiles.lua` (also `games/hop/assets/tiles.png`) | CC0 1.0 ([LICENSE-tiles.txt](../plugins/tilemap/LICENSE-tiles.txt)): drawn by `plugins/tilemap/tools/make_tiles.py` |
| Deepisle's sprites | `games/common/deepisle.png` | CC0 1.0, ours: drawn by `games/common/tools/make_deepisle.py` (pixel art as text) |

## Third-party

| What | Where | Licence | It asks |
|---|---|---|---|
| Lite, the text editor (rxi), and its Replay fork (r-lyeh) | `lite/` | MIT, © 2020 rxi ([lite.license](../editor/3rd/lite/data/lite.license), `lite.h`'s header) | keep the notice |
| Lite's themes (Lite XL team, lite-xl-colors) | `themes/` | MIT, © 2020-present Lite XL team ([LICENSE](../editor/3rd/lite/data/themes/LICENSE)) | keep the notice |
| Lite's plugins from the Lite / Lite XL plugin collections | `plugins/` (the ones that aren't Replay's) | MIT, as their collections (not checked one by one: see [ISSUES.md](ISSUES.md)) | keep the notice |
| Roboto, Roboto Mono (Google; Lite's UI and code fonts) | `font.ttf`, `font_bold.ttf`, `monospace.ttf` | Apache 2.0 (named in the fonts) | keep the notice; say if changed |
| Lite's icon font (made with Fontello) | `icons.ttf` | not confirmed: Fontello fonts take their icons' licences (often SIL OFL 1.1 or MIT): see [ISSUES.md](ISSUES.md) | ? |
| stb_image, stb_image_write, stb_truetype (Sean Barrett) | `stb_*.h` | your choice of public domain (Unlicense) or MIT (each file's end) | nothing (public domain) |
| Lua (PUC-Rio) as minilua (Eduardo Bart) | `minilua/` | MIT, © 1994–2026 Lua.org, PUC-Rio; © 2020-2026 Eduardo Bart ([LICENSE.txt](../editor/3rd/minilua/LICENSE.txt)) | keep the notice |
| SDL 3 (Sam Lantinga and contributors) | `SDL3/`, `SDL3.dll` | zlib ([LICENSE.txt](../editor/3rd/SDL3/LICENSE.txt)) | don't misrepresent the origin; mark altered sources |
| Hurdy's compiler (apicici) | `runtime/hurdyl/` | MIT, © 2024 apicici ([LICENSE](../runtime/hurdyl/LICENSE)) | keep the notice |
| lua-MessagePack (François Perrad) | `runtime/msgpack/` | MIT/X11, © 2012-2023 François Perrad ([COPYRIGHT](../runtime/msgpack/COPYRIGHT)) | keep the notice |
| TweetNaCl's Ed25519 (Bernstein, van Gastel, Janssen, Lange, Schwabe, Smetsers), ported to Lua | `runtime/ed25519.lua` (with SHA-512, written for Replay) | public domain | nothing |
| sfxr (Tomas Pettersson, "DrPetter"), ported to Lua | `runtime/sfxr.lua` (and `plugins/sfxr/`, which uses it) | MIT, © 2007 Tomas Pettersson ("anything goes", with the MIT licence attached: [sfxr's LICENSE.txt](https://github.com/grimfang4/sfxr/blob/master/sfxr/LICENSE.txt); a copy is in `runtime/sfxr.lua`) | keep the notice |

## What a build ships

A game exported, or the editor shipped, carries Replay's code (no conditions),
Lite (MIT), its themes, plugins and fonts (MIT, Apache 2.0), minilua (MIT;
LuaJIT, MIT too, if you ship that instead), SDL 3 (zlib), stb (public domain) and, when a game uses them, Hurdy,
MessagePack and sfxr (MIT). The MIT and Apache notices go with it: a
`LICENSES` folder next to the exe with the files above is enough.

<h1 align="center"><a href="#">&lt;replay&gt; 🎮</a></h1>
<p align="center">
<img src="gallery/1.png" width="150px"/>
<img src="gallery/2.png" width="150px"/>
<img src="gallery/3.png" width="150px"/>
<br/>
<img src="gallery/4.png" width="150px"/>
<img src="gallery/5.png" width="150px"/>
<img src="gallery/6.png" width="150px"/>
<br/>
<img src="gallery/7.png" width="150px"/>
<img src="gallery/8.png" width="150px"/>
<img src="gallery/9.png" width="150px"/>
<br/>
<img src="gallery/full.png" width="459px"/>
</p>

## About
- A small editor for smaller games. Made in Lua.
- Game is a tree of nodes. Leaves are data or Lua code; folders are nodes.
- The tree is the save file, the network packet and the undo history: snapshot it, diff it, patch it, zip it.
- Edit it while it runs. Code reloads on the fly; the world never restarts.
- Rewind it. Scrub back, change something, play again.
- The Lua text is the only truth. The node graph is just another view of it.

## Features and roadmap
- [x] Node graph view of any Lua file. Edit either side, both stay in sync.
- [x] World as a tree of nodes, addressed by paths (`/game/players/luigi`) and patterns (`/a/*`, `/**`).
- [x] Save, load, diff and patch any subtree as plain Lua literals.
- [x] Systems as code leaves: they save, diff, rewind and replicate like any other data.
- [x] Hot reload of scripts, systems and folder worlds. Broken code keeps the old version running.
- [x] Timeline: rewind, scrub, slow motion (x0.01..x4), play again from any point.
- [x] Editor: lite embedded (code, tree, properties, log), the game over it at any opacity.
- [x] Graph: values on wires, flow pulse, find references, split pins, autoconversion.
- [x] Graph: floating code, collapse to function, comments, go to definition.
- [x] Breakpoints and stepping, in the code and in the graph. F5, F10, F11.
- [x] Debug draw and overlay (`dd.line`, `dd.text`...), input view, `--prof`.
- [x] Lua 5.4 or LuaJIT. Hurdy scripts too.
- [x] Simulated network: latency, loss, a line per player, for testing.
- [x] Relocatable projects: relative paths, `/` everywhere.
- [x] Editor plugins, each one in its own tab: node graph, hex editor, particles, sfxr, tilemap, atlas packer.
- [ ] Next plugins: graph diffs, animation graphs, mesh viewer, terrain, splines, hitboxes.
- [ ] Graph diffs: the changes of a session, a git history.
- [x] Players: 1..4 in one window, each a peer over the simulated network. The game tags what travels.
- [x] Prediction per node, ownership that changes hands, a network quality button.
- [x] Replication: classic client / server first (the host decides; prediction, reconciliation, interpolation, lag compensation), p2p later. See [NETWORK.md](NETWORK.md).
- [ ] P2P admin nodes: players who review other games' patches. Never their own.
- [x] Sockets: play online, `play games/pong --host` / `play games/pong --join 1.2.3.4`.

## Build

```
make.bat                    (Windows, from a Visual Studio prompt)
make                        (Linux, macOS; Windows with MinGW / MSYS2 / Cygwin)
play [games/pong.lua]
```

`make release` for an optimized build, `make tidy` cleans up. The Makefile needs SDL3 3.2 or newer: Linux, your distro's `libsdl3-dev` (or `make SDL_DIR=/path/to/sdl3`); macOS, `brew install sdl3`; Windows, the `SDL3.dll` in `3rd/SDL3/x64` (linked directly, copied beside `play.exe`). `play --stopped` starts on the authored world, `play --prof` puts the frame timings in the title.

## FAQ

**Replay, what is it?**

A small editor for smaller games. Made in Lua.

**Why Lua?**

Lua is everywhere. It can be interpreted or JIT'ed, can be patched, and reloaded on the fly. As a sidenote, you can also write code in different languages that compile to Lua: Hurdy is already built in, and others (Teal, Fennel, Erde, TypeScript, YueScript, Moonscript, CSharp.lua, etc.) could be added soon.

**How is Replay organized behind the curtains?**

We use the Lite text editor for the UI, tabs and dockspace. Tabs are now kind of a blank canvas where Lua plugins can draw. You can create entities, components and systems in your game, and the engine moves them and stores game states in memory or disk every few ticks. Then you can rewind the game state, patch it, diff it, send it over network, etc. The runtime supports multiplayers too, and we use SDL3 for the backend.

**Are you using AI?**

Yes, my friend Claude is doing all the heavy lifting. I am both a technical director and designer this time.

**Why AI?**

The project exists because I once had a vision but never started the project. The project may look simple but there are tons of tech behind, trust me. It would take me a decade to reach something nearly this level. For example, developing a polished nodegraph editor would take any human a couple of years easily. AI coded that, plus the editor, in a few hours of computing time. I simply cannot code that fast. AI made this project a reality, rather than a proof-of-concept.

**Do you trust what Claude is doing?**

Absolutely. He is a very capable 100x programmer. And there are about 1,500 automated checks at the time of writing this.

**Can I submit PRs to this repository?**

Not at the moment. While I appreciate the good intentions it is better for everybody to file [a new GH issue instead](https://github.com/r-lyeh/replay/issues) and discuss the proposed changes there. Reasoning: You could rename a member or function in your fix and call it a day, but you will likely forget to: rename references in all markdown documents, edit unrelated scripts, run unit-tests, re-generate image thumbnails for the README, or verify that all the included game templates do still work. AIs will be in charge of all that since they are better than us at tracking references everywhere.

**Could the project get broken at some point, if AI is doing all the code changes continously?**

Well, it could. Why not. Sh!t happens all the time. But we could fix it manually in that case.

**Bugs?**

Sure. Replay should be cross-platform and very portable, but has not been tested that much (so far).

Made for you and me after all. Also for small engine enthusiasts. No big deal and no big expectations.

**Price?**

The engine is $0/free for you to use it as you wish.

$10 has been invested so far while developing this project, though.

## License

This software is multi-licensed into the [μLicense](https://github.com/r-lyeh/uLicense), [Unlicense](https://unlicense.org/), [0-BSD](https://opensource.org/licenses/0BSD) and [MIT (No Attribution)](https://github.com/aws/mit-0) licenses. Choose whichever license you prefer. Any contribution to this repository is implicitly subject to the same licensing conditions aforementioned. Third-party code in `3rd/` keeps its own license (lite, minilua: MIT; SDL3: zlib).

## Links

- [lite](https://github.com/rxi/lite), the editor inside the editor.
- [SDL3](https://github.com/libsdl-org/SDL), windows, input and rendering.
- [Lua](https://www.lua.org/) via [minilua](https://github.com/edubart/minilua), and [LuaJIT](https://luajit.org/).
- [Lua in 100 seconds](https://www.youtube.com/watch?v=jUuqBZwwkQw), a fast intro to Lua.
- [Claude](https://claude.ai), the best programmer under my technical command.
- [USAGE.md](USAGE.md), how to make a game with it: from the big picture to every button.
- [FEATURES.md](FEATURES.md), everything in detail.

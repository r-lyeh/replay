## Replay🎮

Replay is a small editor for smaller games: a place to experiment with ideas, change things live, and see what happens.

Edit your game while it runs. Inspect its world as a tree, text or node graph. Rewind to an earlier moment, change something, and resume playing.

[![Watch the video](https://github.com/user-attachments/assets/7f6bf6dc-e8c4-4b58-8a79-a8894e3e172d)](https://i.imgur.com/ESnxU0L.mp4)

## Why Replay?

Most game-development workflows separate the game, the editor, the debugger, and the history of what happened.

Replay tries a different approach: bring them together in one live, editable world described as a tree.

- **Game as a tree.** Every world is made of nodes. Find things by paths or patterns, inspect their values, and navigate relationships directly.
- **Code as data.** Nodes hold data or Lua code. The tree can be serialized, snapshotted, diffed, and patched, providing a common model for undo and replication.
- **Code as graphs.** Source files are the ground truth; node-graphs are another way to visualize and edit changes.
- **Edit live.** Edit code, systems, and world data without restarting the game; even if a script fails to compile.
- **Rewind and experiment.** Scrub through the timeline, inspect previous states, slow things down, and resume from an earlier moment.
- **Multiplayer locally.** Simulate network latency and packet loss to investigate how games behave under imperfect conditions.

The idea is simple: spend less time restarting and guessing, and more time experimenting.

## Why Lua?

Replay supports LuaJIT and Lua 5.4. Lua is compact, embeddable, and easy to reload, making it a good fit for a tool built around short feedback loops and live experimentation.

If you prefer languages with braces, [Hurdy](https://hurdy.apicici.com) is also supported. And other [languages that compile to Lua](https://github.com/hengestone/lua-languages) could be supported in the future as well.

The goal isn't to build the fastest or biggest engine. It's to make a compact environment where ideas are fun and quick to implement.

## What's inside?

- [x] **Live game editor**. Edit Lua code and game data while the world keeps running. Explore the node tree, inspect properties, and watch the log as changes take effect. Rewind the timeline, scrub through past states, or slow things down to see what happened.
- [x] **Text and node-graph views**. Work with code as text or as a node graph. Navigate between definitions and references, inspect values, and debug with breakpoints and stepping. Replay supports Lua 5.4, LuaJIT, and Hurdy.
- [x] **Inspectable, editable worlds**. The node tree is more than an editor view: it's the structure of the game itself. Find nodes by path or pattern, save and load subtrees as Lua literals, and use diffs and patches to inspect or modify state.
- [x] **Extensible workflow**. Extend the editor with plugins for additional workflows, including graphs, tilemaps, particles, audio, and assets. See [PLUGINS.md](PLUGINS.md) when creating new plugins.
- [x] **Multiplayer and networking**. Explore per-player state, replication, and multiplayer behavior in a controlled environment. Simulate latency and packet loss to see how your game responds when the network isn't perfect. See [NETWORK.md](NETWORK.md) for details.

Some capabilities are still evolving. See the [FEATURES.md](FEATURES.md) and [ROADMAP.md](ROADMAP.md) documents for extra details.

## Get started

### Requirements

Replay uses SDL3 3.2 or newer.

- **macOS**: install SDL3 with Homebrew: `brew install sdl3`.
- **Windows**: install either Visual Studio for game development, or a MinGW/MSYS2/Cygwin environment.
- **Linux**: install your distribution's SDL3 development package, such as `libsdl3-dev`, or point the build to your SDL3 installation (`make SDL_DIR=/path/to/sdl3`).

### Build

On Linux and macOS, Windows with MinGW/MSYS2/Cygwin, or from a Visual Studio console prompt:

```sh
make
```

For an optimized build:

```sh
make release
```

To remove generated artifacts:

```sh
make tidy
```

### Run a game

Run the project launcher:

```sh
replay
```

Or a specific game from the repository root:

```sh
replay games/pong.lua
```

To start with the authored world stopped:

```sh
replay --stopped games/pong.lua
```

To show frame timings in the window title:

```sh
replay --prof games/pong.lua
```

Check [CMDLINE.md](CMDLINE.md) for a detailed view of available options.

## How to make a game

The best way to understand Replay is to open one of the included games and start changing it.

1. Launch Replay and open an example from `games/`.
2. Explore its world tree.
3. Find a system or value that affects the game.
4. Change it while the game is running.
5. Rewind, compare states, and experiment.

Start with [HELP.md](HELP.md) for the walkthrough, then consult [FEATURES.md](FEATURES.md) for a deeper reference.

## Status

Replay is an experimental project for small-game development and engine enthusiasts. No big promises. Just a different way to make games, and a tool to keep exploring.

Replay's workflow is still evolving, and some features or platforms may need more testing. Start with the included examples, consult the documentation, and report reproducible problems or suggestions through [GitHub issues](https://github.com/r-lyeh/replay/issues).

## License

Replay is available under four licensing options: μLicense, Unlicense, 0-BSD, and MIT No Attribution. Choose whichever you prefer. Third-party dependencies retain their [respective licenses](LICENSES.md).

## Links

- [Lua in 100 seconds](https://www.youtube.com/watch?v=jUuqBZwwkQw), a fast intro to [Lua](https://www.lua.org/). See also: [Hurdy](https://hurdy.apicici.com "a Lua flavor with braces"), [LuaJIT](https://luajit.org/ "fastest Lua implementation around"), [Lite](https://github.com/rxi/lite "the editor inside the Editor") and [SDL3](https://github.com/libsdl-org/SDL "windows, input and rendering backends").
- [HELP.md](HELP.md), how to make a game with Replay.
- [FEATURES.md](FEATURES.md), everything in detail.
- [ISSUES.md](ISSUES.md), let's discuss.
- [PLUGINS.md](PLUGINS.md), writing editor plugins.
- [NETWORK.md](NETWORK.md), playing together.
- [ROADMAP.md](ROADMAP.md), what's planned.
- [CHANGELOG.md](CHANGELOG.md), what's new.


# Command line

`replay --help`

`replay [FLAGS] [FILE]`

`replay [FLAGS] [FOLDER]`

FILE is a game: a `.lua` or `.hurdy` script (`games/pong.lua`), a world folder
(`games/pong/`), a snapshot (a `save()` blob), or any other file: an asset, opened in the
plugin whose `files.lua` lists its extension (the game it belongs to loads, stopped). No file:
the project launcher. A renamed copy of the exe (`pong.exe`) opens `pong/`, `pong.lua` or
`pong.hurdy` beside it or in `games/`; a shipped package (no `.c` files beside the exe) runs
`--standalone` unless `--editor` is given.

## Running

| Flag | Argument | What it does |
|---|---|---|
| (no file) |  | the project launcher: the games in games/ (arrows / enter, a gamepad, a click) |
| FILE |  | a game: a .lua / .hurdy script, a world folder or a snapshot; any other file: an asset, opened in its plugin |
| `--stopped` |  | start stopped, on the authored world (in the editor) |
| `--standalone` |  | just the game: no editor, no tree |
| `--editor` |  | the editor even in a shipped package (no .c files beside the exe) |
| `--no-editor` |  | the viewer without Lite (the tree and the game only) |
| `--game` | `WxH` | the game area's size when the window opens (else the game's config/window.lua) |
| `--tab` | `PX` | the left tab's width |
| `--fps` | `N` | the frame limit while focused (0: none); also --fps-target |
| `--prof` |  | where each frame's time goes, in the window title (and on stderr) |
| `--log` |  | write .log.txt beside the game (the default: the setting) |
| `--no-log` |  | don't write .log.txt |
| `-h`, `--help`, `-?` |  | this list |

## Online

| Flag | Argument | What it does |
|---|---|---|
| `--host` | `[PORT]` | host the game online (UDP; no port: the game's own, from its name) |
| `--join` | `ADDR[:PORT]` | join the game that computer hosts (no port: the game's own) |
| `--join` | `ROOM@INTRO[:PORT]` | join through routers: the room that introducer knows |
| `--via` | `ROOM@INTRO[:PORT]` | host through routers: known to that introducer as ROOM (implies `--host`) |
| `--introducer` | `[PORT]` | introduce players behind routers (UDP; no port: its own, from its name; the next two ports too; playing or not) |

Hosting asks the router to open the port (PCP, NAT-PMP, UPnP); the
environment variable `REPLAY_PORTMAP=0` stops that (the test runner sets it).

## Headless and tests

| Flag | Argument | What it does |
|---|---|---|
| `--headless` |  | no window: the world played, a summary printed, exit code 0 / 1 (for CI) |
| `--ticks` | `N` | with --headless: play N ticks (600 by default: 10 s) |
| `--key` | `"KEY@F[-G]"` | hold KEY from frame / tick F (to G); up to 16. In the editor: pressed and released at frame F; `ctrl+` / `shift+` before it press those too (`"ctrl+shift+left@30"`) |
| `--type` | `"LUA@F"` | run a console line (the live world: w) at frame / tick F; up to 16 |
| `--lite` | `"LUA@F"` | run Lua inside Lite at frame F; up to 16 |
| `--events` | `"l X,Y@F ..."` | scripted mouse: l / r / m clicks, x / X press / release, m moves, w / W wheel |
| `--frames` | `N` | quit after N frames (with `--shot`: the screenshot first) |
| `--shot` | `FILE.bmp` | save a screenshot when quitting (60 frames when --frames isn't given) |
| `--pick` | `"EVENTS"` | scripted clicks in the project launcher |
| `--pick-shot` | `FILE.bmp` | a screenshot of the project launcher |
| `--export-dir` | `DIR` | Export writes there without asking |

### All the tests at once

`lua runtime/tests/run.lua` (from the project's folder, after a build; or
`make test`) copies the project to a temporary folder and runs every suite
there: the Lua ones, and the editor's (Replay run on the demos, scripted).
It prints `== name: result` per suite and a summary, and exits 1 if any
failed. `--exe PATH` the Replay to test, `--lua luajit,lua5.4` the
interpreters for the Lua suites, `--only break,dialog` some of them, `--list`
their names, `--keep` keeps the copy.

## Environment (tests)

| Variable | What it does |
|---|---|
| `NG_EXIT=1` | the editor's test scripts exit when done (run.lua sets it) |
| `SDL_VIDEODRIVER=offscreen` | no window (run.lua sets it) |
| `REPLAY_SCALE=2` | a window of 2x the pixels, drawn as `retina` draws on a Retina display (to try it without one) |

## Examples

```
replay                                   the project launcher
replay games/pong.lua                    a script game (games/pong/: the folder one)
replay games/pong --stopped              start stopped, in the editor
replay games/pong --host                 host it online; elsewhere: replay games/pong --join 1.2.3.4
replay games/pong --introducer           introduce players behind routers (this computer: reachable)
replay games/pong --via den@1.2.3.4      host through routers; elsewhere: replay games/pong --join den@1.2.3.4
replay games/pong --headless --ticks 600 --key "space@30-90" --type "assert(w:node('/objects/ball'))@600"
                                         no window: 10 s played, keys held, a check; exit code 0 / 1
```

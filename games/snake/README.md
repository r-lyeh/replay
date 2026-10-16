# snake

Snake as a world folder, with its systems written in **Hurdy**
(https://codeberg.org/apicici/hurdy, bundled in `runtime/hurdyl`):
`play.exe games\snake\`

The same game in one file, all of it hurdy: `games\snake.hurdy`.

Press play: arrows / WASD turn (a gamepad: dpad or left stick; A or START
skips the countdown). After a game over a new one starts in
`data/rules/restart_after` seconds; space (or enter) skips the countdown.

- `systems/*/system.hurdy`  the code: input, step, draw, hud
- `systems/order.lua`       their run order
- `data/rules/*.lua`        tuning: grid size, cell size, step time, speedup, start length, restart_after
- `data/state/*.lua`        the game as data: body cells, direction, food, score, timeout, rng seed
- `objects/*`               what you see: board, food, hud
- `/entities/snake/1..N`    the body, spawned by `systems/draw` while playing: never saved, so no folder

## Code leaves in another language

A file `name.hurdy` is a code leaf just like `name.lua`. It is compiled to
Lua when it loads (and every time you save it) and runs in the same sandbox.
Errors point at the Hurdy line. In a script world (like `games\snake.hurdy`),
write a system as `var step = ecs.system(function() { ... })`.

Hurdy in one breath: braces instead of `then/do/end`, `var` for locals,
`!` / `!=` for `not` / `~=`, `+= -= *= /= ..=`, `**` for power, default
arguments `function f(a, b = 2)`, and table comprehensions
`{ x * x for x in ipairs(t) }`.

Things to try while it runs:
- change `data/rules/step` (seconds per move) or `cols` / `rows`
- edit `systems/draw/system.hurdy`: give the head another colour, save
- break something in a `.hurdy` file and save: the error names the line

# pong

A small game as a world folder: `play.exe games\pong\`  (or add `--standalone`)

The same game also comes as one file, `games\pong.lua`: the very same world,
built by a script. Open both and compare: here every node is a folder and every
component a tiny `.lua` file; there it is all `w:spawn(...)` calls and
`ecs.system(function() ... end)` systems.

Press play, then ESC to give the keyboard to the game:
W / S move the left paddle; the right one is played by the computer,
until player 2 joins (the editor's Players button: 2), then W / S in its view.

Two players over a network (the Players button: simulated; or online), and
the game doesn't know: for it, both are local. The host (player 1) decides
everything; what travels is tagged (`replicate.lua`): player 2's keys,
`data/input/p2` (`{ by = 2, cmd = true }`), go to the host as numbered
commands; the paddles are the host's, each driven by its player's keys
(`{ by = 1, input = 2 }`): player 2 moves its paddle at once and replays
its keys on each of the host's states; the other paddle is shown a little
late and smoothly (`interp = true`). The ball is predicted (`predict =
true`): every player simulates it, and the host's state corrects the guess
(`snap`: a serve or a bounce at once). The host decides the ball's hits on
player 2's paddle the way player 2 saw them (lag compensation, in
`systems/ball`): what you hit on your screen is a hit. More:
[docs/NETWORK.md](../../docs/NETWORK.md).
A gamepad (pad N: player N) moves its paddle with the dpad or the left
stick. First to `data/rules/win` points wins; space, enter, escape (or A /
START) plays again
(or wait `data/rules/restart_after` seconds).

- `systems/*/system.lua`   the systems: input, paddles, ball, score, banner, debug draw
- `systems/order.lua`      their run order
- `classes/paddle/*.lua`   a paddle's members, one file each: its type and
                           value (what spawning one fills in), its range or
                           options. Select /classes/paddle in the tree to
                           edit them (`+ member` adds one)
- `data/rules/*.lua`       tuning: speeds, arena size, points to win...
- `data/score`, `data/input`  the game's state: the score, each player's keys
- `objects/*`              the objects you see: paddles, ball, field, HUD

Things to try while it runs:
- Players: 2, and play the right paddle in player 2's view
- change `data/rules` speeds, or the ball's `circle.r`
- edit `systems/ball/system.lua` and save: it swaps in live

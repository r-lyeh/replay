# asteroids

Two ships against rocks that never stop coming: `play.exe games\asteroids\`
(or add `--standalone`). Whoever lives longest wins the round, and the
longest life so far is the record, shown top-centre under the round's time
(kept between runs: `saves/record.sav`, the tree's `/saves`).

Press play, then ESC to give the keyboard to the game:
A / D turn, W thrusts, SPACE fires (arrows and S / down work too). A
gamepad: dpad or left stick to turn and thrust (or RT), A / X fire.
Player 2 is the computer (a coop AI: it shoots the rocks too) until a second
player joins (the editor's Players button: 2), then the same keys in its view.
Shots don't hurt ships; a rock does. A ship blinks while it's safe, at the
start of a round. When both are gone: space, enter or escape (or wait
`data/rules/restart_after` seconds) plays again.

The pictures are files in `assets/` (`ship.png`, `flame.png`, `rocks/*.png`,
`shot.png`, `spark.png`, `space.png`): the tree shows them under /assets,
click one to open it in the texture viewer. A node draws one with its
`image` component: `{ "/assets/ship.png", w = 36, h = 36, color = {...} }`
(color tints it: the ships are the same picture, tinted). Change a file on
disk and the game shows the new one.

Multiplayer: what travels is tagged (`replicate.lua`). The host (player 1)
owns the round: `/objects/game` (the director), `/data/state`, the rocks and
the sparks and the shots (predicted: everyone simulates them, the host's
state corrects them), and the ships too: a player's keys reach the host as
numbered commands (`data/input/p2`: `{ by = 2, cmd = true }`), the host flies
its ship by them (`{ by = 1, input = 2 }`), decides its shots, its hits and
its death (`w:owns(node)` in the systems). The player flies its own ship at
once and replays its keys on each state from the host (reconciliation);
the others see it a little late and smoothly (`interp = true`). Shots are
the host's, but your SPACE shows one at once (a stand-in, replaced by the
host's). Sparks are an event (`w:event("boom", ...)`, systems/sparks): each
player makes the same burst. Layers (`data/layers`): sparks and shots over
the ships, the HUD on top. Turn the Network button down and watch.

- `systems/*/system.lua`  input, ships (with the AI), rocks, shots, sparks,
                          director (the round: new rocks, who won, the record),
                          hud, debug
- `data/lib/space/module.lua`  what the systems share (`require "space"`):
                          wrap, delta, angle, rand
- `data/rules/*.lua`      tuning: the arena, the ships, shots, rocks
- `data/state`            the round: time, rocks to come, who won, the record
- `objects/ship1, ship2`  the ships (`ship.lua`: its player and start)
- `objects/hud`           the time, the record, each player's time, the banner
- `image.lua`, `order.lua`  the starfield behind everything; what's drawn first
- `config/window.lua`     the window's size (the arena's) and title (`/config`)

Things to try while it runs:
- Players: 2, and fly the orange ship in player 2's view
- `data/rules/rocks.lua`: `every`, `ramp`, `max` (a harder game)
- repaint `assets/ship.png` and save it

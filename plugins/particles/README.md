# particles

A particle effect editor: `.pfx` files. The effect plays in the middle, its
settings are sliders on the right, the effects it comes with on the left.

- `sim.lua`: an effect's settings and the simulation (no Lite in it: a game
  can run it the same way)
- `editor.lua`: the tab (runs in Lite)
- `files.lua`: the extensions it opens (`pfx`)
- `config.lua`: `background` (dark, light, checker), `speed` (the preview's)
- `templates/effect.pfx`: what `New effect` in the tree's `/assets` makes
- `samples/*.pfx`: fire, smoke, sparks, explosion, fountain, rain, snow, magic

The settings: rate and burst (a cycle's), max alive, the cycle (0: forever)
and loop; the emitter's shape (a point, a circle, a box); life (min, max);
angle and spread, speed (min, max), gravity, drag, spin; size (start, end)
and its variety; colour (start, end, with alpha); blend (alpha, add) and
squares or discs.

In a tab: LMB drags the emitter (to see a trail), MMB pans, CTRL+wheel
zooms, double-click fits. SPACE pauses, CTRL+Z / CTRL+Y undo and redo,
CTRL+S saves. Double-click a slider: its default; SHIFT drags finely.
The preview can't blend additively: "add" effects show a little brighter
instead. Not yet: playing them in a game (the simulation is ready for it).

# terrain

A terrain generator: `.terrain` files, the settings of a piece of land, and
the tile map they make, a `.tmap` that the tilemap editor opens. The second
plugin that feeds another (`plugins/chain`), with the dungeon generator; both
use the same tab (`plugins/genview`).

- `gen.lua`: the generator (no Lite in it: a game could make land too)
- `editor.lua`: the tab (runs in Lite)
- `files.lua`: the extensions it opens (`terrain`)
- `templates/terrain.terrain`: a new one (the main menu's Plugins > Terrain generator)
- `samples/islands.terrain`: islands, 96 x 64

## Using it

- **Right**: the shape (a seed: the same seed makes the same land; New
  seed; its size in cells; Scale: how wide its hills and seas; Detail: how
  rugged; Island: water all round), the heights (below Water: sea; then
  Beach: sand; above Hills: stone; above Snow: snow), and life (Dry land:
  dirt and cacti instead of grass; Trees: bushes; Flowers: flowers and tall
  grass; Shores: the water's edges drawn as auto-tiles).
- **Middle**: the land, made again at every change.
- **Left**: how much is land and water, and the map: CTRL+S saves the
  settings **and** writes the map; *Open the map* opens it in the tilemap
  editor, which offers *Regenerate* and *Open source*.

Land is value noise: a lattice of random heights blended smoothly, a few
octaves of it layered (Detail), and a second one for how dry the land is.
The map's layers: `ground`, `decor` (bushes, flowers, cacti, rocks), `top`
(empty, for you). Its tileset is the tilemap plugin's (`plugin:tiles.png`).

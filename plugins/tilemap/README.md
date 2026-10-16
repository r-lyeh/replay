# tilemap

A tilemap editor: `.tmap` maps of 16 x 16 tiles, in layers.

- `map.lua`: the model (cells, layers, paint / rect / fill / resize; no lite
  in it: a game can read a `.tmap` with it)
- `editor.lua`: the tab (runs in lite)
- `tiles.png`: the tileset, 256 x 256, 16 x 16 tiles (62 of them: ground,
  water, lava, wood, bricks, glass, wool, ores, plants, furniture...);
  `tiles.lua`: their names. Ours, drawn by code (`tools/make_tiles.py`), CC0:
  `LICENSE-tiles.txt`
- `files.lua`: the extensions it opens (`tmap`); `config.lua`: `grid`, the
  size of a new map (`w`, `h`)
- `templates/map.tmap` (the tree's *New tmap*), `samples/island.tmap`

In a tab: the tools, the layers and the tileset on the left (click a tile, or
drag over several: a stamp); the map in the middle; its size and the cell
under the mouse on the right.

| Mouse / key | |
|---|---|
| LMB | the tool: **Paint** (the stamp), **Rect** (drag: the stamp over it), **Fill** (the cells like it, touching), **Erase** |
| RMB | erases (CTRL+RMB: the menu) |
| ALT+LMB | picks the tile under it |
| MMB drag, LMB off the map | pans; CTRL+wheel zooms; double-click off the map fits |
| B R F E | the tools; 1..9 the layer |
| CTRL+Z / CTRL+Y, CTRL+S | undo / redo, save |

The layers above the one being edited show faded. A map's `tileset` can be a
picture beside it (`tileset = "my_tiles.png"`, `tile = 16`); the default,
`"plugin:tiles.png"`, is this folder's.

A `.tmap` is Lua data: `tileset`, `tile`, `w`, `h`, and `layers`, each with a
`name`, `visible` and `rows`: a string per row, two hex digits a cell (the
tile's index in the tileset, 16 a row), `..` for none.

## In a game

A node with a `tilemap` component draws a map (from its top left):

    -- objects/level/ground/tilemap.lua
    return { "/assets/level1.tmap", layer = "ground" }   -- (a layer's name or number; none: all)

The tileset is looked up beside the `.tmap` (copy `tiles.png` into the
game's `assets/`). The map reloads when its file changes. A game reads the
cells with `w:asset("level1.tmap")`: games/hop does (solid ground, lava,
gems).

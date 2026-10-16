# tilemap

A tilemap editor: `.tmap` maps of 16 x 16 tiles, in layers.

- `map.lua`: the model (cells, layers, paint / rect / fill / resize; no Lite
  in it: a game can read a `.tmap` with it)
- `editor.lua`: the tab (runs in Lite)
- `tiles.png`: the tileset, 256 x 256, 16 x 16 tiles (250 of them: ground,
  water, lava, wood, bricks, glass, wool, ores, plants, furniture..., and four
  kinds of auto-tiles); `tiles.lua`: their names and the auto-tile kinds. Ours, drawn by code (`tools/make_tiles.py`), CC0:
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

**Auto-tiles**: from tile 64 the tileset has four kinds of 47 tiles ("blob"
sets): water with shores (64..), stone walls with edges (111..), lava with a
crust (158..), grass with ragged edges (205..). A cell's mask sums its
neighbours of the same kind (N 1, NE 2, E 4, SE 8, S 16, SW 32, W 64, NW
128; a corner only when both its sides count; off the map counts as the
same), and the tile is first + the mask's place among the 47 that can be
(`M.BLOB`): inner corners too. Paint with any of a kind and every
cell about the edit picks the one that fits (`map.lua` `M.autotile`);
*Auto-tiles* on the right turns it off (paint exactly what you picked),
*Auto-tile this layer* redoes a layer. The terrain generator's shores and
the dungeon generator's stone walls are made the same way.

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

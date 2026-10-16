# dungeon

A dungeon generator: `.dungeon` files, the settings of a dungeon, and the
tile map they make, a `.tmap` that the tilemap editor opens. The first
plugin that feeds another (`plugins/chain`: see docs/PLUGINS.md).

- `gen.lua`: the generator (no Lite in it: a game could make dungeons too)
- `editor.lua`: the tab (runs in Lite; `plugins/genview`, shared with plugins/terrain)
- `files.lua`: the extensions it opens (`dungeon`)
- `templates/dungeon.dungeon`: a new one (the main menu's Plugins > Dungeon generator)
- `samples/crypt.dungeon`: a crypt, 64 x 40

## Using it

- **Right**: the layout (a seed: the same seed makes the same dungeon; New
  seed; its size in cells; how many rooms, their smallest and largest sides;
  loops: extra corridors, 0 makes a tree) and its look (the theme: stone,
  cave, crypt, wood; torches on the walls, crates and barrels in the rooms,
  doors where corridors enter rooms; Wall edges: the stone theme's walls as
  auto-tiles, outlined where they meet the floor); the map it writes and its tileset.
- **Middle**: the dungeon, made again at every change.
- **Left**: what it made, and the map: CTRL+S saves the settings **and**
  writes the map (`<its name>.tmap` beside it, or the name given);
  *Open the map* opens it in the tilemap editor.
- The map remembers where it came from (`made_by`): the tilemap editor
  shows *Made by* with **Regenerate** (from the settings as saved: hand
  edits to the map go) and **Open source** (back here). Edit the map by hand
  and it stays yours until it's made again: a chain can be cut at any link.
- CTRL+Z / CTRL+Y undo and redo, MMB pans, CTRL+wheel zooms, double-click fits.

The map's layers: `ground` (floors, corridors, walls), `decor` (torches,
crates, barrels, doors), `top` (empty, for you). Its tileset is the tilemap
plugin's (`plugin:tiles.png`); a game needs the picture in its assets (or set
a tileset beside the map).

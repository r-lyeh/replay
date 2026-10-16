# Atlas packer

A plugin of Replay's editor (`plugins/atlaspacker`): many small images packed into
one sheet (a texture atlas). One texture instead of many: fewer state
changes, one file to load.

An atlas is two files, side by side:

- `<name>.atlas.lua`: what it packs (`sources`, `exclude`), its settings,
  and, written by CTRL+S, where each image went (`frames`). Plain data: the
  game reads it.
- `<name>.atlas.png`: the sheet (never packed itself: no `*.atlas.png` is).

The plugin's files:

- `files.lua`: it opens `.atlas.lua` files
- `config.lua`: defaults (padding, power-of-two sides, the most size, rotate)
- `templates/atlas.atlas.lua`: what `New atlas` in the tree's `/assets` makes
- `editor.lua`: the packer and its tab (runs in Lite, on the canvas)

## Using it

1. In the tree, right-click a folder of `/assets` (one with your images):
   **New atlas**, give it a name (`ships`). `ships.atlas.lua` opens in its
   tab: the images next to it (`*.png`) already packed.
2. The tab:
   - **Toolbar**: `+ Add...` (an image, a folder or a name with `*`, typed
     with suggestions; or drop files from your file manager on the tab),
     `Remove` (the selected image), `Save` (lit when the sheet on disk isn't
     this one), and on the right `Fit`, `100%`, `Text`.
   - **Sprites** (left): each source and its images, with a thumbnail and
     size; hover a row for its `x` (out) button, the left-out ones (last)
     get a `+` (back in). Click one to select it; double-click: zoom to it.
   - **The sheet** (middle): as it will be written. Hover an image for its
     name, size and place; click to select it; drag to pan; the wheel zooms;
     double-click fits.
   - **Settings** (right): padding, max size, power of two, rotate; the
     output (sheet, size, how full, frames, saved or not); the selected one.
   Every change goes into the `.atlas.lua`'s text (unsaved, like typing:
   undo it there) and packs again at once; changed images on disk too.
3. **CTRL+S** writes `ships.atlas.png` and the frames into `ships.atlas.lua`.
4. The tab's icon (left of its name), or `Text`, flips it to that text and
   back. Right-click the tab: open the text (or the atlas) beside it.

## The file

```lua
return {
  sources = { "*.png", "rocks" },          -- files, folders, names with * (next to it)
  exclude = { "space.png" },               -- (left out: the ones you removed)
  padding = 2, max_size = 2048, power_of_two = true, rotate = true,
  image = "/assets/ships.atlas.png", w = 256, h = 128,
  frames = {
    { path = "/assets/rocks/big.png", x = 0, y = 0, w = 96, h = 96, deg = 0 },
    { path = "/assets/ship.png", x = 98, y = 0, w = 64, h = 64, deg = 90 },
  },
}
```

`w`, `h`: the image's own size. `deg = 90`: kept turned a quarter clockwise
in the sheet (it takes `h` x `w` there).

## Cut from one picture

An atlas can also be the named parts of one picture you drew (no
packing): `cut = "lcd_on.png"` in its text, or right-click > *Cut from a
picture instead...*. Its tab then shows that picture and its frames:

- **Find segments**: every patch of the picture that shows (touching
  pixels, transparent around them) becomes a frame, `seg1`, `seg2`...
  (the ones already there are kept).
- **Drag** on the picture to mark a part yourself; it asks its name.
- **Double-click** a frame (on the picture or in the list) to rename it;
  **Delete** removes the selected one; **Ctrl+S** saves the text.

```lua
return {
  cut = "lcd_on.png",
  image = "/assets/lcd_on.png", w = 480, h = 320,
  frames = {
    { name = "man1", x = 96, y = 222, w = 49, h = 58 },
  },
}
```

In the game, `at = "sheet"` draws a frame where it is in the picture (the
picture centred on the node): put every segment's node at the same place
and each one lights up where it belongs. `games/lcd/` (Parcels) is made
this way.

## In the game

The `image` component draws a frame of an atlas:

```lua
image = { "/assets/ships.atlas.lua", frame = "ship" }   -- or "rocks/big", or "/assets/ship.png"
```

`frame`: a frame's name (a cut atlas's), its path, or its path's end
without the extension. Turned frames
are drawn upright. (`image = { "/assets/ships.atlas.png", src = { x, y, w, h } }`
draws any part of a picture.)

Packing: MaxRects (best short side fit), the biggest images first, turned
when that fits better (`rotate`); with `power_of_two` the sheet's sides are
powers of two, else it's cut to what's used.

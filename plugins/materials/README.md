# materials

A material editor: `.mat` files open as node graphs. The example of a plugin
built on the canvas (`editor/3rd/lite/data/plugins/canvas`, docs/PLUGINS.md):
`editor.lua` lists the kinds of node and their typed pins, reads and writes
the file, and draws a swatch / a value inside some nodes. The canvas does the
rest: drawing, camera, selecting, moving, wiring, the menu.

- `files.lua`: the extensions it opens (`mat`)
- `templates/material.mat`: what `+ material` in the tree's `/assets` makes
- `sample.mat`: a material to try (`sample.png` is its texture)

In a tab: LMB selects and drags, drag from a pin to a pin of the same type
to wire them (from a wired input: pick its wire up), RMB: add a node (type to
find it), duplicate, delete. DELETE, CTRL+D, CTRL+S. The wheel scrolls,
CTRL+wheel zooms, double-click on nothing fits.

Not yet: editing the values inside nodes (a colour picker, a slider), a
preview.

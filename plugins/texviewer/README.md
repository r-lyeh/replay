# texviewer

A texture viewer: PNG, JPG, BMP, TGA and GIF (its first frame) open in a Lite
tab instead of the text editor. A pure Lua plugin, the first of the project's
own (`plugins/`).

- `files.lua`: which extensions open here (the file registry)
- `templates/texture.png`: what `+ texture` in the tree's `/assets` makes (64 x 64, clear)
- `config.lua`: its settings (`checker`: the squares, % of the monitor's height;
  `thumbnails = "image"`: its files as pictures in the tree's `/assets`)
- `editor.lua`: the viewer itself (runs in Lite)

In the tree it's `/plugins/texviewer`: its `files` and `config` are
components you edit in the properties panel and Save (back to these files).

In a tab: the wheel zooms (around the mouse), dragging pans, double-click
toggles fit / 100%, right-click opens its menu (type to filter it). The
file is read again when it changes on disk. Saving `editor.lua` reloads the
plugin (or: the `reload` link in the tree, its menu's "Plugin: texviewer > Reload").

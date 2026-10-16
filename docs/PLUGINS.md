# Project plugins

The editor's own plugins live in `plugins/`, next to `games/`. Each folder
there is one plugin, written in plain Lua: no C compiler needed. The first
one is `plugins/texviewer` (a texture viewer).

## A plugin's folder

```
plugins/<name>/
  editor.lua     its code: runs in lite (the editor), at start
  files.lua      (optional) data: the file extensions it opens
  config.lua     (optional) data: its settings
  *.lua          more data leaves, if it wants them
  README.md      anything else is left alone
```

At start the editor scans `plugins/` and:

- loads every folder's `editor.lua` into lite
  (`3rd/lite/data/plugins/projectplugins.lua`);
- mounts every folder in the tree as `/plugins/<name>`. Its data leaves (a
  `.lua` file that is plain data, like `config.lua`) are that node's
  components: edit them in the properties panel, then Save writes them back
  to their files. A file is rewritten only when its value changed (a
  rewritten file loses its comments). Undo reads the folder again. Code leaves
  (`editor.lua`) stay on disk. `/plugins` is never saved with a game, sent
  over the network, nor kept by the timeline.

Clicking `/plugins/<name>` in the tree opens its `.lua` files in the editor.

Thumbnails: `config.lua`'s `thumbnails = "image"` shows its files in the
tree's `/assets` as pictures (a matrix of cells under their folder; the
size: the main menu's Thumbnails slider). `false` or missing: a row
each. Only `"image"` (the file is a picture the editor can decode) for now;
later kinds could be animated (`"frames"`) or carry an overlay button
(play / pause for a sound).

## editor.lua

It runs once with one argument, `P`:

| | |
|---|---|
| `P.name`, `P.dir` | its name, its folder |
| `P.read(leaf)` | a data leaf of its folder (`"config"` reads `config.lua`) in an empty sandbox; `nil` if missing or not data |
| `P.changed(leaf)` | has that leaf changed on disk since the last `P.read`? (Saved from the tree, or by hand.) Poll it to pick up new settings live |
| `P.open_with(exts, View)` | files with those extensions open in `View` instead of the text editor. Calling it again replaces this plugin's list |
| `P.menu(View, items)` | its right-click menu over `View` (the standard one, below). `items`: a list, or a function that builds it each time it opens |
| `P.source()` | opens its `editor.lua` (and its data leaves) in the editor |
| `P.reload()` | runs `editor.lua` again; its open tabs come back with the new code (`View(old:get_state())`). If the new code fails, the old one stays. `P.reloadable = false` (set in `editor.lua`): it can't, a restart does (the node graph) |
| `P.view(View)` | a view of its own that opens no file type (the node graph's): its menu gets the "Plugin: <name>" submenu too (views given to `P.open_with` count already) |
| `P.menu_items` | (optional) a function returning more items for that submenu: its own common commands |
| `P.require(mod)` | one of its folder's modules, `plugins/<name>/<mod>.lua` (no `mod`: its `init.lua`); `require "plugins.<name>.<mod>"` finds it too. A big plugin in several files: `plugins/nodegraph` |

`View` is a lite view (`core.view` extended). It's created as
`View({ filename = absolute path })`. Give it `get_state()` returning a table
with `filename` (and anything else), and the workspace reopens its tabs with
`View(state)`. Define `scroll_to_line()` (it can do nothing): opening a file
asks every tab for it.

## Editing a plugin live

Its code is one click away: in the tree, `/plugins/<name>` has a `source`
link (opens `editor.lua`) and a `reload` link; its own menu can offer them
too (`P.source`, `P.reload`). Saving `editor.lua` (or any of its folder's
`.lua` that isn't data) reloads the plugin: no restart.

A plugin's tab gets the mouse wheel with CTRL as well (elsewhere CTRL+wheel
sizes the code's font).

## Right-click menus: the standard

`3rd/lite/data/plugins/contextmenu.lua`. Every menu has a search line on top:
typing filters it, up / down move, Enter picks (the first match while
searching), Backspace erases, Esc closes.

```lua
local menu = require "plugins.contextmenu"
menu:register(predicate, items [, key])   -- predicate: a View class, or a function
-- items: { text = "Fit", command = "cmd:name" or function() end,
--          info = "dbl-click", checked = true }, menu.DIVIDER, ...
-- or a function returning that list (built when it opens: checked marks up to date)
```

An item can be a submenu: `{ text = "More", sub = items }` (a list or a
function): it opens beside its item. A plugin's view gets one at the bottom of its
menu by itself, "Plugin: <name>": source, reload, settings, files, about,
browse folder (`P.menu_items` adds more): don't add those to your own items.

`key` replaces an earlier registration with the same key (a reloaded plugin
doesn't pile up). The first entry that matches opens, but a class's entry
gives way to one for a subclass of it. From a plugin, `P.menu(View, items)`
does this; a canvas view has one already (its `menu_items()`).

## Tabs that flip

A tab can show its file two ways: lite's text, and your view. The icon left
of the tab's name flips it in place (each side kept for the next flip); the
tab's tooltip and its menu say so. The node graph (Lua) and the markdown
viewer (`.md`) are two such kinds:

```lua
local tabflip = require "plugins.tabflip"
tabflip.register {
  key = "mdviewer",
  text = function(view) return view:is(DocView) and view.doc.filename:match("%.md$") end,
  alt = function(view) return view:is(MdView) end,
  to_alt = function(view) return MdView({ filename = view.doc.filename }) end,   -- (it may keep view.doc: live text)
  to_text = function(view) return DocView(view.doc or core.open_doc(view.filename)) end,
  icon = function(x, y, s, color) ... end,        -- your view's glyph, s px
  tip = "Show as preview", menu = "Toggle preview / text",
  after = function(old, new) end,                 -- (optional: keep the place)
  name = "mdviewer",                              -- (optional) its name in menus (default: key; P.title wins)
  first = true,                                   -- (optional) asked before the others: the atlas's
}                                                 --  .atlas.lua is Lua too, but an atlas
```

`plugins/mdviewer/editor.lua` is the example. Beside: `tabflip.open_beside(node,
view)` puts its other view (else a copy) in the pane beside it (right, or
left for the right one; split off when there's none); `copy_beside`,
`move_beside`, `place_beside(node, any_view)` too. The tab's menu, the
text's and `Ctrl+\` use them (`tabmenu.lua`).

## Drawing on a canvas

`3rd/lite/data/plugins/canvas`: the node graph's look and feel for any
editor (a material editor, an animation graph, an image, a curve), so they
all speak the same visual language. The node graph draws with it too.

```lua
local canvas = require "plugins.canvas"
```

| | |
|---|---|
| `canvas.View` | a lite tab with a camera: pan, zoom, fit, a grid, the RMB menu |
| `canvas.GraphView` | a node editor on it: kinds of node, typed pins, wires |
| `canvas.draw` | shapes in pixels: `line`, `disc`, `rrect`, `bezier`, `wire`, `socket`, `arrow`, `checker`, `text`; `font(px)`; `vh(p)` / `vw(p)` |
| `canvas.C`, `canvas.TYPE` | the colours (light / dark follow the editor's Theme); per value type |
| `canvas.rgb("#rrggbb")`, `canvas.alpha(c, a)` | colours |
| `canvas.to_lua(t)` | a table as Lua source, to save data (`return ` .. it) |

### canvas.View

The camera maps world units to pixels: `self:to_screen(wx, wy)`,
`self:to_world(sx, sy)`, `self:z()` (the zoom, times lite's scale),
`self:zoom_at(f, sx, sy)`, `self:pan_by(dx, dy)`, `self:center_on(wx, wy)`,
`self:fit()` (shows `self:bounds()`, a world rect you define). A new tab fits
and keeps fitting as it resizes until the first pan or zoom.

The mouse, as in the node graph: LMB on nothing or MMB drags to pan,
double-click on nothing fits, the wheel scrolls (SHIFT: sideways), CTRL+wheel
zooms (`self.wheel_zooms = true`: the wheel zooms, as in an image viewer).
What's on the canvas gets the mouse first, in world units:
`on_canvas_pressed(button, wx, wy, clicks)` (return true to take it),
`on_canvas_moved(wx, wy)`, `on_canvas_released(button, wx, wy)`.

Draw in `draw_canvas()` (clipped, over the background and the grid) and
`draw_overlay()` (labels; `self:draw_status(text)`: the bottom-left box).
Its RMB menu is `self:menu_items()`: extend it (call
`canvas.View.menu_items(self)` and add yours). A view that edits a file
defines `self:save()` and sets `self.dirty`: CTRL+S saves it, closing it
asks first. Keep the camera across sessions with `self:camera_state()` in
`get_state` and `self:set_camera(state.cam)`.

### canvas.GraphView

Say what nodes there can be; it draws, selects, moves, wires, adds and
deletes them:

```lua
local Mat = canvas.GraphView:extend()
Mat.types = { color = "#c7c729", float = "#a1a1a1" }      -- a pin type's colour
Mat.kinds = {
  mix = { title = "Mix", color = "#3c3c83",
          ins = { { "a", "color" }, { "b", "color" }, { "t", "float" } },
          outs = { { "out", "color" } } },
}
-- self.graph = { nodes = { { id, kind, x, y, data } }, links = { { from, out, to, input } } }
```

A node's pins come from its kind; links name their pins. An output feeds any
number of inputs, an input reads one wire, and only pins of the same type
connect (`self:can_connect(out_type, in_type)`; `"any"` matches all). LMB
selects (CTRL: toggles) and drags; drag from a pin to wire it (from a wired
input: pick its wire up; drop it on nothing: gone); DELETE, CTRL+D; RMB: add a
node there (type to find it), duplicate, delete. Hooks: `on_change()` after
every edit, `node_extra(n)` / `draw_node_extra(n, x, y, w, h, z)` to draw
inside a node (a swatch, a value). `self.graph` is plain data:
`canvas.to_lua` saves it.

`plugins/materials` is the example: a material editor for `.mat` files in
about a hundred lines.

### canvas.ui: a side panel of widgets

Immediate mode, as the atlas's panels: the view draws the panel every frame
(in `draw_overlay`), the panel remembers where its widgets were for the mouse.

```lua
local ui = canvas.ui.new()                          -- one per panel, in the view's new()
-- draw_overlay():
ui:begin(x, y, w, h)                               -- the panel (its background; it scrolls when taller)
ui:head("Emitter")
ui:slider("Rate", d.rate, 0, 500, function(v) d.rate = v end,
          { fmt = "%.0f /s", step = 5, def = 40, int = false, done = function() end })
ui:check("Loop", d.loop, function() d.loop = not d.loop end)
ui:choice("Shape", d.shape, { "point", "circle", "box" }, function(v) d.shape = v end)
ui:color("Colour", d.color, function(c) d.color = c end, { done = fn })   -- { r, g, b, a } 0..255: a swatch; a click: the picker
ui:tiles(img, 16, sel, function(i, j) sel = { i, j } end, { rows = 4 })   -- a sheet of tiles: click one, drag several
ui:buttons({ { "Play", play, accent = true }, { "Save", save } })   -- a row (wraps)
ui:label("Alive", n); ui:text("a line"); ui:space()
ui:finish()
-- the mouse, first (true: the panel's):
ui:pressed(button, x, y, clicks); ui:moved(x, y); ui:released(button); ui:wheel(dy)
```

A slider: a click or a drag sets it, SHIFT drags finely, a double-click
resets it to `def`, CTRL+wheel nudges it by `step` (the wheel alone scrolls
the panel); `done()` when a drag ends (an undo step, a sound). A choice: a
click the next one, RMB the one before. `ui:button_at(x, y, text, fn)` draws
a button anywhere (a toolbar). The particle, sfxr and tilemap editors are
the examples.

More panel widgets: `ui:stepper(text, value, minus, plus)` (a number with
- / + beside it), `ui:field(text, value, on_commit, { key = })` (a line to
type in: a click edits it, Enter keeps it, Escape drops it),
`ui:list(rows, { reveal = i })` (rows of `{ text, info, kind = "head" |
"item" | "dim", indent, selected, icon = fn(x, y, size), press = fn(clicks),
button = { "x", fn, tip = } }`; a row's button shows on hover; returns the row
under the mouse). Buttons, list rows, steppers and fields take a `tip`: shown
once the mouse rests on them. A panel taller than its room scrolls (the
wheel, or drag its scroll bar). The atlas and the tilemap editor use them.

### The other shared pieces (plugins/canvas)

| | |
|---|---|
| `canvas.menu` | popup menus on a canvas (the node graph's): items, headers, separators, submenus, hints, colour rows, a fuzzy search box, the keyboard. `menu.open(x, y, items, bounds, { search = true })`, `menu.draw(m, mx, my)`, `menu.item_at / hover / open_child / step / jump / type / erase / wheel / bar_at / drag_bar`; items can be `checked`; `menu.from_lite(items [, eager])` turns lite's menu items (`{ text, info, command, checked, sub }`, DIVIDER) into these. Every right-click menu is one (contextmenu.lua): `P.menu` items look the same |
| `canvas.field` | a text being typed: `{ text, cur }` and `insert / backspace / delete / left / right / home / finish / paste / key / draw` (utf-8; multi-line with SHIFT+ENTER) |
| `canvas.scrollbar` | a scroll bar of its own: `sb:draw(x, y, w, h, total, shown, pos)`, `sb:pressed / moved / released` give the new position (the hex editor's, the panels') |
| `canvas.tip` | `tip.box(rows, x, y, bounds)`, `tip.text(...)`: tooltips; `tip.note()`: a note that fades. Every canvas view has `self:flash("Saved")` (bottom right, a few seconds) |

### canvas.picker: the colour picker

The node graph's, shared: a saturation / value square, a hue bar, an alpha
bar, a hex row (a click types one). `ui:color` opens it; any view can too:

```lua
local pk = canvas.picker.new(x, y, { r, g, b, a }, function(c, final) end, { alpha = true })
pk:draw()                                          -- last, over the rest
pk:pressed(button, x, y)  -- false: outside it (close it)
pk:moved(x, y); pk:released(); pk:text_input(t); pk:key(k)
canvas.picker.swatches(x, y, canvas.picker.PALETTE, current, mx, my)   -- a row of colour squares -> the one under the mouse
canvas.picker.hsv2rgb / rgb2hsv / parse_hex("#rgb" | "#rrggbb[aa]")
```

The parts work on any `{ x, y, h, s, v, a }` too (`rects`, `draw_parts`,
`part_at`, `pick_at`, `hex`): the node graph keeps its own state and edits.

### More for a plugin

- **Open tab with / beside with**: `require("plugins.openwith").register { key, name, order,
  can = fn(path), open = fn(path) -> a new view, is = fn(view, path) }`
  adds a way to open files (the hex editor: any file). Text, the tab-flip
  kinds and the plugins' extensions are there already. `openwith.list(path)`,
  `openwith.open(key, path)` (focuses the tab that shows it so, else a new
  one), `openwith.open_beside(key, path [, view])` (in the pane beside). A
  file's menus get *Open beside with >*, and *Open tab with >* when it has
  two ways or more.
- More items for a tab that shows a file:
  `require("plugins.tabmenu").file_items[key] = function(path, view) return item end`.
- **A tab of its own**: `P.tab = function() return MyView({}) end` lists the
  plugin in the main menu's *Plugins >* (a new untitled one; return
  nil when it asked for something itself). Without it, a plugin with a view
  asks for a file of its kind. `P.title` names it there and in *Open with*.
  `P.commands = { { "Find...", "myplugin:find" }, ... }` (lite commands) fill
  its menu there, each with its key (from the keymap; `key = "..."` to say
  another) and run on its tab (the active one, or the last one shown).
  An untitled view's first save: `canvas.save_as(ext, function(path) end)`
  asks where (`assets/untitled.<ext>`).
- RMB that isn't the menu (the tilemap's erase): `view:takes_right(x, y)`
  -> true, and the view gets the press.
- Sound: `host_audio_play(pcm, rate)` plays 16-bit little-endian mono PCM (a
  string), stopping what was playing; `host_audio_stop()`,
  `host_audio_queued()` (bytes still to play). The sfxr editor's.
- Big files: plain `io.open` / `f:seek` / `f:read(n)` take 64-bit offsets
  (the hex editor reads gigabytes in 1 MiB chunks).

## Images in lite

The plugins can draw images (stb_image: PNG, JPG, BMP, TGA, GIF's first
frame):

```lua
local img, err = renderer.image.load(path)   -- an Image, or nil, why
local w, h = img:get_size()
renderer.draw_image(img, x, y, w, h [, color [, sx, sy, sw, sh]]) -- the image (or its part: a tile) scaled into that rect
```

Writing one: `renderer.image.write_atlas(path, w, h, { { file =, x =, y = [, deg = 90] }... })`
copies those image files into a w x h picture (`deg = 90`: turned a quarter
clockwise) and writes it as a PNG (the atlas packer's sheet);
`renderer.image.compose(w, h, entries)` makes the same picture as an Image,
to draw. `renderer.image.regions(path [, alpha])` -> `{ { x, y, w, h }... }`:
the box around each patch of a picture that shows (alpha over 16; touching
pixels, corners too), specks under 4 px left out (the atlas's *Find
segments*). Fonts at any size: `canvas.draw.font(px [, mono, bold])`
(bold: `fonts/font_bold.ttf`).

`draw_image` is a draw command like `draw_rect`: lite's redraw cache knows when
it changes, and only the visible part of the rect costs anything. `color`
tints it (default white). An image is freed when it's garbage.

## The texture viewer, as an example

`plugins/texviewer/editor.lua`:

- reads `config.lua` (defaults when a setting is missing or of the wrong type);
- `P.open_with(P.read("files"), TexView)`;
- `TexView` is a `canvas.View` whose world is the image (a unit a pixel); it
  draws a checkerboard (squares a share of the monitor's height:
  `canvas.draw.vh`, the same on any screen), the image, and a pixel grid
  when zoomed in;
  the wheel zooms around the mouse, dragging pans, double-click toggles fit /
  100%;
- every half second it checks its file (changed: read again) and its
  `config.lua` / `files.lua` (`P.changed`);
- its `menu_items()`: fit, 100%, zoom, background (per tab, kept by
  `get_state`), pixel grid, reload image, copy path, plugin source, reload
  plugin.

## Starting the editor

| | |
|---|---|
| `play.exe` | the project launcher (`games/*`) |
| `play.exe games/pong.lua` (or `.hurdy`, or a folder) | a game: it runs |
| `play.exe texture.png` | an asset: the plugin whose `files.lua` lists its extension opens it, in front. The world is the game it's in (`games/<name>/...`, stopped), else none. No plugin takes it: exit code -1 |

(A renamed copy, `pong.exe`, still opens its own game: that's how a shipped
game starts.)

## Assets in the tree

A folder game's `assets/` folder is the tree's `/assets`. Its files that a
plugin opens show there (`/assets/sprites/ball.png`), read again every 2
seconds; other files are left out. They're files, not world data: never in
the world's save, the timeline or the network (`ecs.is_file`: a name with a
dot, under `/assets`). Click one, or its `edit` link, to open it in its
plugin.

On `/assets` and its folders: `+ folder` (a folder on disk) and a `+ <kind>`
per template a plugin ships: `plugins/<name>/templates/<kind>.<ext>`, copied
as `<typed name>.<ext>` and opened (`texviewer`: `texture.png`, `materials`:
`material.mat`, `atlaspacker`: `atlas.atlas.lua`, `particles`: `effect.pfx`,
`sfxr`: `sound.sfx`). An extension can have two
parts (`files.lua`: `"atlas.lua"`): `ui.atlas.lua` is then that plugin's,
not lite's Lua text (a name with a dot is never a world leaf). A game folder gets an empty `assets/` the first time it's
opened.

## Next

The asset pipeline (import, view / edit, use in the game, cook for export) is
meant to build on this: a plugin per asset type, each step a function it may
override.

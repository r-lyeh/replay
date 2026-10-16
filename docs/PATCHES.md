# Patches to third-party code

Everything under `editor/3rd/` and `runtime/hurdyl/` that differs from its upstream.
Checked against upstream on 2026-10-02 (line endings ignored). If you update
a library, re-apply what is listed here, or confirm upstream fixed it.

| Library | Upstream | Status |
|---|---|---|
| minilua | https://github.com/edubart/minilua (Lua 5.5.0) | unmodified (diffed) |
| SDL3 | https://github.com/libsdl-org/SDL (3.4.16, headers + prebuilt libs) | no known changes (not diffed) |
| Lite | https://github.com/r-lyeh/lite (fork of rxi/lite) | 1 file + 1 language + 1 plugin added, 10 files patched |
| hurdyl | https://codeberg.org/apicici/hurdyl (0.2.0) | 1 file patched |

---

## Lite (`editor/3rd/lite/`)

`stb_truetype.h` is unmodified. Search for `Replay` to find our changes in
`lite.h` and the plugins.

### Patched: `lite.h` — a bigger command buffer
`COMMAND_BUF_SIZE` went from 512 KB to 4 MB: a node graph full of wires
filled it ("exhausted command buffer" and missing drawing). The graph also
culls off-screen wires and uses fewer segments on short ones.

### Patched: `lite.h` — `renderer.draw_line(x1, y1, x2, y2, width, color)`
Lite could only fill rectangles and draw text; the node graph needs wires.
- `ren_draw_line()`: an anti-aliased line with round caps, on Lite's
  software surface and clipped like rects. Per row it only visits the span
  the line can touch; each pixel's coverage comes from its distance to the
  segment.
- `rencache`: a new `DRAW_LINE` command. Its rect is the line's bounding box
  (for the dirty cells); the end points and width are stored after the
  command, so they are part of its hash and a moved line redraws.
- `f_draw_line()`, registered as `renderer.draw_line` (width defaults to 1).
Curves are drawn in Lua as short segments.

### Added: `stb_image_write.h`, `data/fonts/font_bold.ttf`, `renderer.image.write_atlas` / `compose`
`stb_image_write.h` (v1.16, public domain / MIT, Sean Barrett), its
implementation in `editor/editor.c` (no stdio: written through SDL). `lite.h`:
`renderer.image.write_atlas(path, w, h, list)`, images copied into a sheet
(each `deg = 90`: turned a quarter clockwise) and written as a PNG
(plugins/atlaspacker); `renderer.image.compose(w, h, list)`: that sheet as an
Image (`lt_compose` does both); `renderer.image.regions(path [, alpha])`:
the boxes around a picture's patches that show (a cut atlas's segments). `data/fonts/font_bold.ttf`: Roboto Bold
2.137 (Apache 2.0, from the `roboto-fontface` package, WOFF converted to
TTF), the bold of `font.ttf` (Roboto Regular 2.137): same metrics.

### Added, then moved: the node graph (ours)
Now a project plugin, `plugins/nodegraph/` (2026-10-14): `require
"plugins.nodegraph.*"` finds it there (`data/replay.lua` adds a searcher for
project plugins' modules, ahead of Lite's own). Its tab flip went to
`data/plugins/tabflip.lua` and the tab menu to `data/plugins/tabmenu.lua`
(both ours, every tab's). Lua files as node graphs, in a Lite tab: `init.lua` (opening, tab flip, hooks),
`view.lua` (the view; its parts: `edits.lua`, `input.lua`, `draw.lua`, plus
`class.lua`, `theme.lua`, `util.lua`), `graph.lua` (layout), `luaparse.lua`,
`resolve.lua`. Not from upstream; listed here because it lives in Lite's
folder. It uses the `draw_line`, workspace and context menu patches. Its `init.lua`
wraps `RootView:on_mouse_wheel` once all plugins are loaded, so the wheel over
a graph (ctrl included) goes to the graph instead of the scale plugin.

### Patched: `data/plugins/workspace.lua` — tabs that remember their state
A non-document tab was saved as its module name only and rebuilt with no
arguments, so a graph tab would forget its file. Now `save_view()` also
stores `view:get_state()` (when the view has one) and `load_view()` passes
it back: `require(t.module)(t.state)`. Views without `get_state` work as before.
The file is `.workspace.lua` (was `.lite_workspace.lua`; an old one is
still read once when there's no new one, then saved under the new name).

### Added: `lite_sys_sdl3.h` (SDL3 backend)
Written for this project. It replaces the fork's `lite_sys.h` (GLFW / FWK)
and is ported from rxi/lite's SDL2 backend (`src/api/system.c`,
`renderer.c`). Embedding model: the host owns the window, renderer and
event loop. It forwards SDL events with `lt_sdl3_push_event()` and draws
Lite's texture (`lt_sdl3_texture()`) wherever it likes. Used by `editor/editor.c`.
`mousewheel` events carry the horizontal amount as a second value (`y, x`);
Lite's own views ignore it, the node graph scrolls sideways with it.

### Added: `data/languages/language_hurdy.lua`
Syntax highlighting for `*.hurdy` files: keywords, `--` and `-* *-`
comments, and operators (`!=`, `**`, `+=`...).

### Patched: tab close buttons (`data/core/node.lua`, `data/core/rootview.lua`, `data/plugins/contextmenu.lua`)
A port of lite-xl 1.16.2 commits ca6d1843, 4cda8fc1 and e861ea1d.
- `node.lua`:
  - `Node` gets `hovered_close`, plus a `tab_mouse_moved()` that tracks
    whether the mouse is over a tab's close button.
  - `close_button_location()` places the button.
  - `draw_cross()` draws a small cross, because our icon font has no close glyph.
  - The active or hovered tab shows the cross. The tab title is clipped
    before it.
- `rootview.lua`: a left click on a hovered close button closes the tab,
  like the right and middle buttons. The condition became
  `button == "right" or button == "middle" or node.hovered_close == idx`.
- `plugins/contextmenu.lua`: this plugin overrides
  `RootView:on_mouse_pressed`, so its copy needed the same one-line change.

Search for `close button (lite-xl)` to find the patched lines.

### Patched: `data/core/node.lua`, `data/core/config.lua` — tabs always shown
Lite drew the tab bar only when a node held two or more views, so a lone file
(or graph) had no tab to click. New `config.always_show_tabs = true`, and
`Node:shows_tabs()` (used by the layout, the drawing and the tab hit test)
shows it for one view too, except on locked side panels and the empty view.
Marked `Replay`.

### Patched: `data/core/node.lua` — a slot left of a tab's name
`Node:draw_tabs` calls `Node.tab_left(node, view, i, x, y, w, h)` if it is
set; it draws something left of the name and returns the width it used (the
name's area shrinks by that). The nodegraph plugin sets it: its flip icon.
Marked `Replay`.

### Overridden (not patched): `RootView:open_doc`
It returned any view in the node with that `.doc`, the graph included, and
callers (tree view, find in project...) then called `scroll_to_line` on it.
`plugins/nodegraph/init.lua` wraps it: a graph of that document in the active
node is flipped back to text. The graph also has a `scroll_to_line` of its own.

### Overridden (not patched): right-click on a tab
`plugins/nodegraph/init.lua` wraps `RootView:on_mouse_pressed` once all plugins
are loaded: a right-click on the tab of a Lua file (or its graph) flips that
tab between text and graph instead of closing it. Other tabs still close on a
right-click; the middle button and the cross close any tab.

### Patched: `data/plugins/contextmenu.lua` — drawn by canvas.menu
Its API stays (register, `last`, DIVIDER, items with text / command / info /
checked / sub), but a menu is now a `plugins/canvas/menu.lua` menu: the node
graph's look, search box, submenus of any depth, scroll bar (dragged), keys.
`CM.from_lite(items, true)` converts the items when it opens (submenus built
then, so the search finds their items).

### Patched: `data/plugins/contextmenu.lua` — "Open tab with" / "Open beside with"
The document right-click menu is built when it opens: after Cut / Copy /
Paste, `Open tab with >` and `Open beside with >` (plugins/openwith.lua),
before `Command Palette...`. `menu.no_last`: a menu without
`ContextMenu.last`'s items (a tab's: plugins/tabmenu.lua). RootView's wheel and mouse release go to an open menu first.

### Patched: Lua 5.5 loop variables (`data/core/doc/init.lua`, `data/plugins/console.lua`, `data/plugins/markers.lua`)
Lua 5.5 makes `for` loop variables read-only, and these loops assigned to theirs.
Each loop now iterates into `line_` and copies it into a local:
`for line_ in ... do local line = line_`. Each line is marked
`--< Lua 5.5: loop variables are const`. These patches predate the
2026-10-02 session.

---

### Patched: `data/plugins/eofnewline.lua` — no empty edit on save
On every save it removed "the blank lines at the end" even when there were
none; an empty `doc:remove` still lands on the undo stack, so the first
ctrl+z after a save did nothing visible. Now it only removes when there is
something to remove.

### Rebound: ctrl+shift+t (todotreeview)
`todotreeview:toggle` loses ctrl+shift+t to `core:duplicate-tab` (the
nodegraph plugin binds it after every plugin loaded); the command is still
in the palette.

## hurdyl (`runtime/hurdyl/`)

### Patched: `transpiler.lua` — compound assignment to a field
`a.b += 1` crashed the compiler with `attempt to call a nil value`, while
`a[k] += 1` and `x += 1` worked. `visit[Stmt.OpAssign]` cached the key
whenever it wasn't a literal, and for `a.b` the key is `nil` (the name is
in `p.name`), so it compiled a nil expression. Fix, marked `Replay fix`:

```lua
local cacheKey = p and p.key ~= nil and getmetatable(p.key) ~= Expr.Literal;
```

Worth reporting upstream.

### Not patched, but worked around: off-by-one line map
`hurdy.compile()` returns a line map where `map[n]` belongs to Lua line
`n + 1`, so errors would point one Hurdy line too far. Each compiled Lua
line ends in a `--[[hurdy line]]` comment, and `ecs.languages.hurdy`
(runtime/ecs.lua) builds the map from those comments instead.

---

## Not third-party (for the record)

These look like vendored code but are ours: `editor/editor.c` (Lite embedding,
the log tab: `lite_show_log` / `lite_hide_log` / `lite_boot_log`), `editor/*.h`, `runtime/{ecs,disk,fs,net}.lua`.

### Patched: `data/core/node.lua`, `data/core/rootview.lua`, `data/plugins/contextmenu.lua` — pane lines, tab drag

- `node.lua`: `Node:resizable()` (neither side has a locked size). Only those
  splits can be grabbed (`get_divider_overlapping_point`), and `Node:draw()`
  draws them again after their panes, a little wider, in `style.pane_divider`
  (dark teal `#2a3c44`), `pane_divider_hover` (`#3a7d90`) under the mouse,
  `pane_divider_drag` (aqua `#3fb8d8`) while dragged. Locked splits (status
  bar, side panels) keep Lite's thin dim divider. `Node.EmptyView` exported.
- `rootview.lua`: `hovered_divider`; a left press on a tab starts
  `tab_drag`; dragged past 8 px, it shows its name under the mouse and
  outlines where it would land (`tab_target`: a pane, or the half near an
  edge); released: `drop_tab` moves the view (into that pane, a new split,
  or a new place among its own tabs), closing the pane it left when empty.
- `contextmenu.lua` (its copy of `RootView:on_mouse_pressed`): starts
  `tab_drag` too.

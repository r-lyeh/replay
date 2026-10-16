-- nodegraph: Lua files as node graphs, in a lite tab (ours, not upstream lite).
-- The graph is another view of the text: the text stays the source of truth.
-- See view.lua for what it can do (move, colour, edit, rename, rewire, zoom).
--
-- Open: right-click a Lua file's tab (flips that tab between text and graph),
-- or right-click in the text > "Open beside with > Node graph" (the graph in
-- the pane beside the text: plugins/openwith.lua), or the commands "nodegraph:open-tab",
-- "nodegraph:open" / "nodegraph:flip", or require("plugins.nodegraph").open(filename).
local core = require "core"
local command = require "core.command"
local DocView = require "core.docview"
local NodeGraphView = require "plugins.nodegraph.view"

local M = { View = NodeGraphView }

-- the graph tab of a document, if open
local function find_graph(doc)
  local found
  local function walk(node)
    if node.type == "leaf" then
      for _, v in ipairs(node.views) do
        if v:is(NodeGraphView) and v.doc == doc then found = found or { node, v } end
      end
    else walk(node.a); walk(node.b) end
  end
  walk(core.root_view.root_node)
  return found
end

-- flip a tab between the text and the graph of the same document, in place
-- (plugins/tabflip.lua: the icon on the tab, its tooltip; the other view is
-- kept for the next flip)
local tabflip = require "plugins.tabflip"
tabflip.register {
  key = "nodegraph",
  name = "nodegraph",
  text = function(view) return view:is(DocView) and view.doc and view.doc.filename and view.doc.filename:match("%.lua$") ~= nil end,
  alt = function(view) return view:is(NodeGraphView) and view.doc ~= nil end,
  to_alt = function(view) return NodeGraphView(view.doc) end,
  to_text = function(view) return DocView(view.doc) end,
  icon = function(x, y, s, c)                      -- two nodes and a wire
    local t = math.max(1, math.floor(s / 7))
    local b = math.max(3, math.floor(s * 0.38))
    renderer.draw_rect(x, y, b, b, c)
    renderer.draw_rect(x + s - b, y + s - b, b, b, c)
    renderer.draw_rect(x + b, y + math.floor(b / 2), math.floor((s - b) / 2), t, c)
    renderer.draw_rect(x + math.floor((s + b) / 2) - t, y + math.floor(b / 2), t, s - b, c)
    renderer.draw_rect(x + math.floor((s + b) / 2) - t, y + s - b + math.floor(b / 2), math.floor((s - b) / 2), t, c)
  end,
  tip = "Show as node graph",
  menu = "Toggle graph / Lua",
  after = function(old, new)
    if new:is(DocView) then                        -- show where the graph's selection is
      local line = old.doc:get_selection()
      new:scroll_to_line(line, true, true)
    end
  end,
}
function M.can_flip(view)
  local k = tabflip.kind_of(view)
  return k ~= nil and k.key == "nodegraph"
end
function M.flip(node, view)
  if not M.can_flip(view) then return end
  return tabflip.flip(node, view)
end

-- show `doc` as a graph: its graph tab if there is one, else flip the text
-- tab showing it, else open a graph to the right
function M.open_doc(doc)
  local f = find_graph(doc)
  if f then
    f[1]:set_active_view(f[2])
    core.set_active_view(f[2])
    return f[2]
  end
  local av = core.active_view
  if av and av:is(DocView) and av.doc == doc then
    local node = core.root_view.root_node:get_node_for_view(av)
    if node then return M.flip(node, av) end
  end
  local view = NodeGraphView(doc)
  local node = core.root_view:get_active_node()
  if node.locked then node = core.root_view.root_node:get_child_overlapping_point(0, 0) end
  node:split("right", view)
  core.set_active_view(view)
  return view
end

-- the graph in a tab of its own, beside the text: the text on the left, the
-- graph in the pane to its right (made if there is none). Its graph tab if
-- there is one already.
function M.open_beside(doc)
  local f = find_graph(doc)
  if f then
    f[1]:set_active_view(f[2])
    core.set_active_view(f[2])
    return f[2]
  end
  local view = NodeGraphView(doc)
  local root = core.root_view.root_node
  local av = core.active_view
  local node = av and root:get_node_for_view(av) or core.root_view:get_active_node()
  local function parent_of(n, p)
    if n == node then return p end
    if n.type ~= "leaf" then return parent_of(n.a, n) or parent_of(n.b, n) end
  end
  local p = parent_of(root)
  local right                                      -- the pane right of the text's, if any
  if p and p.type == "hsplit" and p.a == node and not p.b.locked then
    right = p.b
    while right.type ~= "leaf" do right = right.a end
  end
  if right and not right.locked then right:add_view(view)
  else
    if node.locked then node = root:get_child_overlapping_point(0, 0) end
    node:split("right", view)
  end
  core.set_active_view(view)
  return view
end

function M.open(filename)
  return M.open_doc(core.open_doc(filename))
end


-- a right-click on a tab: its menu (close, copy path, browse, flip): lite's
-- plugins/tabmenu.lua, every tab's

-- the wheel over a graph goes to the graph, ctrl too: there it zooms the graph,
-- not lite (the scale plugin takes ctrl+wheel; it loads after us, so wrap
-- RootView once every plugin is in)
core.add_thread(function()
  local RootView = require "core.rootview"
  local on_mouse_wheel = RootView.on_mouse_wheel
  function RootView:on_mouse_wheel(...)
    local node = self.root_node:get_child_overlapping_point(self.mouse.x, self.mouse.y)
    local v = node and node.active_view
    if v and v:is(NodeGraphView) then return v:on_mouse_wheel(...) end
    return on_mouse_wheel(self, ...)
  end
end)

-- opening a document whose graph is showing (tree view, find in project...):
-- RootView:open_doc would return the graph (it has .doc too) and callers then
-- call DocView methods on it; flip that tab back to text instead
core.add_thread(function()
  local RootView = require "core.rootview"
  local open_doc = RootView.open_doc
  function RootView:open_doc(doc)
    local node = self:get_active_node()
    if node and not node.locked then
      for _, v in ipairs(node.views) do
        if v.doc == doc and v:is(DocView) then return open_doc(self, doc) end
      end
      for _, v in ipairs(node.views) do
        if v.doc == doc and v:is(NodeGraphView) then return M.flip(node, v) end
      end
    end
    return open_doc(self, doc)
  end
end)


-- a click in a text view: every open graph tab of that file selects the
-- node of the clicked code and brings it into view
do
  local on_mouse_released = DocView.on_mouse_released
  function DocView:on_mouse_released(button, ...)
    local was = self.mouse_selecting
    local r = on_mouse_released(self, button, ...)
    if button == "left" and was and not self:is(NodeGraphView) then
      local line, col = self.doc:get_selection()
      local function walk(node)
        if node.type == "leaf" then
          for _, v in ipairs(node.views) do
            if v:is(NodeGraphView) and v.doc == self.doc then v:locate(line, col) end
          end
        else walk(node.a); walk(node.b) end
      end
      walk(core.root_view.root_node)
    end
    return r
  end
end

command.add("core.docview", {
  ["nodegraph:open"] = function() M.open_doc(core.active_view.doc) end,
  ["nodegraph:open-tab"] = function() M.open_beside(core.active_view.doc) end,
})
command.add(function() return M.can_flip(core.active_view) end, {
  ["nodegraph:flip"] = function()
    local v = core.active_view
    M.flip(core.root_view.root_node:get_node_for_view(v), v)
  end,
})

-- ctrl+shift+n / ctrl+shift+t: duplicate the current tab (the same document
-- in a new tab beside it, in the same pane): a text tab keeps its scroll and
-- caret, a graph tab its pan and zoom. (Bound after every plugin loaded, so
-- it wins over todotreeview's ctrl+shift+t; that one stays in the palette.)
function M.duplicate(view)
  local node = view and core.root_view.root_node:get_node_for_view(view)
  if not (node and view.doc) then return end
  local nv
  if view:is(NodeGraphView) then
    nv = NodeGraphView(view.doc)
    nv.pan, nv.zoom, nv.restored = { x = view.pan.x, y = view.pan.y }, view.zoom, true
  elseif getmetatable(view) == DocView then
    nv = DocView(view.doc)
    nv.scroll.x, nv.scroll.y = view.scroll.x, view.scroll.y
    nv.scroll.to.x, nv.scroll.to.y = view.scroll.to.x, view.scroll.to.y
  else
    return
  end
  node:add_view(nv)
  return nv
end
command.add(function()
  local v = core.active_view
  return v and v.doc and (v:is(NodeGraphView) or getmetatable(v) == DocView)
end, {
  ["core:duplicate-tab"] = function() M.duplicate(core.active_view) end,
})
core.add_thread(function()
  require("core.keymap").add { ["ctrl+shift+n"] = "core:duplicate-tab", ["ctrl+shift+t"] = "core:duplicate-tab" }
end)

-- breakpoints in the text (breaks.lua): a click in the gutter, or F9 at the
-- caret's line (a graph: its selected node); a red dot left of the number
local B = require "plugins.nodegraph.breaks"
local style = require "core.style"
local config = require "core.config"
local gutter0, pressed0 = DocView.draw_line_gutter, DocView.on_mouse_pressed
function DocView:draw_line_gutter(idx, x, y)
  gutter0(self, idx, x, y)
  if self.doc and self.doc.filename and B.has(self.doc.filename, idx) then
    local lh = self:get_line_height()
    local d = math.max(7, lh * 0.55)
    local cy = y + lh / 2 + d / 4                  -- (the text sits low in its line: down by half a radius)
    renderer.draw_line(x + style.padding.x * 0.5, cy, x + style.padding.x * 0.5, cy, d, { 224, 70, 78, 255 })
  end
end
-- a breakpoint stays on its statement while the text above it changes: lines
-- inserted or removed before it (typed, pasted, undone, or a graph edit's
-- `--@node` line) move it with its line
local Doc = require "core.doc"
local function blank(s) return not s:find("%S") end
local function move_breaks(doc, f)               -- f(line) -> its new line (or the same)
  local moves = {}
  for _, l in ipairs(B.lines(doc.filename)) do
    local nl = f(l)
    if nl ~= l then moves[#moves + 1] = { l, nl } end
  end
  return moves
end
local function apply_moves(doc, moves)
  for _, m in ipairs(moves) do B.set(doc.filename, m[1], false) end
  for _, m in ipairs(moves) do B.set(doc.filename, m[2], true) end
end
local raw_insert0, raw_remove0 = Doc.raw_insert, Doc.raw_remove
function Doc:raw_insert(line, col, text, ...)
  local k = select(2, text:gsub("\n", ""))
  local moves = {}
  if k > 0 and self.filename then
    local whole = blank((self.lines[line] or ""):sub(1, col - 1))   -- (only indentation before: the line itself moves down)
    moves = move_breaks(self, function(l) return (l > line or (l == line and whole)) and l + k or l end)
  end
  local r = raw_insert0(self, line, col, text, ...)
  if #moves > 0 then apply_moves(self, moves) end
  return r
end
function Doc:raw_remove(line1, col1, line2, col2, ...)
  local k = line2 - line1
  local moves = {}
  if k > 0 and self.filename then
    moves = move_breaks(self, function(l) return l > line2 and l - k or (l > line1 and line1 or l) end)
  end
  local r = raw_remove0(self, line1, col1, line2, col2, ...)
  if #moves > 0 then apply_moves(self, moves) end
  return r
end
-- a breakpoint set on a line outside every function: it runs once, at load
-- (the world stops only code that runs every frame): say so
local function warn_at_load(doc, line)
  if not B.has(doc.filename, line) then return end
  local src = doc:get_text(1, 1, math.huge, math.huge)
  local ast = require("plugins.nodegraph.luaparse").parse(src)
  if not ast then return end
  local at = 1
  for _ = 2, line do at = (src:find("\n", at, true) or #src) + 1 end
  local inner                                     -- the innermost function holding that line
  local function walk(e)
    if type(e) ~= "table" then return end
    if e.tag == "Function" and e.body and e.pos and e.epos and e.pos < at and at <= e.epos then inner = e end
    for _, v in pairs(e) do if type(v) == "table" then walk(v) end end
  end
  walk(ast)
  if not inner and NodeGraphView.is_root(doc.filename) then core.status_view:show_message("i", style.text, NodeGraphView.AT_BOOT_NOTE)
  elseif not inner then core.status_view:show_message("i", style.text, NodeGraphView.AT_LOAD_NOTE)
  elseif NodeGraphView.factories(ast)[inner.pos] then core.status_view:show_message("i", style.text, NodeGraphView.AT_SETUP_NOTE) end
end
local in_label                                     -- (below: the "N breakpoints" label under the mouse?)
local moved0 = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)          -- over the gutter: the arrow (a click there: a breakpoint)
  moved0(self, x, y, ...)
  self.hover_x, self.hover_y = x, y
  local hot = in_label(self, x, y)
  if hot ~= self.bp_hot then self.bp_hot = hot; core.redraw = true end
  if hot then self.cursor = "hand" end
  local over_watch = false
  for _, r in ipairs(self.watch_hits or {}) do      -- (the watches: clickable)
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then over_watch = true end
  end
  if over_watch ~= (self.watch_hot or false) then self.watch_hot = over_watch; core.redraw = true end
  if over_watch then self.cursor = "hand" end
  if B.where() then core.redraw = true end         -- (stopped: the value tooltip follows the mouse)
  if getmetatable(self) == DocView and self.doc and self.doc.filename then
    if x < self.position.x + self:get_gutter_width() and y >= self.position.y then self.cursor = "arrow" end
  end
end
-- stopped at a breakpoint, the text shows what the world did (host_probe, as
-- the graph): the lines that ran in that frame tinted (the stop's line
-- stronger), and a local under the mouse shows its value in a tooltip
local KEYWORDS = {}
for w in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%S+") do KEYWORDS[w] = true end
local tprobe = {}                                  -- abs file -> { at, src, t }
local function text_probe(view)
  if not (view.doc and view.doc.filename and B.where()) then return nil end
  local hp = rawget(_G, "host_probe")
  if not hp then return nil end
  local abs = B.abs(view.doc.filename)
  local c = tprobe[abs] or {}
  tprobe[abs] = c
  local now = system.get_time()
  if not c.at or now - c.at > 0.1 then
    c.at = now
    local s = hp(abs)
    if s ~= c.src then
      c.src = s
      local f = s and load(s, "=probe", "t", {})
      local ok, t = false, nil
      if f then ok, t = pcall(f) end
      c.t = ok and type(t) == "table" and t.lines and next(t.lines) and t or nil
    end
  end
  return c.t, abs
end
local function char_at(view, x, y)                 -- the line and column of the letter under x, y
  local line, col = view:resolve_screen_position(x, y)  -- (Lite's: where a caret goes, the next one past a letter's middle)
  if line and col > 1 then
    local sx = view:get_line_screen_position(line)
    if sx + view:get_font():get_width((view.doc.lines[line] or ""):sub(1, col - 1)) > x then col = col - 1 end
  end
  return line, col
end
M.char_at = char_at
local function expr_at(text, col)                  -- the name (a.b.c, up to the part under col) at a column
  if text:sub(col, col) == "." and text:sub(col - 1, col - 1):match("[%w_]") and text:sub(col + 1, col + 1):match("[%a_]") then
    col = col + 1                                  -- (on a dot: the field after it, v.x)
  end
  for s, e in text:gmatch("()[%a_][%w_]*()") do
    if col >= s and col < e then
      local a = s
      while a > 2 and text:sub(a - 1, a - 1) == "." and text:sub(a - 2, a - 2):match("[%w_]") do
        local b = a - 2
        while b > 1 and text:sub(b - 1, b - 1):match("[%w_]") do b = b - 1 end
        if not text:sub(b, b):match("[%a_]") then break end
        a = b
      end
      local word = text:sub(s, e - 1)
      if KEYWORDS[word] then return nil end
      if text:sub(s - 1, s - 1) == ":" then return nil end   -- (a method name: not a value)
      return text:sub(a, e - 1)
    end
  end
end
local function value_of(P, abs, line, expr)        -- -> value, the line it's read at
  local base = expr:match("^[%a_][%w_]*")
  local cands, seen = {}, {}
  local function add(l) if l and not seen[l] and P.lines[l] then seen[l] = true; cands[#cands + 1] = l end end
  add(P.brk); add(line)
  local later = {}
  for l in pairs(P.lines) do if l > line then later[#later + 1] = l end end
  table.sort(later)
  for _, l in ipairs(later) do add(l) end
  local ev = rawget(_G, "host_probe_eval")
  for _, l in ipairs(cands) do
    local v = P.lines[l].v[base]
    if v then
      if expr == base then return v, l end
      local x = ev and ev(abs, l, expr)
      if x then return x, l end
    end
  end
end
-- where a variable was declared (the text parsed: a fallback when the frame
-- shown never saw it change: a parameter, an upvalue)
local parse_cache = setmetatable({}, { __mode = "k" })
local function decl_line(doc, line, col)
  local id = doc:get_change_id()
  local c = parse_cache[doc]
  if not c or c.id ~= id then
    local src = doc:get_text(1, 1, math.huge, math.huge)
    local ok, ast = pcall(require("plugins.nodegraph.luaparse").parse, src)
    local r = ok and ast and require("plugins.nodegraph.resolve").resolve(ast)
    c = { id = id, src = src, r = r }
    parse_cache[doc] = c
  end
  if not c.r then return nil end
  local at = col
  for l = 1, line - 1 do at = at + #(doc.lines[l] or "") end
  local found
  for _, d in ipairs(c.r.decls) do if d.pos <= at and at <= d.epos then found = d end end   -- (the declaration itself)
  for _, u in ipairs(found and {} or c.r.uses) do
    if u.pos <= at and at <= u.epos then found = u.decl or false end
  end
  do
    local d = found
    if d then
      local n = 1
      for _ in c.src:sub(1, d.pos):gmatch("\n") do n = n + 1 end
      return n
    end
  end
end
-- "(at line N)": the line that last set it (the probe), else where it's declared
local function set_at(P, doc, line, col, expr, read_at)
  local base = expr:match("^[%a_][%w_]*")
  local upto = P.brk or read_at
  local a = B.changed_at(P, base, upto, doc.lines)              -- (its value changed after that line ran)
  local b = B.assigned_at(P, expr, upto, doc.lines, upto ~= P.brk)   -- (that line assigns it: x.y = ...)
  if a and b then return (P.lines[b].s or 0) > (P.lines[a].s or 0) and b or a end
  return a or b or decl_line(doc, line, col)
end
M.set_at = set_at

-- watches: a name (a.b.c) kept on show in the corner of its file's text,
-- its value while the world is stopped (a table unfolds: its fields);
-- right-click a name > Add watch / Remove watch. For this session.
B.watches = B.watches or {}
local function watch_of(abs, expr)
  for i, wt in ipairs(B.watches) do if wt.file == abs and wt.expr == expr then return wt, i end end
end
function M.add_watch(abs, expr) if not watch_of(abs, expr) then B.watches[#B.watches + 1] = { file = abs, expr = expr } end core.redraw = true end
function M.remove_watch(abs, expr) local _, i = watch_of(abs, expr); if i then table.remove(B.watches, i) end core.redraw = true end
require("plugins.contextmenu").docview_extras[#require("plugins.contextmenu").docview_extras + 1] = function(view)
  if not (view and getmetatable(view) == DocView and view.doc and view.doc.filename and view.hover_x) then return nil end
  local line, col = M.char_at(view, view.hover_x, view.hover_y)
  local expr = line and M.expr_at(view.doc.lines[line] or "", col)
  if not expr then return nil end
  local abs = B.abs(view.doc.filename)
  if watch_of(abs, expr) then
    return { { text = "Remove watch " .. expr, command = function() M.remove_watch(abs, expr) end, tags = "debug;unwatch" } }
  end
  return { { text = "Add watch " .. expr, command = function() M.add_watch(abs, expr) end, tags = "debug;inspect;variable" } }
end
-- a watch's value: where the world stopped (in this file), else the last line that knows it
local function watch_value(P, abs, wt)
  if not P then return nil end
  local base = wt.expr:match("^[%a_][%w_]*")
  local best
  if P.brk and P.lines[P.brk] and P.lines[P.brk].v[base] then best = P.brk
  else
    for l, r in pairs(P.lines) do
      if r.v[base] and (not best or (r.s or 0) > (P.lines[best].s or 0)) then best = l end
    end
  end
  if not best then return nil end
  local ev = rawget(_G, "host_probe_eval")
  local v = wt.expr == base and P.lines[best].v[base] or (ev and ev(abs, best, wt.expr))
  return v, best
end
local function watch_rows(view)                    -- { { text, kind = "watch" | "field" | "x", wt, field } } for this file
  local abs = B.abs(view.doc.filename)
  local P = text_probe(view)
  local rows = {}
  for _, wt in ipairs(B.watches) do
    if wt.file == abs then
      local v, l = watch_value(P, abs, wt)
      local tab = v and v:sub(1, 1) == "{"
      rows[#rows + 1] = { text = (tab and (wt.open and "- " or "+ ") or "  ") .. wt.expr .. " = " .. (v or "?"), kind = "watch", wt = wt, line = l, dim = not v }
      if tab and wt.open and l then
        local ev = rawget(_G, "host_probe_eval")
        local f = ev and ev(abs, l, "\1fields " .. wt.expr)
        for k, fv in (f or ""):gmatch("([^\t\n]*)\t([^\n]*)") do
          rows[#rows + 1] = { text = "    ." .. k .. " = " .. fv, kind = "field", wt = wt }
        end
      end
    end
  end
  return rows
end
M.watch_rows = watch_rows
M.text_probe_of = function(view) return (text_probe(view)) end
local function watch_layout(view, y0)              -- the rows placed: top right, under the breakpoints' label
  local rows = watch_rows(view)
  if #rows == 0 then return rows end
  local font = style.font
  local mw = (config.minimap_enabled and (config.minimap_width or 0) or 0) * SCALE + style.scrollbar_size
  local w = 0
  for _, r in ipairs(rows) do w = math.max(w, font:get_width(r.text)) end
  w = math.min(w + style.padding.x + 14 * SCALE, view.size.x * 0.6)
  local h = font:get_height() + 2 * SCALE
  local x = view.position.x + view.size.x - mw - w - style.padding.x / 2
  for i, r in ipairs(rows) do r.x, r.y, r.w, r.h = x, y0 + (i - 1) * h, w, h end
  return rows
end
M.watch_layout = watch_layout

local body0 = DocView.draw_line_body
function DocView:draw_line_body(idx, x, y)
  local P = getmetatable(self) == DocView and text_probe(self)
  local r = P and P.lines[idx]
  if r then
    local _, ly = self:get_line_screen_position(idx)
    local c = idx == P.brk and { 224, 70, 78, 70 } or { style.accent[1], style.accent[2], style.accent[3], 28 }
    renderer.draw_rect(self.position.x + self:get_gutter_width(), ly, self.size.x, self:get_line_height(), c)
  end
  return body0(self, idx, x, y)
end
-- "N breakpoints", top right (left of the minimap): a click goes to the next one
local function bp_label(view)
  local n = #B.lines(view.doc.filename)
  if n == 0 then return nil end
  local t = n .. (n == 1 and " breakpoint" or " breakpoints")
  local font = style.font
  local mw = (config.minimap_enabled and (config.minimap_width or 0) or 0) * SCALE + style.scrollbar_size
  local w, h = font:get_width(t) + style.padding.x, font:get_height() + style.padding.y / 2
  return t, view.position.x + view.size.x - mw - w - style.padding.x / 2, view.position.y + style.padding.y / 2, w, h
end
local draw0 = DocView.draw
function DocView:draw(...)
  draw0(self, ...)
  if getmetatable(self) ~= DocView or not (self.doc and self.doc.filename) then return end
  local t, lx, ly, lw, lh = bp_label(self)
  if t then
    local hot = self.bp_hot
    renderer.draw_rect(lx, ly, lw, lh, hot and { 224, 70, 78, 60 } or { style.background2[1], style.background2[2], style.background2[3], 220 })
    renderer.draw_text(style.font, t, lx + style.padding.x / 2, ly + style.padding.y / 4, { 224, 70, 78, 255 })
  end
  local wy = (t and ly + lh or self.position.y + style.padding.y / 2) + 2 * SCALE
  local rows = watch_layout(self, wy)
  self.watch_hits = rows
  for _, r in ipairs(rows) do                       -- the watches: name = value, a table unfolds (+ / -), x removes
    local hot = self.hover_x and self.hover_x >= r.x and self.hover_x < r.x + r.w and self.hover_y >= r.y and self.hover_y < r.y + r.h
    renderer.draw_rect(r.x, r.y, r.w, r.h, hot and { style.selection[1], style.selection[2], style.selection[3], 230 }
                                             or { style.background2[1], style.background2[2], style.background2[3], 255 })
    local c = r.dim and style.dim or (r.kind == "field" and style.syntax["string"] or style.syntax["function"]) or style.text
    renderer.draw_text(style.font, r.text, r.x + style.padding.x / 2, r.y + SCALE, c)
    if r.kind == "watch" then renderer.draw_text(style.font, "x", r.x + r.w - 10 * SCALE, r.y + SCALE, style.dim) end
  end
  local P, abs = text_probe(self)
  local mx, my = self.hover_x, self.hover_y
  if P and mx and mx >= self.position.x + self:get_gutter_width() and mx < self.position.x + self.size.x
     and my >= self.position.y and my < self.position.y + self.size.y then
    local line, col = char_at(self, mx, my)
    local expr = line and expr_at(self.doc.lines[line] or "", col)
    local v, at = nil, nil
    if expr then v, at = value_of(P, abs, line, expr) end
    if v then
      local set = set_at(P, self.doc, line, col, expr, at)
      local tip = expr .. " = " .. v .. (set and ("   (at line " .. set .. ")") or "")
      core.root_view:defer_draw(function()
        local font = style.font
        local tw, th = font:get_width(tip) + 12 * SCALE, font:get_height() + 6 * SCALE
        local tx, ty = mx + 14 * SCALE, my + 12 * SCALE
        renderer.draw_rect(tx, ty, tw, th, { 22, 22, 26, 240 })
        renderer.draw_text(font, tip, tx + 6 * SCALE, ty + 3 * SCALE, { 230, 230, 230, 255 })
      end)
    end
  end
end
M.text_value = function(view, line, expr)        -- (tests: what the tooltip would say)
  local P, abs = text_probe(view)
  if P then return value_of(P, abs, line, expr) end
end
M.expr_at, M.bp_label = expr_at, bp_label
in_label = function(view, x, y)
  if getmetatable(view) ~= DocView or not (view.doc and view.doc.filename) then return false end
  local t, lx, ly, lw, lh = bp_label(view)
  return t and x >= lx and x < lx + lw and y >= ly and y < ly + lh
end
function DocView:on_mouse_pressed(button, x, y, clicks)
  for _, r in ipairs(button == "left" and getmetatable(self) == DocView and self.watch_hits or {}) do
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      if r.kind == "watch" and x >= r.x + r.w - 14 * SCALE then M.remove_watch(r.wt.file, r.wt.expr)   -- x: gone
      elseif r.kind == "watch" and r.text:match("^[%+%-] ") and x < r.x + style.padding.x / 2 + style.font:get_width("+ ") then
        r.wt.open = not r.wt.open                  -- +/-: its fields
      elseif r.kind == "watch" then                -- the name: where it was last set (else declared)
        local P = text_probe(self)
        local to = P and B.changed_at(P, r.wt.expr:match("^[%a_][%w_]*"), P.brk, self.doc.lines)
        if not to then
          for l, line in ipairs(self.doc.lines) do
            local c = line:find("%f[%w_]" .. r.wt.expr:match("^[%a_][%w_]*") .. "%f[^%w_]")
            if c then to = decl_line(self.doc, l, c); break end
          end
        end
        if to then self.doc:set_selection(to, 1); self:scroll_to_line(to, true, true) end
      end
      core.redraw = true
      return true
    end
  end
  if button == "left" and in_label(self, x, y) then    -- the next breakpoint after the caret (round to the first)
    local ls = B.lines(self.doc.filename)
    local cur = self.doc:get_selection()
    local to = ls[1]
    for _, l in ipairs(ls) do if l > cur then to = l; break end end
    if to then
      self.doc:set_selection(to, 1)
      self:scroll_to_line(to, true, true)
    end
    return true
  end
  if button == "left" and self.doc and self.doc.filename and getmetatable(self) == DocView
     and x < self.position.x + self:get_gutter_width() and y >= self.position.y then
    local line = self:resolve_screen_position(x, y)
    if line then B.toggle(self.doc.filename, line); warn_at_load(self.doc, line); return true end
  end
  return pressed0(self, button, x, y, clicks)
end
command.add(function()
  local v = core.active_view
  return v and v.doc and v.doc.filename and (v:is(NodeGraphView) or getmetatable(v) == DocView)
end, {
  ["nodegraph:toggle-breakpoint"] = function()
    local v = core.active_view
    local line
    if v:is(NodeGraphView) then line = v.selected and v.selected.kind ~= "expr" and v.selected.line
    else line = v.doc:get_selection() end
    if line then
      B.toggle(v.doc.filename, line)
      if v:is(NodeGraphView) then
        if v.selected and B.has(v.doc.filename, line) and v.at_load(v.selected) then
          v:flash(v.is_root(v.doc.filename) and v.AT_BOOT_NOTE or v.AT_LOAD_NOTE)
        elseif v.selected and B.has(v.doc.filename, line) and v:at_setup(v.selected) then v:flash(v.AT_SETUP_NOTE) end
      else warn_at_load(v.doc, line) end
    end
  end,
})
-- stopped at a breakpoint: F5 continue, F10 step over, F11 step into,
-- shift+F11 step out (only then: otherwise these keys do what they did)
local function stopped() return B.where() ~= nil end
local function step(mode) return function() local hs = rawget(_G, "host_break_step"); if hs then hs(mode) end end end
command.add(stopped, {
  ["nodegraph:continue"] = step("continue"),
  ["nodegraph:step-over"] = step("over"),
  ["nodegraph:step-into"] = step("in"),
  ["nodegraph:step-out"] = step("out"),
})
core.add_thread(function()
  require("core.keymap").add { ["f9"] = "nodegraph:toggle-breakpoint", ["f5"] = "nodegraph:continue",
    ["f10"] = "nodegraph:step-over", ["f11"] = "nodegraph:step-into", ["shift+f11"] = "nodegraph:step-out" }
end)

-- the world stopped at a breakpoint: show where (a graph of that file: it
-- glides there by itself; else its text, at that line; opened if need be)
core.add_thread(function()
  local seen
  while true do
    local file, line, n = B.where()
    if n and n ~= seen then
      seen = n
      local graph, text
      local function walk(node)
        if node.type == "leaf" then
          for _, v in ipairs(node.views) do
            if v.doc and v.doc.filename and B.same(v.doc.filename, file) then
              if v:is(NodeGraphView) then graph = graph or { node, v }
              elseif getmetatable(v) == DocView then text = text or { node, v } end
            end
          end
        else walk(node.a); walk(node.b) end
      end
      walk(core.root_view.root_node)
      local at = graph or text
      if at then at[1]:set_active_view(at[2]) end
      if not graph then
        local v = text and text[2]
        if not v then
          local ok, doc = pcall(core.open_doc, file)
          if ok and doc then v = core.root_view:open_doc(doc) end
        end
        if v then
          v.doc:set_selection(line, 1)
          if v.scroll_to_line then v:scroll_to_line(line, true, true) end
        end
      end
      core.redraw = true
    elseif not n then seen = nil end
    coroutine.yield(0.1)
  end
end)

return M

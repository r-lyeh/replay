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
local moved0 = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)          -- over the gutter: the arrow (a click there: a breakpoint)
  moved0(self, x, y, ...)
  if getmetatable(self) == DocView and self.doc and self.doc.filename then
    if x < self.position.x + self:get_gutter_width() and y >= self.position.y then self.cursor = "arrow" end
  end
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
  elseif not inner then core.status_view:show_message("!", style.accent, NodeGraphView.AT_LOAD_NOTE)
  elseif NodeGraphView.factories(ast)[inner.pos] then core.status_view:show_message("i", style.text, NodeGraphView.AT_SETUP_NOTE) end
end
function DocView:on_mouse_pressed(button, x, y, clicks)
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

-- tabflip.lua - a tab that shows a file two ways (Replay, ours): its text,
-- and another view of it (a Lua file's node graph, a markdown file
-- rendered). A small icon left of the tab's name flips it in place; the
-- other view is kept (scroll, pan, zoom) for the next flip. Hovering the tab
-- says so. Any plugin can add a kind:
--
--   local tabflip = require "plugins.tabflip"
--   tabflip.register {
--     key = "markdown",                  -- (registering the same key again replaces it)
--     text = function(view) end,         -- a text tab of this kind? (a DocView of a .md)
--     alt = function(view) end,          -- the other view of this kind?
--     to_alt = function(view) end,       -- the other view for this text tab (new)
--     to_text = function(view) end,      -- a text tab for this other view (new: a DocView)
--     icon = function(x, y, s, color) end,  -- the other view's glyph (s px square)
--     tip = "Show as preview",           -- the icon's tooltip on a text tab
--     menu = "Toggle preview / text",    -- the tab menu's item (nodegraph/init.lua)
--     after = function(old, new) end,    -- (optional) after a flip
--     name = "preview",                  -- (optional) its name in menus (default: key)
--     first = true,                      -- (optional) asked before the others (a .atlas.lua
--   }                                    --  is an atlas, not a node graph)
--
-- tabflip.kind_of(view) -> kind, is_alt; tabflip.can_flip(view);
-- tabflip.flip(node, view) -> the view now shown.
-- Beside: the pane right of a tab's (left of it, for the right one; made by
-- splitting when there is none) gets
--   tabflip.open_beside(node, view)  its other view (the graph, the preview;
--                                    the text, for those), else a copy of it
--   tabflip.copy_beside(node, view)  a copy (the same file, its own scroll)
--   tabflip.move_beside(node, view)  the tab itself
-- (the tab's menu, the text's menu, CTRL+\: plugins/tabmenu.lua)
local core = require "core"
local style = require "core.style"
local Node = require "core.node"

local M = { kinds = {} }

function M.register(kind)
  for i, k in ipairs(M.kinds) do
    if k.key == kind.key then M.kinds[i] = kind; core.redraw = true return kind end
  end
  if kind.first then table.insert(M.kinds, 1, kind) else M.kinds[#M.kinds + 1] = kind end
  core.redraw = true
  return kind
end

function M.kind_of(view)
  if not view then return nil end
  for _, k in ipairs(M.kinds) do
    local ok, alt = pcall(k.alt, view)
    if ok and alt then return k, true end
    local ok2, text = pcall(k.text, view)
    if ok2 and text then return k, false end
  end
end
function M.can_flip(view) return M.kind_of(view) ~= nil end

function M.flip(node, view)
  local k, is_alt = M.kind_of(view)
  if not k then return end
  local idx = node:get_view_idx(view)
  if not idx then return end
  local other = view.flipped
  if not other then other = is_alt and k.to_text(view) or k.to_alt(view) end
  if not other then return end
  other.flipped, view.flipped = view, nil
  node.views[idx] = other
  node:set_active_view(other)
  core.set_active_view(other)
  if k.after then k.after(view, other) end
  return other
end

-- beside: the pane next to a tab's -------------------------------------
local function parent_of(n, node, p)
  if n == node then return p end
  if n.type ~= "leaf" then return parent_of(n.a, node, n) or parent_of(n.b, node, n) end
end
local function edge_leaf(n, right)                 -- (the leaf of n nearest the split: its first, or last)
  while n.type ~= "leaf" do n = right and n.b or n.a end
  return n
end
function M.beside_node(node)                       -- the pane right of node's (or left, for a right one), or nil
  local p = parent_of(core.root_view.root_node, node)
  if not (p and p.type == "hsplit") then return nil end
  local b = p.a == node and edge_leaf(p.b, false) or edge_leaf(p.a, true)
  if not b.locked then return b end
end
function M.place_beside(node, view)                -- view in a tab of the pane beside node's (made if none)
  local b = M.beside_node(node)
  if b then b:add_view(view)
  else
    if node.locked then node = core.root_view.root_node:get_child_overlapping_point(0, 0) end
    node:split("right", view)
  end
  core.set_active_view(view)
  return view
end
function M.copy(view)                              -- a new tab showing what view shows, or nil
  local DocView = require "core.docview"
  local nv
  if getmetatable(view) == DocView then
    nv = DocView(view.doc)
    nv.scroll.x, nv.scroll.y, nv.scroll.to.x, nv.scroll.to.y = view.scroll.x, view.scroll.y, view.scroll.to.x, view.scroll.to.y
    return nv
  end
  local k, is_alt = M.kind_of(view)
  if k and is_alt then                             -- (the graph, the preview: a new one of its text)
    local ok, t = pcall(k.to_text, view)
    if ok and t then ok, nv = pcall(k.to_alt, t) end
    if ok and nv then if k.after then pcall(k.after, t, nv) end return nv end
  end
  if view.filename and view.get_state then         -- (a plugin's view: made from its state again)
    local ok, v = pcall(getmetatable(view), view:get_state())
    if ok then return v end
  end
end
local function node_of(node, view)                -- (a node split since: the leaf the view is in now)
  return view and core.root_view.root_node:get_node_for_view(view) or node
end
function M.open_beside(node, view)
  node = node_of(node, view)
  local k, is_alt = M.kind_of(view)
  local other
  if k then
    other = is_alt and k.to_text(view) or k.to_alt(view)
    if other and k.after then k.after(view, other) end
  else other = M.copy(view) end
  if other then return M.place_beside(node, other) end
end
function M.copy_beside(node, view)
  node = node_of(node, view)
  local nv = M.copy(view)
  if nv then return M.place_beside(node, nv) end
end
function M.move_beside(node, view)
  node = node_of(node, view)
  local idx = node:get_view_idx(view)
  if not idx then return end
  local b = M.beside_node(node)
  if not b then                                    -- (none: a new pane, if this one keeps a tab)
    if #node.views < 2 then return end
    table.remove(node.views, idx)
    node:set_active_view(node.views[math.min(idx, #node.views)])
    node:split("right", view)
  else
    b:add_view(view)
    table.remove(node.views, idx)
    if #node.views > 0 then node.active_view = node.views[math.min(idx, #node.views)]
    else                                           -- (its pane emptied: it goes, as when its last tab closes)
      local parent = node:get_parent_node(core.root_view.root_node)
      local other = parent[parent.a == node and "b" or "a"]
      if other:get_locked_size() then node:add_view(require("core.emptyview")())
      else parent:consume(other) end
    end
  end
  core.set_active_view(view)
  return view
end

-- the text glyph (shown on the other view's tab: back to text): three lines
function M.text_icon(x, y, s, c)
  local t = math.max(1, math.floor(s / 7))
  for i = 0, 2 do
    renderer.draw_rect(x, y + math.floor(s * (0.2 + 0.3 * i)), math.floor(s * (i == 2 and 0.6 or 1)), t, c)
  end
end

-- the icon, left of the tab's name (lite's Node:draw_tabs calls Node.tab_left)
function M.icon_rect(node, i)
  local x, y, _, h = node:get_tab_rect(i)
  local s = math.floor(style.font:get_height() * 0.7)
  return x + style.padding.y, y + math.floor((h - s) / 2), s
end
function Node.tab_left(node, view, i)
  local k, is_alt = M.kind_of(view)
  if not k then return 0 end
  local x, y, s = M.icon_rect(node, i)
  local c = node.hovered_flip == i and style.text or style.dim
  if is_alt then M.text_icon(x, y, s, c) else k.icon(x, y, s, c) end
  return s + style.padding.y
end
local tab_mouse_moved = Node.tab_mouse_moved
function Node:tab_mouse_moved(px, py)
  tab_mouse_moved(self, px, py)
  self.hovered_flip = 0
  local idx = self:get_tab_overlapping_point(px, py)
  if idx and M.can_flip(self.views[idx]) then
    local x, y, s = M.icon_rect(self, idx)
    if px >= x - 2 and px < x + s + 2 and py >= y - 2 and py < y + s + 2 then self.hovered_flip = idx end
  end
end
function M.on_icon(node, idx, x, y)                -- is (x, y) on that tab's icon?
  if not (node and idx and M.can_flip(node.views[idx])) then return false end
  local ix, iy, s = M.icon_rect(node, idx)
  return x >= ix - 2 and x < ix + s + 2 and y >= iy - 2 and y < iy + s + 2
end

-- a click on the icon flips the tab
core.add_thread(function()
  local RootView = require "core.rootview"
  local on_mouse_pressed = RootView.on_mouse_pressed
  function RootView:on_mouse_pressed(button, x, y, clicks)
    local menu = package.loaded["plugins.contextmenu"]
    if button == "left" and not (menu and menu.show_context_menu) and not self.root_node:get_divider_overlapping_point(x, y) then
      local node = self.root_node:get_child_overlapping_point(x, y)
      local idx = node and node.type == "leaf" and node:get_tab_overlapping_point(x, y)
      if idx and M.on_icon(node, idx, x, y) then
        M.flip(node, node.views[idx])
        return true
      end
    end
    return on_mouse_pressed(self, button, x, y, clicks)
  end
end)

-- a tooltip on tabs that flip: what the icon and a right-click do
core.add_thread(function()
  local RootView = require "core.rootview"
  local draw = RootView.draw
  local hover = {}                                 -- { view, since }
  function RootView:draw(...)
    draw(self, ...)
    local mx, my = self.mouse.x, self.mouse.y
    if mx <= 0 and my <= 0 then hover.view = nil; return end   -- (no mouse over lite yet: its (0, 0) is the first tab)
    local node = self.root_node:get_child_overlapping_point(mx, my)
    local idx = node and node.type == "leaf" and node:get_tab_overlapping_point(mx, my)
    local v = idx and node.views[idx]
    local k, is_alt = M.kind_of(v)
    local menu = package.loaded["plugins.contextmenu"]
    if not k or (menu and menu.show_context_menu) then hover.view = nil; return end
    if hover.view ~= v then hover.view, hover.since = v, system.get_time() end
    local wait = 0.5 - (system.get_time() - hover.since)
    if wait > 0 then core.redraw = true; return end  -- keep drawing until it shows
    local text = (is_alt and "Show as text" or k.tip) .. ": the icon   RMB: the tab's menu"
    local f, p = style.font, style.padding.x / 2
    local w, h = f:get_width(text) + 2 * p, f:get_height() + p
    local x, y = mx + 12 * SCALE, my + 18 * SCALE
    if x + w > self.size.x then x = self.size.x - w end
    renderer.draw_rect(x - 1, y - 1, w + 2, h + 2, style.divider)
    renderer.draw_rect(x, y, w, h, style.background3 or style.background2)
    renderer.draw_text(f, text, x + p, y + p / 2, style.text)
  end
end)

return M

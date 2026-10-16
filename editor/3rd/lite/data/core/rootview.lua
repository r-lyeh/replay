local core = require "core"
local common = require "core.common"
local style = require "core.style"
local keymap = require "core.keymap"
local Object = require "core.object"
local View = require "core.view"
local DocView = require "core.docview"
local Node = require "core.node"
local config = require "core.config"







local RootView = View:extend()

function RootView:new()
  RootView.super.new(self)
  self.root_node = Node()
  self.deferred_draws = {}
  self.mouse = { x = 0, y = 0 }
end


function RootView:defer_draw(fn, ...)
  table.insert(self.deferred_draws, 1, { fn = fn, ... })
end


function RootView:get_active_node()
  return self.root_node:get_node_for_view(core.active_view)
end


function RootView:open_doc(doc)
  local node = self:get_active_node()
  if node.locked and core.last_active_view then
    core.set_active_view(core.last_active_view)
    node = self:get_active_node()
  end
  assert(not node.locked, "Cannot open doc on locked node")
  for i, view in ipairs(node.views) do
    if view.doc == doc then
      node:set_active_view(node.views[i])
      return view
    end
  end
  local view = DocView(doc)
  node:add_view(view)
  self.root_node:update_layout()
  view:scroll_to_line(view.doc:get_selection(), true, true)
  return view
end


function RootView:on_mouse_pressed(button, x, y, clicks)
  local div = self.root_node:get_divider_overlapping_point(x, y)
  if div ~= self.hovered_divider then self.hovered_divider = div; core.redraw = true end --< Replay: drawn lighter
  if div then
    if clicks == 2 then                            --< Replay: a double-click puts it back (its default, else half way)
      div.divider = div.default_divider or 0.5
      self.dragged_divider = nil
      core.redraw = true
      return
    end
    self.dragged_divider = div
    return
  end
  local node = self.root_node:get_child_overlapping_point(x, y)
  local idx = node:get_tab_overlapping_point(x, y)
  if idx then
    node:set_active_view(node.views[idx])
    if button == "right" or button == "middle" or node.hovered_close == idx then --< @rlyeh middle>right; close button (lite-xl)
      node:close_active_view(self.root_node)
    elseif button == "left" then                   --< Replay: a tab can be dragged to another pane (or an edge: a new one)
      self.tab_drag = { node = node, view = node.views[idx], x = x, y = y, moved = false }
    end
  else
    core.set_active_view(node.active_view)
    node.active_view:on_mouse_pressed(button, x, y, clicks)
  end
end


function RootView:on_mouse_released(...)
  if self.dragged_divider then
    self.dragged_divider = nil
  end
  local td = self.tab_drag                         --< Replay: a tab dropped
  self.tab_drag = nil
  if td and td.moved then
    self:drop_tab(td)
    return
  end
  self.root_node:on_mouse_released(...)
end


--< Replay: where a dragged tab would land: { node, dir } (dir: nil = in that
-- pane, among its tabs; "left" / "right" / "up" / "down" = a new pane there,
-- when dropped near that edge, the outer fifth)
function RootView:tab_target(x, y)
  local node = self.root_node:get_child_overlapping_point(x, y)
  if not node or node.locked then return nil end
  local px, py, w, h = node.position.x, node.position.y, node.size.x, node.size.y
  local fx, fy = (x - px) / w, (y - py) / h
  local _, _, _, th = node:get_tab_rect(1)
  local dir
  if y > py + th then
    if fx < 0.2 then dir = "left" elseif fx > 0.8 then dir = "right"
    elseif fy > 0.8 then dir = "down" elseif fy < 0.2 then dir = "up" end
  end
  return { node = node, dir = dir }
end

-- take view out of node (the pane goes when it was its last tab, as when closing it)
local function take_out(root, node, view)
  local idx = node:get_view_idx(view)
  if not idx then return end
  if #node.views > 1 then
    table.remove(node.views, idx)
    if node.active_view == view then node:set_active_view(node.views[idx] or node.views[#node.views]) end
    return
  end
  local parent = node:get_parent_node(root)
  if not parent then return end
  local is_a = (parent.a == node)
  local other = parent[is_a and "b" or "a"]
  if other:get_locked_size() then
    node.views = {}
    node:add_view(Node.EmptyView())
  else
    parent:consume(other)
  end
end

function RootView:drop_tab(td)
  local t = self:tab_target(self.mouse.x, self.mouse.y)
  if not t then return end
  local src, view, dst = td.node, td.view, t.node
  if t.dir then
    if src == dst and #src.views == 1 then return end   -- (its only tab, beside itself: nothing to do)
    local child = dst:split(t.dir, view)
    if src == dst then take_out(self.root_node, child, view)   -- (the split moved its tabs into child)
    else take_out(self.root_node, src, view) end
  elseif src == dst then                           -- the same pane: a new place among its tabs
    local idx = src:get_tab_overlapping_point(self.mouse.x, self.mouse.y)
    local from = src:get_view_idx(view)
    if idx and from and idx ~= from then
      table.remove(src.views, from)
      table.insert(src.views, math.min(idx, #src.views + 1), view)
    end
    src:set_active_view(view)
    return
  else
    dst:add_view(view)
    take_out(self.root_node, src, view)
  end
  local n = self.root_node:get_node_for_view(view)
  if n then n:set_active_view(view) end
  core.set_active_view(view)
end


function RootView:on_mouse_moved(x, y, dx, dy)
  local td = self.tab_drag                         --< Replay: a tab being dragged
  if td then
    if math.abs(x - td.x) + math.abs(y - td.y) > 8 then td.moved = true end
    if td.moved then
      self.mouse.x, self.mouse.y = x, y
      system.set_cursor("hand")
      core.redraw = true
      return
    end
  end
  if self.dragged_divider then
    local node = self.dragged_divider
    if node.type == "hsplit" then
      node.divider = node.divider + dx / node.size.x
    else
      node.divider = node.divider + dy / node.size.y
    end
    node.divider = common.clamp(node.divider, 0.01, 0.99)
    return
  end

  self.mouse.x, self.mouse.y = x, y
  self.root_node:on_mouse_moved(x, y, dx, dy)

  local node = self.root_node:get_child_overlapping_point(x, y)
  local div = self.root_node:get_divider_overlapping_point(x, y)
  if div ~= self.hovered_divider then self.hovered_divider = div; core.redraw = true end --< Replay: drawn lighter
  if div then
    system.set_cursor(div.type == "hsplit" and "sizeh" or "sizev")
  elseif node:get_tab_overlapping_point(x, y) then
    system.set_cursor("arrow")
  else
    system.set_cursor(node.active_view.cursor)
  end
end


function RootView:on_mouse_wheel(...)
  local x, y = self.mouse.x, self.mouse.y
  local node = self.root_node:get_child_overlapping_point(x, y)
  node.active_view:on_mouse_wheel(...)
end


function RootView:on_text_input(...)
  core.active_view:on_text_input(...)
end


function RootView:update()
  common.copy_position_and_size(self.root_node, self)
  self.root_node:update()
  self.root_node:update_layout()
end


function RootView:draw()
  self.root_node:draw()
  local td = self.tab_drag                         --< Replay: where a dragged tab would land
  if td and td.moved then
    local t = self:tab_target(self.mouse.x, self.mouse.y)
    if t then
      local n = t.node
      local x, y, w, h = n.position.x, n.position.y, n.size.x, n.size.y
      if t.dir == "left" then w = w / 2 elseif t.dir == "right" then x, w = x + w / 2, w / 2
      elseif t.dir == "up" then h = h / 2 elseif t.dir == "down" then y, h = y + h / 2, h / 2 end
      local c = style.pane_divider_drag or { 0x3f, 0xb8, 0xd8, 255 }
      renderer.draw_rect(x, y, w, h, { c[1], c[2], c[3], 40 })
      local b = math.max(1, math.floor(2 * SCALE))
      renderer.draw_rect(x, y, w, b, c); renderer.draw_rect(x, y + h - b, w, b, c)
      renderer.draw_rect(x, y, b, h, c); renderer.draw_rect(x + w - b, y, b, h, c)
    end
    local name = td.view:get_name()                -- the tab's name under the mouse
    local f = style.font
    local tw, th = f:get_width(name) + style.padding.x * 2, f:get_height() + style.padding.y
    renderer.draw_rect(self.mouse.x + 12, self.mouse.y + 8, tw, th, style.background2)
    renderer.draw_text(f, name, self.mouse.x + 12 + style.padding.x, self.mouse.y + 8 + style.padding.y / 2, style.text)
  end
  while #self.deferred_draws > 0 do
    local t = table.remove(self.deferred_draws)
    t.fn(table.unpack(t))
  end
end


return RootView

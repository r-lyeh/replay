local core = require "core"
local common = require "core.common"
local style = require "core.style"
local keymap = require "core.keymap"
local Object = require "core.object"
local View = require "core.view"
local DocView = require "core.docview"
local config = require "core.config"


local EmptyView = View:extend()

local function draw_text(x, y, color)
  local th = style.big_font:get_height()
  local dh = th + style.padding.y * 2
  x = renderer.draw_text(style.big_font, "edit", x, y + (dh - th) / 2, color) --< @r-lyeh lite>edit
  x = x + style.padding.x
  renderer.draw_rect(x, y, math.ceil(1 * SCALE), dh, color)
  local lines = {
    { fmt = "%s to run a command", cmd = "core:find-command" },
    { fmt = "%s to open a file from the project", cmd = "core:find-file" },
  }
  th = style.font:get_height()
  y = y + (dh - th * 2 - style.padding.y) / 2
  local w = 0
  for _, line in ipairs(lines) do
    local text = string.format(line.fmt, keymap.get_binding(line.cmd))
    w = math.max(w, renderer.draw_text(style.font, text, x + style.padding.x, y, color))
    y = y + th + style.padding.y
  end
  return w, dh
end

function EmptyView:draw()
  self:draw_background(style.background)
  local w, h = draw_text(0, 0, { 0, 0, 0, 0 })
  local x = self.position.x + math.max(style.padding.x, (self.size.x - w) / 2)
  local y = self.position.y + (self.size.y - h) / 2
  draw_text(x, y, style.dim)
end


local Node = Object:extend()

function Node:new(type)
  self.type = type or "leaf"
  self.position = { x = 0, y = 0 }
  self.size = { x = 0, y = 0 }
  self.views = {}
  self.divider = 0.5
  if self.type == "leaf" then
    self:add_view(EmptyView())
  end
  self.hovered_close = 0
end


function Node:propagate(fn, ...)
  self.a[fn](self.a, ...)
  self.b[fn](self.b, ...)
end


function Node:on_mouse_moved(x, y, ...)
  self.hovered_tab = self:get_tab_overlapping_point(x, y)
  if self.type == "leaf" then
    self:tab_mouse_moved(x, y)
    self.active_view:on_mouse_moved(x, y, ...)
  else
    self:propagate("on_mouse_moved", x, y, ...)
  end
end


function Node:on_mouse_released(...)
  if self.type == "leaf" then
    self.active_view:on_mouse_released(...)
  else
    self:propagate("on_mouse_released", ...)
  end
end


function Node:consume(node)
  for k, _ in pairs(self) do self[k] = nil end
  for k, v in pairs(node) do self[k] = v   end
end


local type_map = { up="vsplit", down="vsplit", left="hsplit", right="hsplit" }

function Node:split(dir, view, locked)
  assert(self.type == "leaf", "Tried to split non-leaf node")
  local type = assert(type_map[dir], "Invalid direction")
  local last_active = core.active_view
  local child = Node()
  child:consume(self)
  self:consume(Node(type))
  self.a = child
  self.b = Node()
  if view then self.b:add_view(view) end
  if locked then
    self.b.locked = locked
    core.set_active_view(last_active)
  end
  if dir == "up" or dir == "left" then
    self.a, self.b = self.b, self.a
  end
  return child
end


function Node:close_active_view(root)
  local do_close = function()
    if #self.views > 1 then
      local idx = self:get_view_idx(self.active_view)
      table.remove(self.views, idx)
      self:set_active_view(self.views[idx] or self.views[#self.views])
    else
      local parent = self:get_parent_node(root)
      local is_a = (parent.a == self)
      local other = parent[is_a and "b" or "a"]
      if other:get_locked_size() then
        self.views = {}
        self:add_view(EmptyView())
      else
        parent:consume(other)
        local p = parent
        while p.type ~= "leaf" do
          p = p[is_a and "a" or "b"]
        end
        p:set_active_view(p.active_view)
      end
    end
    core.last_active_view = nil
  end
  self.active_view:try_close(do_close)
end


function Node:add_view(view)
  assert(self.type == "leaf", "Tried to add view to non-leaf node")
  assert(not self.locked, "Tried to add view to locked node")
  if self.views[1] and self.views[1]:is(EmptyView) then
    table.remove(self.views)
  end
  table.insert(self.views, view)
  self:set_active_view(view)
end


function Node:set_active_view(view)
  assert(self.type == "leaf", "Tried to set active view on non-leaf node")
  self.active_view = view
  core.set_active_view(view)
end


function Node:get_view_idx(view)
  for i, v in ipairs(self.views) do
    if v == view then return i end
  end
end


function Node:get_node_for_view(view)
  for _, v in ipairs(self.views) do
    if v == view then return self end
  end
  if self.type ~= "leaf" then
    return self.a:get_node_for_view(view) or self.b:get_node_for_view(view)
  end
end


function Node:get_parent_node(root)
  if root.a == self or root.b == self then
    return root
  elseif root.type ~= "leaf" then
    return self:get_parent_node(root.a) or self:get_parent_node(root.b)
  end
end


function Node:get_children(t)
  t = t or {}
  for _, view in ipairs(self.views) do
    table.insert(t, view)
  end
  if self.a then self.a:get_children(t) end
  if self.b then self.b:get_children(t) end
  return t
end


Node.EmptyView = EmptyView                         --< Replay: (rootview's tab drops)


-- a split whose divider can be dragged: neither side has a locked size --< Replay
-- (the status bar, side panels: they keep theirs, dragging would do nothing)
function Node:resizable()
  return self.type ~= "leaf" and not self.a:get_locked_size() and not self.b:get_locked_size()
end


function Node:get_divider_overlapping_point(px, py)
  if self.type ~= "leaf" then
    local p = 6
    local x, y, w, h = self:get_divider_rect()
    x, y = x - p, y - p
    w, h = w + p * 2, h + p * 2
    if self:resizable() and px > x and py > y and px < x + w and py < y + h then --< Replay: resizable() only
      return self
    end
    return self.a:get_divider_overlapping_point(px, py)
        or self.b:get_divider_overlapping_point(px, py)
  end
end


-- tabs: when there are several views, or always (config.always_show_tabs) --< Replay
-- except on locked nodes (side panels)
function Node:shows_tabs()
  return config.tabs_allowed and (#self.views > 1 or (config.always_show_tabs and not self.locked
    and not (self.views[1] and self.views[1]:is(EmptyView))))
end


function Node:get_tab_overlapping_point(px, py)
  if not self:shows_tabs() then return nil end --< Replay: was #self.views == 1
  local x, y, w, h = self:get_tab_rect(1)
  if px >= x and py >= y and px < x + w * #self.views and py < y + h then
    return math.floor((px - x) / w) + 1
  end
end


-- tab close buttons (from lite-xl 1.16.2: ca6d1843, 4cda8fc1, e861ea1d),
-- drawn as a small cross since our icon font has no close glyph
local function close_button_location(x, w)
  local cw = math.floor(style.font:get_height() * 0.6)
  local pad = style.padding.y
  return x + w - pad - cw, cw, pad
end


local function draw_cross(cx, cy, size, color)
  local t = math.max(1, math.floor(size / 6))      -- stroke thickness
  for i = 0, size - t do
    renderer.draw_rect(cx + i, cy + i, t, t, color)
    renderer.draw_rect(cx + size - t - i, cy + i, t, t, color)
  end
end


function Node:tab_mouse_moved(px, py)
  local tab_index = self:get_tab_overlapping_point(px, py)
  if tab_index then
    local x, y, w, h = self:get_tab_rect(tab_index)
    local cx, cw = close_button_location(x, w)
    if px >= cx and px < cx + cw and py >= y and py < y + h then
      self.hovered_close = tab_index
      return
    end
  end
  self.hovered_close = 0
end


function Node:get_child_overlapping_point(x, y)
  local child
  if self.type == "leaf" then
    return self
  elseif self.type == "hsplit" then
    child = (x < self.b.position.x) and self.a or self.b
  elseif self.type == "vsplit" then
    child = (y < self.b.position.y) and self.a or self.b
  end
  return child:get_child_overlapping_point(x, y)
end


function Node:get_tab_rect(idx)
  if not config.tabs_allowed then return 0,0,0,0 end --< https://github.com/rxi/lite/issues/191
  local tw = math.min(style.tab_width, math.ceil(self.size.x / #self.views))
  local h = style.font:get_height() + style.padding.y * 2
  return self.position.x + (idx-1) * tw, self.position.y, tw, h
end


function Node:get_divider_rect()
  local x, y = self.position.x, self.position.y
  if self.type == "hsplit" then
    return x + self.a.size.x, y, style.divider_size, self.size.y
  elseif self.type == "vsplit" then
    return x, y + self.a.size.y, self.size.x, style.divider_size
  end
end


function Node:get_locked_size()
  if self.type == "leaf" then
    if self.locked then
      local size = self.active_view.size
      return size.x, size.y
    end
  else
    local x1, y1 = self.a:get_locked_size()
    local x2, y2 = self.b:get_locked_size()
    if x1 and x2 then
      local dsx = (x1 < 1 or x2 < 1) and 0 or style.divider_size
      local dsy = (y1 < 1 or y2 < 1) and 0 or style.divider_size
      return x1 + x2 + dsx, y1 + y2 + dsy
    end
  end
end




-- calculating the sizes is the same for hsplits and vsplits, except the x/y
-- axis are swapped; this function lets us use the same code for both
local function calc_split_sizes(self, x, y, x1, x2)
  local n
  local ds = (x1 and x1 < 1 or x2 and x2 < 1) and 0 or style.divider_size
  if x1 then
    n = x1 + ds
  elseif x2 then
    n = self.size[x] - x2
  else
    n = math.floor(self.size[x] * self.divider)
  end
  self.a.position[x] = self.position[x]
  self.a.position[y] = self.position[y]
  self.a.size[x] = n - ds
  self.a.size[y] = self.size[y]
  self.b.position[x] = self.position[x] + n
  self.b.position[y] = self.position[y]
  self.b.size[x] = self.size[x] - n
  self.b.size[y] = self.size[y]
end


function Node:update_layout()
  if self.type == "leaf" then
    local av = self.active_view
    if self:shows_tabs() then --< Replay: was #self.views > 1
      local _, _, _, th = self:get_tab_rect(1)
      av.position.x, av.position.y = self.position.x, self.position.y + th
      av.size.x, av.size.y = self.size.x, self.size.y - th
    else
      common.copy_position_and_size(av, self)
    end
  else
    local x1, y1 = self.a:get_locked_size()
    local x2, y2 = self.b:get_locked_size()
    if self.type == "hsplit" then
      calc_split_sizes(self, "x", "y", x1, x2)
    elseif self.type == "vsplit" then
      calc_split_sizes(self, "y", "x", y1, y2)
    end
    self.a:update_layout()
    self.b:update_layout()
  end
end


function Node:update()
  if self.type == "leaf" then
    for _, view in ipairs(self.views) do
      view:update()
    end
  else
    self.a:update()
    self.b:update()
  end
end


function Node:draw_tabs()
  local x, y, _, h = self:get_tab_rect(1)
  local ds = style.divider_size
  core.push_clip_rect(x, y, self.size.x, h)
  renderer.draw_rect(x, y, self.size.x, h, style.background2)
  renderer.draw_rect(x, y + h - ds, self.size.x, ds, style.divider)

  for i, view in ipairs(self.views) do
    local x, y, w, h = self:get_tab_rect(i)
    local text = view:get_name()
    local color = style.dim
    if view == self.active_view then
      color = style.text
      renderer.draw_rect(x, y, w, h, lite_bg(style.background)) --< Replay
      renderer.draw_rect(x + w, y, ds, h, style.divider)
      renderer.draw_rect(x - ds, y, ds, h, style.divider)
    end
    local cx, cw, cspace = close_button_location(x, w)
    if view == self.active_view or i == self.hovered_tab then
      local close_color = self.hovered_close == i and style.text or style.dim
      draw_cross(cx, y + math.floor((h - cw) / 2), cw, close_color)
    end
    if i == self.hovered_tab then
      color = style.text
    end
    local lw = Node.tab_left and Node.tab_left(self, view, i, x, y, w, h) or 0   --< Replay: something left of the name (the node graph's flip icon)
    core.push_clip_rect(x + lw, y, cx - x - lw - cspace, h)
    x, w = x + lw + style.padding.x, w - lw - style.padding.x * 2
    local align = style.font:get_width(text) > w and "left" or "center"
    common.draw_text(style.font, color, text, align, x, y, w, h)
    core.pop_clip_rect()
  end

  core.pop_clip_rect()
end


function Node:draw()
  if self.type == "leaf" then
    if self:shows_tabs() then --< https://github.com/rxi/lite/issues/191; Replay: shows_tabs()
      self:draw_tabs()
    end
    local pos, size = self.active_view.position, self.active_view.size
    core.push_clip_rect(pos.x, pos.y, size.x + pos.x % 1, size.y + pos.y % 1)
    self.active_view:draw()
    core.pop_clip_rect()
  else
    local x, y, w, h = self:get_divider_rect()
    renderer.draw_rect(x, y, w, h, style.divider)
    self:propagate("draw")
    --< Replay: a split that can be dragged gets a line of its own, over its
    -- edges (two graphs side by side: their grids would run into each other):
    -- dark teal, lighter under the mouse, aqua while dragged. The others (the
    -- status bar's, side panels') stay as they were: thin, dim.
    if self:resizable() then
      local rv = core.root_view
      local c = rv.dragged_divider == self and (style.pane_divider_drag or { 0x3f, 0xb8, 0xd8, 255 })
             or rv.hovered_divider == self and (style.pane_divider_hover or { 0x3a, 0x7d, 0x90, 255 })
             or (style.pane_divider or { 0x2a, 0x3c, 0x44, 255 })
      local t = math.max(1, math.floor(SCALE + 0.5))
      if self.type == "hsplit" then x, w = x - t, w + 2 * t else y, h = y - t, h + 2 * t end
      renderer.draw_rect(x, y, w, h, c)
    end
  end
end

return Node

-- graph.lua - canvas.GraphView: a node editor on a canvas (plugins/canvas),
-- drawn like the node graph. Extend it for a material editor, an animation
-- graph, a dialogue tree: give it the kinds of node, it does the rest.
--
--   MyView.kinds = {                       -- what nodes there can be
--     mix = { title = "Mix", color = "#3c3c83",
--             ins = { { "a", "color" }, { "b", "color" }, { "t", "float" } },
--             outs = { { "out", "color" } } },
--     ...
--   }
--   MyView.types = { color = "#c7c729" }   -- a pin type's colour (else the
--                                          -- canvas's, else grey)
--   self.graph = {                         -- the data (plain: save it as is)
--     nodes = { { id = 1, kind = "mix", x = 0, y = 0, data = {...} }, ... },
--     links = { { from = 1, out = "out", to = 2, input = "a" }, ... },
--   }
-- A node's pins come from its kind (change a kind: its nodes follow); links
-- name their pins. An output feeds any number of inputs, an input reads one.
--
-- The mouse: LMB selects (CTRL: adds / removes), drags the selection, drags
-- a wire from a pin to a pin of the same type (self:can_connect) - from a
-- connected input: picks its wire up; drop it on nothing: gone. DELETE
-- removes the selection. RMB: the menu (add a node there: type to find it;
-- duplicate, delete). Pan / zoom / fit: canvas.View's.
-- Hooks: self:on_change() after any edit (mark it unsaved);
-- self:node_extra(n) -> world height below its pins, drawn by
-- self:draw_node_extra(n, x, y, w, h, z) (screen: a swatch, a value).
local core = require "core"
local keymap = require "core.keymap"
local style = require "core.style"
local CanvasView = require "plugins.canvas.view"
local D = require "plugins.canvas.draw"
local T = require "plugins.canvas.theme"
local C, rgb, alpha = T.C, T.rgb, T.alpha

local GraphView = CanvasView:extend()
GraphView.kinds = {}
GraphView.types = {}
GraphView.node_w, GraphView.head_h, GraphView.row_h = 150, 24, 20   -- world units
GraphView.HEAD = rgb"#3c3c83"                       -- a header's colour when its kind has none
GraphView.LOD = 0.3                                -- under this zoom: plain boxes

local function color_of(c) return type(c) == "string" and rgb(c) or c end

function GraphView:new(graph)
  GraphView.super.new(self)
  self.graph = graph or {}
  self.graph.nodes = self.graph.nodes or {}
  self.graph.links = self.graph.links or {}
  self.sel = {}
end

-- the model --------------------------------------------------------------

function GraphView:kind(n) return self.kinds[n.kind] or { title = tostring(n.kind) .. "?", color = C.err, ins = {}, outs = {} } end
function GraphView:node(id)
  for _, n in ipairs(self.graph.nodes) do if n.id == id then return n end end
end
function GraphView:next_id()
  local m = 0
  for _, n in ipairs(self.graph.nodes) do if type(n.id) == "number" and n.id > m then m = n.id end end
  return m + 1
end
local function pin_index(list, name)
  for i, p in ipairs(list or {}) do if p[1] == name then return i end end
end
function GraphView:type_color(t)
  return color_of(self.types[t]) or T.TYPE[t] or C.wire
end
function GraphView:can_connect(out_type, in_type)
  return out_type == in_type or out_type == "any" or in_type == "any"
end

function GraphView:changed()
  self.dirty = true
  core.redraw = true
  self:on_change()
end
function GraphView:on_change() end

function GraphView:add_node(kind, wx, wy, data)
  local n = { id = self:next_id(), kind = kind, x = math.floor(wx), y = math.floor(wy), data = data }
  table.insert(self.graph.nodes, n)
  self.sel = { [n] = true }
  self:changed()
  return n
end

function GraphView:remove_nodes(set)
  local keep, gone = {}, {}
  for _, n in ipairs(self.graph.nodes) do if set[n] then gone[n.id] = true else table.insert(keep, n) end end
  self.graph.nodes = keep
  local links = {}
  for _, l in ipairs(self.graph.links) do if not gone[l.from] and not gone[l.to] then table.insert(links, l) end end
  self.graph.links = links
  self.sel = {}
  self:changed()
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end

function GraphView:duplicate(set)
  local made = {}
  for _, n in ipairs(self.graph.nodes) do
    if set[n] then
      local m = copy(n)
      m.id, m.x, m.y = self:next_id(), n.x + 24, n.y + 24
      table.insert(self.graph.nodes, m)
      made[m] = true
    end
  end
  self.sel = made
  self:changed()
end

function GraphView:link_into(id, input)            -- the link an input reads, and its index
  for i, l in ipairs(self.graph.links) do if l.to == id and l.input == input then return l, i end end
end

function GraphView:connect(from, out, to, input)
  local _, i = self:link_into(to, input)
  if i then table.remove(self.graph.links, i) end  -- (an input reads one wire)
  table.insert(self.graph.links, { from = from, out = out, to = to, input = input })
  self:changed()
end

-- the layout (world units) ----------------------------------------------

function GraphView:node_extra(n) return 0 end
function GraphView:draw_node_extra(n, x, y, w, h, z) end

function GraphView:node_rect(n)
  local k = self:kind(n)
  local rows = #(k.outs or {}) + #(k.ins or {})
  return n.x, n.y, k.w or self.node_w, self.head_h + rows * self.row_h + 6 + self:node_extra(n)
end

function GraphView:pin_xy(n, side, i)              -- world
  local k = self:kind(n)
  local x, y, w = self:node_rect(n)
  local row = side == "out" and i or #(k.outs or {}) + i
  return side == "out" and x + w or x, y + self.head_h + (row - 0.5) * self.row_h
end

function GraphView:bounds()
  local x0, y0, x1, y1
  for _, n in ipairs(self.graph.nodes) do
    local x, y, w, h = self:node_rect(n)
    x0, y0 = math.min(x0 or x, x), math.min(y0 or y, y)
    x1, y1 = math.max(x1 or x + w, x + w), math.max(y1 or y + h, y + h)
  end
  if not x0 then return -200, -150, 400, 300 end
  return x0, y0, x1 - x0, y1 - y0
end
GraphView.zoom_max = 1.5

-- what's under a world point: a pin (n, side, i), or a node
function GraphView:pin_at(wx, wy)
  local r = 9 / self.cam.zoom * 0.6 + 4            -- (generous when far out)
  for j = #self.graph.nodes, 1, -1 do
    local n = self.graph.nodes[j]
    local k = self:kind(n)
    for side, list in pairs({ out = k.outs or {}, ["in"] = k.ins or {} }) do
      for i = 1, #list do
        local px, py = self:pin_xy(n, side, i)
        if math.abs(wx - px) <= r and math.abs(wy - py) <= r then return n, side, i end
      end
    end
  end
end
function GraphView:node_at(wx, wy)
  for j = #self.graph.nodes, 1, -1 do
    local n = self.graph.nodes[j]
    local x, y, w, h = self:node_rect(n)
    if wx >= x and wx < x + w and wy >= y and wy < y + h then return n end
  end
end

-- the mouse --------------------------------------------------------------

local function to_front(nodes, n)
  for i, m in ipairs(nodes) do if m == n then table.remove(nodes, i) break end end
  table.insert(nodes, n)
end

function GraphView:on_canvas_pressed(button, wx, wy, clicks)
  if button ~= "left" then return false end
  local n, side, i = self:pin_at(wx, wy)
  if n then
    local k = self:kind(n)
    if side == "in" then
      local l, li = self:link_into(n.id, k.ins[i][1])
      local src = l and self:node(l.from)
      if src then                                   -- pick its wire up: from its output again
        table.remove(self.graph.links, li)
        self:changed()
        self.drag = { wire = true, node = src, side = "out", i = pin_index(self:kind(src).outs, l.out) or 1, wx = wx, wy = wy }
        return true
      end
    end
    self.drag = { wire = true, node = n, side = side, i = i, wx = wx, wy = wy }
    return true
  end
  n = self:node_at(wx, wy)
  if n then
    if keymap.modkeys["ctrl"] then self.sel[n] = not self.sel[n] or nil
    elseif not self.sel[n] then self.sel = { [n] = true } end
    to_front(self.graph.nodes, n)
    self.drag = { move = true, wx = wx, wy = wy }
    core.redraw = true
    return true
  end
  if not keymap.modkeys["ctrl"] and next(self.sel) then self.sel = {}; core.redraw = true end
  return false                                     -- (nothing: the canvas pans)
end

function GraphView:on_canvas_moved(wx, wy)
  local d = self.drag
  local hn, hs, hi = self:pin_at(wx, wy)
  local hover = hn and { hn, hs, hi } or nil
  local hnode = not hn and self:node_at(wx, wy) or nil
  if (hover and (not self.hover_pin or self.hover_pin[1] ~= hn or self.hover_pin[2] ~= hs or self.hover_pin[3] ~= hi))
     or (not hover and self.hover_pin) or hnode ~= self.hover then
    self.hover_pin, self.hover = hover, hnode
    core.redraw = true
  end
  if not d then return end
  if d.move then
    local dx, dy = wx - d.wx, wy - d.wy
    for n in pairs(self.sel) do n.x, n.y = n.x + dx, n.y + dy end
    d.wx, d.wy, d.moved = wx, wy, true
  else
    d.wx, d.wy = wx, wy
  end
  core.redraw = true
end

function GraphView:on_canvas_released(button, wx, wy)
  local d = self.drag
  self.drag = nil
  if not d then return end
  if d.move then
    if d.moved then
      for n in pairs(self.sel) do n.x, n.y = math.floor(n.x + 0.5), math.floor(n.y + 0.5) end
      self:changed()
    end
    return
  end
  local n, side, i = self:pin_at(wx, wy)            -- a wire dropped on a pin
  if n and n ~= d.node and side ~= d.side then
    local a, ai, b, bi = d.node, d.i, n, i
    if d.side == "in" then a, ai, b, bi = n, i, d.node, d.i end
    local o, p = self:kind(a).outs[ai], self:kind(b).ins[bi]
    if self:can_connect(o[2], p[2]) then self:connect(a.id, o[1], b.id, p[1]) end
  end
  core.redraw = true
end

-- the menu: add a node where it opened, or act on the selection
function GraphView:menu_items()
  local items = {}
  local wx, wy = self:to_world(self.mx or 0, self.my or 0)
  local under = self:node_at(wx, wy)
  if under and not self.sel[under] then self.sel = { [under] = true } end
  if next(self.sel) then
    local set = self.sel
    table.insert(items, { text = "Duplicate", command = function() self:duplicate(set) end })
    table.insert(items, { text = "Delete", info = "delete", command = function() self:remove_nodes(set) end })
    table.insert(items, require("plugins.contextmenu").DIVIDER)
  end
  local names = {}
  for name in pairs(self.kinds) do table.insert(names, name) end
  table.sort(names, function(a, b) return #(self.kinds[a].title or a) < #(self.kinds[b].title or b) or
    (#(self.kinds[a].title or a) == #(self.kinds[b].title or b) and (self.kinds[a].title or a) < (self.kinds[b].title or b)) end)
  for _, name in ipairs(names) do
    table.insert(items, { text = "Add " .. (self.kinds[name].title or name), command = function() self:add_node(name, wx, wy) end })
  end
  table.insert(items, require("plugins.contextmenu").DIVIDER)
  for _, it in ipairs(GraphView.super.menu_items(self)) do table.insert(items, it) end
  return items
end

-- drawing ----------------------------------------------------------------

function GraphView:draw_wire(x1, y1, x2, y2, color, hot)
  local z = self:z()
  D.wire(x1, y1, x2, y2, color, (hot and 2.2 or 1.4) * z, 40 * z, hot and alpha(C.outline, 220) or nil)
end

function GraphView:draw_node(n)
  local z = self:z()
  local k = self:kind(n)
  local wx, wy, ww, wh = self:node_rect(n)
  local x, y = self:to_screen(wx, wy)
  local w, h = ww * z, wh * z
  local head = color_of(k.color) or self.HEAD
  local sel, hot = self.sel[n], self.hover == n
  local nsel = 0
  for _ in pairs(self.sel) do nsel = nsel + 1 end
  local outline = sel and (nsel <= 1 and C.active or C.sel) or (hot and C.hover) or nil
  if z < self.LOD then
    if outline then renderer.draw_rect(x - 1, y - 1, w + 2, h + 2, outline) end
    renderer.draw_rect(x, y, w, h, C.body)
    renderer.draw_rect(x, y, w, math.max(1, self.head_h * z), head)
    return
  end
  local r = 5 * z
  D.rrect(x + 2 * z, y + 3 * z, w, h, r, C.shadow)
  if outline then
    local t = math.max(1, (sel and 2 or 1) * z)
    D.rrect(x - t, y - t, w + 2 * t, h + 2 * t, r + t, outline)
  end
  D.rrect(x, y, w, h, r, C.body)
  local hh = self.head_h * z
  D.rrect(x, y, w, hh, r, head, true)
  local pad = 8 * z
  if z >= 0.4 then
    local F = D.font(13 * z)
    core.push_clip_rect(x, y, w, h)
    D.text(F, k.title or tostring(n.kind), x + pad, y, C.text, hh)
    local L = D.font(12 * z)
    for i, p in ipairs(k.outs or {}) do
      local _, py = self:to_screen(self:pin_xy(n, "out", i))
      local label = p[1]
      D.text(L, label, x + w - pad - L:get_width(label), py - L:get_height() / 2, C.blabel)
    end
    for i, p in ipairs(k.ins or {}) do
      local _, py = self:to_screen(self:pin_xy(n, "in", i))
      D.text(L, p[1], x + pad, py - L:get_height() / 2, C.blabel)
    end
    local extra = self:node_extra(n)
    if extra > 0 then self:draw_node_extra(n, x, y + h - (extra + 3) * z, w, extra * z, z) end
    core.pop_clip_rect()
  end
  local hp = self.hover_pin
  for side, list in pairs({ out = k.outs or {}, ["in"] = k.ins or {} }) do
    for i, p in ipairs(list) do
      local sx, sy = self:to_screen(self:pin_xy(n, side, i))
      local lit = hp and hp[1] == n and hp[2] == side and hp[3] == i
      D.socket(sx, sy, 11 * z, self:type_color(p[2]), lit, C.outline, C.active)
    end
  end
end

function GraphView:draw_canvas()
  for _, l in ipairs(self.graph.links) do
    local a, b = self:node(l.from), self:node(l.to)
    local ai = a and pin_index(self:kind(a).outs, l.out)
    local bi = b and pin_index(self:kind(b).ins, l.input)
    if ai and bi then
      local x1, y1 = self:to_screen(self:pin_xy(a, "out", ai))
      local x2, y2 = self:to_screen(self:pin_xy(b, "in", bi))
      self:draw_wire(x1, y1, x2, y2, self:type_color(self:kind(a).outs[ai][2]), self.sel[a] or self.sel[b])
    end
  end
  for _, n in ipairs(self.graph.nodes) do
    local x, y, w, h = self:node_rect(n)
    local sx, sy = self:to_screen(x, y)
    local z = self:z()
    if sx < self.position.x + self.size.x and sy < self.position.y + self.size.y and sx + w * z > self.position.x and sy + h * z > self.position.y then
      self:draw_node(n)
    end
  end
  local d = self.drag                              -- a wire being dragged: from its pin to the mouse
  if d and d.wire then
    local px, py = self:to_screen(self:pin_xy(d.node, d.side, d.i))
    local list = d.side == "out" and self:kind(d.node).outs or self:kind(d.node).ins
    local c = self:type_color(list[d.i][2])
    if d.side == "out" then self:draw_wire(px, py, self.mx, self.my, c, true)
    else self:draw_wire(self.mx, self.my, px, py, c, true) end
  end
end

function GraphView:draw_overlay()
  if #self.graph.nodes == 0 then
    local t = "empty: right-click to add a node"
    renderer.draw_text(style.font, t, self.position.x + (self.size.x - style.font:get_width(t)) / 2,
                       self.position.y + self.size.y / 2, C.dim)
  end
end

return GraphView

-- editor.lua - the tilemap editor: .tmap tile maps (runs in lite). The map in
-- the middle (a canvas: MMB or SPACE+drag pans, CTRL+wheel zooms); the tools,
-- the layers and the tileset on the left; the map's size on the right.
--
--   LMB          the tool: Paint (the picked tiles, a stamp), Rect, Fill, Erase
--   RMB          erases (any tool)        ALT+LMB  picks the tile under it
--   B / R / F / E   the tools             CTRL+Z / CTRL+Y  undo / redo
--   1..9         the layer                CTRL+S  save
--
-- The tileset: tiles.png, 256 x 256, 16 x 16 tiles (ours, CC0: made by
-- tools/make_tiles.py), or a picture beside the map (`tileset` in the file).
-- map.lua is the model (no lite in it): a game can read a .tmap the same way.
local P = ...
P.title = "Tilemap editor"                         -- (its name in menus: Open with, the main menu's Plugins)
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local canvas = require "plugins.canvas"
local Map = P.require("map")

local DEFAULTS = { grid = true, w = 32, h = 20 }
local cfg = {}
local function load_config()
  local c = P.read("config")
  cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if type(c) == "table" then for k, v in pairs(c) do if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then cfg[k] = v end end end
end

local function S(n) return math.floor(n * SCALE + 0.5) end
local function base_of(f) return (f:match("[^/\\]*$")) end
local function dir_of(f) return f:match("^(.*)[/\\]") or "." end
local function read(file)
  local f = io.open(file, "rb")
  if not f then return nil, "can't read" end
  local src = f:read("*a")
  f:close()
  if src:match("^%s*$") then return {} end
  local fn, err = load(src, "=" .. file, "t", {})
  if not fn then return nil, err end
  local ok, v = pcall(fn)
  if not ok or type(v) ~= "table" then return nil, ok and "not a table" or v end
  return v
end
local NAMES = (function()                          -- the plugin's tiles' names (tiles.lua)
  local t = read(P.dir .. "/tiles.lua")
  return type(t) == "table" and type(t.names) == "table" and t.names or {}
end)()

local AUTO = (function()                           -- the plugin's auto-tiles (tiles.lua's auto: { shore = { first = 64 } })
  local t = read(P.dir .. "/tiles.lua")
  return type(t) == "table" and type(t.auto) == "table" and t.auto or Map.AUTO
end)()
local NAMED_ROWS = 0                               -- (the plugin's sheet: only its rows with tiles show)
for i in pairs(NAMES) do NAMED_ROWS = math.max(NAMED_ROWS, math.floor(i / 16) + 1) end
local TOOLS = { "paint", "rect", "fill", "erase" }
local TOOL_NAMES = { paint = "Paint", rect = "Rect", fill = "Fill", erase = "Erase" }

local TileView = canvas.View:extend()
TileView.grid = nil                                -- (the map draws its own)
TileView.zoom_min, TileView.zoom_max = 0.1, 16

function TileView:new(state)
  TileView.super.new(self)
  self.filename = state and state.filename or ""
  self.untitled = state and state.untitled or self.filename == ""
  self.left, self.right = canvas.ui.new(), canvas.ui.new()
  self.undo, self.redo = {}, {}
  self.tool, self.layer, self.sel = "paint", 1, { 0, 0 }
  local t, err
  if self.untitled then t = { w = cfg.w, h = cfg.h }
  else t, err = read(self.filename) end
  self.err = not t and err or nil
  self.map = (t and t.layers) and Map.from_data(t) or Map.new(t and t.w, t and t.h)
  if t and t.tileset then self.map.tileset = t.tileset end
  self:load_tileset()
  if state and state.cam then self:set_camera(state.cam) end
end
function TileView:get_name() return (self.untitled and "untitled.tmap" or base_of(self.filename)) .. (self.dirty and "*" or "") end
function TileView:get_state() return { filename = self.filename, untitled = self.untitled, cam = self:camera_state() } end

function TileView:tileset_path()
  local ts = self.map.tileset
  if ts:match("^plugin:") then return P.dir .. "/" .. ts:sub(8) end
  return dir_of(self.filename) .. "/" .. ts
end
function TileView:load_tileset()
  local img, err = renderer.image.load(self:tileset_path())
  if not img then                                  -- (the plugin's own, then)
    self.ts_err = err
    img = renderer.image.load(P.dir .. "/tiles.png")
  else self.ts_err = nil end
  self.img = img
  local iw, ih = 256, 256
  if img then iw, ih = img:get_size() end
  self.cols, self.rows = math.max(1, math.floor(iw / self.map.tile)), math.max(1, math.floor(ih / self.map.tile))
end
function TileView:bounds() return 0, 0, self.map.w * self.map.tile, self.map.h * self.map.tile end

-- edits: a stroke is one undo step (a copy of the map before it)
function TileView:begin_edit()
  self.undo[#self.undo + 1] = Map.copy(self.map)
  if #self.undo > 100 then table.remove(self.undo, 1) end
  self.redo = {}
end
function TileView:changed() self.dirty = true; core.redraw = true end
-- auto-tiles (the plugin's tileset, on unless turned off): the cells about
-- an edit re-picked from their neighbours (water shores, wall edges)
function TileView:autotile(x0, y0, x1, y1)
  if self.auto == false or self.map.tileset ~= Map.DEFAULTS.tileset then return end
  if Map.autotile(self.map, self.layer, AUTO, x0, y0, x1, y1) > 0 then self:changed() end
end
function TileView:undo_step(back)
  local from, to = back and self.undo or self.redo, back and self.redo or self.undo
  local m = table.remove(from)
  if not m then return end
  to[#to + 1] = Map.copy(self.map)
  self.map = m
  self:changed()
end

function TileView:reload()                         -- (read again from the disk: a regenerated map)
  local t, err = read(self.filename)
  if not t then self.err = err return end
  self.err = nil
  self.map = Map.from_data(t)
  if t.tileset then self.map.tileset = t.tileset end
  self.layer = math.min(self.layer, #self.map.layers)
  self.dirty = false
  self:load_tileset()
  core.redraw = true
end
function TileView:regenerate(src)
  local out, err = require("plugins.chain").rebuild(src)
  if not out then core.error("regenerate: %s", tostring(err)) self:flash("Can't regenerate", true) return end
  self:reload()
  self:flash("Regenerated")
end
function TileView:save()
  if self.untitled then
    return canvas.save_as("tmap", function(path) self.filename, self.untitled = path, nil; self:save() end)
  end
  local f = io.open(self.filename, "wb")
  if not f then core.error("can't write %s", self.filename) return end
  f:write("-- a tile map (plugins/tilemap): its tileset, size and layers (plugins/tilemap/map.lua)\nreturn ",
          canvas.to_lua(Map.to_data(self.map)), "\n")
  f:close()
  self.dirty = false
  core.log("Saved %s", self:get_name())
  self:flash("Saved")                              -- (canvas.tip: a note on the tab, bottom right)
end

function TileView:update()
  TileView.super.update(self)
  local now = system.get_time()
  if now >= (TileView.next_check or 0) then
    TileView.next_check = now + 0.5
    if P.changed("config") then load_config() end
    if P.changed("files") then P.open_with(P.read("files") or {}, TileView) end
  end
end

-- layout: the panels, the map between them
function TileView:rects()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local lw = math.floor(math.min(S(340), w * 0.34))
  local rw = math.floor(math.min(S(190), w * 0.22))
  return { left = { x, y, lw, h }, right = { x + w - rw, y, rw, h }, mid = { x + lw, y, w - lw - rw, h } }
end
function TileView:fit()
  local r = self:rects().mid
  local mw, mh = self.map.w * self.map.tile, self.map.h * self.map.tile
  local z = math.min(r[3] / mw, r[4] / mh) * 0.9 / SCALE
  self.cam.zoom = math.max(self.zoom_min, math.min(self.zoom_max, z))
  self.cam.x = r[1] - self.position.x + r[3] / 2 - mw / 2 * self.cam.zoom * SCALE
  self.cam.y = r[2] - self.position.y + r[4] / 2 - mh / 2 * self.cam.zoom * SCALE
  self.fitting = true
  self.fit_w, self.fit_h = self.size.x, self.size.y
  core.redraw = true
end

function TileView:stamp() return Map.stamp(self.sel, self.cols) end
function TileView:tile_name(i)
  if not i then return "none" end
  return (self.map.tileset == Map.DEFAULTS.tileset and NAMES[i]) or ("tile " .. i)
end

function TileView:draw_left(r)
  local ui = self.left
  ui:begin(r[1], r[2], r[3], r[4], { divider_right = true })
  ui:head("Tools")
  local list = {}
  for _, t in ipairs(TOOLS) do list[#list + 1] = { TOOL_NAMES[t], function() self.tool = t end, on = self.tool == t } end
  ui:buttons(list)
  ui:head("Layers")
  local rows = {}                                  -- (canvas.ui's list: the one edited lit; hover: show / hide it)
  for i, l in ipairs(self.map.layers) do
    rows[#rows + 1] = { text = i .. "  " .. l.name, info = (not l.visible) and "hidden" or nil, selected = i == self.layer,
                        press = function() self.layer = i end, tip = "the layer to edit (keys 1..9)",
                        button = { l.visible and "hide" or "show", function() l.visible = not l.visible; self:changed() end } }
  end
  ui:list(rows)
  local cur = self.map.layers[self.layer]
  ui:field("Name", cur.name, function(t)
    if t:match("%S") then self:begin_edit(); cur.name = t; self:changed() end
  end, { key = "layer" .. self.layer, tip = "click to rename this layer; Enter keeps it" })
  ui:buttons({ { "+ layer", function()
      self:begin_edit()
      table.insert(self.map.layers, Map.new_layer("layer " .. (#self.map.layers + 1), self.map.w, self.map.h))
      self.layer = #self.map.layers
      self:changed()
    end },
    { "- layer", #self.map.layers > 1 and function()
      self:begin_edit()
      table.remove(self.map.layers, self.layer)
      self.layer = math.min(self.layer, #self.map.layers)
      self:changed()
    end or nil } })
  ui:head("Tiles")
  local st = self:stamp()
  ui:label(st.w * st.h > 1 and string.format("%d x %d tiles", st.w, st.h) or self:tile_name(self.sel[1]))
  if self.img then
    local rows = (self.map.tileset == Map.DEFAULTS.tileset and NAMED_ROWS > 0) and NAMED_ROWS or nil
    local hov = ui:tiles(self.img, self.map.tile, self.sel, function(i, j) self.sel = { i, j }; if self.tool == "erase" then self.tool = "paint" end end, { rows = rows })
    if hov then self.hover_tile = hov end
  else ui:text("no tileset: " .. tostring(self.ts_err), style.error) end
  ui:finish()
end

function TileView:draw_right(r)
  local ui, m = self.right, self.map
  ui:begin(r[1], r[2], r[3], r[4])
  ui:head("Map")
  self.new_w, self.new_h = self.new_w or m.w, self.new_h or m.h
  ui:slider("Width", self.new_w, 1, 256, function(v) self.new_w = v end, { fmt = "%d", int = true, step = 1, def = m.w })
  ui:slider("Height", self.new_h, 1, 256, function(v) self.new_h = v end, { fmt = "%d", int = true, step = 1, def = m.h })
  if self.new_w ~= m.w or self.new_h ~= m.h then
    ui:buttons({ { "Resize", function() self:begin_edit(); Map.resize(m, self.new_w, self.new_h); self:changed(); self:fit() end, accent = true },
                 { "Cancel", function() self.new_w, self.new_h = m.w, m.h end } })
  end
  if m.tileset == Map.DEFAULTS.tileset then
    ui:check("Auto-tiles", self.auto ~= false, function() self.auto = self.auto == false end)   -- (water shores, wall edges: picked from the neighbours as you paint)
    if self.auto ~= false then
      ui:buttons({ { "Auto-tile this layer", function() self:begin_edit(); self:autotile() end, tip = "every water and stone-wall cell of the layer re-picked from its neighbours" } })
    end
  end
  if m.made_by and not self.untitled then          -- (another plugin made it: plugins/chain)
    local chain = require "plugins.chain"
    local src = chain.source(m.made_by, self.filename)
    ui:space()
    ui:head("Made by")
    ui:label("Source", base_of(m.made_by))
    ui:buttons({ { "Regenerate", function() self:regenerate(src) end, tip = "Make it again from its source (your edits here go)" },
                 { "Open source", function() chain.open_source(src) end } })
    ui:space()
  end
  ui:label("Tile", m.tile .. " px")
  ui:label("Tileset", base_of(m.tileset:gsub("^plugin:", "")))
  ui:check("Grid", cfg.grid, function() cfg.grid = not cfg.grid; core.redraw = true end)
  ui:space()
  ui:head("Layer " .. self.layer)
  ui:label("Name", m.layers[self.layer].name)
  ui:label("Tiles", Map.count(m, self.layer))
  if self.hover then
    ui:space()
    ui:head("Cell")
    ui:label("At", self.hover[1] .. ", " .. self.hover[2])
    local v = Map.get(m, self.layer, self.hover[1], self.hover[2])
    if v ~= nil then ui:label("Tile", self:tile_name(v or nil)) end
  end
  ui:space()
  ui:buttons({ { self.dirty and "Save  CTRL+S" or "Saved", function() self:save() end, accent = self.dirty } })
  ui:finish()
end

function TileView:draw_canvas()
  local m, img, ts = self.map, self.img, self.map.tile
  local z = self:z()
  local cs = ts * z                                -- a cell, px on screen
  local ox, oy = self:to_screen(0, 0)
  local r = self:rects().mid
  renderer.draw_rect(ox, oy, m.w * cs, m.h * cs, { 0, 0, 0, 60 })
  local x0 = math.max(0, math.floor((r[1] - ox) / cs))   -- (only the cells on screen)
  local y0 = math.max(0, math.floor((r[2] - oy) / cs))
  local x1 = math.min(m.w - 1, math.floor((r[1] + r[3] - ox) / cs))
  local y1 = math.min(m.h - 1, math.floor((r[2] + r[4] - oy) / cs))
  if img then
    for li, l in ipairs(m.layers) do
      if l.visible then
        local tint = (li > self.layer) and { 255, 255, 255, 150 } or nil   -- (the layers above the one edited: faded)
        for y = y0, y1 do
          local row = y * m.w
          for x = x0, x1 do
            local c = l.cells[row + x + 1]
            if c then
              renderer.draw_image(img, math.floor(ox + x * cs), math.floor(oy + y * cs), math.ceil(cs), math.ceil(cs), tint,
                                  (c % self.cols) * ts, math.floor(c / self.cols) * ts, ts, ts)
            end
          end
        end
      end
    end
  end
  if cfg.grid and cs >= 6 then                     -- the grid
    local gc = { 255, 255, 255, 22 }
    for x = x0, x1 + 1 do renderer.draw_rect(ox + x * cs, oy + y0 * cs, 1, (y1 - y0 + 1) * cs, gc) end
    for y = y0, y1 + 1 do renderer.draw_rect(ox + x0 * cs, oy + y * cs, (x1 - x0 + 1) * cs, 1, gc) end
  end
  local edge = style.dim                           -- the map's edge
  renderer.draw_rect(ox, oy, m.w * cs, 1, edge); renderer.draw_rect(ox, oy + m.h * cs, m.w * cs, 1, edge)
  renderer.draw_rect(ox, oy, 1, m.h * cs, edge); renderer.draw_rect(ox + m.w * cs, oy, 1, m.h * cs + 1, edge)
  local h = self.hover                             -- where the tool goes: the stamp, faint, or the rectangle
  if h then
    local hx, hy = ox + h[1] * cs, oy + h[2] * cs
    if self.dragrect then
      local a, b = self.dragrect, h
      local rx, ry = ox + math.min(a[1], b[1]) * cs, oy + math.min(a[2], b[2]) * cs
      local rw, rh = (math.abs(a[1] - b[1]) + 1) * cs, (math.abs(a[2] - b[2]) + 1) * cs
      renderer.draw_rect(rx, ry, rw, rh, { style.accent[1], style.accent[2], style.accent[3], 50 })
    elseif self.tool == "paint" and img then
      local st = self:stamp()
      for j = 0, st.h - 1 do for i = 0, st.w - 1 do
        local c = st[j * st.w + i + 1]
        renderer.draw_image(img, hx + i * cs, hy + j * cs, math.ceil(cs), math.ceil(cs), { 255, 255, 255, 140 },
                            (c % self.cols) * ts, math.floor(c / self.cols) * ts, ts, ts)
      end end
    end
    local st = (self.tool == "paint") and self:stamp() or { w = 1, h = 1 }
    local fc = self.tool == "erase" and (style.error or style.accent) or style.accent
    local fw, fh = st.w * cs, st.h * cs
    renderer.draw_rect(hx, hy, fw, 1, fc); renderer.draw_rect(hx, hy + fh, fw, 1, fc)
    renderer.draw_rect(hx, hy, 1, fh, fc); renderer.draw_rect(hx + fw, hy, 1, fh + 1, fc)
  end
end

function TileView:draw_overlay()
  local r = self:rects()
  local m = r.mid
  renderer.draw_text(style.font, self:get_name() .. "   " .. TOOL_NAMES[self.tool] .. "   layer " .. self.layer
                     .. (self.err and ("   can't read: " .. self.err) or ""),
                     m[1] + S(12), m[2] + S(10), self.err and (style.error or style.text) or style.dim)
  self:draw_left(r.left)
  self:draw_right(r.right)
end

-- the mouse: the panels first; on the map, the tool
function TileView:cell_at(wx, wy)
  return math.floor(wx / self.map.tile), math.floor(wy / self.map.tile)
end
function TileView:apply(button, cx, cy, first)
  local m, L = self.map, self.layer
  if button == "right" or self.tool == "erase" then
    if Map.set(m, L, cx, cy, false) then self:changed(); self:autotile(cx - 1, cy - 1, cx + 1, cy + 1) end
  elseif self.tool == "paint" then
    local st = self:stamp()
    if Map.paint(m, L, cx, cy, st) then self:changed(); self:autotile(cx - 1, cy - 1, cx + st.w, cy + st.h) end
  elseif self.tool == "fill" and first then
    local st = self:stamp()
    if Map.fill(m, L, cx, cy, st[1]) > 0 then self:changed(); self:autotile() end
  end
end
function TileView:takes_right(x, y)               -- (contextmenu.lua: RMB on the map erases; CTRL+RMB, or off the map: the menu)
  if keymap.modkeys["ctrl"] or self.left:inside(x, y) or self.right:inside(x, y) then return false end
  local cx, cy = self:cell_at(self:to_world(x, y))
  return Map.get(self.map, self.layer, cx, cy) ~= nil
end
function TileView:on_mouse_pressed(button, x, y, clicks)
  if self.left:pressed(button, x, y, clicks) or self.right:pressed(button, x, y, clicks) then return true end
  if button == "right" and not keymap.modkeys["ctrl"] then   -- (RMB on the map erases; CTRL+RMB: the menu)
    local wx, wy = self:to_world(x, y)
    local cx, cy = self:cell_at(wx, wy)
    if Map.get(self.map, self.layer, cx, cy) ~= nil then
      self:begin_edit()
      self.painting = "right"
      self:apply("right", cx, cy, true)
      return true
    end
  end
  return TileView.super.on_mouse_pressed(self, button, x, y, clicks)
end
function TileView:on_canvas_pressed(button, wx, wy, clicks)
  if button ~= "left" then return false end
  local cx, cy = self:cell_at(wx, wy)
  if Map.get(self.map, self.layer, cx, cy) == nil then return false end   -- (off the map: pans)
  if keymap.modkeys["alt"] then                    -- pick the tile under it
    local v = Map.get(self.map, self.layer, cx, cy)
    if v then self.sel = { v, v }; self.tool = "paint" end
    return true
  end
  self:begin_edit()
  if self.tool == "rect" then self.dragrect = { cx, cy } return true end
  self.painting = "left"
  self:apply("left", cx, cy, true)
  return true
end
function TileView:on_mouse_moved(x, y, dx, dy)
  if self.left:moved(x, y) or self.right:moved(x, y) then self.hover = nil return end
  local r = self:rects().mid
  if x >= r[1] and x < r[1] + r[3] then
    local cx, cy = self:cell_at(self:to_world(x, y))
    local was = self.hover
    self.hover = Map.get(self.map, self.layer, cx, cy) ~= nil and { cx, cy } or nil
    if (was and self.hover and (was[1] ~= cx or was[2] ~= cy)) or (was == nil) ~= (self.hover == nil) then core.redraw = true end
    if self.painting and self.hover then self:apply(self.painting, cx, cy, false) end
  else self.hover = nil end
  if self.painting or self.dragrect then return end
  TileView.super.on_mouse_moved(self, x, y, dx, dy)
end
function TileView:on_mouse_released(button, x, y)
  if self.left:released(button) or self.right:released(button) then return end
  if self.dragrect and self.hover then
    local a, b = self.dragrect, self.hover
    if Map.rect(self.map, self.layer, a[1], a[2], b[1], b[2], self:stamp()) then
      self:changed()
      self:autotile(math.min(a[1], b[1]) - 1, math.min(a[2], b[2]) - 1, math.max(a[1], b[1]) + 1, math.max(a[2], b[2]) + 1)
    end
  end
  self.painting, self.dragrect = nil, nil
  TileView.super.on_mouse_released(self, button, x, y)
end
function TileView:on_mouse_wheel(dy, dx)
  if self.right:wheel(dy) or self.left:wheel(dy) then return true end
  return TileView.super.on_mouse_wheel(self, dy, dx)
end

function TileView:menu_items()                     -- (CTRL+RMB on the map; its source, reload, settings: "Plugin: tilemap", last)
  local DIV = require("plugins.contextmenu").DIVIDER
  local items = {}
  for _, t in ipairs(TOOLS) do items[#items + 1] = { text = TOOL_NAMES[t], info = t:sub(1, 1):upper(), command = function() self.tool = t end } end
  items[#items + 1] = DIV
  items[#items + 1] = { text = "Undo", info = "CTRL+Z", command = function() self:undo_step(true) end }
  items[#items + 1] = { text = "Redo", info = "CTRL+Y", command = function() self:undo_step(false) end }
  items[#items + 1] = { text = "Save", info = "CTRL+S", command = function() self:save() end }
  items[#items + 1] = { text = "Fit", info = "dbl-click", command = function() self:fit() end }
  return items
end

local function active() return core.active_view and core.active_view:is(TileView) and core.active_view end
command.add(function() return active() and true or false end, {
  ["tilemap:undo"] = function() active():undo_step(true) end,
  ["tilemap:redo"] = function() active():undo_step(false) end,
  ["tilemap:paint"] = function() active().tool = "paint"; core.redraw = true end,
  ["tilemap:rect"] = function() active().tool = "rect"; core.redraw = true end,
  ["tilemap:fill"] = function() active().tool = "fill"; core.redraw = true end,
  ["tilemap:erase"] = function() active().tool = "erase"; core.redraw = true end,
})
for i = 1, 9 do
  command.add(function() local v = active() return v and v.map.layers[i] ~= nil end,
    { ["tilemap:layer-" .. i] = function() active().layer = i; core.redraw = true end })
end
if not package.loaded["tilemap.keys"] then
  package.loaded["tilemap.keys"] = true
  local keys = { ["ctrl+z"] = "tilemap:undo", ["ctrl+y"] = "tilemap:redo", ["b"] = "tilemap:paint", ["r"] = "tilemap:rect",
                 ["f"] = "tilemap:fill", ["e"] = "tilemap:erase" }
  for i = 1, 9 do keys[tostring(i)] = "tilemap:layer-" .. i end
  keymap.add(keys)
end

load_config()
P.open_with(P.read("files") or {}, TileView)
P.commands = { { "Paint", "tilemap:paint" }, { "Rect", "tilemap:rect" }, { "Fill", "tilemap:fill" }, { "Erase", "tilemap:erase" },
               { "Undo", "tilemap:undo" }, { "Redo", "tilemap:redo" }, { "Save", "canvas:save" } }
P.tab = function() return TileView({}) end         -- (the main menu's Plugins >: a new map, untitled)
return TileView

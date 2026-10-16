-- editor.lua - the particle editor: .pfx particle effects (runs in lite).
-- The effect plays in the middle (a canvas: the emitter at 0, 0; drag it with
-- LMB, pan with MMB, CTRL+wheel zooms); the effects it comes with on the
-- left (fire, smoke, sparks, explosion, fountain, rain, snow, magic); its
-- settings on the right, as sliders. Changes show at once.
--
-- The simulation is sim.lua (no lite there: a game can run the same). A .pfx
-- file is Lua data: return { rate = 40, life = { 0.8, 1.4 }, ... } (sim.lua
-- says what each setting is). Saving this file reloads the plugin.
local P = ...
P.title = "Particle editor"                         -- (its name in menus: Open with, the main menu's Plugins)
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local canvas = require "plugins.canvas"
local D = canvas.draw
local fx = P.require("sim")

local DEFAULTS = { background = "dark", speed = 1 }
local cfg = {}
local function load_config()
  local c = P.read("config")
  cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if type(c) == "table" then for k, v in pairs(c) do if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then cfg[k] = v end end end
end

local function S(n) return math.floor(n * SCALE + 0.5) end
local function base_of(f) return (f:match("[^/\\]*$")) end
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

local FxView = canvas.View:extend()
FxView.grid = 32
FxView.zoom_min, FxView.zoom_max = 0.1, 8

function FxView:new(state)
  FxView.super.new(self)
  self.filename = state and state.filename or ""
  self.untitled = state and state.untitled or self.filename == ""   -- (a tab opened apart: the template, saved where asked)
  self.left, self.right = canvas.ui.new(), canvas.ui.new()
  self.undo, self.redo = {}, {}
  self.playing, self.speed = true, cfg.speed
  local t, err = read(self.untitled and (P.dir .. "/templates/effect.pfx") or self.filename)
  self.err = not t and err or nil
  self.def = fx.check(t)
  self:restart()
  if state and state.cam then self:set_camera(state.cam) end
end
function FxView:get_name() return (self.untitled and "untitled.pfx" or base_of(self.filename)) .. (self.dirty and "*" or "") end
function FxView:get_state() return { filename = self.filename, untitled = self.untitled, cam = self:camera_state() } end
function FxView:bounds() return -200, -200, 400, 400 end

function FxView:restart()
  local x, y = self.e and self.e.x or 0, self.e and self.e.y or 0
  self.e = fx.new(self.def, 1)
  self.e.x, self.e.y = x, y
  self.last = nil
  core.redraw = true
end
function FxView:edit(fn, held)                     -- fn(def) changes a copy; held: a slider still dragged (one undo step)
  if not held or not self.holding then
    self.undo[#self.undo + 1] = fx.copy(self.def)
    if #self.undo > 200 then table.remove(self.undo, 1) end
    self.redo = {}
  end
  self.holding = held
  local d = fx.copy(self.def)
  fn(d)
  self.def = fx.check(d)
  self.e.def = self.def                            -- (the particles alive keep going, with the new settings)
  self.dirty = true
  core.redraw = true
end
function FxView:undo_step(back)
  local from, to = back and self.undo or self.redo, back and self.redo or self.undo
  if #from == 0 then return end
  to[#to + 1] = fx.copy(self.def)
  self.def = fx.check(table.remove(from))
  self.dirty = true
  self:restart()
end
function FxView:use_preset(name)
  self:edit(function(d) for k, v in pairs(fx.preset(name)) do d[k] = v end end)
  self:restart()
end

function FxView:save()
  if self.untitled then                            -- (where, first)
    return canvas.save_as("pfx", function(path) self.filename, self.untitled = path, nil; self:save() end)
  end
  local f = io.open(self.filename, "wb")
  if not f then core.error("can't write %s", self.filename) return end
  f:write("-- a particle effect (plugins/particles): its settings (plugins/particles/sim.lua)\nreturn ", canvas.to_lua(self.def), "\n")
  f:close()
  self.dirty = false
  core.log("Saved %s", self:get_name())
  self:flash("Saved")                              -- (canvas.tip: a note on the tab, bottom right)
end

function FxView:update()
  FxView.super.update(self)
  local now = system.get_time()
  if self.playing then
    local dt = math.min(0.05, now - (self.last or now)) * self.speed
    self.last = now
    if dt > 0 then fx.step(self.e, dt) end
    core.redraw = true
  else self.last = nil end
  if now >= (FxView.next_check or 0) then
    FxView.next_check = now + 0.5
    if P.changed("config") then load_config() end
    if P.changed("files") then P.open_with(P.read("files") or {}, FxView) end
  end
end

-- the panels -----------------------------------------------------------
function FxView:rects()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local lw = math.floor(math.min(S(170), w * 0.22))
  local rw = math.floor(math.min(S(300), w * 0.38))
  return { left = { x, y, lw, h }, right = { x + w - rw, y, rw, h }, mid = { x + lw, y, w - lw - rw, h } }
end
function FxView:fit()                              -- the middle, between the panels
  local r = self:rects().mid
  local z = math.min(r[3], r[4]) * 0.8 / 400 / SCALE
  self.cam.zoom = math.max(self.zoom_min, math.min(self.zoom_max, z))
  self.cam.x = r[1] - self.position.x + r[3] / 2
  self.cam.y = r[2] - self.position.y + r[4] / 2
  self.fitting = true
  self.fit_w, self.fit_h = self.size.x, self.size.y
  core.redraw = true
end

function FxView:draw_left(r)
  local ui = self.left
  ui:begin(r[1], r[2], r[3], r[4], { divider_right = true })
  ui:head("Effects")
  for _, k in ipairs(fx.PRESETS) do ui:buttons({ { fx.PRESET_NAMES[k], function() self:use_preset(k) end } }) end
  ui:space()
  ui:head("Preview")
  ui:buttons({ { self.playing and "Pause" or "Play", function() self.playing = not self.playing end, accent = not self.playing },
               { "Restart", function() self:restart() end } })
  ui:slider("Speed", self.speed, 0.1, 2, function(v) self.speed = v end, { fmt = "x%.2f", def = 1, step = 0.1 })
  ui:choice("Background", cfg.background, { "dark", "light", "checker" }, function(v) cfg.background = v end)
  ui:space()
  ui:buttons({ { self.dirty and "Save  CTRL+S" or "Saved", function() self:save() end, accent = self.dirty } })
  ui:label("Alive", tostring(#self.e.ps))
  ui:label("Time", string.format("%.1f s", self.e.t))
  ui:finish()
end

function FxView:draw_right(r)
  local ui, d = self.right, self.def
  ui:begin(r[1], r[2], r[3], r[4])
  local function num(label, k, min, max, o)
    o = o or {}
    o.done = function() self.holding = false end
    o.def = o.def == nil and fx.DEFAULTS[k] or o.def
    ui:slider(label, d[k], min, max, function(v) self:edit(function(t) t[k] = v end, true) end, o)
  end
  local function two(label, k, i, min, max, o)
    o = o or {}
    o.done = function() self.holding = false end
    o.def = fx.DEFAULTS[k][i]
    ui:slider(label, d[k][i], min, max, function(v) self:edit(function(t) t[k][i] = v end, true) end, o)
  end
  ui:head("Emitter")
  num("Rate", "rate", 0, 500, { fmt = "%.0f /s", step = 5 })
  num("Burst", "burst", 0, 500, { fmt = "%d", int = true, step = 5 })
  num("Max alive", "max", 1, 3000, { fmt = "%d", int = true, step = 50 })
  num("Cycle", "duration", 0, 10, { fmt = "%.2f s", step = 0.1 })
  ui:check("Loop", d.loop, function() self:edit(function(t) t.loop = not t.loop end); self:restart() end)
  ui:choice("Shape", d.shape, fx.SHAPES, function(v) self:edit(function(t) t.shape = v end) end)
  if d.shape == "circle" then num("Radius", "radius", 0, 200, { fmt = "%.0f px", step = 2 }) end
  if d.shape == "box" then
    num("Width", "width", 0, 800, { fmt = "%.0f px", step = 5 })
    num("Height", "height", 0, 800, { fmt = "%.0f px", step = 5 })
  end
  ui:head("Life")
  two("Life min", "life", 1, 0.01, 10, { fmt = "%.2f s", step = 0.05 })
  two("Life max", "life", 2, 0.01, 10, { fmt = "%.2f s", step = 0.05 })
  ui:head("Motion")
  num("Angle", "angle", -180, 180, { fmt = "%.0f deg", step = 5 })
  num("Spread", "spread", 0, 180, { fmt = "%.0f deg", step = 5 })
  two("Speed min", "speed", 1, 0, 800, { fmt = "%.0f", step = 5 })
  two("Speed max", "speed", 2, 0, 800, { fmt = "%.0f", step = 5 })
  two("Gravity x", "gravity", 1, -800, 800, { fmt = "%.0f", step = 10 })
  two("Gravity y", "gravity", 2, -800, 800, { fmt = "%.0f", step = 10 })
  num("Drag", "drag", 0, 5, { fmt = "%.2f", step = 0.05 })
  two("Spin min", "spin", 1, -720, 720, { fmt = "%.0f", step = 10 })
  two("Spin max", "spin", 2, -720, 720, { fmt = "%.0f", step = 10 })
  ui:head("Look")
  two("Size start", "size", 1, 0, 128, { fmt = "%.1f px", step = 1 })
  two("Size end", "size", 2, 0, 128, { fmt = "%.1f px", step = 1 })
  num("Size variety", "size_var", 0, 1, { fmt = "%.2f", step = 0.05 })
  ui:color("Colour start", d.color[1], function(c) self:edit(function(t) t.color[1] = c end, true) end, { done = function() self.holding = false end })
  ui:color("Colour end", d.color[2], function(c) self:edit(function(t) t.color[2] = c end, true) end, { done = function() self.holding = false end })
  ui:choice("Blend", d.blend, fx.BLENDS, function(v) self:edit(function(t) t.blend = v end) end)
  ui:check("Squares", d.square, function() self:edit(function(t) t.square = not t.square end) end)
  ui:finish()
end

function FxView:draw_background_color()
  return cfg.background == "light" and { 220, 220, 220, 255 } or style.background
end
function FxView:draw_canvas()
  local r = self:rects().mid
  if cfg.background == "checker" then
    local light = { style.background3[1], style.background3[2], style.background3[3], 255 }
    local dark = { math.floor(light[1] * 0.82), math.floor(light[2] * 0.82), math.floor(light[3] * 0.82), 255 }
    D.checker(r[1], r[2], r[3], r[4], S(16), light, dark)
  end
  local z = self:z()
  local add = self.def.blend == "add"
  local sq = self.def.square
  for _, p in ipairs(self.e.ps) do
    local x, y, size, cr, cg, cb, ca = fx.look(self.e, p)
    local sx, sy = self:to_screen(x, y)
    local s = math.max(1, size * z)
    if add then                                    -- ("add": lighter where they pile up; the preview can't add, it brightens)
      cr, cg, cb = math.min(255, cr * 1.15 + 20), math.min(255, cg * 1.15 + 20), math.min(255, cb * 1.15 + 20)
    end
    local c = { cr, cg, cb, ca }
    if sq or s < 3 then renderer.draw_rect(sx - s / 2, sy - s / 2, s, s, c)
    else D.disc(sx, sy, s, c) end
  end
  local ex, ey = self:to_screen(self.e.x, self.e.y)   -- the emitter: a cross, its shape
  local c = { style.dim[1], style.dim[2], style.dim[3], 200 }
  D.line(ex - S(8), ey, ex + S(8), ey, c, 1)
  D.line(ex, ey - S(8), ex, ey + S(8), c, 1)
  local d = self.def
  if d.shape == "box" then
    local w, h = d.width * z, d.height * z
    renderer.draw_rect(ex - w / 2, ey - h / 2, w, 1, c); renderer.draw_rect(ex - w / 2, ey + h / 2, w, 1, c)
    renderer.draw_rect(ex - w / 2, ey - h / 2, 1, h, c); renderer.draw_rect(ex + w / 2, ey - h / 2, 1, h, c)
  elseif d.shape == "circle" then
    local rr, n = d.radius * z, 32
    for i = 0, n - 1 do
      local a0, a1 = i / n * 2 * math.pi, (i + 1) / n * 2 * math.pi
      D.line(ex + math.cos(a0) * rr, ey + math.sin(a0) * rr, ex + math.cos(a1) * rr, ey + math.sin(a1) * rr, c, 1)
    end
  end
end
function FxView:draw_overlay()
  local r = self:rects()
  local m = r.mid
  renderer.draw_text(style.font, self:get_name() .. (self.err and ("   can't read: " .. self.err) or ""),
                     m[1] + S(12), m[2] + S(10), self.err and (style.error or style.text) or style.dim)
  self:draw_left(r.left)
  self:draw_right(r.right)
end

-- the mouse: the panels first; on the canvas, LMB drags the emitter
function FxView:on_mouse_pressed(button, x, y, clicks)
  if self.left:pressed(button, x, y, clicks) or self.right:pressed(button, x, y, clicks) then return true end
  return FxView.super.on_mouse_pressed(self, button, x, y, clicks)
end
function FxView:on_canvas_pressed(button, wx, wy, clicks)
  if button == "left" and clicks == 1 then self.moving = true; self.e.x, self.e.y = wx, wy; return true end
  return false
end
function FxView:on_mouse_moved(x, y, dx, dy)
  if self.left:moved(x, y) or self.right:moved(x, y) then return end
  if self.moving then self.e.x, self.e.y = self:to_world(x, y); return end
  FxView.super.on_mouse_moved(self, x, y, dx, dy)
end
function FxView:on_mouse_released(button, x, y)
  if self.left:released(button) or self.right:released(button) then return end
  self.moving = nil
  FxView.super.on_mouse_released(self, button, x, y)
end
function FxView:on_mouse_wheel(dy, dx)
  if self.right:wheel(dy) or self.left:wheel(dy) then return true end
  return FxView.super.on_mouse_wheel(self, dy, dx)
end

function FxView:menu_items()                       -- (its source, reload, settings: "Plugin: particles", last)
  local DIV = require("plugins.contextmenu").DIVIDER
  local items = {
    { text = self.playing and "Pause" or "Play", info = "SPACE", command = function() self.playing = not self.playing end },
    { text = "Restart", command = function() self:restart() end },
    { text = "Emitter back to the middle", command = function() self.e.x, self.e.y = 0, 0 end },
    { text = "Save", info = "CTRL+S", command = function() self:save() end },
    DIV,
  }
  for _, k in ipairs(fx.PRESETS) do
    items[#items + 1] = { text = "Effect: " .. fx.PRESET_NAMES[k], command = function() self:use_preset(k) end }
  end
  items[#items + 1] = DIV
  items[#items + 1] = { text = "Undo", info = "CTRL+Z", command = function() self:undo_step(true) end }
  items[#items + 1] = { text = "Redo", info = "CTRL+Y", command = function() self:undo_step(false) end }
  items[#items + 1] = { text = "Fit", info = "dbl-click", command = function() self:fit() end }
  return items
end

command.add(function() return core.active_view and core.active_view:is(FxView) end, {
  ["particles:play"] = function() local v = core.active_view; v.playing = not v.playing end,
  ["particles:undo"] = function() core.active_view:undo_step(true) end,
  ["particles:redo"] = function() core.active_view:undo_step(false) end,
})
if not package.loaded["particles.keys"] then
  package.loaded["particles.keys"] = true
  keymap.add { ["space"] = "particles:play", ["ctrl+z"] = "particles:undo", ["ctrl+y"] = "particles:redo" }
end

load_config()
P.open_with(P.read("files") or {}, FxView)
P.commands = { { "Play / pause", "particles:play" }, { "Undo", "particles:undo" }, { "Redo", "particles:redo" }, { "Save", "canvas:save" } }
P.tab = function() return FxView({}) end           -- (the main menu's Plugins >: a new effect, untitled)
return FxView

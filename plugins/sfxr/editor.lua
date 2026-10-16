-- editor.lua - the sfxr editor: .sfx sound effects (runs in lite). sfxr's
-- own layout, as DrPetter made it: the generators left (pickup, laser,
-- explosion, powerup, hit, jump, blip; randomize, mutate), the wave and the
-- sliders right, the sound drawn in the middle. Every change plays it.
--
-- The synth is runtime/sfxr.lua (sfxr ported to Lua; no lite there). A .sfx file
-- is Lua data: return { wave = 0..3, base_freq = 0.3, ... } (synth.lua's
-- parameters). Playing goes through the editor's sound (host_audio_play,
-- editor/editor.c); Export writes a .wav next to the file. Saving this file reloads
-- the plugin.
local P = ...
P.title = "Sound effects (sfxr)"                         -- (its name in menus: Open with, the main menu's Plugins)
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local canvas = require "plugins.canvas"
local sfxr = P.require("synth")

local DEFAULTS = { autoplay = true, gain = 4 }
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
  if src:match("^%s*$") then return {} end         -- (a new, empty file: the defaults)
  local fn, err = load(src, "=" .. file, "t", {})  -- (data: nothing runs with any power)
  if not fn then return nil, err end
  local ok, v = pcall(fn)
  if not ok or type(v) ~= "table" then return nil, ok and "not a table" or v end
  return v
end

local SfxView = canvas.View:extend()
SfxView.grid = false
SfxView.wants_ctrl_wheel = false

function SfxView:new(state)
  SfxView.super.new(self)
  self.filename = state and state.filename or ""
  self.untitled = state and state.untitled or self.filename == ""   -- (a tab opened apart: the template, saved where asked)
  self.left, self.right = canvas.ui.new(), canvas.ui.new()
  self.undo, self.redo = {}, {}
  self.seed = os.time() % 100000
  local t, err = read(self.untitled and (P.dir .. "/templates/sound.sfx") or self.filename)
  self.err = not t and err or nil
  self:set(sfxr.check(t), true)
end

function SfxView:get_name() return (self.untitled and "untitled.sfx" or base_of(self.filename)) .. (self.dirty and "*" or "") end
function SfxView:get_state() return { filename = self.filename, untitled = self.untitled } end

-- the sound changed: rendered again (and played, unless it's a slider still held)
function SfxView:set(p, quiet)
  self.p = sfxr.check(p)
  self.samples = sfxr.render(self.p, { gain = cfg.gain })
  self.peaks = nil
  core.redraw = true
  if not quiet and cfg.autoplay then self:play() end
end
function SfxView:change(p, quiet)                  -- an edit: undoable, the tab dirty
  self.undo[#self.undo + 1] = self.p
  if #self.undo > 200 then table.remove(self.undo, 1) end
  self.redo = {}
  self.dirty = true
  self:set(p, quiet)
end
function SfxView:copy() local q = {}; for k, v in pairs(self.p) do q[k] = v end; return q end
function SfxView:value(k, v, quiet)                -- one parameter
  local q = self:copy()
  q[k] = v
  if not self.drag_start then self:change(q, quiet) else self.dirty = true; self:set(q, true) end
end
function SfxView:undo_step(back)
  local from, to = back and self.undo or self.redo, back and self.redo or self.undo
  if #from == 0 then return end
  to[#to + 1] = self.p
  self.dirty = true
  self:set(table.remove(from))
end

function SfxView:play()
  if not host_audio_play then core.error("sfxr: no sound here") return end
  local ok, err = host_audio_play(sfxr.pcm16(self.samples), sfxr.RATE)
  if not ok then core.error("sfxr: %s", tostring(err)) return end
  self.played_at = system.get_time()
  core.redraw = true
end
function SfxView:generate(kind)
  self.seed = self.seed + 1
  if kind == "random" then self:change(sfxr.randomize(self.p, self.seed))
  elseif kind == "mutate" then self:change(sfxr.mutate(self.p, self.seed))
  else self:change(sfxr.preset(kind, self.seed)) end
end

function SfxView:save()
  if self.untitled then                            -- (where, first)
    return canvas.save_as("sfx", function(path) self.filename, self.untitled = path, nil; self:save() end)
  end
  local f = io.open(self.filename, "wb")
  if not f then core.error("can't write %s", self.filename) return end
  local p = {}
  for k, v in pairs(self.p) do p[k] = v end
  f:write("-- a sound effect (plugins/sfxr): sfxr's parameters (runtime/sfxr.lua)\nreturn ", canvas.to_lua(p), "\n")
  f:close()
  self.dirty = false
  core.log("Saved %s", self:get_name())
  self:flash("Saved")                              -- (canvas.tip: a note on the tab, bottom right)
end
function SfxView:export()                          -- the .wav, beside it
  if self.untitled then                            -- (untitled: saved first, where asked)
    return canvas.save_as("sfx", function(path) self.filename, self.untitled = path, nil; self:save(); self:export() end)
  end
  local out = self.filename:gsub("%.[^%./\\]*$", "") .. ".wav"
  local f = io.open(out, "wb")
  if not f then core.error("can't write %s", out) return end
  f:write(sfxr.wav(self.samples))
  f:close()
  core.log("Exported %s (%.2f s)", base_of(out), #self.samples / sfxr.RATE)
end

-- the panels -----------------------------------------------------------
function SfxView:rects()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local lw = math.floor(math.min(S(190), w * 0.25))
  local rw = math.floor(math.min(S(300), w * 0.4))
  return { left = { x, y, lw, h }, right = { x + w - rw, y, rw, h }, mid = { x + lw, y, w - lw - rw, h } }
end

function SfxView:draw_left(r)
  local ui = self.left
  ui:begin(r[1], r[2], r[3], r[4], { divider_right = true })
  ui:head("Generate")
  for _, k in ipairs(sfxr.PRESETS) do
    ui:buttons({ { sfxr.PRESET_NAMES[k], function() self:generate(k) end } })
  end
  ui:space()
  ui:buttons({ { "Mutate", function() self:generate("mutate") end }, { "Randomize", function() self:generate("random") end } })
  ui:space()
  ui:head("Sound")
  ui:buttons({ { "Play  SPACE", function() self:play() end, accent = true } })
  ui:buttons({ { "Export .wav", function() self:export() end } })
  ui:buttons({ { self.dirty and "Save  CTRL+S" or "Saved", function() self:save() end, accent = self.dirty } })
  ui:check("Play on change", cfg.autoplay, function() cfg.autoplay = not cfg.autoplay end)
  ui:space()
  ui:label("Length", string.format("%.2f s", #self.samples / sfxr.RATE))
  ui:finish()
end

function SfxView:draw_right(r)
  local ui = self.right
  ui:begin(r[1], r[2], r[3], r[4])
  ui:head("Wave")
  local wl = {}
  for i = 0, 3 do
    local n = sfxr.WAVES[i]
    wl[#wl + 1] = { n:sub(1, 1):upper() .. n:sub(2), function() self:value("wave", i) end, on = self.p.wave == i }
  end
  ui:buttons(wl)
  local group
  local function done() self.drag_start = nil; if cfg.autoplay then self:play() end end
  for _, d in ipairs(sfxr.PARAMS) do
    if d[5] ~= group then group = d[5]; ui:space(S(2)); ui:head(group) end
    local k = d[1]
    ui:slider(d[2], self.p[k], d[3], d[4], function(v)
      if not self.drag_start then self.drag_start = true; self.undo[#self.undo + 1] = self.p; self.redo = {} end
      self.dirty = true
      local q = self:copy(); q[k] = v; self:set(q, true)
    end, { def = sfxr.defaults()[k], step = 0.01, fmt = "%.3f", done = done })
  end
  ui:space(S(2))
  ui:head("Volume")
  ui:slider("Volume", self.p.volume, 0, 1, function(v)
    if not self.drag_start then self.drag_start = true; self.undo[#self.undo + 1] = self.p; self.redo = {} end
    self.dirty = true
    local q = self:copy(); q.volume = v; self:set(q, true)
  end, { def = 0.5, step = 0.05, fmt = "%.2f", done = done })
  ui:finish()
end

-- the sound itself: its waveform (min / max per column), where it's playing
function SfxView:draw_canvas()
  local r = self:rects().mid
  local x, y, w, h = r[1], r[2], r[3], r[4]
  local pad = S(16)
  local gx, gy, gw, gh = x + pad, y + pad * 2 + style.font:get_height(), w - pad * 2, h - pad * 4 - style.font:get_height() * 2
  if gw < 10 or gh < 10 then return end
  renderer.draw_text(style.font, self:get_name() .. (self.err and ("   can't read: " .. self.err) or ""), gx, y + pad, self.err and (style.error or style.text) or style.text)
  renderer.draw_rect(gx, gy, gw, gh, style.background2)
  local mid = gy + gh / 2
  renderer.draw_rect(gx, math.floor(mid), gw, 1, style.divider)
  local s, n = self.samples, #self.samples
  if n == 0 then return end
  if not self.peaks or self.peaks.w ~= gw then     -- (each column: the samples it covers, their min and max)
    local pk = { w = gw }
    local per = n / gw
    for c = 0, gw - 1 do
      local a, b = math.floor(c * per) + 1, math.max(math.floor(c * per) + 1, math.floor((c + 1) * per))
      local lo, hi = 0, 0
      for i = a, math.min(b, n) do local v = s[i]; if v < lo then lo = v end; if v > hi then hi = v end end
      pk[c] = { lo, hi }
    end
    self.peaks = pk
  end
  local col = style.accent
  for c = 0, gw - 1 do
    local lo, hi = self.peaks[c][1], self.peaks[c][2]
    local y1, y2 = math.floor(mid - hi * gh / 2), math.ceil(mid - lo * gh / 2)
    renderer.draw_rect(gx + c, y1, 1, math.max(1, y2 - y1), col)
  end
  if self.played_at then                           -- the playhead
    local t = (system.get_time() - self.played_at) * sfxr.RATE / n
    if t < 1 then
      renderer.draw_rect(gx + math.floor(t * gw), gy, S(2), gh, style.text)
      core.redraw = true
    else self.played_at = nil end
  end
  local secs = n / sfxr.RATE
  renderer.draw_text(style.font, string.format("%.2f s   %s   %d samples", secs, sfxr.WAVES[self.p.wave], n),
                     gx, gy + gh + S(8), style.dim)
end

function SfxView:draw_overlay()
  local r = self:rects()
  self:draw_left(r.left)
  self:draw_right(r.right)
end
function SfxView:draw_background_color() return style.background end

-- the mouse: the panels first
function SfxView:on_mouse_pressed(button, x, y, clicks)
  if self.left:pressed(button, x, y, clicks) or self.right:pressed(button, x, y, clicks) then return true end
  if button == "left" then self:play() return true end   -- (a click on the sound: it plays)
  return SfxView.super.on_mouse_pressed(self, button, x, y, clicks)
end
function SfxView:on_mouse_moved(x, y, dx, dy)
  self.left:moved(x, y)
  self.right:moved(x, y)
end
function SfxView:on_mouse_released(button, x, y)
  self.left:released(button)
  self.right:released(button)
end
function SfxView:on_mouse_wheel(dy, dx)
  return self.right:wheel(dy) or self.left:wheel(dy) or true
end

function SfxView:menu_items()                      -- (its source, reload, settings: "Plugin: sfxr", last)
  local DIV = require("plugins.contextmenu").DIVIDER
  local items = {
    { text = "Play", info = "SPACE", command = function() self:play() end },
    { text = "Save", info = "CTRL+S", command = function() self:save() end },
    { text = "Export .wav", command = function() self:export() end },
    DIV,
  }
  for _, k in ipairs(sfxr.PRESETS) do
    items[#items + 1] = { text = "New: " .. sfxr.PRESET_NAMES[k], command = function() self:generate(k) end }
  end
  items[#items + 1] = { text = "Mutate", command = function() self:generate("mutate") end }
  items[#items + 1] = { text = "Randomize", command = function() self:generate("random") end }
  items[#items + 1] = DIV
  items[#items + 1] = { text = "Undo", info = "CTRL+Z", command = function() self:undo_step(true) end }
  items[#items + 1] = { text = "Redo", info = "CTRL+Y", command = function() self:undo_step(false) end }
  items[#items + 1] = { text = "Play on change", checked = cfg.autoplay, command = function() cfg.autoplay = not cfg.autoplay end }
  return items
end

command.add(function() return core.active_view and core.active_view:is(SfxView) end, {
  ["sfxr:play"] = function() core.active_view:play() end,
  ["sfxr:undo"] = function() core.active_view:undo_step(true) end,
  ["sfxr:redo"] = function() core.active_view:undo_step(false) end,
})
if not package.loaded["sfxr.keys"] then            -- (once: a reload keeps them)
  package.loaded["sfxr.keys"] = true
  keymap.add { ["space"] = "sfxr:play", ["ctrl+z"] = "sfxr:undo", ["ctrl+y"] = "sfxr:redo" }
end

local next_check = 0
function SfxView:update()
  SfxView.super.update(self)
  local now = system.get_time()
  if now >= next_check then
    next_check = now + 0.5
    if P.changed("config") then load_config() end
    if P.changed("files") then P.open_with(P.read("files") or {}, SfxView) end
  end
end

load_config()
P.open_with(P.read("files") or {}, SfxView)
P.commands = { { "Play", "sfxr:play" }, { "Undo", "sfxr:undo" }, { "Redo", "sfxr:redo" }, { "Save", "canvas:save" } }
P.tab = function() return SfxView({}) end          -- (the main menu's Plugins >: a new sound, untitled)
return SfxView

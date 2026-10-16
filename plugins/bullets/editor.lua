-- editor.lua - the bullet editor: .bullets files (runs in Lite). A shoot'em
-- up's patterns (what ships fire), its ships, its waves and its boss, as
-- data (runtime/bullets.lua: the format, and the simulation games run too).
-- Left: the lists (patterns, ships, waves, the boss) and the preview's
-- controls. Middle: the preview, on the play field: a pattern fired from the
-- top at a target you drag (LMB), or the whole stage played (the ships on
-- their paths, the boss through its phases). Right: what's selected, as
-- sliders and choices. Changes show at once; CTRL+S saves.
local P = ...
P.title = "Bullet editor"                          -- (its name in menus: Open with, the main menu's Plugins)
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local canvas = require "plugins.canvas"
local D = canvas.draw
local B = dofile((rawget(_G, "REPLAY_ROOT") or (DATADIR .. "/../../..")) .. "/runtime/bullets.lua")

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
local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end
local function read(file)
  local f = io.open(file, "rb")
  if not f then return nil, "can't read" end
  local src = f:read("*a")
  f:close()
  return B.parse(src)
end
local function hex_rgb(h) h = B.rgb(h); return { math.floor(h / 65536) % 256, math.floor(h / 256) % 256, h % 256, 255 } end
local function rgb_hex(c) return string.format("#%02x%02x%02x", c[1], c[2], c[3]) end
local function names(list, extra)
  local t = extra and { extra } or {}
  for _, x in ipairs(list) do t[#t + 1] = x.name end
  return t
end
local function unique(list, base)
  local taken = {}
  for _, x in ipairs(list) do taken[x.name] = true end
  if not taken[base] then return base end
  for i = 2, 999 do if not taken[base .. i] then return base .. i end end
end

local BView = canvas.View:extend()
BView.grid = 50
BView.zoom_min, BView.zoom_max = 0.1, 6

function BView:new(state)
  BView.super.new(self)
  self.filename = state and state.filename or ""
  self.untitled = state and state.untitled or self.filename == ""
  self.left, self.right = canvas.ui.new(), canvas.ui.new()
  self.undo, self.redo = {}, {}
  self.playing, self.speed, self.mode = true, cfg.speed, "pattern"
  local d, err = read(self.untitled and (P.dir .. "/templates/stage.bullets") or self.filename)
  self.err = not d and err or nil
  self.d = d or B.check({})
  self.sel = self.d.patterns[1] and { "pattern", 1 } or nil
  self.target = { x = 0, y = 200 }
  self:restart()
  if state and state.cam then self:set_camera(state.cam) end
end
function BView:get_name() return (self.untitled and "untitled.bullets" or base_of(self.filename)) .. (self.dirty and "*" or "") end
function BView:get_state() return { filename = self.filename, untitled = self.untitled, cam = self:camera_state() } end
function BView:bounds() local F = B.field(self.d) return -F.w / 2 - 20, -F.h / 2 - 20, F.w + 40, F.h + 40 end

-- the selection: { "pattern" | "ship" | "wave" | "boss", index }
function BView:selected()
  local s = self.sel
  if not s then return nil end
  if s[1] == "pattern" then return self.d.patterns[s[2]]
  elseif s[1] == "ship" then return self.d.enemies[s[2]]
  elseif s[1] == "wave" then return self.d.waves[s[2]]
  elseif s[1] == "boss" then return self.d.boss end
end
function BView:select(kind, i) self.sel = { kind, i }; if kind == "pattern" then self.mode = "pattern" end; self:restart() end

-- edits: fn(d) changes the file's data; one undo step (held: a slider still dragged)
function BView:edit(fn, held)
  if not held or not self.holding then
    self.undo[#self.undo + 1] = copy(self.d)
    if #self.undo > 200 then table.remove(self.undo, 1) end
    self.redo = {}
  end
  self.holding = held
  fn(self.d)
  self.dirty = true
  if not held then self:restart() end
  core.redraw = true
end
function BView:undo_step(back)
  local from, to = back and self.undo or self.redo, back and self.redo or self.undo
  if #from == 0 then return end
  to[#to + 1] = copy(self.d)
  self.d = setmetatable(table.remove(from), B.methods)
  if self.sel and not self:selected() then self.sel = nil end
  self.dirty = true
  self:restart()
end
function BView:save()
  if self.untitled then
    return canvas.save_as("bullets", function(path) self.filename, self.untitled = path, nil; self:save() end, self:assets_dir())
  end
  local f = io.open(self.filename, "wb")
  if not f then core.error("can't write %s", self.filename) return end
  f:write(B.to_lua(self.d))
  f:close()
  self.dirty = false
  core.log("Saved %s", self:get_name())
  self:flash("Saved")
end

-- where the game open reads its files: a script's games/common/, a folder's assets/
function BView:assets_dir()
  local hf = rawget(_G, "host_world_file")
  local f = hf and hf()
  if not f then return nil end
  f = f:gsub("\\", "/"):gsub("/+$", "")
  if f:match("%.lua$") or f:match("%.hurdy$") then return (f:match("^(.*)/[^/]*$") or ".") .. "/common" end
  return f .. "/assets"
end
-- import: another file's patterns and ships (names taken get a number)
function BView:import()
  local common = require "core.common"
  core.command_view:set_text((self:assets_dir() or ".") .. "/")
  core.command_view:enter("Import patterns and ships from", function(text)
    local other, err = read(text)
    if not other then core.error("can't import %s: %s", text, tostring(err)) return end
    local np, ns
    self:edit(function(d) np, ns = B.import(d, other) end)
    self:flash(string.format("Imported %d patterns, %d ships", np, ns))
  end, common.path_suggest)
end

-- renames: a pattern's or a ship's new name, everywhere it's used
local function rename_pattern(d, old, new)
  for _, p in ipairs(d.patterns) do if p.split and p.split.pattern == old then p.split.pattern = new end end
  for _, e in ipairs(d.enemies) do if e.pattern == old then e.pattern = new end end
  for _, w in ipairs(d.waves) do if w.pattern == old then w.pattern = new end end
  for _, ph in ipairs(d.boss and d.boss.phases or {}) do
    for i, n in ipairs(ph.patterns or {}) do if n == old then ph.patterns[i] = new end end
  end
end
local function rename_ship(d, old, new)
  for _, w in ipairs(d.waves) do if w.enemy == old then w.enemy = new end end
end

-- the preview -------------------------------------------------------------
function BView:restart()
  self.t = 0
  self.done = false
  self.stage = B.stage_new(self.d, 1)              -- (the stage: runtime/bullets.lua's, as games play it)
  self.st = self.stage.bul                         -- (the bullets: the stage's, or the pattern shown)
  if self.mode == "pattern" then
    local p = self.sel and self.sel[1] == "pattern" and self:selected()
    local F = B.field(self.d)
    if p then B.emit(self.st, p.name, 0, -F.h / 4, "preview") end
  end
  core.redraw = true
end
function BView:advance(dt)
  self.t = self.t + dt
  if self.mode == "stage" then
    local b = self.stage.boss                      -- (no player shooting here: the boss weakens by itself, a few seconds a phase)
    if b and b.in_ and b.hp > 0 then
      b.hp = math.max(0, b.hp - b.max * dt / (7 * math.max(1, #(self.d.boss and self.d.boss.phases or {}))))
    end
    for _, ev in ipairs(B.stage_step(self.d, self.stage, dt, self.target.x, self.target.y)) do
      if ev[1] == "beaten" or ev[1] == "done" then self.done = true end
    end
  else
    if #self.st.emitters == 0 and #self.st.bullets == 0 then self:restart() end   -- (a pattern that ends: again)
    B.step(self.d, self.st, dt, self.target.x, self.target.y)
  end
end
function BView:seek(t)                             -- (the stage: played again from the start, quickly)
  self:restart()
  while self.t < t do self:advance(1 / 30) end
end

function BView:update()
  BView.super.update(self)
  local now = system.get_time()
  if self.playing then
    local dt = math.min(0.05, now - (self.last or now)) * self.speed
    self.last = now
    if dt > 0 then self:advance(dt) end
    core.redraw = true
  else self.last = nil end
  if now >= (BView.next_check or 0) then
    BView.next_check = now + 0.5
    if P.changed("config") then load_config() end
    if P.changed("files") then P.open_with(P.read("files") or {}, BView) end
  end
end

-- the panels -----------------------------------------------------------
function BView:rects()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local lw = math.floor(math.min(S(220), w * 0.24))
  local rw = math.floor(math.min(S(300), w * 0.34))
  return { left = { x, y, lw, h }, right = { x + w - rw, y, rw, h }, mid = { x + lw, y, w - lw - rw, h } }
end
function BView:fit()
  local r = self:rects().mid
  local F = B.field(self.d)
  local z = math.min(r[3] / (F.w + 60), r[4] / (F.h + 60)) / SCALE
  self.cam.zoom = math.max(self.zoom_min, math.min(self.zoom_max, z))
  self.cam.x = r[1] - self.position.x + r[3] / 2
  self.cam.y = r[2] - self.position.y + r[4] / 2
  self.fitting = true
  self.fit_w, self.fit_h = self.size.x, self.size.y
  core.redraw = true
end

function BView:draw_left(r)
  local ui, d, sel = self.left, self.d, self.sel or {}
  ui:begin(r[1], r[2], r[3], r[4], { divider_right = true })
  local function rows(kind, list, label, info)
    local t = {}
    for i, x in ipairs(list) do
      t[#t + 1] = { text = label(x, i), info = info and info(x) or nil, selected = sel[1] == kind and sel[2] == i,
                    press = function() self:select(kind, i) end,
                    button = { "x", function() self:remove(kind, i) end, tip = "Delete" } }
    end
    ui:list(t)
  end
  ui:head("Patterns")
  rows("pattern", d.patterns, function(p) return p.name or "?" end, function(p) return B.get(p, "kind") end)
  ui:buttons({ { "+ Pattern", function() self:add("pattern") end }, { "Duplicate", self.sel and self.sel[1] == "pattern" and function() self:add("pattern", true) end or nil } })
  ui:head("Ships")
  rows("ship", d.enemies, function(e) return e.name or "?" end, function(e) return e.pattern end)
  ui:buttons({ { "+ Ship", function() self:add("ship") end } })
  ui:head("Waves")
  rows("wave", d.waves, function(w) return string.format("%gs  %s x%d", w.at or 0, w.enemy or "?", w.count or 1) end, function(w) return w.path end)
  ui:buttons({ { "+ Wave", function() self:add("wave") end } })
  ui:head("Boss")
  if d.boss then
    ui:list({ { text = string.format("hp %d, %d phases", d.boss.hp or 0, #(d.boss.phases or {})), selected = sel[1] == "boss",
                press = function() self:select("boss", 1) end, button = { "x", function() self:remove("boss", 1) end, tip = "No boss" } } })
  else ui:buttons({ { "+ Boss", function() self:add("boss") end } }) end
  ui:buttons({ { "Import from...", function() self:import() end, tip = "Another .bullets file's patterns and ships, added to these" } })
  ui:head("Play field")
  local F = B.field(d)
  ui:slider("Width", F.w, 320, 1600, function(v) self:edit(function(dd) dd.field = dd.field or {}; dd.field.w = math.floor(v / 10 + 0.5) * 10; dd.field.h = dd.field.h or F.h end, true) end,
            { fmt = "%d px", step = 20, def = 800, done = function() self.holding = false; self:restart() end })
  ui:slider("Height", F.h, 240, 1200, function(v) self:edit(function(dd) dd.field = dd.field or {}; dd.field.h = math.floor(v / 10 + 0.5) * 10; dd.field.w = dd.field.w or F.w end, true) end,
            { fmt = "%d px", step = 20, def = 600, done = function() self.holding = false; self:restart() end })
  ui:space()
  ui:head("Preview")
  ui:choice("Show", self.mode, { "pattern", "stage" }, function(v) self.mode = v; self:restart() end)
  ui:buttons({ { self.playing and "Pause" or "Play", function() self.playing = not self.playing end, accent = not self.playing },
               { "Restart", function() self:restart() end } })
  ui:slider("Speed", self.speed, 0.1, 3, function(v) self.speed = v end, { fmt = "x%.2f", def = 1, step = 0.1 })
  if self.mode == "stage" then
    ui:slider("Time", self.t, 0, 120, function(v) self:seek(v) end, { fmt = "%.1f s", step = 1 })
  end
  ui:label("Bullets", tostring(#self.st.bullets))
  ui:space()
  ui:buttons({ { self.dirty and "Save  CTRL+S" or "Saved", function() self:save() end, accent = self.dirty } })
  ui:finish()
end

function BView:add(kind, dup)
  self:edit(function(d)
    if kind == "pattern" then
      local p = dup and copy(self:selected()) or { kind = "ring", count = 12, rate = 1, speed = 140, color = "#ff7ab0" }
      p.name = unique(d.patterns, dup and p.name or "pattern")
      d.patterns[#d.patterns + 1] = p
      self.sel = { "pattern", #d.patterns }
      self.mode = "pattern"
    elseif kind == "ship" then
      d.enemies[#d.enemies + 1] = { name = unique(d.enemies, "ship"), hp = 3, score = 100, size = 40, speed = 140, pattern = d.patterns[1] and d.patterns[1].name }
      self.sel = { "ship", #d.enemies }
    elseif kind == "wave" then
      local last = d.waves[#d.waves]
      d.waves[#d.waves + 1] = { at = (last and last.at or 0) + 4, enemy = d.enemies[1] and d.enemies[1].name, count = 5, gap = 0.4, path = "down", x = 0 }
      self.sel = { "wave", #d.waves }
    elseif kind == "boss" then
      d.boss = { hp = 300, size = 150, score = 5000, phases = { { hp = 1, patterns = { d.patterns[1] and d.patterns[1].name } } } }
      self.sel = { "boss", 1 }
    end
  end)
end
function BView:remove(kind, i)
  self:edit(function(d)
    if kind == "pattern" then table.remove(d.patterns, i)
    elseif kind == "ship" then table.remove(d.enemies, i)
    elseif kind == "wave" then table.remove(d.waves, i)
    elseif kind == "boss" then d.boss = nil end
  end)
  if self.sel and self.sel[1] == kind and (kind == "boss" or self.sel[2] >= i) then self.sel = nil end
end

function BView:draw_right(r)
  local ui, d, x = self.right, self.d, self:selected()
  ui:begin(r[1], r[2], r[3], r[4])
  local kind = self.sel and self.sel[1]
  local function done() self.holding = false; self:restart() end
  local function num(label, t, k, min, max, def, o)
    o = o or {}
    o.done, o.def = done, def
    local v = t[k]
    if v == nil then v = def end
    ui:slider(label, v, min, max, function(nv) self:edit(function() t[k] = o.int and math.floor(nv + 0.5) or nv end, true) end, o)
  end
  local function choose(label, t, k, options, def)
    local v = t[k]
    if v == nil then v = def end
    ui:choice(label, v, options, function(nv) self:edit(function() t[k] = nv end) end)
  end
  local function check(label, t, k)
    ui:check(label, t[k] == true, function() self:edit(function() t[k] = not t[k] or nil end) end)
  end
  if not x then
    ui:head("Nothing selected")
    ui:text("Pick a pattern, a ship, a wave")
    ui:text("or the boss on the left.")
    ui:finish()
    return
  end
  if kind == "pattern" then
    local p, DF = x, B.DEFAULTS
    ui:head("Pattern")
    ui:field("Name", p.name, function(v)
      v = v:gsub("%s+", "_")
      if v == "" or v == p.name or B.pattern(d, v) then return end
      local old = p.name
      self:edit(function(dd) p.name = v; rename_pattern(dd, old, v) end)
    end, { key = "pname" })
    choose("Kind", p, "kind", B.KINDS, DF.kind)
    num("Count", p, "count", 1, 64, DF.count, { fmt = "%d", int = true, step = 1 })
    if B.get(p, "kind") ~= "ring" then num("Spread", p, "spread", 0, 360, DF.spread, { fmt = "%.0f deg", step = 5 }) end
    check("Aim at the player", p, "aim")
    if not p.aim then num("Angle", p, "angle", -180, 360, DF.angle, { fmt = "%.0f deg", step = 5 }) end
    num("Spin", p, "spin", -720, 720, DF.spin, { fmt = "%.0f deg/s", step = 5 })
    ui:head("Timing")
    num("Rate", p, "rate", 0.1, 30, DF.rate, { fmt = "%.2f /s", step = 0.1 })
    num("Volleys", p, "volleys", 0, 50, DF.volleys, { fmt = "%d (0: always)", int = true, step = 1 })
    num("Delay", p, "delay", 0, 5, DF.delay, { fmt = "%.2f s", step = 0.05 })
    ui:head("Motion")
    num("Speed", p, "speed", 0, 800, DF.speed, { fmt = "%.0f", step = 5 })
    num("Accel", p, "accel", -600, 600, DF.accel, { fmt = "%.0f", step = 5 })
    num("Curve", p, "curve", -360, 360, DF.curve, { fmt = "%.0f deg/s", step = 5 })
    num("Life", p, "life", 0.5, 20, DF.life, { fmt = "%.1f s", step = 0.5 })
    ui:head("Look")
    num("Size", p, "size", 2, 40, DF.size, { fmt = "%.0f px", step = 1 })
    ui:color("Colour", hex_rgb(B.get(p, "color")), function(c) self:edit(function() p.color = rgb_hex(c) end, true) end, { done = done })
    choose("Sprite", p, "sprite", B.SPRITES, DF.sprite)
    ui:head("Split")
    ui:check("Bursts into another", type(p.split) == "table", function()
      self:edit(function() if p.split then p.split = nil else p.split = { at = 1, pattern = (d.patterns[1] ~= p and d.patterns[1] or d.patterns[2] or p).name } end end)
    end)
    if type(p.split) == "table" then
      num("At", p.split, "at", 0.1, 5, 1, { fmt = "%.2f s", step = 0.05 })
      local opts = {}
      for _, q in ipairs(d.patterns) do if q ~= p then opts[#opts + 1] = q.name end end
      if #opts > 0 then choose("Into", p.split, "pattern", opts, opts[1]) end
    end
  elseif kind == "ship" then
    local e = x
    ui:head("Ship")
    ui:field("Name", e.name, function(v)
      v = v:gsub("%s+", "_")
      if v == "" or v == e.name or B.enemy(d, v) then return end
      local old = e.name
      self:edit(function(dd) e.name = v; rename_ship(dd, old, v) end)
    end, { key = "sname" })
    num("HP", e, "hp", 1, 200, 3, { fmt = "%d", int = true, step = 1 })
    num("Score", e, "score", 0, 5000, 100, { fmt = "%d", int = true, step = 50 })
    num("Size", e, "size", 10, 120, 40, { fmt = "%.0f px", step = 2 })
    num("Speed", e, "speed", 10, 400, 140, { fmt = "%.0f", step = 5 })
    if #d.patterns > 0 then choose("Fires", e, "pattern", names(d.patterns), d.patterns[1].name) end
  elseif kind == "wave" then
    local w = x
    ui:head("Wave")
    num("At", w, "at", 0, 300, 0, { fmt = "%.1f s", step = 0.5 })
    if #d.enemies > 0 then choose("Ship", w, "enemy", names(d.enemies), d.enemies[1].name) end
    num("Count", w, "count", 1, 30, 1, { fmt = "%d", int = true, step = 1 })
    num("Gap", w, "gap", 0, 2, 0, { fmt = "%.2f s", step = 0.05 })
    choose("Path", w, "path", B.PATHS, "down")
    num("X", w, "x", -400, 400, 0, { fmt = "%.0f", step = 10 })
    if w.path == "sweep" then num("Height", w, "y", -300, 300, -150, { fmt = "%.0f", step = 10 }) end
    num("Spacing", w, "spacing", -200, 200, 0, { fmt = "%.0f", step = 10 })
    check("Mirrored (every other)", w, "mirror")
    local opts = names(d.patterns, "(the ship's)")
    ui:choice("Fires", w.pattern or "(the ship's)", opts, function(v) self:edit(function() w.pattern = v ~= "(the ship's)" and v or nil end) end)
  elseif kind == "boss" then
    local b = x
    b.phases = b.phases or {}
    ui:head("Boss")
    num("HP", b, "hp", 10, 3000, 300, { fmt = "%d", int = true, step = 10 })
    num("Size", b, "size", 40, 300, 150, { fmt = "%.0f px", step = 5 })
    num("Score", b, "score", 0, 50000, 5000, { fmt = "%d", int = true, step = 500 })
    for pi, ph in ipairs(b.phases) do
      ui:head("Phase " .. pi)
      num("From hp", ph, "hp", 0, 1, 1, { fmt = "%.2f of all", step = 0.05 })
      ph.patterns = ph.patterns or {}
      for k, name in ipairs(ph.patterns) do
        ui:choice("Fires", name, names(d.patterns), function(v) self:edit(function() ph.patterns[k] = v end) end)
      end
      ui:buttons({ { "+ Pattern", #d.patterns > 0 and function() self:edit(function() ph.patterns[#ph.patterns + 1] = d.patterns[1].name end) end or nil },
                   { "- Pattern", #ph.patterns > 0 and function() self:edit(function() table.remove(ph.patterns) end) end or nil },
                   { "Delete phase", function() self:edit(function() table.remove(b.phases, pi) end) end } })
    end
    ui:buttons({ { "+ Phase", function()
      self:edit(function() local last = b.phases[#b.phases]; b.phases[#b.phases + 1] = { hp = math.max(0.05, (last and last.hp or 1) - 0.33), patterns = {} } end)
    end } })
  end
  ui:finish()
end

-- the canvas: the play field, the target, the ships, the bullets
function BView:draw_background_color() return cfg.background == "light" and { 220, 220, 220, 255 } or style.background end
function BView:draw_canvas()
  local z = self:z()
  local F = B.field(self.d)
  local x0, y0 = self:to_screen(-F.w / 2, -F.h / 2)
  local x1, y1 = self:to_screen(F.w / 2, F.h / 2)
  renderer.draw_rect(x0, y0, x1 - x0, y1 - y0, { 10, 12, 24, 255 })
  local edge = { style.dim[1], style.dim[2], style.dim[3], 120 }
  renderer.draw_rect(x0, y0, x1 - x0, 1, edge); renderer.draw_rect(x0, y1, x1 - x0, 1, edge)
  renderer.draw_rect(x0, y0, 1, y1 - y0, edge); renderer.draw_rect(x1, y0, 1, y1 - y0, edge)
  local function tri(x, y, s, c, up)               -- a ship: a triangle
    local sx, sy = self:to_screen(x, y)
    local h = s * z / 2
    local dy = up and -h or h
    D.line(sx - h * 0.7, sy - dy * 0.6, sx, sy + dy, c, math.max(1, 2 * z))
    D.line(sx + h * 0.7, sy - dy * 0.6, sx, sy + dy, c, math.max(1, 2 * z))
    D.line(sx - h * 0.7, sy - dy * 0.6, sx + h * 0.7, sy - dy * 0.6, c, math.max(1, 2 * z))
  end
  if self.mode == "stage" then
    for _, s in ipairs(self.stage.ships) do tri(s.x, s.y, s.size, { 120, 200, 255, 255 }, false) end
    local b = self.stage.boss
    if b and not self.done then
      local bs = (self.d.boss and self.d.boss.size or 150) * z
      local bx, by = self:to_screen(b.x, b.y)
      D.disc(bx, by, bs, { 120, 100, 90, 255 })
      renderer.draw_text(style.font, "phase " .. b.phase, bx - S(24), by - S(8), style.text)
    end
  else
    local ex, ey = self:to_screen(0, -F.h / 4)      -- the emitter: a cross
    local c = { style.dim[1], style.dim[2], style.dim[3], 220 }
    D.line(ex - S(8), ey, ex + S(8), ey, c, 1)
    D.line(ex, ey - S(8), ex, ey + S(8), c, 1)
  end
  for _, b in ipairs(self.st.bullets) do
    local p = B.pattern(self.d, b.p) or B.DEFAULTS
    local sx, sy = self:to_screen(b.x, b.y)
    local c = hex_rgb(B.get(p, "color"))
    c[4] = math.floor(255 * B.alpha(b))
    local s = math.max(2, B.get(p, "size") * z)
    if B.get(p, "sprite") == "shot" then
      local a = b.a * math.pi / 180
      D.line(sx - math.cos(a) * s * 0.6, sy - math.sin(a) * s * 0.6, sx + math.cos(a) * s * 0.6, sy + math.sin(a) * s * 0.6, c, math.max(1, s * 0.45))
    else D.disc(sx, sy, s, c) end
  end
  tri(self.target.x, self.target.y, 40, { 255, 170, 90, 255 }, true)   -- the player (drag it)
end
function BView:draw_overlay()
  local r = self:rects()
  local m = r.mid
  local name = self:get_name() .. (self.err and ("   can't read: " .. self.err) or "")
  renderer.draw_text(style.font, name, m[1] + S(12), m[2] + S(10), self.err and (style.error or style.text) or style.dim)
  renderer.draw_text(style.font, string.format("%.1f s   LMB: move the player   SPACE: pause", self.t), m[1] + S(12), m[2] + m[4] - S(24), style.dim)
  self:draw_left(r.left)
  self:draw_right(r.right)
end

-- the mouse: the panels first; on the canvas, LMB drags the player (the target)
function BView:on_mouse_pressed(button, x, y, clicks)
  if self.left:pressed(button, x, y, clicks) or self.right:pressed(button, x, y, clicks) then return true end
  return BView.super.on_mouse_pressed(self, button, x, y, clicks)
end
function BView:on_canvas_pressed(button, wx, wy, clicks)
  if button == "left" and clicks == 1 then self.moving = true; self.target.x, self.target.y = wx, wy; return true end
  return false
end
function BView:on_mouse_moved(x, y, dx, dy)
  if self.left:moved(x, y) or self.right:moved(x, y) then return end
  if self.moving then self.target.x, self.target.y = self:to_world(x, y); return end
  BView.super.on_mouse_moved(self, x, y, dx, dy)
end
function BView:on_mouse_released(button, x, y)
  if self.left:released(button) or self.right:released(button) then return end
  self.moving = nil
  BView.super.on_mouse_released(self, button, x, y)
end
function BView:on_mouse_wheel(dy, dx)
  if self.right:wheel(dy) or self.left:wheel(dy) then return true end
  return BView.super.on_mouse_wheel(self, dy, dx)
end

function BView:menu_items()
  local DIV = require("plugins.contextmenu").DIVIDER
  return {
    { text = self.playing and "Pause" or "Play", info = "SPACE", command = function() self.playing = not self.playing end },
    { text = "Restart", command = function() self:restart() end },
    { text = self.mode == "stage" and "Show the pattern" or "Play the stage", command = function() self.mode = self.mode == "stage" and "pattern" or "stage"; self:restart() end, tags = "preview;waves;boss" },
    { text = "Save", info = "CTRL+S", command = function() self:save() end },
    DIV,
    { text = "New pattern", command = function() self:add("pattern") end, tags = "add;emitter" },
    { text = "New ship", command = function() self:add("ship") end, tags = "add;enemy" },
    { text = "New wave", command = function() self:add("wave") end, tags = "add" },
    { text = "Import patterns and ships from...", command = function() self:import() end, tags = "merge;copy;load" },
    DIV,
    { text = "Undo", info = "CTRL+Z", command = function() self:undo_step(true) end },
    { text = "Redo", info = "CTRL+Y", command = function() self:undo_step(false) end },
    { text = "Fit", info = "dbl-click", command = function() self:fit() end },
  }
end

command.add(function() return core.active_view and core.active_view:is(BView) end, {
  ["bullets:play"] = function() local v = core.active_view; v.playing = not v.playing end,
  ["bullets:undo"] = function() core.active_view:undo_step(true) end,
  ["bullets:redo"] = function() core.active_view:undo_step(false) end,
})
if not package.loaded["bullets.keys"] then
  package.loaded["bullets.keys"] = true
  keymap.add { ["space"] = "bullets:play", ["ctrl+z"] = "bullets:undo", ["ctrl+y"] = "bullets:redo" }
end

load_config()
P.open_with(P.read("files") or {}, BView)
P.commands = { { "Play / pause", "bullets:play" }, { "Undo", "bullets:undo" }, { "Redo", "bullets:redo" }, { "Save", "canvas:save" } }
P.tab = function() return BView({}) end            -- (the main menu's Plugins >: a new file, untitled)
return BView

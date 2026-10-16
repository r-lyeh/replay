-- genview.lua - a generator's tab (Replay): the settings on the right, what
-- they make in the middle at once (a tile map, drawn with its tileset), on
-- the left what it made and the file it writes. Saving writes the settings
-- and the map: a .tmap the tilemap editor opens, marked as made here
-- (plugins/chain: Regenerate, Open source there). Undo / redo, New seed.
-- plugins/dungeon and plugins/terrain are made of it.
--
--   return require("plugins.genview").make(P, G, {
--     ext = "dungeon",                            -- the settings' extension (makes .tmap)
--     head = "Dungeon",                           -- the left panel's heading
--     info = function(view, ui) end,              -- (left) what it made: view.info (G.generate's second result)
--     panel = function(view, ui, num, edit) end,  -- (right) the settings: num(label, key, lo, hi, opts), edit(fn)
--   })
-- G (no Lite in it: a game could run it too): G.DEFAULTS, G.check(t) -> s,
-- G.generate(s) -> map data, info; G.output_of(s, path), G.settings_lua(s),
-- G.map_lua(data, made_by).
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local canvas = require "plugins.canvas"
local chain = require "plugins.chain"

local GV = {}
local function S(n) return math.floor(n * SCALE + 0.5) end
local function base_of(f) return (f:match("[^/\\]*$")) end
local function dir_of(f) return f:match("^(.*)[/\\]") or "." end
local function read(file)
  local f = io.open(file, "rb")
  if not f then return nil, "can't read" end
  local src = f:read("*a")
  f:close()
  local fn, err = load(src, "=" .. file, "t", {})
  if not fn then return nil, err end
  local ok, v = pcall(fn)
  if not ok or type(v) ~= "table" then return nil, ok and "not a table" or v end
  return v
end
local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
GV.read = read

function GV.make(P, G, o)
  local ext = o.ext
  -- the chain: a .<ext> makes a .tmap (written beside it, marked made_by)
  local function build(path)
    local t, err = read(path)
    if not t then return nil, err end
    local s = G.check(t)
    local data = G.generate(s)
    local out = G.output_of(s, path)
    local f = io.open(out, "wb")
    if not f then return nil, "can't write " .. out end
    f:write(G.map_lua(data, base_of(path)))
    f:close()
    return out
  end
  chain.register { ext = ext, key = ext, name = P.title, makes = "tmap", build = build }

  local V = canvas.View:extend()
  V.grid = nil
  V.zoom_min, V.zoom_max = 0.05, 8
  V.build = build

  function V:new(state)
    V.super.new(self)
    self.filename = state and state.filename or ""
    self.untitled = state and state.untitled or self.filename == ""
    self.left, self.right = canvas.ui.new(), canvas.ui.new()
    self.undo, self.redo = {}, {}
    local t, err = read(self.untitled and (P.dir .. "/templates/" .. ext .. "." .. ext) or self.filename)
    self.err = not t and err or nil
    self.s = G.check(t)
    self:make()
    if state and state.cam then self:set_camera(state.cam) end
  end
  function V:get_name() return (self.untitled and ("untitled." .. ext) or base_of(self.filename)) .. (self.dirty and "*" or "") end
  function V:get_state() return { filename = self.filename, untitled = self.untitled, cam = self:camera_state() } end
  function V:bounds() return 0, 0, self.data.w * 16, self.data.h * 16 end

  function V:make()                                -- the preview: the map, as cells
    local data, info = G.generate(self.s)
    self.data, self.info = data, info or {}
    self.cells = {}
    for li, l in ipairs(data.layers) do
      local layer = {}
      for y, row in ipairs(l.rows) do
        for x = 1, data.w do
          local hx = row:sub(x * 2 - 1, x * 2)
          if hx ~= ".." then layer[(y - 1) * data.w + x] = tonumber(hx, 16) end
        end
      end
      self.cells[li] = layer
    end
    local ts = self.s.tileset or "plugin:tiles.png"
    local path = ts:match("^plugin:") and (P.dir .. "/../tilemap/" .. ts:sub(8)) or (dir_of(self.filename) .. "/" .. ts)
    if path ~= self.img_path then
      self.img_path = path
      self.img = renderer.image.load(path) or renderer.image.load(P.dir .. "/../tilemap/tiles.png")
    end
    core.redraw = true
  end
  function V:edit(fn, held)
    if not held or not self.holding then
      self.undo[#self.undo + 1] = copy(self.s)
      if #self.undo > 200 then table.remove(self.undo, 1) end
      self.redo = {}
    end
    self.holding = held
    fn(self.s)
    self.s = G.check(self.s)
    self.dirty = true
    self:make()
  end
  function V:undo_step(back)
    local from, to = back and self.undo or self.redo, back and self.redo or self.undo
    if #from == 0 then return end
    to[#to + 1] = copy(self.s)
    self.s = G.check(table.remove(from))
    self.dirty = true
    self:make()
  end
  function V:reroll() self:edit(function(t) t.seed = math.random(1, 999999) end) end
  function V:map_path() return (G.output_of(self.s, self.untitled and ("untitled." .. ext) or self.filename)) end
  function V:save()                                -- the settings, and the map they make
    if self.untitled then
      return canvas.save_as(ext, function(path) self.filename, self.untitled = path, nil; self:save() end)
    end
    local f = io.open(self.filename, "wb")
    if not f then core.error("can't write %s", self.filename) return end
    f:write(G.settings_lua(self.s))
    f:close()
    local out, err = build(self.filename)
    self.dirty = false
    if not out then core.error("%s: %s", ext, tostring(err)); self:flash("Saved; the map: " .. tostring(err), true) return end
    core.log("Saved %s and made %s", self:get_name(), base_of(out))
    self:flash("Saved; made " .. base_of(out))
    for _, v in ipairs(core.root_view.root_node:get_children()) do   -- (an open tab of that map: read again)
      if v.filename and v.reload and (system.absolute_path(v.filename) or v.filename) == (system.absolute_path(out) or out) and not v.dirty then v:reload() end
    end
  end
  function V:open_map()
    local out = self:map_path()
    if not system.get_file_info(out) then self:save() end
    if system.get_file_info(out) then require("plugins.openwith").open("tilemap", out) end
  end

  -- the panels ---------------------------------------------------------
  function V:rects()
    local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
    local lw = math.floor(math.min(S(200), w * 0.22))
    local rw = math.floor(math.min(S(280), w * 0.32))
    return { left = { x, y, lw, h }, right = { x + w - rw, y, rw, h }, mid = { x + lw, y, w - lw - rw, h } }
  end
  function V:fit()
    local r = self:rects().mid
    local W, H = self.data.w, self.data.h
    local z = math.min(r[3] / (W * 16 + 32), r[4] / (H * 16 + 32)) / SCALE
    self.cam.zoom = math.max(self.zoom_min, math.min(self.zoom_max, z))
    self.cam.x = r[1] - self.position.x + r[3] / 2 - W * 8 * self.cam.zoom * SCALE
    self.cam.y = r[2] - self.position.y + r[4] / 2 - H * 8 * self.cam.zoom * SCALE
    self.fitting = true
    self.fit_w, self.fit_h = self.size.x, self.size.y
    core.redraw = true
  end

  function V:draw_left(r)
    local ui = self.left
    ui:begin(r[1], r[2], r[3], r[4], { divider_right = true })
    ui:head(o.head or P.title)
    if o.info then o.info(self, ui) end
    ui:label("Size", self.data.w .. " x " .. self.data.h)
    ui:space()
    ui:head("Makes")
    ui:label("Map", base_of(self:map_path()))
    ui:buttons({ { self.dirty and "Save and make  CTRL+S" or "Make again", function() self:save() end, accent = self.dirty } })
    ui:buttons({ { "Open the map", function() self:open_map() end, tip = "In the tilemap editor (it can regenerate it from here)" } })
    ui:space()
    ui:text("Hand edits to the map")
    ui:text("go when it's made again.")
    ui:finish()
  end
  function V:draw_right(r)
    local ui, s = self.right, self.s
    ui:begin(r[1], r[2], r[3], r[4])
    local function done() self.holding = false end
    local function num(label, k, lo, hi, opts)
      opts = opts or {}
      opts.done, opts.def = done, G.DEFAULTS[k]
      ui:slider(label, s[k], lo, hi, function(v) self:edit(function(t) t[k] = opts.int and math.floor(v + 0.5) or v end, true) end, opts)
    end
    local function edit(fn) self:edit(fn) end
    if s.seed then
      ui:head("Seed")
      ui:stepper("Seed", s.seed, function() self:edit(function(t) t.seed = t.seed - 1 end) end, function() self:edit(function(t) t.seed = t.seed + 1 end) end)
      ui:buttons({ { "New seed", function() self:reroll() end } })
    end
    o.panel(self, ui, num, edit)
    ui:head("Files")
    ui:field("Map", s.output or "", function(v) self:edit(function(t) t.output = v ~= "" and v or nil end) end, { key = "output", tip = "The .tmap it writes, beside it (empty: its own name)" })
    if G.DEFAULTS.tileset then
      ui:field("Tileset", s.tileset, function(v) self:edit(function(t) t.tileset = v ~= "" and v or G.DEFAULTS.tileset end) end, { key = "tileset", tip = "plugin:tiles.png (the tilemap plugin's), or a picture beside the map" })
    end
    ui:finish()
  end

  function V:draw_canvas()
    local z = self:z()
    local cs = 16 * z
    local ox, oy = self:to_screen(0, 0)
    local W, H = self.data.w, self.data.h
    renderer.draw_rect(ox, oy, W * cs, H * cs, { 0, 0, 0, 120 })
    local r = self:rects().mid
    local x0 = math.max(0, math.floor((r[1] - ox) / cs))
    local y0 = math.max(0, math.floor((r[2] - oy) / cs))
    local x1 = math.min(W - 1, math.floor((r[1] + r[3] - ox) / cs))
    local y1 = math.min(H - 1, math.floor((r[2] + r[4] - oy) / cs))
    if self.img then
      for _, layer in ipairs(self.cells) do
        for y = y0, y1 do
          for x = x0, x1 do
            local c = layer[y * W + x + 1]
            if c then
              renderer.draw_image(self.img, math.floor(ox + x * cs), math.floor(oy + y * cs), math.ceil(cs), math.ceil(cs), nil,
                                  (c % 16) * 16, math.floor(c / 16) * 16, 16, 16)
            end
          end
        end
      end
    end
    local e = style.dim
    renderer.draw_rect(ox, oy, W * cs, 1, e); renderer.draw_rect(ox, oy + H * cs, W * cs, 1, e)
    renderer.draw_rect(ox, oy, 1, H * cs, e); renderer.draw_rect(ox + W * cs, oy, 1, H * cs + 1, e)
  end
  function V:draw_overlay()
    local r = self:rects()
    local m = r.mid
    renderer.draw_text(style.font, self:get_name() .. (self.err and ("   can't read: " .. self.err) or ""), m[1] + S(12), m[2] + S(10),
                       self.err and (style.error or style.text) or style.dim)
    self:draw_left(r.left)
    self:draw_right(r.right)
  end

  function V:on_mouse_pressed(button, x, y, clicks)
    if self.left:pressed(button, x, y, clicks) or self.right:pressed(button, x, y, clicks) then return true end
    return V.super.on_mouse_pressed(self, button, x, y, clicks)
  end
  function V:on_mouse_moved(x, y, dx, dy)
    if self.left:moved(x, y) or self.right:moved(x, y) then return end
    V.super.on_mouse_moved(self, x, y, dx, dy)
  end
  function V:on_mouse_released(button, x, y)
    if self.left:released(button) or self.right:released(button) then return end
    V.super.on_mouse_released(self, button, x, y)
  end
  function V:on_mouse_wheel(dy, dx)
    if self.right:wheel(dy) or self.left:wheel(dy) then return true end
    return V.super.on_mouse_wheel(self, dy, dx)
  end
  function V:menu_items()
    local DIV = require("plugins.contextmenu").DIVIDER
    return {
      { text = "Save and make the map", info = "CTRL+S", command = function() self:save() end, tags = "generate;build" },
      { text = "Open the map", command = function() self:open_map() end, tags = "tilemap;tmap" },
      { text = "New seed", command = function() self:reroll() end, tags = "random;reroll" },
      DIV,
      { text = "Undo", info = "CTRL+Z", command = function() self:undo_step(true) end },
      { text = "Redo", info = "CTRL+Y", command = function() self:undo_step(false) end },
      { text = "Fit", info = "dbl-click", command = function() self:fit() end },
    }
  end

  command.add(function() return core.active_view and core.active_view:is(V) end, {
    [ext .. ":undo"] = function() core.active_view:undo_step(true) end,
    [ext .. ":redo"] = function() core.active_view:undo_step(false) end,
    [ext .. ":reroll"] = function() core.active_view:reroll() end,
  })
  if not package.loaded[ext .. ".keys"] then
    package.loaded[ext .. ".keys"] = true
    keymap.add { ["ctrl+z"] = ext .. ":undo", ["ctrl+y"] = ext .. ":redo" }
  end

  P.open_with(P.read("files") or {}, V)
  P.commands = { { "New seed", ext .. ":reroll" }, { "Undo", ext .. ":undo" }, { "Redo", ext .. ":redo" }, { "Save and make", "canvas:save" } }
  P.tab = function() return V({}) end
  return V
end

return GV

-- editor.lua - the atlas packer (runs in lite; see
-- editor/3rd/lite/data/plugins/projectplugins.lua for what P gives). An atlas is two
-- files: <name>.atlas.lua (what it packs, how, and where each image went: the
-- game reads it) and <name>.atlas.png (the sheet; no *.atlas.png is packed). Its tab:
--
--   [toolbar]  + Add...  Remove   Save (CTRL+S)                 Fit  100%  Text
--   [sprites: each source (a file,   [the sheet]   [settings: padding, max size,
--    a folder, ships/*.png) and its                 power of two, rotate; the
--    images; the ones left out]                     output; the selected one]
--
-- Edits (add, remove, settings) change the .atlas.lua's text (unsaved, as
-- typing would; undo there undoes them); it packs again at once, and when
-- the images change on disk. CTRL+S writes the sheet and, in the .atlas.lua,
-- where each image went (frames). Its tab's icon (plugins/tabflip) flips it
-- to that text and back. Packing: MaxRects, best short side fit, the
-- biggest first, turned a quarter when that fits better (rotate = true);
-- the sheet the smallest that fits.
local P = ...
P.title = "Atlas packer"                      -- (its name in menus: Open with, the main menu's Plugins)
local core = require "core"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local canvas = require "plugins.canvas"
local D = canvas.draw

local DEFAULTS = { padding = 2, power_of_two = true, max_size = 2048, rotate = false, checker = 1.5 }
local SETTINGS = { "padding", "max_size", "power_of_two", "rotate" }   -- (an atlas's own: written in its file)
local cfg = {}
local function load_config()
  local c = P.read("config")
  cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if type(c) == "table" then for k, v in pairs(c) do if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then cfg[k] = v end end end
end
load_config()

local IMAGES = { png = true, jpg = true, jpeg = true, bmp = true, tga = true, gif = true }

local function norm(f) return (f:gsub("\\", "/")) end
local function dir_of(f) return f:match("^(.*)/") or "." end
local function base_of(f) return (f:match("[^/]*$")) end
local function ext(f) return (f:match("%.([^%./]+)$") or ""):lower() end
local function mtime(f) local i = system.get_file_info(f) return i and i.modified end
local function glob(pat)                           -- "ships*.png" -> a Lua pattern, whole name
  return "^" .. pat:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
end
local function is_atlas(f) return type(f) == "string" and f:lower():match("%.atlas%.lua$") ~= nil end
local function is_sheet(f) return f:lower():match("%.atlas%.png$") ~= nil end   -- (an atlas's sheet: never packed)
local function atlas_stem(f) return (base_of(f):gsub("%.[Aa][Tt][Ll][Aa][Ss]%.[Ll][Uu][Aa]$", "")) end

-- the game's path of a file ("/assets/...": below the folder named assets), and that folder
local function game_path(abs)
  local root, rest = abs:match("^(.*/assets)(/.*)$")
  if root then return "/assets" .. rest, root end
end

-- an atlas's text -> its table (data only: an empty sandbox), or nil, err
local function parse(src, name)
  local fn, err = load(src, "=" .. name, "t", {})
  if not fn then return nil, err end
  local ok, v = pcall(fn)
  if not ok then return nil, v end
  if type(v) ~= "table" then return nil, "not a table" end
  return v
end

-- its text again: a header, what it packs, the settings, what was written
local HEADER = [[
-- %s: a texture atlas (plugins/atlaspacker). Its tab packs `sources`
-- (files, folders, names with *; next to this file) but `exclude` into
-- `image`; CTRL+S there writes that sheet and `frames`: where each image
-- went (deg = 90: turned a quarter clockwise). In the game:
--   image = { "%s", frame = "ship" }   (a frame's path, or its end)]]
local function q(s) return string.format("%q", s) end
local function list_src(t)
  local out = {}
  for _, s in ipairs(t or {}) do out[#out + 1] = q(s) end
  return #out > 0 and ("{ " .. table.concat(out, ", ") .. " }") or "{}"
end
local HEADER_CUT = [[
-- %s: a texture atlas (plugins/atlaspacker), cut from one picture (`cut`):
-- each frame a named part of it, where it is. Its tab: Find segments (each
-- patch that shows, a frame), drag on the picture to add one, double-click
-- a name to rename it. In the game (`at = "sheet"`: drawn where it is in the
-- picture, the picture centred on the node; a Game & Watch's segments):
--   image = { "%s", frame = "man1", at = "sheet" }]]
local function to_text(spec, file)
  local L = {}
  if type(spec.cut) == "string" then                -- (cut: the picture, and its named parts)
    L[#L + 1] = string.format(HEADER_CUT, base_of(file), game_path(file) or base_of(file))
    L[#L + 1] = "return {"
    L[#L + 1] = "  cut = " .. q(spec.cut) .. ","
    if spec.image then L[#L + 1] = "  image = " .. q(spec.image) .. (spec.w and string.format(", w = %d, h = %d", spec.w, spec.h) or "") .. "," end
    L[#L + 1] = "  frames = {"
    for _, f in ipairs(type(spec.frames) == "table" and spec.frames or {}) do
      L[#L + 1] = string.format("    { name = %s, x = %d, y = %d, w = %d, h = %d },", q(tostring(f.name)), f.x or 0, f.y or 0, f.w or 0, f.h or 0)
    end
    L[#L + 1] = "  },"
    L[#L + 1] = "}"
    return table.concat(L, "\n") .. "\n"
  end
  L[#L + 1] = string.format(HEADER, base_of(file), game_path(file) or base_of(file))
  L[#L + 1] = "return {"
  L[#L + 1] = "  sources = " .. list_src(spec.sources) .. ","
  if spec.exclude and #spec.exclude > 0 then L[#L + 1] = "  exclude = " .. list_src(spec.exclude) .. "," end
  local set = {}
  for _, k in ipairs(SETTINGS) do
    local v = spec[k]
    if v == nil then v = cfg[k] end
    set[#set + 1] = k .. " = " .. tostring(v)
  end
  L[#L + 1] = "  " .. table.concat(set, ", ") .. ","
  if spec.image then L[#L + 1] = "  image = " .. q(spec.image) .. (spec.w and string.format(", w = %d, h = %d", spec.w, spec.h) or "") .. "," end
  if type(spec.frames) == "table" then
    L[#L + 1] = "  frames = {"
    for _, f in ipairs(spec.frames) do
      L[#L + 1] = string.format("    { path = %s, x = %d, y = %d, w = %d, h = %d, deg = %d },",
        q(tostring(f.path)), f.x or 0, f.y or 0, f.w or 0, f.h or 0, f.deg or 0)
    end
    L[#L + 1] = "  },"
  end
  L[#L + 1] = "}"
  return table.concat(L, "\n") .. "\n"
end

-- what it packs: { file = abs, rel = "rocks/big.png", src = i (its source) }...,
-- and the ones exclude leaves out (the same), each sorted by rel
local function sources(spec, base, outputs)
  local list, out, seen, ex = {}, {}, {}, {}
  for _, e in ipairs(type(spec.exclude) == "table" and spec.exclude or {}) do if type(e) == "string" then ex[e] = true end end
  local function add(file, rel, i)
    if seen[file] or not IMAGES[ext(file)] or outputs[file] or is_sheet(file) then return end
    seen[file] = true
    local it = { file = file, rel = rel, src = i }
    if ex[rel] then out[#out + 1] = it else list[#list + 1] = it end
  end
  local function add_dir(dir, prefix, i)          -- (a folder: its images, and its folders')
    local names = system.list_dir(dir) or {}
    table.sort(names)
    for _, e in ipairs(names) do
      local f = dir .. "/" .. e
      local info = system.get_file_info(f)
      if info and info.type == "dir" and e:sub(1, 1) ~= "." then add_dir(f, prefix .. e .. "/", i)
      elseif info then add(f, prefix .. e, i) end
    end
  end
  for i, s in ipairs(type(spec.sources) == "table" and spec.sources or {}) do
    if type(s) == "string" and s ~= "" then
      s = norm(s):gsub("/+$", "")
      local sub, name = s:match("^(.-)/?([^/]*)$")
      local abs = s:match("^%a:") or s:sub(1, 1) == "/"
      local dir = abs and sub or (sub ~= "" and (base .. "/" .. sub) or base)
      local prefix = (abs or sub == "") and "" or (sub .. "/")
      if name:find("*", 1, true) then
        local pat = glob(name)
        local names = system.list_dir(dir) or {}
        table.sort(names)
        for _, e in ipairs(names) do
          if e:match(pat) then add(dir .. "/" .. e, prefix .. e, i) end
        end
      else
        local f = dir .. "/" .. name
        local info = system.get_file_info(f)
        if info and info.type == "dir" then add_dir(f, prefix .. name .. "/", i)
        elseif info then add(f, prefix .. name, i) end
      end
    end
  end
  table.sort(list, function(a, b) return a.rel < b.rel end)
  table.sort(out, function(a, b) return a.rel < b.rel end)
  return list, out
end

-- MaxRects, best short side fit: rects { pw, ph } -> each .x, .y (.rot:
-- turned a quarter); false if they don't fit W x H
local function pack(rects, W, H, rotate)
  local free = { { x = 0, y = 0, w = W, h = H } }
  for _, r in ipairs(rects) do
    local best, bs, bl, brot
    for _, f in ipairs(free) do
      for turn = 0, (rotate and r.pw ~= r.ph) and 1 or 0 do
        local pw, ph = r.pw, r.ph
        if turn == 1 then pw, ph = ph, pw end
        if pw <= f.w and ph <= f.h then
          local a, b = f.w - pw, f.h - ph
          local s, l = math.min(a, b), math.max(a, b)
          if not best or s < bs or (s == bs and l < bl) then best, bs, bl, brot = f, s, l, turn == 1 end
        end
      end
    end
    if not best then return false end
    r.x, r.y, r.rot = best.x, best.y, brot
    local px, py, pw, ph = r.x, r.y, r.pw, r.ph
    if brot then pw, ph = ph, pw end
    local split = {}
    for _, f in ipairs(free) do                    -- every free rect it overlaps: what's left of it, around
      if px >= f.x + f.w or px + pw <= f.x or py >= f.y + f.h or py + ph <= f.y then split[#split + 1] = f
      else
        if px > f.x then split[#split + 1] = { x = f.x, y = f.y, w = px - f.x, h = f.h } end
        if px + pw < f.x + f.w then split[#split + 1] = { x = px + pw, y = f.y, w = f.x + f.w - px - pw, h = f.h } end
        if py > f.y then split[#split + 1] = { x = f.x, y = f.y, w = f.w, h = py - f.y } end
        if py + ph < f.y + f.h then split[#split + 1] = { x = f.x, y = py + ph, w = f.w, h = f.y + f.h - py - ph } end
      end
    end
    free = {}
    for i, a in ipairs(split) do                   -- (one inside another: gone; of two the same, one)
      local inside = false
      for j, b in ipairs(split) do
        if i ~= j and a.x >= b.x and a.y >= b.y and a.x + a.w <= b.x + b.w and a.y + a.h <= b.y + b.h
           and (i > j or not (a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h)) then inside = true break end
      end
      if not inside then free[#free + 1] = a end
    end
  end
  return true
end

-- the smallest sheet they fit in -> W, H (nil, why)
local function layout(rects, o)
  local pad = o.padding
  local area, mw, mh = 0, 0, 0
  for _, r in ipairs(rects) do
    r.pw, r.ph = r.w + pad, r.h + pad
    area = area + r.pw * r.ph
    if o.rotate then local m = math.min(r.pw, r.ph); mw, mh = math.max(mw, m), math.max(mh, m)
    else mw, mh = math.max(mw, r.pw), math.max(mh, r.ph) end
  end
  if #rects == 0 then return nil, "nothing to pack yet: + Add... (or drop images here)" end
  table.sort(rects, function(a, b)
    local ma, mb = math.max(a.w, a.h), math.max(b.w, b.h)
    if ma ~= mb then return ma > mb end
    if a.w * a.h ~= b.w * b.h then return a.w * a.h > b.w * b.h end
    return a.rel < b.rel
  end)
  local tries, max = {}, o.max_size
  if o.power_of_two then
    local sides = {}
    local s = 1
    while s <= max do sides[#sides + 1] = s; s = s * 2 end
    for _, w in ipairs(sides) do for _, h in ipairs(sides) do
      if w >= mw - pad and h >= mh - pad and w * h >= area * 0.98 and h <= w then tries[#tries + 1] = { w, h } end
    end end
    table.sort(tries, function(a, b) return a[1] * a[2] < b[1] * b[2] or (a[1] * a[2] == b[1] * b[2] and a[1] - a[2] < b[1] - b[2]) end)
  else
    local s = math.max(math.ceil(math.sqrt(area)), mw, mh)
    while s <= max do tries[#tries + 1] = { s, s }; s = s + math.max(1, math.ceil(s * 0.04)) end
    tries[#tries + 1] = { max, max }
  end
  for _, t in ipairs(tries) do
    if pack(rects, t[1] + pad, t[2] + pad, o.rotate) then   -- (the last column / row needs no padding)
      local W, H = t[1], t[2]
      if not o.power_of_two then                   -- cut to what's used
        W, H = 0, 0
        for _, r in ipairs(rects) do
          local w, h = r.w, r.h
          if r.rot then w, h = h, w end
          W, H = math.max(W, r.x + w), math.max(H, r.y + h)
        end
      end
      return W, H
    end
  end
  return nil, string.format("doesn't fit in %d x %d: a larger Max size, or Rotate", max, max)
end

-------------------------------------------------------------------------------
local AtlasView = canvas.View:extend()
AtlasView.wheel_zooms = true
AtlasView.grid = false
AtlasView.zoom_min, AtlasView.zoom_max = 0.05, 32

function AtlasView:new(state)
  AtlasView.super.new(self)
  self.filename = norm(state and state.filename or "")
  self.doc = state and state.doc or core.open_doc(self.filename)
  if state and state.cam then self:set_camera(state.cam) end
  self.images = {}
  self.ui_top, self.ui_left, self.ui_right = canvas.ui.new(), canvas.ui.new(), canvas.ui.new()   -- (its panels: canvas.ui)
  self:repack()
end

function AtlasView:get_name() return base_of(self.filename) .. (self.doc:is_dirty() and "*" or "") end
function AtlasView:get_state() return { filename = self.filename, cam = self:camera_state() } end
function AtlasView:base() return dir_of(self.filename) end

function AtlasView:opt(k)                          -- a setting: the atlas's own, else config.lua's
  local v = self.spec and self.spec[k]
  if type(v) ~= type(DEFAULTS[k]) then v = cfg[k] end
  return v
end

function AtlasView:sheet_file()                    -- where the sheet goes (abs), and its path for the game
  local spec = self.spec or {}
  local img = type(spec.image) == "string" and spec.image ~= "" and norm(spec.image) or nil
  if img and img:sub(1, 8) == "/assets/" then
    local _, root = game_path(self.filename)
    if root then return root .. img:sub(8), img end
  end
  local f = self:base() .. "/" .. (img or (atlas_stem(self.filename) .. ".atlas.png"))
  return f, game_path(f) or base_of(f)
end

-- the text (the doc's, unsaved typing too) -> self.spec; its images -> packed
function AtlasView:repack()
  self.err = nil
  self.change_id = self.doc:get_change_id()
  local spec, err = parse(table.concat(self.doc.lines), base_of(self.filename))
  if not spec then self.err = err; self.items, self.left_out = self.items or {}, self.left_out or {}; core.redraw = true return end
  self.spec = spec
  self.cut = type(spec.cut) == "string" and spec.cut ~= "" or nil
  if self.cut then return self:recut() end
  local list, out = sources(spec, self:base(), { [self:sheet_file()] = true })
  local items, sig = {}, {}
  local function image(s)                          -- (read once; again when its file changes)
    local m = mtime(s.file)
    local c = self.images[s.file]
    if not c or c.mtime ~= m then
      local img, ierr = renderer.image.load(s.file)
      c = img and { img = img, mtime = m } or nil
      self.images[s.file] = c
      if not img then core.warn("atlas %s: %s", base_of(self.filename), tostring(ierr)) end
    end
    if c then
      local w, h = c.img:get_size()
      s.img, s.w, s.h = c.img, math.floor(w), math.floor(h)
    end
    return m
  end
  for _, s in ipairs(list) do
    sig[#sig + 1] = s.file .. "@" .. tostring(image(s))
    if s.img then s.path = game_path(s.file) or s.rel; items[#items + 1] = s end
  end
  for _, s in ipairs(out) do image(s) end         -- (left out: shown, to put back)
  self.sig = table.concat(sig, "|") .. "#" .. #out
  local o = {
    padding = math.max(0, math.floor(tonumber(self:opt("padding")) or 0)),
    power_of_two = self:opt("power_of_two"),
    max_size = math.max(16, math.floor(tonumber(self:opt("max_size")) or 2048)),
    rotate = self:opt("rotate"),
  }
  local W, H = layout(items, o)
  self.items, self.left_out = items, out
  self.W, self.H, self.sheet = nil, nil, nil
  if not W then self.err = H
  else
    local used, entries = 0, {}
    for _, it in ipairs(items) do
      used = used + it.w * it.h
      entries[#entries + 1] = { file = it.file, x = it.x, y = it.y, deg = it.rot and 90 or 0 }
    end
    self.W, self.H, self.fill, self.entries = W, H, used / (W * H), entries
    local img, cerr = renderer.image.compose(W, H, entries)   -- (the sheet as it will be written)
    if img then self.sheet = img else self.err = cerr end
  end
  if self.fitting then self.fit_w = nil end        -- (fit again: a new size)
  core.redraw = true
end

-- cut: the picture itself is the sheet; its frames, as the text has them
function AtlasView:cut_file() return self:base() .. "/" .. norm(self.spec.cut) end
function AtlasView:recut()
  local file = self:cut_file()
  local m = mtime(file)
  local c = self.images[file]
  if not c or c.mtime ~= m then
    local img, ierr = renderer.image.load(file)
    c = img and { img = img, mtime = m } or nil
    self.images[file] = c
    if not img then self.err = tostring(ierr) end
  end
  self.sig = file .. "@" .. tostring(m)
  local items = {}
  for i, f in ipairs(type(self.spec.frames) == "table" and self.spec.frames or {}) do
    if type(f) == "table" and f.name then
      items[#items + 1] = { rel = tostring(f.name), path = tostring(f.name), x = tonumber(f.x) or 0, y = tonumber(f.y) or 0,
                            w = tonumber(f.w) or 0, h = tonumber(f.h) or 0, idx = i }
    end
  end
  table.sort(items, function(a, b) return #a.rel < #b.rel or (#a.rel == #b.rel and a.rel < b.rel) end)
  self.items, self.left_out, self.fill, self.entries = items, {}, nil, nil
  self.W, self.H, self.sheet = nil, nil, nil
  if c then
    local w, h = c.img:get_size()
    self.W, self.H, self.sheet = math.floor(w), math.floor(h), c.img
  end
  if self.fitting then self.fit_w = nil end
  core.redraw = true
end
-- cut: a part added (x, y, w, h: in the picture), renamed, removed; every patch that shows, a frame
local function frames_copy(spec)
  local out = {}
  for _, f in ipairs(type(spec.frames) == "table" and spec.frames or {}) do
    if type(f) == "table" then out[#out + 1] = { name = f.name, x = f.x, y = f.y, w = f.w, h = f.h } end
  end
  return out
end
function AtlasView:cut_add(x, y, w, h)
  core.command_view:enter("Name this part", function(text)
    text = tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    self:edit(function(spec)
      spec.frames = frames_copy(spec)
      spec.frames[#spec.frames + 1] = { name = text, x = x, y = y, w = w, h = h }
    end)
    self.sel = text
  end)
end
function AtlasView:cut_rename(it)
  if not it then return end
  core.command_view:enter("Rename " .. it.rel, function(text)
    text = tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or text == it.rel then return end
    self:edit(function(spec)
      spec.frames = frames_copy(spec)
      if spec.frames[it.idx] then spec.frames[it.idx].name = text end
    end)
    self.sel = text
  end)
  core.command_view:set_text(it.rel)
end
function AtlasView:find_segments()
  if not (self.cut and renderer.image.regions) then return end
  local found, err = renderer.image.regions(self:cut_file())
  if not found then core.error("atlas %s: %s", base_of(self.filename), tostring(err)) return end
  local added = 0
  self:edit(function(spec)
    spec.frames = frames_copy(spec)
    local have, names = {}, {}
    for _, f in ipairs(spec.frames) do have[string.format("%d,%d,%d,%d", f.x or 0, f.y or 0, f.w or 0, f.h or 0)] = true; names[tostring(f.name)] = true end
    table.sort(found, function(a, b) return a.y < b.y or (a.y == b.y and a.x < b.x) end)
    local n = 0
    for _, r in ipairs(found) do
      if not have[string.format("%d,%d,%d,%d", r.x, r.y, r.w, r.h)] then
        repeat n = n + 1 until not names["seg" .. n]
        spec.frames[#spec.frames + 1] = { name = "seg" .. n, x = r.x, y = r.y, w = r.w, h = r.h }
        added = added + 1
      end
    end
  end)
  core.log("Atlas %s: %d segments found, %d new (named seg<n>: double-click to rename)", base_of(self.filename), #found, added)
end
function AtlasView:prompt_cut()                    -- make it a cut atlas: the picture's name
  core.command_view:enter("Cut from a picture (next to " .. base_of(self.filename) .. ")", function(text)
    text = norm(tostring(text)):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    self:edit(function(spec)
      spec.cut = text
      local gp = game_path(self:base() .. "/" .. text)
      spec.image = gp or text
      if not (type(spec.frames) == "table" and spec.frames[1] and spec.frames[1].name) then spec.frames = {} end
    end)
    self:find_segments()
  end, function(text)
    local out = {}
    for _, e in ipairs(system.list_dir(self:base()) or {}) do
      if IMAGES[ext(e)] and e:lower():sub(1, #text) == text:lower() then out[#out + 1] = e end
    end
    table.sort(out)
    return out
  end)
end

-- the frames as packed now; and why the written ones aren't these (nil: saved)
function AtlasView:frames()
  local fr = {}
  for _, it in ipairs(self.items or {}) do
    fr[#fr + 1] = { path = it.path, x = it.x, y = it.y, w = it.w, h = it.h, deg = it.rot and 90 or 0 }
  end
  table.sort(fr, function(a, b) return a.path < b.path end)
  return fr
end
local function frames_sig(list)
  local t = {}
  for _, f in ipairs(type(list) == "table" and list or {}) do
    if type(f) == "table" then
      local n = function(v) return math.floor(tonumber(v) or 0) end
      t[#t + 1] = string.format("%s:%d,%d,%d,%d,%d", tostring(f.path), n(f.x), n(f.y), n(f.w), n(f.h), n(f.deg))
    end
  end
  return table.concat(t, "|")
end
function AtlasView:stale()
  if not self.W or not self.spec then return nil end
  if self.doc:is_dirty() then return "unsaved" end
  if self.cut then return nil end                  -- (cut: nothing to write but its text)
  local t = mtime(self:sheet_file())
  if not t then return "not written yet" end
  if self.spec.w ~= self.W or self.spec.h ~= self.H or frames_sig(self.spec.frames) ~= frames_sig(self:frames()) then return "packed again" end
  for _, it in ipairs(self.items) do if (mtime(it.file) or 0) > t then return "an image changed" end end
  return nil
end

-- the view's edits go into the text (unsaved; undo there undoes them)
function AtlasView:set_text(src)
  local doc = self.doc
  src = src:gsub("\n$", "")                        -- (a lite doc ends in a newline of its own)
  if table.concat(doc.lines):gsub("\n$", "") == src then return end
  doc:remove(1, 1, #doc.lines, #doc.lines[#doc.lines])
  doc:insert(1, 1, src)
  self:repack()
end
function AtlasView:edit(fn)                        -- fn(spec) changes a copy of it; the text follows
  if not self.spec then core.error("atlas %s: %s (fix its text first)", base_of(self.filename), tostring(self.err)) return end
  local spec = {}
  for k, v in pairs(self.spec) do spec[k] = v end
  spec.sources = { table.unpack(type(self.spec.sources) == "table" and self.spec.sources or {}) }
  spec.exclude = { table.unpack(type(self.spec.exclude) == "table" and self.spec.exclude or {}) }
  for _, k in ipairs(SETTINGS) do if spec[k] == nil then spec[k] = cfg[k] end end
  fn(spec)
  self:set_text(to_text(spec, self.filename))
end

function AtlasView:save()                          -- CTRL+S: the sheet, and its frames in the text, written
  if self.doc:get_change_id() ~= self.change_id then self:repack() end
  if self.cut then                                 -- (cut: the picture is the sheet; the text, saved)
    if self.W then self:edit(function(spec) spec.w, spec.h = self.W, self.H end) end
    self.doc:save()
    core.log("Atlas %s: %d frames of %s", base_of(self.filename), #self.items, base_of(self:cut_file()))
    return
  end
  if self.err or not self.W then core.error("atlas %s: %s", base_of(self.filename), self.err or "nothing packed") return end
  local png, gp = self:sheet_file()
  local ok, err = renderer.image.write_atlas(png, self.W, self.H, self.entries)
  if not ok then core.error("atlas %s: %s", base_of(self.filename), tostring(err)) return end
  self:edit(function(spec) spec.image, spec.w, spec.h, spec.frames = gp, self.W, self.H, self:frames() end)
  self.doc:save()
  core.log("Atlas %s: %d images, %d x %d -> %s", base_of(self.filename), #self.items, self.W, self.H, base_of(png))
end

-- in: a file, a folder or a pattern (abs, or next to the atlas)
function AtlasView:add(s)
  s = norm(s or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
  if s == "" then return end
  local base = self:base()
  if s:sub(1, #base + 1) == base .. "/" then s = s:sub(#base + 2) end
  self:edit(function(spec)
    for i = #spec.exclude, 1, -1 do               -- (left out before: back in)
      local e = spec.exclude[i]
      if e == s or e:sub(1, #s + 1) == s .. "/" then table.remove(spec.exclude, i) end
    end
    for _, x in ipairs(spec.sources) do if x == s then return end end
    spec.sources[#spec.sources + 1] = s
  end)
end
function AtlasView:remove_source(i) self:edit(function(spec) table.remove(spec.sources, i) end) end
function AtlasView:remove(it)                      -- out: its source if it's only that image, else left out
  if not it then return end
  if self.cut then                                 -- (cut: the frame goes)
    self:edit(function(spec) spec.frames = frames_copy(spec); table.remove(spec.frames, it.idx) end)
    if self.sel == it.rel then self.sel = nil end
    return
  end
  self:edit(function(spec)
    local s = spec.sources[it.src]
    if s and norm(s):gsub("/+$", "") == it.rel then table.remove(spec.sources, it.src)
    else spec.exclude[#spec.exclude + 1] = it.rel end
  end)
  if self.sel == it.rel then self.sel = nil end
end
function AtlasView:put_back(it)
  self:edit(function(spec)
    for i = #spec.exclude, 1, -1 do if spec.exclude[i] == it.rel then table.remove(spec.exclude, i) end end
  end)
end
function AtlasView:prompt_add()                    -- the command line: a name, with what's next to the atlas
  local base = self:base()
  core.command_view:enter("Add to " .. base_of(self.filename) .. " (an image, a folder, or *.png)", function(text)
    self:add(text)
  end, function(text)
    local sub, start = norm(text):match("^(.-/?)([^/]*)$")
    local dir = base .. "/" .. sub
    local out = {}
    local names = system.list_dir(dir) or {}
    table.sort(names)
    for _, e in ipairs(names) do
      local info = system.get_file_info(dir .. e)
      if info and e:sub(1, 1) ~= "." and e:lower():sub(1, #start) == start:lower() then
        if info.type == "dir" then out[#out + 1] = sub .. e .. "/"
        elseif IMAGES[ext(e)] and not is_sheet(e) then out[#out + 1] = sub .. e end
      end
    end
    if start == "" and #out > 1 then table.insert(out, 1, sub .. "*.png") end
    return out
  end)
end
function AtlasView:on_file_dropped(file) self:add(file) return true end

function AtlasView:update()
  AtlasView.super.update(self)
  self.dirty = self.doc:is_dirty()                 -- (closing it unsaved asks: canvas.View)
  local now = system.get_time()
  if self.doc:get_change_id() ~= self.change_id then   -- (typed in its text: packed once the typing stops)
    if not self.typed then self.typed = now end
    if now - self.typed > 0.25 then self.typed = nil; self:repack() else core.redraw = true end
    return
  end
  if now < (self.next_check or 0) then return end
  self.next_check = now + 0.5                      -- its images changed on disk: pack again
  if self.spec and self.cut then                   -- (cut: its picture changed)
    local f = self:cut_file()
    if f .. "@" .. tostring(mtime(f)) ~= self.sig then self:repack() end
  elseif self.spec then
    local list, out = sources(self.spec, self:base(), { [self:sheet_file()] = true })
    local sig = {}
    for _, s in ipairs(list) do sig[#sig + 1] = s.file .. "@" .. tostring(mtime(s.file)) end
    if table.concat(sig, "|") .. "#" .. #out ~= self.sig then self:repack() end
  end
  if P.changed("config") then load_config(); self:repack() end
end

-------------------------------------------------------------------------------
-- the panels: a toolbar on top, the sprites left, the settings right; the
-- sheet (the canvas) between them. Drawn each frame with canvas.ui (one per
-- panel: self.ui_top, ui_left, ui_right), which keeps what's clickable.
local function S(n) return math.floor(n * SCALE + 0.5) end
function AtlasView:rects()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local fh = style.font:get_height()
  local th = fh + S(14)
  local lw = math.floor(math.min(math.max(S(200), w * 0.24), S(300)))
  local rw = math.floor(math.min(S(220), w * 0.26))
  if w < S(560) then rw = 0 end                    -- (narrow: no settings panel; its menu has them)
  if w < S(320) then lw = 0 end
  return {
    top = { x, y, w, th },
    left = { x, y + th, lw, h - th },
    right = { x + w - rw, y + th, rw, h - th },
    mid = { x + lw, y + th, w - lw - rw, h - th },
    row = fh + S(8),
  }
end
local function inside(r, px, py) return r[3] > 0 and px >= r[1] and px < r[1] + r[3] and py >= r[2] and py < r[2] + r[4] end

function AtlasView:fit(frac)                       -- the sheet in the middle, between the panels
  if not self.W or self.size.x <= 0 then return end
  local m = self:rects().mid
  frac = frac or self.fit_frac
  local zoom = math.min(frac * m[3] / self.W, frac * m[4] / self.H) / SCALE
  self.cam.zoom = math.max(self.zoom_min, math.min(self.zoom_max, zoom))
  local z = self:z()
  self.cam.x = (m[1] - self.position.x) + (m[3] - self.W * z) / 2
  self.cam.y = (m[2] - self.position.y) + (m[4] - self.H * z) / 2
  self.fitting = true
  core.redraw = true
end
function AtlasView:bounds() if self.W then return 0, 0, self.W, self.H end end
function AtlasView:center_on_item(it)
  local z = self:z()
  local cx, cy = it.x + (it.rot and it.h or it.w) / 2, it.y + (it.rot and it.w or it.h) / 2
  local m = self:rects().mid
  self.cam.x = (m[1] - self.position.x) + m[3] / 2 - cx * z
  self.cam.y = (m[2] - self.position.y) + m[4] / 2 - cy * z
  self.fitting = false
  core.redraw = true
end

function AtlasView:item_at(wx, wy)
  for _, it in ipairs(self.items or {}) do
    local w, h = it.w, it.h
    if it.rot then w, h = h, w end
    if it.x and wx >= it.x and wx < it.x + w and wy >= it.y and wy < it.y + h then return it end
  end
end
function AtlasView:selected()
  for _, it in ipairs(self.items or {}) do if it.rel == self.sel then return it end end
end

-- the mouse: the panels first, then the sheet
function AtlasView:on_mouse_pressed(button, x, y, clicks)
  self.mx, self.my = x, y
  local r = self:rects()
  for _, ui in ipairs { self.ui_top, self.ui_left, self.ui_right } do
    if ui:pressed(button, x, y, clicks) then return true end
  end
  if inside(r.top, x, y) or inside(r.left, x, y) or inside(r.right, x, y) then return button == "left" end
  return AtlasView.super.on_mouse_pressed(self, button, x, y, clicks)
end
function AtlasView:on_mouse_released(button, x, y)
  for _, ui in ipairs { self.ui_top, self.ui_left, self.ui_right } do if ui:released(button) then return end end
  return AtlasView.super.on_mouse_released(self, button, x, y)
end
function AtlasView:on_canvas_pressed(button, wx, wy, clicks)
  if button == "left" and clicks == 1 and self.cut and self.W and not self:item_at(wx, wy)
     and wx >= 0 and wy >= 0 and wx < self.W and wy < self.H then   -- (cut: a drag on the picture marks a new part)
    self.drag = { x0 = math.floor(wx), y0 = math.floor(wy), x1 = math.floor(wx), y1 = math.floor(wy) }
    self.sel = nil
    return true
  end
  if button == "left" and clicks == 2 and self.cut then   -- (cut: a part double-clicked: its name)
    local it = self:item_at(wx, wy)
    if it then self:cut_rename(it) return true end
  end
  if button == "left" and clicks == 1 then
    local it = self:item_at(wx, wy)
    self.sel = it and it.rel or nil
    self.reveal = it ~= nil                        -- (the list scrolls to it)
    core.redraw = true
  end
  return false                                     -- (a drag still pans; a double-click fits)
end
function AtlasView:on_mouse_moved(x, y, dx, dy)
  local took = false
  for _, ui in ipairs { self.ui_top, self.ui_left, self.ui_right } do took = ui:moved(x, y) or took end
  if took then self.mx, self.my = x, y; core.redraw = true return end
  AtlasView.super.on_mouse_moved(self, x, y, dx, dy)
  if not inside(self:rects().mid, x, y) then core.redraw = true end   -- (the panels light what's under it)
end
function AtlasView:on_canvas_moved(wx, wy)
  if self.drag then
    self.drag.x1 = math.max(0, math.min(self.W or 0, math.floor(wx + 0.5)))
    self.drag.y1 = math.max(0, math.min(self.H or 0, math.floor(wy + 0.5)))
    core.redraw = true
    return
  end
  if not inside(self:rects().mid, self.mx or 0, self.my or 0) then return end
  local it = self:item_at(wx, wy)
  if it ~= self.hot then self.hot = it; core.redraw = true end
end
function AtlasView:on_mouse_wheel(dy, dx)
  local r = self:rects()
  if self.ui_left:wheel(dy or 0) or self.ui_right:wheel(dy or 0) then return true end
  if not inside(r.mid, self.mx or 0, self.my or 0) then return true end
  return AtlasView.super.on_mouse_wheel(self, dy, dx)
end

function AtlasView:on_canvas_released(button, wx, wy)
  local d = self.drag
  if not d or button ~= "left" then return end
  self.drag = nil
  local x, y = math.min(d.x0, d.x1), math.min(d.y0, d.y1)
  local w, h = math.abs(d.x1 - d.x0), math.abs(d.y1 - d.y0)
  if w >= 2 and h >= 2 then self:cut_add(x, y, w, h) end
  core.redraw = true
end

-- drawing ---------------------------------------------------------------
function AtlasView:draw_background_color() return style.background end

local function frame(x, y, w, h, c)
  renderer.draw_rect(x, y, w, 1, c); renderer.draw_rect(x, y + h - 1, w, 1, c)
  renderer.draw_rect(x, y, 1, h, c); renderer.draw_rect(x + w - 1, y, 1, h, c)
end
local function clip_text(f, text, w)               -- cut to w px, with ".."
  if f:get_width(text) <= w then return text end
  while #text > 1 and f:get_width(text .. "..") > w do text = text:sub(1, -2) end
  return text .. ".."
end

function AtlasView:draw_canvas()
  if not self.W or not self.sheet then return end
  local z = self:z()
  local x0, y0 = self:to_screen(0, 0)
  x0, y0 = math.floor(x0), math.floor(y0)
  local w, h = math.floor(self.W * z), math.floor(self.H * z)
  local light = { style.background3[1], style.background3[2], style.background3[3], 255 }
  if self.cut then light = { 236, 236, 230, 255 } end   -- (cut: a light backdrop: its parts are often dark ink)
  local dark = { math.floor(light[1] * 0.82), math.floor(light[2] * 0.82), math.floor(light[3] * 0.82), 255 }
  D.checker(x0, y0, w, h, math.max(2, math.floor(D.vh(cfg.checker) + 0.5)),
            lite_bg and lite_bg(light) or light, lite_bg and lite_bg(dark) or dark, x0, y0)
  renderer.draw_image(self.sheet, x0, y0, w, h)
  local edge = { style.dim[1], style.dim[2], style.dim[3], 90 }
  local sel = self:selected()
  for _, it in ipairs(self.items) do              -- each one's frame (the hovered, the selected: bright)
    if it.x then
      local iw, ih = it.w, it.h
      if it.rot then iw, ih = ih, iw end
      local sx, sy = math.floor(x0 + it.x * z), math.floor(y0 + it.y * z)
      local sw, sh = math.max(1, math.floor(iw * z)), math.max(1, math.floor(ih * z))
      if it == sel then frame(sx - 1, sy - 1, sw + 2, sh + 2, style.accent); frame(sx, sy, sw, sh, style.accent)
      elseif it ~= self.hot then frame(sx, sy, sw, sh, edge) end
    end
  end
  if self.hot and self.hot ~= sel and self.hot.x then
    local it = self.hot
    local iw, ih = it.w, it.h
    if it.rot then iw, ih = ih, iw end
    frame(math.floor(x0 + it.x * z), math.floor(y0 + it.y * z), math.max(1, math.floor(iw * z)), math.max(1, math.floor(ih * z)), style.text)
  end
  frame(x0 - 1, y0 - 1, w + 2, h + 2, style.divider)   -- the sheet's edge
  local d = self.drag
  if d then                                        -- (cut: the part being marked)
    local ax, ay = math.floor(x0 + math.min(d.x0, d.x1) * z), math.floor(y0 + math.min(d.y0, d.y1) * z)
    frame(ax, ay, math.max(1, math.floor(math.abs(d.x1 - d.x0) * z)), math.max(1, math.floor(math.abs(d.y1 - d.y0) * z)), style.accent)
  end
end

-- the toolbar: canvas.ui buttons, the actions left, the view right
function AtlasView:draw_toolbar(r)
  local x, y, w, h = table.unpack(r.top)
  local ui = self.ui_top
  renderer.draw_rect(x, y, w, h, style.background2)
  renderer.draw_rect(x, y + h - 1, w, 1, style.divider)
  ui:begin(x, y, w, h, { flat = true })
  local by = y + math.floor((h - style.font:get_height() - S(6)) / 2)
  local bx, gap = x + S(8), S(6)
  local sel = self:selected()
  if self.cut then                                 -- (cut: parts of one picture)
    bx = bx + ui:button_at(bx, by, "Find segments", function() self:find_segments() end, nil, nil, "Find the parts of the picture (its shapes on transparency)") + gap
    bx = bx + ui:button_at(bx, by, "Rename", sel and function() self:cut_rename(sel) end) + gap
  else
    bx = bx + ui:button_at(bx, by, "+ Add...", function() self:prompt_add() end, nil, nil, "Add a picture or a folder of them (or drop them here)") + gap
  end
  bx = bx + ui:button_at(bx, by, "Remove", sel and function() self:remove(sel) end) + gap * 3
  local why = self:stale()
  bx = bx + ui:button_at(bx, by, why and "Save  CTRL+S" or "Saved", function() self:save() end, why ~= nil, nil, why) + gap
  local right = x + w - S(8)
  for _, it in ipairs { { "Text", function() self:edit_text() end, "Its text (the tab's icon flips it too)" }, { "100%", function() self:set_zoom(1) end }, { "Fit", function() self:fit() end } } do
    right = right - (style.font:get_width(it[1]) + S(16))
    if right > bx then ui:button_at(right, by, it[1], it[2], nil, nil, it[3]) end
    right = right - gap
  end
  ui:finish()
end

local function thumb(img, w, h, x, y, s)           -- an image in an s x s square, its shape kept
  local k = math.min(s / w, s / h)
  local tw, th = math.max(1, math.floor(w * k)), math.max(1, math.floor(h * k))
  renderer.draw_image(img, x + math.floor((s - tw) / 2), y + math.floor((s - th) / 2), tw, th)
end

-- the sprites (or frames): canvas.ui's list, a thumbnail each
function AtlasView:draw_list(r)
  local x, y, w, h = table.unpack(r.left)
  if w <= 0 then return end
  local ui = self.ui_left
  ui:begin(x, y, w, h, { divider_right = true })
  local rows, items = {}, {}
  local spec, by_src = self.spec or {}, {}
  for _, it in ipairs(self.items or {}) do if it.src then by_src[it.src] = by_src[it.src] or {}; table.insert(by_src[it.src], it) end end
  local function item(it, out)
    local row = { text = it.rel, info = it.w and string.format("%dx%d", it.w, it.h) or "", indent = 1, kind = out and "dim" or nil,
                  icon = it.img and function(ix, iy, sz) thumb(it.img, it.w, it.h, ix, iy, sz) end }
    if out then
      row.button = { "+", function() self:put_back(it) end, tip = "back in the sheet" }
    else
      row.selected = it.rel == self.sel
      row.press = function(clicks)
        self.sel = it.rel
        if clicks >= 2 then if self.cut then self:cut_rename(it) else self:center_on_item(it) end end
        core.redraw = true
      end
      row.button = { "x", function() self:remove(it) end, tip = "out of the sheet" }
    end
    rows[#rows + 1] = row
    items[#rows] = it
  end
  rows[#rows + 1] = { text = self.cut and "Frames" or "Sprites", info = tostring(#(self.items or {})), kind = "head" }
  if self.cut then                                 -- (cut: its parts, by name)
    for _, it in ipairs(self.items or {}) do item(it) end
    if #rows == 1 then rows[#rows + 1] = { text = "Find segments, or drag on the picture", kind = "dim" } end
  end
  for i, src in ipairs(not self.cut and type(spec.sources) == "table" and spec.sources or {}) do
    local list = by_src[i] or {}
    rows[#rows + 1] = { text = tostring(src), info = #list == 0 and "none" or tostring(#list),
                        button = { "x", function() self:remove_source(i) end, tip = "this source out of the atlas" } }
    for _, it in ipairs(list) do item(it) end
  end
  if #(self.left_out or {}) > 0 then
    rows[#rows + 1] = { text = "Left out", info = tostring(#self.left_out), kind = "head" }
    for _, it in ipairs(self.left_out) do item(it, true) end
  end
  if #rows == 1 and not self.cut then rows[#rows + 1] = { text = "+ Add..., or drop images here", kind = "dim" } end
  local reveal
  if self.reveal then                              -- (the selected one in view)
    self.reveal = nil
    for i, row in ipairs(rows) do if row.selected then reveal = i end end
  end
  local hov = ui:list(rows, { row = r.row, reveal = reveal })
  ui:finish()
  if inside(r.left, self.mx or -1, self.my or -1) then self.hot = hov and items[hov] or nil end
end

-- the settings and what came out: canvas.ui
function AtlasView:draw_settings(r)
  local x, y, w, h = table.unpack(r.right)
  if w <= 0 then return end
  local ui = self.ui_right
  ui:begin(x, y, w, h)
  local function toggle(k) return function() local v = not self:opt(k); self:edit(function(s) s[k] = v end) end end
  local function selected_rows(sel, rot)
    ui:space()
    ui:head("Selected")
    ui:text(sel.path, style.text)
    ui:label("Size", string.format("%d x %d", sel.w, sel.h))
    ui:label("At", string.format("%d, %d", sel.x or 0, sel.y or 0))
    if rot and sel.rot then ui:label("Turned", "90") end
  end
  if self.cut then                                 -- (cut: no packing; the picture and its parts)
    ui:head("Cut from")
    ui:label("Picture", base_of(self:cut_file()))
    ui:label("Size", self.W and string.format("%d x %d", self.W, self.H) or "-")
    ui:label("Frames", tostring(#(self.items or {})))
    ui:label("State", self:stale() or "saved")
    local sel = self:selected()
    if sel then selected_rows(sel) end
    ui:finish()
    return
  end
  ui:head("Settings")
  local pv, mv = self:opt("padding"), self:opt("max_size")
  ui:stepper("Padding", pv, function() self:edit(function(s) s.padding = math.max(0, pv - 1) end) end,
                            function() self:edit(function(s) s.padding = pv + 1 end) end, { tip = "px between sprites" })
  ui:stepper("Max size", mv, function() self:edit(function(s) s.max_size = math.max(16, math.floor(mv / 2)) end) end,
                             function() self:edit(function(s) s.max_size = math.min(16384, mv * 2) end) end, { tip = "the sheet's largest side, px" })
  ui:check("Power of two", self:opt("power_of_two"), toggle("power_of_two"))
  ui:check("Rotate", self:opt("rotate"), toggle("rotate"))
  ui:space()
  ui:head("Output")
  ui:label("Sheet", base_of(self:sheet_file()))
  ui:label("Size", self.W and string.format("%d x %d", self.W, self.H) or "-")
  ui:label("Used", self.fill and self.W and string.format("%d%%", math.floor(self.fill * 100 + 0.5)) or "-")
  ui:label("Frames", tostring(#(self.items or {})))
  ui:label("State", self:stale() or "saved")
  local sel = self:selected()
  if sel then selected_rows(sel, true) end
  ui:finish()
end

function AtlasView:draw_overlay()
  local r = self:rects()
  if self.err then
    local m = r.mid
    renderer.draw_text(style.font, tostring(self.err), m[1] + style.padding.x, m[2] + style.padding.y, style.error or style.text)
  end
  local hot = self.hot
  if hot and hot.x and inside(r.mid, self.mx or 0, self.my or 0) then
    self:draw_status(string.format("%s   %d x %d   at %d, %d%s   |   %d%%", hot.path, hot.w, hot.h, hot.x, hot.y,
      hot.rot and "   turned 90" or "", math.floor(self:z() * 100 + 0.5)))
  end
  self:draw_list(r)
  self:draw_settings(r)
  self:draw_toolbar(r)
end

function AtlasView:edit_text()                     -- its text, in this tab (plugins/tabflip: the tab's icon too)
  local node = core.root_view.root_node:get_node_for_view(self)
  if node then require("plugins.tabflip").flip(node, self) end
end

function AtlasView:menu_items()                    -- (its source, reload, settings: "Plugin: atlas", last)
  local DIV = require("plugins.contextmenu").DIVIDER
  local sel = self:selected()
  local items
  if self.cut then                                 -- (cut: a picture's parts)
    items = {
      { text = "Save", info = "CTRL+S", command = function() self:save() end },
      { text = "Find segments", command = function() self:find_segments() end },
    }
    if sel then
      items[#items + 1] = { text = "Rename " .. sel.rel, info = "dbl-click", command = function() self:cut_rename(sel) end }
      items[#items + 1] = { text = "Remove " .. sel.rel, info = "DEL", command = function() self:remove(sel) end }
    end
    items[#items + 1] = DIV
  else
    items = {
      { text = "Save the sheet and frames", info = "CTRL+S", command = function() self:save() end },
      { text = "Add images...", command = function() self:prompt_add() end },
    }
    if sel then items[#items + 1] = { text = "Remove " .. sel.rel, info = "DEL", command = function() self:remove(sel) end } end
    local function toggle(k) return function() local v = not self:opt(k); self:edit(function(s) s[k] = v end) end end
    items[#items + 1] = DIV
    items[#items + 1] = { text = "Power of two", checked = self:opt("power_of_two"), command = toggle("power_of_two") }
    items[#items + 1] = { text = "Rotate", checked = self:opt("rotate"), command = toggle("rotate") }
    items[#items + 1] = { text = "Cut from a picture instead...", command = function() self:prompt_cut() end }
    items[#items + 1] = DIV
  end
  items[#items + 1] = { text = "Fit", info = "dbl-click", checked = self.fitting, command = function() self:fit() end }
  items[#items + 1] = { text = "100%", checked = not self.fitting and math.abs(self.cam.zoom - 1) < 1e-3, command = function() self:set_zoom(1) end }
  items[#items + 1] = DIV
  items[#items + 1] = { text = "Open the sheet", command = function() core.root_view:open_doc(core.open_doc(self:sheet_file())) end }
  items[#items + 1] = { text = "Edit as text", command = function() self:edit_text() end }
  return items
end

-- a tab flips between its text and this view (the icon left of its name)
require("plugins.tabflip").register {
  key = "atlaspacker",
  name = "atlaspacker",
  first = true,                                    -- (a .atlas.lua is Lua too: this, not the node graph)
  text = function(view) return view:is(DocView) and view.doc and is_atlas(view.doc.filename) end,
  alt = function(view) return view:is(AtlasView) end,
  to_alt = function(view) return AtlasView({ filename = system.absolute_path(view.doc.filename) or view.doc.filename, doc = view.doc }) end,
  to_text = function(view) return DocView(view.doc) end,
  icon = function(x, y, s, c)                      -- a sheet: one big frame and two small ones
    local t = math.max(1, math.floor(s / 7))
    local a = math.floor(s * 0.55)
    renderer.draw_rect(x, y, s, t, c); renderer.draw_rect(x, y + s - t, s, t, c)
    renderer.draw_rect(x, y, t, s, c); renderer.draw_rect(x + s - t, y, t, s, c)
    renderer.draw_rect(x + a, y, t, s, c)
    renderer.draw_rect(x + a, y + math.floor(s / 2), s - a, t, c)
  end,
  tip = "Show as atlas",
  menu = "Toggle atlas / text",
}

-- DEL: the selected image out; files dropped on its tab: in
command.add(function()
  local v = core.active_view
  return v and v:is(AtlasView) and v:selected() ~= nil
end, { ["atlaspacker:remove"] = function() core.active_view:remove(core.active_view:selected()) end })
if not package.loaded["atlaspacker.keys"] then           -- (once: a reload keeps them)
  package.loaded["atlaspacker.keys"] = true
  keymap.add { ["delete"] = "atlaspacker:remove" }
  local on_event = core.on_event
  function core.on_event(type, ...)                -- (a file dropped on a view with on_file_dropped: its)
    if type == "filedropped" then
      local file, mx, my = ...
      local node = core.root_view.root_node:get_child_overlapping_point(mx, my)
      local v = node and node.active_view
      if v and v.on_file_dropped and v:on_file_dropped(file, mx, my) then return true end
    end
    return on_event(type, ...)
  end
end

P.open_with(P.read("files") or {}, AtlasView)
return AtlasView

-- picker.lua - canvas.picker: the colour picker (Replay), the node graph's,
-- shared by every canvas and panel: a saturation / value square, a hue bar,
-- an alpha bar (when the colour has one) and a hex row (a click types one).
-- And a row of colour squares (the node graph's palette, its comment boxes').
--
-- Two ways to use it:
--
-- 1. A popup (canvas.ui's colour rows use it): it owns the mouse while open.
--      local pk = picker.new(x, y, { r, g, b, a }, function(c, final) ... end, { alpha = true })
--      pk:draw()                               -- (over everything: last)
--      pk:pressed(button, x, y) -> true (it took it) | false (outside: close it)
--      pk:moved(x, y); pk:released(); pk:text_input(t); pk:key(k) -> true when its
--    on_change(c, final): c = { r, g, b, a } 0..255; final: a drag ended, Enter.
--
-- 2. The parts, on a table of your own { x, y, h, s, v, a } (h, s, v, a 0..1;
--    a nil: no alpha bar) - the node graph keeps its own state and edits:
--      picker.rects(pk) -> box, sv, hue, alpha, hex     picker.draw_parts(pk, { hex_typing = bool })
--      picker.part_at(pk, x, y) -> "sv" | "hue" | "alpha" | "hex" | "box" | nil
--      picker.pick_at(pk, part, x, y)                   (moves h / s / v / a)
--      picker.hex(pk) -> "#rrggbb";  picker.rgb(pk) -> r, g, b (0..1)
--
-- picker.swatches(x, y, list, current, mx, my, step, size) draws a row of squares
-- (false: none, a slash) -> the index under (mx, my); picker.PALETTE.
-- picker.hsv2rgb(h, s, v), picker.rgb2hsv(r, g, b), picker.parse_hex("#rgb" / "#rrggbb[aa]").
local core = require "core"
local style = require "core.style"
local T = require "plugins.canvas.theme"
local D = require "plugins.canvas.draw"
local C, rgb = T.C, T.rgb

local P = {}
P.__index = P
P.W, P.H = 150, 110                                -- the square's box (times SCALE), the hex row below
P.PALETTE = { false, "#e06c75", "#e5a050", "#e5c07b", "#98c379", "#56b6c2", "#61afef", "#c678dd" }

function P.hsv2rgb(h, s, v)
  local i = math.floor(h * 6) % 6
  local f = h * 6 - math.floor(h * 6)
  local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  local c = ({ { v, t, p }, { q, v, p }, { p, v, t }, { p, q, v }, { t, p, v }, { v, p, q } })[i + 1]
  return c[1], c[2], c[3]
end
function P.rgb2hsv(r, g, b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d, h = mx - mn, 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
    h = h / 6
  end
  return h, mx > 0 and d / mx or 0, mx
end
function P.parse_hex(t)                            -- "#rgb", "#rrggbb", "#rrggbbaa" (the # optional) -> r, g, b[, a] 0..255 | nil
  t = tostring(t or ""):match("^%s*#?(%x+)%s*$")
  if not t then return nil end
  if #t == 3 then t = t:gsub(".", "%0%0") end
  if #t ~= 6 and #t ~= 8 then return nil end
  local n = function(i) return tonumber(t:sub(i, i + 1), 16) end
  return n(1), n(3), n(5), #t == 8 and n(7) or nil
end

-- the parts, on any { x, y, h, s, v, a } ------------------------------------
function P.rects(pk)
  local W, H = P.W * SCALE, P.H * SCALE
  local pad, ah, hh = 6 * SCALE, pk.a and 14 * SCALE or 0, style.font:get_height() + 6 * SCALE
  local sq = H - 2 * pad - (pk.a and (ah + pad) or 0)
  local box = { x = pk.x, y = pk.y, w = W, h = H + hh }
  local sv = { x = pk.x + pad, y = pk.y + pad, w = W - 3 * pad - 14 * SCALE, h = sq }
  local hue = { x = pk.x + W - pad - 14 * SCALE, y = pk.y + pad, w = 14 * SCALE, h = sq }
  local al = pk.a and { x = sv.x, y = sv.y + sq + pad, w = W - 2 * pad, h = ah } or nil
  local hex = { x = pk.x + pad, y = pk.y + H, w = W - 2 * pad, h = hh - pad }
  return box, sv, hue, al, hex
end
function P.rgb(pk) return P.hsv2rgb(pk.h, pk.s, pk.v) end
function P.hex(pk)
  local r, g, b = P.rgb(pk)
  return string.format("#%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end
local function inr(r, x, y) return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h end
function P.part_at(pk, x, y)
  local box, sv, hue, al, hex = P.rects(pk)
  if inr(hex, x, y) then return "hex" end
  if inr(sv, x, y) then return "sv" end
  if inr(hue, x, y) then return "hue" end
  if inr(al, x, y) then return "alpha" end
  if inr(box, x, y) then return "box" end
end
function P.pick_at(pk, part, x, y)
  local _, sv, hue, al = P.rects(pk)
  local function cl(v) return math.max(0, math.min(1, v)) end
  if part == "sv" then pk.s, pk.v = cl((x - sv.x) / sv.w), 1 - cl((y - sv.y) / sv.h)
  elseif part == "alpha" and al then pk.a = cl((x - al.x) / al.w)
  elseif part == "hue" then pk.h = cl((y - hue.y) / hue.h) * 0.999 end
  core.redraw = true
end
-- opts.hex_typing: the hex row is being typed (the caller draws the text field;
-- opts.text: draw this text there instead, with a caret)
function P.draw_parts(pk, opts)
  opts = opts or {}
  local box, sv, hue, al, hex = P.rects(pk)
  D.rrect(box.x + 2 * SCALE, box.y + 3 * SCALE, box.w, box.h, 5 * SCALE, C.shadow)
  D.rrect(box.x, box.y, box.w, box.h, 5 * SCALE, rgb"#181818")
  local N = 12
  local cw, ch = sv.w / N, sv.h / N
  for i = 0, N - 1 do for j = 0, N - 1 do        -- the square: saturation across, value down
    local r, g, b = P.hsv2rgb(pk.h, (i + 0.5) / N, 1 - (j + 0.5) / N)
    renderer.draw_rect(sv.x + i * cw, sv.y + j * ch, cw + 1, ch + 1, { r * 255, g * 255, b * 255, 255 })
  end end
  local M = 24
  for j = 0, M - 1 do                              -- the hue bar
    local r, g, b = P.hsv2rgb((j + 0.5) / M, 1, 1)
    renderer.draw_rect(hue.x, hue.y + j * hue.h / M, hue.w, hue.h / M + 1, { r * 255, g * 255, b * 255, 255 })
  end
  local mx, my = sv.x + pk.s * sv.w, sv.y + (1 - pk.v) * sv.h
  D.disc(mx, my, 9 * SCALE, C.outline); D.disc(mx, my, 6 * SCALE, C.active)
  local hy = hue.y + pk.h * hue.h
  renderer.draw_rect(hue.x - 2 * SCALE, hy - SCALE, hue.w + 4 * SCALE, 2 * SCALE, C.active)
  local r, g, b = P.rgb(pk)
  if al then                                       -- alpha: from the background to the colour
    local K = 16
    for i = 0, K - 1 do
      local t = (i + 0.5) / K
      renderer.draw_rect(al.x + i * al.w / K, al.y, al.w / K + 1, al.h,
                         { 24 + (r * 255 - 24) * t, 24 + (g * 255 - 24) * t, 24 + (b * 255 - 24) * t, 255 })
    end
    local ax = al.x + pk.a * al.w
    renderer.draw_rect(ax - SCALE, al.y - 2 * SCALE, 2 * SCALE, al.h + 4 * SCALE, C.active)
  end
  if opts.hex_typing then return end               -- (the caller's text field is there)
  D.rrect(hex.x, hex.y, hex.w, hex.h, 3 * SCALE, C.field)
  local f = style.code_font
  local text = opts.text or P.hex(pk)
  local ty = hex.y + (hex.h - f:get_height()) / 2
  local Field = require "plugins.canvas.field"
  if opts.text and pk.tf and Field.focused(pk.tf) then   -- (typed in lite: its selection, its caret)
    Field.draw(pk.tf, f, hex.x + 6 * SCALE, ty, C.code, C.active)
  else
    renderer.draw_text(f, text, hex.x + 6 * SCALE, ty, C.code)
    if opts.text then renderer.draw_rect(hex.x + 6 * SCALE + f:get_width(text), ty, style.caret_width, f:get_height(), C.active) end
  end
  D.rrect(hex.x + hex.w - hex.h, hex.y + 2 * SCALE, hex.h - 4 * SCALE, hex.h - 4 * SCALE, 2 * SCALE, { r * 255, g * 255, b * 255, 255 })
end

-- a row of colour squares (a menu's; "#rrggbb" or false: none) -> the index under (mx, my)
function P.swatches(x, y, list, current, mx, my, step, size)
  step, size = step or 22 * SCALE, size or 14 * SCALE
  local hot
  for k, c in ipairs(list) do
    local sx = x + (k - 1) * step
    local over = mx and my and mx >= sx and mx < sx + step and my >= y - 4 * SCALE and my < y + size + 4 * SCALE
    if over then hot = k end
    if over or (current or false) == c then D.rrect(sx - 2 * SCALE, y - 2 * SCALE, size + 4 * SCALE, size + 4 * SCALE, 3 * SCALE, over and C.text or C.dim) end
    D.rrect(sx, y, size, size, 2 * SCALE, c and rgb(c) or rgb"#2a2a2a")
    if not c then                                  -- none: a slash
      for d = 0, size - 1 do renderer.draw_rect(sx + d, y + size - 1 - d, math.max(1, SCALE), math.max(1, SCALE), C.err) end
    end
  end
  return hot
end

-- the popup ------------------------------------------------------------------
function P.new(x, y, c, on_change, opts)
  opts = opts or {}
  local h, s, v = P.rgb2hsv((c[1] or 0) / 255, (c[2] or 0) / 255, (c[3] or 0) / 255)
  local pk = setmetatable({ x = x, y = y, h = h, s = s, v = v, on_change = on_change,
                            a = (opts.alpha ~= false and (c[4] or opts.alpha)) and (c[4] or 255) / 255 or nil }, P)
  local W, H = P.W * SCALE, (P.H + 30) * SCALE      -- (kept on screen)
  local sw, sh = core.root_view.size.x, core.root_view.size.y
  pk.x = math.max(0, math.min(pk.x, sw - W))
  if pk.y + H > sh then pk.y = math.max(0, y - H - (opts.above or 0)) end
  return pk
end
function P:color()
  local r, g, b = P.rgb(self)
  local function byte(v) return math.floor(v * 255 + 0.5) end
  return { byte(r), byte(g), byte(b), self.a and byte(self.a) or 255 }
end
function P:changed(final) if self.on_change then self.on_change(self:color(), final) end end
function P:draw() P.draw_parts(self, { text = self.typing }) end
function P:pressed(button, x, y)
  local part = P.part_at(self, x, y)
  if not part then self:commit(); return false end
  if button ~= "left" then return true end
  if part == "hex" then self:type_hex(x, y); core.redraw = true; return true end
  if part ~= "box" then
    self:commit()
    self.drag = part
    P.pick_at(self, part, x, y)
    self:changed(false)
  end
  return true
end
function P:moved(x, y)
  if self.hex_drag and self.tf then require("plugins.canvas.field").mouse(self.tf, "moved", x, y) return true end
  if not self.drag then return P.part_at(self, x, y) ~= nil end
  P.pick_at(self, self.drag, x, y)
  self:changed(false)
  return true
end
function P:released()
  if self.hex_drag then
    self.hex_drag = nil
    if self.tf then require("plugins.canvas.field").mouse(self.tf, "released", 0, 0) end
    return true
  end
  if not self.drag then return false end
  self.drag = nil
  self:changed(true)
  return true
end
function P:commit()                                -- the hex typed so far, if it's one
  if not self.typing then return end
  local r, g, b, a = P.parse_hex(self.typing)
  local tf = self.tf
  self.typing, self.tf = nil, nil
  if tf then require("plugins.canvas.field").blur(tf) end
  if r then
    self.h, self.s, self.v = P.rgb2hsv(r / 255, g / 255, b / 255)
    if a and self.a then self.a = a / 255 end
    self:changed(true)
  end
  core.redraw = true
end
-- the hex row typed: in lite (plugins/textproxy.lua: selection, words, the
-- clipboard, undo), what a hex can hold only (#, 0-9, a-f; 9 at most); it
-- starts as the colour now, all of it selected. Enter keeps it, Escape drops it
local Field = require "plugins.canvas.field"
function P:type_hex(x, y)
  if self.tf and Field.focused(self.tf) then       -- (typing already: the caret there, a drag selects)
    Field.mouse(self.tf, "pressed", x, y, 1)
    self.hex_drag = true
    return
  end
  local t = P.hex(self)
  self.typing = t
  local tf = Field.new(t)
  self.tf = tf
  Field.focus(tf, {
    font = style.code_font, select_all = true,
    on_key = function(k)
      if k == "return" or k == "keypad enter" then self:commit() return true end
      if k == "escape" then self.typing, self.tf = nil, nil; Field.blur(tf); core.redraw = true return true end
      return false
    end,
    on_change = function(text)
      local clean = text:gsub("[^#%x]", ""):sub(1, 9)
      if clean ~= text then Field.set(tf, clean) end
      self.typing = clean
      core.redraw = true
    end,
    on_blur = function() if self.tf == tf then self.typing, self.tf = nil, nil end end,
  })
end
function P:text_input(t) return false end          -- (lite has the keys and the text while it types)
function P:key(k) return false end

return P

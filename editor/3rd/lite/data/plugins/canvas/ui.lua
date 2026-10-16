-- ui.lua - canvas.ui: a side panel of widgets for a plugin's tab (Replay):
-- headings, labels, buttons, sliders, checkboxes, choices, colours. Immediate
-- mode, as the atlas's panels: the view draws the panel every frame and the
-- panel remembers where its widgets were for the mouse.
--
--   local ui = canvas.ui.new()                 -- one per view
--   -- draw_overlay():
--   ui:begin(x, y, w, h)                       -- a panel (background, scroll)
--   ui:head("Emitter")
--   ui:slider("Rate", e.rate, 0, 500, function(v) e.rate = v end, { fmt = "%.0f/s", step = 1, def = 50 })
--   ui:check("Loop", e.loop, function() e.loop = not e.loop end)
--   ui:choice("Shape", e.shape, { "point", "circle", "box" }, function(v) e.shape = v end)
--   ui:buttons({ { "Play", play, accent = true }, { "Save", save } })
--   ui:finish()
--   -- the mouse: ui:pressed(button, x, y, clicks) / ui:moved(x, y) /
--   -- ui:released(button) / ui:wheel(dy) -> true when the panel took it
--
-- A slider: click or drag sets it, SHIFT drags finely, double-click resets it
-- to opts.def, CTRL+wheel over it nudges it (opts.step; the wheel alone
-- scrolls the panel). A choice: click the next, RMB the one before. on_change(v) gets the
-- new value; opts.done() (optional) when a drag ends (an undo step, a sound).
local core = require "core"
local style = require "core.style"
local keymap = require "core.keymap"
local Picker = require "plugins.canvas.picker"
local Field = require "plugins.canvas.field"
local Scrollbar = require "plugins.canvas.scrollbar"
local Tip = require "plugins.canvas.tip"

local UI = {}
UI.__index = UI

local function S(n) return math.floor(n * SCALE + 0.5) end
local function frame(x, y, w, h, c)
  renderer.draw_rect(x, y, w, 1, c); renderer.draw_rect(x, y + h - 1, w, 1, c)
  renderer.draw_rect(x, y, 1, h, c); renderer.draw_rect(x + w - 1, y, 1, h, c)
end
local function mix(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, 255 } end

function UI.new()
  return setmetatable({ hits = {}, scroll = 0, mx = -1, my = -1, sb = Scrollbar.new(), moved_at = 0 }, UI)
end

-- a panel: x, y, w, h on screen (the content scrolls when it's taller)
function UI:begin(x, y, w, h, opts)
  self.x, self.y, self.w, self.h = x, y, w, h
  self.hits = {}
  self.pad = S(10)
  self.row = style.font:get_height() + S(10)
  if not (opts and opts.flat) then
    renderer.draw_rect(x, y, w, h, style.background2)
    renderer.draw_rect(opts and opts.divider_right and x + w - 1 or x, y, 1, h, style.divider)
  end
  core.push_clip_rect(x, y, w, h)
  self.cy = y + self.pad - self.scroll
end
function UI:finish()
  core.pop_clip_rect()
  if UI.popup and UI.popup_owner == self then core.root_view:defer_draw(function() if UI.popup then UI.popup:draw() end end) end
  local content = self.cy + self.scroll - self.y + self.pad
  self.max_scroll = math.max(0, content - self.h)
  if self.scroll > self.max_scroll then self.scroll = self.max_scroll end
  self.sb:draw(self.x + self.w - S(7), self.y, S(7), self.h, content, self.h, self.scroll, { no_track = true })   -- (canvas.scrollbar: drag it)
  local h = self:hit_at(self.mx, self.my)          -- a widget's tip (opts.tip), once the mouse rests on it
  if h and h.tip and not self.active and not UI.popup and system.get_time() - self.moved_at >= Tip.DELAY then
    local mx, my, tip = self.mx, self.my, h.tip
    core.root_view:defer_draw(function() Tip.text(tip, mx, my, { x = 0, y = 0, w = core.root_view.size.x, h = core.root_view.size.y }) end)
  elseif h and h.tip then core.redraw = true end   -- (until it shows)
end
function UI:hit_at(x, y)
  if not self:inside(x, y) then return nil end
  for i = #self.hits, 1, -1 do
    local h = self.hits[i]
    if x >= h[1] and x < h[1] + h[3] and y >= h[2] and y < h[2] + h[4] then return h end
  end
end

local function hot(self, x, y, w, h) return self.mx >= x and self.mx < x + w and self.my >= y and self.my < y + h end
function UI:hit(x, y, w, h, t)                     -- t: { press = fn(mx, my, clicks, button), drag = fn(mx, my), wheel = fn(dy) }
  t[1], t[2], t[3], t[4] = x, y, w, h
  self.hits[#self.hits + 1] = t
end

function UI:space(px) self.cy = self.cy + (px or S(6)) end
function UI:head(text)
  self.cy = self.cy + S(2)
  renderer.draw_text(style.font, text, self.x + self.pad, self.cy + S(3), style.accent)
  self.cy = self.cy + self.row
end
function UI:label(text, value, color)
  local f, x, w = style.font, self.x + self.pad, self.w - self.pad * 2
  renderer.draw_text(f, text, x, self.cy + S(3), style.dim)
  if value then
    value = tostring(value)
    while #value > 1 and f:get_width(value) > w - f:get_width(text) - S(10) do value = value:sub(1, -3) end
    renderer.draw_text(f, value, x + w - f:get_width(value), self.cy + S(3), color or style.text)
  end
  self.cy = self.cy + self.row
end
function UI:text(text, color)                      -- a line of text (cut to the panel)
  renderer.draw_text(style.font, text, self.x + self.pad, self.cy + S(3), color or style.dim)
  self.cy = self.cy + self.row
end

-- a button anywhere (toolbars too): returns its width
function UI:button_at(x, y, text, fn, accent, on, tip)
  local f = style.font
  local pad = S(8)
  local w, h = f:get_width(text) + pad * 2, f:get_height() + S(6)
  local is_hot = fn and hot(self, x, y, w, h)
  if accent or on then renderer.draw_rect(x, y, w, h, style.accent)
  else
    if is_hot then renderer.draw_rect(x, y, w, h, style.background3) end
    frame(x, y, w, h, is_hot and style.dim or style.divider)
  end
  renderer.draw_text(f, text, x + pad, y + S(3), (accent or on) and style.background or (fn and style.text or style.dim))
  if fn or tip then self:hit(x, y, w, h, { press = fn and function() fn() end, tip = tip }) end
  return w
end
-- buttons in rows: { { "text", fn, accent = bool, on = bool }, ... }
function UI:buttons(list)
  local x0, x1 = self.x + self.pad, self.x + self.w - self.pad
  local x, gap = x0, S(6)
  local h = style.font:get_height() + S(6)
  for _, b in ipairs(list) do
    local bw = style.font:get_width(b[1]) + S(16)
    if x > x0 and x + bw > x1 then x = x0; self.cy = self.cy + h + gap end
    x = x + self:button_at(x, self.cy, b[1], b[2], b.accent, b.on, b.tip) + gap
  end
  self.cy = self.cy + h + S(8)
end

function UI:check(text, on, fn)
  local f = style.font
  local s = f:get_height() - S(2)
  local x, y, rh = self.x + self.pad, self.cy + S(4), self.row
  local is_hot = hot(self, self.x, self.cy, self.w, rh)
  frame(x, y, s, s, is_hot and style.text or style.dim)
  if on then renderer.draw_rect(x + S(3), y + S(3), s - S(6), s - S(6), style.accent) end
  renderer.draw_text(f, text, x + s + S(8), self.cy + S(3), style.text)
  self:hit(self.x, self.cy, self.w, rh, { press = function() fn() end })
  self.cy = self.cy + rh
end

-- one of a list: a click the next, RMB / the wheel the one before
function UI:choice(text, value, options, set)
  local f = style.font
  local x, w, rh = self.x + self.pad, self.w - self.pad * 2, self.row
  renderer.draw_text(f, text, x, self.cy + S(3), style.dim)
  local vx = x + math.floor(math.max(w * 0.35, math.min(w * 0.55, f:get_width(text) + S(12))))
  local bw, bh = x + w - vx, rh - S(4)
  local is_hot = hot(self, vx, self.cy, bw, bh)
  renderer.draw_rect(vx, self.cy, bw, bh, is_hot and style.background3 or style.background)
  local label = tostring(value)
  renderer.draw_text(f, label, vx + S(8), self.cy + S(2), style.text)
  renderer.draw_text(f, "<>", vx + bw - f:get_width("<>") - S(6), self.cy + S(2), style.dim)
  local function step(d)
    local i = 1
    for k, o in ipairs(options) do if o == value then i = k end end
    set(options[(i - 1 + d) % #options + 1])
  end
  self:hit(vx, self.cy, bw, bh, { press = function(_, _, _, button) step(button == "right" and -1 or 1) end,
                                  wheel = function(dy) step(dy > 0 and -1 or 1) end })
  self.cy = self.cy + rh
end

-- a number: a bar filled to its value, the label in it, the value right
function UI:slider(text, value, min, max, on_change, opts)
  opts = opts or {}
  local f = style.font
  local x, w, rh = self.x + self.pad, self.w - self.pad * 2, self.row
  local bh = rh - S(4)
  value = tonumber(value) or opts.def or min
  local t = (math.max(min, math.min(max, value)) - min) / (max - min)
  local is_hot = hot(self, x, self.cy, w, bh) or self.dragging == text
  renderer.draw_rect(x, self.cy, w, bh, is_hot and style.background3 or style.background)
  local fill = opts.color or mix(style.background, style.accent, 0.28)
  if min < 0 and max > 0 then                      -- (both ways: filled from 0)
    local z = x + w * (-min / (max - min))
    local v = x + w * t
    renderer.draw_rect(math.min(z, v), self.cy, math.abs(v - z), bh, fill)
    renderer.draw_rect(math.floor(z), self.cy, 1, bh, style.dim)
  else
    renderer.draw_rect(x, self.cy, math.floor(w * t), bh, fill)
  end
  renderer.draw_text(f, text, x + S(6), self.cy + S(2), style.text)
  local vs = string.format(opts.fmt or "%.3f", value)
  renderer.draw_text(f, vs, x + w - f:get_width(vs) - S(6), self.cy + S(2), style.text)
  local function clamp(v)
    if opts.int then v = math.floor(v + 0.5) end
    return math.max(min, math.min(max, v))
  end
  local function at(mx) return clamp(min + (max - min) * math.max(0, math.min(1, (mx - x) / w))) end
  local grab = { x0 = 0, v0 = value }
  self:hit(x, self.cy, w, bh, {
    press = function(mx, _, clicks)
      if clicks >= 2 and opts.def ~= nil then on_change(opts.def); return end
      grab.x0, grab.v0 = mx, value
      self.dragging = text
      if not keymap.modkeys["shift"] then on_change(at(mx)) end
    end,
    drag = function(mx)
      if keymap.modkeys["shift"] then on_change(clamp(grab.v0 + (mx - grab.x0) / w * (max - min) * 0.1))
      else on_change(at(mx)) end
    end,
    done = opts.done,
    wheel = function(dy)
      local step = opts.step or (max - min) / 100
      on_change(clamp(value + (dy > 0 and step or -step)))
      if opts.done then opts.done() end
    end,
  })
  self.cy = self.cy + rh
end

-- a colour { r, g, b, a } (0..255): a swatch and its hex; a click opens the
-- colour picker (plugins/canvas/picker.lua, the node graph's) beside it.
-- on_change(c) while picking; opts.done() when a pick ends (an undo step)
function UI:color(text, c, on_change, opts)
  opts = opts or {}
  local f = style.font
  local x, w, rh = self.x + self.pad, self.w - self.pad * 2, self.row
  renderer.draw_text(f, text, x, self.cy + S(3), style.dim)
  local sw, sh = S(40), rh - S(8)
  local sx, sy = x + w - sw, self.cy + S(2)
  local hex = string.format("#%02x%02x%02x", c[1] or 0, c[2] or 0, c[3] or 0) .. ((c[4] or 255) < 255 and string.format("%02x", c[4]) or "")
  local is_hot = hot(self, x, self.cy, w, rh)
  renderer.draw_text(style.code_font, hex, sx - style.code_font:get_width(hex) - S(8), self.cy + S(3), is_hot and style.text or style.dim)
  renderer.draw_rect(sx, sy, sw, sh, { c[1], c[2], c[3], 255 })
  local cut = math.floor(sw * (1 - (c[4] or 255) / 255))   -- (its alpha: the right part shows the background)
  if cut > 0 then renderer.draw_rect(sx + sw - cut, sy, cut, sh, style.background) end
  frame(sx, sy, sw, sh, is_hot and style.text or style.dim)
  local px, py = sx + sw - Picker.W * SCALE, self.cy + rh   -- (the picker under the row, its right edge on the swatch's)
  self:hit(x, self.cy, w, rh, { press = function()
    UI.popup = Picker.new(px, py, c, function(nc, final)
      on_change(nc)
      if final and opts.done then opts.done() end
    end, { alpha = true, above = rh })
    UI.popup_owner = self
  end })
  self.cy = self.cy + rh
end

-- a sheet of tiles (an Image cut in cells of `cell` px, `cols` a row): drawn
-- to the panel's width; a click picks one, a drag a rectangle of them.
-- sel = { i, j } (the first and last index, 0-based; nil: none);
-- on_pick(i, j). -> the index under the mouse, or nil
function UI:tiles(img, cell, sel, on_pick, opts)
  opts = opts or {}
  local iw, ih = img:get_size()
  local cols, rows = math.floor(iw / cell), math.floor(ih / cell)
  if opts.rows then rows = math.min(rows, opts.rows) end
  local x, w = self.x + self.pad, self.w - self.pad * 2
  local s = math.max(1, math.floor(w / cols))      -- (whole pixels a cell)
  local y = self.cy
  renderer.draw_rect(x, y, s * cols, s * rows, style.background)
  for r = 0, rows - 1 do                           -- (row by row: the rows of the sheet)
    renderer.draw_image(img, x, y + r * s, s * cols, s, nil, 0, r * cell, cols * cell, cell)
  end
  local function cell_at(mx, my)
    local cx, cy = math.floor((mx - x) / s), math.floor((my - y) / s)
    if cx < 0 or cy < 0 or cx >= cols or cy >= rows then return nil end
    return cy * cols + cx
  end
  local hot_i = hot(self, x, y, s * cols, s * rows) and cell_at(self.mx, self.my) or nil
  if sel and sel[1] then                           -- the picked ones: a frame around them
    local a, b = sel[1], sel[2] or sel[1]
    local fl = math.floor
    local x0, y0 = math.min(a % cols, b % cols), math.min(fl(a / cols), fl(b / cols))
    local x1, y1 = math.max(a % cols, b % cols), math.max(fl(a / cols), fl(b / cols))
    frame(x + x0 * s - 1, y + y0 * s - 1, (x1 - x0 + 1) * s + 2, (y1 - y0 + 1) * s + 2, style.accent)
    frame(x + x0 * s, y + y0 * s, (x1 - x0 + 1) * s, (y1 - y0 + 1) * s, style.background)
  end
  if hot_i then frame(x + (hot_i % cols) * s, y + math.floor(hot_i / cols) * s, s, s, style.text) end
  local first
  self:hit(x, y, s * cols, s * rows, {
    press = function(mx, my) first = cell_at(mx, my); if first then on_pick(first, first) end end,
    drag = function(mx, my)
      local c = cell_at(math.max(x, math.min(x + s * cols - 1, mx)), math.max(y, math.min(y + s * rows - 1, my)))
      if first and c then on_pick(first, c) end
    end,
  })
  self.cy = y + s * rows + S(6)
  return hot_i
end

-- the mouse (in screen pixels): true when it was the panel's
-- a number with - / + beside it (a step each click): text, its value shown, minus(), plus()
function UI:stepper(text, value, minus, plus, opts)
  local f = style.font
  local x, w = self.x + self.pad, self.w - self.pad * 2
  renderer.draw_text(f, text, x, self.cy + S(3), style.dim)
  local bw = f:get_width("+") + S(16)
  local bx = x + w - bw
  self:button_at(bx, self.cy, "+", plus, nil, nil, opts and opts.tip)
  local vs = tostring(value)
  bx = bx - S(8) - f:get_width(vs)
  renderer.draw_text(f, vs, bx, self.cy + S(3), style.text)
  self:button_at(bx - S(8) - bw, self.cy, "-", minus, nil, nil, opts and opts.tip)
  self.cy = self.cy + self.row
end

-- a line of text to type in: a click edits it (Enter keeps it, Escape drops
-- it, a click elsewhere keeps it); on_commit(text) when kept and changed
function UI:field(text, value, on_commit, opts)
  local f = style.font
  local x, w, rh = self.x + self.pad, self.w - self.pad * 2, self.row
  local lw = text ~= "" and math.floor(math.max(w * 0.3, math.min(w * 0.5, f:get_width(text) + S(12)))) or 0
  if text ~= "" then renderer.draw_text(f, text, x, self.cy + S(3), style.dim) end
  local fx, fw, fh = x + lw, w - lw, rh - S(4)
  local ed = UI.editing and UI.editing.owner == self and UI.editing.key == (opts and opts.key or text) and UI.editing
  renderer.draw_rect(fx, self.cy, fw, fh, ed and style.background or (hot(self, fx, self.cy, fw, fh) and style.background3 or style.background))
  if ed then
    ed.rect = { fx, self.cy, fw, fh }
    frame(fx, self.cy, fw, fh, style.caret)
    core.push_clip_rect(fx, self.cy, fw, fh)
    Field.draw(ed.e, f, fx + S(6), self.cy + S(2), style.text, style.caret)
    core.pop_clip_rect()
  else
    renderer.draw_text(f, tostring(value or ""), fx + S(6), self.cy + S(2), style.text)
  end
  local function mouse(what, mx, my, clicks)        -- (typing: lite places the caret, a drag selects)
    local e = UI.editing
    if e and e.owner == self and e.key == (opts and opts.key or text) then Field.mouse(e.e, what, mx, my, clicks) end
  end
  self:hit(fx, self.cy, fw, fh, { tip = opts and opts.tip,
    press = function(mx, my, clicks)
      if not ed then
        UI.commit_edit()
        local e = { owner = self, key = opts and opts.key or text, e = Field.new(tostring(value or "")), commit = on_commit,
                    orig = tostring(value or ""), rect = { fx, self.cy, fw, fh } }
        UI.editing = e
        Field.focus(e.e, {                         -- (lite edits it: selection, words, the clipboard, undo)
          font = f,
          on_key = function(k)
            if k == "return" or k == "keypad enter" then UI.commit_edit() return true end
            if k == "escape" then UI.commit_edit(true) return true end
            return false
          end,
          on_blur = function() if UI.editing == e then UI.commit_edit() end end,   -- (a click elsewhere: kept)
        })
        e.e.tp:place(fx + S(6), self.cy + S(2), f:get_height())
      end
      mouse("pressed", mx, my, clicks)
    end,
    drag = function(mx, my) mouse("moved", mx, my) end,
    done = function() mouse("released", 0, 0) end,
  })
  self.cy = self.cy + rh
end
function UI.commit_edit(cancel)                    -- (the field being typed in: kept, or dropped)
  local ed = UI.editing
  UI.editing = nil
  if ed then Field.blur(ed.e) end
  core.redraw = true
  if ed and not cancel and ed.e.text ~= ed.orig and ed.commit then ed.commit(ed.e.text) end
end

-- a list: rows of { text, info = "right", kind = "head" | "item" | "dim",
-- indent = n, selected = bool, icon = function(x, y, size) end (a picture),
-- press = function(clicks) end, button = { "x", fn, tip = }, tip = "..." }.
-- An item's button shows while the mouse is over its row. opts.reveal = i:
-- that row scrolled into view (once). -> the row under the mouse.
function UI:list(rows, opts)
  local f, pad = style.font, self.pad
  local rh = opts and opts.row or self.row
  local hovered
  for i, r in ipairs(rows) do
    local ry, x, w = self.cy, self.x, self.w
    if opts and opts.reveal == i then              -- (in view: the panel scrolls to it)
      local top = ry + self.scroll - self.y
      if top < self.scroll then self.scroll = top - pad
      elseif top + rh > self.scroll + self.h then self.scroll = top + rh - self.h + pad end
    end
    local act = r.press or r.button
    local is_hot = act and hot(self, x, ry, w, rh) and self:inside(self.mx, self.my)
    if is_hot then hovered = i end
    if r.selected then renderer.draw_rect(x, ry, w, rh, style.selection or style.background3)
    elseif is_hot then renderer.draw_rect(x, ry, w, rh, style.background3) end
    local tx = x + pad + (r.indent or 0) * S(12)
    if r.icon then local sz = rh - S(6); r.icon(tx, ry + S(3), sz); tx = tx + sz + S(6) end
    local bw = (is_hot and r.button) and (f:get_width(r.button[1]) + S(16)) or 0
    local iw = r.info and (f:get_width(r.info) + pad) or 0
    local c = (r.kind == "head" and style.accent) or (r.kind == "dim" and style.dim) or style.text
    local text = tostring(r.text or "")
    local room = x + w - tx - iw - bw - pad
    while #text > 1 and f:get_width(text) > room do text = text:sub(1, -2) end
    local ty = ry + math.floor((rh - f:get_height()) / 2)
    renderer.draw_text(f, text, tx, ty, c)
    if r.info then renderer.draw_text(f, r.info, x + w - pad - bw - f:get_width(r.info), ty, style.dim) end
    if r.press or r.tip then self:hit(x, ry, w, rh, { press = r.press and function(_, _, clicks) r.press(clicks) end, tip = r.tip }) end
    if is_hot and r.button then
      self:button_at(x + w - pad - bw + S(4), ry + math.floor((rh - f:get_height() - S(6)) / 2), r.button[1], r.button[2], nil, nil, r.button.tip)
    end
    self.cy = self.cy + rh
  end
  return hovered                                   -- (the row under the mouse)
end

function UI:inside(x, y) return self.x and x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h end
-- a popup open (the colour picker: UI.popup, any panel's) takes the mouse first
function UI:pressed(button, x, y, clicks)
  if UI.popup then
    if UI.popup:pressed(button, x, y) then core.redraw = true; return true end
    UI.popup, UI.popup_owner = nil, nil            -- (a click outside: closed, and taken)
    core.redraw = true
    return true
  end
  self.mx, self.my = x, y
  local er = UI.editing and UI.editing.rect       -- (a field being typed in: a click elsewhere keeps it)
  if er and not (x >= er[1] and x < er[1] + er[3] and y >= er[2] and y < er[2] + er[4]) then UI.commit_edit() end
  if not self:inside(x, y) then return false end
  local on, p = self.sb:pressed(x, y)              -- (its scroll bar: dragged)
  if on then self.scroll = math.max(0, math.min(self.max_scroll or 0, p)); core.redraw = true; return true end
  for i = #self.hits, 1, -1 do
    local h = self.hits[i]
    if x >= h[1] and x < h[1] + h[3] and y >= h[2] and y < h[2] + h[4] then
      if h.press and (button == "left" or (button == "right" and h.wheel)) then
        h.press(x, y, clicks, button)
        if h.drag and button == "left" then self.active = h end
        core.redraw = true
      end
      return true
    end
  end
  return true
end
function UI:moved(x, y)
  if UI.popup and UI.popup:moved(x, y) then core.redraw = true; return true end
  local was = self.mx >= 0 and self:inside(self.mx, self.my)
  self.mx, self.my, self.moved_at = x, y, system.get_time()
  local p = self.sb:moved(x, y)
  if p then self.scroll = math.max(0, math.min(self.max_scroll or 0, p)); core.redraw = true; return true end
  if self.active then self.active.drag(x, y); core.redraw = true; return true end
  if was or self:inside(x, y) then core.redraw = true end
  return self:inside(x, y)
end
function UI:released(button)
  if UI.popup and UI.popup:released() then return true end
  if self.sb:released() then return true end
  if self.active then
    local done = self.active.done
    self.active, self.dragging = nil, nil
    if done then done() end
    core.redraw = true
    return true
  end
  return false
end
function UI:wheel(dy)
  if not self:inside(self.mx, self.my) then return false end
  for i = #self.hits, 1, -1 do
    local h = self.hits[i]
    if h.wheel and self.mx >= h[1] and self.mx < h[1] + h[3] and self.my >= h[2] and self.my < h[2] + h[4]
       and keymap.modkeys["ctrl"] then             -- (CTRL+wheel on a value: changes it; the wheel alone scrolls)
      h.wheel(dy); core.redraw = true; return true
    end
  end
  self.scroll = math.max(0, math.min(self.max_scroll or 0, self.scroll - dy * self.row * 2))
  core.redraw = true
  return true
end

-- typing a hex in the picker: the keys and the text are its while it types
local on_key_pressed = keymap.on_key_pressed
function keymap.on_key_pressed(k, ...)
  -- (a field being typed in: lite has the keys, plugins/textproxy.lua)
  if UI.popup and UI.popup.typing and UI.popup:key(k) then return true end
  if UI.popup and k == "escape" then UI.popup, UI.popup_owner = nil, nil; core.redraw = true; return true end
  return on_key_pressed(k, ...)
end
local RootView = require "core.rootview"
local on_text_input = RootView.on_text_input
function RootView:on_text_input(t, ...)
  if UI.popup and UI.popup:text_input(t) then return end
  return on_text_input(self, t, ...)
end

return UI

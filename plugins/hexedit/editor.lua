-- editor.lua - the hex editor (runs in lite): any file, of any size, as
-- bytes. The file is read off disk in chunks (hexfile.lua: 1 MiB each, a
-- few kept), so a gigabyte opens at once and scrolls as fast as a small one.
--
-- The offset, the bytes in hex, the same as text. Click a byte (or the
-- arrows) to move; type hex digits (the hex side) or characters (the text
-- side, TAB switches) to change it. Edits are kept aside, lit, until
-- CTRL+S writes them in place (only those bytes). CTRL+F finds (hex
-- "DE AD BE EF" or text; F3 / SHIFT+F3 the next / the one before), CTRL+R
-- replaces all, CTRL+G goes to an offset (hex 0x1F00, or decimal), CTRL+Z
-- undoes an edit, CTRL+C copies the selection (SHIFT+click / SHIFT+arrows)
-- as hex. Under the bytes: the value at the cursor as u8 .. f64.
-- Searching a big file runs in the background (ESC stops it).
-- Saving this file reloads the plugin.
local P = ...
P.title = "Hex editor"                         -- (its name in menus: Open with, the main menu's Plugins)
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local canvas = require "plugins.canvas"
local hex = P.require("hexfile")

local DEFAULTS = { columns = 16, chunk_kib = 1024, big_endian = false }
local cfg = {}
local function load_config()
  local c = P.read("config")
  cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if type(c) == "table" then for k, v in pairs(c) do if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then cfg[k] = v end end end
  cfg.columns = math.max(4, math.min(64, math.floor(cfg.columns)))
  cfg.chunk_kib = math.max(4, math.min(65536, math.floor(cfg.chunk_kib)))
end

local function S(n) return math.floor(n * SCALE + 0.5) end
local function base_of(f) return (f:match("[^/\\]*$")) end
local function size_text(n)
  if n >= 1024 ^ 3 then return string.format("%.2f GiB", n / 1024 ^ 3) end
  if n >= 1024 ^ 2 then return string.format("%.2f MiB", n / 1024 ^ 2) end
  if n >= 1024 then return string.format("%.1f KiB", n / 1024) end
  return n .. " bytes"
end
local history = {}                                 -- (what was looked for: the prompts suggest it)

local HexView = canvas.View:extend()
HexView.grid = false
HexView.wants_ctrl_wheel = false

function HexView:new(state)
  HexView.super.new(self)
  self.sb = canvas.scrollbar.new()                 -- (the whole file's: rows)
  self.filename = state and state.filename or ""
  self.top, self.cur, self.nib, self.side = 0, state and state.cur or 0, 0, "hex"
  self.undo = {}
  self:open()
  self.top = math.max(0, math.floor((state and state.top or 0)))
end
function HexView:open()
  if self.f then self.f:close() end
  local f, err = hex.open(self.filename, { chunk = cfg.chunk_kib * 1024 })
  self.f, self.err = f, not f and err or nil
  local info = system.get_file_info(self.filename)
  self.mtime = info and info.modified
  self.undo = {}
  core.redraw = true
end
function HexView:get_name() return base_of(self.filename) .. (self.dirty and "*" or "") end
function HexView:get_state() return { filename = self.filename, top = self.top, cur = self.cur } end
function HexView:fsize() return self.f and self.f.size or 0 end
function HexView:try_close(do_close)
  HexView.super.try_close(self, function() if self.f then self.f:close() end do_close() end)
end

-- the layout: rows of `cols` bytes
function HexView:metrics()
  local font = style.code_font
  local cw, lh = font:get_width("0"), font:get_height() + S(4)
  local digits = math.max(8, #string.format("%X", math.max(0, self:fsize() - 1)))
  local cols = cfg.columns
  local x0 = self.position.x + S(10)
  local hx = x0 + cw * (digits + 2)                -- the bytes
  local gap = cw                                   -- (a space every 8)
  local tx = hx + cols * cw * 3 + math.floor((cols - 1) / 8) * gap + cw * 2   -- the text
  local y0 = self.position.y + S(8) + lh           -- (a header row: the columns)
  local foot = lh * 2 + S(10)                       -- (the values, the status)
  local rows = math.max(1, math.floor((self.size.y - (y0 - self.position.y) - foot) / lh))
  return { font = font, cw = cw, lh = lh, digits = digits, cols = cols, x0 = x0, hx = hx, gap = gap, tx = tx, y0 = y0, rows = rows }
end
function HexView:byte_x(m, c) return m.hx + c * m.cw * 3 + math.floor(c / 8) * m.gap end
function HexView:total_rows(m) return math.max(1, math.ceil(self:fsize() / m.cols)) end
function HexView:scroll_to(row)
  local m = self:metrics()
  self.top = math.max(0, math.min(self:total_rows(m) - m.rows, math.floor(row)))
  core.redraw = true
end
function HexView:reveal()                          -- the cursor's row on screen
  local m = self:metrics()
  local row = math.floor(self.cur / m.cols)
  if row < self.top then self:scroll_to(row) elseif row >= self.top + m.rows then self:scroll_to(row - m.rows + 1) end
end
function HexView:move(to, select)
  local n = self:fsize()
  if n == 0 then return end
  if select then self.anchor = self.anchor or self.cur else self.anchor = nil end
  self.cur = math.max(0, math.min(n - 1, math.floor(to)))
  self.nib = 0
  self:reveal()
end
function HexView:selection()                       -- -> first, last (or the cursor's byte)
  local a = self.anchor or self.cur
  return math.min(a, self.cur), math.max(a, self.cur)
end

-- editing ---------------------------------------------------------------
function HexView:set_byte(off, b)
  local was = self.f:set(off, b)
  self.undo[#self.undo + 1] = { off, was }
  self.dirty = self.f.nedits > 0
  core.redraw = true
end
function HexView:undo_step()
  local u = table.remove(self.undo)
  if not u then return end
  self.f:unset(u[1], u[2])
  self.cur, self.nib, self.anchor = u[1], 0, nil
  self.dirty = self.f.nedits > 0
  self:reveal()
end
function HexView:on_text_input(text)
  if not self.f or self.job or self:fsize() == 0 then return end
  for ch in text:gmatch(utf8 and utf8.charpattern or ".") do
    if self.side == "hex" then
      local d = tonumber(ch, 16)
      if d and #ch == 1 then
        local b = self.f:byte(self.cur) or 0
        if self.nib == 0 then b = d * 16 + b % 16 else b = math.floor(b / 16) * 16 + d end
        self:set_byte(self.cur, b)
        if self.nib == 0 then self.nib = 1 else self:move(self.cur + 1); self.nib = 0 end
      end
    elseif #ch == 1 then
      self:set_byte(self.cur, ch:byte())
      self:move(self.cur + 1)
    end
  end
end
function HexView:save()
  if not self.f then return end
  local n = self.f.nedits
  local ok, err = self.f:save()
  if not ok then core.error("hexedit: can't write %s: %s", base_of(self.filename), tostring(err)) return end
  local info = system.get_file_info(self.filename)
  self.mtime = info and info.modified
  self.dirty, self.undo = false, {}
  core.log("Saved %s: %d bytes changed", base_of(self.filename), n)
  self:flash("Saved")                              -- (canvas.tip: a note on the tab, bottom right)
end

-- find / replace / go to: the command line, then a background job (a big
-- file takes a while: the status shows how far, ESC stops it)
function HexView:job_run(what, fn)
  if self.job then return end
  self.job = { what = what, done = 0, total = self:fsize() }
  core.add_thread(function()
    local step = function(done, total)
      self.job.done, self.job.total = done, total
      core.redraw = true
      coroutine.yield()
      return self.job.stop
    end
    local ok, err = pcall(fn, step)
    self.job = nil
    if not ok then core.error("hexedit: %s", tostring(err)) end
    core.redraw = true
  end)
end
local function suggest(text)
  local out = {}
  for i = #history, 1, -1 do if history[i]:lower():find(text:lower(), 1, true) then out[#out + 1] = history[i] end end
  return out
end
local function remember(s)
  for i = #history, 1, -1 do if history[i] == s then table.remove(history, i) end end
  history[#history + 1] = s
end
function HexView:find_next(back)
  if not self.pat or not self.f then return self:prompt_find() end
  local pat, from = self.pat, back and self.cur or self.cur + 1
  self:job_run("Finding", function(step)
    local at = self.f:find(pat, from, back, step)
    if at then
      self.cur, self.anchor, self.nib = at, nil, 0   -- (the cursor at its start, the match lit)
      self:reveal()
      self.found = { at, #pat }
    else
      core.log("hexedit: %s not found %s", self.pat_text, back and "before here" or "after here")
    end
  end)
end
function HexView:prompt_find()
  core.command_view:enter('Find (hex: DE AD BE EF, or text; "quoted" for text that looks like hex)', function(text)
    if text == "" then return end
    remember(text)
    local pat, kind = hex.pattern(text)
    self.pat, self.pat_text = pat, (kind == "hex" and hex.to_hex(pat) or ('"' .. pat .. '"'))
    self:find_next(false)
  end, suggest)
end
function HexView:prompt_replace()
  core.command_view:enter("Replace all (what: hex or text)", function(text)
    if text == "" then return end
    remember(text)
    local pat = hex.pattern(text)
    core.command_view:enter("Replace all " .. hex.to_hex(pat) .. " with", function(text2)
      remember(text2)
      local rep = hex.pattern(text2)
      local same = #rep == #pat
      self:job_run("Replacing", function(step)
        local n, err = self.f:replace_all(pat, rep, step)
        if not n then core.error("hexedit: replace: %s", tostring(err)) return end
        if same then self.dirty = self.f.nedits > 0
        else
          self.undo, self.dirty = {}, false
          local info = system.get_file_info(self.filename)
          self.mtime = info and info.modified
        end
        core.log("hexedit: %d replaced%s", n, same and " (CTRL+S writes them)" or ": the file was written again, now " .. size_text(self.f.size))
      end)
    end, suggest)
  end, suggest)
end
function HexView:prompt_goto()
  core.command_view:enter(string.format("Go to offset (0x1F00 hex, 8000 decimal, +16 / -16; 0 .. %X)", math.max(0, self:fsize() - 1)), function(text)
    text = text:gsub("%s", "")
    local sign, rest = text:match("^([+-]?)(.*)$")
    local v = rest:match("^0[xX]%x+$") and tonumber(rest:sub(3), 16) or rest:match("^%x+[hH]$") and tonumber(rest:sub(1, -2), 16)
              or tonumber(rest)
    if not v then core.error("hexedit: not an offset: %s", text) return end
    if sign == "+" then v = self.cur + v elseif sign == "-" then v = self.cur - v end
    self:move(v)
    self:scroll_to(math.floor(self.cur / self:metrics().cols) - 2)
  end)
end
function HexView:copy()
  if not self.f then return end
  local a, b = self:selection()
  if b - a + 1 > 16 * 1024 * 1024 then core.error("hexedit: too much to copy (16 MiB at most)") return end
  system.set_clipboard(self.side == "text" and self.f:read(a, b - a + 1) or hex.to_hex(self.f:read(a, b - a + 1)))
  core.log("hexedit: copied %d bytes as %s", b - a + 1, self.side == "text" and "text" or "hex")
end

-- the mouse ---------------------------------------------------------------
function HexView:hit(x, y)                         -- -> offset, side, nibble (nil: none)
  local m = self:metrics()
  if y < m.y0 then return nil end
  local row = self.top + math.floor((y - m.y0) / m.lh)
  if x >= m.tx then
    local c = math.floor((x - m.tx) / m.cw)
    if c < 0 or c >= m.cols then return nil end
    return row * m.cols + c, "text", 0
  end
  for c = 0, m.cols - 1 do
    local bx = self:byte_x(m, c)
    if x >= bx - m.cw / 2 and x < bx + m.cw * 2.5 then return row * m.cols + c, "hex", x >= bx + m.cw and 1 or 0 end
  end
end
function HexView:scrollbar(m)                      -- x, y, w, h of its track
  return self.position.x + self.size.x - S(12), m.y0, S(10), m.rows * m.lh
end
function HexView:on_mouse_pressed(button, x, y, clicks)
  self.mx, self.my = x, y
  if button ~= "left" then return HexView.super.on_mouse_pressed(self, button, x, y, clicks) end
  local m = self:metrics()
  local on, p = self.sb:pressed(x, y)              -- (the scroll bar: canvas.scrollbar)
  if on then self:scroll_to(p) return true end
  local off, side, nib = self:hit(x, y)
  if off and off < self:fsize() then
    self:move(off, keymap.modkeys["shift"])
    self.side, self.nib = side, nib or 0
    self.selecting = true
  end
  return true
end
function HexView:on_mouse_moved(x, y, dx, dy)
  self.mx, self.my = x, y
  local p = self.sb:moved(x, y)
  if p then self:scroll_to(p)
  elseif self.selecting then
    local off = self:hit(x, y)
    if off then self.anchor = self.anchor or self.cur; self.cur = math.max(0, math.min(self:fsize() - 1, off)); core.redraw = true end
  end
end
function HexView:on_mouse_released(button, x, y)
  self.sb:released()
  self.selecting = nil
  if self.anchor == self.cur then self.anchor = nil end
end
function HexView:on_mouse_wheel(dy, dx)
  self:scroll_to(self.top - (dy or 0) * 3)
  return true
end

-- drawing ---------------------------------------------------------------
function HexView:draw_background_color() return style.background end
function HexView:draw_canvas()
  local m = self:metrics()
  local font, cw, lh = m.font, m.cw, m.lh
  local px, py = self.position.x, self.position.y
  if not self.f then
    renderer.draw_text(style.font, "can't open " .. base_of(self.filename) .. ": " .. tostring(self.err), px + S(10), py + S(10), style.error or style.text)
    return
  end
  local cols, size = m.cols, self:fsize()
  renderer.draw_text(font, "offset", m.x0, py + S(8), style.dim)   -- the header: the columns
  for c = 0, cols - 1 do renderer.draw_text(font, string.format("%02X", c), self:byte_x(m, c), py + S(8), style.dim) end
  renderer.draw_rect(px, m.y0 - S(3), self.size.x, 1, style.divider)
  local first = self.top * cols
  local data = self.f:read(first, m.rows * cols)
  local s1, s2 = self:selection()
  local has_sel = self.anchor ~= nil
  local found = self.found
  local sel_c = style.selection
  local edit_c = style.accent
  local cur_c = { style.caret[1], style.caret[2], style.caret[3], 90 }
  for r = 0, m.rows - 1 do
    local off = first + r * cols
    if off >= size then break end
    local y = m.y0 + r * lh
    renderer.draw_text(font, string.format("%0" .. m.digits .. "X", off), m.x0, y, style.line_number or style.dim)
    for c = 0, cols - 1 do
      local o = off + c
      if o >= size then break end
      local b = data:byte(r * cols + c + 1) or 0
      local bx, tx = self:byte_x(m, c), m.tx + c * cw
      local in_sel = has_sel and o >= s1 and o <= s2
      local in_found = found and o >= found[1] and o < found[1] + found[2]
      if in_sel or in_found then
        renderer.draw_rect(bx - S(2), y, cw * 2 + S(4), lh, sel_c)
        renderer.draw_rect(tx, y, cw, lh, sel_c)
      end
      if o == self.cur then                        -- the cursor: on its side (the nibble), shown on the other
        if self.side == "hex" then
          renderer.draw_rect(bx + self.nib * cw, y, cw, lh, cur_c)
          renderer.draw_rect(tx, y + lh - S(2), cw, S(2), style.caret)
        else
          renderer.draw_rect(tx, y, cw, lh, cur_c)
          renderer.draw_rect(bx, y + lh - S(2), cw * 2, S(2), style.caret)
        end
      end
      local col = self.f:edited(o) and edit_c or (b == 0 and style.dim or style.text)
      renderer.draw_text(font, string.format("%02X", b), bx, y, col)
      local ch = (b >= 32 and b < 127) and string.char(b) or "."
      renderer.draw_text(font, ch, tx, y, self.f:edited(o) and edit_c or ((b >= 32 and b < 127) and style.syntax and style.syntax.string or style.dim))
    end
  end
  -- the scrollbar: where we are in the whole file
  local sx, sy, sw, sh = self:scrollbar(m)
  self.sb:draw(sx, sy, sw, sh, self:total_rows(m), m.rows, self.top, { always = true })
  -- under it: the values at the cursor, and the status
  local fy = m.y0 + m.rows * lh + S(6)
  renderer.draw_rect(px, fy - S(3), self.size.x, 1, style.divider)
  local v = self.f:values(self.cur, cfg.big_endian)
  local parts = { string.format("u8 %s  i8 %s", v.u8 or "-", v.i8 or "-") }
  if v.u16 then parts[#parts + 1] = string.format("u16 %d  i16 %d", v.u16, v.i16) end
  if v.u32 then parts[#parts + 1] = string.format("u32 %d  i32 %d  f32 %.6g", v.u32, v.i32, v.f32) end
  if v.f64 then parts[#parts + 1] = string.format("f64 %.10g", v.f64) end
  renderer.draw_text(font, table.concat(parts, "   ") .. (cfg.big_endian and "   (BE)" or "   (LE)"), m.x0, fy, style.text)
  local a, b = self:selection()
  local status = string.format("%s   %s   at 0x%X (%d)%s%s%s", base_of(self.filename), size_text(size), self.cur, self.cur,
    self.anchor and string.format("   %d selected", b - a + 1) or "",
    self.f.nedits > 0 and string.format("   %d edited (CTRL+S)", self.f.nedits) or "",
    self.side == "text" and "   typing: text" or "   typing: hex")
  if self.job then
    status = string.format("%s... %d%%  (ESC stops)", self.job.what, math.floor(self.job.done / math.max(1, self.job.total) * 100))
  end
  renderer.draw_text(style.font, status, m.x0, fy + lh, self.job and style.accent or style.dim)
end

-- the file changed on disk (and nothing edited here): read again
function HexView:update()
  HexView.super.update(self)
  local now = system.get_time()
  if now < (self.next_check or 0) then return end
  self.next_check = now + 1
  local info = system.get_file_info(self.filename)
  if info and info.modified ~= self.mtime and not self.job and (not self.f or self.f.nedits == 0) then self:open() end
  if P.changed("config") then load_config(); self:open() end
  if P.changed("files") then P.open_with(P.read("files") or {}, HexView) end
end

function HexView:menu_items()                      -- (its source, reload, settings: "Plugin: hexedit", last)
  local DIV = require("plugins.contextmenu").DIVIDER
  return {
    { text = "Find...", info = "CTRL+F", command = function() self:prompt_find() end },
    { text = "Find next", info = "F3", command = function() self:find_next(false) end },
    { text = "Find previous", info = "SHIFT+F3", command = function() self:find_next(true) end },
    { text = "Replace all...", info = "CTRL+R", command = function() self:prompt_replace() end },
    { text = "Go to offset...", info = "CTRL+G", command = function() self:prompt_goto() end },
    DIV,
    { text = "Copy selection", info = "CTRL+C", command = function() self:copy() end },
    { text = "Undo edit", info = "CTRL+Z", command = function() self:undo_step() end },
    { text = "Save edits", info = "CTRL+S", command = function() self:save() end },
    { text = "Revert (drop the edits)", command = function() self:open(); self.dirty = false end },
    DIV,
    { text = "Type into: hex", checked = self.side == "hex", info = "TAB", command = function() self.side = "hex" end },
    { text = "Type into: text", checked = self.side == "text", info = "TAB", command = function() self.side = "text" end },
    { text = "Values big-endian", checked = cfg.big_endian, command = function() cfg.big_endian = not cfg.big_endian end },
  }
end

-- the keys (only while a hex tab is in front)
local function hv() return core.active_view end
command.add(function() return core.active_view and core.active_view:is(HexView) end, {
  ["hexedit:left"] = function() hv():move(hv().cur - 1) end,
  ["hexedit:right"] = function() hv():move(hv().cur + 1) end,
  ["hexedit:up"] = function() hv():move(hv().cur - cfg.columns) end,
  ["hexedit:down"] = function() hv():move(hv().cur + cfg.columns) end,
  ["hexedit:select-left"] = function() hv():move(hv().cur - 1, true) end,
  ["hexedit:select-right"] = function() hv():move(hv().cur + 1, true) end,
  ["hexedit:select-up"] = function() hv():move(hv().cur - cfg.columns, true) end,
  ["hexedit:select-down"] = function() hv():move(hv().cur + cfg.columns, true) end,
  ["hexedit:page-up"] = function() local m = hv():metrics(); hv():move(hv().cur - cfg.columns * m.rows); hv():scroll_to(hv().top - m.rows) end,
  ["hexedit:page-down"] = function() local m = hv():metrics(); hv():move(hv().cur + cfg.columns * m.rows); hv():scroll_to(hv().top + m.rows) end,
  ["hexedit:home"] = function() hv():move(hv().cur - hv().cur % cfg.columns) end,
  ["hexedit:end"] = function() hv():move(hv().cur - hv().cur % cfg.columns + cfg.columns - 1) end,
  ["hexedit:start"] = function() hv():move(0) end,
  ["hexedit:finish"] = function() hv():move(hv():fsize() - 1) end,
  ["hexedit:side"] = function() local v = hv(); v.side = v.side == "hex" and "text" or "hex"; v.nib = 0; core.redraw = true end,
  ["hexedit:find"] = function() hv():prompt_find() end,
  ["hexedit:find-next"] = function() hv():find_next(false) end,
  ["hexedit:find-previous"] = function() hv():find_next(true) end,
  ["hexedit:replace"] = function() hv():prompt_replace() end,
  ["hexedit:goto"] = function() hv():prompt_goto() end,
  ["hexedit:copy"] = function() hv():copy() end,
  ["hexedit:undo"] = function() hv():undo_step() end,
  ["hexedit:save"] = function() hv():save() end,
  ["hexedit:stop"] = function() local v = hv(); if v.job then v.job.stop = true else v.anchor, v.found = nil, nil; core.redraw = true end end,
})
if not package.loaded["hexedit.keys"] then         -- (once: a reload keeps them)
  package.loaded["hexedit.keys"] = true
  keymap.add {
    ["left"] = "hexedit:left", ["right"] = "hexedit:right", ["up"] = "hexedit:up", ["down"] = "hexedit:down",
    ["shift+left"] = "hexedit:select-left", ["shift+right"] = "hexedit:select-right",
    ["shift+up"] = "hexedit:select-up", ["shift+down"] = "hexedit:select-down",
    ["pageup"] = "hexedit:page-up", ["pagedown"] = "hexedit:page-down",
    ["home"] = "hexedit:home", ["end"] = "hexedit:end", ["ctrl+home"] = "hexedit:start", ["ctrl+end"] = "hexedit:finish",
    ["tab"] = "hexedit:side", ["ctrl+f"] = "hexedit:find", ["f3"] = "hexedit:find-next", ["shift+f3"] = "hexedit:find-previous",
    ["ctrl+r"] = "hexedit:replace", ["ctrl+g"] = "hexedit:goto", ["ctrl+c"] = "hexedit:copy", ["ctrl+z"] = "hexedit:undo",
    ["ctrl+s"] = "hexedit:save", ["escape"] = "hexedit:stop",
  }
end

-- any file as hex: a tab's menu ("Open tab with > Hex editor", "Open beside with >"), the command palette
-- ("Hexedit: Open File...": a path)
local function open_hex(path)
  local node = core.root_view:get_active_node()
  for _, v in ipairs(node.views) do if v:is(HexView) and v.filename == path then node:set_active_view(v) return end end
  node:add_view(HexView({ filename = path }))
end
require("plugins.openwith").register {               -- any file: "Open tab with > Hex editor" (plugins/openwith.lua)
  key = "hexedit", name = "Hex editor", order = 90,
  can = function(path) local i = system.get_file_info(path) return i and i.type == "file" end,
  open = function(path) return HexView({ filename = path }) end,
  is = function(v) return v.is and v:is(HexView) end,
}
command.add(nil, {
  ["hexedit:open-file"] = function()
    core.command_view:enter("Open as hex (a file)", function(text)
      local p = system.absolute_path(text) or text
      if not system.get_file_info(p) then core.error("hexedit: no such file: %s", text) return end
      open_hex((p:gsub("\\", "/")))
    end, function(text)
      local dir, start = text:match("^(.-/?)([^/\\]*)$")
      local out = {}
      for _, e in ipairs(system.list_dir(dir == "" and "." or dir) or {}) do
        if e:lower():sub(1, #start) == start:lower() then
          local info = system.get_file_info((dir == "" and "" or dir) .. e)
          out[#out + 1] = dir .. e .. (info and info.type == "dir" and "/" or "")
        end
      end
      table.sort(out)
      return out
    end)
  end,
})

load_config()
P.open_with(P.read("files") or {}, HexView)
P.commands = { { "Find...", "hexedit:find" }, { "Find next", "hexedit:find-next" }, { "Find previous", "hexedit:find-previous" },
               { "Replace all...", "hexedit:replace" }, { "Go to offset...", "hexedit:goto" }, { "Copy", "hexedit:copy" },
               { "Undo", "hexedit:undo" }, { "Text / hex side", "hexedit:side" }, { "Save", "hexedit:save" } }
P.tab = function() command.perform("hexedit:open-file") end   -- (the main menu's Plugins >: a file, asked for)
return HexView

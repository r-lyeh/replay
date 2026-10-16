-- field.lua - canvas.field: a text being typed (Replay), the node graph's
-- edit box, shared: { text, cur } (cur: the caret, 1-based, before that
-- byte), utf-8 aware. The view keeps it and draws it; these change it:
--
--   local F = canvas.field
--   local e = F.new("hello")               -- { text = "hello", cur = 6 }
--   F.insert(e, "!")  F.backspace(e)  F.delete(e)  F.left(e)  F.right(e)
--   F.home(e)  F.finish(e)  F.paste(e [, multiline])
--   F.key(e, k [, multiline]) -> true when it took the key (backspace, delete,
--     left, right, home, end; shift+return a new line when multiline)
--   F.draw(e, font, x, y, color, caret_color) -> its lines, the caret on its line
local M = {}

local function cont(b) return b and b >= 0x80 and b < 0xC0 end    -- a utf-8 continuation byte
function M.new(text) text = text or ""; return { text = text, cur = #text + 1 } end
function M.step(e, d)                              -- one character left (-1) / right (1): its index
  local i = e.cur + d
  while i > 1 and i <= #e.text and cont(e.text:byte(i)) do i = i + d end
  return math.max(1, math.min(#e.text + 1, i))
end
function M.insert(e, s) e.text = e.text:sub(1, e.cur - 1) .. s .. e.text:sub(e.cur); e.cur = e.cur + #s end
function M.backspace(e) local i = M.step(e, -1); e.text = e.text:sub(1, i - 1) .. e.text:sub(e.cur); e.cur = i end
function M.delete(e) local i = M.step(e, 1); e.text = e.text:sub(1, e.cur - 1) .. e.text:sub(i) end
function M.left(e) e.cur = M.step(e, -1) end
function M.right(e) e.cur = M.step(e, 1) end
function M.home(e) e.cur = 1 end
function M.finish(e) e.cur = #e.text + 1 end
function M.paste(e, multiline)
  local s = system.get_clipboard() or ""
  s = multiline and s:gsub("\r", "") or s:gsub("[\r\n]+", " ")
  M.insert(e, s)
end
local KEYS = { backspace = M.backspace, delete = M.delete, left = M.left, right = M.right, home = M.home, ["end"] = M.finish }
function M.key(e, k, multiline)
  local keymap = require "core.keymap"
  if k == "return" and multiline and keymap.modkeys["shift"] then M.insert(e, "\n") return true end
  if k == "v" and keymap.modkeys["ctrl"] then M.paste(e, multiline) return true end
  local fn = KEYS[k]
  if fn and not keymap.modkeys["ctrl"] and not keymap.modkeys["alt"] then fn(e) return true end
  return false
end

function M.lines(text) local n = 1 for _ in (text or ""):gmatch("\n") do n = n + 1 end return n end
function M.draw(e, font, x, y, color, caret_color)
  local lh = font:get_height()
  local ly = y
  for ln in (e.text .. "\n"):gmatch("(.-)\n") do renderer.draw_text(font, ln, x, ly, color); ly = ly + lh end
  if caret_color then                              -- the caret: on its line, after what's before it there
    local before = e.text:sub(1, e.cur - 1)
    local row = M.lines(before) - 1
    renderer.draw_rect(x + font:get_width(before:match("[^\n]*$")), y + row * lh, require("core.style").caret_width, lh, caret_color)
  end
  return ly - y
end

return M

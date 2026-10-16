-- tip.lua - canvas.tip: tooltips and flashed notes (Replay), the node
-- graph's, shared.
--
--   canvas.tip.box(rows, x, y, bounds)   -- a dark box of lines by (x, y), kept inside bounds
--     rows: { "text" } or { { text, color [, font] }... }; bounds: { x, y, w, h }
--   canvas.tip.text(text, x, y, bounds [, color])   -- one line
--   local n = canvas.tip.note()          -- a short note that fades: n:say("saved", is_error)
--   n:draw(x, y [, bounds]) -> drawn?    -- (for 4 s; core.redraw keeps it going)
local core = require "core"
local style = require "core.style"
local T = require "plugins.canvas.theme"
local D = require "plugins.canvas.draw"
local C, rgb = T.C, T.rgb

local M = {}
M.DELAY = 0.4                                      -- (s the mouse rests before a widget's tip shows)
M.SHOWN = 4                                        -- (s a note stays)

function M.box(rows, x, y, bounds)
  local p = 4 * SCALE
  local list = {}
  for _, r in ipairs(rows) do
    if type(r) == "string" then list[#list + 1] = { r, C.text, style.font }
    else list[#list + 1] = { r[1], r[2] or C.text, r[3] or style.font } end
  end
  local tw, th = 0, p
  for _, r in ipairs(list) do tw = math.max(tw, r[3]:get_width(r[1])); th = th + r[3]:get_height() + 2 * SCALE end
  tw = tw + 2 * p
  local tx, ty = x + 12 * SCALE, y + 14 * SCALE
  if bounds then
    if tx + tw > bounds.x + bounds.w then tx = math.max(bounds.x, bounds.x + bounds.w - tw) end   -- (kept inside the view)
    if ty + th > bounds.y + bounds.h then ty = math.max(bounds.y, y - th - 6 * SCALE) end
  end
  D.rrect(tx, ty, tw, th, 3 * SCALE, rgb"#181818")
  local yy = ty + p / 2
  for _, r in ipairs(list) do renderer.draw_text(r[3], r[1], tx + p, yy, r[2]); yy = yy + r[3]:get_height() + 2 * SCALE end
  return tx, ty, tw, th
end
function M.text(text, x, y, bounds, color) return M.box({ { text, color } }, x, y, bounds) end

local Note = {}
Note.__index = Note
function M.note() return setmetatable({}, Note) end
function Note:say(text, err) self.text, self.t, self.err = text, system.get_time(), err or nil; core.redraw = true end
function Note:shown() return self.text and system.get_time() - self.t < M.SHOWN end
function Note:draw(x, y, bounds)                   -- (bottom right of bounds when x is nil)
  if not self:shown() then self.text = nil return false end
  local f = style.font
  local w, h = f:get_width(self.text) + 12 * SCALE, f:get_height() + 6 * SCALE
  if not x and bounds then x, y = bounds.x + bounds.w - w - 8 * SCALE, bounds.y + bounds.h - h - 8 * SCALE end
  D.rrect(x, y, w, h, 3 * SCALE, T.alpha(rgb"#16161a", 220))
  renderer.draw_text(f, self.text, x + 6 * SCALE, y + 3 * SCALE, self.err and C.err or (style.syntax and style.syntax.keyword2 or C.text))
  core.redraw = true                               -- (until it's gone)
  return true
end

return M

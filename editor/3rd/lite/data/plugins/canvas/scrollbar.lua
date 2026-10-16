-- scrollbar.lua - canvas.scrollbar: a scroll bar of its own (Replay), for
-- what isn't one of lite's views (a panel, the hex editor's rows): a track,
-- a thumb as big as what's shown, dragged or clicked.
--
--   local sb = canvas.scrollbar.new()
--   sb:draw(x, y, w, h, total, shown, pos)      -- total / shown / pos: in any unit (rows, px)
--   sb:pressed(x, y) -> true: on it (the thumb follows the mouse from there)
--   sb:moved(x, y) -> the new pos while dragged (nil: not dragging)
--   sb:released()
-- The view sets its own position from what pressed / moved return (it
-- clamps): local p = sb:moved(x, y); if p then self:scroll_to(p) end
local style = require "core.style"

local SB = {}
SB.__index = SB

function SB.new() return setmetatable({}, SB) end

local function thumb(self)
  local x, y, w, h, total, shown, pos = self.x, self.y, self.w, self.h, self.total, self.shown, self.pos
  local th = math.max(math.floor(16 * SCALE), h * math.min(1, shown / math.max(total, 1e-9)))
  local ty = y + (h - th) * (total > shown and math.max(0, math.min(1, pos / (total - shown))) or 0)
  return ty, th
end

function SB:draw(x, y, w, h, total, shown, pos, opts)
  self.x, self.y, self.w, self.h, self.total, self.shown, self.pos = x, y, w, h, total, shown, pos
  if not (opts and opts.always) and total <= shown then self.hidden = true return end
  self.hidden = false
  if not (opts and opts.no_track) then renderer.draw_rect(x, y, w, h, style.background2) end
  local ty, th = thumb(self)
  local inset = math.floor(w / 5)
  renderer.draw_rect(x + inset, ty, w - inset * 2, th, (self.drag or self.hot) and (style.scrollbar2 or style.text) or (style.scrollbar or style.dim))
end

function SB:inside(x, y) return self.x and not self.hidden and x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h end
function SB:at(y)                                  -- the pos whose thumb is centred at y
  local _, th = thumb(self)
  local span = self.h - th
  if span <= 0 then return 0 end
  return (y - self.y - th / 2) / span * (self.total - self.shown)
end
function SB:pressed(x, y)
  if not self:inside(x, y) then return false end
  local ty, th = thumb(self)
  self.drag = (y >= ty and y < ty + th) and (y - ty - th / 2) or 0   -- (on the thumb: it keeps where it was held)
  return true, self:at(y - self.drag)
end
function SB:moved(x, y)
  self.hot = self:inside(x, y)
  if not self.drag then return nil end
  return self:at(y - self.drag)
end
function SB:released() local was = self.drag ~= nil; self.drag = nil; return was end

return SB

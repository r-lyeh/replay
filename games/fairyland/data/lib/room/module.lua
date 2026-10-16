-- room: the map as the game reads it (assets/room.tmap: two hex digits a
-- cell, ".." empty), and what's solid there
local M = { TILE = 16, OX = -240, OY = -136 }
function M.tile(m, name, cx, cy)                   -- (0-based cell) -> its tile index | nil
  for _, l in ipairs(m and m.layers or {}) do
    if l.name == name then
      local row = l.rows and l.rows[cy + 1]
      local s = row and row:sub(cx * 2 + 1, cx * 2 + 2)
      if not s or s == "" or s == ".." then return nil end
      return tonumber(s, 16)
    end
  end
end
function M.solid(m, layers, x, y)                  -- a point of the world: in a solid cell?
  local cx, cy = math.floor((x - M.OX) / M.TILE), math.floor((y - M.OY) / M.TILE)
  if cx < 0 or cy < 0 or cx >= (m.w or 30) or cy >= (m.h or 17) then return true end
  for _, l in ipairs(layers) do if M.tile(m, l, cx, cy) then return true end end
  return false
end
function M.any(set, keys) for _, k in ipairs(keys) do if set[k] then return true end end return false end
M.LEFT = { "left", "a", "pad dpleft", "pad left" }
M.RIGHT = { "right", "d", "pad dpright", "pad right" }
M.UP = { "up", "w", "pad dpup", "pad up" }
M.DOWN = { "down", "s", "pad dpdown", "pad down" }
M.TALK = { "space", "return", "e", "pad a" }
return M

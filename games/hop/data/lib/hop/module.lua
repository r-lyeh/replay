-- hop: the level as the game reads it. The map is the tilemap editor's file
-- (assets/level1.tmap): two hex digits a cell, ".." empty. Read again every
-- second or so, so an edit saved in the editor is solid at once.
local M = {}
M.TILE = 16
M.OX, M.OY = -240, -136                            -- (the map's top left, in the world: the level nodes' xform)

local cache = { name = nil, map = nil, age = 0 }
function M.map(w, name)
  cache.age = cache.age - 1
  if cache.name ~= name or cache.age <= 0 or not cache.map then
    local m = w:asset(name)
    if m then cache.map = m end
    cache.name, cache.age = name, 60
  end
  return cache.map
end

local function layer(m, name)
  for _, l in ipairs(m.layers or {}) do if l.name == name then return l end end
end
function M.tile(m, name, cx, cy)                   -- (0-based cell) -> its tile index | nil
  local l = m and layer(m, name)
  local row = l and l.rows and l.rows[cy + 1]
  if not row then return nil end
  local s = row:sub(cx * 2 + 1, cx * 2 + 2)
  if s == "" or s == ".." then return nil end
  return tonumber(s, 16)
end
function M.cells(m, name)                          -- every cell of a layer: { x, y, tile }...
  local out, l = {}, m and layer(m, name)
  for cy, row in ipairs(l and l.rows or {}) do
    for cx = 0, #row / 2 - 1 do
      local t = M.tile(m, name, cx, cy - 1)
      if t then out[#out + 1] = { x = cx, y = cy - 1, tile = t } end
    end
  end
  return out
end
function M.cell_of(x, y) return math.floor((x - M.OX) / M.TILE), math.floor((y - M.OY) / M.TILE) end
function M.centre(cx, cy) return M.OX + cx * M.TILE + M.TILE / 2, M.OY + cy * M.TILE + M.TILE / 2 end

local function any(m, rules, x0, y0, x1, y1, test)  -- a box (world px) over cells that pass test
  local a, b = M.cell_of(x0, y0)
  local c, d = M.cell_of(x1 - 0.001, y1 - 0.001)
  for cy = b, d do for cx = a, c do
    if test(m, rules, cx, cy) then return true end
  end end
  return false
end
local function solid(m, rules, cx, cy)
  if cx < 0 or cx >= (m.w or 0) then return true end          -- (the sides are walls; above and below are open)
  local t = M.tile(m, "ground", cx, cy)
  if not t then return false end
  for _, h in ipairs(rules.hurts or {}) do if t == h then return false end end
  return true
end
local function hurts(m, rules, cx, cy)
  local t = M.tile(m, "ground", cx, cy)
  for _, h in ipairs(rules.hurts or {}) do if t == h then return true end end
  return false
end
function M.solid(m, rules, x0, y0, x1, y1) return any(m, rules, x0, y0, x1, y1, solid) end
function M.hurts(m, rules, x0, y0, x1, y1) return any(m, rules, x0, y0, x1, y1, hurts) end

function M.tile_src(t) return { (t % 16) * M.TILE, math.floor(t / 16) * M.TILE, M.TILE, M.TILE } end
return M

-- map.lua - a tilemap (no lite here: a game can read the same file): its
-- size, its tileset, its layers of cells, and the edits the editor makes.
--
-- A .tmap file is Lua data:
--   return {
--     tileset = "tiles.png",   -- beside the .tmap; "plugin:tiles.png": the plugin's own (CC0)
--     tile = 16,               -- px a tile, in the tileset
--     w = 32, h = 20,          -- cells
--     layers = {               -- drawn first to last
--       { name = "ground", visible = true, rows = { "0000000101..", ... } },
--     },
--   }
-- A row: two hex digits a cell, the tile's index in the tileset (00 = the top
-- left one, 16 a row), ".." none. Readable, and a diff shows the cells changed.
local M = {}

M.DEFAULTS = { tileset = "plugin:tiles.png", tile = 16, w = 32, h = 20 }
M.MAX = 512                                        -- (cells, each way)

local function new_layer(name, w, h)
  local cells = {}
  for i = 1, w * h do cells[i] = false end
  return { name = name, visible = true, cells = cells }
end
M.new_layer = new_layer

function M.new(w, h)
  w, h = w or M.DEFAULTS.w, h or M.DEFAULTS.h
  return { tileset = M.DEFAULTS.tileset, tile = M.DEFAULTS.tile, w = w, h = h,
           layers = { new_layer("ground", w, h), new_layer("decor", w, h), new_layer("top", w, h) } }
end

-- the file's data -> a map (what's wrong is fixed: sizes clamped, rows padded)
function M.from_data(t)
  if type(t) ~= "table" then return M.new() end
  local function int(v, d, lo, hi) v = math.floor(tonumber(v) or d) return math.max(lo, math.min(hi, v)) end
  local m = { tileset = type(t.tileset) == "string" and t.tileset or M.DEFAULTS.tileset,
              tile = int(t.tile, 16, 1, 256), w = int(t.w, M.DEFAULTS.w, 1, M.MAX), h = int(t.h, M.DEFAULTS.h, 1, M.MAX), layers = {} }
  for _, l in ipairs(type(t.layers) == "table" and t.layers or {}) do
    local nl = new_layer(type(l.name) == "string" and l.name or ("layer " .. (#m.layers + 1)), m.w, m.h)
    nl.visible = l.visible ~= false
    for y = 1, m.h do
      local row = type(l.rows) == "table" and type(l.rows[y]) == "string" and l.rows[y] or ""
      for x = 1, m.w do
        local hx = row:sub(x * 2 - 1, x * 2)
        nl.cells[(y - 1) * m.w + x] = hx:match("^%x%x$") and tonumber(hx, 16) or false
      end
    end
    m.layers[#m.layers + 1] = nl
  end
  if #m.layers == 0 then m.layers[1] = new_layer("ground", m.w, m.h) end
  return m
end

function M.to_data(m)
  local t = { tileset = m.tileset, tile = m.tile, w = m.w, h = m.h, layers = {} }
  for _, l in ipairs(m.layers) do
    local rows = {}
    for y = 1, m.h do
      local parts = {}
      for x = 1, m.w do
        local c = l.cells[(y - 1) * m.w + x]
        parts[x] = c and string.format("%02x", c) or ".."
      end
      rows[y] = table.concat(parts)
    end
    t.layers[#t.layers + 1] = { name = l.name, visible = l.visible, rows = rows }
  end
  return t
end

function M.get(m, layer, x, y)                     -- (0-based cells) -> tile index | false | nil (outside)
  if x < 0 or y < 0 or x >= m.w or y >= m.h then return nil end
  return m.layers[layer].cells[y * m.w + x + 1]
end
function M.set(m, layer, x, y, v)                  -- -> true when it changed
  if x < 0 or y < 0 or x >= m.w or y >= m.h then return false end
  local cells = m.layers[layer].cells
  local i = y * m.w + x + 1
  if cells[i] == v then return false end
  cells[i] = v
  return true
end

-- a stamp: tiles sel[1]..sel[2] of a sheet `cols` wide, as a w x h block
function M.stamp(sel, cols)
  local a, b = sel[1], sel[2] or sel[1]
  local x0, y0 = math.min(a % cols, b % cols), math.min(math.floor(a / cols), math.floor(b / cols))
  local x1, y1 = math.max(a % cols, b % cols), math.max(math.floor(a / cols), math.floor(b / cols))
  local s = { w = x1 - x0 + 1, h = y1 - y0 + 1 }
  for j = 0, s.h - 1 do for i = 0, s.w - 1 do s[j * s.w + i + 1] = (y0 + j) * cols + x0 + i end end
  return s
end
function M.paint(m, layer, x, y, stamp)            -- the stamp at x, y (its top left) -> changed
  local ch = false
  for j = 0, stamp.h - 1 do for i = 0, stamp.w - 1 do
    if M.set(m, layer, x + i, y + j, stamp[j * stamp.w + i + 1]) then ch = true end
  end end
  return ch
end
function M.rect(m, layer, x0, y0, x1, y1, stamp)   -- the stamp repeated over a rectangle (false: erase it)
  local ch = false
  for y = math.min(y0, y1), math.max(y0, y1) do
    for x = math.min(x0, x1), math.max(x0, x1) do
      local v = stamp and stamp[((y - math.min(y0, y1)) % stamp.h) * stamp.w + ((x - math.min(x0, x1)) % stamp.w) + 1] or false
      if M.set(m, layer, x, y, v) then ch = true end
    end
  end
  return ch
end
function M.fill(m, layer, x, y, v)                 -- the cells like (x, y), touching it, become v -> how many
  local from = M.get(m, layer, x, y)
  if from == nil or from == v then return 0 end
  local stack, n = { { x, y } }, 0
  while #stack > 0 do
    local p = table.remove(stack)
    if M.get(m, layer, p[1], p[2]) == from then
      M.set(m, layer, p[1], p[2], v)
      n = n + 1
      stack[#stack + 1] = { p[1] + 1, p[2] }; stack[#stack + 1] = { p[1] - 1, p[2] }
      stack[#stack + 1] = { p[1], p[2] + 1 }; stack[#stack + 1] = { p[1], p[2] - 1 }
    end
  end
  return n
end

function M.resize(m, w, h)                         -- keeps what fits (top left anchored)
  w, h = math.max(1, math.min(M.MAX, w)), math.max(1, math.min(M.MAX, h))
  for _, l in ipairs(m.layers) do
    local cells = {}
    for y = 0, h - 1 do for x = 0, w - 1 do
      cells[y * w + x + 1] = (x < m.w and y < m.h) and l.cells[y * m.w + x + 1] or false
    end end
    l.cells = cells
  end
  m.w, m.h = w, h
end

function M.copy(m)
  local c = { tileset = m.tileset, tile = m.tile, w = m.w, h = m.h, layers = {} }
  for i, l in ipairs(m.layers) do
    local cells = {}
    for k = 1, #l.cells do cells[k] = l.cells[k] end
    c.layers[i] = { name = l.name, visible = l.visible, cells = cells }
  end
  return c
end

function M.count(m, layer)                         -- cells with a tile
  local n = 0
  for _, c in ipairs(m.layers[layer].cells) do if c then n = n + 1 end end
  return n
end

return M

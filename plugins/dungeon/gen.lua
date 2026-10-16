-- gen.lua - the dungeon generator: a .dungeon file's settings -> a tile map
-- (plugins/tilemap's .tmap data). No Lite in it: the editor previews with it,
-- the chain writes maps with it, and a game could make dungeons with it too.
--
-- A .dungeon (Lua data; every field optional, M.DEFAULTS):
--   seed       the same seed, the same dungeon
--   w, h       its size in cells
--   rooms      how many rooms it tries to place; room_min, room_max: their sides
--   loops      0..1: extra corridors between rooms (0: a tree, no loops)
--   theme      "stone", "cave", "crypt", "wood" (the floor and wall tiles: M.THEMES)
--   torches    0..1: how many walls next to a room carry a torch
--   clutter    0..1: crates and barrels along the rooms' walls
--   doors      true: a door where a corridor enters a room
--   auto_walls true: walls as auto-tiles where the theme has them (stone): outlined
--              where they meet the floor (plugins/tilemap/map.lua M.autotile's rule)
--   tileset    the map's tileset ("plugin:tiles.png": plugins/tilemap's)
--   output     the map it writes, beside it ("<its name>.tmap" when not given)
local M = {}
-- auto-tiles: plugins/tilemap/map.lua's "blob" rule (47 a kind): the mask of
-- the 8 neighbours of the same kind (N 1, NE 2, E 4, SE 8, S 16, SW 32, W 64,
-- NW 128; a corner only with both its sides) -> its place among the 47
local BLOB_AT = {}
do
  local seen, k = {}, 0
  for m = 0, 255 do
    local function has(b) return math.floor(m / b) % 2 == 1 end
    local r = (has(1) and 1 or 0) + (has(4) and 4 or 0) + (has(16) and 16 or 0) + (has(64) and 64 or 0)
    if has(2) and has(1) and has(4) then r = r + 2 end
    if has(8) and has(4) and has(16) then r = r + 8 end
    if has(32) and has(16) and has(64) then r = r + 32 end
    if has(128) and has(64) and has(1) then r = r + 128 end
    seen[r] = true
  end
  for m = 0, 255 do if seen[m] then BLOB_AT[m] = k; k = k + 1 end end
end
local function blob(first, same)                   -- same(dx, dy) -> that neighbour is of the kind
  local n, e, s, w = same(0, -1), same(1, 0), same(0, 1), same(-1, 0)
  local m = (n and 1 or 0) + (e and 4 or 0) + (s and 16 or 0) + (w and 64 or 0)
          + ((n and e and same(1, -1)) and 2 or 0) + ((e and s and same(1, 1)) and 8 or 0)
          + ((s and w and same(-1, 1)) and 32 or 0) + ((w and n and same(-1, -1)) and 128 or 0)
  return first + BLOB_AT[m]
end

M.DEFAULTS = { seed = 1, w = 48, h = 32, rooms = 9, room_min = 4, room_max = 9, loops = 0.25, theme = "stone",
               torches = 0.12, clutter = 0.08, doors = true, auto_walls = true, tileset = "plugin:tiles.png" }
M.THEMES = {                                       -- (tiles of plugins/tilemap/tiles.png: tiles.lua names them)
  stone = { floor = 22, corridor = 3, wall = 21, wall_auto = 111 },  -- floor tiles, cobblestone, stone bricks (auto-tiles: 111..157)
  cave = { floor = 1, corridor = 5, wall = 2 },       -- dirt, gravel, stone
  crypt = { floor = 3, corridor = 13, wall = 61 },    -- cobblestone, mossy stone, obsidian
  wood = { floor = 16, corridor = 16, wall = 17 },    -- planks, planks, log
}
M.THEME_NAMES = { "stone", "cave", "crypt", "wood" }
M.TILE = { torch = 50, crate = 39, barrel = 40, door = 41 }

function M.check(t)
  t = type(t) == "table" and t or {}
  local s = {}
  for k, v in pairs(M.DEFAULTS) do s[k] = v end
  for k, v in pairs(t) do if M.DEFAULTS[k] ~= nil and type(v) == type(M.DEFAULTS[k]) then s[k] = v end end
  s.output = type(t.output) == "string" and t.output or nil
  s.w = math.max(12, math.min(256, math.floor(s.w)))
  s.h = math.max(12, math.min(256, math.floor(s.h)))
  s.room_min = math.max(3, math.min(30, math.floor(s.room_min)))
  s.room_max = math.max(s.room_min, math.min(40, math.floor(s.room_max)))
  s.rooms = math.max(1, math.min(80, math.floor(s.rooms)))
  if not M.THEMES[s.theme] then s.theme = "stone" end
  return s
end

-- s: the settings (checked) -> map data (as plugins/tilemap writes it: { tileset, tile, w, h,
-- layers = { { name, visible, rows } } }), and what it made: { rooms = n, corridors = n, list = the rooms }
function M.generate(s)
  s = M.check(s)
  local seed = math.floor(s.seed) % 2147483647
  if seed <= 0 then seed = seed + 2147483646 end
  local function rnd() seed = (seed * 16807) % 2147483647; return seed / 2147483647 end
  local function ri(a, b) return a + math.floor(rnd() * (b - a + 1)) end
  local W, H = s.w, s.h
  local th = M.THEMES[s.theme]
  local ground, decor = {}, {}                     -- (cell index y * W + x + 1 -> tile)
  local kind = {}                                  -- "room" | "corr" | "wall"
  local function at(x, y) return y * W + x + 1 end
  local function inside(x, y) return x >= 1 and y >= 1 and x < W - 1 and y < H - 1 end
  -- rooms: placed at random, apart from each other (a cell of wall between)
  local rooms = {}
  for _ = 1, s.rooms * 12 do
    if #rooms >= s.rooms then break end
    local rw, rh = ri(s.room_min, s.room_max), ri(s.room_min, s.room_max)
    if rw < W - 2 and rh < H - 2 then
      local x, y = ri(1, W - rw - 1), ri(1, H - rh - 1)
      local ok = true
      for _, r in ipairs(rooms) do
        if x <= r.x + r.w + 1 and r.x <= x + rw + 1 and y <= r.y + r.h + 1 and r.y <= y + rh + 1 then ok = false break end
      end
      if ok then rooms[#rooms + 1] = { x = x, y = y, w = rw, h = rh, cx = x + math.floor(rw / 2), cy = y + math.floor(rh / 2) } end
    end
  end
  for _, r in ipairs(rooms) do
    for y = r.y, r.y + r.h - 1 do for x = r.x, r.x + r.w - 1 do kind[at(x, y)] = "room" end end
  end
  -- corridors: each room to its nearest already joined (a tree), then a few more (loops)
  local function dig(x0, y0, x1, y1)
    local horizontal_first = rnd() < 0.5
    local x, y = x0, y0
    local function cell() if inside(x, y) and kind[at(x, y)] ~= "room" then kind[at(x, y)] = "corr" end end
    local function walk_x() while x ~= x1 do x = x + (x1 > x and 1 or -1); cell() end end
    local function walk_y() while y ~= y1 do y = y + (y1 > y and 1 or -1); cell() end end
    if horizontal_first then walk_x(); walk_y() else walk_y(); walk_x() end
  end
  local corridors = 0
  local joined = { rooms[1] }
  for i = 2, #rooms do
    local r, best, bd = rooms[i], nil, math.huge
    for _, q in ipairs(joined) do
      local dd = (q.cx - r.cx) ^ 2 + (q.cy - r.cy) ^ 2
      if dd < bd then best, bd = q, dd end
    end
    dig(r.cx, r.cy, best.cx, best.cy)
    corridors = corridors + 1
    joined[#joined + 1] = r
  end
  local extra = math.floor(#rooms * s.loops + 0.5)
  for _ = 1, extra do
    if #rooms < 3 then break end
    local a, b = rooms[ri(1, #rooms)], rooms[ri(1, #rooms)]
    if a ~= b then dig(a.cx, a.cy, b.cx, b.cy); corridors = corridors + 1 end
  end
  -- the floor; walls round it (the 8 cells about every floor cell)
  for y = 0, H - 1 do for x = 0, W - 1 do
    local k = kind[at(x, y)]
    if k == "room" then ground[at(x, y)] = th.floor elseif k == "corr" then ground[at(x, y)] = th.corridor end
  end end
  for y = 0, H - 1 do for x = 0, W - 1 do
    if not kind[at(x, y)] then
      local near = false
      for dy = -1, 1 do for dx = -1, 1 do
        local nx, ny = x + dx, y + dy
        if nx >= 0 and ny >= 0 and nx < W and ny < H then
          local k = kind[at(nx, ny)]
          if k == "room" or k == "corr" then near = true end
        end
      end end
      if near then kind[at(x, y)] = "wall"; ground[at(x, y)] = th.wall end
    end
  end end
  local function is(x, y, k) return x >= 0 and y >= 0 and x < W and y < H and kind[at(x, y)] == k end
  -- doors: a corridor cell next to a room, between two walls
  if s.doors then
    for y = 1, H - 2 do for x = 1, W - 2 do
      if is(x, y, "corr") then
        local by_room = is(x - 1, y, "room") or is(x + 1, y, "room") or is(x, y - 1, "room") or is(x, y + 1, "room")
        local gate = (is(x - 1, y, "wall") and is(x + 1, y, "wall")) or (is(x, y - 1, "wall") and is(x, y + 1, "wall"))
        if by_room and gate then decor[at(x, y)] = M.TILE.door end
      end
    end end
  end
  -- torches on walls that face a room; crates and barrels along the rooms' edges
  for y = 0, H - 1 do for x = 0, W - 1 do
    if is(x, y, "wall") and (is(x, y + 1, "room") or is(x + 1, y, "room") or is(x - 1, y, "room")) and rnd() < s.torches then
      decor[at(x, y)] = M.TILE.torch
    elseif is(x, y, "room") and not decor[at(x, y)] then
      local edge = is(x - 1, y, "wall") or is(x + 1, y, "wall") or is(x, y - 1, "wall") or is(x, y + 1, "wall")
      if edge and rnd() < s.clutter then decor[at(x, y)] = rnd() < 0.5 and M.TILE.crate or M.TILE.barrel end
    end
  end end
  if s.auto_walls and th.wall_auto then             -- (auto-tiles: the blob rule, a wall beside it; off the map: one)
    local function wall(x, y) return x < 0 or y < 0 or x >= W or y >= H or kind[at(x, y)] == "wall" end
    for y = 0, H - 1 do for x = 0, W - 1 do
      if kind[at(x, y)] == "wall" then
        ground[at(x, y)] = blob(th.wall_auto, function(dx, dy) return wall(x + dx, y + dy) end)
      end
    end end
  end
  local function rows(cells)
    local out = {}
    for y = 0, H - 1 do
      local p = {}
      for x = 0, W - 1 do local c = cells[at(x, y)]; p[#p + 1] = c and string.format("%02x", c) or ".." end
      out[#out + 1] = table.concat(p)
    end
    return out
  end
  return { tileset = s.tileset, tile = 16, w = W, h = H,
           layers = { { name = "ground", visible = true, rows = rows(ground) },
                      { name = "decor", visible = true, rows = rows(decor) },
                      { name = "top", visible = true, rows = rows({}) } } },
         { rooms = #rooms, corridors = corridors, list = rooms }   -- (list: each room's x, y, w, h, cx, cy: cells)
end

-- the map's file name for a .dungeon at `path`
function M.output_of(s, path)
  local dir = path:match("^(.*)[/\\]") or "."
  local name = (type(s.output) == "string" and s.output ~= "") and s.output or ((path:match("([^/\\]+)%.[^.]*$") or "dungeon") .. ".tmap")
  return dir .. "/" .. name, name
end

-- Lua source of a value (plain data: what's written to files)
local function ser(v, ind)
  local t = type(v)
  if t == "string" then return string.format("%q", v)
  elseif t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return (string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", ""))
  elseif t == "boolean" then return tostring(v)
  elseif t ~= "table" then return "nil" end
  local parts, n = {}, #v
  for i = 1, n do parts[#parts + 1] = ser(v[i], ind .. "  ") end
  local keys = {}
  for k in pairs(v) do if not (type(k) == "number" and k >= 1 and k <= n) then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. " = " .. ser(v[k], ind .. "  ") end
  local one = "{ " .. table.concat(parts, ", ") .. " }"
  if #one < 90 and not one:find("\n") then return one end
  return "{\n" .. ind .. "  " .. table.concat(parts, ",\n" .. ind .. "  ") .. ",\n" .. ind .. "}"
end
M.ser = ser
function M.settings_lua(s)
  local t = {}
  for k in pairs(M.DEFAULTS) do t[k] = s[k] end
  t.output = s.output
  return "-- a dungeon (plugins/dungeon): its settings (plugins/dungeon/gen.lua says what each is); it makes " ..
         (s.output or "a .tmap beside it") .. "\nreturn " .. ser(t, "") .. "\n"
end
-- the map's file text, marked as made from `source` (plugins/chain: Regenerate there)
function M.map_lua(data, source)
  data.made_by = source
  return "-- a tile map (plugins/tilemap), made by " .. source .. " (plugins/dungeon): regenerating it there replaces it\nreturn " .. ser(data, "") .. "\n"
end
return M

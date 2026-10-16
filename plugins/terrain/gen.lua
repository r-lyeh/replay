-- gen.lua - the terrain generator: a .terrain file's settings -> a tile map
-- (plugins/tilemap's .tmap data): land and water from noise, beaches, grass
-- and dry land, hills and snow, trees, flowers. No Lite in it: the editor
-- previews with it, the chain writes maps with it, a game could use it too.
--
-- A .terrain (Lua data; every field optional, M.DEFAULTS):
--   seed       the same seed, the same land
--   w, h       its size in cells
--   scale      the size of its features, in cells (bigger: wider hills, seas)
--   octaves    detail: noise layered on noise (1 smooth .. 6 rugged)
--   island     true: water all round the edges
--   water      0..1: the height below which it's water (more: more sea)
--   beach      0..0.2: how much sand above the water
--   hills      0..1: the height above which it's stone; snow: above which it's snow
--   dry        0..1: how much of the low land is dry (dirt, cacti) instead of grass
--   trees      0..1: bushes on the grass; flowers 0..1: flowers and tall grass
--   shores     true: the water as auto-tiles (sand edges where it meets land)
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

M.DEFAULTS = { seed = 1, w = 64, h = 48, scale = 16, octaves = 4, island = true, water = 0.38, beach = 0.04,
               hills = 0.72, snow = 0.86, dry = 0.2, trees = 0.25, flowers = 0.05, shores = true, tileset = "plugin:tiles.png" }
M.TILE = { water = 8, sand = 4, grass = 0, dirt = 1, stone = 2, snow = 6, bush = 52, rock = 51, cactus = 48,
           red_flower = 44, yellow_flower = 45, tall_grass = 47, shore = 64 }   -- (plugins/tilemap/tiles.png; shore: 64..110, auto-tiles)

function M.check(t)
  t = type(t) == "table" and t or {}
  local s = {}
  for k, v in pairs(M.DEFAULTS) do s[k] = v end
  for k, v in pairs(t) do if M.DEFAULTS[k] ~= nil and type(v) == type(M.DEFAULTS[k]) then s[k] = v end end
  if type(t.output) == "string" and t.output ~= "" then s.output = t.output end
  local function clamp(k, lo, hi) s[k] = math.max(lo, math.min(hi, s[k])) end
  s.w, s.h = math.floor(s.w), math.floor(s.h)
  clamp("w", 8, 256); clamp("h", 8, 256); clamp("scale", 2, 128); clamp("octaves", 1, 6)
  s.octaves = math.floor(s.octaves)
  for _, k in ipairs({ "water", "hills", "snow", "dry", "trees", "flowers" }) do clamp(k, 0, 1) end
  clamp("beach", 0, 0.2)
  s.seed = math.floor(s.seed)
  return s
end

-- value noise: a lattice of random heights, smoothly blended; octaves of it
local function noise_fn(seed)
  local function lat(ix, iy)
    local h = (ix * 73856093 + iy * 19349663 + seed * 83492791) % 2147483647
    if h <= 0 then h = h + 2147483646 end
    for _ = 1, 3 do h = (h * 16807) % 2147483647 end
    return h / 2147483647
  end
  local function smooth(t) return t * t * (3 - 2 * t) end
  return function(x, y)
    local ix, iy = math.floor(x), math.floor(y)
    local fx, fy = smooth(x - ix), smooth(y - iy)
    local a, b = lat(ix, iy), lat(ix + 1, iy)
    local c, d = lat(ix, iy + 1), lat(ix + 1, iy + 1)
    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
  end
end
local function fbm(n, x, y, octaves)
  local v, amp, freq, total = 0, 1, 1, 0
  for o = 1, octaves do
    v = v + n(x * freq + o * 31.7, y * freq + o * 17.3) * amp
    total = total + amp
    amp, freq = amp * 0.5, freq * 2
  end
  return v / total
end

-- s: the settings (checked) -> map data ({ tileset, tile, w, h, layers }), and
-- what it made: { land = %, water = %, trees = n }
function M.generate(s)
  s = M.check(s)
  local W, H, T = s.w, s.h, M.TILE
  local height, moist = noise_fn(s.seed), noise_fn(s.seed + 7919)
  local seed = s.seed % 2147483647
  if seed <= 0 then seed = seed + 2147483646 end
  local function rnd() seed = (seed * 16807) % 2147483647; return seed / 2147483647 end
  local ground, decor, kind = {}, {}, {}
  local function at(x, y) return y * W + x + 1 end
  local wet, trees = 0, 0
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      local hgt = fbm(height, x / s.scale, y / s.scale, s.octaves)
      hgt = (hgt - 0.5) * 1.6 + 0.5                 -- (more contrast: value noise sits near the middle)
      if s.island then                              -- (lower towards the edges: water all round)
        local dx, dy = (x + 0.5) / W * 2 - 1, (y + 0.5) / H * 2 - 1
        local d = math.sqrt(dx * dx + dy * dy) / math.sqrt(2)
        hgt = hgt - d * d * 0.8 + 0.16
        if x < 2 or y < 2 or x >= W - 2 or y >= H - 2 then hgt = math.min(hgt, s.water - 0.01) end   -- (the edge: always water)
      end
      local k
      if hgt < s.water then k = "water"
      elseif hgt < s.water + s.beach then k = "sand"
      elseif hgt >= s.snow then k = "snow"
      elseif hgt >= s.hills then k = "stone"
      else k = (fbm(moist, x / s.scale * 0.7 + 100, y / s.scale * 0.7 + 100, 3) - 0.5) * 1.8 + 0.5 < s.dry and "dirt" or "grass" end
      kind[at(x, y)] = k
      ground[at(x, y)] = T[k]
      if k == "water" then wet = wet + 1 end
      local r = rnd()
      if k == "grass" then
        if r < s.trees * 0.5 then decor[at(x, y)] = T.bush; trees = trees + 1
        elseif r < s.trees * 0.5 + s.flowers then
          local f = rnd()
          decor[at(x, y)] = f < 0.35 and T.red_flower or f < 0.7 and T.yellow_flower or T.tall_grass
        end
      elseif k == "dirt" and r < s.trees * 0.08 then decor[at(x, y)] = T.cactus
      elseif k == "stone" and r < 0.06 then decor[at(x, y)] = T.rock end
    end
  end
  if s.shores then                                  -- (auto-tiles: the blob rule, water beside it; off the map: water)
    local function water(x, y) return x < 0 or y < 0 or x >= W or y >= H or kind[at(x, y)] == "water" end
    for y = 0, H - 1 do for x = 0, W - 1 do
      if kind[at(x, y)] == "water" then
        ground[at(x, y)] = blob(T.shore, function(dx, dy) return water(x + dx, y + dy) end)
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
  local n = W * H
  return { tileset = s.tileset, tile = 16, w = W, h = H,
           layers = { { name = "ground", visible = true, rows = rows(ground) },
                      { name = "decor", visible = true, rows = rows(decor) },
                      { name = "top", visible = true, rows = rows({}) } } },
         { land = math.floor((n - wet) * 100 / n + 0.5), water = math.floor(wet * 100 / n + 0.5), trees = trees }
end

function M.output_of(s, path)
  local dir = path:match("^(.*)[/\\]") or "."
  local name = (type(s.output) == "string" and s.output ~= "") and s.output or ((path:match("([^/\\]+)%.[^.]*$") or "terrain") .. ".tmap")
  return dir .. "/" .. name, name
end
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
  return "-- a terrain (plugins/terrain): its settings (plugins/terrain/gen.lua says what each is); it makes " ..
         (s.output or "a .tmap beside it") .. "\nreturn " .. ser(t, "") .. "\n"
end
function M.map_lua(data, source)
  data.made_by = source
  return "-- a tile map (plugins/tilemap), made by " .. source .. " (plugins/terrain): regenerating it there replaces it\nreturn " .. ser(data, "") .. "\n"
end

return M

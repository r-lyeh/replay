-- autotile.lua - auto-tiles (plugins/tilemap/map.lua M.autotile: a kind's 16
-- tiles picked from the 4 neighbours) and the generators that use them: the
-- terrain's shores (plugins/terrain/gen.lua), the dungeon's wall edges.
--   cd runtime/tests && luajit autotile.lua   (or lua5.4)
local Map = dofile("../../plugins/tilemap/map.lua")
local Terrain = dofile("../../plugins/terrain/gen.lua")
local Dungeon = dofile("../../plugins/dungeon/gen.lua")
local n, fails = 0, 0
local function check(c, m) n = n + 1; if not c then fails = fails + 1; print("  FAIL: " .. m) end end

local function W(mask) return 64 + Map.BLOB_AT[mask] end      -- (water: the shore kind, 47 tiles from 64)
check(#Map.BLOB == 47 and Map.BLOB[1] == 0 and Map.BLOB[47] == 255, "the blob masks: 47, from 0 to 255")
-- a 5 x 4 map: a 3 x 2 pond of water (any of the shore tiles) in grass
local m = Map.new(5, 4)
for y = 1, 2 do for x = 1, 3 do Map.set(m, 1, x, y, 64) end end
check(Map.autotile(m, 1) == 6, "a pond: all six cells re-picked")
-- masks: N 1, NE 2, E 4, SE 8, S 16, SW 32, W 64, NW 128 (a corner with both its sides)
check(Map.get(m, 1, 1, 1) == W(4 + 8 + 16) and Map.get(m, 1, 2, 1) == W(4 + 8 + 16 + 32 + 64) and Map.get(m, 1, 3, 1) == W(16 + 32 + 64), "the top row: corners and an edge")
check(Map.get(m, 1, 1, 2) == W(1 + 2 + 4) and Map.get(m, 1, 3, 2) == W(1 + 64 + 128), "the bottom row")
do                                                   -- an inner corner: an L of water, its elbow
  local l = Map.new(4, 4)
  for _, c in ipairs({ { 1, 1 }, { 2, 1 }, { 1, 2 } }) do Map.set(l, 1, c[1], c[2], 64) end
  Map.autotile(l, 1)
  check(Map.get(l, 1, 1, 1) == W(4 + 16), "an L: its elbow has water east and south, land between them (an inner corner)")
end
check(Map.get(m, 1, 0, 0) == false, "the grass round it: untouched (none)")
check(Map.autotile(m, 1) == 0, "again: nothing to change")
-- (a lone wall: another kind, no edge shared with the water)
Map.set(m, 1, 0, 0, 111)
Map.autotile(m, 1)
check(Map.get(m, 1, 0, 0) == 111 + Map.BLOB_AT[1 + 64 + 128] and Map.get(m, 1, 1, 1) == W(4 + 8 + 16), "another kind beside it: each its own (off the map counts as the same)")
check(Map.auto_kind(nil, 70).key == "shore" and Map.auto_kind(nil, 120).key == "wall" and Map.auto_kind(nil, 160).key == "lava"
      and Map.auto_kind(nil, 210).key == "grass" and Map.auto_kind(nil, 8) == nil, "which kind a tile is")
local old = { shore = { first = 64, n = 16 } }       -- (a 16-tile kind: the 4 neighbours)
local o = Map.new(3, 3); Map.set(o, 1, 1, 1, 64); Map.set(o, 1, 2, 1, 64)
Map.autotile(o, 1, old)
check(Map.get(o, 1, 1, 1) == 64 + 2 and Map.get(o, 1, 2, 1) == 64 + 2 + 8, "a 16-tile kind still works (N 1, E 2, S 4, W 8)")

-- the terrain: the same seed, the same land; water all round an island; shores by the rule
local a, ia = Terrain.generate({ seed = 3 })
local b = Terrain.generate({ seed = 3 })
local c = Terrain.generate({ seed = 4 })
check(table.concat(a.layers[1].rows) == table.concat(b.layers[1].rows), "terrain: the same seed, the same land")
check(table.concat(a.layers[1].rows) ~= table.concat(c.layers[1].rows), "terrain: another seed, other land")
check(ia.land > 20 and ia.water > 20 and ia.trees > 0, "terrain: land, water and bushes: " .. ia.land .. "% land")
local t = Map.from_data(a)
local edge_ok = true
for x = 0, t.w - 1 do for _, y in ipairs({ 0, t.h - 1 }) do
  local v = Map.get(t, 1, x, y)
  if not (v and v >= 64 and v < 111) then edge_ok = false end
end end
check(edge_ok, "terrain: an island: its edges are water")
check(Map.autotile(t, 1) == 0, "terrain: its shores are what the editor's auto-tiles would pick")
local plain = Map.from_data(Terrain.generate({ seed = 3, shores = false }))
check(Map.get(plain, 1, 0, 0) == Terrain.TILE.water, "terrain without shores: plain water")
-- the dungeon: stone walls outlined; the crypt theme has no auto walls
local d = Map.from_data(Dungeon.generate({ seed = 5 }))
local walls = 0
for y = 0, d.h - 1 do for x = 0, d.w - 1 do local v = Map.get(d, 1, x, y); if v and v >= 111 and v < 158 then walls = walls + 1 end end end
check(walls > 50 and Map.autotile(d, 1) == 0, "dungeon: stone walls as auto-tiles, by the rule: " .. walls)
local cr = Map.from_data(Dungeon.generate({ seed = 5, theme = "crypt" }))
local any = false
for y = 0, cr.h - 1 do for x = 0, cr.w - 1 do local v = Map.get(cr, 1, x, y); if v and v >= 111 and v < 158 then any = true end end end
check(not any, "dungeon, crypt: its own walls (no auto-tiles for them)")

print(string.format("autotile: %s", fails == 0 and ("all ok (" .. n .. " checks)") or (fails .. " failed")))

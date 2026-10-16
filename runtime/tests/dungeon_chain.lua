-- dungeon_chain.lua - plugins that feed other plugins: the dungeon generator
-- (plugins/dungeon) makes a .tmap that the tilemap editor (plugins/tilemap)
-- opens, marked as made by it (plugins/chain): Regenerate there, Open source.
-- Auto-tiles as the tilemap editor paints; the terrain generator, the second maker.
--   replay games/pong.lua --stopped --lite "dofile(REPLAY_ROOT .. '/runtime/tests/dungeon_chain.lua')@3" --frames 100000 --shot x.bmp
-- Prints the failures and a count; NG_EXIT exits. SHOW=1: stays open (a screenshot).
local core = require "core"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local root = rawget(_G, "REPLAY_ROOT") or "."
  local G = dofile(root .. "/plugins/dungeon/gen.lua")
  -- the generator: the same seed, the same dungeon; another seed, another
  local a, ia = G.generate({ seed = 5 })
  local b = G.generate({ seed = 5 })
  local c = G.generate({ seed = 6 })
  check(table.concat(a.layers[1].rows) == table.concat(b.layers[1].rows), "the same seed: the same dungeon")
  check(table.concat(a.layers[1].rows) ~= table.concat(c.layers[1].rows), "another seed: another")
  check(ia.rooms >= 5 and ia.corridors >= ia.rooms - 1, "rooms, joined: " .. ia.rooms .. " rooms, " .. ia.corridors .. " corridors")
  check(table.concat(a.layers[2].rows):find(string.format("%02x", G.TILE.door), 1, true), "doors where corridors meet rooms")
  -- a copy of the sample, opened in its tab
  local path = root .. "/dungeon_chain_test.dungeon"
  local tmap = root .. "/dungeon_chain_test.tmap"
  do
    local f = io.open(root .. "/plugins/dungeon/samples/crypt.dungeon", "rb"); local s = f:read("*a"); f:close()
    s = s:gsub('output = "crypt.tmap"', 'output = "dungeon_chain_test.tmap"')
    f = io.open(path, "wb"); f:write(s); f:close()
    os.remove(tmap)
  end
  local v = require("plugins.openwith").open("dungeon", path)
  coroutine.yield(0.3)
  check(v and v.s and v.s.theme == "crypt" and v.info.rooms > 5, "the sample is open: a crypt, " .. tostring(v and v.info and v.info.rooms) .. " rooms")
  if not (v and v.s) then print(string.format("dungeon chain: %d checks ok, %d failed", ok_n, fail_n)); if os.getenv("NG_EXIT") then os.exit(0) end return end
  local before = table.concat(v.data.layers[1].rows)
  v:edit(function(t) t.seed = t.seed + 1 end)
  check(table.concat(v.data.layers[1].rows) ~= before, "a new seed: the preview changes at once")
  v:undo_step(true)
  check(table.concat(v.data.layers[1].rows) == before, "undo: back")
  -- the chain
  local chain = require "plugins.chain"
  local makers = chain.makers_of("tmap")
  check(#makers >= 1 and makers[1].ext == "dungeon", "a maker of .tmap: the dungeon generator")
  v:save()
  local f = io.open(tmap, "rb")
  check(f ~= nil, "saving made the map: " .. tmap)
  local text = f and f:read("*a") or ""
  if f then f:close() end
  check(text:find('made_by = "dungeon_chain_test.dungeon"', 1, true), "marked: made by the .dungeon")
  local tv = require("plugins.openwith").open("tilemap", tmap)
  coroutine.yield(0.3)
  check(tv and tv.map and tv.map.made_by == "dungeon_chain_test.dungeon" and tv.map.w == 64, "the tilemap editor opens it, knows where it came from")
  -- a hand edit in the tilemap editor, then Regenerate: the dungeon's map again
  local Map = tv.map and package.loaded["plugins.tilemap.map"]
  if Map then Map.set(tv.map, 1, 0, 0, 30); tv.dirty = true end
  tv:save()
  local f2 = io.open(tmap, "rb"); local edited = f2:read("*a"); f2:close()
  check(edited:find("made_by", 1, true), "a hand edit saved keeps the mark")
  tv:regenerate(chain.source(tv.map.made_by, tmap))
  check(tv.map and Map and Map.get(tv.map, 1, 0, 0) ~= 30 and not tv.dirty, "Regenerate: made again from its source (the hand edit gone)")
  local sv = chain.open_source(chain.source(tv.map.made_by, tmap))
  check(sv and sv.s and sv.filename:find("dungeon_chain_test.dungeon", 1, true), "Open source: the dungeon's tab")
  -- auto-tiles in the tilemap editor: water painted on the empty top layer gets its shores
  tv.layer, tv.tool, tv.sel = 3, "paint", { 64, 64 }
  tv:begin_edit()
  tv:apply("left", 2, 2, true); tv:apply("left", 3, 2, false)
  check(Map.get(tv.map, 3, 2, 2) == 64 + Map.BLOB_AT[4] and Map.get(tv.map, 3, 3, 2) == 64 + Map.BLOB_AT[64], "auto-tiles: two water cells, each with its shores: "
        .. tostring(Map.get(tv.map, 3, 2, 2)) .. " " .. tostring(Map.get(tv.map, 3, 3, 2)))
  tv.auto = false
  tv:apply("left", 4, 2, false)
  check(Map.get(tv.map, 3, 4, 2) == 64 and Map.get(tv.map, 3, 3, 2) == 64 + Map.BLOB_AT[64], "auto-tiles off: painted as picked, the others left")
  tv.auto = nil
  -- a second maker of .tmap: the terrain generator, the same way
  local tpath, tout = root .. "/dungeon_chain_test.terrain", root .. "/dungeon_chain_test_land.tmap"
  do
    local f = io.open(root .. "/plugins/terrain/samples/islands.terrain", "rb"); local src = f:read("*a"); f:close()
    src = src:gsub('output = "islands.tmap"', 'output = "dungeon_chain_test_land.tmap"')
    f = io.open(tpath, "wb"); f:write(src); f:close()
    os.remove(tout)
  end
  local makers2 = chain.makers_of("tmap")
  check(#makers2 == 2 and makers2[2].ext == "terrain", "two makers of .tmap: dungeon, terrain")
  local lv = require("plugins.openwith").open("terrain", tpath)
  coroutine.yield(0.3)
  check(lv and lv.info and lv.info.land > 10 and lv.data.w == 96, "the terrain sample is open: " .. tostring(lv and lv.info and lv.info.land) .. "% land")
  if lv and lv.s then
    lv:save()
    local f3 = io.open(tout, "rb")
    local txt = f3 and f3:read("*a") or ""
    if f3 then f3:close() end
    check(txt:find('made_by = "dungeon_chain_test.terrain"', 1, true), "the terrain made its map, marked")
    check(chain.rebuild(tpath) == root .. "/dungeon_chain_test_land.tmap", "chain.rebuild: the terrain's map again")
  end
  if os.getenv("SHOW") then
    sv:fit()
    return
  end
  os.remove(tpath); os.remove(tout)
  os.remove(path); os.remove(tmap)
  print(string.format("dungeon chain: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

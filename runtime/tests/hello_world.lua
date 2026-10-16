-- hello_world.lua
-- Run from anywhere:  luajit hello_world.lua   (or: lua hello_world.lua)

-- let `require` find modules next to this script
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. here .. "?/init.lua;" .. package.path

local ecs = require("ecs")
local save, load, tick = ecs.save, ecs.load, ecs.tick

local function systems(w)
  w:system("greet", { "greeting" }, function(w, node)
    if w.frame == 1 then print(node.path .. " says: " .. node.c.greeting.text) end
  end)
  w:system("move", { "pos", "vel" }, function(w, node, dt)
    local p, v = node.c.pos, node.c.vel
    p.x, p.y = p.x + v.x * dt, p.y + v.y * dt
  end)
end

local function where(w, pattern)
  for _, n in ipairs(w:select(pattern)) do
    if n.c.pos then print(("  %-28s (%g, %g)"):format(n.path, n.c.pos.x, n.c.pos.y)) end
  end
end

-- build a world -------------------------------------------------------------
local world = ecs.world()
systems(world)
world:spawn("/game/hello",         { greeting = { text = "Hello, World!" } })
world:spawn("/game/players/mario", { pos = { x = 0, y = 0 }, vel = { x = 1,  y = 2 } })
world:spawn("/game/players/luigi", { pos = { x = 5, y = 5 }, vel = { x = -1, y = 0 } })

-- tick the whole world, then only mario ----------------------------------
tick(world, "/**", 1)
tick(world, "/**", 1)
tick(world, "/game/players/mario", 1)
print("\nafter 2 full ticks + 1 mario-only tick:")
where(world, "/**")

-- save everything ----------------------------------------------------------
local ok, blob = save(world, "/**")
assert(ok, blob)
print("\nsnapshot blob:\n" .. blob)

-- load it into a brand new world, exactly where it was ---------------------
local ok2, copy = load(blob, "/")
assert(ok2, copy)
systems(copy)
tick(copy, "/**", 1)
print("fresh world loaded from blob, ticked once:")
where(copy, "/**")

-- save only the players and patch them under another mount point ----------
local _, players = save(world, "/game/players/*")
assert(load(players, "/backup", world))
print("\noriginal world with players patched under /backup:")
print(world:dump())

-- removals 1: a saved scope is authoritative ------------------------------
-- loading a "/backup/**"-scoped blob deletes nodes in that scope it doesn't list
local _, empty = save(ecs.world(), "/backup/**")
assert(load(empty, "/", world))
print("\nafter loading an empty /backup/** snapshot (backup is gone):")
print(world:dump())

-- removals 2: diff two snapshots, send the patch -------------------------
local _, before = save(world, "/**")
local peer = select(2, load(before, "/"))  -- a peer with the same state
systems(peer)

world:remove("/game/players/luigi")                     -- removed
world:spawn("/game/players/peach", { pos = { x = 9, y = 9 }, vel = { x = 0, y = -1 } })  -- added
tick(world, "/game/players/mario", 1)                   -- changed

local _, patch = ecs.diff(before, world)
print("\npatch sent to peer:\n" .. patch)
assert(ecs.patch(patch, "/", peer))
print("peer in sync after patch:", select(2, save(peer, "/**")) == select(2, save(world, "/**")))

-- bad input is reported, not thrown ---------------------------------------
print("\nload garbage ->", load("return os.exit()", "/"))
local bad = ecs.world()
bad:spawn("/x", { f = print })
print("save a function ->", save(bad, "/**"))

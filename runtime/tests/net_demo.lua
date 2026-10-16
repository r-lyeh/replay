-- net_demo.lua
-- Three peers on a bad simulated network, each owning its own player
-- subtree. They move, spawn and remove nodes; one link is cut for a while.
-- At the end every peer must hold the same copy of /players/**.
--
-- Run: luajit net_demo.lua

local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path

local ecs = require("ecs")
local net = require("net")

local sim = net.sim{ latency = 0.08, jitter = 0.05, loss = 0.25, dup = 0.05, seed = 7 }
local names = { "alice", "bob", "carol" }
local peers = {}

for i, id in ipairs(names) do
  local w = ecs.world()
  -- everyone moves only what they own
  w:system("move", { "pos", "vel" }, function(w, n, dt)
    n.c.pos.x = n.c.pos.x + n.c.vel.x * dt
    n.c.pos.y = n.c.pos.y + n.c.vel.y * dt
  end)
  local me = "/players/" .. id
  w:spawn(me, { pos = { x = i * 10, y = 0 }, vel = { x = i, y = -i } })
  w:spawn(me .. "/pet", { pos = { x = 0, y = 0 }, vel = { x = 0.5, y = 0.5 } })

  local r = net.replica(w, sim:endpoint(id), {
    -- only accept a peer writing inside its own /players/<id> subtree
    accept = function(from, scope) return scope == "/players/" .. from .. "/**" end,
  })
  r:own(me .. "/**")
  peers[id] = { world = w, replica = r, me = me }
end
for _, a in ipairs(names) do
  for _, b in ipairs(names) do if a ~= b then peers[a].replica:connect(b) end end
end

local dt = 1 / 20
for frame = 1, 400 do
  local moving = frame <= 300
  for _, id in ipairs(names) do
    local p = peers[id]
    if moving then p.world:tick(p.me .. "/**", dt) end
    if frame == 100 and id == "alice" then p.world:remove("/players/alice/pet") end
    if frame == 150 and id == "bob" then
      p.world:spawn("/players/bob/hat", { color = "red" })
    end
    if frame == 250 and id == "bob" then p.world:remove("/players/bob/hat") end
    p.replica:update()
  end
  if frame == 120 then sim:cut("bob", "carol") end
  if frame == 220 then sim:heal("bob", "carol") end
  sim:advance(dt)
end

-- compare everyone's view of /players/**
local ref
local all_same = true
for _, id in ipairs(names) do
  local _, blob = peers[id].world:save("/players/**")
  ref = ref or blob
  if blob ~= ref then all_same = false end
end
print(peers.carol.world:dump("/players"))
print()
print("network:", ("sent %d  dropped %d  delivered %d  bytes %d"):format(
  sim.stats.sent, sim.stats.dropped, sim.stats.delivered, sim.stats.bytes))
for _, id in ipairs(names) do
  local s = peers[id].replica.stats
  print(("  %-6s applied %4d  ignored %3d  naks %d  rejected %d"):format(
    id, s.applied, s.ignored, s.naks, s.rejected))
end
print("all peers in sync:", all_same)
assert(all_same)

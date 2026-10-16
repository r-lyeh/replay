-- disk_demo.lua
-- Player 2 pauses, the world is flushed to a folder, the "user" edits
-- files in it, player 2 resumes: the edits are loaded and replicated, and
-- player 1 sees them.
--
-- Run: lua disk_demo.lua   (leaves the folder save_p2/ behind to look at)

local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path

local ecs  = require("ecs")
local net  = require("net")
local disk = require("disk")
local fs   = require("fs")

local sim = net.sim{ latency = 0.05, jitter = 0.02, loss = 0.2, seed = 3 }

local function make_peer(id, x)
  local w = ecs.world()
  w:system("move", { "pos", "vel" }, function(w, n, dt)
    n.c.pos.x = n.c.pos.x + n.c.vel.x * dt
    n.c.pos.y = n.c.pos.y + n.c.vel.y * dt
  end)
  local me = "/players/" .. id
  w:spawn(me, { pos = { x = x, y = 0 }, vel = { x = 1, y = 0 } })
  w:spawn(me .. "/pet", { pos = { x = 5, y = 5 } })
  local r = net.replica(w, sim:endpoint(id), {
    accept = function(from, scope) return scope == "/players/" .. from .. "/**" end,
  })
  r:own(me .. "/**")
  return { id = id, world = w, replica = r, scope = me .. "/**", paused = false }
end

local p1, p2 = make_peer("p1", 0), make_peer("p2", 50)
p1.replica:connect("p2")
p2.replica:connect("p1")

local function run(frames, frozen)
  for _ = 1, frames do
    for _, p in ipairs({ p1, p2 }) do
      if not p.paused and not frozen then p.world:tick(p.scope, 0.1) end
      p.replica:update()            -- paused peers still receive and ack
    end
    sim:advance(0.1)
  end
end

-- remove a folder we created ourselves (demo only)
local function rmtree(dir)
  for _, e in ipairs(fs.list(dir)) do
    local p = fs.join(dir, e.name)
    if e.dir then rmtree(p) else fs.rmfile(p) end
  end
  fs.rmdir(dir)
end

run(30)
print("fs backend: " .. fs.backend)

-- pause ------------------------------------------------------------------------
local folder = here .. "save_p2"
rmtree(folder)
local d = disk.new(folder)
p2.paused = true
assert(d:flush(p2.world, "/**"))
print("p2 paused, world flushed to " .. folder)

-- the user edits files (simulated) --------------------------------------------
local root = folder .. "/players"
fs.write(root .. "/p2/pos.lua", "return { x = 100, y = -40 }\n")       -- move
fs.mkdir(root .. "/p2/hat")                                            -- new node
fs.write(root .. "/p2/hat/color.lua", "return { 255, 0, 0 }\n")
fs.write(root .. "/p2/hat/rect.lua", "return { w = 10, h = 4, fill = true\n")  -- typo!
fs.rmfile(root .. "/p2/pet/pos.lua")                                   -- delete node
fs.rmdir(root .. "/p2/pet")
fs.write(root .. "/p1/pos.lua", "return { x = -999, y = 0 }\n")        -- not ours

-- resume -------------------------------------------------------------------
local function resume(p)
  -- report edits outside what we own: other peers would reject them
  local changed, err = d:changes("/**")
  if not changed then return false, err end
  for _, path in ipairs(changed) do
    if not ecs.match(p.scope, path) then
      print("  warning: " .. path .. " is not yours, edit ignored")
    end
  end
  local ok, res = d:pull(p.world, p.scope)
  if not ok then return false, res end
  p.paused = false
  return true, res
end

print("resume #1:", resume(p2))           -- fails: syntax error, nothing applied
fs.write(root .. "/p2/hat/rect.lua", "return { w = 10, h = 4, fill = true }\n")
print("resume #2:", resume(p2))           -- ok, changed = true

run(30)
run(20, true)   -- stop moving and let the last packets land

-- p1 must see exactly what p2 has under /players/p2 ---------------------------
local _, a = p1.world:save("/players/p2/**")
local _, b = p2.world:save("/players/p2/**")
print("\np1's view of the world:")
print(p1.world:dump("/players"))
print("p2's hat as seen by p1:", ecs.serialize(p1.world:node("/players/p2/hat").c))
print("p1 in sync with p2's edits:", a == b)
print("p1's own position untouched:", p1.world:node("/players/p1").c.pos.x > 0)
assert(a == b)

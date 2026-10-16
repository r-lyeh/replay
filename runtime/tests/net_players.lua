-- net_players.lua
-- Two players of games/pong.lua over a bad simulated network, the way the
-- editor's Players button runs them: player 1 is the host (it simulates the
-- `replicate = true` nodes), player 2 a copy of its world that sends only
-- its own keys (`replicate = 2`). The game doesn't know: for it, both
-- players are local (on_key's player, w.players).
--
-- Run: luajit net_players.lua   (or lua5.4)

local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path

local ecs = require("ecs")
local net = require("net")

local fails = 0
local function check(ok, what)
  print((ok and "ok   " or "FAIL ") .. what)
  if not ok then fails = fails + 1 end
end

local host = dofile(here .. "../../games/pong.lua")
local function copy(w)
  local ok, blob = w:save("/**")
  local c = ecs.world()
  assert(c:load(assert(ok and blob), "/"))
  return c
end
local client = copy(host)

local sim = net.sim{ latency = 0.05, jitter = 0.02, loss = 0.1, dup = 0.05, seed = 3 }
local p1 = net.peer(host, sim:endpoint("p1"), 1)
local p2 = net.peer(client, sim:endpoint("p2"), 2)
p1:connect("p2"); p2:connect("p1")
host.players, client.players = { true, true }, { true, true }

local dt = 1 / 60
local function frame(tick_host)
  sim:advance(dt)
  if tick_host ~= false then host:tick("/**", dt) end
  client:tick("/**", dt)
  p1:update(dt); p2:update(dt)
end
local function y(w, p) return w:node(p).c.xform.y or 0 end

for _ = 1, 30 do frame() end
check(p2:rtt("p1") > 0.05 and p2:rtt("p1") < 0.3, ("a round trip measured: %.0f ms"):format(p2:rtt("p1") * 1000))
local y0, c0 = y(host, "/objects/right"), y(client, "/objects/right")
client:key("w", true, 2)                           -- player 2 holds W, in its own world
frame(); frame()
check(y(client, "/objects/right") < c0 - 5, "player 2's paddle (its own while it plays) moves at once in its world")
check(math.abs(y(host, "/objects/right") - y0) < 1, "... before the host has heard of it")
for _ = 1, 38 do frame() end
check(y(host, "/objects/right") < y0 - 20, "player 2's W moves the right paddle on the host")
check(host:node("/data/input/p2").c.held.w == true, "player 2's keys reach the host")
check(host:node("/data/input/p1").c.held.w == nil, "player 1 holds nothing")
client:key("w", false, 2)

-- a client can't move what the host owns: score (not predicted): undone at once
client:node("/data/score").c.left = 99
p2:update(dt)
check(client:node("/data/score").c.left ~= 99, "a client's write to the host's score is undone")
client:node("/objects/ball").c.xform.x = 999         -- the ball (predicted): the host's state corrects it
for _ = 1, 20 do frame() end
check(math.abs(client:node("/objects/ball").c.xform.x - host:node("/objects/ball").c.xform.x) < 30, "a client's write to the host's ball: corrected")
check(host:node("/objects/ball").c.xform.x ~= 999 and host:node("/data/score").c.left ~= 99, "... and none reaches the host")

-- predicted, the client's ball is where the host's is now, not where it was
-- half a trip ago: compare both while they run (bounces, serves aside)
local sum, n, lag = 0, 0, 0
for _ = 1, 240 do
  local hb = host:node("/objects/ball").c
  local before = { hb.xform.x, hb.xform.y }
  frame()
  hb = host:node("/objects/ball").c
  local cb = client:node("/objects/ball").c
  local d = math.sqrt((hb.xform.x - cb.xform.x) ^ 2 + (hb.xform.y - cb.xform.y) ^ 2)
  if d < 60 then
    sum, n = sum + d, n + 1
    lag = lag + math.sqrt(hb.vel.x ^ 2 + hb.vel.y ^ 2) * p2:rtt("p1") / 2   -- (what showing the host's state, as it arrives, would be off)
  end
end
check(n > 200 and sum / n < 0.5 * lag / n, ("predicted ball: %.1f px off the host's on average (shown as it arrives: %.1f)"):format(sum / n, lag / n))

-- the host stops; the network settles: both see the same owned state
for _ = 1, 120 do frame(false) end
local same = true
for _, scope in ipairs({ "/data/score/**", "/data/input/**" }) do
  local _, a = host:save(scope)
  local _, b = client:save(scope)
  if a ~= b then same = false; print("  differs: " .. scope) end
end
check(same, "host and client agree on every replicated node")

check(client:node("/objects/hud/left").c.text[1] == host:node("/objects/hud/left").c.text[1], "the client's HUD follows the replicated score")

-- player 2 leaves: the computer plays the right paddle again
p1:disconnect("p2"); sim:close("p2")
host.players = { true }
local function ai_moves()
  local before = y(host, "/objects/right")
  for _ = 1, 60 do sim:advance(dt); host:tick("/**", dt); p1:update(dt) end
  return y(host, "/objects/right") ~= before
end
check(ai_moves(), "player 2 gone: the computer plays the right paddle")

print(("network: sent %d  dropped %d  delivered %d  bytes %d"):format(
  sim.stats.sent, sim.stats.dropped, sim.stats.delivered, sim.stats.bytes))
print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

-- net_links.lua: the simulated network's per-player links and the send rate.
-- A link of one's own (a player on a bad line, or unplugged) applies to
-- every packet to and from it (the worse of the two ends); a replica at
-- rate N sends states N times a second, whatever the tick rate.
-- Run from runtime/tests: luajit net_links.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs, net = require("ecs"), require("net")
local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end

local sim = net.sim{ latency = 0.05, seed = 7 }
local a, b, c = sim:endpoint("a"), sim:endpoint("b"), sim:endpoint("c")
sim:link("c", { latency = 0.3 })                   -- c: a slow line
a:send("b", "x"); a:send("c", "y"); c:send("b", "z")
sim:advance(0.1)
check(b:recv() == "a" and b:recv() == nil, "a -> b: the sim's 50 ms")
check(c:recv() == nil, "a -> c: not yet (c's line: 300 ms)")
sim:advance(0.25)
check(c:recv() == "a", "a -> c: after 300 ms")
check(b:recv() == "c", "c -> b: slow too (the worse end)")
sim:link("c", { cut = true })                      -- c unplugged
a:send("c", "lost"); c:send("a", "lost")
sim:advance(1)
check(c:recv() == nil and a:recv() == nil, "cut: nothing in or out")
sim:link("c", nil)                                 -- back: the sim's
a:send("c", "back")
sim:advance(0.1)
check(c:recv() == "a", "healed: the sim's line again")

-- the send rate: a state that changes every tick, sent 10 times a second
local w1, w2 = ecs.world(), ecs.world()
w1:spawn("/objects/x", { n = 0, replicate = true })
w2:spawn("/objects/x", { n = 0, replicate = true })
local s2 = net.sim{ latency = 0.01, seed = 3 }
local p1 = net.peer(w1, s2:endpoint("p1"), 1)
local p2 = net.peer(w2, s2:endpoint("p2"), 2)
p1:connect("p2"); p2:connect("p1")
w1.players, w2.players = { true, true }, { true, true }
p1.replica.rate = 10
local dt = 1 / 60
for i = 1, 120 do                                  -- 2 seconds at 60 ticks
  w1:node("/objects/x").c.n = i
  s2:advance(dt); p1:update(dt); p2:update(dt)
end
local sent = p1.replica.stats.sent
check(sent >= 19 and sent <= 21, "rate 10: about 20 states in 2 s (" .. sent .. ")")
check(math.abs(w2:node("/objects/x").c.n - 120) <= 7, "they still arrive (" .. w2:node("/objects/x").c.n .. " of 120)")
p1.replica.rate = nil
local before = p1.replica.stats.sent
for i = 121, 180 do w1:node("/objects/x").c.n = i; s2:advance(dt); p1:update(dt); p2:update(dt) end
check(p1.replica.stats.sent - before >= 55, "no rate: every tick (" .. (p1.replica.stats.sent - before) .. " in 60)")

print(fails == 0 and "net links: all ok" or ("net links: " .. fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

-- net_bandwidth.lua: sending less. A changed node carries only its changed
-- components (ecs.diff(a, b, true)); a player who doesn't want a node (w.net
-- .interest) drops it, and gets it whole again when it wants it back;
-- with a budget, the scopes with the higher priority go first and more
-- often; unchanged keys don't travel in commands.
-- Run from runtime/tests: luajit net_bandwidth.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs, net = require("ecs"), require("net")
local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end

-- component deltas
local a = ecs.world()
a:spawn("/n", { xform = { x = 1, y = 2 }, big = { text = string.rep("x", 400) }, gone = true })
local _, before = a:save("/**")
a:node("/n").c.xform.x = 5
a:node("/n").c.gone = nil
local _, after = a:save("/**")
local _, coarse = ecs.diff(before, after)
local ok, fine = ecs.diff(before, after, true)
check(ok and #fine < #coarse / 3, "only what changed: " .. #fine .. " bytes, not " .. #coarse)
local b = ecs.world()
b:load(before, "/"); b:load(fine, "/")
local _, got = b:save("/**")
check(got == after, "applied: the same node (big kept, gone dropped)")

-- interest
local sim = net.sim{ latency = 0.03, loss = 0.2, seed = 2 }
local h, c = ecs.world(), ecs.world()
h:spawn("/objects/near", { replicate = true, xform = { x = 0 } })
h:spawn("/objects/far", { replicate = true, xform = { x = 0 } })
local p1, p2 = net.peer(h, sim:endpoint("p1"), 1), net.peer(c, sim:endpoint("p2"), 2)
p1:connect("p2"); p2:connect("p1")
local dt = 1 / 60
local function run(n) for _ = 1, n do sim:advance(dt); h:tick("/**", dt); c:tick("/**", dt); p1:update(dt); p2:update(dt) end end
run(30)
check(c:node("/objects/far") ~= nil, "wanted: there")
p1.interest = function(player, node) return node.c.xform.x < 100 end   -- (far away: not for anyone)
h:node("/objects/far").c.xform.x = 500
run(60)
check(c:node("/objects/far") == nil and c:node("/objects/near") ~= nil, "not wanted: dropped (20% lost)")
local sent0 = p1.replica.stats.bytes["/objects/far/**"] or 0
h:node("/objects/far").c.xform.x = 600
run(60)
check((p1.replica.stats.bytes["/objects/far/**"] or 0) == sent0, "... and not sent while so")
h:node("/objects/far").c.xform.x = 50
run(60)
check(c:node("/objects/far") and c:node("/objects/far").c.xform.x == 50, "wanted again: whole again")

-- priorities and a budget
local sim2 = net.sim{ latency = 0.02, seed = 3 }
local h2, c2 = ecs.world(), ecs.world()
for i = 1, 8 do h2:spawn("/objects/o" .. i, { replicate = { by = 1, priority = i == 1 and 8 or 1 }, xform = { x = 0, pad = string.rep("p", 200) } }) end
local q1, q2 = net.peer(h2, sim2:endpoint("p1"), 1), net.peer(c2, sim2:endpoint("p2"), 2)
q1:connect("p2"); q2:connect("p1")
q1.replica.rate, q1.replica.budget = 20, 1          -- (one scope a send)
for t = 1, 240 do
  for i = 1, 8 do h2:node("/objects/o" .. i).c.xform.x = t end
  sim2:advance(dt); h2:tick("/**", dt); c2:tick("/**", dt); q1:update(dt); q2:update(dt)
end
local hi, lo = q1.replica.stats.bytes["/objects/o1/**"] or 0, q1.replica.stats.bytes["/objects/o2/**"] or 0
check(hi > lo * 2.5, string.format("priority 8: sent more often (%d bytes, a priority 1: %d)", hi, lo))
local lag1 = 240 - c2:node("/objects/o1").c.xform.x
check(lag1 <= 8, "priority 8: hardly late (" .. lag1 .. " ticks)")
check(c2:node("/objects/o8") ~= nil, "priority 1: still comes")

-- commands: unchanged keys don't travel
local sim3 = net.sim{ latency = 0.05, seed = 1 }
local hw, cw = ecs.world(), ecs.world()
for _, w in ipairs({ hw, cw }) do w:spawn("/data/input/p2", { held = { w = true, s = true, a = true, d = true }, replicate = { by = 2, cmd = true } }) end
local r1, r2 = net.peer(hw, sim3:endpoint("p1"), 1), net.peer(cw, sim3:endpoint("p2"), 2)
r1:connect("p2"); r2:connect("p1")
local bytes = 0
local send0 = sim3._send
sim3._send = function(self, from, to, s)
  local ok, m = pcall(net.mp.unpack, s)
  if ok and type(m) == "table" and m.t == "cmds" then bytes = bytes + #s end
  return send0(self, from, to, s)
end
for _ = 1, 120 do sim3:advance(dt); hw:tick("/**", dt); cw:tick("/**", dt); r1:update(dt); r2:update(dt) end
check(bytes / 2 < 6000, string.format("commands, the same keys held: %.1f KB/s", bytes / 2 / 1024))

print(fails == 0 and "net bandwidth: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

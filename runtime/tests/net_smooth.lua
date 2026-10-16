-- net_smooth.lua: ways to hide the network's lag and its few states a
-- second (and to be fair despite it: lag compensation, at the end). Interpolation (`replicate = { by = 1, interp = true }`): what
-- another player owns is shown a little late, between two of its states,
-- so it moves every frame instead of jumping when a state arrives. And a
-- predicted scope whose nodes change (things spawned, removed): a new state
-- brings its new nodes and takes away the gone ones, and the rest stays a
-- guess (before: the whole scope snapped to the owner's state, every tick).
-- Run from runtime/tests: luajit net_smooth.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs, net = require("ecs"), require("net")
local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end

-- interpolation: the host moves a box 60 units a second, sends 10 states a second
local sim = net.sim{ latency = 0.05, seed = 3 }
local wa, wb = ecs.world(), ecs.world()
wa:spawn("/objects/box", { replicate = { by = 1, interp = true, delay = 0.15 }, xform = { x = 0 } })
local pa, pb = net.peer(wa, sim:endpoint("p1"), 1), net.peer(wb, sim:endpoint("p2"), 2)
pa:connect("p2"); pb:connect("p1")
pa.replica.rate = 10
local dt, xs = 1 / 60, {}
for t = 1, 120 do
  wa:node("/objects/box").c.xform.x = t * dt * 60
  sim:advance(dt)
  pa:update(dt); pb:update(dt)
  local n = wb:node("/objects/box")
  if t > 40 and n then xs[#xs + 1] = n.c.xform.x end
end
local steps, rising = 0, true
for i = 2, #xs do
  if xs[i] < xs[i - 1] - 1e-6 then rising = false end
  if math.abs(xs[i] - xs[i - 1]) > 1e-6 then steps = steps + 1 end
end
check(#xs > 0 and rising, "interpolated: never backwards")
check(steps >= #xs - 3, "interpolated: it moves every frame (" .. steps .. " of " .. (#xs - 1) .. "), not 10 times a second")
local lagging = wa:node("/objects/box").c.xform.x - xs[#xs]
check(lagging > 5 and lagging < 30, "a little late: " .. string.format("%.1f", lagging) .. " units (delay + latency)")

-- without it: a jump each state, the same value between
local wc, wd = ecs.world(), ecs.world()
wc:spawn("/objects/box", { replicate = true, xform = { x = 0 } })
local sim2 = net.sim{ latency = 0.05, seed = 3 }
local pc, pd = net.peer(wc, sim2:endpoint("p1"), 1), net.peer(wd, sim2:endpoint("p2"), 2)
pc:connect("p2"); pd:connect("p1")
pc.replica.rate = 10
local same = 0
local last
for t = 1, 120 do
  wc:node("/objects/box").c.xform.x = t * dt * 60
  sim2:advance(dt)
  pc:update(dt); pd:update(dt)
  local n = wd:node("/objects/box")
  if t > 40 and n then if last and n.c.xform.x == last then same = same + 1 end; last = n.c.xform.x end
end
check(same > 40, "plain: it stands still between states (" .. same .. " frames)")

-- a predicted scope whose nodes change: new ones come, gone ones go, the rest stays a guess
local sim3 = net.sim{ latency = 0.05, seed = 5 }
local we, wf = ecs.world(), ecs.world()
we:spawn("/entities/rocks", { replicate = { by = 1, predict = true } })
we:spawn("/entities/rocks/r1", { xform = { x = 0 }, vel = 30 })
local pe, pf = net.peer(we, sim3:endpoint("p1"), 1), net.peer(wf, sim3:endpoint("p2"), 2)
pe:connect("p2"); pf:connect("p1")
local function step(w) for _, n in ipairs(w:select("/entities/rocks/*")) do n.c.xform.x = n.c.xform.x + n.c.vel * dt end end
local snapped
for t = 1, 90 do
  step(we)
  if t == 30 then we:spawn("/entities/rocks/r2", { xform = { x = 100 }, vel = -30 }) end   -- the host spawns one
  if t == 60 then we:remove("/entities/rocks/r1") end                                     -- and one goes
  sim3:advance(dt)
  pe:update(dt)
  step(wf)                                         -- (the guess: the same simulation here)
  if t == 45 then wf:spawn("/entities/rocks/mine", { xform = { x = 0 }, vel = 0 }) end   -- one only here
  pf:update(dt)
  if t == 40 then snapped = wf:node("/entities/rocks/r2") ~= nil end
end
check(snapped, "a new rock arrives")
check(wf:node("/entities/rocks/r1") == nil, "a rock gone at the owner's: gone here")
check(wf:node("/entities/rocks/mine") == nil, "one only here: gone at the next state")
local s
for _, x in pairs(pf.replica.streams) do s = x end
check(s and s.guess ~= nil and (s.reshaped or 0) >= 2, "still a guess after its nodes changed (reshaped " .. tostring(s and s.reshaped) .. " times)")
local r2a, r2b = we:node("/entities/rocks/r2").c.xform.x, wf:node("/entities/rocks/r2").c.xform.x
check(math.abs(r2a - r2b) < 3, string.format("the guess is close: %.2f here, %.2f there", r2b, r2a))

-- jitter: states arrive unevenly (30 ms either way); they carry the time they
-- were made, so the interpolated box still moves evenly
local sim4 = net.sim{ latency = 0.05, jitter = 0.03, seed = 7 }
local wg, wh = ecs.world(), ecs.world()
wg:spawn("/objects/box", { replicate = { by = 1, interp = true, delay = 0.1 }, xform = { x = 0 } })
local pg, ph = net.peer(wg, sim4:endpoint("p1"), 1), net.peer(wh, sim4:endpoint("p2"), 2)
pg:connect("p2"); ph:connect("p1")
pg.replica.rate = 20
local worst, prev = 0, nil
for t = 1, 180 do
  wg:node("/objects/box").c.xform.x = t * dt * 60
  sim4:advance(dt)
  pg:update(dt); ph:update(dt)
  local n = wh:node("/objects/box")
  if t > 60 and n then
    if prev then worst = math.max(worst, math.abs((n.c.xform.x - prev) - 1)) end
    prev = n.c.xform.x
  end
end
check(prev and worst < 0.35, string.format("jitter doesn't show: each frame's step is 1 +- %.2f", worst or -1))

-- a wrap around (snap): a jump, not a slide across
local sim6 = net.sim{ latency = 0.05, seed = 4 }
local wk, wl = ecs.world(), ecs.world()
wk:spawn("/objects/ship", { replicate = { by = 1, interp = true, snap = { x = 200 } }, xform = { x = 380 } })
local pk, pl = net.peer(wk, sim6:endpoint("p1"), 1), net.peer(wl, sim6:endpoint("p2"), 2)
pk:connect("p2"); pl:connect("p1")
pk.replica.rate = 20
local across = false
for t = 1, 60 do
  local x = wk:node("/objects/ship").c.xform
  x.x = x.x + 2; if x.x > 400 then x.x = x.x - 800 end
  sim6:advance(dt)
  pk:update(dt); pl:update(dt)
  local n = wl:node("/objects/ship")
  if t <= 60 and n and math.abs(n.c.xform.x) < 250 then across = true end   -- (by then: at -300, shown a little behind)
end
check(not across, "a wrap around: never shown crossing the middle")

-- lag compensation: player 2 sees the host's ball late (interpolated) and
-- puts its paddle where it sees the ball. The host asks where the paddle
-- was when player 2 was seeing the ball at the host's time t: right there.
local sim5 = net.sim{ latency = 0.06, jitter = 0.01, seed = 9 }
local wi, wj = ecs.world(), ecs.world()
wi:spawn("/objects/ball", { replicate = { by = 1, interp = true }, xform = { x = 0 } })
wj:spawn("/objects/pad", { replicate = { by = 2, interp = true }, xform = { y = 0 } })
local pi, pj = net.peer(wi, sim5:endpoint("p1"), 1), net.peer(wj, sim5:endpoint("p2"), 2)
pi:connect("p2"); pj:connect("p1")
pi.replica.rate, pj.replica.rate = 20, 20
local was = {}                                     -- the ball, by the host's time
local worst2, asked = 0, 0
for t = 1, 240 do
  local now = wi.net:now()
  wi:node("/objects/ball").c.xform.x = now * 60    -- (the host's tick)
  was[#was + 1] = { now, now * 60 }
  local b = wj:node("/objects/ball")               -- (player 2's tick: the paddle follows the ball it sees)
  if b then wj:node("/objects/pad").c.xform.y = b.c.xform.x end
  sim5:advance(dt)
  pi:update(dt); pj:update(dt)
  if t > 90 and t % 10 == 0 then
    local tt = was[#was - 20][1]                   -- (a third of a second ago: they have seen it by now)
    local p = wi.net:as_seen("/objects/pad", tt, "/objects/ball")
    if p then asked = asked + 1; worst2 = math.max(worst2, math.abs(p.xform.y - tt * 60)) end
  end
end
check(asked >= 14, "lag compensation: answered (" .. asked .. " of 15)")
check(worst2 < 0.5, string.format("lag compensation: the paddle where they saw the ball (off by %.2f at most)", worst2))
check(wi.net:seen(2, "/objects/ball") ~= nil and wi.net:seen(2, "/objects/ball") < wi.net:now(), "seen: a time of ours, in the past")

-- exact ages: a predicted ball the host steers, over a jittery link (80 ms,
-- 40 ms either way). Each state is compared with our guess from when the
-- host made it (its stamp, on our clock), not from its arrival less half a
-- round trip: the jitter stays out of the corrections.
local function steer(arrival)
  local sim = net.sim{ latency = 0.08, jitter = 0.04, seed = 3 }
  local a, b = ecs.world(), ecs.world()
  for _, w in ipairs({ a, b }) do
    w:spawn("/objects/ball", { replicate = { by = 1, predict = true }, xform = { x = 0 }, vel = { x = 0 } })
    w:system("move", { "xform", "vel" }, function(_, n, dt) n.c.xform.x = n.c.xform.x + n.c.vel.x * dt end)
  end
  local p1, p2 = net.peer(a, sim:endpoint("p1"), 1), net.peer(b, sim:endpoint("p2"), 2)
  p1:connect("p2"); p2:connect("p1")
  if arrival then p2.replica.rtt_min = setmetatable({}, { __newindex = function() end }) end   -- (no quickest trip: the old way)
  local err, n = 0, 0
  for t = 1, 1200 do
    a:node("/objects/ball").c.vel.x = 200 * math.sin(t / 40)
    sim:advance(dt); a:tick("/**", dt); b:tick("/**", dt); p1:update(dt); p2:update(dt)
    if t > 300 then err = err + math.abs(a:node("/objects/ball").c.xform.x - b:node("/objects/ball").c.xform.x); n = n + 1 end
  end
  return err / n
end
local exact, arrival = steer(false), steer(true)
check(exact < arrival * 0.95, string.format("exact ages: the guess %.2f off on average (by arrival: %.2f)", exact, arrival))

print(fails == 0 and "net smooth: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

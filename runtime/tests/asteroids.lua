-- asteroids.lua: games/asteroids headless. Both ships flown by the AI
-- (nobody playing), ticked at 60 Hz for a few simulated minutes: the systems
-- run without errors, rounds end and start again, a winner and a record
-- come out, rocks keep coming (never more than max), and the same seed plays
-- the same game twice. Run from runtime/tests: luajit asteroids.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs, disk = require("ecs"), require("disk")
local secs = tonumber(arg and arg[1]) or 240

local function play(seconds, players)
  local d = disk.new(here .. "../../games/asteroids")
  local ok, blob = d:read("/**")
  assert(ok, blob)
  local ok2, w = ecs.load(blob, "/")
  assert(ok2, w)
  w.players = players                              -- ({}: nobody plays, both ships fly themselves)
  local rounds, longest, peak, errs = {}, 0, 0, {}
  local last = 0
  for _ = 1, seconds * 60 do
    w:tick("/**", 1 / 60)
    local name, err = next(w.code_err or {})
    if name then errs[#errs + 1] = name .. ": " .. tostring(err) break end
    local s = w:node("/data/state").c
    if s.over and s.round ~= last then
      last = s.round
      rounds[#rounds + 1] = { round = s.round, time = s.time, winner = s.winner,
                              t1 = w:node("/objects/ship1").c.ship.time, t2 = w:node("/objects/ship2").c.ship.time }
      longest = math.max(longest, s.time)
    end
    local box = w:node("/entities/rocks")
    if box then peak = math.max(peak, #w:children(box)) end
  end
  return w, rounds, longest, peak, errs
end

local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end
local w, rounds, longest, peak, errs = play(secs, {})
check(#errs == 0, "no errors: " .. tostring(errs[1]))
check(#rounds >= 2, "rounds end and start again (" .. #rounds .. ")")
local s = w:node("/data/state").c
check(s.record.time > 0 and s.record.who ~= "", "a record, and whose")
local best = 0
for _, r in ipairs(rounds) do best = math.max(best, r.t1, r.t2) end
check(math.abs(s.record.time - best) < 1e-9, "the record is the longest life")
check(peak <= w:node("/data/rules").c.rocks.max * 2 + 2, "rocks: never far past max (splits add some)")
local sum = 0
for _, r in ipairs(rounds) do sum = sum + r.time end
local avg = #rounds > 0 and sum / #rounds or 0
print(string.format("  %d rounds, %.1f s a round on average, longest %.1f s, record %.1f s (%s), %d rocks at most",
  #rounds, avg, longest, s.record.time, s.record.who, peak))
check(avg > 8, "the AI lives a while (" .. string.format("%.1f", avg) .. " s a round)")
local _, again = play(30, {})
local _, first = play(30, {})
check(#again == #first and (not again[1] or again[1].time == first[1].time), "the same seed: the same game")
-- two players over a bad simulated network (as the Players button runs
-- them): player 2 spins and fires (its keys: commands to the host); the
-- host flies its ship, fires its shots and decides the hits
local net = require("net")
do
  local d = disk.new(here .. "../../games/asteroids")
  local _, blob = d:read("/**")
  local _, host = ecs.load(blob, "/")
  local _, client = ecs.load(blob, "/")
  local sim = net.sim{ latency = 0.05, jitter = 0.02, loss = 0.05, seed = 5 }
  local p1 = net.peer(host, sim:endpoint("p1"), 1)
  local p2 = net.peer(client, sim:endpoint("p2"), 2)
  p1:connect("p2"); p2:connect("p1")
  host.players, client.players = { true, true }, { true, true }
  local dt, hits2, errs = 1 / 60, 0, nil
  local function frame()
    sim:advance(dt)
    local live = {}                                -- (player 2's shots with life left: one gone early hit a rock)
    local box = host:node("/entities/shots2")
    if box then for _, sh in ipairs(host:children(box)) do if sh.c.shot.life > 2 * dt then live[sh.path] = true end end end
    host:tick("/**", dt); client:tick("/**", dt)
    for path in pairs(live) do if not host.nodes[path] then hits2 = hits2 + 1 end end
    p1:update(dt); p2:update(dt)
    for _, w in ipairs({ host, client }) do
      local name, err = next(w.code_err or {})
      if name and not errs then errs = name .. ": " .. tostring(err) end
    end
  end
  for _ = 1, 60 do frame() end
  client:key("d", true, 2); client:key("space", true, 2)   -- player 2: spin and fire
  local seen = 0
  for _ = 1, 60 * 20 do
    frame()
    local box = host:node("/entities/shots2")
    if box then seen = math.max(seen, #host:children(box)) end
  end
  check(not errs, "networked: no errors (" .. tostring(errs) .. ")")
  local hr, cr = host:node("/entities/rocks"), client:node("/entities/rocks")
  check(cr and math.abs(#host:children(hr) - #client:children(cr)) <= 3, "player 2 sees the host's rocks")
  check(client:node("/entities/shots2") and seen > 0, "player 2's shots reach the host")
  check(hits2 > 0, "the host breaks rocks with player 2's shots")
  local a, b = host:node("/objects/ship2").c, client:node("/objects/ship2").c
  check(a.ship.alive == b.ship.alive, "the host and player 2 agree on its ship (alive " .. tostring(b.ship.alive) .. ")")
  check(host:node("/data/state").c.round == client:node("/data/state").c.round, "the same round on both")
end

print(fails == 0 and "asteroids: all ok" or ("asteroids: " .. fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

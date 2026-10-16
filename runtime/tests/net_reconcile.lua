-- net_reconcile.lua: games/pong, classic client / server (Gambetta part II).
-- Player 2's keys travel as numbered commands (data/input/p2: { by = 2,
-- cmd = true }); the host simulates the right paddle (`{ by = 1, input = 2 }`)
-- from them, and player 2 predicts it at once and reconciles it with each
-- state from the host (its commands since the host's ack, run again).
-- Over a slow, lossy link: the paddle moves at once for player 2, later on
-- the host, never jumps for player 2, a one-tick tap isn't lost, and both
-- end up exactly in the same place.
-- Run from runtime/tests: luajit net_reconcile.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs, net, disk = require("ecs"), require("net"), require("disk")
local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end

local function pong()
  local ok, blob = disk.new(here .. "../../games/pong"):read("/**")
  assert(ok, blob)
  local ok2, w = ecs.load(blob, "/")
  assert(ok2, w)
  w:node("/data/score").c.over = "left"            -- (the ball waits: only the paddles move)
  w:node("/data/rules").c.restart_after = 1e9
  return w
end

local function session(link)
  local host, client = pong(), pong()
  local sim = net.sim(link)
  local p1, p2 = net.peer(host, sim:endpoint("p1"), 1), net.peer(client, sim:endpoint("p2"), 2)
  p1:connect("p2"); p2:connect("p1")
  host.players, client.players = { true, true }, { true, true }
  local S = { host = host, client = client, p2 = p2, steps = {} }
  function S.frame(keys)                           -- keys: { w = true } this tick (player 2's)
    for _, k in ipairs({ "w", "s" }) do
      local want = keys and keys[k] or false
      if (client:node("/data/input/p2").c.held[k] or false) ~= want then client:key(k, want, 2) end
    end
    local y0 = client:node("/objects/right").c.xform.y or 0
    sim:advance(1 / 60)
    host:tick("/**", 1 / 60); client:tick("/**", 1 / 60)
    p1:update(1 / 60); p2:update(1 / 60)
    S.steps[#S.steps + 1] = math.abs((client:node("/objects/right").c.xform.y or 0) - y0)
  end
  function S.y(w) return w:node("/objects/right").c.xform.y or 0 end
  return S
end

local step = 340 / 60                              -- (data/rules/paddle_speed a tick)
local S = session{ latency = 0.15, jitter = 0.02, loss = 0.1, seed = 5 }
for _ = 1, 30 do S.frame() end
local h0, c0 = S.y(S.host), S.y(S.client)
S.frame{ w = true }
check(S.y(S.client) < c0 - step + 1e-6, "player 2's W: its paddle moves at once")
check(S.y(S.host) == h0, "... the host's, not yet")
for _ = 1, 29 do S.frame{ w = true } end
for _ = 1, 60 do S.frame() end
check(S.y(S.host) < h0 - 100, "the host moved it too (" .. string.format("%.1f", S.y(S.host) - h0) .. ")")
check(math.abs(S.y(S.host) - S.y(S.client)) < 1e-6, string.format("the same place on both: %.3f / %.3f", S.y(S.host), S.y(S.client)))
local worst = 0
for _, d in ipairs(S.steps) do worst = math.max(worst, d) end
check(worst <= step + 1e-6, string.format("player 2's paddle never jumped (its biggest step: %.2f, a tick's move: %.2f)", worst, step))
local s
for _, x in pairs(S.p2.replica.streams) do if x.scope == "/objects/right/**" then s = x end end
check(s and (s.replayed or 0) > 5, "reconciled (" .. tostring(s and s.replayed) .. " times)")

local y1 = S.y(S.host)                             -- a tap: one tick down
S.frame{ s = true }
for _ = 1, 60 do S.frame() end
check(math.abs(S.y(S.host) - (y1 + step)) < 1e-6, string.format("a one-tick tap reaches the host: moved %.2f", S.y(S.host) - y1))
check(math.abs(S.y(S.host) - S.y(S.client)) < 1e-6, "... and both agree")

local B = session{ latency = 0.1, jitter = 0.04, loss = 0.3, seed = 8 }   -- a bad link: 30% lost
for i = 1, 240 do B.frame{ w = (i % 40) < 15, s = (i % 40) > 25 } end
for _ = 1, 90 do B.frame() end
check(math.abs(B.y(B.host) - B.y(B.client)) < 1e-6, string.format("30%% lost: still the same place (%.3f / %.3f)", B.y(B.host), B.y(B.client)))

print(fails == 0 and "net reconcile: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

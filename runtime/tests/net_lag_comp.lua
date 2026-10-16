-- net_lag_comp.lua: games/pong online, player 2 on a slow link (150 ms each
-- way). Player 2 is (nearly) perfect: it holds W / S to keep its paddle
-- where it sees the ball (fast paddles). Its keys reach the host late (as
-- numbered commands), but the host decides the ball's hits on that paddle
-- the way player 2 saw them (lag compensation: systems/ball): player 2
-- never misses. Then player 2 holds its paddle away: the host scores.
-- Run from runtime/tests: luajit net_lag_comp.lua (or lua5.4)
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
  return w
end

local function play(secs, p2_plays, latency)
  local host, client = pong(), pong()
  for _, w in ipairs({ host, client }) do w:node("/data/rules").c.paddle_speed = 1500 end
  local sim = net.sim{ latency = latency, jitter = 0.01, seed = 11 }
  local p1, p2 = net.peer(host, sim:endpoint("p1"), 1), net.peer(client, sim:endpoint("p2"), 2)
  p1:connect("p2"); p2:connect("p1")
  p1.replica.rate, p2.replica.rate = 30, 30
  host.players, client.players = { true, true }, { true, true }
  local dt, bounces, last, keys = 1 / 60, 0, nil, {}
  for _ = 1, secs * 60 do
    sim:advance(dt)
    local want = p2_plays and client:node("/objects/ball").c.xform.y or 160          -- (player 2: the ball, or away)
    local y = client:node("/objects/right").c.xform.y or 0
    local up, down = y > want + 12, y < want - 12
    if up ~= keys.w then client:key("w", up, 2); keys.w = up end
    if down ~= keys.s then client:key("s", down, 2); keys.s = down end
    host:tick("/**", dt); client:tick("/**", dt)
    host:node("/objects/left").c.xform.y = host:node("/objects/ball").c.xform.y      -- (player 1: perfect too)
    p1:update(dt); p2:update(dt)
    local vx = host:node("/objects/ball").c.vel.x
    if last and last > 0 and vx < 0 then bounces = bounces + 1 end
    last = vx
    local name, err = next(host.code_err or {})
    if name then check(false, name .. ": " .. tostring(err)) break end
  end
  return host:node("/data/score").c, bounces
end

local s, bounces = play(20, true, 0.15)             -- (without lag compensation: it misses)
check(bounces >= 5, "the host bounced the ball off player 2's paddle (" .. bounces .. " times)")
check(s.left == 0, "player 2 never missed, the way it saw it (left scored " .. s.left .. ")")
local s2 = play(6, false, 0.15)
check(s2.left >= 1, "player 2 away: the host scores (" .. s2.left .. ")")
local s3, b3 = play(20, true, 0.02)
check(s3.left == 0 and b3 >= 5, "a fast link: the same (" .. s3.left .. ", " .. b3 .. " bounces)")

print(fails == 0 and "net lag compensation: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

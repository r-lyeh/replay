-- net_bundle.lua: one datagram a peer an update (bundled), and the game's own
-- network settings (config/net.lua: rate, bundle, keys, budget; changed on
-- the fly), and a worse network on purpose over real sockets (UdpEp.impair:
-- what the Network button does online).
-- Run from runtime/tests: luajit net_bundle.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs, net, disk = require("ecs"), require("net"), require("disk")
local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end

local function load(game)
  local ok, blob = disk.new(here .. "../../games/" .. game):read("/**")
  assert(ok, blob)
  local ok2, w = ecs.load(blob, "/")
  assert(ok2, w)
  return w
end
-- 10 s of two players; cfg: config/net.lua for both; -> packets/s each way, KB/s, the worlds
local function play(game, cfg, secs, during)
  local host, client = load(game), load(game)
  for _, w in ipairs({ host, client }) do
    if cfg then w:spawn("/config", { net = ecs.copy(cfg) }) end
  end
  local sim = net.sim{ latency = 0.05, seed = 3 }
  local p1, p2 = net.peer(host, sim:endpoint("p1"), 1), net.peer(client, sim:endpoint("p2"), 2)
  p1:connect("p2"); p2:connect("p1")
  p1.replica.rate, p2.replica.rate = 20, 20
  host.players, client.players = { true, true }, { true, true }
  local n, bytes = { p1 = 0, p2 = 0 }, 0
  local send0 = sim._send
  sim._send = function(self, from, to, b) n[from] = n[from] + 1; bytes = bytes + #b; return send0(self, from, to, b) end
  local dt, ticks = 1 / 60, (secs or 10) * 60
  for t = 1, ticks do
    if during then during(t, host, client) end
    if t % 40 == 0 then client:key("w", t % 80 == 0, 2) end
    sim:advance(dt); host:tick("/**", dt); client:tick("/**", dt); p1:update(dt); p2:update(dt)
  end
  for _ = 1, 60 do sim:advance(dt); host:tick("/**", dt); client:tick("/**", dt); p1:update(dt); p2:update(dt) end
  local s = (ticks + 60) / 60
  return n.p1 / s, n.p2 / s, bytes / s / 1024, host, client
end

local h, c, kb = play("asteroids")
check(h <= 26, string.format("bundled: the host sends %.0f packets a second (20 states, a few events)", h))
check(c <= 61, string.format("bundled: player 2 sends %.0f (a command each tick, the clock with one)", c))
local h2, c2, kb2 = play("asteroids", { bundle = false })
check(h2 > h * 2, string.format("bundle = false: one a message (%.0f a second)", h2))
print(string.format("  asteroids: bundled %.0f + %.0f packets/s, %.1f KB/s; not: %.0f + %.0f, %.1f KB/s", h, c, kb, h2, c2, kb2))

local _, c3, _, hp, cp = play("pong", { keys = 30 })
check(c3 <= 31, string.format("keys = 30: player 2 sends %.0f packets a second", c3))
check(math.abs((hp:node("/objects/right").c.xform.y or 0) - (cp:node("/objects/right").c.xform.y or 0)) < 1e-6, "keys = 30: both still agree on the paddle")

local early, late = 0, 0                           -- adaptive: the game changes its rate as it plays
local h4 = play("pong", { rate = 20 }, 10, function(t, host)
  if t == 300 then host:node("/config").c.net.rate = 5 end
end)
check(h4 < 18, string.format("rate changed on the fly (20 -> 5 a second): %.1f packets a second on average", h4))

-- impaired real sockets: pretend ones, a pretend clock
local now = 0
local wire = {}
local function sock(port)
  local s = { port = port, box = {} }
  wire[port] = s
  function s:send(host, p, bytes) local to = wire[p]; if to then to.box[#to.box + 1] = { bytes, "127.0.0.1", self.port } end return true end
  function s:recv() local m = table.remove(self.box, 1); if m then return m[1], m[2], m[3] end end
  return s
end
local a, b = net.udp(sock(2001), "p1"), net.udp(sock(2002), "p2")
a:add("p2", "127.0.0.1", 2002); b:add("p1", "127.0.0.1", 2001)
a.clock = function() return now end
local prm = { latency = 0.1, jitter = 0, loss = 0, dup = 0 }
a.impair = function() return prm end
a:send("p2", "late")
check(b:recv() == nil, "impaired: held for its latency")
now = 0.11; a:poll()
check(select(2, b:recv()) == "late", "... and out after it")
prm.loss = 1; a:send("p2", "lost"); now = 1; a:poll()
check(b:recv() == nil, "loss 1: never")
prm.loss, prm.dup, prm.latency = 0, 1, 0; a:send("p2", "twice"); a:poll()
check(select(2, b:recv()) == "twice" and select(2, b:recv()) == "twice", "dup 1: twice")
a.impair = function() return nil end
a:send("p2", "as is")
check(select(2, b:recv()) == "as is", "nil: as it is, at once")

print(fails == 0 and "net bundle: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

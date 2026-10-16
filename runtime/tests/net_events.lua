-- net_events.lua: events (one-shot, from the host: w:event) reach every
-- player once and in order over a lossy link; a player's own w:event does
-- nothing; a player who joins later doesn't get the old ones. Then
-- asteroids online: a rock's sparks travel as an event (each world makes
-- the burst itself), and player 2's SPACE shows a shot at once (a
-- stand-in), replaced by the host's when it comes.
-- Run from runtime/tests: luajit net_events.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs, net, disk = require("ecs"), require("net"), require("disk")
local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end

local sim = net.sim{ latency = 0.06, jitter = 0.03, loss = 0.3, seed = 4 }
local a, b = ecs.world(), ecs.world()
local got, here_too = {}, {}
b.on_event = function(_, name, data, player) got[#got + 1] = name .. data.i .. "@" .. tostring(player) end
a.on_event = function(_, name, data) here_too[#here_too + 1] = data.i end
local pa, pb = net.peer(a, sim:endpoint("p1"), 1), net.peer(b, sim:endpoint("p2"), 2)
pa:connect("p2"); pb:connect("p1")
local dt = 1 / 60
for t = 1, 300 do
  if t <= 50 then check(a:event("e", { i = t }), "the host's w:event: true") end
  sim:advance(dt); a:tick("/**", dt); b:tick("/**", dt); pa:update(dt); pb:update(dt)
end
local want = {}
for i = 1, 50 do want[i] = "e" .. i .. "@1" end
check(table.concat(got, ",") == table.concat(want, ","), "30% lost: all 50, once, in order (" .. #got .. ")")
check(#here_too == 50, "the host gets its own at once")
check(b:event("x", { i = 0 }) == false, "a player's w:event: nothing (only the host decides)")
local c = ecs.world()
local late = {}
c.on_event = function(_, name, data) late[#late + 1] = data.i end
local pc = net.peer(c, sim:endpoint("p3"), 3)
pa:connect("p3"); pc:connect("p1")
a:event("e", { i = 51 })
for _ = 1, 60 do sim:advance(dt); pa:update(dt); pb:update(dt); pc:update(dt) end
check(#late == 1 and late[1] == 51, "joined later: only the new ones (" .. #late .. ")")

-- asteroids, two players
local function load()
  local ok, blob = disk.new(here .. "../../games/asteroids"):read("/**")
  assert(ok, blob)
  local ok2, w = ecs.load(blob, "/")
  assert(ok2, w)
  return w
end
local host, client = load(), load()
local s2 = net.sim{ latency = 0.08, seed = 6 }
local p1, p2 = net.peer(host, s2:endpoint("p1"), 1), net.peer(client, s2:endpoint("p2"), 2)
p1:connect("p2"); p2:connect("p1")
host.players, client.players = { true, true }, { true, true }
local function frame()
  s2:advance(dt); host:tick("/**", dt); client:tick("/**", dt); p1:update(dt); p2:update(dt)
end
for _ = 1, 120 do frame() end
client:key("space", true, 2)
frame()
local stand = client:node("/entities/mine")
check(stand and #client:children(stand) == 1, "player 2's SPACE: a shot at once, here")
check(not host:node("/entities/shots2") or #host:children(host:node("/entities/shots2")) == 0, "... not yet at the host")
client:key("space", false, 2)
local came, both = false, false
for _ = 1, 40 do
  frame()
  local real = client:node("/entities/shots2/1")
  if real then
    came = true
    if client:node("/entities/mine/1") then both = true end
  end
end
check(came, "the host's shot came")
check(not both, "... and took the stand-in's place (never both)")
local sparks, streams = 0, 0
for _ = 1, 60 * 30 do
  frame()
  local sp = client:node("/entities/sparks")
  if sp then sparks = math.max(sparks, #client:children(sp)) end
end
for _, st in pairs(p2.replica.streams) do if st.scope:find("sparks") then streams = streams + 1 end end
check(sparks > 0, "sparks here, from the host's events (" .. sparks .. " at most)")
check(streams == 0, "sparks aren't replicated")

print(fails == 0 and "net events: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

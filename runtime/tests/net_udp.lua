-- net_udp.lua: net.udp, the real network's endpoint, over pretend sockets
-- (in memory: no network needed; the viewer's own are editor/udp.h).
-- Addresses learnt from the first packet, long messages cut into pieces and
-- put together, control messages beside the data, packets for someone else
-- dropped, a lost piece loses its message; and two replicas keeping a node
-- in sync over it. Run from runtime/tests: luajit net_udp.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs, net = require("ecs"), require("net")
local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end

-- pretend sockets: one shared wire, each socket an address "127.0.0.1:<port>"
local wire, lose = {}, nil                         -- lose(n): drop the n-th datagram sent
local sent = 0
local function sock(port)
  local s = { port = port, box = {} }
  wire[port] = s
  function s:send(host, p, bytes)
    sent = sent + 1
    if lose and lose(sent) then return true end
    local to = wire[p]
    if to then to.box[#to.box + 1] = { bytes, host == "127.0.0.1" and "127.0.0.1" or host, self.port } end
    return true
  end
  function s:recv() local m = table.remove(self.box, 1); if m then return m[1], "127.0.0.1", m[3] end end
  function s:close() wire[port] = nil end
  return s
end

local a = net.udp(sock(1001), "p1")
local b = net.udp(sock(1002), "p2")
check(a:send("p2", "x") == false, "an unknown peer: nothing sent")
b:add("p1", "127.0.0.1", 1001)
b:send("p1", "hello")
check(select(2, a:recv()) == "hello", "b -> a")
check(a:addr("p2") == "127.0.0.1" and select(2, a:addr("p2")) == 1002, "a learnt where p2 is")
a:send("p2", "back")
local from, bytes = b:recv()
check(from == "p1" and bytes == "back", "a -> b, at the learnt address")

local big = string.rep("0123456789", 500)          -- 5000 bytes: 5 pieces
a:send("p2", big)
check(select(2, b:recv()) == big, "a long message: cut, put together")
local got
b.on_control = function(f, m) got = { f, m } end
a:control("p2", big .. "!")
b:recv()
check(got and got[1] == "p1" and got[2] == big .. "!", "a long control message: to on_control, not recv")

local c = net.udp(sock(1003), "p3")
c:add("p2", "127.0.0.1", 1002)                     -- c says it's p3, to p2: fine; p1's packet to p3 at 1002: dropped
a:add("p3", "127.0.0.1", 1002)
a:send("p3", "wrong door")
check(b:recv() == nil, "a packet for someone else: dropped")

local n0 = sent                                    -- (the second piece of the next message: lost)
lose = function(n) return n == n0 + 2 end
a:send("p2", big)
check(b:recv() == nil, "a piece lost: the whole message lost")
lose = nil
a:send("p2", "after")
check(select(2, b:recv()) == "after", "and the next one comes")

-- two replicas over it: a node of a's, kept in sync on b
local wa, wb = ecs.world(), ecs.world()
wa:spawn("/players/a", { pos = { x = 1 }, blob = string.rep("x", 3000) })   -- (bigger than a datagram)
local ra, rb = net.replica(wa, a), net.replica(wb, b)
ra:own("/players/a/**")
ra:connect("p2"); rb:connect("p1")
for _ = 1, 3 do ra:update(1 / 60); rb:update(1 / 60) end
check(wb:node("/players/a") and wb:node("/players/a").c.pos.x == 1 and #wb:node("/players/a").c.blob == 3000, "replicated over udp")
wa:node("/players/a").c.pos.x = 5
for _ = 1, 3 do ra:update(1 / 60); rb:update(1 / 60) end
check(wb:node("/players/a").c.pos.x == 5, "and its changes")

print(fails == 0 and "net udp: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

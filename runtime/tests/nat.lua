-- nat.lua - getting through routers (runtime/nat.lua) on a pretend internet
-- (nat.inet): a host and a joiner, each behind a router of some kind, meet
-- through an introducer; hole punching opens a direct path, a relay when it
-- can't; on the same network a local address wins; what's-my-address.
--   cd runtime/tests && luajit nat.lua   (or lua5.4)
package.path = "../?.lua;" .. package.path
local ecs = require "ecs"
local net = require "net"
local nat = require "nat"
local n, fails = 0, 0
local function check(c, m) n = n + 1; if not c then fails = fails + 1; print("  FAIL: " .. m) end end

-- one meeting: host behind router kind a, joiner behind kind b (nil: no router, a public address)
local function meet(a, b, same_net, opened, iport)
  local inet = nat.inet { latency = 0.02 }
  local isock = inet:socket("198.51.100.1", iport or 47800)  -- the introducer: public
  local I = nat.introducer(isock, function(port) return inet:socket("198.51.100.1", port) end)
  if a then inet:router("hostnet", { kind = a, ip = "203.0.113.10" }) end
  if b and not same_net then inet:router("joinnet", { kind = b, ip = "203.0.113.20" }) end
  local hs = inet:socket(a and "192.168.1.10" or "203.0.113.10", 7777, a and "hostnet" or nil)
  local js = inet:socket(same_net and "192.168.1.20" or (b and "10.0.0.5" or "203.0.113.20"), 0, same_net and "hostnet" or (b and "joinnet" or nil))
  local hep, jep = net.udp(hs, "p1"), net.udp(js, "j1")
  local ilist = iport and net.ports("replay:introducer") or 47800   -- (by name: whichever of its ports answers)
  local hc = nat.client(hep, "198.51.100.1", ilist, { lan = { { hs.ip, hs:port() } } })
  if opened == true or opened == "host" then         -- (the host's router opened 7777 when asked: runtime/portmap.lua)
    local R = inet.routers.hostnet
    R.static[7777], R.back[7777] = hs, hs
    hc:add_candidate(R.ip, 7777)
  end
  local jc = nat.client(jep, "198.51.100.1", ilist, { lan = { { js.ip, js:port() } } })
  if opened == "joiner" then                         -- (the joiner's router opened 6000 when asked, before it meets)
    local R = inet.routers.joinnet
    R.static[6000], R.back[6000] = js, js
    jc:add_candidate(R.ip, 6000)
  end
  hc:register("room1")
  local path, host_saw
  hc.on_intro = function(id, h, p, how) host_saw = { id, h, p, how } end
  local dt = 1 / 60
  for _ = 1, 30 do I:tick(dt); hc:tick(dt); jc:tick(dt); inet:advance(dt) end   -- (the host registers)
  jc:meet("room1", function(h, p, how) path = { h, p, how } end)
  for _ = 1, 360 do I:tick(dt); hc:tick(dt); jc:tick(dt); inet:advance(dt) end
  -- the game's own traffic on that path, both ways (net.udp data)
  local got_h, got_j
  if path then
    jep:add("p1", path[1], path[2])
    jep:send("p1", "hello host")
    for _ = 1, 20 do I:tick(dt); inet:advance(dt); hep:poll(); jep:poll() end
    local from, bytes = hep:recv()
    got_h = from == "j1" and bytes == "hello host"
    if got_h then
      hep:send("j1", "hello joiner")                 -- (the host answers where the joiner was heard from)
      for _ = 1, 20 do I:tick(dt); inet:advance(dt); hep:poll(); jep:poll() end
      local f2, b2 = jep:recv()
      got_j = f2 == "p1" and b2 == "hello joiner"
    end
  end
  return { path = path, host_saw = host_saw, got_h = got_h, got_j = got_j, hc = hc, jc = jc, I = I, hs = hs, js = js }
end

-- what's-my-address
do
  local r = meet("port", "port")
  check(r.hc.public and r.hc.public[1] == "203.0.113.10", "what's-my-address: the host is 203.0.113.10 to the world: " .. tostring(r.hc.public and r.hc.public[1]))
end
do                                                   -- what our router does, from the two ports the introducer saw
  check(meet("port", "port").hc:mapping() == "same", "a port-restricted router: the same port everywhere")
  check(meet("symmetric", "port").hc:mapping() == "step 1", "a symmetric router: a step of 1: " .. tostring(meet("symmetric", "port").hc:mapping()))
  check(meet("random", "port").hc:mapping() == "random", "a random one: random")
end
local cases = {
  { "no routers", nil, nil, "direct" },
  { "full cone, full cone", "full", "full", "direct" },
  { "restricted, port-restricted", "restricted", "port", "direct" },
  { "port-restricted both", "port", "port", "direct" },
  { "symmetric joiner, full cone host", "full", "symmetric", "direct" },
  { "symmetric joiner, port-restricted host (predicted)", "port", "symmetric", "direct" },
  { "symmetric host, restricted joiner (predicted)", "symmetric", "restricted", "direct" },
  { "symmetric host, port-restricted joiner (predicted)", "symmetric", "port", "direct" },
  { "random-port joiner, port-restricted host", "port", "random", "relay" },
  { "symmetric both", "symmetric", "symmetric", "relay" },
}
for _, c in ipairs(cases) do
  local r = meet(c[2], c[3])
  check(r.path and r.path[3] == c[4], c[1] .. ": a path, " .. c[4] .. ": " .. tostring(r.path and r.path[3]))
  check(r.got_h and r.got_j, c[1] .. ": the game's packets get through, both ways")
  if c[4] == "relay" then check(r.I.stats.relayed > 0, c[1] .. ": through the introducer's relay") end
  if c[1]:find("predicted", 1, true) then check(r.I.stats.predicted > 0, c[1] .. ": the predicted ports") end
end
do                                                   -- the same network: a local address wins
  local r = meet("port", "port", true)
  check(r.path and r.path[1] == "192.168.1.10" and r.path[3] == "direct", "the same network: the host's local address: " .. tostring(r.path and r.path[1]))
  check(r.got_h and r.got_j, "the same network: both ways")
end
do                                                   -- both symmetric, but the host's router opened a port when asked
  local r = meet("symmetric", "symmetric", false, true)
  check(r.path and r.path[3] == "direct" and r.path[1] == "203.0.113.10" and r.path[2] == 7777, "both symmetric, the host's port opened: direct to it: " .. tostring(r.path and (r.path[2] .. " " .. r.path[3])))
  check(r.got_h and r.got_j, "...the game's packets, both ways")
end
do                                                   -- both symmetric, the joiner's router opened a port
  local r = meet("symmetric", "symmetric", false, "joiner")
  check(r.path and r.path[3] == "direct" and r.got_h and r.got_j, "both symmetric, the joiner's port opened: direct: " .. tostring(r.path and r.path[3]))
end
do                                                   -- the introducer's port by name: on its 3rd port (as if the first two were taken)
  local p3 = net.ports("replay:introducer")[3]
  local r = meet("port", "symmetric", false, false, p3)
  check(r.hc.ip == p3 and r.jc.ip == p3, "the introducer found on its third port: " .. tostring(r.hc.ip))
  check(r.path and r.path[3] == "direct" and r.got_h and r.got_j, "...and a symmetric joiner predicted through it: " .. tostring(r.path and r.path[3]))
  check(r.jc:mapping() == "step 1", "...its router: a step of 1, measured after the 8 asks: " .. tostring(r.jc:mapping()))
end
do                                                   -- ports by name
  local a, b = net.ports("replay:pong"), net.ports("replay:pong")
  local ok, seen = #a == 8, {}
  for i, p in ipairs(a) do ok = ok and p == b[i] and p >= 20000 and p <= 32767 and not seen[p]; seen[p] = true end
  check(ok, "net.ports: 8 different ports in 20000..32767, the same each time")
  check(table.concat(a, ",") == "30679,27930,21538,28022,24394,23856,28336,32676", "net.ports: the same on every Lua (and in C): " .. table.concat(a, ","))
  check(net.ports("replay:asteroids")[1] ~= a[1], "another name, other ports")
  check(net.fnv32("a") == 3826002220 and net.fnv32("foobar") == 3214735720, "FNV-1a 32: the known values")
  check(net.mix32(1) == 824515495 and net.mix32(123456789) == 1952335732, "hash_32 (Mueller): as in C")
end
do                                                   -- peer IDs
  math.randomseed(5)
  local ids, ok, all = {}, true, true
  for _ = 1, 200 do local id = nat.id_new(); ids[id] = true; ok = ok and nat.id_norm(id) == id and #id == 7 end
  check(ok, "peer IDs: 7 characters, each one checks")
  local id = nat.id_new()
  check(nat.id_norm(id:lower()) == id and nat.id_norm(id:sub(1, 3) .. "-" .. id:sub(4)) == id, "case and a dash forgiven: " .. id)
  local B = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  for i = 1, 7 do                                    -- one wrong character: caught (but 0 <-> Z, the same mod 31)
    for v = 1, 32 do
      local ch = B:sub(v, v)
      local bad = id:sub(1, i - 1) .. ch .. id:sub(i + 1)
      if bad ~= id and nat.id_norm(bad) then
        local a, b = B:find(id:sub(i, i), 1, true), v
        if math.abs(a - b) ~= 31 then all = false end
      end
    end
  end
  check(all, "one wrong character: never another ID")
  check(nat.id_norm("ABCDEF") == nil and nat.id_norm("1.2.3.4") == nil and nat.id_norm("UUUUUUU") == nil, "not IDs: too short, an address, a U")
  check(nat.id_norm("0" .. id:sub(2)) == nat.id_norm("O" .. id:sub(2)), "O read as 0")
end
do                                                   -- peer IDs from keys: a key's ID, its proofs, the introducer checks them
  local E = require "ed25519"
  local seedA, seedB = string.rep("\17", 32), string.rep("\34", 32)
  local pkA, pkB = E.keypair(seedA), E.keypair(seedB)
  local idA, idB = nat.id_of(pkA), nat.id_of(pkB)
  check(idA == "WD4GYN3" and nat.id_norm(idA) == idA and idA ~= idB, "a key's ID: its public key's hash, a valid ID: " .. idA)
  local sig = nat.sign(seedA, "here", idA, "c1")
  check(nat.proves(E.hex(pkA), sig, "here", idA, "c1"), "its owner proves it")
  check(not nat.proves(E.hex(pkA), sig, "here", idA, "c2"), "not with another challenge (no replays)")
  check(not nat.proves(E.hex(pkB), nat.sign(seedB, "here", idA, "c1"), "here", idA, "c1"), "another key can't claim it")
  local function reg(seed, pk, id)                   -- an introducer, a host registering id with that key -> the room, its last word
    local inet = nat.inet {}
    local I = nat.introducer(inet:socket("198.51.100.1", 47800))
    local hs = inet:socket("203.0.113.10", 7777)
    local hc = nat.client(net.udp(hs, "p1"), "198.51.100.1", 47800, { seed = seed, pk = pk and E.hex(pk) })
    hc:register(id)
    for _ = 1, 60 do I:tick(1 / 60); hc:tick(1 / 60); inet:advance(1 / 60) end
    return I.rooms[id], hc.failed
  end
  local r = reg(seedA, pkA, idA)
  check(r and r.pk == E.hex(pkA), "a host registers its own ID: proven (its key's signature)")
  local r2, why = reg(seedB, pkB, idA)
  check(not r2 and why and why:find("no proof", 1, true), "another key registering it: refused (" .. tostring(why) .. ")")
  local r3 = reg(nil, nil, idA)
  check(not r3, "no key at all: not registered by an ID")
  local r4 = reg(nil, nil, "room1")
  check(r4 ~= nil, "a room by name: as before (no key needed)")
end
do                                                   -- a room nobody hosts
  local inet = nat.inet {}
  local I = nat.introducer(inet:socket("198.51.100.1", 47800))
  local js = inet:socket("203.0.113.30", 0)
  local jc = nat.client(net.udp(js, "j1"), "198.51.100.1", 47800)
  jc:meet("nobody")
  for _ = 1, 60 do I:tick(1 / 60); jc:tick(1 / 60); inet:advance(1 / 60) end
  check(jc.meeting.failed and jc.meeting.failed:find("no room", 1, true), "an unknown room: said so")
end

print(string.format("nat: %s", fails == 0 and ("all ok (" .. n .. " checks)") or (fails .. " failed")))

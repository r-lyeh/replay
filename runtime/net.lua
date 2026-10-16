-- net.lua
-- Simulated network + delta replication of world subtrees.
--
-- Two layers:
--
-- 1. Transport: simulated (here), or real UDP (net.udp, below: the same
--    interface; players.lua plays online with it).
--    Peers exchange byte strings. The simulator adds latency, jitter,
--    loss, duplication and reordering, and is deterministic for a seed.
--
--      local sim = net.sim{ latency = 0.05, jitter = 0.02, loss = 0.1, seed = 42 }
--      sim:link("bob", { latency = 0.3, loss = 0.2 })   -- bob on a bad line
--      sim:link("bob", { cut = true })                  -- bob unplugged
--      local a, b = sim:endpoint("alice"), sim:endpoint("bob")
--      a:send("bob", "hi")
--      sim:advance(0.1)
--      local from, bytes = b:recv()      --> "alice", "hi"
--
--    Anything with the same endpoint interface (id, send, recv) can
--    replace it.
--
-- 2. Replica: keeps subtrees of a world in sync between peers.
--    Each peer owns scopes (patterns like "/players/alice/**") and sends
--    them to connected peers as diffs from the last snapshot that peer
--    acknowledged (Quake 3 style snapshot deltas):
--
--      local r = net.replica(world, a)
--      r:own("/players/alice/**")
--      r:connect("bob")
--      r:update()             -- once per tick: receive, apply, send
--      r.rate = 20            -- states 20 times a second (nil: every update)
--
--    Loss, duplicates and reordering are fine: patches are rebuilt
--    against the exact base snapshot they were computed from, old ones
--    are ignored, and unacknowledged state is simply sent again.
--
-- 3. Peer: a world playing in a session (the game doesn't know about the
--    network: for it, every player is local). Nodes tagged
--    `replicate = true` (the host's: player 1) or `replicate = N` (player
--    N's) are owned by that player: only its peer simulates them (ecs: per
--    node systems skip the others' nodes, w.peer) and sends them; everyone
--    else shows what the owner sent last (local writes to them are undone).
--    `replicate = { by = 2 }`: player 2's while it's in the game, else the
--    host's (the owner changes hands: who sends it, who takes it).
--    Prediction, per node: `replicate = { by = 1, predict = true }`: the
--    others simulate it too (a guess, no waiting); each state the owner
--    sends corrects it by how far off the guess was when that state was
--    made (its sender's stamp, put on our clock: arrival jitter doesn't
--    count; `lag = 0.05`: say instead it is that old when it arrives), eased in over
--    `smooth` seconds (0.1), or at once when a number is off by more than
--    `snap` (a teleport, a serve: better a jump than a slow slide; a
--    number, or by field: { x = 200, r = 3 }). Its nodes
--    can come and go: each new state brings its new ones, takes away the
--    gone ones, and leaves the rest a guess.
--    Interpolation, per node: `replicate = { by = 1, interp = true [,
--    delay = 0.1] }`: not simulated here, shown `delay` seconds late
--    between the two states around then (smooth at any send rate). Each
--    state carries the time its sender made it, so their arrival's jitter
--    doesn't show (the delay is a playout buffer: keep it above the jitter).
--    `snap` (as above) here too: a jump (a wrap around the arena) isn't blended.
--    Lag compensation: every peer tells the others which of their times it
--    is showing (a "clock" message with its states). The host asks
--    `w.net:as_seen(path, t, ours)`: where a player had its node `path`
--    when that player was looking at our node `ours` as it was at our time
--    t; `w.net:seen(player, ours)`: the latest of our times it has shown.
--    `replicate = { ..., hold = true }`: not sent while set (a decision
--    pending: the others keep their guess instead of getting a wrong state).
--    Inputs as numbered commands (classic client / server, Gambetta part
--    II): a player's input node tagged `{ by = N, cmd = true }` isn't sent
--    as a state: every tick its contents become command number `tick`, sent
--    to the host (player 1) with every one it hasn't acknowledged yet (a
--    lost packet loses nothing). The host loads them into its world one a
--    tick, in order, and each state it sends says which of yours it had used
--    (`ack`). A node the host owns but your inputs drive, `{ by = 1, input
--    = N }`, is simulated by you at once (prediction); each new state of it
--    from the host replaces yours and your commands since its ack are run
--    again (reconciliation: w:rerun, the node's per-node systems). The
--    others see it as tagged (`interp = true`).
--
--      local p = net.peer(world, sim:endpoint("p2"), 2)
--      p:connect("p1")
--      p:update(dt)   -- once per tick, after the world's tick

local ecs = require("ecs")
local net = {}

---------------------------------------------------------------------------
-- deterministic RNG (same sequence on Lua 5.1 / 5.4 / LuaJIT)
---------------------------------------------------------------------------

local function rng(seed)
  local s = (seed or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()                       -- float in [0, 1)
    s = (s * 16807) % 2147483647          -- Park-Miller, exact in doubles
    return (s - 1) / 2147483646
  end
end
net.rng = rng

-- Ports by name, not by number (mario's idea): a service's ports come from
-- its name, so nobody has to know or type them. net.ports("replay:pong")
-- -> 8 ports in 20000..32767 (the same everywhere, every time): a host
-- binds the first free one (several on one computer: the next), a client
-- tries them all at once. The name: FNV-1a (32 bits); port i: that plus i
-- times the golden ratio, through Thomas Mueller's mixer (hash_32: a
-- bijection, so no two i collide before the cut to the range). 32-bit
-- arithmetic, exact in doubles: LuaJIT and Lua 5.1..5.4 alike, no bit ops.
local function xor8(a, b)                -- (two bytes; no bit ops in 5.1)
  local r, v = 0, 1
  for _ = 1, 8 do
    if a % 2 ~= b % 2 then r = r + v end
    a, b, v = math.floor(a / 2), math.floor(b / 2), v * 2
  end
  return r
end
local function xor32(a, b)
  local r, v = 0, 1
  for _ = 1, 4 do
    r = r + xor8(a % 256, b % 256) * v
    a, b, v = math.floor(a / 256), math.floor(b / 256), v * 256
  end
  return r
end
local function mul32(a, c)               -- a * c mod 2^32, in two halves (each product < 2^53)
  local lo, hi = a % 65536, math.floor(a / 65536)
  return ((hi * c) % 65536 * 65536 + lo * c) % 4294967296
end
local function fnv32(str)
  local h = 2166136261
  for i = 1, #str do
    local lo = h % 256
    h = mul32(h - lo + xor8(lo, str:byte(i)), 16777619)
  end
  return h
end
local function mix32(x)                  -- hash_32 (Thomas Mueller): x ^= x >> 16; x *= 0x45d9f3b; twice; x ^= x >> 16
  x = mul32(xor32(x, math.floor(x / 65536)), 0x45d9f3b)
  x = mul32(xor32(x, math.floor(x / 65536)), 0x45d9f3b)
  return xor32(x, math.floor(x / 65536))
end
net.fnv32, net.mix32 = fnv32, mix32
function net.ports(name, n, lo, hi)
  n, lo, hi = n or 8, lo or 20000, hi or 32767
  local h = fnv32(tostring(name))
  local out, seen, i = {}, {}, 0
  while #out < n and i < n * 8 do
    i = i + 1
    local p = lo + mix32((h + i * 2654435769) % 4294967296) % (hi - lo + 1)
    if not seen[p] then seen[p] = true; out[#out + 1] = p end
  end
  return out
end

---------------------------------------------------------------------------
-- transport: simulated network
---------------------------------------------------------------------------

local Sim = {}
Sim.__index = Sim

local Endpoint = {}
Endpoint.__index = Endpoint

-- opts: latency (s), jitter (s), loss (0..1), dup (0..1), seed
function net.sim(opts)
  opts = opts or {}
  return setmetatable({
    time    = 0,
    latency = opts.latency or 0.05,
    jitter  = opts.jitter or 0,
    loss    = opts.loss or 0,
    dup     = opts.dup or 0,
    rand    = rng(opts.seed or 1),
    eps     = {},        -- id -> endpoint
    flight  = {},        -- packets in the air
    cuts    = {},        -- "a|b" -> true when the link is down
    links   = {},        -- id -> its own link { latency, jitter, loss, dup, cut } (else the sim's)
    seq     = 0,
    stats   = { sent = 0, delivered = 0, dropped = 0, bytes = 0 },
  }, Sim)
end

-- An endpoint leaves: packets to it are dropped from now on.
function Sim:close(id) self.eps[id] = nil end

function Sim:endpoint(id)
  assert(not self.eps[id], "endpoint exists: " .. tostring(id))
  local ep = setmetatable({ id = id, sim = self, inbox = {}, head = 1 }, Endpoint)
  self.eps[id] = ep
  return ep
end

local function link(a, b) if a < b then return a .. "|" .. b end return b .. "|" .. a end

-- Take the link between two peers down / up (both directions).
function Sim:cut(a, b)  self.cuts[link(a, b)] = true end
function Sim:heal(a, b) self.cuts[link(a, b)] = nil end

-- One endpoint's own link (a player on a bad connection): { latency,
-- jitter, loss, dup, cut = true } (missing fields: the sim's); nil: the
-- sim's. A packet between two endpoints gets the worse of their links.
function Sim:link(id, l) self.links[id] = l end
function Sim:_params(from, to)
  local a, b = self.links[from] or {}, self.links[to] or {}
  local function worse(k) return math.max(a[k] or self[k], b[k] or self[k]) end
  return { latency = worse("latency"), jitter = worse("jitter"), loss = worse("loss"), dup = worse("dup"),
           cut = (a.cut or b.cut) and true or false }
end

function Sim:_queue(from, to, bytes, p)
  p = p or self
  self.seq = self.seq + 1
  local delay = p.latency + p.jitter * (self.rand() * 2 - 1)
  if delay < 0 then delay = 0 end
  self.flight[#self.flight + 1] = { at = self.time + delay, n = self.seq,
                                    from = from, to = to, bytes = bytes }
end

function Sim:_send(from, to, bytes)
  assert(type(bytes) == "string", "send expects a string")
  local st = self.stats
  st.sent, st.bytes = st.sent + 1, st.bytes + #bytes
  local p = self:_params(from, to)
  if not self.eps[to] or self.cuts[link(from, to)] or p.cut or self.rand() < p.loss then
    st.dropped = st.dropped + 1
    return
  end
  self:_queue(from, to, bytes, p)
  if self.rand() < p.dup then self:_queue(from, to, bytes, p) end
end

-- Move time forward and deliver everything that has arrived.
function Sim:advance(dt)
  self.time = self.time + (dt or 0)
  local due, keep = {}, {}
  for _, p in ipairs(self.flight) do
    if p.at <= self.time then due[#due + 1] = p else keep[#keep + 1] = p end
  end
  self.flight = keep
  table.sort(due, function(a, b)
    if a.at ~= b.at then return a.at < b.at end
    return a.n < b.n
  end)
  for _, p in ipairs(due) do
    local ep = self.eps[p.to]
    if ep then
      ep.inbox[#ep.inbox + 1] = { p.from, p.bytes }
      self.stats.delivered = self.stats.delivered + 1
    end
  end
end

-- Endpoint API --------------------------------------------------------------

function Endpoint:send(to, bytes) self.sim:_send(self.id, to, bytes) end

-- Pop one received packet: from, bytes  (nil when empty).
function Endpoint:recv()
  local m = self.inbox[self.head]
  if not m then
    self.inbox, self.head = {}, 1
    return nil
  end
  self.inbox[self.head] = nil
  self.head = self.head + 1
  return m[1], m[2]
end

-- Other endpoints on this network, sorted.
function Endpoint:peers()
  local list = {}
  for id in pairs(self.sim.eps) do if id ~= self.id then list[#list + 1] = id end end
  table.sort(list)
  return list
end

---------------------------------------------------------------------------
-- transport: real UDP (the same endpoint interface as the simulator's)
---------------------------------------------------------------------------
-- local ep = net.udp(udp.open(7777), "p1")   -- udp: the viewer's sockets (editor/udp.h)
-- ep:add("p2", "192.168.1.5", 7777)          -- where a peer is (or: learnt from its first packet)
-- ep:send("p2", bytes); local from, bytes = ep:recv()
-- ep:control(to, bytes) / ep.on_control(from, bytes, host, port): the
-- session's own messages (hello, welcome...), beside the replica's.
-- A datagram: "RPL1" from-id NUL to-id NUL kind, then the bytes; kind "d"
-- whole, "c" control, "f" / "g" a piece of a longer one (data / control):
-- msg id (4 bytes), index, count (2 each). Long messages are cut into
-- pieces of MTU bytes and put together again; a lost piece loses the
-- message (the replica sends its state again; the session asks again).
-- Packets for another id, or not ours (no "RPL1"), are dropped.
local MTU = 1100

local UdpEp = {}
UdpEp.__index = UdpEp

-- sock: anything with send(host, port, bytes) and recv() -> bytes, host, port
function net.udp(sock, id, opts)
  opts = opts or {}
  return setmetatable({ sock = sock, id = id, addrs = {}, inbox = {}, parts = {}, nparts = 0, msgid = 0,
                        mtu = opts.mtu or MTU, stats = { sent = 0, received = 0, bytes = 0, dropped = 0 } }, UdpEp)
end
function UdpEp:add(id, host, port) self.addrs[id] = { host, port } end
function UdpEp:pin(id, on) self.pinned = self.pinned or {}; self.pinned[id] = on ~= false or nil end   -- (its address stays: not relearnt from what arrives)
function UdpEp:forget(id) self.addrs[id] = nil end
function UdpEp:addr(id) local a = self.addrs[id] return a and a[1], a and a[2] end
function UdpEp:peers()
  local list = {}
  for id in pairs(self.addrs) do if id ~= self.id then list[#list + 1] = id end end
  table.sort(list)
  return list
end
local function u32(n) return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) end
local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function rd16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function rd32(s, i) return ((s:byte(i) * 256 + s:byte(i + 1)) * 256 + s:byte(i + 2)) * 256 + s:byte(i + 3) end
function UdpEp:_out(to, kind, bytes, host, port)
  if not host then host, port = self:addr(to) end
  if not host then self.stats.dropped = self.stats.dropped + 1 return false end
  local head = "RPL1" .. self.id .. "\0" .. to .. "\0"
  if #bytes <= self.mtu then
    self:_raw(host, port, head .. kind .. bytes, to)
    self.stats.sent, self.stats.bytes = self.stats.sent + 1, self.stats.bytes + #bytes
    return true
  end
  self.msgid = (self.msgid + 1) % 4294967296
  local n = math.ceil(#bytes / self.mtu)
  local pk = kind == "c" and "g" or "f"
  for i = 1, n do
    self:_raw(host, port, head .. pk .. u32(self.msgid) .. u16(i) .. u16(n) .. bytes:sub((i - 1) * self.mtu + 1, i * self.mtu), to)
  end
  self.stats.sent, self.stats.bytes = self.stats.sent + n, self.stats.bytes + #bytes
  return true
end
-- A worse network on purpose, on real sockets (the Network button, online):
-- ep.impair = function(to) -> { latency, jitter, loss, dup, cut } or nil
-- (nil: as it is), ep.clock = function() -> seconds. Each datagram we send
-- is held latency +- jitter, lost, or sent twice, as net.sim does; the ones
-- due go out as we poll. (Our side only: the others impair theirs.)
function UdpEp:_raw(host, port, dg, to)
  local prm = self.impair and self.impair(to)
  if not prm or not self.clock then return self.sock:send(host, port, dg) end
  self.irand = self.irand or rng(11)
  if prm.cut or self.irand() < (prm.loss or 0) then return true end
  self.iq = self.iq or {}
  local now = self.clock()
  for _ = 1, self.irand() < (prm.dup or 0) and 2 or 1 do
    local d = (prm.latency or 0) + (prm.jitter or 0) * (self.irand() * 2 - 1)
    self.iq[#self.iq + 1] = { at = now + math.max(0, d), host = host, port = port, dg = dg }
  end
  self:_release()
  return true
end
function UdpEp:_release()
  local q = self.iq
  if not q or #q == 0 then return end
  local now, due, keep = self.clock(), {}, {}
  for _, x in ipairs(q) do if x.at <= now then due[#due + 1] = x else keep[#keep + 1] = x end end
  self.iq = keep
  table.sort(due, function(a, b) return a.at < b.at end)
  for _, x in ipairs(due) do self.sock:send(x.host, x.port, x.dg) end
end
function UdpEp:send(to, bytes) return self:_out(to, "d", bytes) end
function UdpEp:control(to, bytes, host, port) return self:_out(to, "c", bytes, host, port) end   -- (host, port: one not added yet)
-- every datagram waiting: ours put in the inbox (control: on_control), pieces put together
function UdpEp:poll()
  if self.iq then self:_release() end              -- (held datagrams that are due: out now)
  while true do
    local dg, host, port = self.sock:recv()
    if not dg then break end
    local from, to, rest
    local z1 = dg:sub(1, 4) == "RPL1" and dg:find("\0", 5, true)
    local z2 = z1 and dg:find("\0", z1 + 1, true)
    if z2 then from, to, rest = dg:sub(5, z1 - 1), dg:sub(z1 + 1, z2 - 1), z2 + 1 end
    if from and (to == self.id or to == "*") and rest <= #dg then
      local kind, body = dg:sub(rest, rest), dg:sub(rest + 1)
      if not (self.pinned and self.pinned[from]) and (not self.addrs[from] or self.addrs[from][1] ~= host or self.addrs[from][2] ~= port) then
        self.addrs[from] = { host, port }        -- (learnt: where it is now)
      end
      if kind == "f" or kind == "g" then
        if #body >= 8 then
          local key = from .. "|" .. rd32(body, 1)
          local i, n = rd16(body, 5), rd16(body, 7)
          local m = self.parts[key]
          if not m then
            m = { n = n, got = 0, pieces = {}, kind = kind == "g" and "c" or "d", at = self.nparts }
            self.parts[key] = m
            self.nparts = self.nparts + 1
            if self.nparts % 64 == 0 then           -- (pieces that never all came: forgotten)
              for k, o in pairs(self.parts) do if o.at < self.nparts - 64 then self.parts[k] = nil end end
            end
          end
          if not m.pieces[i] and i >= 1 and i <= m.n then m.pieces[i] = body:sub(9); m.got = m.got + 1 end
          if m.got == m.n then
            self.parts[key] = nil
            local whole = table.concat(m.pieces)
            if m.kind == "c" then if self.on_control then self.on_control(from, whole, host, port) end
            else self.inbox[#self.inbox + 1] = { from, whole } end
            self.stats.received = self.stats.received + 1
          end
        end
      elseif kind == "c" then
        if self.on_control then self.on_control(from, body, host, port) end
        self.stats.received = self.stats.received + 1
      elseif kind == "d" then
        self.inbox[#self.inbox + 1] = { from, body }
        self.stats.received = self.stats.received + 1
      end
    end
  end
end
function UdpEp:recv()
  if #self.inbox == 0 then self:poll() end
  local m = table.remove(self.inbox, 1)
  if m then return m[1], m[2] end
end
function UdpEp:close() if self.sock.close then self.sock:close() end end

---------------------------------------------------------------------------
-- replica: delta replication of owned scopes
---------------------------------------------------------------------------
-- Messages: MessagePack (runtime/msgpack: lua-MessagePack, vendored; data
-- only, nothing runs when one is read):
--   { t = "patch", i, scope, base, seq, d }  sender -> receiver: d = delta(base -> seq);
--                                          i: the scope's number (the scope itself
--                                          only until the receiver acknowledged one)
--   acks ride on the clock messages:       { acks = { [i] = the last seq it has } }
--   { t = "nak",   i }                     receiver lost the base (or the scope's
--                                          name): sender restarts from empty
-- base = 0 means "the empty snapshot". A snapshot is data, World:capture's
-- { scope, nodes = { [path] = components } }; a delta carries, by node path
-- relative to the scope's root, only the fields that changed (`set`, nested
-- as the components are), the fields gone (`drop`: key paths) and the nodes
-- gone (`del`).

local mp = string.pack and require("msgpack.MessagePack53") or require("msgpack.MessagePack")
net.mp = mp

local Replica = {}
Replica.__index = Replica

local is_code, dcopy = ecs.is_code, ecs.copy
local unpack = unpack or table.unpack
local function same(a, b)                          -- the same data, deeply
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return a ~= a and b ~= b end   -- (NaN)
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function nested(a, b) return type(a) == "table" and type(b) == "table" and not is_code(a) and not is_code(b) end
local function part(a, b)                          -- what of table b differs from table a (nil: nothing)
  local o
  for k, v in pairs(b) do
    local x = a[k]
    if not same(x, v) then
      o = o or {}
      if nested(x, v) then o[k] = part(x, v) or {} else o[k] = dcopy(v) end
    end
  end
  return o
end
local function drops(a, b, at, out)                -- key paths in a, not in b
  for k, v in pairs(a) do
    local path = { unpack(at) }
    path[#path + 1] = k
    if b[k] == nil then out[#out + 1] = path
    elseif nested(v, b[k]) then drops(v, b[k], path, out) end
  end
end
local function merge(t, p)                         -- (part, applied)
  for k, v in pairs(p) do
    if nested(t[k], v) then merge(t[k], v) else t[k] = dcopy(v) end
  end
end
local function rel(path, root)                     -- (a node path, short: from the scope's root)
  if root == "/" then return path end
  return path == root and "" or path:sub(#root + 1)
end
local function abs(r, root)
  if type(r) ~= "string" or (r ~= "" and r:sub(1, 1) ~= "/") then error("bad node in a delta", 0) end
  if root == "/" then return r == "" and "/" or r end
  return root .. r
end
-- the delta from snapshot a to snapshot b (same scope)
function net.delta(a, b, root)
  local d, set, del, drop = {}, nil, nil, nil
  for p, c in pairs(b.nodes) do
    local was = a.nodes[p]
    if was == nil then set = set or {}; set[rel(p, root)] = dcopy(c)
    elseif not same(was, c) then
      set = set or {}
      set[rel(p, root)] = part(was, c) or {}
      local dl = {}
      drops(was, c, {}, dl)
      if #dl > 0 then drop = drop or {}; drop[rel(p, root)] = dl end
    end
  end
  for p in pairs(a.nodes) do if b.nodes[p] == nil then del = del or {}; del[#del + 1] = rel(p, root) end end
  d.set, d.del, d.drop = set, del, drop
  return d
end
-- snapshot a with delta d applied: a new snapshot (a stays). Errors on a bad delta.
function net.apply(a, d, root)
  if type(d) ~= "table" then error("bad delta", 0) end
  local nodes = {}
  for p, c in pairs(a.nodes) do nodes[p] = dcopy(c) end
  for _, r in ipairs(type(d.del) == "table" and d.del or {}) do nodes[abs(r, root)] = nil end
  for r, pt in pairs(type(d.set) == "table" and d.set or {}) do
    if type(pt) ~= "table" then error("bad node in a delta", 0) end
    local p = abs(r, root)
    if nodes[p] then merge(nodes[p], pt) else nodes[p] = dcopy(pt) end
  end
  for r, dl in pairs(type(d.drop) == "table" and d.drop or {}) do
    local c = nodes[abs(r, root)]
    for _, path in ipairs(type(dl) == "table" and dl or {}) do
      local t = c
      for i = 1, #path - 1 do t = type(t) == "table" and t[path[i]] or nil end
      if type(t) == "table" and #path > 0 then t[path[#path]] = nil end
    end
  end
  return { version = 1, scope = a.scope, nodes = nodes, removed = {} }
end
local function empty_of(scope) return { version = 1, scope = scope, nodes = {}, removed = {} } end

local KEEP = 64   -- snapshots kept per incoming stream

-- opts.accept(from, scope) -> bool decides which remote scopes may be
-- written into our world. Default: accept everything (fine for the stub;
-- a real p2p network needs an ownership/permission policy here).
function net.replica(world, endpoint, opts)
  opts = opts or {}
  return setmetatable({
    world  = world,
    ep     = endpoint,
    accept = opts.accept or function() return true end,
    owned  = {},    -- scope -> { seq, history = {seq -> blob}, empty, acked = {peer -> seq} }
    order  = {},    -- owned scopes in insertion order
    peers  = {},    -- connected peer ids (sorted list)
    streams = {},   -- "from|scope" -> { last, snaps = {seq -> blob} }
    stats  = { sent = 0, applied = 0, ignored = 0, rejected = 0, naks = 0 },
    now    = 0,     -- seconds (advanced by update(dt)): round trips are measured with it
    rtts   = {},    -- peer -> round trip (s), smoothed: a patch sent -> its ack
    hold   = opts.hold, -- hold(scope) -> true: don't send it now
    bundle = opts.bundle, -- true: what goes to a peer in an update goes as one datagram (flush)
    interest = opts.interest, -- interest(peer, scope) -> false: not for that peer now (it drops it)
    priority = opts.priority, -- priority(scope) -> a number (1): who goes first when the budget is short
    rate_of = opts.rate_of, -- rate_of(scope) -> its own states a second (nil: the replica's)
    budget = opts.budget, -- bytes of states to a peer a send (nil: no limit; at least one scope goes)
    rate   = opts.rate, -- states sent this many times a second (nil: every update); acks: at once
    offs   = {},    -- peer -> our clock - theirs (+ the trip here: the least seen, slowly let up)
    views  = {},    -- peer -> { { at = their time, tick =, seen = { [our scope] = our time they showed } } }
    me     = opts.me, -- our player (inputs: the nodes `{ input = me }` are ours to predict and reconcile)
    host   = opts.host, -- host(peer) -> true: where our commands go
    tick   = 0,     -- updates so far: our commands' numbers
    cmds   = {},    -- ours: tick -> { blob = the input scopes then, dt }
    cmd_ack = {},   -- peer -> the last of our commands it said it used
    inq    = {},    -- from -> { list = { seq -> blob }, loaded, used, max, stall }: theirs, to apply
    past   = {},    -- path -> { from, list = { { seq, c } } }: what their commands did here (lag compensation)
    evseq  = 0,     -- our events: the last one's number
    evlog  = {},    -- ours, not yet acknowledged by everyone: { seq, name, data }
    ev_acked = {},  -- peer -> the last of our events it said it got
    ev_got = {},    -- from -> the last of theirs we handed on
    ev_buf = {},    -- from -> { seq -> event }: theirs that came early (one missing before them)
    on_event = opts.on_event, -- on_event(from, name, data): one of theirs, once, in order
  }, Replica)
end

-- time to send states? (rate: N a second; nil or 0: every update)
function Replica:due()
  if not self.rate or self.rate <= 0 then return true end
  local nxt = self.next_send or 0
  if self.now + 1e-9 < nxt then return false end
  nxt = nxt + 1 / self.rate
  if nxt < self.now then nxt = self.now + 1 / self.rate end   -- (fell behind: from now)
  self.next_send = nxt
  return true
end

function Replica:own(scope, cmd)
  scope = ecs.normalize(scope)
  if self.owned[scope] then self.owned[scope].cmd = cmd or nil return end
  local empty = empty_of(scope)
  local acked = {}
  for _, p in ipairs(self.peers) do acked[p] = 0 end   -- (peers connected before: from the start)
  self.next_id = (self.next_id or 0) + 1           -- (its number on the wire: never reused)
  self.by_id = self.by_id or {}
  self.by_id[self.next_id] = scope
  self.owned[scope] = { seq = 0, history = { [0] = empty }, empty = empty, acked = acked, cmd = cmd or nil, id = self.next_id }
  self.order[#self.order + 1] = scope
end

-- commands ------------------------------------------------------------------

-- our input scopes (`cmd`) this tick: command number `tick` (kept 3 s: resent
-- until acknowledged, replayed when reconciling)
function Replica:record(dt)
  self.tick = self.tick + 1
  local blobs, any = {}, false
  for _, scope in ipairs(self.order) do
    if self.owned[scope].cmd then blobs[scope], any = self.world:capture(scope), true end
  end
  local last = self.cmds[self.tick - 1]
  if any and last and same(blobs, last.blob) then blobs = last.blob end   -- (unchanged: the same table, sent as "same")
  if any then self.cmds[self.tick] = { blob = blobs, dt = dt } end
  self.cmds[self.tick - 180] = nil
end
function Replica:_load_cmd(blobs)
  for _, b in pairs(blobs) do self.world:put(b, "/") end
end

-- the host: commands that came, kept to be applied in order
function Replica:_on_cmds(from, m)
  if type(m.first) == "number" and type(m.last) == "number" and type(m.blobs) == "table" and m.last - m.first < 64 then
    local list = {}                                -- ({ first, last, blobs = { [i] = blob } }: one entry a command)
    for q = m.first, m.last do
      local slim, blob = m.blobs[q - m.first + 1], nil
      if type(slim) == "table" then                -- (each scope's nodes: a snapshot again)
        blob = {}
        for scope, nodes in pairs(slim) do
          if type(scope) == "string" and type(nodes) == "table" then blob[scope] = { version = 1, scope = scope, nodes = nodes, removed = {} } end
        end
      end
      list[#list + 1] = { seq = q, blob = blob }
    end
    m.list = list
  end
  if type(m.list) ~= "table" then return end
  local q = self.inq[from] or { list = {} }
  self.inq[from] = q
  for _, c in ipairs(m.list) do                    -- (no blob: the same as the one before it, here or kept)
    if type(c) == "table" and c.blob == nil and type(c.seq) == "number" then
      c.blob = q.list[c.seq - 1] or (q.loaded == c.seq - 1 and q.loaded_blob) or nil
    end
    if type(c) == "table" and type(c.seq) == "number" and type(c.blob) == "table" and c.seq > (q.loaded or 0) and not q.list[c.seq] then
      local ok = true
      for scope in pairs(c.blob) do if type(scope) ~= "string" or not self.accept(from, scope) then ok = false end end
      if ok then q.list[c.seq] = c.blob; q.max = math.max(q.max or 0, c.seq) end
    end
  end
end
-- the host, each tick: the commands the last tick ran with are "used"; the
-- next of each player's goes into the world for the next tick (one a tick;
-- far behind: on to the newest but two; a gap that stays: skipped)
function Replica:used() for _, q in pairs(self.inq) do q.used = q.loaded end end
function Replica:apply_cmds()
  for _, q in pairs(self.inq) do
    local n = (q.loaded or 0) + 1
    if q.max and q.max - n > 8 then n = q.max - 2 end
    if not q.list[n] and q.max and q.max > n then
      q.stall = (q.stall or 0) + 1
      if q.stall > 3 then for k = n, q.max do if q.list[k] then n = k break end end end
    end
    if q.list[n] then
      self:_load_cmd(q.list[n])
      q.loaded, q.stall, q.loaded_blob = n, 0, q.list[n]
      for k in pairs(q.list) do if k <= n then q.list[k] = nil end end
    end
  end
end
-- (to the host: the commands it hasn't acknowledged, the newest 32)
function Replica:_send_cmds()
  if not self.cmds[self.tick] or not self.host then return end
  for _, peer in ipairs(self.peers) do
    if self.host(peer) then
      local first, blobs, any = math.max((self.cmd_ack[peer] or 0) + 1, self.tick - 31), {}, false
      while first <= self.tick and not self.cmds[first] do first = first + 1 end
      for q = first, self.tick do                  -- (only the ones that differ from the one before carry
        local c, before = self.cmds[q], self.cmds[q - 1]   -- their keys; the host has that one, or it comes first)
        if c then
          any = true
          if not (before and before.blob == c.blob) then   -- (on the wire: each scope's nodes, nothing more)
            local slim = {}
            for scope, st in pairs(c.blob) do slim[scope] = st.nodes end
            blobs[q - first + 1] = slim
          end
        end
      end
      if any then self:_send(peer, { t = "cmds", first = first, last = self.tick, blobs = blobs }) end
    end
  end
end

-- events: ours go to every peer with every one it hasn't acknowledged
-- (each update: not at the state rate), theirs are handed on once, in order
function Replica:event(name, data)
  self.evseq = self.evseq + 1
  self.evlog[#self.evlog + 1] = { seq = self.evseq, name = name, data = data }
end
function Replica:_send_events()
  if #self.evlog == 0 then return end
  local low = self.evseq
  for _, peer in ipairs(self.peers) do
    local a = self.ev_acked[peer] or 0
    if a < low then low = a end
    local list = {}
    for _, e in ipairs(self.evlog) do if e.seq > a and #list < 64 then list[#list + 1] = e end end
    if #list > 0 then self:_send(peer, { t = "events", list = list, base = a }) end   -- (base: what came before isn't for it)
  end
  local keep = {}                                  -- (acknowledged by all: forgotten; 256 at most kept)
  for _, e in ipairs(self.evlog) do if e.seq > low then keep[#keep + 1] = e end end
  while #keep > 256 do table.remove(keep, 1) end
  self.evlog = keep
end
function Replica:_on_events(from, m)
  if type(m.list) ~= "table" then return end
  local got, buf = self.ev_got[from] or 0, self.ev_buf[from] or {}
  if type(m.base) == "number" and m.base > got then got = m.base; self.ev_got[from] = got end   -- (joined after those)
  self.ev_buf[from] = buf
  for _, e in ipairs(m.list) do
    if type(e) == "table" and type(e.seq) == "number" and e.seq > got and type(e.name) == "string" then buf[e.seq] = e end
  end
  while buf[got + 1] do
    local e = buf[got + 1]
    buf[got + 1], got = nil, got + 1
    self.ev_got[from] = got
    if self.on_event then self.on_event(from, e.name, e.data) end
  end
end

-- reconciliation: the host's state of a node our inputs drive, and our
-- commands since the one it had used, run again
function Replica:_reconcile(s)
  self.world:put(s.snaps[s.last], "/")
  local a = s.acks and s.acks[s.last] or 0
  for q = a + 1, self.tick do
    local c = self.cmds[q]
    if c then self:_load_cmd(c.blob); self.world:rerun(s.scope, c.dt) end
  end
  local last = self.cmds[self.tick]
  if last then self:_load_cmd(last.blob) end
  s.replayed = (s.replayed or 0) + 1
end

function Replica:connect(peer)
  for _, p in ipairs(self.peers) do if p == peer then return end end
  self.peers[#self.peers + 1] = peer
  table.sort(self.peers)
  self.ev_acked[peer] = self.evseq                 -- (events from now on: not the ones before it came)
  for _, o in pairs(self.owned) do o.acked[peer] = 0 end
end

-- A peer left: nothing more to it, and what it sent is forgotten (its
-- nodes stay as they were last).
function Replica:disconnect(peer)
  for i, p in ipairs(self.peers) do if p == peer then table.remove(self.peers, i) break end end
  for _, o in pairs(self.owned) do o.acked[peer] = nil end
  if self.their_ids then self.their_ids[peer] = nil end
  local pre = peer .. "|"
  for key in pairs(self.streams) do
    if key:sub(1, #pre) == pre then self.streams[key] = nil end
  end
end

-- What others own shows what they sent last: local changes to it (a system,
-- an edit, a rewind) are undone. Call after the world's tick (now: advanced).
-- A predicted scope (its node's tag: { predict = true }) keeps its local
-- guess instead, corrected by what the owner sent: the owner's state is
-- `lag` seconds old when it arrives (default: half the round trip), so it is
-- compared with our own guess from that long ago, and the difference is
-- added to now's (numbers; anything else that differed takes the owner's).
local function copy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = copy(x) end
  return o
end
-- `snap`: a number (any field), or by field name ({ x = 100, r = 3 })
local function limit(snap, key) if type(snap) == "table" then return tonumber(snap[key]) end return tonumber(snap) end
local function correct(cur, past, want, k, snap, key)   -- now's guess + k * (owner's - our past guess)
  if type(want) == "number" then                   -- (off by more than `snap`: all of it at once)
    if type(cur) == "number" and type(past) == "number" then
      local most = limit(snap, key)
      if most and math.abs(want - past) > most then k = 1 end
      return past == want and cur or cur + (want - past) * k
    end
    return want
  end
  if type(want) == "table" then
    local o = {}
    for key, v in pairs(want) do
      o[key] = correct(type(cur) == "table" and cur[key] or nil, type(past) == "table" and past[key] or nil, v, k, snap, key)
    end
    return o
  end
  if past == want and cur ~= nil then return cur end
  return want
end
function Replica:enforce()
  for _, s in pairs(self.streams) do
    local node = self.world:node((s.scope:gsub("/%*%*$", "")))
    local by = node and net.owner(node.c.replicate, self.world)
    if by and by ~= tonumber(tostring(s.from):match("(%d+)$")) then by = false end   -- (it changed hands: not the sender's any more)
    if s.last > 0 and by ~= false and not self.owned[s.scope] then
      if s.dec_seq ~= s.last then s.dec, s.dec_seq = s.snaps[s.last], s.last end
      local root = s.dec and s.dec.nodes and s.dec.nodes[(s.scope:gsub("/%*%*$", ""))]
      local r = root and root.replicate
      local here = self.world:select(s.scope)
      local driven = type(r) == "table" and self.me ~= nil and r.input == self.me   -- (our inputs drive it: reconcile)
      local predict = not driven and type(r) == "table" and r.predict and true or false
      if predict and s.fixed ~= s.last then        -- a new state: its nodes here too (gone ones go, new ones
        local changed = false                      -- come); the others stay guesses, corrected below
        for path, c in pairs(s.dec.nodes) do
          if not self.world.nodes[path] then self.world:spawn(path, copy(c)); changed = true end
        end
        for _, node in ipairs(here) do
          if not s.dec.nodes[node.path] and self.world.nodes[node.path] then self.world:remove(node.path); changed = true end
        end
        if changed then here = self.world:select(s.scope); s.reshaped = (s.reshaped or 0) + 1 end
      end
      if driven then
        if s.fixed ~= s.last then self:_reconcile(s); s.fixed = s.last end
      elseif not predict and type(r) == "table" and r.interp and s.hist then
        self:_interp(s, tonumber(r.delay) or 0.1)
      elseif not predict then
        self.world:put(s.snaps[s.last], "/")
        s.guess, s.fixed = nil, s.last
      else
        s.guess = s.guess or {}                    -- our guesses, by time
        local g = { t = self.now, nodes = {} }
        for _, node in ipairs(here) do g.nodes[node.path] = copy(node.c) end
        s.guess[#s.guess + 1] = g
        if s.fixed ~= s.last then                  -- a new state from the owner: how far off were we?
          local made                               -- (when the owner made it, by its clock: its tick's time;
          for i = #(s.hist or {}), 1, -1 do        -- on ours, + the clocks' offset: no arrival jitter in it)
            if s.hist[i].seq == s.last then made = s.hist[i].at break end
          end
          local off = self.offs[s.from]
          local least = self.rtt_min and self.rtt_min[s.from]
          local at = r.lag and self.now - tonumber(r.lag)                    -- (told: that long ago)
                     or made and off and least and made + off - least / 2    -- (their time on our clock)
                     or self.now - self:rtt(s.from) / 2                      -- (not measured yet: a guess)
          local past
          for _, x in ipairs(s.guess) do if x.t <= at + 1e-9 then past = x end end
          if past then                             -- now, and every guess kept, by (part of) that much
            local k = math.min(1, (self.now - (s.fixed_t or self.now)) / (tonumber(r.smooth) or 0.1))
            local pn = past.nodes
            for _, node in ipairs(here) do
              local want = s.dec.nodes[node.path]
              local snap = r.snap
              for _, x in ipairs(s.guess) do
                if x ~= past then x.nodes[node.path] = correct(x.nodes[node.path], pn[node.path], want, k, snap) end
              end
              node.c = correct(node.c, pn[node.path], want, k, snap)
              pn[node.path] = correct(pn[node.path], pn[node.path], want, k, snap)
            end
          elseif #s.guess >= 256 then              -- (no guess that old: the owner's, as it is)
            for _, node in ipairs(here) do node.c = copy(s.dec.nodes[node.path]) end
          end
          s.fixed, s.fixed_t = s.last, self.now
          if past then                             -- (guesses before that one: never compared again)
            local keep = {}
            for _, x in ipairs(s.guess) do if x == past or x.t > past.t then keep[#keep + 1] = x end end
            s.guess = keep
          end
          while s.guess[2] and s.guess[2].t <= at - 0.5 do table.remove(s.guess, 1) end
        end
        while #s.guess > 256 do table.remove(s.guess, 1) end
      end
      s.was, s.shows = s.shows, self:_shown(s)     -- (what the next tick sees; the state we send next came from the one before)
    end
  end
end

-- an interpolated scope (its tag: { interp = true [, delay = 0.1] }): shown
-- `delay` seconds late, between the two states that arrived around then
-- (numbers blended; the rest, and nodes in only one of them, the later's).
-- Smooth at any send rate, for what others own and we don't predict.
local function blend(a, b, f, snap, key)           -- (a jump bigger than `snap`, a wrap around: not blended)
  if type(a) == "number" and type(b) == "number" then
    local most = limit(snap, key)
    if most and math.abs(b - a) > most then return b end
    return a + (b - a) * f
  end
  if type(a) == "table" and type(b) == "table" then
    local o = {}
    for k, v in pairs(b) do o[k] = blend(a[k], v, f, snap, k) end
    return o
  end
  return copy(b)
end
function Replica:_interp(s, delay)
  local h, at = s.hist, self.now - (self.offs[s.from] or 0) - delay   -- (their time, `delay` ago)
  local i = #h
  while i > 1 and h[i].at > at do i = i - 1 end    -- h[i]: the last state they had made by then
  local a, b = h[i], h[i + 1]
  local snap = s.snaps[(b or a).seq]
  if not snap then return end
  if s.shown ~= (b or a).seq then self.world:put(snap, "/"); s.shown = (b or a).seq end   -- (its nodes: the later state's)
  if not b or b.at <= a.at then
    for path, c in pairs(a.nodes) do local n = self.world.nodes[path]; if n then n.c = copy(c) end end
    return
  end
  local f = math.max(0, math.min(1, (at - a.at) / (b.at - a.at)))
  for path, c in pairs(b.nodes) do
    local n = self.world.nodes[path]
    if n then n.c = a.nodes[path] and blend(a.nodes[path], c, f, type(s.tag) == "table" and s.tag.snap) or copy(c) end
  end
end

-- clocks: a time of theirs, `at`, got here now: how far apart are we?
-- (the least: the fastest trip; let up slowly, for a trip that got longer)
function Replica:_clock(from, at)
  if type(at) ~= "number" then return end
  local d, o = self.now - at, self.offs[from]
  self.offs[from] = (not o or d < o) and d or o + (d - o) * 0.01
end

-- which time of the sender's we show of a stream: interpolated, `delay`
-- behind what arrives; predicted, their now (what arrives + the trip);
-- else the last state's
function Replica:_shown(s)
  local h, off, r = s.hist, self.offs[s.from], s.tag
  if not h or not h[1] then return nil end
  if off and type(r) == "table" and (r.predict or (self.me ~= nil and r.input == self.me)) then return self.now - off + (tonumber(r.lag) or self:rtt(s.from) / 2) end
  if off and type(r) == "table" and r.interp then return math.max(h[1].at, self.now - off - (tonumber(r.delay) or 0.1)) end
  return h[#h].at
end

local function root_of(scope) return (scope:gsub("/%*%*$", "")) end

-- lag compensation: node `path` (another peer's) as its owner had it when
-- it was showing our node `ours` as it was at our time t (nil: not known,
-- or they haven't shown that time yet)
-- (when a peer showed our node `ours` at our time t: the clock message
-- before and after it, and how far between)
function Replica:_when(from, t, ours)
  local v = self.views[from]
  if not v then return nil end
  local key = root_of(ecs.normalize(ours)) .. "/**"
  for i = 1, #v - 1 do
    local va, vb = v[i].seen[key], v[i + 1].seen[key]
    if va and vb and va <= t and t <= vb then return v[i], v[i + 1], vb > va and (t - va) / (vb - va) or 1 end
  end
end

function Replica:as_seen(path, t, ours)
  local own = self.past[path]                      -- a node of ours their commands drive: by their command then
  if own then
    local a, b, f = self:_when(own.from, t, ours)
    if not (a and a.tick and b.tick) then return nil end
    local tk, l = a.tick + (b.tick - a.tick) * f, own.list
    if not l[#l] or l[#l].seq < math.ceil(tk - 1e-9) then return nil end   -- (that command not used here yet)
    for i = #l, 1, -1 do
      if l[i].seq <= tk + 1e-9 then
        local nx = l[i + 1]
        if not nx or nx.seq == l[i].seq then return copy(l[i].c) end
        return blend(l[i].c, nx.c, math.max(0, math.min(1, (tk - l[i].seq) / (nx.seq - l[i].seq))))
      end
    end
    return nil
  end
  local s
  for _, x in pairs(self.streams) do
    local r = root_of(x.scope)
    if x.hist and x.hist[1] and (path == r or path:sub(1, #r + 1) == r .. "/") then s = x break end
  end
  if not s then return nil end
  local va, vb, f = self:_when(s.from, t, ours)    -- their time when they showed our t
  if not va then return nil end
  local at = va.at + (vb.at - va.at) * f
  local h = s.hist                                 -- their node then (what they sent around then)
  local i = #h
  while i > 1 and h[i].at > at do i = i - 1 end
  local a, b = h[i].nodes[path], h[i + 1] and h[i + 1].nodes[path]
  if not a then return b and copy(b) end
  if not b or h[i + 1].at <= h[i].at then return copy(a) end
  return blend(a, b, math.max(0, math.min(1, (at - h[i].at) / (h[i + 1].at - h[i].at))), type(s.tag) == "table" and s.tag.snap)
end

-- the latest of our times that peer has shown of our node `ours`
function Replica:seen(from, ours)
  local v = self.views[from]
  local e = v and v[#v]
  return e and e.seen[root_of(ecs.normalize(ours)) .. "/**"]
end

-- not ours any more (its new owner sends it): stop sending it
function Replica:disown(scope)
  if not self.owned[scope] then return end
  self.owned[scope] = nil
  for i, x in ipairs(self.order) do if x == scope then table.remove(self.order, i) break end end
end

-- the round trip to a peer (s), 0 until measured
function Replica:rtt(peer) return self.rtts[peer] or 0 end
-- the quickest round trip (let up slowly, as the clocks' offset): half of it
-- is the trip inside that offset
function Replica:_least(from, r)
  self.rtt_min = self.rtt_min or {}
  local o = self.rtt_min[from]
  self.rtt_min[from] = (not o or r < o) and r or o + (r - o) * 0.01
end

function Replica:_send(to, msg)               -- -> its size (bytes)
  local bytes = mp.pack(msg)
  if self.bundle then                              -- (bundled: one datagram a peer an update, see flush)
    self.out = self.out or {}
    local q = self.out[to] or {}
    self.out[to] = q
    q[#q + 1] = bytes
  else self.ep:send(to, bytes); self.stats.packets = (self.stats.packets or 0) + 1 end
  if msg.t == "clock" then self.stats.clocks = (self.stats.clocks or 0) + 1 else self.stats.sent = self.stats.sent + 1 end
  return #bytes
end

-- incoming ------------------------------------------------------------------

function Replica:_on_patch(from, m)
  if type(m.i) ~= "number" or type(m.seq) ~= "number" or type(m.base) ~= "number" or type(m.d) ~= "table" then return end
  self.their_ids = self.their_ids or {}
  local ids = self.their_ids[from] or {}
  self.their_ids[from] = ids
  if type(m.scope) == "string" then ids[m.i] = m.scope end
  m.scope = ids[m.i]
  if not m.scope then                              -- (its name never came: start over, it comes with it)
    self.stats.naks = self.stats.naks + 1
    self:_send(from, { t = "nak", i = m.i })
    return
  end
  if not self.accept(from, m.scope) or self.owned[m.scope] then
    self.stats.rejected = self.stats.rejected + 1
    return
  end
  self:_clock(from, m.at)
  local key = from .. "|" .. m.scope
  local s = self.streams[key]
  if not s then
    s = { last = 0, snaps = { [0] = empty_of(m.scope) }, from = from, scope = m.scope }
    self.streams[key] = s
  end
  s.i = m.i

  if m.seq <= s.last then                       -- old or duplicate (acknowledged again: the clock says s.last)
    self.stats.ignored = self.stats.ignored + 1
    return
  end
  local base = s.snaps[m.base]
  if not base then                              -- can't rebuild: ask for a restart
    self.stats.naks = self.stats.naks + 1
    self:_send(from, { t = "nak", i = m.i })
    return
  end

  -- rebuild the sender's snapshot: base + delta
  local ok, full = pcall(net.apply, base, m.d, root_of(m.scope))
  if not ok then
    self.stats.rejected = self.stats.rejected + 1
    return
  end

  -- apply: the scope in our world matches it exactly (predicted, interpolated
  -- or driven by our inputs: enforce takes it from there)
  local root = full.nodes[root_of(m.scope)]
  local r = root and root.replicate
  if not (type(r) == "table" and (r.predict or r.interp or (self.me ~= nil and r.input == self.me))) then
    local ok2 = self.world:put(full, "/")
    if not ok2 then self.stats.rejected = self.stats.rejected + 1 return end
  end
  s.snaps[m.seq], s.last = full, m.seq
  if type(m.ack) == "number" then s.acks = s.acks or {}; s.acks[m.seq] = m.ack end   -- (our last command in it)
  s.dec, s.dec_seq = full, m.seq
  s.tag = r
  do                                               -- (the last 2 s, by their time: interpolation, lag compensation)
    local at, h = tonumber(m.at) or self.now, s.hist or {}
    s.hist = h
    if not h[#h] or at > h[#h].at then h[#h + 1] = { at = at, seq = m.seq, nodes = full.nodes } end
    while #h > 2 and h[1].at < at - 2 do table.remove(h, 1) end
  end
  for q in pairs(s.snaps) do if q ~= 0 and q < m.seq - KEEP then s.snaps[q] = nil; if s.acks then s.acks[q] = nil end end end
  self.stats.applied = self.stats.applied + 1     -- (acknowledged with our next clock message)
end

function Replica:_on_ack(from, m)
  local o = self.owned[m.scope]
  if not o or o.acked[from] == nil or type(m.seq) ~= "number" then return end
  if m.seq > o.acked[from] and o.history[m.seq] then o.acked[from] = m.seq end
end

function Replica:_on_nak(from, m)
  local o = self.owned[(self.by_id or {})[m.i] or ""]
  if o and o.acked[from] ~= nil then o.acked[from] = 0 end
end

function Replica:_on_clock(from, m)
  if type(m.at) ~= "number" or type(m.seen) ~= "table" then return end
  for i, seq in pairs(type(m.acks) == "table" and m.acks or {}) do   -- (what it has of ours)
    local scope = (self.by_id or {})[i]
    if scope and type(seq) == "number" then self:_on_ack(from, { scope = scope, seq = seq }) end
  end
  local seen = {}                                  -- (by our scopes' numbers: their names)
  for i, v in pairs(m.seen) do local scope = (self.by_id or {})[i]; if scope and type(v) == "number" then seen[scope] = v end end
  m.seen = seen
  self:_clock(from, m.at)
  self.heard = self.heard or {}
  self.heard[from] = { at = m.at, got = self.now }   -- (echoed back: a round trip, whatever we send)
  if type(m.echo) == "number" and type(m.held) == "number" then
    local r = math.max(0, self.now - m.echo - m.held)
    self.rtts[from] = self.rtts[from] and self.rtts[from] * 0.9 + r * 0.1 or r
    self:_least(from, r)
  end
  local v = self.views[from] or {}
  self.views[from] = v
  if v[#v] and m.at <= v[#v].at then return end    -- (old)
  v[#v + 1] = { at = m.at, seen = m.seen, tick = tonumber(m.tick) }
  if type(m.ack) == "number" and m.ack > (self.cmd_ack[from] or 0) then self.cmd_ack[from] = m.ack end
  if type(m.evack) == "number" and m.evack > (self.ev_acked[from] or 0) then self.ev_acked[from] = m.evack end
  while #v > 2 and v[1].at < m.at - 2 do table.remove(v, 1) end
end

function Replica:receive()
  while true do
    local from, bytes = self.ep:recv()
    if not from then break end
    local ok, list = pcall(function()               -- (one or more messages, one after another; data
      local l = {}                                   -- only: a bad packet is dropped whole)
      for _, x in mp.unpacker(bytes) do l[#l + 1] = x end
      return l
    end)
    for _, m in ipairs(ok and list or {}) do self:_on_message(from, m) end
  end
end
function Replica:_on_message(from, m)
  do
    if type(m) == "table" then
      if m.t == "patch" then self:_on_patch(from, m)
      elseif m.t == "nak" then self:_on_nak(from, m)
      elseif m.t == "clock" then self:_on_clock(from, m)
      elseif m.t == "cmds" then self:_on_cmds(from, m)
      elseif m.t == "events" then self:_on_events(from, m)
      elseif m.t == "gone" and type(m.scope) == "string" then   -- (not for us now: what we had of it goes)
        local s = self.streams[from .. "|" .. m.scope]
        if s then self.world:put(s.snaps[0], "/"); self.streams[from .. "|" .. m.scope] = nil end
        self:_send(from, { t = "gone_ok", scope = m.scope })
      elseif m.t == "gone_ok" and type(m.scope) == "string" then
        local o = self.owned[m.scope]
        if o and o.gone and o.gone[from] == "asked" then o.gone[from], o.acked[from] = "done", 0 end
      end
    end
  end
end

-- outgoing ------------------------------------------------------------------

function Replica:send()
  local live = {}                                  -- the scopes we send: their state now
  for _, scope in ipairs(self.order) do
    local o = self.owned[scope]
    if not o.cmd and not (self.hold and self.hold(scope)) then   -- (input scopes travel as commands)
      local cur = self.world:capture(scope)
      local prev = o.history[o.seq]
      if not same(cur.nodes, prev.nodes) then  -- state changed: new snapshot
        local moved = false                    -- (nodes came or went: sent at once, whatever its rate)
        for p in pairs(cur.nodes) do if prev.nodes[p] == nil then moved = true break end end
        for p in pairs(prev.nodes) do if cur.nodes[p] == nil then moved = true break end end
        if moved then o.moved = o.seq + 1 end
        o.seq = o.seq + 1
        o.history[o.seq] = cur
        o.made = o.made or {}
        o.made[o.seq] = self.now               -- (when: its time, sent with it, every time)
        o.used = o.used or {}
        local u = {}                           -- (and each player's last command in it)
        for from, q in pairs(self.inq) do u[from] = q.used end
        o.used[o.seq] = u
      end
      local rate = self.rate_of and self.rate_of(scope)   -- (its own rate: `replicate = { ..., rate = 2 }`)
      local due = not rate or rate <= 0 or self.now + 1e-9 >= (o.next_at or 0)
      if due and rate and rate > 0 then o.next_at = math.max((o.next_at or 0) + 1 / rate, self.now) end
      live[#live + 1] = { scope = scope, o = o, cur = cur, i = #live + 1, due = due }
    end
  end
  self.stats.bytes = self.stats.bytes or {}
  for _, peer in ipairs(self.peers) do
    local want = {}
    for _, e in ipairs(live) do
      local o = e.o
      o.gone = o.gone or {}
      if self.interest and not self.interest(peer, e.scope) then   -- (not for that player now: it drops it)
        if o.gone[peer] ~= "done" then self:_send(peer, { t = "gone", scope = e.scope }); o.gone[peer] = "asked" end
      else
        if o.gone[peer] then o.gone[peer], o.acked[peer] = nil, 0 end   -- (wanted again: from nothing)
        if o.acked[peer] < o.seq and (e.due or (o.moved or 0) > o.acked[peer]) then want[#want + 1] = e end   -- (nodes that came
        -- or went: sent at once, until it has them)
      end
    end
    for _, e in ipairs(want) do                    -- priorities: each waiting scope gains its priority a send;
      local acc = e.o.acc or {}                    -- the highest go first, as many as the budget lets
      e.o.acc = acc
      acc[peer] = (acc[peer] or 0) + (self.priority and self.priority(e.scope) or 1)
    end
    table.sort(want, function(x, y)
      local ax, ay = x.o.acc[peer], y.o.acc[peer]
      if ax ~= ay then return ax > ay end
      return x.i < y.i
    end)
    local spent = 0
    for _, e in ipairs(want) do
      if self.budget and spent > 0 and spent >= self.budget then break end
      local o, acked = e.o, e.o.acked[peer]
      local d = net.delta(o.history[acked], e.cur, root_of(e.scope))   -- (only the fields that changed)
      local n = self:_send(peer, { t = "patch", i = o.id, scope = acked == 0 and e.scope or nil, base = acked,
                                   seq = o.seq, d = d, at = o.made and o.made[o.seq] or self.now,
                                   ack = o.used and o.used[o.seq] and o.used[o.seq][peer] })
      spent = spent + n
      self.stats.bytes[e.scope] = (self.stats.bytes[e.scope] or 0) + n
      o.acc[peer] = 0
      o.sent = o.sent or {}
      o.sent[o.seq] = o.sent[o.seq] or self.now
    end
  end
  for _, e in ipairs(live) do                      -- forget snapshots nobody needs
    local o, oldest = e.o, e.o.seq
    for _, peer in ipairs(self.peers) do if (o.acked[peer] or 0) < oldest then oldest = o.acked[peer] or 0 end end
    for q in pairs(o.history) do if q ~= 0 and q < oldest then o.history[q] = nil end end
    for q in pairs(o.sent or {}) do if q < oldest then o.sent[q] = nil end end
    for q in pairs(o.made or {}) do if q < oldest then o.made[q] = nil end end
    for q in pairs(o.used or {}) do if q < oldest then o.used[q] = nil end end
  end
  local function r4(x) return x and math.floor(x * 10000 + 0.5) / 10000 end   -- (times to 0.1 ms: shorter to send)
  for _, peer in ipairs(self.peers) do             -- (after the states) our time, and which of theirs we show
    local seen, acks = {}, {}
    for _, s in pairs(self.streams) do
      if s.from == peer and s.i then seen[s.i], acks[s.i] = r4(s.was or s.shows or self:_shown(s)), s.last end
    end
    local q = self.inq[peer]
    local h = self.heard and self.heard[peer]
    self:_send(peer, { t = "clock", at = r4(self.now), seen = seen, acks = acks, tick = self.tick, ack = q and q.used,
                       echo = h and h.at, held = h and r4(self.now - h.got), evack = self.ev_got[peer] })
  end
end

function Replica:update(dt)
  self.now = self.now + (dt or 0)
  self:receive()
  if self:due() then self:send() end
  self:flush()
end
-- bundled: what's waiting for each peer goes as one datagram (MessagePack
-- objects one after another; the endpoint cuts it in pieces if too long)
function Replica:flush()
  for to, q in pairs(self.out or {}) do
    if #q > 0 then self.ep:send(to, table.concat(q)); self.stats.packets = (self.stats.packets or 0) + 1 end
    self.out[to] = nil
  end
end

---------------------------------------------------------------------------
-- peer: a world in a session; replication by `replicate` tags
---------------------------------------------------------------------------

local Peer = {}
Peer.__index = Peer

-- the player owning a `replicate` value: true -> 1 (the host), N -> N,
-- { by = N, predict = ... } -> N
net.owner = ecs.owner
local function player_of(id) return tonumber(tostring(id):match("(%d+)$")) end

-- endpoint ids end in the player number ("p2")
function net.peer(world, endpoint, player)
  local self = setmetatable({ world = world, player = player }, Peer)
  world.peer, world.net = player, self
  self.replica = net.replica(world, endpoint, {
    me = player,
    bundle = true,                                 -- (one datagram a peer an update: config/net.lua bundle = false)
    host = function(id) return player_of(id) == 1 end,   -- (commands go to the host)
    on_event = function(from, name, data) world:deliver(name, data, player_of(from)) end,
    interest = function(id, scope)                 -- (w.net.interest = function(player, node): false, not for them)
      local f = self.interest
      if not f then return true end
      local n = world:node((scope:gsub("/%*%*$", "")))
      return n == nil or f(player_of(id), n) ~= false
    end,
    rate_of = function(scope)                      -- (replicate = { ..., rate = 2 }: what everyone guesses anyway)
      local n = world:node((scope:gsub("/%*%*$", "")))
      local r = n and n.c.replicate
      return type(r) == "table" and tonumber(r.rate) or nil
    end,
    priority = function(scope)                     -- (a node's replicate = { ..., priority = 3 })
      local n = world:node((scope:gsub("/%*%*$", "")))
      local r = n and n.c.replicate
      return type(r) == "table" and tonumber(r.priority) or 1
    end,
    hold = function(scope)                         -- (a node of ours tagged { hold = true }: not now)
      local n = world:node((scope:gsub("/%*%*$", "")))
      local r = n and n.c.replicate
      return type(r) == "table" and r.hold and true or false
    end,
    -- a scope is written by its owner only (one we don't have yet: anyone)
    accept = function(from, scope)
      local n = world:node((scope:gsub("/%*%*$", "")))
      local o = n and net.owner(n.c.replicate, world)
      return o == nil or o == player_of(from)
    end,
  })
  return self
end

function Peer:connect(id) self.replica:connect(id) end
function Peer:disconnect(id) self.replica:disconnect(id) end

-- own the scopes of the nodes tagged as ours (new ones too: each update);
-- the ones that went to another player: not ours to send any more
function Peer:scan()
  local w = self.world
  for _, n in ipairs(w:query("replicate")) do
    local scope = n.path .. "/**"
    local r = n.c.replicate
    if net.owner(r, w) == self.player then self.replica:own(scope, type(r) == "table" and r.cmd and self.player ~= 1)
    elseif self.replica.owned[scope] then self.replica:disown(scope) end
  end
end

function Peer:receive() self.replica:receive() end
function Peer:send()
  self:scan(); self.replica:enforce()
  if self.replica:due() then self.replica:send() end   -- (states at the replica's rate; acks went at once)
end
-- once a tick, after the world's tick: what we send is that tick's, at the
-- time it saw (w.net:now()); then the clock moves on. Our inputs become a
-- command; as the host, the players' next commands go in for the next tick.
function Peer:update(dt)
  local r = self.replica
  self:configure()
  r:record(dt); r:used()
  self:receive()
  r:apply_cmds()
  local every = r.keys and r.keys > 0 and dt and dt > 0 and math.max(1, math.floor(1 / (r.keys * dt) + 0.5)) or 1
  local keys_now = r.tick % every == 0             -- (commands: every tick, or every `keys`-th of a second)
  local states = false                             -- (a player that sends only commands: its clock goes with
  for _, o in pairs(r.owned) do if not o.cmd then states = true break end end   -- them, not in packets of its own)
  if keys_now or states then self:send() else self:scan(); r:enforce() end
  if keys_now then r:_send_cmds() end
  r:_send_events()
  r:flush()                                        -- (bundled: one datagram a peer)
  self:remember()
  r.now = r.now + (dt or 0)
end
-- The game's network settings: /config's `net` component (config/net.lua),
-- read every update, so a system may change them as it plays:
--   rate    = 20    states a second (else the Network menu's send rate)
--   bundle  = true  one datagram a peer an update (false: one a message)
--   keys    = 60    commands a second (a player's keys; at most the tick rate)
--   budget  = nil   bytes of states to a player a send (priorities, 7.1)
--   hz      = 60    the session's fixed ticks a second (read when it starts)
function Peer:configure()                          -- (a setting it doesn't give: as it was, the menu's or a test's)
  local n = self.world.nodes["/config"]
  local c = n and n.c.net
  if type(c) ~= "table" then return end
  local r = self.replica
  if c.rate ~= nil and not self.rate_override then r.rate = tonumber(c.rate) end   -- (the Network menu's send rate, when set, wins: testing)
  if c.bundle ~= nil then r.bundle = c.bundle ~= false end
  if c.keys ~= nil then r.keys = tonumber(c.keys) end
  if c.budget ~= nil then r.budget = tonumber(c.budget) end
end
-- the host: the nodes other players' commands drive, by the command they
-- ran on (w.net:as_seen judges by them: lag compensation), 2 s of them
function Peer:remember()
  local r = self.replica
  if not next(r.inq) then return end
  for _, n in ipairs(self.world:query("replicate")) do
    local t = n.c.replicate
    if type(t) == "table" and t.input and t.input ~= self.player and net.owner(t, self.world) == self.player then
      local from
      for id in pairs(r.inq) do if player_of(id) == t.input then from = id end end
      local q = from and r.inq[from]
      if q and q.used then
        local p = r.past[n.path] or { list = {} }
        r.past[n.path], p.from = p, from
        local l = p.list
        if not l[#l] or l[#l].seq ~= q.used then l[#l + 1] = { seq = q.used, c = copy(n.c) } end
        while #l > 120 do table.remove(l, 1) end
      end
    end
  end
end
function Peer:rtt(id) return self.replica:rtt(id) end

-- for the game's systems (w.net, in a session): our clock, and lag
-- compensation (see the top: Replica:as_seen, Replica:seen)
function Peer:now() return self.replica.now end
function Peer:seen(player, ours)
  for _, id in ipairs(self.replica.peers) do
    if player_of(id) == player then return self.replica:seen(id, ours) end
  end
end
function Peer:as_seen(path, t, ours) return self.replica:as_seen(path, t, ours) end
function Peer:event(name, data) self.replica:event(name, data) end   -- (w:event, on the host: to everyone)

return net

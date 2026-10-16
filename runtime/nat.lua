-- nat.lua - getting through home routers (NAT traversal) for online play,
-- without a server of our own: a privileged node (an admin, any node with a
-- public address) runs the introducer; players behind routers meet through it.
--
--   introducer   knows each host's room by name, tells anyone who asks the
--                address it sees them at (what's-my-address: STUN without
--                STUN), and introduces a joiner to a host: each gets the
--                other's candidates (the public address first, then the
--                ones on its own network) and a relay to fall back on.
--   hole punch   both sides send to every candidate at once, a few times a
--                second: their routers see traffic going out to the other,
--                so the other's comes in. The first answer is the path (on
--                the same network: a local address wins).
--   prediction   a symmetric router gives each destination a new port, often
--                the next one: each player also asks the introducer's two
--                probe ports (its port + 1, + 2) what they see, one right
--                after the other; two ports a step apart (1, 2...) and the
--                other side punches the next dozen ports in that step.
--   relay        when no path opens in a few seconds (a symmetric router that
--                picks ports at random, both sides symmetric, a firewall), the
--                introducer forwards between them on a port of its own (a
--                TURN-like relay: the last resort).
--
-- One socket from the introduction to the game: a router's opening is for
-- that port (SimpleMatchmaker's lesson, docs/ROADMAP.md). The messages are
-- net.udp control messages ({ t = "nat", op = ... }, ecs.encode'd); the
-- relay forwards whole datagrams, so the game's own (net.udp) pass as they are.
--
--   local I = nat.introducer(sock, open)     -- open(port) -> a socket (its relays)
--   I:tick(dt)                               -- every frame / tick
--   local c = nat.client(ep, intro_host, intro_port, { lan = { { host, port } } })
--                                             -- intro_port: a list (net.ports("replay:introducer")): whichever answers
--   c:register("room")                        -- (a host) known by that name
--   c:meet("room", function(host, port, how) end)   -- (a joiner) -> the host's address; how: "direct" | "relay"
--   c.on_intro = function(id, host, port, how) end  -- (a host) someone came in that way
--   c:tick(dt);  c.public: { host, port } as the introducer sees us
--
-- A router that maps a port when asked (runtime/portmap.lua: PCP, NAT-PMP,
-- UPnP) is one more candidate: c:add_candidate(host, port).
--
-- nat.inet{}: a pretend internet with routers of each kind, for tests:
--   local inet = nat.inet{ latency = 0.02 }
--   inet:router("home", { kind = "port", ip = "203.0.113.7" })   -- full | restricted | port | symmetric | random
--   local s = inet:socket("192.168.1.10", 0, "home")  -- (behind it; no router: a public address)
--   s:send(host, port, bytes); bytes, host, port = s:recv(); inet:advance(dt)
local ok_ecs, ecs = pcall(require, "ecs")
local net = require("net")
local nat = {}

local function enc(m) return assert(ecs.encode(m)) end
local function dec(b)
  local ok, m = pcall(ecs.decode, b)
  return ok and type(m) == "table" and m or nil
end
local function key(h, p) return tostring(h) .. "|" .. tostring(p) end
local E_ok, E = pcall(require, "ed25519")          -- (signatures: a peer ID is its public key's hash, runtime/ed25519.lua)
nat.signing = E_ok

---------------------------------------------------------------------------
-- peer IDs: "TJHJDJX", a name for a node instead of its address. Crockford
-- base32 (no I, L, O, U: typed or read aloud without mistakes; case and
-- I/L/O typos forgiven), 6 random characters (30 bits) and a check one
-- (weighted sum mod 31: any one wrong character, two swapped ones: caught).
-- nat.id_of(public key): the ID a key gives (its SHA-512's first 30 bits),
-- so only the one with the key behind an ID can prove it (a signature).
---------------------------------------------------------------------------
local B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local function b32v(ch) local i = B32:find(ch, 1, true); return i and i - 1 end
local function id_sum(six) local t = 0; for i = 1, 6 do t = t + i * b32v(six:sub(i, i)) end; return t % 31 end
function nat.id_norm(s)                            -- "tjh-jdjx", "TJHJDJX " -> "TJHJDJX" | nil (not one)
  s = tostring(s or ""):upper():gsub("[%s%-]", ""):gsub("[IL]", "1"):gsub("O", "0")
  if #s ~= 7 or s:find("[^" .. B32 .. "]") then return nil end
  if B32:sub(id_sum(s:sub(1, 6)) + 1, id_sum(s:sub(1, 6)) + 1) ~= s:sub(7, 7) then return nil end
  return s
end
function nat.id_of(pk)                             -- a public key (32 bytes) -> its ID
  local h = E.sha512(pk)
  local v = ((h:byte(1) * 256 + h:byte(2)) * 256 + h:byte(3)) * 256 + h:byte(4)   -- (32 bits: the first 30 used)
  local six = ""
  for i = 1, 6 do
    local c = math.floor(v / 2 ^ (32 - 5 * i)) % 32
    six = six .. B32:sub(c + 1, c + 1)
  end
  return six .. B32:sub(id_sum(six) + 1, id_sum(six) + 1)
end
-- what's signed to show a key: "replay <what> <ID> <challenge>" (what: reg, at
-- the introducer; here, an answer to a seek nearby); a challenge never repeats
function nat.proof_text(what, id, challenge) return "replay " .. what .. " " .. tostring(id) .. " " .. tostring(challenge) end
function nat.sign(seed, what, id, challenge) return E.hex(E.sign(seed, nat.proof_text(what, id, challenge))) end
function nat.proves(pk_hex, sig_hex, what, id, challenge)   -- the key's ID is that one, and it signed this
  if not E_ok or type(pk_hex) ~= "string" or type(sig_hex) ~= "string" or #pk_hex ~= 64 or #sig_hex ~= 128 then return false end
  local pk = E.unhex(pk_hex)
  if nat.id_of(pk) ~= id then return false end
  return E.verify(pk, nat.proof_text(what, id, challenge), E.unhex(sig_hex))
end
function nat.id_new(rand)                          -- rand() -> [0, 1) (math.random)  (an ID without a key: tests)
  rand = rand or math.random
  local six = ""
  for _ = 1, 6 do local v = math.floor(rand() * 32) % 32; six = six .. B32:sub(v + 1, v + 1) end
  return six .. B32:sub(id_sum(six) + 1, id_sum(six) + 1)
end

---------------------------------------------------------------------------
-- the introducer
---------------------------------------------------------------------------
local Intro = {}
Intro.__index = Intro

-- sock: its public socket; open(port): a new socket (for relays; nil: no relays)
-- (its probe ports, for prediction: opts.probes = { s1, s2 }, else open(its port + 1), open(its port + 2))
function nat.introducer(sock, open, opts)
  opts = opts or {}
  local I = setmetatable({ ep = net.udp(sock, "intro"), open = open, rooms = {}, relays = {}, probes = {}, t = 0, nonce = 0,
                           ch = {}, ch_n = 0, proven = {},
                           room_life = opts.room_life or 30, relay_life = opts.relay_life or 60, predict = opts.predict or 12,
                           stats = { intros = 0, relayed = 0, predicted = 0 } }, Intro)
  I.ep.on_control = function(from, bytes, host, port) I:_on(from, bytes, host, port) end
  I.peps = {}
  for i = 1, 2 do
    local ps = opts.probes and opts.probes[i] or (not opts.probes and open and sock.port and open(sock:port() + i))
    if ps then
      local pep = net.udp(ps, "intro")
      I.peps[i] = pep
      pep.on_control = function(from, bytes, host, port)
        local m = dec(bytes)
        if m and m.t == "nat" and m.op == "probe" and type(m.tok) == "string" then
          local pr = I.probes[m.tok] or {}
          pr[i], pr.host, pr.seen = port, host, I.t
          I.probes[m.tok] = pr
          pep:control(from, enc({ t = "nat", op = "you2", host = host, port = port, i = i }), host, port)
        end
      end
    end
  end
  return I
end
function Intro:close()
  if self.ep.sock.close then self.ep.sock:close() end
  for _, p in pairs(self.peps) do if p.sock.close then p.sock:close() end end
  for _, r in ipairs(self.relays) do if r.sock.close then r.sock:close() end end
end
-- a side's candidates: its public address, the predicted ones (a symmetric
-- router counting up: the next ports in its step), the ones it sent
function Intro:_cands(host, port, tok, extra)
  local c = { { host, port } }
  local pr = tok and self.probes[tok]
  if pr and pr.host == host and (pr[1] or pr[2]) then
    local a, b = pr[1], pr[2]                       -- (two fresh mappings, one right after the other: the step)
    if not (a and b) then a, b = port, a or b end   -- (one probe port only: our port and it)
    local step, last = math.abs(b - a), math.max(a, b, port)   -- (counting up: the usual way)
    if step ~= 0 and step <= 8 then
      for i = 1, self.predict do c[#c + 1] = { host, last + step * i } end
      self.stats.predicted = self.stats.predicted + 1
    end
  end
  for _, e in ipairs(type(extra) == "table" and extra or {}) do c[#c + 1] = e end
  return c
end
function Intro:_send(to, m, host, port) self.ep:control(to, enc(m), host, port) end
function Intro:_on(from, bytes, host, port)
  local m = dec(bytes)
  if not m or m.t ~= "nat" then return end
  local k = key(host, port)
  local ch = self.ch[k]                              -- (this address's challenge: what a peer ID's owner signs to register it)
  if not ch then self.ch_n = self.ch_n + 1; ch = string.format("%s:%s:%d", tostring(host), tostring(port), self.ch_n); self.ch[k] = ch end
  if m.op == "who" then
    self:_send(from, { t = "nat", op = "you", host = host, port = port, ch = ch }, host, port)
  elseif m.op == "reg" and type(m.room) == "string" then   -- a host: known by its room's name (again every few seconds)
    local pk
    if nat.id_norm(m.room) == m.room and E_ok then   -- (a peer ID: only its key's owner, signing this address's challenge)
      local pkey = k .. "|" .. m.room .. "|" .. tostring(m.pk)
      if not self.proven[pkey] then
        if not m.sig then self:_send(from, { t = "nat", op = "you", host = host, port = port, ch = ch }, host, port) return end
        if not nat.proves(m.pk, m.sig, "reg", m.room, ch) then
          self:_send(from, { t = "nat", op = "nope", room = m.room, why = "not " .. m.room .. ": no proof (its key)" }, host, port)
          return
        end
        self.proven[pkey] = true
      end
      pk = m.pk
    end
    self.rooms[m.room] = { host = host, port = port, lan = type(m.lan) == "table" and m.lan or {}, id = from, seen = self.t, tok = m.tok, pk = pk }
    self:_send(from, { t = "nat", op = "you", host = host, port = port, ch = ch }, host, port)
  elseif m.op == "meet" and type(m.room) == "string" then
    local r = self.rooms[m.room]
    if not r then self:_send(from, { t = "nat", op = "nope", room = m.room, why = "no room " .. m.room }, host, port) return end
    if m.tok and not (self.probes[m.tok] and self.probes[m.tok][#self.peps]) and #self.peps > 0 and (tonumber(m.n) or 9) < 3 then return end   -- (its probes first, if they come: it asks again)
    self.nonce = self.nonce + 1
    local relay
    if self.open then                               -- (a relay ready, in case: a socket that forwards between the two)
      local s = self.open(0)
      if s then
        relay = { sock = s, a = { host = host, port = port }, b = { host = r.host, port = r.port }, seen = self.t }
        self.relays[#self.relays + 1] = relay
      end
    end
    local rport = relay and relay.sock:port() or nil
    local jc = self:_cands(host, port, m.tok, m.lan)
    local hc = self:_cands(r.host, r.port, r.tok, r.lan)
    self:_send(from, { t = "nat", op = "intro", room = m.room, peer = r.id, cands = hc, nonce = self.nonce, relay = rport, you = { host, port }, pk = r.pk }, host, port)
    self:_send(r.id, { t = "nat", op = "intro", room = m.room, peer = from, cands = jc, nonce = self.nonce, relay = rport }, r.host, r.port)
    self.stats.intros = self.stats.intros + 1
  end
end
function Intro:tick(dt)
  self.t = self.t + dt
  self.ep:poll()
  for _, p in pairs(self.peps) do p:poll() end
  for name, r in pairs(self.rooms) do if self.t - r.seen > self.room_life then self.rooms[name] = nil end end
  for tok, p in pairs(self.probes) do if self.t - p.seen > self.room_life then self.probes[tok] = nil end end
  for i = #self.relays, 1, -1 do
    local R = self.relays[i]
    while true do                                    -- (a datagram from one side: to the other, as it is)
      local bytes, host, port = R.sock:recv()
      if not bytes then break end
      local function is(side) return side.host == host and side.port == port end
      local function same_ip(side) return side.host == host end
      local to
      if is(R.a) then to = R.b elseif is(R.b) then to = R.a
      elseif same_ip(R.a) then R.a.port = port; to = R.b   -- (a symmetric router: another port toward the relay)
      elseif same_ip(R.b) then R.b.port = port; to = R.a end
      if to then R.sock:send(to.host, to.port, bytes); R.seen = self.t; self.stats.relayed = self.stats.relayed + 1 end
    end
    if self.t - R.seen > self.relay_life then
      if R.sock.close then R.sock:close() end
      table.remove(self.relays, i)
    end
  end
end

---------------------------------------------------------------------------
-- a player's side: register (a host), meet (a joiner), punch, fall back
---------------------------------------------------------------------------
local Client = {}
Client.__index = Client

-- ep: the game's net.udp endpoint (its socket: the one the game plays on)
local tok_n = 0
function nat.client(ep, intro_host, intro_port, opts)
  opts = opts or {}
  tok_n = tok_n + 1
  local tok = string.format("%x%x%x", math.floor((os.time() % 65536)), math.floor(os.clock() * 1e6) % 65536, tok_n) .. (tostring({}):match("(%x+)$") or "")
  local list = type(intro_port) == "table" and intro_port or nil
  local c = setmetatable({ ep = ep, ih = intro_host, ip = not list and intro_port or nil, iports = list, next_who = 0, lan = opts.lan or {}, t = 0, tok = tok,
                           next_probe = 0,
                           punch_every = opts.punch_every or 0.2, give_up = opts.give_up or 3,
                           tries = {}, public = nil, room = nil, next_reg = 0,
                           seed = opts.seed, pk = opts.pk }, Client)   -- (seed, pk: our key, to register our peer ID: hex pk)
  local prev = ep.on_control
  ep.on_control = function(from, bytes, host, port)
    local m = dec(bytes)
    if m and m.t == "nat" then c:_on(from, m, host, port)
    elseif prev then prev(from, bytes, host, port) end
  end
  return c
end
function Client:_send(to, m, host, port) self.ep:control(to, enc(m), host, port) end
function Client:who() if self.ip then self:_send("intro", { t = "nat", op = "who" }, self.ih, self.ip) end end
function Client:register(room)                    -- (again: known by that name too, e.g. a room and our peer ID)
  self.rooms = self.rooms or {}
  for _, r in ipairs(self.rooms) do if r == room then return end end
  self.rooms[#self.rooms + 1] = room
  self.room = self.room or room
  self.next_reg = math.max(self.t, 0.1)
end
function Client:meet(room, on_path)
  self.meeting = { room = room, on_path = on_path, next = self.t + 0.1, asked = 0 }   -- (the probe goes first)
end
function Client:add_candidate(host, port)          -- (a port the router opened for us: runtime/portmap.lua)
  for _, l in ipairs(self.lan) do if l[1] == host and l[2] == port then return end end
  table.insert(self.lan, 1, { host, port })
  if self.room then self.next_reg = self.t end      -- (registered again at once)
end
-- what our router does, from the two ports the introducer saw:
-- "same" (one port for every destination: punching works), "step N" (a new
-- port a destination, N apart: predicted), "random" (relayed), nil (not yet)
function Client:mapping()
  local a, b = self.public2, self.public3
  if not (a and b) then a, b = self.public, self.public2 end
  if not (a and b) then return nil end
  local d = b[2] - a[2]
  if d == 0 then return "same" end
  if math.abs(d) <= 8 then return "step " .. math.abs(d) end
  return "random"
end
function Client:_on(from, m, host, port)
  if m.op == "you" then
    self.public = { m.host, m.port }
    if type(m.ch) == "string" and m.ch ~= self.ch then   -- (a new challenge: our peer ID registered again, signed, now)
      self.ch, self.sigs = m.ch, {}
      if self.room then self.next_reg = self.t end
    end
    if not self.ip and host == self.ih then self.ip = port end   -- (the introducer's port: the one that answered)
  elseif m.op == "you2" then
    if tonumber(m.i) == 2 then self.public3 = { m.host, m.port } else self.public2 = { m.host, m.port } end
  elseif m.op == "nope" then self.failed = m.why; if self.meeting then self.meeting.failed = m.why end
  elseif m.op == "intro" and tonumber(m.nonce) then
    if m.you then self.public = m.you end
    local try = { nonce = m.nonce, peer = m.peer, cands = m.cands or {}, relay = m.relay, t0 = self.t, next = 0,
                  joiner = self.meeting ~= nil and self.meeting.room == m.room }
    self.tries[m.nonce] = try
    if try.relay then self:_send("*", { t = "nat", op = "open" }, self.ih, try.relay) end   -- (our router: open toward the relay too)
    if try.joiner then self.meeting.got = true end
  elseif m.op == "punch" and tonumber(m.nonce) then
    self:_send("*", { t = "nat", op = "punched", nonce = m.nonce }, host, port)
    self:_found(m.nonce, host, port)
  elseif m.op == "punched" and tonumber(m.nonce) then
    self:_found(m.nonce, host, port)
  end
end
function Client:_found(nonce, host, port, how)
  local try = self.tries[nonce]
  if not try or try.done then return end
  try.done = { host, port, how or "direct" }
  if try.joiner and self.meeting and self.meeting.on_path then self.meeting.on_path(host, port, how or "direct", try.peer) end
  if not try.joiner and self.on_intro then self.on_intro(try.peer, host, port, how or "direct") end
end
function Client:tick(dt)
  self.t = self.t + dt
  if not self.ip then                                -- (which of its ports: ask them all, the first answer)
    if self.iports and self.t >= self.next_who then
      self.next_who = self.t + 0.5
      for _, p in ipairs(self.iports) do self:_send("intro", { t = "nat", op = "who" }, self.ih, p) end
      if self.t > 5 and self.meeting and not self.meeting.failed then self.meeting.failed = "no introducer at " .. tostring(self.ih) end
    end
    self.ep:poll()
    return
  end
  local want_probe = self.room or (self.meeting and not self.meeting.got and not self.meeting.failed)
  if want_probe and self.t >= self.next_probe then   -- (the introducer's second port: our router's step)
    self.next_probe = self.t + 5
    self:_send("intro", { t = "nat", op = "probe", tok = self.tok }, self.ih, self.ip + 1)   -- (one right after the other)
    self:_send("intro", { t = "nat", op = "probe", tok = self.tok }, self.ih, self.ip + 2)
  end
  if self.room and self.t >= self.next_reg then      -- (a host: known by its room; keeps its router's opening open)
    self.next_reg = self.t + 5
    local lan = {}
    for _, l in ipairs(self.lan) do lan[#lan + 1] = l end
    for _, room in ipairs(self.rooms) do
      local m = { t = "nat", op = "reg", room = room, lan = lan, tok = self.tok }
      if self.seed and self.ch and nat.id_norm(room) == room and E_ok then   -- (our peer ID: proven with our key)
        self.sigs = self.sigs or {}
        self.sigs[room] = self.sigs[room] or nat.sign(self.seed, "reg", room, self.ch)
        m.pk, m.sig = self.pk, self.sigs[room]
      end
      self:_send("intro", m, self.ih, self.ip)
    end
  end
  local mt = self.meeting
  if mt and not mt.got and not mt.failed and self.t >= mt.next then   -- (a joiner: until introduced)
    mt.next = self.t + 0.5
    mt.asked = mt.asked + 1
    self:_send("intro", { t = "nat", op = "meet", room = mt.room, lan = self.lan, tok = self.tok, n = mt.asked }, self.ih, self.ip)
    if mt.asked > 10 then mt.failed = "the introducer doesn't answer" end
  end
  for nonce, try in pairs(self.tries) do
    if not try.done then
      if self.t - try.t0 > self.give_up then         -- no path: the relay, if there's one
        if try.relay then self:_found(nonce, self.ih, try.relay, "relay")
        else try.done = { nil, nil, "failed" } end
      elseif self.t >= try.next then
        try.next = self.t + self.punch_every
        for _, c in ipairs(try.cands) do self:_send("*", { t = "nat", op = "punch", nonce = nonce }, c[1], c[2]) end
      end
    elseif try.done[3] == "direct" and not try.joiner and self.t - try.t0 < self.give_up + 2 and self.t >= try.next then
      try.next = self.t + 0.5                         -- (a host: a little more, so the joiner's side sees ours too)
      self:_send("*", { t = "nat", op = "punch", nonce = nonce }, try.done[1], try.done[2])
    end
  end
  self.ep:poll()
end

---------------------------------------------------------------------------
-- a pretend internet: sockets, and routers that translate (NAT), for tests
---------------------------------------------------------------------------
local Inet = {}
Inet.__index = Inet
local Sock = {}
Sock.__index = Sock

-- router kinds (RFC 4787's, roughly):
--   full        one public port per inside socket; anyone may send to it
--   restricted  ...only hosts it has sent to (any of their ports)
--   port        ...only host:ports it has sent to
--   symmetric   a new public port per destination (the next one); only that destination answers
--   random      symmetric, the ports picked at random
-- R.static[pub] = inside socket: a port the router opened when asked (anyone may send)
function nat.inet(opts)
  opts = opts or {}
  return setmetatable({ latency = opts.latency or 0.02, routers = {}, socks = {}, flight = {}, t = 0, next_port = 40000,
                        loss = opts.loss or 0, rand = net.rng(opts.seed or 7), stats = { sent = 0, dropped = 0 } }, Inet)
end
function Inet:router(name, r)
  self.routers[name] = { name = name, kind = r.kind or "port", ip = r.ip, map = {}, back = {}, perm = {}, next = 50000, static = {} }
  return self.routers[name]
end
function Inet:socket(ip, port, behind)
  if not port or port == 0 then self.next_port = self.next_port + 1; port = self.next_port end
  local s = setmetatable({ inet = self, ip = ip, p = port, behind = behind and self.routers[behind], inbox = {} }, Sock)
  self.socks[key(ip, port)] = s
  return s
end
function Sock:port() return self.p end
function Sock:close() self.inet.socks[key(self.ip, self.p)] = nil end
function Sock:recv()
  local m = table.remove(self.inbox, 1)
  if m then return m[1], m[2], m[3] end
end
function Sock:send(host, port, bytes)
  local inet = self.inet
  inet.stats.sent = inet.stats.sent + 1
  local R = self.behind
  local local_dst = inet.socks[key(host, port)]
  if R and local_dst and local_dst.behind == R then   -- (the same network: straight there)
    return inet:_fly(local_dst, bytes, self.ip, self.p)
  end
  local sh, sp = self.ip, self.p
  if R then                                          -- out through our router: its public address, a port it maps
    local sym = R.kind == "symmetric" or R.kind == "random"
    local mk = sym and key(self.ip .. ":" .. self.p, host .. ":" .. port) or key(self.ip, self.p)
    local pub = R.map[mk]
    for sp2, inside in pairs(R.static) do if inside == self then pub = sp2 end end   -- (an opened port: ours, every destination)
    if not pub then
      if R.kind == "random" then repeat pub = 1024 + math.floor(inet.rand() * 64000) until not R.back[pub]
      else R.next = R.next + 1; pub = R.next end
      R.map[mk] = pub; R.back[pub] = self
    end
    R.perm[key(pub, host)] = true                    -- (who may answer: restricted / port / symmetric)
    R.perm[key(pub, host .. ":" .. port)] = true
    sh, sp = R.ip, pub
  end
  for _, T in pairs(inet.routers) do                 -- in through the destination's router
    if T.ip == host then
      local inside = T.back[port]
      if not inside then inet.stats.dropped = inet.stats.dropped + 1 return true end
      local okp = T.kind == "full" or T.static[port] or (T.kind == "restricted" and T.perm[key(port, sh)]) or T.perm[key(port, sh .. ":" .. sp)]
      if not okp or T == R then inet.stats.dropped = inet.stats.dropped + 1 return true end   -- (no hairpin: our own public address)
      return inet:_fly(inside, bytes, sh, sp)
    end
  end
  local dst = inet.socks[key(host, port)]
  if not dst or dst.behind then inet.stats.dropped = inet.stats.dropped + 1 return true end   -- (a private address from outside: nowhere)
  return inet:_fly(dst, bytes, sh, sp)
end
function Inet:_fly(dst, bytes, sh, sp)
  if self.rand() < self.loss then self.stats.dropped = self.stats.dropped + 1 return true end
  self.flight[#self.flight + 1] = { at = self.t + self.latency, dst = dst, m = { bytes, sh, sp } }
  return true
end
function Inet:advance(dt)
  self.t = self.t + dt
  local keep = {}
  for _, f in ipairs(self.flight) do
    if f.at <= self.t then if self.socks[key(f.dst.ip, f.dst.p)] then f.dst.inbox[#f.dst.inbox + 1] = f.m end
    else keep[#keep + 1] = f end
  end
  self.flight = keep
end

return nat

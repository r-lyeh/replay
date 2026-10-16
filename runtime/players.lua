-- players.lua - the Players and Network buttons' Lua (the editor's world VM):
-- players 1..4 of the game over a simulated network (net.sim). replay.c runs
-- it at start (editor/players.h: the C side, the views and buttons).

local ecs, net = require('ecs'), require('net')
local PL = { peers = {} }                          -- peers[k] = { world, peer }; [1]: the host (player 1 or not)
viewer_players = PL
-- the network's quality (the Network button: its bars), game seconds
PL.levels = {
  [0] = { name = 'awful', latency = 0.4, jitter = 0.1, loss = 0.25, dup = 0.05 },
  { name = 'bad', latency = 0.2, jitter = 0.05, loss = 0.1, dup = 0.02 },
  { name = 'fair', latency = 0.1, jitter = 0.025, loss = 0.03, dup = 0 },
  { name = 'good', latency = 0.05, jitter = 0.01, loss = 0.01, dup = 0 },
  { name = 'local', latency = 0.005, jitter = 0.001, loss = 0, dup = 0 },   -- (exactly 100%: no network at all)
}
-- q: 0 (awful) .. 1 (local); between two of them, their numbers blend
PL.q = 1                                          -- (100%: no network, see sync)
local function params(q)
  local x = (q or PL.q) * 4
  local i = math.min(3, math.floor(x))
  local a, b, f = PL.levels[i], PL.levels[i + 1], x - i
  local p = {}
  for _, k in ipairs({ 'latency', 'jitter', 'loss', 'dup' }) do p[k] = a[k] + (b[k] - a[k]) * f end
  p.name = f < 1e-6 and a.name or f > 1 - 1e-6 and b.name or nil
  return p
end
-- The Network button's menu (right-click), this session only:
--   ghosts   each view also shows, faintly, what the owners sent last of
--            what it predicts (the truth its guess is corrected towards)
--   rate     states sent this many times a second (acks: at once)
--   links    a player's own line: nil as everyone's, 0..1 a quality, 'cut'
PL.ghosts, PL.rate, PL.links = true, 20, {}
local function id(k) return 'p' .. k end
local function apply(sim)
  for k, v in pairs(params()) do if k ~= 'name' then sim[k] = v end end
  for k = 1, 4 do
    local l = PL.links[k]
    sim:link(id(k), l == 'cut' and { cut = true } or type(l) == 'number' and params(l) or nil)
  end
end
local function apply_rate()                      -- (the menu's rate, once chosen, beats the game's config/net.lua)
  for k = 1, 4 do local p = PL.peers[k]; if p then p.peer.replica.rate = PL.rate; p.peer.rate_override = PL.rate_set and PL.rate or nil end end
  if PL.online and PL.online.peer then PL.online.peer.replica.rate = PL.rate; PL.online.peer.rate_override = PL.rate_set and PL.rate or nil end
end
function viewer_players_net(q) PL.q = q; if PL.sim then apply(PL.sim) end end
function viewer_players_rate(hz) PL.rate, PL.rate_set = hz, true; apply_rate() end
function viewer_players_ghosts(on) PL.ghosts = on and true or false end
function viewer_players_link(k, v)                 -- v: -1 as everyone's, -2 cut, else 0..1
  PL.links[k] = v == -2 and 'cut' or (v >= 0 and v) or nil
  if PL.sim then apply(PL.sim) end
end
-- what the network carries now: bytes a second (over the last second or so)
function viewer_players_bandwidth()
  local sim = PL.sim
  if not sim and PL.online then                    -- (online: what this editor sends, by its clock)
    sim = { time = udp and udp.clock and udp.clock() or 0, stats = PL.online.ep.stats }
  end
  if not sim then return 0 end
  local t, b = sim.time, sim.stats.bytes
  PL.bw = PL.bw or { t = 0, b = 0, rate = 0 }   -- (from the network's start)
  if t - PL.bw.t >= 0.5 then
    PL.bw.rate = (b - PL.bw.b) / (t - PL.bw.t)
    PL.bw.t, PL.bw.b = t, b
  end
  return PL.bw.rate
end
-- the ghost of what player k's view predicts or interpolates: a world
-- holding the last state each owner sent of those nodes (rebuilt when one
-- arrives): how far off a guess is, how late an interpolated node shows
function viewer_players_ghost(k)
  if not (PL.sim and PL.ghosts) then return nil end
  local p = PL.peers[k == 0 and 1 or k]
  if not p then return nil end
  local list, keys = {}, {}
  for key, s in pairs(p.peer.replica.streams) do
    local root = s.last > 0 and s.dec and s.dec.nodes and s.dec.nodes[(s.scope:gsub('/%*%*$', ''))]
    local r = root and root.replicate
    if type(r) == 'table' and (r.predict or r.interp) then list[#list + 1] = s; keys[#keys + 1] = key .. '=' .. s.last end
  end
  if #list == 0 then return nil end
  table.sort(keys)
  local key = table.concat(keys, ',')
  if p.ghost_key ~= key then
    local g = ecs.world()
    g.silent = true
    for _, s in ipairs(list) do g:put(s.snaps[s.last], '/') end
    p.ghost, p.ghost_key = g, key
  end
  return p.ghost
end
function viewer_players_net_info()                 -- name (nil between two), ms, jitter ms, loss %, dup %
  local l = params()
  return l.name, l.latency * 1000, l.jitter * 1000, l.loss * 100, l.dup * 100
end
local function peer_dd(k)                          -- a peer's dd: its messages, said by it; no drawing
  local real, t = dd, {}
  for _, f in ipairs({ 'log', 'warn', 'error' }) do
    t[f] = function(...) if real and real[f] then real[f]('P' .. k .. ':', ...) end end
  end
  return setmetatable(t, { __index = function() return function() end end })
end
local function as_peer(k, fn, ...)               -- not the editor's probe, profiler or overlay
  local g, b, pr = ecs.code_globals.dd, ecs.on_build, ecs.profiler
  ecs.code_globals.dd, ecs.on_build, ecs.profiler = PL.peers[k].dd, nil, nil
  local ok, err = pcall(fn, ...)
  ecs.code_globals.dd, ecs.on_build, ecs.profiler = g, b, pr
  if not ok and PL.peers[k].err ~= err then PL.peers[k].err = err; if dd then dd.error('P' .. k .. ': ' .. tostring(err)) end end
end
local function join(k)                           -- a copy of the host's world, connected to the host (a star)
  local ok, blob = PL.host:save('/**')
  if not ok then error(blob, 0) end
  local w = ecs.world()
  assert(w:load(blob, '/'))
  w.code = PL.host.code
  w.silent = true                                  -- (its sounds: the host's world plays them, once)
  local p = net.peer(w, PL.sim:endpoint(id(k)), k)
  PL.peers[1].peer:connect(id(k)); p:connect(id(1))
  p.replica.rate = PL.rate
  p.rate_override = PL.rate_set and PL.rate or nil
  PL.peers[k] = { world = w, peer = p, dd = peer_dd(k) }
end
local function part(k)                           -- gone: nobody sends it anything more
  PL.peers[k] = nil
  for j = 1, 4 do local o = PL.peers[j]; if o then o.peer:disconnect(id(k)) end end
  PL.sim:close(id(k))
end
local function drop_all()
  for k = 4, 2, -1 do if PL.peers[k] then part(k) end end
  if PL.host then PL.host.peer, PL.host.players, PL.host.net = nil, nil, nil end
  PL.peers, PL.sim, PL.host = {}, nil, nil
end
-- every frame while playing: mask = who's in (bit k-1: player k); they
-- join / part to get there; a new host world (a reload, Play) starts them
-- all over. The network is up while anyone but player 1 is in, below
-- 100%: at 100% everyone plays in the host's world (local, no network)
function viewer_players_sync(host, mask)
  if PL.online then                                -- (online: who's in is the session's)
    if PL.online.world ~= host then online_drop() else return end
  end
  if PL.host ~= host then drop_all() end
  PL.host = host
  local set, others = {}, false
  for k = 1, 4 do if math.floor(mask / 2 ^ (k - 1)) % 2 == 1 then set[k] = true; if k > 1 then others = true end end end
  PL.set = set
  if not others or PL.q >= 1 then
    if PL.sim then drop_all(); PL.host = host end
    host.players = set
    return
  end
  if not PL.sim then
    PL.sim = net.sim{ seed = 1 }
    apply(PL.sim)
    PL.peers[1] = { world = host, peer = net.peer(host, PL.sim:endpoint(id(1)), 1) }
    PL.peers[1].peer.replica.rate = PL.rate
    PL.peers[1].peer.rate_override = PL.rate_set and PL.rate or nil
    PL.bw = nil
  end
  for k = 2, 4 do
    if set[k] and not PL.peers[k] then join(k) elseif not set[k] and PL.peers[k] then part(k) end
  end
  for k = 1, 4 do
    local p = PL.peers[k]
    if p then p.world.players = {}; for j in pairs(set) do p.world.players[j] = true end end
  end
end

-- Online: the game played over a real network (net.udp: UDP, a LAN or the
-- internet), one player per editor, no server: one of them hosts (player
-- 1, the world everyone gets when they join, and decides it: classic
-- client / server). The others talk to the host only (a star): their keys
-- go to it, its states come back.
--   host(port)               this editor hosts (port 7777 by default)
--   join("1.2.3.4:7777")     this editor joins: it gets the host's world and
--                            the first free player (2..4); its keys are that player's
--   leave(), online()        stop being online; who's in, where
-- (the console, while playing; or edit <game> --host 7777 / --join 1.2.3.4).
-- Messages beside the replica's (net.udp control, ecs.encode'd):
--   hello { game }      joiner -> host, until welcomed (twice a second)
--   welcome { player, world, players }   host -> joiner (the world: a save of it)
--   full { why }        host -> joiner: no free player
--   roster { players }  host -> everyone, every second: who's in
--   ping {}             host <-> each player, every second: still here (6 s of silence: gone)
--   bye {}              leaving
-- Stop (or Play again) leaves. Everyone needs the same game (its folder):
-- the world travels, the game's other files (assets, modules) don't.
local ONLINE_PORT = 7777                           -- (the old default: still tried when joining without a port)
-- Ports by name (net.ports): a game's ports come from its name, the
-- introducer's from "replay:introducer"; a host takes the first free one,
-- joiners try them all. Nobody types a port (they still can).
local nat_ok, nat = pcall(require, 'nat')
local pm_ok, portmap = pcall(require, 'portmap')
-- a host asks its router to open its port (portmap.lua: PCP, NAT-PMP, UPnP):
-- on by default; portmap(false) in the console, or REPLAY_PORTMAP=0 (the tests)
PL.portmap = os.getenv('REPLAY_PORTMAP') ~= '0'
PL.closing = {}                                    -- (mappings being released: ticked until done)
local function hostport(h, p) return (tostring(h):find(':', 1, true) and ('[' .. h .. ']') or tostring(h)) .. ':' .. tostring(p) end   -- (IPv6: in brackets)
local function game_name() return viewer_game_name and viewer_game_name() or '?' end
local function game_ports() return net.ports('replay:' .. game_name()) end
local function intro_ports() return net.ports('replay:introducer') end
local function in_list(p, list) for _, q in ipairs(list) do if q == p then return true end end return false end
-- "1.2.3.4" when the port is one of the list's (found by name), else "1.2.3.4:30679"
local function addr_of(h, p, list)
  if type(p) == 'table' or (list and in_list(p, list)) then return tostring(h):find(':', 1, true) and ('[' .. h .. ']') or tostring(h) end
  return hostport(h, p)
end
-- the first port of the list that opens (need(p): its neighbours too) -> socket, port | nil, err
local function open_first(list, need)
  for _, p in ipairs(list) do
    local s = udp.open(p)
    if s then
      if not need or need(p) then return s, p end
      s:close()
    end
  end
  return nil, 'its ports are all taken (' .. table.concat(list, ', ') .. ')'
end
-- This computer's network settings: <root>/.network.lua (made on first use):
--   return { key = "<64 hex>", id = "TJHJDJX", introducers = { "1.2.3.4" } }
-- key: our secret key (an Ed25519 seed, runtime/ed25519.lua: keep it to
-- yourself); id: our peer ID, its public key's hash (nat.id_of: others
-- join("TJHJDJX"); written for reading, worked out from the key again);
-- introducers: where a host makes itself known by its ID (proving it: a
-- signature), and where a join by ID looks when nobody nearby has it.
-- REPLAY_PEER_KEY (64 hex) / REPLAY_INTRODUCERS ("a,b"): for tests.
local function net_conf_path()
  local f = package.searchpath and package.searchpath('players', package.path)
  return (f and f:gsub('runtime[/\\]players%.lua$', '') or './') .. '.network.lua'
end
local function net_conf()
  if PL.conf then return PL.conf end
  local c = {}
  local f = io.open(net_conf_path(), 'rb')
  if f then
    local src = f:read('*a'); f:close()
    local fn = (loadstring or load)(src)
    if fn then
      if setfenv then setfenv(fn, {}) end
      local ok, t = pcall(fn)
      if ok and type(t) == 'table' then c = t end
    end
  end
  c.introducers = type(c.introducers) == 'table' and c.introducers or {}
  local fresh = false
  local hex_ok = function(k) return type(k) == 'string' and #k == 64 and not k:find('[^%x]') end
  if os.getenv('REPLAY_PEER_KEY') and hex_ok(os.getenv('REPLAY_PEER_KEY')) then c.key = os.getenv('REPLAY_PEER_KEY')
  elseif nat_ok and nat.signing and not hex_ok(c.key) then   -- (no key yet: a new one, from the system's random bytes)
    local seed = udp and udp.random and udp.random(32)
    if not seed then                               -- (none: whatever varies, hashed; weaker, said so)
      local mix = { tostring(os.time()), tostring(os.clock()), tostring({}), tostring(math.random()), tostring(c) }
      local f = io.open('/dev/urandom', 'rb')
      if f then mix[#mix + 1] = f:read(32) or ''; f:close() end
      seed = require('ed25519').sha512(table.concat(mix, '|')):sub(1, 32)
      print('online: a new key from weak random bytes (no system source here)')
    end
    local old = c.id
    c.key = require('ed25519').hex(seed)
    fresh = true
    if nat.id_norm(old) then c.old_id = old end
  end
  if nat_ok and nat.signing and hex_ok(c.key) then  -- (our ID: our public key's hash)
    local E = require('ed25519')
    c.seed = E.unhex(c.key)
    c.pk = E.hex((E.keypair(c.seed)))
    c.id = nat.id_of(E.unhex(c.pk))
  elseif not (nat_ok and nat.id_norm(c.id)) and nat_ok then   -- (no signatures here: a random ID, as before keys)
    math.randomseed(os.time() + math.floor(os.clock() * 1e6) + (tonumber(tostring({}):match('(%x+)$'), 16) or 0) % 1000003)
    c.id = nat.id_new()
    fresh = true
  end
  PL.conf = c
  if fresh and not os.getenv('REPLAY_PEER_KEY') then
    PL.save_conf()
    if c.old_id and c.old_id ~= c.id then print(string.format('online: your peer ID is now %s (made from your new key; it was %s)', c.id, c.old_id)) end
  end
  if os.getenv('REPLAY_INTRODUCERS') then
    c.introducers = {}
    for a in os.getenv('REPLAY_INTRODUCERS'):gmatch('[^,%s]+') do c.introducers[#c.introducers + 1] = a end
  end
  return c
end
function PL.save_conf()
  local c = PL.conf
  local f = io.open(net_conf_path(), 'wb')
  if not f then return false end
  local ins = {}
  for _, a in ipairs(c.introducers or {}) do ins[#ins + 1] = string.format('%q', a) end
  f:write('-- this computer\'s network settings (runtime/players.lua): our secret key (keep it to yourself), our peer ID (its hash), introducers\n',
          string.format('return { key = %q, id = %q, introducers = { %s } }\n', tostring(c.key or ''), tostring(c.id), table.concat(ins, ', ')))
  f:close()
  return true
end
function viewer_peer_id() return nat_ok and net_conf().id or nil end
-- this network, everyone: the broadcast addresses (all, and this subnet's
-- .255, guessed /24) and this computer (several copies on one machine)
local function lan_targets()
  local t = { '255.255.255.255' }
  local me = udp.localip and udp.localip()
  local a, b, c = tostring(me):match('^(%d+)%.(%d+)%.(%d+)%.%d+$')
  if a then t[#t + 1] = a .. '.' .. b .. '.' .. c .. '.255' end
  t[#t + 1] = '127.0.0.1'
  return t
end
local function lan_socket()                        -- (IPv4, allowed to broadcast)
  local s = udp.open(0, '4')
  if s and s.broadcast then s:broadcast() end
  return s
end
-- "room@host[:port]" (an introducer's address) -> room, ip, port (no port: its list) | nil, err
local function parse_via(s)
  local room, addr = tostring(s or ''):match('^([^@]+)@(.+)$')
  if not room then return nil, 'not room@introducer[:port]: ' .. tostring(s) end
  local host, port = addr:match('^%[(.-)%]:(%d+)$')
  if not host and select(2, addr:gsub(':', '')) == 1 then host, port = addr:match('^(.-):(%d+)$') end
  host = host or addr:match('^%[(.-)%]$') or addr
  local ip, err = udp.resolve(host)
  if not ip then return nil, tostring(err) .. ': ' .. host end
  return room, ip, tonumber(port) or intro_ports()
end
local function say(...) local m = 'online: ' .. string.format(...); if dd and dd.log then dd.log(m) else print(m) end; io.stdout:flush() end   -- (flushed: a log being watched sees it now)
local function online_send(o, to, msg, host, port) o.ep:control(to, assert(ecs.encode(msg)), host, port) end
local function online_set(o)                       -- who's in: { [k] = true }
  local set = o.role == 'host' and { [1] = true } or {}
  if o.role == 'host' then for k, r in pairs(o.remotes) do if r.ok then set[k] = true end end
  else for k in pairs(o.players or {}) do set[k] = true end end
  return set
end
local function online_part(o, k, why)              -- player k is gone
  local r = o.remotes[k]
  if not r then return end
  o.remotes[k] = nil
  if o.peer then o.peer:disconnect('p' .. k) end
  o.ep:forget('p' .. k)
  say('player %d left (%s)', k, why)
end
local function online_control(o, from, bytes, host, port)
  local m = ecs.decode(bytes)
  if type(m) ~= 'table' then return end
  local k = tonumber(tostring(from):match('^p(%d+)$'))
  if k and o.remotes[k] then o.remotes[k].seen = o.t; o.remotes[k].ok = true end   -- (a joiner counts once it speaks as its player)
  if o.role == 'host' and m.t == 'seek' then        -- (someone looking for a host on our ports: this one)
    local n = 0
    for _ in pairs(online_set(o)) do n = n + 1 end
    local here = { t = 'here', game = game_name(), players = n, free = 4 - n, id = viewer_peer_id() }
    local c = net_conf()
    if m.id and m.id == c.id and type(m.ch) == 'string' and #m.ch <= 64 and c.seed then   -- (asked by our ID: proven, its challenge signed)
      o.proofs = o.proofs or {}
      if not o.proofs[m.ch] then o.proofs[m.ch] = nat.sign(c.seed, 'here', c.id, m.ch); o.nproofs = (o.nproofs or 0) + 1 end
      if o.nproofs > 64 then o.proofs, o.nproofs = {}, 0 end
      here.pk, here.sig = c.pk, o.proofs[m.ch]
    end
    online_send(o, from, here, host, port)
  elseif m.t == 'here' and o.lobby then           -- (the lobby's scan)
    if m.game == game_name() then o.lobby.found[hostport(host, port)] = { host = host, port = port, players = tonumber(m.players) or 1, free = tonumber(m.free) or 0, id = m.id } end
  elseif o.role == 'join' and m.t == 'here' and o.seek and o.waiting then
    local sk = o.seek
    if sk.id and m.id == sk.id and m.game == game_name() and nat.signing and not nat.proves(m.pk, m.sig, 'here', sk.id, sk.ch) then
      if not sk.fake then say('%s at %s answered as %s but can\'t prove it (no key behind that ID): ignored', tostring(m.game), hostport(host, port), sk.id) end
      sk.fake = true
      return
    end
    if m.game == game_name() and (not o.seek.lan or (tonumber(m.free) or 1) > 0) and (not o.seek.id or m.id == o.seek.id) then
      o.ep:add('p1', host, port)
      o.ep:pin('p1')                               -- (this one: other hosts' late answers don't move it)
      o.waiting, o.next_hello, o.target = false, 0, hostport(host, port)
      say('found %s at %s', game_name(), hostport(host, port))
    else o.seek.other = tostring(m.game) end
  elseif o.role == 'host' and m.t == 'hello' then
    if m.game ~= game_name() then online_send(o, from, { t = 'full', why = 'this is ' .. game_name() .. ', not ' .. tostring(m.game) }, host, port) return end
    local pk
    for j, r in pairs(o.remotes) do if r.tmp == from and r.host == host and r.port == port then pk = j end end   -- (welcome lost: again, the same player)
    local want = tonumber(m.seat)                  -- (a seat asked for: 2..4; none: the first free)
    if not pk and want and want >= 2 and want <= 4 then
      if o.remotes[want] then online_send(o, from, { t = 'full', why = 'player ' .. want .. ' is taken' }, host, port) return end
      pk = want
    end
    for j = 2, 4 do if not pk and not o.remotes[j] then pk = j end end
    if not pk then online_send(o, from, { t = 'full', why = 'four players already' }, host, port) return end
    local fresh = not o.remotes[pk]
    o.remotes[pk] = o.remotes[pk] or { host = host, port = port, tmp = from, seen = o.t }
    o.ep:add('p' .. pk, host, port)
    if fresh then o.peer:connect('p' .. pk) end
    local ok, blob = o.world:save('/**')
    if not ok then return end
    local players = online_set(o)
    players[pk] = true                             -- (the joiner is in: its nodes are its own from the start)
    online_send(o, from, { t = 'welcome', player = pk, world = blob, players = players }, host, port)
    if fresh then say('player %d joined from %s', pk, hostport(host, port)) end
    o.next_roster = 0
  elseif o.role == 'join' and m.t == 'welcome' and not o.player and tonumber(m.player) and type(m.world) == 'string' then
    o.player = tonumber(m.player)
    o.ep.id = 'p' .. o.player
    o.ep:add('p1', host, port)
    o.ep:pin('p1')                                 -- (the host is here: no other answer moves it)
    local ok, err = o.world:load(m.world, '/')
    if not ok then say("can't take the host's world: %s", tostring(err)); o.failed = true return end
    o.world.players = m.players
    o.players = m.players
    o.peer = net.peer(o.world, o.ep, o.player)
    o.peer.replica.rate = PL.rate
    o.peer.rate_override = PL.rate_set and PL.rate or nil
    o.peer:connect('p1')
    o.remotes[1] = { host = host, port = port, seen = o.t, ok = true }
    say('joined %s as player %d', hostport(host, port), o.player)
  elseif o.role == 'join' and m.t == 'full' then
    say("can't join: %s", tostring(m.why)); o.failed = true
  elseif o.role == 'join' and m.t == 'kick' and k == 1 then
    say('the host let you go'); o.failed = true
  elseif o.role == 'join' and m.t == 'roster' and o.peer then
    o.players = type(m.players) == 'table' and m.players or o.players
    o.players[o.player] = true                     -- (we're in, whatever the host has heard yet)
    o.world.players = o.players
  elseif m.t == 'bye' and k then
    if o.role == 'join' and k == 1 then say('the host left'); o.failed = true
    else online_part(o, k, 'said bye') end
  end
end
local function online_drop()
  local o = PL.online
  if not o then return end
  if o.pm then o.pm:close(); o.pm:tick(0); if not o.pm.closed then PL.closing[#PL.closing + 1] = o.pm end end   -- (released: the router's port closes)
  for k in pairs(o.remotes) do pcall(online_send, o, 'p' .. k, { t = 'bye' }) end
  o.ep:close()
  if o.world then o.world.peer, o.world.players, o.world.net = nil, nil, nil end   -- (offline: the world plays alone again)
  PL.online = nil
  say('offline')
end
viewer_online_drop = online_drop
local function online_kick(o, k)                   -- (the host) player k out
  pcall(online_send, o, 'p' .. k, { t = 'kick' })
  online_part(o, k, 'let go')
  o.next_roster = 0
end
function viewer_online_player() return PL.online and PL.online.player end   -- (this editor's player online; nil: not in)
function viewer_online_peers()                     -- (tests) the replica's peers, joined: "p1,p3"
  local o = PL.online
  return o and o.peer and table.concat(o.peer.replica.peers, ',') or ''
end
-- online too, the Network button makes it worse on purpose: what this
-- editor sends is held, lost or doubled (net.lua UdpEp.impair) as its
-- quality says (100%: as it is); a player's own line (its menu) for what
-- goes to that player (the host) or what this player sends (a joiner)
local function online_impair(o, ep)
  ep.clock = udp.clock
  ep.impair = function(to)
    local k = o.role == 'host' and tonumber(tostring(to):match('(%d+)$')) or o.player
    local l = k and PL.links[k]
    if l == 'cut' then return { cut = true } end
    if type(l) == 'number' then return l < 1 and params(l) or nil end
    return PL.q < 1 and params() or nil
  end
end
function viewer_online_host(w, port, via)          -- via: "room@introducer[:port]" (nil: PL.mode.via) -> ok, port | nil, err
  online_drop(); drop_all()
  if not udp then return nil, 'no sockets here' end
  via = via or PL.mode.via
  local me = viewer_peer_id()
  if not via and me and #net_conf().introducers > 0 then via = me .. '@' .. net_conf().introducers[1] end   -- (an introducer set: known there by our ID)
  if via and me and tostring(via):sub(1, 1) == '@' then via = me .. via end   -- ("@1.2.3.4": by our ID)
  local room, ih, ip
  if via then
    if not nat_ok then return nil, 'no nat.lua here' end
    room, ih, ip = parse_via(via)
    if not room then return nil, ih end
  end
  local sock, err
  if tonumber(port) and tonumber(port) > 0 then sock, err = udp.open(tonumber(port))
  else sock, err = open_first(game_ports()) end    -- (no port: the game's, the first free)
  if not sock then return nil, err end
  local ep = net.udp(sock, 'p1')
  local o = { role = 'host', ep = ep, world = w, player = 1, remotes = {}, t = 0, next_roster = 0, next_ping = 0 }
  if udp.clock then online_impair(o, ep) end
  o.peer = net.peer(w, ep, 1)
  o.peer.replica.rate = PL.rate
  o.peer.rate_override = PL.rate_set and PL.rate or nil
  ep.on_control = function(...) online_control(o, ...) end
  PL.online = o
  w.players = online_set(o)
  local lan = addr_of(udp.localip and udp.localip() or '<this computer>', sock:port(), game_ports())
  if PL.portmap and pm_ok and udp.gateway then o.pm = portmap.new { port = sock:port() } end   -- (the router, asked to open our port)
  if room then                                     -- (through routers: known to the introducer as this room)
    o.nat = nat.client(ep, ih, ip, { lan = { { udp.localip and udp.localip() or '127.0.0.1', sock:port() } },
                                     seed = net_conf().seed, pk = net_conf().pk })   -- (our key: our peer ID registered, proven)
    o.nat:register(room)
    if me and room ~= me then o.nat:register(me) end   -- (by our ID too)
    o.nat.on_intro = function(id, h, p, how) say('a player is coming in from %s (%s)', hostport(h, p), how) end
    o.via = via
    if room == me then say('hosting %s on port %d, known to %s by our ID: others join("%s")', game_name(), sock:port(), addr_of(ih, ip, intro_ports()), me)
    else say('hosting %s on port %d as room %s at %s: others join with join("%s@%s")%s', game_name(), sock:port(), room, addr_of(ih, ip, intro_ports()), room, addr_of(ih, ip, intro_ports()), me and (' or join("' .. me .. '")') or '') end
  else
    say('hosting %s on port %d: others join with join("%s")%s', game_name(), sock:port(), lan, me and (' or, nearby, join("' .. me .. '")') or '')
  end
  return true, sock:port()
end
function viewer_online_join(w, addr, seat, not_id)   -- addr: "host[:port]" (no port: the game's), a peer ID, "room@introducer"; seat: 2..4 (nil: the first free) -> ok | nil, err
  online_drop(); drop_all()
  if not udp then return nil, 'no sockets here' end
  if tostring(addr):find('@', 1, true) then return viewer_online_meet(w, addr, seat) end   -- "room@introducer": through routers
  if addr == nil or addr == '' or addr == '*' then return viewer_online_join_lan(w, seat) end   -- nobody named: the first host nearby
  local id = nat_ok and not not_id and not tostring(addr):find('[%.:%[]') and nat.id_norm(addr)
  if id then return viewer_online_join_lan(w, seat, id, addr) end   -- a peer ID: nearby first, then the introducers
  local host, port = tostring(addr):match('^%[(.-)%]:(%d+)$')   -- "[2001:db8::1]:7777"
  if not host then host = tostring(addr):match('^%[(.-)%]$') end  -- "[2001:db8::1]"
  if not host and select(2, tostring(addr):gsub(':', '')) == 1 then host, port = tostring(addr):match('^(.-):(%d+)$') end   -- "1.2.3.4:7777", "name:7777"
  host, port = host or tostring(addr), tonumber(port)  -- ("2001:db8::1", "1.2.3.4", a name: no port: the game's)
  local ip, err = udp.resolve(host)
  if not ip then return nil, err .. ': ' .. host end
  local sock, err2 = udp.open(0)
  if not sock then return nil, err2 end
  local ep = net.udp(sock, string.format('j%d', sock:port() or 0))   -- (a name until the host gives us a player)
  local o = { role = 'join', ep = ep, world = w, remotes = {}, t = 0, next_hello = 0, next_ping = 0, target = port and hostport(ip, port) or ip, seat = seat }
  if port then ep:add('p1', ip, port)
  else                                             -- (which port: ask all of the game's at once, the first host of this game)
    local list = game_ports()
    list[#list + 1] = ONLINE_PORT
    o.seek, o.waiting, o.next_seek = { ips = { ip }, ports = list, where = ip }, true, 0
  end
  if udp.clock then online_impair(o, ep) end
  ep.on_control = function(...) online_control(o, ...) end
  PL.online = o
  say('joining %s...', port and hostport(ip, port) or (ip .. " (the game's ports)"))
  return true
end
-- join through routers: the introducer at "room@introducer[:port]" introduces
-- us to that room's host; hole punching (nat.lua) finds the path (a relay
-- when none opens), then it's an ordinary join on the same socket
function viewer_online_meet(w, via, seat)
  if not nat_ok then return nil, 'no nat.lua here' end
  local room, ih, ip = parse_via(via)
  if not room then return nil, ih end
  local sock, err = udp.open(0)
  if not sock then return nil, err end
  local ep = net.udp(sock, string.format('j%d', sock:port() or 0))
  local o = { role = 'join', ep = ep, world = w, remotes = {}, t = 0, next_hello = 0, next_ping = 0, target = room .. '@' .. addr_of(ih, ip, intro_ports()), seat = seat, waiting = true }
  if udp.clock then online_impair(o, ep) end
  ep.on_control = function(...) online_control(o, ...) end
  o.nat = nat.client(ep, ih, ip, { lan = { { udp.localip and udp.localip() or '127.0.0.1', sock:port() } } })
  local function found(h, p, how)
    ep:add('p1', h, p)
    o.waiting, o.next_hello = false, 0
    o.target = hostport(h, p) .. (how == 'relay' and ' (relayed)' or '')
    say('found %s: %s (%s)', room, hostport(h, p), how)
  end
  if PL.portmap and pm_ok and udp.gateway then   -- (our router asked first, a moment: an opened port is one more way in)
    o.pm = portmap.new { port = sock:port() }
    o.meet_later = { room, found }
    o.nat:who()
  else o.nat:meet(room, found) end
  PL.online = o
  say('asking %s for room %s...', addr_of(ih, ip, intro_ports()), room)
  return true
end
-- join(): nobody named, the first host of this game on this network with a
-- free seat (broadcast on the game's ports; IPv4)
-- join(ID): the same, only the host with that peer ID; not nearby (1.5 s):
-- through the introducers (ID@introducer); none: as a name (it may be one)
local function challenge()                         -- a seek's challenge: never the same twice (what a host signs to prove its ID)
  local r = udp and udp.random and udp.random(12)
  if r then return (r:gsub('.', function(ch) return string.format('%02x', ch:byte()) end)) end
  PL.ch_n = (PL.ch_n or 0) + 1
  return string.format('%x%x%x', os.time(), math.floor(os.clock() * 1e6), PL.ch_n) .. tostring({}):match('(%x+)$')
end
function viewer_online_join_lan(w, seat, id, raw)
  local sock, err = lan_socket()
  if not sock then return nil, err end
  local ep = net.udp(sock, string.format('j%d', sock:port() or 0))
  local o = { role = 'join', ep = ep, world = w, remotes = {}, t = 0, next_hello = 0, next_ping = 0, target = id or 'this network', seat = seat,
              seek = { ips = lan_targets(), ports = game_ports(), lan = true, id = id, raw = raw, ch = id and challenge() or nil }, waiting = true, next_seek = 0 }
  if udp.clock then online_impair(o, ep) end
  ep.on_control = function(...) online_control(o, ...) end
  PL.online = o
  if id then say('looking for %s nearby...', id) else say('looking for a %s host on this network...', game_name()) end
  return true
end
-- the lobby: who hosts this game nearby (a scan: 1 s; the log lists them;
-- viewer_lobby() -> { { host, port, players, free } ... } sorted)
function viewer_lobby_scan(secs)
  if PL.lobby_o then PL.lobby_o.ep:close() end
  local sock, err = lan_socket()
  if not sock then return nil, err end
  local ep = net.udp(sock, string.format('l%d', sock:port() or 0))
  local o = { ep = ep, lobby = { found = {} }, remotes = {}, t = 0, until_t = tonumber(secs) or 1, next_seek = 0, sent = 0 }
  ep.on_control = function(...) online_control(o, ...) end
  PL.lobby_o = o
  return true
end
local function lobby_tick(dt)
  local o = PL.lobby_o
  if not o then return end
  o.t = o.t + dt
  if o.t >= o.next_seek and o.sent < 2 then         -- (twice: broadcasts get lost)
    o.next_seek, o.sent = o.t + 0.4, o.sent + 1
    for _, ip in ipairs(lan_targets()) do
      for _, p in ipairs(game_ports()) do pcall(online_send, o, '*', { t = 'seek', game = game_name() }, ip, p) end
    end
  end
  o.ep:poll()
  if o.t >= o.until_t then
    o.ep:close()
    PL.lobby_o = nil
    PL.lobby = {}
    local me = udp.localip and udp.localip()
    for _, h in pairs(o.lobby.found) do           -- (this computer, heard twice: by 127.0.0.1 and by its address; the address kept)
      local twin = h.host == '127.0.0.1' and me and o.lobby.found[hostport(me, h.port)]
      if not twin then PL.lobby[#PL.lobby + 1] = h end
    end
    table.sort(PL.lobby, function(a, b) return a.host == b.host and a.port < b.port or tostring(a.host) < tostring(b.host) end)
    local ls = {}
    for _, h in ipairs(PL.lobby) do ls[#ls + 1] = string.format('%s (%d in, %d free)', hostport(h.host, h.port), h.players, h.free) end
    say(#ls > 0 and ('%s hosts nearby: ' .. table.concat(ls, ', ')) or 'no %s host nearby', game_name())
  end
end
PL.lobby = {}
function viewer_lobby() return PL.lobby, PL.lobby_o ~= nil end   -- (the last scan's hosts, scanning now)
-- the Players button's lobby menu (RMB on P2-P4, the switch on, stopped:
-- editor/bar.h): its lines ("" a separator) and what a click on one does
function viewer_lobby_items()
  local t = { 'Type an address...', 'The first host nearby', '' }
  local hosts, scanning = viewer_lobby()
  for _, h in ipairs(hosts) do
    t[#t + 1] = string.format('%s%s   %d in, %d free', hostport(h.host, h.port), h.id and ('  ' .. h.id) or '', h.players, h.free)
  end
  if #hosts == 0 then t[#t + 1] = scanning and '(looking nearby...)' or '(no host nearby)' end
  t[#t + 1] = ''
  t[#t + 1] = 'Look again'
  return table.concat(t, '\n')
end
function viewer_lobby_pick(w, i, seat)             -- -> ask for an address (true), a message
  local m = PL.mode
  if seat and seat > 1 then m.seat = seat end
  local hosts, n = PL.lobby or {}, 0
  for _ in pairs(hosts) do n = n + 1 end
  local last = 3 + math.max(1, #hosts) + 2         -- (Look again)
  if i == 1 then return true end
  if i == 2 then viewer_online_set(true, 'join', '*'); return false, 'joins the first host nearby on Play' end
  if i == last then viewer_lobby_scan(1); return false end
  local h = hosts[i - 3]
  if h then
    viewer_online_set(true, 'join', hostport(h.host, h.port))   -- (its address: two copies on one computer share an ID)
    return false, 'joins ' .. hostport(h.host, h.port) .. (h.id and (' (' .. h.id .. ')') or '') .. ' on Play'
  end
  return false
end
function viewer_net_busy() return PL.online ~= nil or PL.lobby_o ~= nil or PL.intro ~= nil or #PL.closing > 0 end
local function online_tick(o, dt)
  o.t = o.t + dt
  if o.seek and o.seek.id and o.waiting and not o.failed and o.t > 1.5 then   -- (an ID nobody nearby has: elsewhere)
    local intros, sk = net_conf().introducers, o.seek
    if #intros > 0 then
      o.ep:close(); PL.online = nil
      say('%s is not nearby: asking %s', sk.id, intros[1])
      local ok, err = viewer_online_meet(o.world, sk.id .. '@' .. intros[1], o.seat)
      if not ok then say("can't: %s", tostring(err)) end
      return
    elseif udp.resolve(sk.raw) then                -- (a computer's name that looks like an ID)
      o.ep:close(); PL.online = nil
      local ok, err = viewer_online_join(o.world, sk.raw, o.seat, true)
      if not ok then say("can't: %s", tostring(err)) end
      return
    else
      say('nobody nearby is %s (no introducer set: introducers("1.2.3.4"))', sk.id)
      o.failed = true
    end
  end
  if o.seek and o.waiting and not o.failed then
    if o.t > 5 then
      say('no %s host %s%s', game_name(), o.seek.lan and 'on this network' or ('at ' .. o.seek.where), o.seek.other and (' (found ' .. o.seek.other .. ')') or '')
      o.failed = true
    elseif o.t >= o.next_seek then
      o.next_seek = o.t + 0.5
      for _, ip in ipairs(o.seek.ips) do
        for _, p in ipairs(o.seek.ports) do pcall(online_send, o, 'p1', { t = 'seek', game = game_name(), id = o.seek.id, ch = o.seek.ch }, ip, p) end
      end
    end
  end
  if o.nat then
    o.nat:tick(dt)
    local mt = o.nat.meeting
    if o.waiting and mt and mt.failed and not o.failed then
      local why = tostring(mt.failed)
      if nat.id_norm(mt.room) and why:find('^no room') then why = 'nobody known as ' .. mt.room .. ' there' end
      say("can't meet: %s", why); o.failed = true
    end
    if o.waiting and mt and mt.got and not o.failed and o.t > 20 then say("can't meet: no path to the host"); o.failed = true end
    if o.role == 'host' and o.nat.public and not o.said_public then
      o.said_public = true
      say('the introducer sees this computer at %s (this router: %s)', hostport(o.nat.public[1], o.nat.public[2]), o.nat:mapping() or '?')
    end
  end
  if o.pm then                                     -- the router's answer: an address others can reach, or why not
    o.pm:tick(dt)
    local r = o.pm.result
    if (r or o.pm.failed) and not o.pm_said and (not o.nat or o.nat.public or o.pm.failed or o.t > 5) then
      o.pm_said = true
      local pub = o.nat and o.nat.public
      if o.pm.failed then say('%s', o.pm:status())
      elseif r.private then say('%s', o.pm:status())
      elseif pub and pub[1] ~= r[1] then
        say('the router opened %s, but the introducer sees us at %s: another NAT is in front (not used)', hostport(r[1], r[2]), pub[1])
      else
        o.reachable = { r[1], r[2] }
        if o.nat then o.nat:add_candidate(r[1], r[2]) end
        if o.role == 'host' then say('%s: others can join("%s") directly', o.pm:status(), addr_of(r[1], r[2], game_ports()))
        else say('%s: one more way in for the host', o.pm:status()) end
      end
    end
  end
  if o.meet_later and (o.pm_said or o.t > 2.5) then  -- (a joiner: the router answered, or 2.5 s: meet now)
    local m = o.meet_later
    o.meet_later = nil
    o.nat:meet(m[1], m[2])
  end
  if o.role == 'join' and not o.waiting and not o.player and not o.failed and o.t >= o.next_hello then   -- (until welcomed)
    o.next_hello = o.t + 0.5
    online_send(o, 'p1', { t = 'hello', game = game_name(), seat = o.seat })
  end
  if o.peer then o.peer:update(dt) else o.ep:poll() end
  if o.role == 'host' and o.t >= o.next_roster then
    o.next_roster = o.t + 1
    local msg = { t = 'roster', players = online_set(o) }
    for k in pairs(o.remotes) do online_send(o, 'p' .. k, msg) end
    o.world.players = online_set(o)
  end
  if o.peer and o.t >= o.next_ping then
    o.next_ping = o.t + 1
    for k in pairs(o.remotes) do online_send(o, 'p' .. k, { t = 'ping' }) end
  end
  for k, r in pairs(o.remotes) do
    if o.t - r.seen > 6 then
      if o.role == 'join' and k == 1 then say('the host is gone (6 s of silence)'); o.failed = true; o.remotes[1] = nil
      else online_part(o, k, '6 s of silence') end
    end
  end
end
function viewer_online_info()                      -- -> a line: who's in, where (nil: offline)
  local o = PL.online
  if not o then return nil end
  local ks = {}
  for k in pairs(online_set(o)) do ks[#ks + 1] = k end
  table.sort(ks)
  if o.role == 'host' then
    local pub = o.reachable and (', ' .. hostport(o.reachable[1], o.reachable[2]) .. ' opened on the router')
      or o.nat and o.nat.public and (', ' .. hostport(o.nat.public[1], o.nat.public[2]) .. ' to the world') or ''
    return string.format('hosting on port %d%s%s%s: players %s', o.ep.sock:port() or 0, viewer_peer_id() and (', ID ' .. viewer_peer_id()) or '', o.via and (' as ' .. o.via) or '', pub, table.concat(ks, ', '))
  end
  if not o.player then return 'joining ' .. o.target .. (o.failed and ' (failed)' or '...') end
  return string.format('player %d at %s: players %s%s', o.player, o.target, table.concat(ks, ', '), o.failed and ' (the host is gone)' or '')
end
viewer_console_cmds = viewer_console_cmds or {}
-- The online switch (the bar's power button): off, the Players button's
-- players are this computer's (local multiplayer, over net.sim); on, each
-- editor is one player, and the Players button is the seat: P1 hosts (the
-- default), P2..P4 join the host's address as that player (0: the first
-- free). Set while stopped; Play starts the session, Stop ends it, the
-- switch stays. --host / --join turn it on at launch.
PL.mode = { on = false, seat = 1, port = nil, addr = nil, via = nil }   -- (port nil: the game's; via: the host's room@introducer)
local function mode_role(m) return m.seat == 1 and 'host' or 'join' end
local function bits(set) local mask = 0; for k in pairs(set) do mask = mask + 2 ^ (k - 1) end; return mask end   -- (no bit ops: 5.1 / luajit)
function viewer_online_mode()                      -- -> on, role, a line for the tooltip, seat
  local m = PL.mode
  local line = m.seat == 1 and ('P1 hosts' .. (m.port and (', port ' .. m.port) or '') .. (m.via and (' as ' .. m.via) or ''))
    or ((m.seat > 1 and ('P' .. m.seat) or 'a free seat') .. ' joins ' .. (m.addr == '*' and 'the first host nearby' or m.addr or '(no address yet)'))
  return m.on, mode_role(m), line, m.seat
end
function viewer_online_set(on, role, arg, via)     -- (role: 'host' (arg: a port, via: room@introducer) or 'join' (arg: an address or room@introducer))
  local m = PL.mode
  if role == 'host' then
    m.seat = 1
    if arg ~= nil then m.port = (tonumber(arg) and tonumber(arg) > 0) and tonumber(arg) or nil end   -- (0, "": the game's ports)
    if via ~= nil then m.via = via ~= '' and tostring(via) or nil end
  elseif role == 'join' then
    if m.seat == 1 then m.seat = 0 end             -- (a seat picked on the Players button stays)
    m.addr = (arg and arg ~= '') and tostring(arg) or m.addr
  end
  if on ~= nil then m.on = on and true or false end
  if not m.on then online_drop() end
  return m.on
end
function viewer_online_begin(w)                    -- Play: online now, if the switch is on (-> ok | nil, err)
  PL.playing = true
  local m = PL.mode
  if not m.on or PL.online then return true end
  if m.seat == 1 then return viewer_online_host(w, m.port) end
  if not m.addr then return nil, 'join: no address (right-click a player on the Players button)' end
  return viewer_online_join(w, m.addr, m.seat > 1 and m.seat or nil)
end
function viewer_online_mask()                      -- the Players button, the switch on: -1 off; stopped: the seat; playing: who's in
  local m, o = PL.mode, PL.online
  if not m.on then return -1 end
  if not PL.playing then return m.seat > 0 and 2 ^ (m.seat - 1) or 0 end
  if not o or o.failed then return 0 end
  return bits(online_set(o))
end
-- a click on the Players button's quarter k, the switch on -> ask (the
-- console: join("") for the address), a message (nil: done)
--   stopped: this editor's seat (P1 hosts; P2..P4 join; RMB: the address again)
--   playing, the host: a joiner's quarter lets that player go
--   playing, a joiner: its own leaves; a free one joins there (again)
function viewer_players_click(w, k, rmb)
  local m, o = PL.mode, PL.online
  if not PL.playing then
    m.seat = k
    return k > 1 and (rmb or not m.addr) or false
  end
  if o and o.role == 'host' then
    if k > 1 and o.remotes[k] then online_kick(o, k) end
    return false
  end
  if o and not o.failed and o.player == k then online_drop(); return false end
  if k == 1 or (o and not o.failed and online_set(o)[k]) then return false end   -- (the host's, a taken one)
  if not m.addr then m.seat = k; return true end
  m.seat = k
  local ok, err = viewer_online_join(w, m.addr, k)
  return false, not ok and err or nil
end
function viewer_players_tip()                      -- the Players button's tooltip, the switch on (nil: off)
  local m, o = PL.mode, PL.online
  if not m.on then return nil end
  if not PL.playing then
    return 'Online seat: ' .. select(3, viewer_online_mode()) .. '   click: this editor\'s seat (P1 hosts, P2-P4 join)   RMB on P2-P4: hosts nearby, an address'
      .. (viewer_peer_id() and ('   your ID: ' .. viewer_peer_id()) or '')
  end
  local ks = {}
  if o and not o.failed then for k in pairs(online_set(o)) do ks[#ks + 1] = k end end
  table.sort(ks)
  local who = #ks > 0 and table.concat(ks, ' ') or 'none'
  if o and o.role == 'host' then return 'Online, hosting' .. (viewer_peer_id() and (' (ID ' .. viewer_peer_id() .. ')') or '') .. ': players ' .. who .. '   click a joiner: let them go' end
  if o and not o.failed and o.player then return 'Online, player ' .. o.player .. ': players ' .. who .. '   click yours: leave   a free one: join there' end
  return 'Online: not in (' .. (o and (o.failed and 'out' or 'joining...') or 'left') .. ')   click a free player (2-4): join there'
end
viewer_console_cmds.host = function(w, port, via)  -- (stopped: the switch, for the next Play; playing: now too)
  if type(port) == 'string' and port:find('@', 1, true) then port, via = nil, port end   -- host("room@1.2.3.4")
  viewer_online_set(true, 'host', port, via)
  if not PL.playing then return 'online: hosting on Play (port ' .. PL.mode.port .. ')' end
  local ok, p = viewer_online_host(w, PL.mode.port); return ok and ('hosting on port ' .. p) or p
end
viewer_console_cmds.join = function(w, addr)
  if (addr == nil or addr == '') and not PL.mode.addr then addr = '*' end   -- (nobody named: the first host nearby)
  viewer_online_set(true, 'join', addr)
  local who = PL.mode.addr == '*' and 'the first host nearby' or tostring(PL.mode.addr)
  if not PL.playing then return 'online: joining ' .. who .. ' on Play' end
  local m = PL.mode
  local ok, err = viewer_online_join(w, m.addr, m.seat > 1 and m.seat or nil); return ok and ('joining ' .. who .. '...') or err
end
-- an introducer here (nat.lua): players behind routers meet through it (it
-- needs an address they can reach: a public one, or a port forwarded)
function viewer_introducer(port)                   -- -> ok, port | nil, err (port: nil / 0: its own ports; false: stop it)
  if PL.intro then PL.intro:close(); PL.intro = nil end
  if port == false then say('introducer stopped'); return true end
  if not nat_ok then return nil, 'no nat.lua here' end
  if not udp then return nil, 'no sockets here' end
  local sock, err, probes
  local function with_probes(p)                    -- (its probe ports: the next two, free too)
    local a = udp.open(p + 1)
    local b = a and udp.open(p + 2)
    if b then probes = { a, b } return true end
    if a then a:close() end
    return false
  end
  if tonumber(port) and tonumber(port) > 0 then
    sock, err = udp.open(tonumber(port))
    if sock and not with_probes(sock:port()) then probes = {} end   -- (a port asked for: no prediction if its neighbours are taken)
  else sock, err = open_first(intro_ports(), with_probes) end
  if not sock then return nil, err end
  PL.intro = nat.introducer(sock, function(p) return udp.open(p) end, { probes = probes })
  local me = addr_of(udp.localip and udp.localip() or '<this computer>', sock:port(), intro_ports())
  say('introducing on port %d (and %d, %d): hosts use host("room@%s"), players join("room@%s")', sock:port(), sock:port() + 1, sock:port() + 2, me, me)
  return true, sock:port()
end
function viewer_introducer_tick(dt)               -- (every frame, playing or not: the introducer, the lobby's scan, mappings being released)
  if PL.intro then PL.intro:tick(dt) end
  lobby_tick(dt)
  for i = #PL.closing, 1, -1 do
    local pm = PL.closing[i]
    pm:tick(dt)
    if pm.closed then table.remove(PL.closing, i) end
  end
end
function viewer_release_ports(secs)                -- (on the way out: give the routers a moment to close our ports)
  if #PL.closing == 0 or not (udp and udp.clock) then return end
  local t0, last = udp.clock(), udp.clock()
  while #PL.closing > 0 and udp.clock() - t0 < (secs or 1) do
    local now = udp.clock(); viewer_introducer_tick(now - last); last = now
    udp.sleep(0.01)
  end
end
viewer_console_cmds.portmap = function(w, on)     -- portmap(): what the router said; portmap(false / true): ask it or not (next hosting)
  if on ~= nil then PL.portmap = on and true or false; return 'asking the router to open a port: ' .. (PL.portmap and 'on' or 'off') .. ' (from the next host)' end
  local o = PL.online
  if o and o.pm then return o.pm:status() end
  return 'asking the router to open a port: ' .. (PL.portmap and 'on (when hosting)' or 'off')
end
viewer_console_cmds.introducer = function(w, port)
  local ok, p = viewer_introducer(port)               -- (introducer(false): stop it)
  if not ok then return p end
  return PL.intro and ('introducing on port ' .. p .. ' (rooms: ' .. (function() local n = 0; for _ in pairs(PL.intro.rooms) do n = n + 1 end; return n end)() .. ')') or 'introducer stopped'
end
viewer_console_cmds.lobby = function(w, secs)    -- lobby(): who hosts this game nearby (listed in the log in a second)
  local ok, err = viewer_lobby_scan(tonumber(secs))
  if not ok then return err end
  return 'looking for ' .. game_name() .. ' hosts on this network...'
end
viewer_console_cmds.id = function()                -- id(): this computer's peer ID (others join("TJHJDJX"))
  local id = viewer_peer_id()
  return id and ('your peer ID: ' .. id .. '   (others join("' .. id .. '"); stored in .network.lua)') or 'no peer IDs here'
end
viewer_console_cmds.introducers = function(w, ...)  -- introducers("1.2.3.4", ...): where hosts make themselves known by ID; introducers(): the list; introducers(false): none
  local c = net_conf()
  local args = { ... }
  if args[1] == false then c.introducers = {}; PL.save_conf()
  elseif #args > 0 then c.introducers = {}; for _, a in ipairs(args) do c.introducers[#c.introducers + 1] = tostring(a) end; PL.save_conf() end
  return #c.introducers > 0 and ('introducers: ' .. table.concat(c.introducers, ', ')) or 'no introducers (introducers("1.2.3.4"): one)'
end
viewer_console_cmds.leave = function() viewer_online_set(false); return 'offline' end
viewer_console_cmds.online = function() return viewer_online_info() or 'offline' end
-- the joiner's keys are its player's
local key0 = viewer_key
function viewer_key(w, key, down, player)
  local o = PL.online
  if o and o.world == w and o.player then player = o.player end
  return key0(w, key, down, player)
end

function viewer_players_stop() online_drop(); drop_all(); PL.playing = false end
-- a tick (after the host's): the network moves, the peers tick, then
-- everyone takes what arrived and sends what it owns
local function tick_one(w, dt) w:tick('/**', dt) end
-- a network session ticks at a fixed rate (the viewer runs as many ticks as
-- the time that passed: a slow window still keeps up), numbered: commands,
-- replays (net.lua). nil: no session, a tick a frame.
PL.hz = 60
local function hz_of(w)                           -- (the game's config/net.lua hz, else 60)
  local n = w and w.nodes and w.nodes['/config']
  local c = n and n.c.net
  return type(c) == 'table' and tonumber(c.hz) or PL.hz
end
function viewer_players_step()
  if PL.online and PL.online.peer then return 1 / hz_of(PL.online.world) end
  if PL.sim then return 1 / hz_of(PL.host) end
end
function viewer_players_tick(dt)
  if PL.online then online_tick(PL.online, dt) return end
  if not PL.sim then return end
  PL.sim:advance(dt)
  for k = 2, 4 do if PL.peers[k] then as_peer(k, tick_one, PL.peers[k].world, dt) end end
  for k = 1, 4 do
    local p = PL.peers[k]
    if p and k == 1 then p.peer:update(dt) elseif p then as_peer(k, p.peer.update, p.peer, dt) end
  end
end
local function shared(k) return not PL.sim and PL.host and PL.set and PL.set[k] end   -- (100%: the host's world)
function viewer_players_key(k, key, down)
  if shared(k) then return PL.host:key(key, down, k) end
  local p = PL.peers[k]
  if p then as_peer(k, p.world.key, p.world, key, down, k) end
end
function viewer_players_world(k)
  if shared(k) then return PL.host end
  return PL.peers[k] and PL.peers[k].world
end
function viewer_players_rtt(k)                     -- player k's round trip to the host, ms (0: not measured)
  local p = PL.peers[k]
  return p and k > 1 and math.floor(p.peer:rtt('p1') * 1000 + 0.5) or 0
end
-- a folder world's files changed (viewer_poll): every player has the same files
function viewer_players_patch(patch)
  for k = 2, 4 do if PL.peers[k] then PL.peers[k].world:load(patch, '/') end end
end

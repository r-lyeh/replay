-- players.lua - the Players and Network buttons' Lua (the editor's world VM):
-- players 1..4 of the game over a simulated network (net.sim). play.c runs
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
local ONLINE_PORT = 7777
local function hostport(h, p) return (tostring(h):find(':', 1, true) and ('[' .. h .. ']') or tostring(h)) .. ':' .. tostring(p) end   -- (IPv6: in brackets)
local function say(...) local m = 'online: ' .. string.format(...); if dd and dd.log then dd.log(m) else print(m) end end
local function game_name() return viewer_game_name and viewer_game_name() or '?' end
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
  if o.role == 'host' and m.t == 'hello' then
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
function viewer_online_host(w, port)               -- -> ok, port | nil, err
  online_drop(); drop_all()
  if not udp then return nil, 'no sockets here' end
  local sock, err = udp.open(tonumber(port) or ONLINE_PORT)
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
  say('hosting %s on port %d: others join with join("%s")', game_name(), sock:port(), hostport(udp.localip and udp.localip() or '<this computer>', sock:port()))
  return true, sock:port()
end
function viewer_online_join(w, addr, seat)         -- addr: "host[:port]", seat: 2..4 (nil: the first free) -> ok | nil, err
  online_drop(); drop_all()
  if not udp then return nil, 'no sockets here' end
  local host, port = tostring(addr):match('^%[(.-)%]:(%d+)$')   -- "[2001:db8::1]:7777"
  if not host then host = tostring(addr):match('^%[(.-)%]$') end  -- "[2001:db8::1]"
  if not host and select(2, tostring(addr):gsub(':', '')) == 1 then host, port = tostring(addr):match('^(.-):(%d+)$') end   -- "1.2.3.4:7777", "name:7777"
  host, port = host or tostring(addr), tonumber(port) or ONLINE_PORT  -- ("2001:db8::1", "1.2.3.4", a name: the default port)
  local ip, err = udp.resolve(host)
  if not ip then return nil, err .. ': ' .. host end
  local sock, err2 = udp.open(0)
  if not sock then return nil, err2 end
  local ep = net.udp(sock, string.format('j%d', sock:port() or 0))   -- (a name until the host gives us a player)
  ep:add('p1', ip, port)
  local o = { role = 'join', ep = ep, world = w, remotes = {}, t = 0, next_hello = 0, next_ping = 0, target = hostport(ip, port), seat = seat }
  if udp.clock then online_impair(o, ep) end
  ep.on_control = function(...) online_control(o, ...) end
  PL.online = o
  say('joining %s...', hostport(ip, port))
  return true
end
local function online_tick(o, dt)
  o.t = o.t + dt
  if o.role == 'join' and not o.player and not o.failed and o.t >= o.next_hello then   -- (until welcomed)
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
  if o.role == 'host' then return string.format('hosting on port %d: players %s', o.ep.sock:port() or 0, table.concat(ks, ', ')) end
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
PL.mode = { on = false, seat = 1, port = ONLINE_PORT, addr = nil }
local function mode_role(m) return m.seat == 1 and 'host' or 'join' end
local function bits(set) local mask = 0; for k in pairs(set) do mask = mask + 2 ^ (k - 1) end; return mask end   -- (no bit ops: 5.1 / luajit)
function viewer_online_mode()                      -- -> on, role, a line for the tooltip, seat
  local m = PL.mode
  local line = m.seat == 1 and ('P1 hosts, port ' .. m.port)
    or ((m.seat > 1 and ('P' .. m.seat) or 'a free seat') .. ' joins ' .. (m.addr or '(no address yet)'))
  return m.on, mode_role(m), line, m.seat
end
function viewer_online_set(on, role, arg)          -- (role: 'host' (arg: a port) or 'join' (arg: an address))
  local m = PL.mode
  if role == 'host' then m.seat, m.port = 1, tonumber(arg) or m.port
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
    return 'Online seat: ' .. select(3, viewer_online_mode()) .. '   click: this editor\'s seat (P1 hosts, P2-P4 join)   RMB: the address'
  end
  local ks = {}
  if o and not o.failed then for k in pairs(online_set(o)) do ks[#ks + 1] = k end end
  table.sort(ks)
  local who = #ks > 0 and table.concat(ks, ' ') or 'none'
  if o and o.role == 'host' then return 'Online, hosting: players ' .. who .. '   click a joiner: let them go' end
  if o and not o.failed and o.player then return 'Online, player ' .. o.player .. ': players ' .. who .. '   click yours: leave   a free one: join there' end
  return 'Online: not in (' .. (o and (o.failed and 'out' or 'joining...') or 'left') .. ')   click a free player (2-4): join there'
end
viewer_console_cmds.host = function(w, port)       -- (stopped: the switch, for the next Play; playing: now too)
  viewer_online_set(true, 'host', port)
  if not PL.playing then return 'online: hosting on Play (port ' .. PL.mode.port .. ')' end
  local ok, p = viewer_online_host(w, PL.mode.port); return ok and ('hosting on port ' .. p) or p
end
viewer_console_cmds.join = function(w, addr)
  if (addr == nil or addr == '') and not PL.mode.addr then return 'join: whose? join("1.2.3.4") or join("1.2.3.4:7777")' end
  viewer_online_set(true, 'join', addr)
  if not PL.playing then return 'online: joining ' .. tostring(PL.mode.addr) .. ' on Play' end
  local m = PL.mode
  local ok, err = viewer_online_join(w, m.addr, m.seat > 1 and m.seat or nil); return ok and 'joining...' or err
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

# Replay: the network

How games play together: what travels, who decides, and the tricks that hide
the lag. Everything here is plain Lua in `runtime/net.lua` (the engine),
`runtime/players.lua` (sessions: the Players button, host and join) and
`editor/udp.h` (the sockets).

Contents:

1. [The model](#1-the-model)
2. [Playing](#2-playing)
3. [Tagging a game](#3-tagging-a-game)
4. [Ticks](#4-ticks)
5. [The techniques](#5-the-techniques)
6. [Writing systems for the network](#6-writing-systems-for-the-network)
7. [Under the hood](#7-under-the-hood)
8. [Testing](#8-testing)
9. [Limits, and what's next](#9-limits-and-whats-next)

## 1. The model

**Classic client / server, for now.** Player 1 hosts: its world is the game.
The other players send it their keys and show what it sends back. They talk
to the host only (a star): a player's keys reach the others through what the
host sends. Later the
same pieces will carry a p2p network (no host to keep). That comes after
the techniques below are solid.

- **The world is a tree** of nodes, and so is everything that travels: a
  state is a saved subtree (a *scope*, `/objects/ball/**`), and an update
  is a diff of it.
- **The game doesn't know about the network.** For it, every player is
  local: keys come with a player number (`on_key(w, key, down, player)`),
  and `w.players` says who is in. Its nodes carry a `replicate` tag that
  says whose they are and how the others see them.
- **One owner per node.** The owner simulates it and sends it. Everyone
  else shows it, by its tag (late and smooth, or guessed and corrected).
  Local writes to a node you don't own are undone.

The layers, bottom up:

| Layer | What it does | Where |
|---|---|---|
| transport | datagrams between ids: `net.sim` (pretend: latency, jitter, loss) or `net.udp` (real sockets) | net.lua, udp.h |
| replica | owns scopes, sends them as snapshot deltas, acknowledged | net.lua `Replica` |
| peer | a world in a session: owns what its tags say, commands, clocks, lag compensation | net.lua `Peer` |
| session | who's in, host / join, the Players button, fixed ticks; each player connected to the host only | players.lua |

## 2. Playing

**In one window (testing).** The **Players** button (bottom bar) adds
players 2..4, each in a quarter of the screen with a world of its own,
over the pretend network. The **Network** button sets how bad that
network is: 100% is perfect, lower is more latency, jitter and loss
(5 presets blended; the wheel moves 1%). Its right-click menu has:

- ghosts: each view also draws, faintly, what the host last sent of the
  nodes it guesses or interpolates (how far off a guess is, how late a
  node is shown);
- the send rate (states a second, default 20; once you pick one it beats
  the game's `config/net.lua` rate, for testing);
- a line per player (one player on a bad link; cut and heal a link).

The Network button works online too: what this editor sends is held, lost
or sent twice as its quality says (100%: the network as it is). Each side
makes its own outgoing worse, so set it on both to make both directions
bad. A player's own line in the menu applies to what goes to that player
(on the host) or to what this player sends (on a joiner). Example: two
editors at 25% measure a round trip of about 450 ms instead of 16.

**Online (real sockets, UDP).** One player hosts, the others join:

The bar's **power** button is the network device: off (the default), the
Players button's players play on one computer (local, over the simulated
line); on, Play goes online and Stop leaves (the switch stays on). It is
set while stopped only (runtime/players.lua `PL.mode`,
`viewer_online_set` / `viewer_online_begin`, called by Play).

With the switch on, the Players button is this editor's seat: P1 hosts,
P2..P4 join as that player (the hello asks the host for that seat; taken:
refused). Playing, the host clicks a joiner to let it go (a `kick`
message), a joiner clicks its own seat to leave or a free one to join
there (`viewer_players_click`).

- Power on + P1, or `host()` in the console, or `play games/pong --host`;
  then Play. The log says the address to give the others.
- Power on + P2..P4 (the address once), or `join("192.168.1.20")`,
  `join("2001:db8::5")` (IPv6), or `play games/pong --join 192.168.1.20`;
  then Play.
- **No ports to type.** A game's ports come from its name
  (`net.ports("replay:" .. game)`: 8 ports in 20000..32767, the same on
  every computer). The host takes the first free one (a second host on the
  same computer, the next); a joiner given no port asks all of them at
  once (`seek`; the first host of this game answers `here`) and 7777, the
  old default. A port can still be given: `host(8000)`, `join("1.2.3.4:8000")`.
- **No address on a LAN.** `join()` broadcasts `seek` on the game's ports
  (255.255.255.255, this subnet's .255, and this computer) from an IPv4
  socket: the first host of this game with a free seat. `lobby()` scans
  the same way for a second and lists every host found (`here` carries
  who's in and the free seats; this computer heard twice counts once).
- `online()` says who's in; Stop leaves the session; `leave()` turns the
  switch off. `host()` / `join()` typed while playing go online at once.

Joiners get the host's world and the next free player (2..4); their keys
are that player's. Everyone needs the same game folder. On a LAN it just
works. Over the internet the host forwards its UDP port on its router (the
log says which), the router opens it when asked, or everyone goes through
an introducer (2.1). IPv4 and IPv6 both work, on
one socket.

### 2.1 Through home routers (runtime/nat.lua)

No port forwarding, no server of ours: an **introducer** runs on any node
with a reachable address (a privileged node's job; `introducer()`,
`--introducer [port]`; its ports by name too: the first of
`net.ports("replay:introducer")` whose next two are free; `room@1.2.3.4`
finds it by asking all of them).

- **Rooms.** The host registers a room (`host("den@1.2.3.4")`, or
  `--via den@1.2.3.4`), again every 5 s (that keeps its router's mapping
  open). Rooms not heard from for 30 s are dropped.
- **Peer IDs.** A room named by a peer ID (`TJHJDJX`: a public key's hash,
  runtime/ed25519.lua) is registered only with that key's signature over
  the challenge the introducer gave the host's address ("replay reg <ID>
  <challenge>"): nobody else can take an ID. Rooms by plain names stay
  open to anyone, as before.
- **What's my address.** The introducer answers each register with the
  address it sees: STUN without STUN (the host's log says it).
- **Introductions.** A joiner (`join("den@1.2.3.4")`) asks for the room;
  both sides get the other's candidates: the public address first, then
  the local one. Each punches to every candidate at once, from the game's
  own socket (a router's opening is per port); the first answer is the
  path. On the same network the local address answers first.
- **Prediction.** Each player also asks the introducer's two probe ports
  (its port + 1 and + 2), one right after the other, where it sees them.
  One port for both: an ordinary router. Two ports a small step apart
  (1..8): a symmetric router
  that counts up, so the introducer adds the next 12 ports in that step to
  its candidates, and the other side punches all of them.
- **The router, asked.** A host asks its own router to open its port
  (runtime/portmap.lua: PCP, NAT-PMP, then UPnP-IGD). If it does, and the
  address is public and the one the introducer sees, that address is a
  candidate too (it works with no introducer at all: `join("1.2.3.4")`).
- **Relay.** No answer in 3 s (random ports, both sides symmetric, a
  firewall): both use a relay port the introducer opened for the pair.
  It forwards whole datagrams, learning a symmetric router's new port by
  its IP. Relays idle for 60 s close.
- After that it's an ordinary join (hello, welcome, the world) on the
  path found.

A game's own: `seek` / `here` (who hosts this game on this port).
Messages are `net.udp` control messages `{ t = "nat", op = who / you / reg
/ meet / intro / nope / punch / punched / open / probe / you2 }`. `nat.inet{}` is a pretend
internet with routers (full cone, restricted, port-restricted, symmetric;
no hairpinning) for the tests.

## 3. Tagging a game

A node's `replicate` component (a `replicate.lua` file in a folder world)
says whose it is and how the others see it. Children go with it: the tag
covers the subtree.

| Tag | Meaning |
|---|---|
| `true` | the host's (player 1's). The others show its last state |
| `2` | player 2's while it plays, else the host's |
| `{ by = N }` | the same, as a table (with the options below) |
| `predict = true` | everyone simulates it (a guess, no waiting); the owner's states correct the guess |
| `interp = true` | not simulated here: shown a little in the past, moving smoothly between the owner's states |
| `delay = 0.1` | (interp) how far in the past, in seconds. Keep it above the jitter |
| `snap = 40` | a number off by more than this jumps instead of sliding (a serve, a wrap around). Or per field: `{ x = 200, r = 3 }` |
| `smooth = 0.1` | (predict) how long a correction takes to ease in |
| `lag = 0.05` | (predict) say the owner's state is this old when it arrives (default: worked out from its stamp and the clocks) |
| `cmd = true` | an input node: sent to the host as numbered commands, one a tick, not as a state |
| `input = N` | (on a host's node) player N's commands drive it: player N predicts and reconciles it |
| `hold = true` | not sent while set (a decision pending: the others keep their guess) |
| `priority = 3` | with a budget (7.1), goes first and more often (default 1) |
| `rate = 2` | its own states a second (else the send rate, 20): for what everyone simulates anyway (asteroids' rocks and shots). Nodes coming or going are sent at once whatever the rate |

pong, the reference (`games/pong/`):

| Node | Tag | Why |
|---|---|---|
| `/data/input/p2` | `{ by = 2, cmd = true }` | player 2's keys: commands to the host |
| `/objects/right` | `{ by = 1, input = 2, interp = true }` | the host's paddle, driven by player 2's keys: player 2 predicts it, the others see it late and smooth |
| `/objects/left` | `{ by = 1, input = 1, interp = true }` | the same, for player 1 (the host) |
| `/objects/ball` | `{ by = 1, predict = true, snap = 40 }` | the host's; everyone simulates it, the host corrects |
| `/data/score` | `true` | the host's: only it scores |

asteroids does the same for its ships (`input = N`, `snap` for the wrap
around). Rocks and shots are the host's, predicted. Sparks aren't
replicated at all: they're an event (5.6). Your own shots show at once as
stand-ins (5.7).

### 3.1 The game's network settings

`config/net.lua` (the `net` component of `/config`), read every update, so a
system can change them while the game plays (`w:node("/config").c.net.rate
= 10`: fewer states when the scene is calm, more in a fight):

| Setting | Default | What it does |
|---|---|---|
| `rate` | 20 | the host's states a second (a node can ask for its own: `replicate.rate`) |
| `bundle` | true | one datagram a peer an update (false: one per message) |
| `keys` | the tick rate | a player's commands (its keys) a second; 30 halves its packets, at about 8 ms more delay on average |
| `budget` | none | bytes of states to a player a send (priorities, 7.1) |
| `hz` | 60 | fixed ticks a second, read when a session starts |

A setting it doesn't give stays as it was (the Network menu's, a test's).
pong and asteroids ship one with the defaults, to edit.

## 4. Ticks

In a session (the Players button, or online), the game ticks at a fixed
rate: 60 a second, numbered. Each frame the viewer runs as many ticks as
the time that passed. A window running at 15 fps (minimized, in the
background) still runs 60 ticks a second, four a frame. A long stall
catches up a quarter of a second at most, and a frame never spends more
than 25 ms ticking: past that the game slows down instead (else slow ticks
make slow frames that want more ticks, down to a few fps). Out of a
session, it's one tick a frame, as before.

Fixed ticks matter because a player's commands are replayed. A tick on the
host and the same tick replayed on the player must be the same step.

A tick, in order:

1. **Keys.** The viewer delivers them (`on_key`); the game writes them
   into its input node.
2. **The world's tick** (`w:tick`): its systems.
3. **The peer's update** (`peer:update(dt)`):
   1. our input nodes become command number `tick`;
   2. the host notes which commands that tick ran with ("used");
   3. receive: states, acks, clocks, commands;
   4. the host loads each player's next command into its world, for the next tick;
   5. enforce: what others own takes their state (interpolated, corrected, or reconciled);
   6. send: our states (at the send rate), our commands to the host (every tick), a clock message;
   7. the clock moves on.

## 5. The techniques

After Gabriel Gambetta's
[Fast-Paced Multiplayer](https://www.gabrielgambetta.com/client-server-game-architecture.html):
its four parts, and how they are done here.

### 5.1 The host decides (part I)

The host owns the round: the ball, the score, the rocks, the ships. A
player sends only its keys. A system that decides something (a point, a
death, a hit) does it only where `w:owns(node)` is true, so the host
decides and the others show it.

### 5.2 Prediction and reconciliation (part II)

- **Commands.** Each tick, a player's input nodes (`cmd = true`) become
  command number `tick`. It goes to the host with every command the host
  hasn't acknowledged yet, so a lost packet loses nothing. An unchanged
  command is sent without its contents.
- **The host applies them in order, one a tick.** If it falls far behind,
  it jumps to the newest but two. If a gap stays for a few ticks, it skips
  it. Every state it sends says which of that player's commands it had
  used (`ack`).
- **The player predicts.** A node its commands drive (`input = N`) is
  simulated at once in its own world: no waiting for the host.
- **Reconciliation.** Each new state of that node from the host replaces
  the player's copy. Then the player's commands since the host's `ack` are
  run again (`w:rerun(scope, dt)`: the node's per-node systems, one tick a
  command). When the simulation agrees, nothing moves. When the host
  disagreed (a wall, a collision only it saw), the node lands where the
  host says, plus the keys since.
- **What it needs.** The node's per-node systems must give the same result
  for the same keys and the same dt. Systems that run once a tick are not
  replayed.

### 5.3 Interpolation (part III)

Other players' nodes (`interp = true`) aren't guessed: their moves can't
be predicted. They are shown `delay` seconds in the past, between the two
states around then.

- **The sender's clock.** Every state carries the time its sender made
  it. Each peer keeps how far the others' clocks are from its own: the
  smallest difference seen, let up slowly. So states that arrive unevenly
  (jitter) still play back evenly. The delay is a playout buffer.
- **`snap`.** A jump bigger than `snap` (a wrap around the arena) isn't
  blended across the screen.

### 5.4 Lag compensation (part IV)

What a player hit on its screen is a hit. Every peer tells the others,
with each clock message, which of their times it is showing of each of
their nodes (`seen`) and its latest command number. The host keeps,
for each node a player's commands drive, its state by the command it ran
on. A system on the host asks:

- `w.net:as_seen(path, t, ours)`: node `path` (another player's, or one
  their commands drive) as it was when that player was looking at our node
  `ours` as it was at our time `t`. nil while they haven't seen that time,
  or the host hasn't run that command yet;
- `w.net:seen(player, ours)`: the latest of our times that player has shown
  of `ours`;
- `w.net:now()`: our clock (the time of the tick being run).

pong's `systems/ball`, on the host: the ball crosses player 2's paddle's
face at time `t`. The host notes where, and holds the ball
(`replicate.hold`, so player 2's guess, already bounced off its own
paddle, isn't corrected meanwhile). When `as_seen` answers, it decides: a
hit bounces the ball from then and there and moves it on to now; a miss
lets it go on (and score). A second at most, then it decides with what it
has. The cost: on the host's screen, the ball enters player 2's paddle for
a moment before it bounces.

### 5.5 Prediction of what nobody's keys drive

The ball, rocks, sparks: `predict = true`. Everyone simulates them; each
state from the owner is compared with our own guess from when the owner
made it (half a round trip ago), and the difference is added to now's,
eased in over `smooth` seconds (or at once past `snap`). "When the owner
made it" is exact: every state carries its sender's time (its tick's), and
each peer knows the other's clock (the offset, less half the quickest round
trip), so a state that arrived late or early (jitter) is still compared with
the right guess. `lag = 0.05` overrides it with a fixed age. Nodes that come
and go in a predicted scope (shots, sparks) arrive and leave with each
state; the rest stays a guess. Discontinuities (a serve, a point) are
decided by the owner only: a player doesn't predict them.

### 5.6 Events

One-shot things (a sound, a burst of sparks, "left wins") aren't state: a
player that guessed them would make its own. `w:event(name, data)` on the
host hands the event at once to `w.on_event` and every system's
`on_event(w, name, data, player)`, and sends it to every player: numbered,
resent until acknowledged (the `evack` of their clock messages), handed on
once and in order. A player's own `w:event` does nothing (only the host
decides), nor does one made while a tick is replayed. A player who joins
later gets the ones after it came. asteroids: a rock broken or a ship
gone is a `boom` event with a position, colours and a seed; each player
makes the same burst itself (`systems/sparks`): a few dozen bytes instead
of every spark's state, every send.

### 5.7 Your own shots at once

A shot in asteroids is the host's: it decides what it hits. Online, your
SPACE also makes a stand-in at once in your world only (`/entities/mine/N`,
not replicated; not again when your keys are replayed: `w.replaying`). When
the host's shot of that number arrives, it takes the stand-in's place (and
position: ours is ahead of what the host sent) and the stand-in goes. The
same pattern fits any spawn a player causes: show it now, let the host's
replace it.

## 6. Writing systems for the network

- **`w:owns(node)`**: true where this world decides for the node (out of a
  session: always). Decide points, deaths and spawns only there.
- **`w.peer`**: our player number in a session (nil: none). **`w.players`**:
  who's in (`{ [1] = true, [2] = true }`; nil: player 1 alone). A player
  who isn't in owns nothing: the host plays it (pong's computer paddle).
- **`w.net`**: the session's peer (nil offline): `now`, `seen`, `as_seen`;
  `w.net.interest = function(player, node) ... end` (7.1).
- **One-shot things are events** (`w:event`, 5.6), made where the host
  decides them; everyone's `on_event` makes what they show.
- **`w.replaying`**: true while a player's keys are replayed
  (reconciliation): don't spawn what you already did.
- **Inputs are data.** Keys go into a node (`/data/input/pN`), tagged
  `{ by = N, cmd = true }`. Systems read them from there, never from the
  keyboard.
- **Per-node systems for what a player drives**, deterministic: same keys,
  same dt, same result. That's what reconciliation replays.
- **Don't predict what's decided elsewhere.** pong's ball scores only
  where the score is owned.
- **Taps.** A command is the input node's contents at a tick. A key pressed
  and released between two ticks is lost unless the game records it (a
  `taps` list, as `games/lcd` does).

## 7. Under the hood

**Messages**: MessagePack (`runtime/msgpack/`: lua-MessagePack 0.5.4,
vendored unmodified, its own test suite passing on LuaJIT, Lua 5.4 and
5.5). Binary, data only: reading one runs nothing. A datagram holds one
or more messages, one after another (bundled: everything for a peer in an
update; the endpoint cuts a long one in pieces).


| `t` | From → to | Fields |
|---|---|---|
| `patch` | owner → others | `i` (the scope's number), `scope` (its name: only until you acknowledged one), `base` (the snapshot it's a delta from, 0: empty), `seq`, `d` (the delta), `at` (sender's time it was made), `ack` (your last command in it) |
| `nak` | receiver → owner | `i`: base (or name) lost, start over from empty |
| `clock` | everyone → everyone, each send | `at`, `acks` (by scope number: the last state I have), `seen` (by scope number: which time of yours I show), `tick` (my latest command), `ack` (your last command I used), `evack`, `echo` / `held` (your last clock, and how long ago: the round trip) |
| `cmds` | player → host, each tick | `first`, `last` (the commands it holds: the ones not acknowledged), `blobs` (by position: only those that differ from the one before) |
| `events` | host → players, each tick while any is unacknowledged | `list` of `{ seq, name, data }`, `base` (what came before isn't for you) |
| `gone` / `gone_ok` | owner → player / back | `scope`: not for you now, drop it / dropped |

**Snapshots.** A snapshot is data (`w:capture(scope)`: `{ scope, nodes =
{ [path] = components } }`; `w:put(snapshot)` loads one). Each owned scope
keeps its snapshots by number until every peer acknowledged a newer one,
and sends each peer a delta from the last one it acknowledged (Quake 3
style): by node, relative to the scope's root (`/5` for
`/entities/rocks/5`), only the fields that changed (`set`, nested as the
components are), the fields gone (`drop`) and the nodes gone (`del`). Loss, duplicates and reordering are fine:
an old patch is ignored, an unacknowledged state is simply sent again.

### 7.1 Sending less

- **Binary**: MessagePack, not Lua text: a number is 1..9 bytes, not 18;
  no escaped text inside text.
- **Only the fields that changed** (`net.delta`): a ship whose `time`
  ticked sends that number, not its whole `ship` component.
- **Scopes by number**: after the first state a player has, a scope travels
  as a small number (`i`), its acks and `seen` too; acks ride on the clock
  messages (no message per state).
- **What everyone simulates, rarely**: `replicate = { ..., rate = 2 }`
  (asteroids' rocks and shots: they drift on their own): twice a second, as
  a correction, and at once when one comes or goes.
- **Interest**: `w.net.interest = function(player, node) return ... end`
  (on the host, from a system). A scope's root node it says `false` for
  isn't sent to that player, who drops it (`gone`); when it says yes again
  the player gets it whole. Per scope (a tagged node and what's under it):
  rocks in one box come and go together.
- **Priorities and a budget**: `peer.replica.budget = 1200` (bytes of
  states to a player a send; nil: no limit). Each waiting scope gains its
  `priority` every send; the highest go first, as many as fit (at least
  one); a sent scope starts again from 0. A low one is late, never lost.
- **Commands**: an unchanged command carries no keys (the host has the one
  before); one message per tick holds all the unacknowledged ones.
- **Clocks**: times rounded to 0.1 ms. A player that sends only commands
  sends its clock with them, not in packets of its own.
- **Bundles**: everything for a peer in an update goes as one datagram
  (states, clock, events, commands): asteroids, 157 packets a second down
  to 81 (the host 21, player 2 60: a command each tick); with `keys = 30`,
  player 2 sends 30.

`peer.replica.stats.bytes[scope]` counts what each scope cost. asteroids
online, 20 states a second, player 2 flying and firing: about 14 KB/s in
all, both ways (was 75): the host's states 6.5 (rocks 1), player 2's
commands (60 a second) 3.7, clocks 3.8, events 0.4. pong: about 9 KB/s.
(Payload only: UDP and IP add about 28 bytes a packet, our header 11; at
81 packets a second, about 3 KB/s more.)

**Datagrams** (`net.udp`): `RPL1` plus who it's from and to; messages
longer than about 1100 bytes are cut into pieces and put together (a lost
piece loses the message: the next state carries it again). Addresses are
learnt from the first packet. A control channel beside the data carries
the session's own messages.

**Sessions** (players.lua): `hello` (a joiner, until welcomed), `welcome`
(your player number, the world), `full`, `roster` (who's in, every second),
`ping` (host and player, every second; 6 s of silence and you're gone),
`bye`. A player only ever talks to the host.

## 8. Testing

All in `runtime/tests/`, run with `luajit <name>.lua` (or `lua5.4`):

| Test | What |
|---|---|
| `net_demo.lua` | three peers keep a world in sync over a bad network |
| `net_links.lua` | per-player links, cut and heal, the send rate |
| `net_players.lua` | pong.lua, two players: keys, ownership, corrections |
| `net_ghosts.lua` | the Players harness headless on asteroids, ghosts, the star |
| `net_udp.lua` | net.udp over pretend sockets: pieces, losses, a replica |
| `net_smooth.lua` | interpolation, jitter, `snap`, predicted scopes that change, `as_seen`, exact ages |
| `net_reconcile.lua` | commands, prediction and reconciliation over a lossy link: no jumps, taps kept, both agree |
| `net_lag_comp.lua` | pong at 150 ms each way: player 2 never misses what it hit |
| `asteroids.lua` | asteroids with two players: shots, hits, rounds |
| `net_events.lua` | events over a lossy link (all, once, in order; a late joiner); asteroids' sparks by event, a stand-in shot |
| `net_bundle.lua` | bundles (packets a second), config/net.lua (bundle, keys, rate changed while playing), the Network button on real sockets (held, lost, doubled) |
| `net_bandwidth.lua` | component deltas, interest (drop, back whole), priorities with a budget, commands without keys |
| `nat.lua` | through routers: each pair of router kinds meets (direct, predicted or relayed), the game's packets both ways, a local address on the same network, what's-my-address, a router's mapping guessed, an opened port, an unknown room |
| `portmap.lua` | (in replay: `--headless --type "dofile('runtime/tests/portmap.lua')@1"`) a pretend router on real sockets: PCP, NAT-PMP, UPnP, a taken port, another NAT in front, nobody answering |

Real sockets, headless, one machine:
`play games/pong --headless --ticks 420 --host 47777` in one shell, and
`play games/pong --headless --ticks 300 --join 127.0.0.1:47777 --key 'w@60-250'`
in another (the suites' "online" line). Through an introducer: the
suites' "routers" line (`--introducer 47790`; `--via room1@127.0.0.1:47790
--host 47791`; `--join room1@127.0.0.1:47790`).

`net.sim{ latency, jitter, loss, dup, seed }` is the pretend network:
`sim:link(id, { latency = 0.3 })` gives one player a worse link,
`sim:cut(a, b)` / `sim:heal(a, b)` take one down.

**Profiling.** `play games/pong --prof` puts where each frame's time goes in
the window title (and on stderr): `tick` is the game and the network
together. The network's share (a peer's update a tick) is about as much as
the game's own tick.

Two copies on one computer: a minimized or background window may run at
5..15 fps. Its ticks keep up (section 4), but what it shows and sends
arrives in bursts. Test on two computers for the real feel.

## 9. Limits, and what's next

- **A player's own state** (a node tagged `by = N` without `cmd`) reaches
  the host only, not the other players: in the star, what the others see
  comes from the host.
- **Interest is per scope**, not per node: a box of rocks is all or
  nothing. Numbers travel as text, unquantized.
- **NAT**: through an introducer (2.1). Not yet: a joiner asking its own
  router for a port, the birthday trick for random-port routers (hundreds
  of probes; they relay), several local addresses (one is sent), more than
  one introducer, an introducer that checks who may register a room. The
  router mapping is IPv4 (PCP's IPv6 firewall pinholes: later).
- **Later, p2p**: host migration, trust (the host checks inputs, signed
  patches), admin nodes that review other games' patches (never their own).

The plan, with what's done struck through, is in
[ROADMAP.md](ROADMAP.md) ("Network plan").

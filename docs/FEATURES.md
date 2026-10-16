# Replay: features

Replay: a live MMO built as a tree of Lua nodes. This file lists what exists today
and what is planned. Legend: ✔️ done · 🧪 works, still rough · 💤 parked (in the code, off) · 🔜 planned · 💡 idea.

Layout: `editor/editor.c` + `replay.c` (the only two C units) and `editor/*.h`
(included by `replay.c`); `runtime/` (the Lua engine); `games/` (demos);
`editor/3rd/` (SDL3, minilua, Lite). Build: `make.bat` (Visual Studio) or `make` (Linux, macOS, MinGW).

---

## World model (runtime/ecs.lua)

- [x] **Tree of nodes** addressed by paths (`/game/players/mario`). Components
  are plain data on a node; nodes are created like `mkdir -p`.
- [x] **Path patterns**: `/a/b`, `/a/*`, `/a/**`, `/**`, and `*` / `?` inside a segment.
- [x] **Systems** are named functions over nodes that have a set of components.
  Re-registering one with the same name replaces it in place (hot reload).
- [x] **Save / load / diff / patch** of any subtree as Lua-literal blobs, mounted
  anywhere (`ecs.save`, `ecs.load`, `ecs.diff`, `ecs.patch`).
- [x] **Code leaves**: systems stored as data (`ecs.code(src)`), so they save,
  diff, rewind and replicate like everything else. Changed source hot-swaps
  the system in its run slot; a removed leaf removes the system.
  - Returns `function(w, dt)` (once per tick), or
    `{ requires = {...}, run = function(w, node, dt), on_key = function(w, key, down, player) }`.
  - A compile error keeps the old version running; a runtime error stops only
    that system until its source changes (`w.code_err`).
- [x] **Systems as real code in scripts**: `local ball = ecs.system(function() ... end)`
  keeps the function's body (its source text) as a code leaf, then
  `w:spawn("/systems/ball", { system = ball })`. Works in Lua and Hurdy scripts
  (`ecs.loadscript` remembers their text). The body must not use outer locals:
  it is checked, because the leaf later runs on its own.
- [x] **Sandbox for code leaves**: only math/string/table/utf8 (copies) and
  safe base functions; no io/os/load/require. Host extras via `ecs.code_globals` (`dd`).
- [x] **Other languages for code leaves**: `ecs.code(src, "hurdy")`
  (`{ __hurdy = src }`), compiled to Lua by `ecs.languages.hurdy` and run in
  the same sandbox. Errors point at the Hurdy line. The Lua target follows
  the runtime (LuaJIT / 5.1 / 5.2 / 5.3+).
- [x] **Global run order**: the root's `order` component (`order.lua` in a
  folder world) is a list of paths/globs. Siblings in the tree and code
  systems sort by their first matching line, then by name.
- [ ] 🧪 **The layout** (a world with `/systems`, `/objects` or `/entities` at its
  root follows it; others work as before). Its roots, in this order:
  `/config` the project's settings (its components, `config/*.lua`);
  `/assets` asset folders; `/data` rules, state, tables; `/classes/<name>` a
  component's defaults (`w:spawn` fills a table component's missing fields
  from them); `/objects` what's placed in the editor (saved);
  `/systems/<name>` a system per node (its code in a `system` component;
  `/systems`' `order`, names, is the run order: drag them in the tree);
  `/entities` what's spawned while playing (in the timeline and the
  network, never written to disk: `w:save(pat, true)`, disk.lua, Save, the
  overrides file leave it out, so Stop and quitting lose it; `/entities`
  folders on disk are neither read nor touched); `/tmp` temporaries (never saved, so never in a
  diff, a snapshot or a network patch; a load keeps them). Only `/objects`
  and `/entities` are live: per-node systems run on them and the viewer
  draws and picks only them. (Named `/s /c /o /e` at first: long names
  read better for students.)
- [x] **Overrides**: field-level difference between two worlds
  (`ecs.overrides`, `ecs.apply_overrides`), used to save edits on top of script worlds.
- [x] **Input**: `w:key(key, down, player)` calls `w.on_key` and every system's `on_key`
  (player: who pressed it, 1..4; 1 when not given).
- [ ] 🧪 **Players, for the game all local**: `w.players` is who is in the
  game, a set (`{ [1] = true, [3] = true }`; nil: player 1 alone). A node
  tagged `replicate = true` is the host's (player 1), `replicate = N`
  player N's, `{ by = N, predict = true }` the same with prediction; a
  player who isn't in the game owns nothing (the host does). With `w.peer`
  set (a network session), per-node systems skip the nodes, and their
  subtrees, another player owns, unless they're predicted.

## Worlds on disk (runtime/disk.lua, runtime/fs.lua)

- [x] **Folder worlds**: node = folder, component = `name.lua` leaf
  (`return { x = 1 }`), code = a `.lua` leaf that returns a system.
- [x] **`.hurdy` leaves**: `name.hurdy` is a code leaf in hurdy. Saving writes
  code back with its own extension; `name.lua` + `name.hurdy` together is an error.
- [x] **Safe names**: anything outside `[A-Za-z0-9_-]` is %-encoded. Foreign
  files (`README.md`, `.workspace.lua`, `.git`) are never read or deleted.
- [x] **Flush** mirrors the world to the folder and rewrites only leaves whose
  *value* changed, so hand-formatted files with comments survive.
- [x] **Read** is all-or-nothing: one bad leaf fails the read with `file: error`.
- [x] **Pull / changes**: apply the folder to a live world; list nodes edited on disk.
- [x] **Pretty output**: one-line tables when they fit; strings one per line
  (paths in `order.lua`, sprite rows).
- [x] `hostfs` (list/isdir/mkdir/remove via SDL3) so fs.lua never shells out.

## Network (runtime/net.lua): simulated and real

- [x] **Transport stub** with latency, jitter, loss, duplication and
  reordering, deterministic for a seed. Same interface as the real one.
- [ ] 🧪 **Real transport: UDP** (`net.udp(sock, id)`, the same endpoint
  interface: send / recv / peers): datagrams `RPL1 from\0 to\0 kind`;
  messages over 1100 bytes cut into pieces and put together (a lost piece
  loses the message: the replica sends its state again); peers' addresses
  learnt from their first packet (or `ep:add`); control messages beside
  the replica's (`ep:control`, `ep.on_control`); packets for another id
  dropped. Sockets: `udp` in the world VM (editor/udp.h, compiled in
  editor/editor.c with the system headers: Winsock on Windows, BSD sockets
  elsewhere; IPv4; `udp.open / resolve / localip / clock / sleep`). Test:
  runtime/tests/net_udp.lua (pretend sockets).
- [ ] 🧪 **Online play, client / server** (runtime/players.lua): one editor hosts
  (player 1: `host()`, power on + P1, or `play <game> --host [port]`, UDP:
  the game's ports by name), others join (`join("1.2.3.4")`, power on + P2..P4 on the Players
  button: that seat, `--join addr`); the bar's power button is the switch
  (off: local players; on: Play goes online, Stop leaves; set while
  stopped); playing, the host lets a joiner go and a joiner leaves or
  changes seat from the Players button: the host sends the joiner its world (a save
  of it) and the first free player (2..4), and every second the roster
  (who's in); every player connects to the host only (a star; was a mesh),
  sends it its keys and gets the host's states. Pings every
  second, 6 s of silence: gone; `bye` when leaving; Stop leaves. The same
  game on every side (checked by its name); one player per editor; the
  joiner's keys are its player's. Works on a LAN; over the internet the
  host's port must be reachable (forwarded). `--headless` plays online at
  the real pace (tests: suites' "online" line: a host and a joiner, the
  joiner's W moves the right paddle on the host).
- [ ] 🧪 **Through home routers** (runtime/nat.lua, no port forwarding): an
  introducer (`--introducer [port]`, console `introducer()`, UDP: its ports by name: any
  node with a reachable address, a privileged node's job) knows each host's
  room, tells anyone where it sees them (what's-my-address) and introduces a
  joiner to a host with every candidate (the public address, then the local
  ones). Both sides punch to all of them at once from the game's own socket;
  the first answer is the path (on the same network: a local address). No
  path in 3 s (a symmetric router): the introducer relays on a port of its
  own. `--via room@intro` / `host(port, "room@intro")` hosts that way,
  `join("room@intro")` / `--join room@intro` joins. Tests: `nat.lua` (a
  pretend internet: full cone, restricted, port-restricted and symmetric
  routers, each pair), suites' "routers" line (real sockets).
- [ ] 🧪 **Ports by name** (net.ports, mario's idea): a service's 8 ports
  come from its name (`net.ports("replay:pong")`, 20000..32767): FNV-1a of
  the name, then name + i times the golden ratio through Thomas Mueller's
  32-bit mixer (a bijection), in pure Lua, the same in C. A host takes the
  first free port of its game's (several hosts on one computer: the next
  ones; Windows' reserved ranges: skipped); `join("1.2.3.4")` asks all of
  them at once (`seek` -> `here`, the first host of this game) and 7777
  (the old default); the introducer sits on the first of
  "replay:introducer"'s ports whose next two are free too, and
  `room@1.2.3.4` finds it by asking all of them. Ports can still be given.
  Tests: `nat.lua` (the same ports on every Lua, an introducer on its 3rd
  port), suites' "by name" (two hosts on one computer, a joiner by
  address alone) and "routers" (no ports anywhere).
- [ ] 🧪 **Port prediction** (runtime/nat.lua): each player also asks the
  introducer's two probe ports (its port + 1, + 2) where it sees them, one right after the other; a router that
  gives each destination the next port (a step of 1, 2...) is symmetric but
  predictable, and the other side punches the next 12 ports in that step.
  A symmetric router facing any other kind: direct (it was relayed). Random
  ports, or symmetric on both sides: the relay. `c:mapping()` -> "same",
  "step N", "random".
- [ ] 🧪 **The lobby on the Players button**: power on, stopped, RMB on
  P2-P4: a menu (editor/menus.h, players.lua `viewer_lobby_items` /
  `viewer_lobby_pick`) of the hosts nearby (address, peer ID, who's in,
  free seats; a scan fills it in), *The first host nearby*, *Type an
  address...*, *Look again*. The tooltip shows this computer's ID.
- [ ] 🧪 **Deepisle** (`games/deepisle.lua`): a roguelite in one file. An
  island (the terrain generator) with three stairs down; three dungeons
  (the dungeon generator), 3, 2 and 3 levels deep, made from a seed as the
  game starts (`w:generate`; levels drawn with in-place `tilemap` rows).
  Walk into a monster to hit it (slimes, bats, skeletons, spiders, ghosts,
  imps, tougher deeper and in later dungeons); weapons (dagger, club,
  sword, spear, axe, mace) wear out with each hit and break to fists;
  chests and bones hold weapons, potions, gold; monsters drop some. Won
  when every monster of every dungeon is dead; R: a new island. The rules
  are data (`/data/rules`), the play is `/data/state` (saves, rewinds).
  Sprites: `games/common/deepisle.png` (`games/common/tools/make_deepisle.py`,
  pixel art as text). Suite: "deepisle" (stairs, a kill, winning, dying, R).
- [ ] 🧪 **Peer IDs** (runtime/nat.lua, players.lua): each computer has a
  7-character ID (Crockford base32: 6 characters and a check one, case and
  I / L / O forgiven, a dash allowed): its public key's hash (`nat.id_of`:
  SHA-512's first 30 bits). The key: an Ed25519 seed in `.network.lua`
  (`key = "<64 hex>"`, from the system's random bytes: `udp.random`,
  RtlGenRandom / /dev/urandom), with its introducers; `id()`,
  `introducers("1.2.3.4", ...)`. Proofs: "replay <what> <ID> <challenge>"
  signed (runtime/ed25519.lua: SHA-512 and Ed25519 in plain Lua, LuaJIT and
  5.4; checked against RFC 8032 and 40 random vectors). An introducer
  registers a room named by a peer ID only with its key's signature over
  that address's challenge (sent in "you"), checked once per address and
  key; its "intro" carries the key. A seek by ID sends a fresh challenge;
  the host's "here" signs it; the joiner ignores (and says) an answer that
  can't prove it. Old random IDs: replaced by the key's (the log says).
  `REPLAY_PEER_KEY` (64 hex): a fixed key, for tests. A host says
  its ID, answers `seek` with it, and registers it at its introducer (a
  room named by the ID). `join("TJHJDJX")`: the host nearby with that ID
  (1.5 s), then `ID@introducer`, else as a computer's name. Tests:
  `nat.lua` (IDs: every one checks, one wrong character never another
  ID), suite "peer id" (nearby, and through an introducer).
- [ ] 🧪 **A LAN lobby** (runtime/players.lua): `join()` with no address
  joins the first host of this game on the network with a free seat
  (broadcast `seek` on the game's ports; `s:broadcast()` in editor/udp.h);
  `lobby()` / `viewer_lobby_scan()` + `viewer_lobby()` list the hosts
  nearby (who's in, free seats). Suite: "lobby" (two hosts, a scan, a
  join without an address).
- [ ] 🧪 **The router opens the port** (runtime/portmap.lua): hosting asks
  the router (udp.gateway(): the default route's next hop) with PCP, then
  NAT-PMP, then UPnP-IGD (SSDP, the description over HTTP, SOAP
  AddPortMapping, with permanent-lease and port-taken fallbacks); renewed
  halfway through the lease, released on Stop and on quit. A joiner
  through an introducer asks its own router too, up to 2.5 s before it
  meets (both sides symmetric: direct when one side's port opened). A private
  external address, or one that isn't what the introducer sees: another NAT
  in front, not used. The opened address is one more candidate for the
  introducer. `portmap()` / `portmap(false)`; `REPLAY_PORTMAP=0` (the
  tests). editor/udp.h gains non-blocking TCP (`tcp.connect`, `tcp.listen`),
  `udp.open(port, "4")` and `udp.gateway()`. Test: `portmap.lua` (a pretend
  router on real sockets: each protocol, a taken port, permanent leases
  only, another NAT in front, nobody answering).
- [ ] 🧪 **IPv4 and IPv6 alike** (editor/udp.h): the socket is IPv6 with IPv4
  mapped in (dual stack: one socket talks to both; IPv4 addresses show as
  1.2.3.4), plain IPv4 where the system has no IPv6; names resolve to
  either; `join("[2001:db8::5]:7777")`, `join("::1")`. (Not tried here: the
  test machine has no IPv6.)
- [ ] 🧪 **Smoother replication** (net.lua): interpolation per node
  (`replicate = { by = 1, interp = true, delay = 0.1 }`: shown `delay`
  seconds late, between the two states that arrived around then: it moves
  every frame at any send rate); a predicted scope whose nodes change (shots,
  rocks, sparks) keeps guessing: each new state brings its new nodes and
  takes the gone ones, instead of the whole scope snapping to the owner's
  state every tick. Test: runtime/tests/net_smooth.lua.
- [ ] 🧪 **Interpolation by the sender's clock** (net.lua): every state carries
  the time its owner made it, and each peer keeps how far the others'
  clocks are from its own; an interpolated node is shown `delay` seconds
  behind the sender's time, so uneven arrivals (jitter) don't show.
  `snap` (a number, or per field: `{ x = 200, r = 3 }`): a bigger jump (a
  wrap around the arena, a serve) isn't blended, in interpolation and in
  prediction's corrections. pong's and asteroids' other players' paddles
  and ships are interpolated now (they were guessed from stale keys: the
  hiccups). Test: runtime/tests/net_smooth.lua.
- [ ] 🧪 **Lag compensation** (Gambetta part IV): each peer tells the others
  which of their times it is showing; `w.net:as_seen(path, t, ours)` gives
  where a player had its node when it was looking at ours as it was at our
  time t, `w.net:seen(player, ours)` how far it has seen, `w.net:now()` our
  clock; `replicate = { ..., hold = true }` holds a node back while a
  decision is pending. pong's host decides the ball's hits on player 2's
  paddle that way (systems/ball): what you hit on your screen is a hit.
  Test: runtime/tests/net_lag_comp.lua (150 ms each way: never misses; with
  it off, it does). As players' keys became commands, `as_seen` also
  answers for a host's node a player's commands drive (by the command it
  ran then).
- [ ] 🧪 **Classic client / server: commands, prediction, reconciliation**
  (Gambetta part II): a player's input node `{ by = N, cmd = true }`
  becomes a numbered command each tick, sent to the host with every one not
  yet acknowledged (an unchanged one without its contents); the host loads
  them in order, one a tick, and its states say which it had used. A host's
  node the player's keys drive, `{ by = 1, input = N }`, is simulated by
  that player at once and reconciled with each host state (its commands
  since the ack, run again: `w:rerun`, per-node systems only). pong's
  paddles and asteroids' ships work so (the host decides everything; shots
  appear a round trip after SPACE). Test: runtime/tests/net_reconcile.lua
  (150 ms, 10% and 30% lost: no jumps, a one-tick tap kept, both agree to
  the last digit).
- [ ] 🧪 **Fixed ticks in a session** (editor/world.h, players.lua): 60 a
  second, as many a frame as the time that passed (a minimized window at
  5 fps still keeps up; a stall catches up a quarter second at most). Out
  of a session: a tick a frame, as before.
- [ ] 🧪 **Round trips from clock echoes**: every clock message echoes the
  last one heard, so a player that owns nothing to send still measures
  its round trip.
- [ ] 🧪 **A star** (players.lua): each player connects to the host only (was
  a mesh); the roster says who's in, no addresses. Test: net_ghosts.lua.
- [ ] 🧪 **Exact ages for predicted nodes**: a state is compared with our guess
  from when its sender made it (its stamp on our clock: the offset less
  half the quickest round trip), not from its arrival less half a round
  trip: jitter stays out of the corrections (net_smooth.lua: 13% closer at
  80 +- 40 ms). Older guesses are dropped after each correction.
- [ ] 🧪 **No slow-frame spiral**: a frame spends at most 25 ms ticking; past
  that a session's game slows down instead of running ever more ticks.
- [ ] 🧪 **Systems after tiny-ecs** (ecs.lua; HELP 4.4): `filter = { any,
  none }` besides `requires`; each system's node list kept (worked out
  again when the tree, w:set/unset or a load changes it; `w:refresh()`;
  twice a second regardless), so a tick walks lists; `on_add` / `on_remove`
  as nodes enter / leave a list; structure changes count between systems
  (a node spawned by one runs in the later ones the same tick); `interval`
  (game time); `active = false`, or an `active` component on the system's
  node (its props row). 3000 entities: 0.97 -> 0.34 ms a tick (LuaJIT).
  Test: ecs_systems.lua.
- [ ] 🧪 **Draw order: layers** (render.h draw_layers, boot.lua
  viewer_layers): a `layer` component (inherited down the tree),
  `/data/layers`' `order` bottom to top, unlisted ones after by name,
  "default" for the rest; one pass a layer, tree order within. asteroids:
  sparks and shots in `fx` over the ships, the HUD in `hud`. (Per-layer
  y-sort: not yet.)
- [x] **Tree**: `New class` on `/classes`' menu; in `/assets`, `/docs` and
  `/saves` folders come before files.
- [x] **select / query / children from a kept order** (ecs.lua): the
  depth-first sorted node list is built once and kept until a node comes or
  goes or the ranks change (was: a walk with a sort at every node, each
  call). Ticks 3..10x faster: pong 0.83 -> 0.11 ms, asteroids 2.6 -> 0.6 ms
  (Lua 5.4); a session's network update 2..4x faster. A pattern's answer
  is kept too while the tree stays the same (asteroids asked for every
  entity once per rock per tick: it grew with the rocks squared), and
  only paths as deep as the pattern are tried.
- [x] **Code leaves looked for only when they may have changed**: a load, a
  spawn or a remove with code in it, `w:set`, a code leaf replaced, the
  order changed, and twice a second regardless (was: every component of
  every node, every tick).
- [x] **A folder world re-read only when a file changed** (disk.lua
  `stamp`: names, times and sizes; hostfs gives them): the twice-a-second
  poll read and compiled every file before. Unchanged files keep their
  value (and plugins' leaves too). Poll: 13 -> 1.6 ms here.
- [x] **Serializing**: identifier checks and long strings (code) quoted once,
  names sorted with the plain sort.
- [ ] 🧪 **Events** (`w:event(name, data)`, `on_event` in systems; net.lua
  `events`): one-shot things handed on at once locally and, from the host,
  to every player once and in order (resent until acknowledged). asteroids'
  sparks are a `boom` event each player turns into the same burst (a seed).
  Test: net_events.lua.
- [ ] 🧪 **Your own shots at once** (asteroids): SPACE makes a stand-in in your
  world (`/entities/mine`), replaced by the host's shot of that number
  (taking its place); `w.replaying` keeps replays from making it twice.
- [ ] 🧪 **Bundles and the game's network settings** (net.lua; NETWORK.md
  3.1): one datagram a peer an update (asteroids: 157 -> 81 packets a
  second); `config/net.lua` `{ rate, bundle, keys, budget, hz }`, read every
  update (a system can adapt them as it plays); the Network menu's send
  rate, once picked, wins. Test: net_bundle.lua.
- [ ] 🧪 **The Network button online**: on real sockets too, this editor's
  outgoing datagrams are held, lost or doubled as its quality says (and a
  player's own line); 100% leaves the network as it is. (It only applied to
  the simulated network before.)
- [ ] 🧪 **A binary, field-level network** (net.lua; NETWORK.md 7): messages
  are MessagePack (runtime/msgpack: lua-MessagePack 0.5.4, vendored
  unmodified, its test suite run on LuaJIT / 5.4 / 5.5; reading one runs
  nothing); snapshots are data (`w:capture`, `w:put`); deltas carry only
  changed fields, nodes relative to the scope; scopes travel by number,
  acks ride on clocks; `replicate.rate` for what everyone simulates
  (asteroids' rocks and shots: twice a second, at once when one comes or
  goes). asteroids online: 75 -> 14 KB/s both ways, pong 9. Export copies
  runtime/msgpack.
- [ ] 🧪 **Sending less** (net.lua; NETWORK.md 7.1): component-level deltas
  (`ecs.diff(a, b, true)`, `merge`), interest per scope
  (`w.net.interest`, `gone`), priorities with a budget (`priority`,
  `replica.budget`, a priority accumulator), commands without unchanged
  keys, clock times to 0.1 ms. asteroids online: 75 -> 50 KB/s; commands
  24 -> 3.5. Test: net_bandwidth.lua.
- [x] **docs/NETWORK.md**: the network in one page (model, tags, ticks, the
  techniques, messages, tests, limits).
- [x] **Replicas**: each peer owns scopes (`/players/alice/**`) and sends
  Quake-3-style snapshot deltas against the last acknowledged state.
  Survives loss, duplicates and reordering.
- [x] Deterministic RNG (Park-Miller), identical on Lua 5.1 / 5.4 / LuaJIT.
- [ ] 🧪 **Peers by tags** (`net.peer(world, endpoint, player)`): a player's
  peer owns the scopes of the nodes tagged for it (`replicate`), new ones
  too, and sends them to everyone; when a node changes hands (`by = 2` and
  player 2 joins / leaves) the old owner stops sending it and the new one
  starts. What others own shows what they sent last (local writes to it are
  undone: `Replica:enforce`), from its owner only. Round trips are measured
  (a patch out, its ack back: `peer:rtt(id)`). `Replica:disconnect`,
  `Replica:disown`, `Sim:close`.
- [ ] 🧪 **Prediction, per node** (`replicate = { by = 1, predict = true }`):
  everyone simulates it (no waiting for the owner); each state the owner
  sends is compared with our own guess from when it was made (`lag`
  seconds ago, default half the measured round trip), and that difference
  corrects now's guess and the ones kept, spread over `smooth` seconds
  (default 0.1): numbers move, anything else that differed takes the
  owner's, nodes appearing / going snap. `runtime/tests/net_players.lua`:
  pong, host + player 2, 10% loss: player 2's paddle (its own) moves at
  once and reaches the host, a client's write to the host's score is undone
  and to the (predicted) ball corrected, the predicted ball is 6 px off the
  host's on average (14 px shown as it arrives), the computer takes over
  when player 2 leaves.

## Viewer / editor (replay.c, editor/editor.c, editor/*.h)

**Running worlds**
- [x] Opens a **script** (`.lua` or `.hurdy` that returns a world), a **save()
  blob**, or a **world folder**. Everything reloads live when files change.
- [x] **Play-in-editor**: starts playing (`--stopped`: on the authored world); Play runs a
  session; Stop drops play changes but keeps file edits made meanwhile.
- [x] **Save**: folder worlds flush to their files; save() blobs are rewritten;
  script worlds get `<name>.overrides.lua` (field-level, applied on load).
- [x] **Standalone mode** (`--standalone`): just the game, every key to the game.
  An exe with no `.c` files next to it runs standalone automatically.
- [x] **RMB on Play** (stopped): runs the world standalone in its own
  process; the editor hides and minimizes, then comes back when the game
  exits. LMB on Play plays; Pause and Resume work with either button. The
  other toolbar and timeline icons take RMB like LMB.
- [x] **Project picker**: with no world on the command line, `games/` is
  scanned (folders, `*.lua`, `*.hurdy`). One project opens directly; more
  show a list with each one's description (README.md or first comment);
  click to open, or the arrows (a gamepad: dpad / left stick) and Enter
  (A / START); ESC (B) quits. A path on the command line skips it. Its
  colours follow the saved Theme (`.preferences.lua`: dark or light).
- [ ] 🧪 **New project** (the launcher's last row; the launcher shows even when
  `games/` is empty): type a name (letters, digits, `_`, `-`; anything else,
  like `.` `?` `$` `:`, isn't taken as typed and says why), Enter makes
  `games/<name>.lua` from `runtime/template.lua` (`{{name}}` in it becomes
  the name) and opens it, with `play.png` copied as `games/<name>.png` (its
  icon: Export uses it); ESC cancels; an existing name is refused. (With a
  single project in `games/` it still opens directly: no launcher.)
- [x] **Renamed exe = game**: `pong.exe` opens `pong/`, `pong.lua` or
  `pong.hurdy` (next to it or in `games/`) and uses `pong.png` as icon.
- [x] Window title = world name. Own frame limiter (`--fps`, else the menu's FPS:
  default the monitor's Hz; slower unfocused / minimized, see the menu).
- [ ] 🧪 **Players** (the button between Rewind and Network; its icon is the
  four players' quarters, lit = in): a click (LMB or RMB) on a quarter
  (top-left 1, top-right 2, bottom-left 3, bottom-right 4; the cross between
  them: nothing) toggles that player, player 1 too: with nobody in, the host runs alone,
  a server ("server (nobody plays)"). While playing they join or leave at
  once; stopped, the choice waits for Play; Stop drops them all. The editor
  always starts with player 1 alone, and the choice lasts the session (never
  saved). The editor's world is the host (timeline, tree, probe,
  breakpoints, debug draw are its); player 1 plays in it; every other
  player is a peer that starts as a copy of the host's world, with its own
  view, placed by its quarter: 1 in, the whole area (no split); 2 in the
  same row (1+2, 3+4), side by side; in the same column (1+3, 2+4), one
  over the other; across (1+4, 2+3), and 3 or 4, the 2x2 grid, each in its
  own quarter (an empty one stays dark). Each view shows what the whole area would, smaller, and is named
  in its player's colour with its measured round trip ("P2 103 ms"). The
  view under the mouse gets the keyboard (framed in its player's colour,
  game view); gamepad N is player N (player 1 alone: every pad). Peers tick
  with the host (pause, speed, breakpoints stop them too), draw nothing on
  the overlay, and say their `dd.log`s as "P2: ...". Folder edits reach
  every player; a reload starts them all again from the host's world.
- [ ] 🧪 **Network** (signal bars, next to Players): the simulated network
  between the players, 0..100%. Presets: awful 0% (400 ms, 25% lost, some
  doubled), bad 25% (200 ms, 10%), fair 50% (100 ms, 3%), good 75% (50 ms,
  1%), local 100%; between two, their numbers blend (99%: 5 ms). Exactly
  100% (the default for now; 75% later) is no network at all: every player
  plays in the host's world, as local multiplayer, exactly as offline. A
  click: the next preset down (awful: local again); the wheel: 1% a notch.
  The bars fill like the old speed bars (partly lit between). Live; lasts
  the session.
- [ ] 🧪 **Network menu** (right-click the Network button; this session only):
  **Ghosts** (each view also shows, faint, the last state the owners sent of
  what it predicts: where its guess is corrected towards; in asteroids, on a
  bad line, the rocks trail their ghosts), **Send rate** (states a second,
  5..60, default 20; acks go at once) and **P1..P4 line** (that player's own
  connection: as everyone's, a preset, or cut; a packet takes the worse of
  its two ends). The button's tooltip shows the rate and the kB/s on the
  network. net.lua: `sim:link(id, {...})`, `replica.rate`. Tests:
  runtime/tests/net_links.lua, net_ghosts.lua.
- [ ] 🧪 **frame N** (the overlay) counts the game's ticks: it stops while
  paused and follows the timeline (a seek shows that time's frame).
- [ ] 🧪 **Speed** is a gauge now (the bars mean the network): the needle from
  x0.01 (left) to x4 (right), ticks at x1..x4.

**Rendering (render components, by convention)**
- [x] `xform`/`pos`, `color` (inherited), `lines`, `tris`, `rect`, `circle`,
  `text` (+ size), `sprite` (ASCII + palette), `ref` (instance of another
  subtree), `bounds` (picking shape), `hidden`.
- [x] Camera pan (drag) and zoom (wheel); reset button.

**Timeline**
- [x] Snapshot every 0.5 s of game time. Click/drag to seek (states between
  snapshots are blended); play resumes from there and drops the old future.
- [x] Drawn as an **fps equalizer**: thin at the target fps, thicker where it dropped.
- [x] **Speed**: click for x1..x4 (rounds up from fractions); wheel for
  x0.01..x4.00 in 0.05 steps.

**Left tab**
- [x] **Tree** in run order; click to inspect; Ctrl+click multi-select;
  drag rows to reorder (writes `order.lua`).
- [x] **Property editor**: scrub numbers (Shift x10, Ctrl x0.1), toggle
  booleans, type Lua literals; multi-selection shows `--` for mixed values.
  Overridden fields are marked. Per-selection Save / Undo.
- [x] **Systems** in the props panel show run order `#n`, line count and
  language; drag to reorder; click opens the file.
- [ ] 🧪 **The left tab is Lite's** (plugins/sidetab.lua, editor/side.h): the
  tree and the properties drawn on Lite's surface left of its pane, with its
  fonts, colours and scrollbars, and its menus for the drop-downs; the data
  stays in the viewer (`host_world(fn, ...)` runs `viewer_*` there,
  `host_tab(cmd, ...)` the host's part). The mouse over the tab is Lite's,
  the keyboard too while a value or the filter is typed.
- [ ] 🧪 **One text editing, Lite's** (plugins/textproxy.lua): while a text
  box types (the tree's filter, a property, a menu's search, the bar's Lua
  prompt, a graph's edit box and comments, canvas.ui fields), an invisible
  editor view (a document of a line, or a few) is Lite's active view: keys go
  through Lite's keymap to its editing commands only (move / select / delete
  by char, word, line ends; cut, copy, paste, undo, redo, select all), the box
  reads back the text, caret and selection and draws them; mouse clicks and
  drags go to the view (placed where the box draws its text). The box's own
  keys first (on_key). The prompt is drawn by C and typed in Lite
  (lite_prompt; host_call "prompt run / leave / older / newer..."). Test:
  runtime/tests/textproxy.lua ("text boxes"), sidetab_typing.lua.
- [ ] 🧪 **One kind of popup menu, Lite's**: the right-click menus, the main
  menu, the Network and lobby menus, the tree's menu and the properties'
  drop-downs are all canvas.menu (plugins/contextmenu.lua), drawn over the
  whole window (`core.overlays`: Lite's surface is the window, its views
  laid out in the pane `host_pane()` gives). C sends a menu as text lines
  and gets the pick back (editor/menus.h, plugins/hostmenu.lua): a search
  box, submenus (a setting's values are one), scrolling when it doesn't fit.
- [ ] 🧪 **Main menu** (top-right of the tab). **Log window** (a checkbox) shows / hides Lite's Log tab (every
  message with where it came from; click opens the file at the line).
  Each click on it saves the settings to `.preferences.lua` next to the exe
  (`return { log_window = true }`). At start: `--log` / `--no-log` win, then
  that file, else hidden. (The tab's own log view is gone.)
  **Confirm close** (a checkbox, off by default): closing a tab with unsaved
  changes, or quitting (the window's close button, alt+F4) with any, asks
  first in an SDL dialog (Save / Save all, Don't save, Cancel); off, it just
  closes and the changes are dropped. Never Lite's status bar prompt.
  Quitting also asks about the world's own unsaved edits (tree, properties:
  the save icon yellow) first, then about Lite's files.
  **Theme**: dark (Lite's own, as it starts: its defaults or what
  `data/user/init.lua` chose) or light (ours: `themes/replay_light.lua`,
  the dark one turned over: the same teal / cyan for the caret, links and
  `+` actions, code hues darkened to read on white; plain code text a soft
  slate `#4f545d` so the colours are the highlights; strings green and the
  warning amber darkened, no yellow on white); a click or the wheel
  switches, at once: the editor, the tree and properties, the bar, this
  menu, and the node graph's canvas (`nodegraph/theme.lua: T.set_light`:
  a cool light grey `#c9ccd1`, its grid `#c1c4c9` / every 5th `#b5b9bf`,
  functions' frames a darker grey; the nodes' bodies `#dfe1e5`, a little
  brighter than the canvas as the dark theme's are, their text dark; the
  headers, sockets and value fields keep their colours, but the yellow
  number pins and loop sockets darken; the wires and grey sockets drawn on
  the canvas darken). The right-click menus (canvas.menu) take the light
  theme's popup colours (white, its selection for the hovered item, dark
  text), as the main menu; the project launcher's background is the
  theme's code background (`background`) in both themes. Saved as `theme = "light"`. Back to
  dark, every colour the light theme set goes back to Lite's own.
  **FPS** (the limit while focused: monitor, its refresh rate, or a multiple
  of 6: the usual ones 12, 18 ... 60, 72, 90, 120, 144, 180, 240), **FPS unfocused** (default 15) and **FPS minimized** (default 5;
  both: "as focused", or 1..60): LMB the next usual value, RMB the one
  before, the wheel a step (6 / 1); the menu stays open. `--fps` wins over
  FPS. A standalone game and test runs (`--shot`) don't slow down. Every
  change is saved to `.preferences.lua` at once. Every item has a tooltip
  (by the cursor) saying what it does and how; while the wheel turns a
  number, it shows at once. So do the toolbar's and timeline's wheel icons
  (opacity, network, speed): their tooltip, with the value, shows while
  wheeling. The wheel never hides a tooltip: it stays while the mouse rests
  on the icon. Once shown, moving within the same icon (menu item,
  timeline, console) keeps it; leaving it, or a click, hides it.
  **Reset editor** asks first (unsaved changes in open files would be
  lost), then deletes `.preferences.lua` and the project's `.workspace.lua`
  (open tabs, graph views, folded nodes, pinned references) and starts the
  editor again with the same command line; the old process quits without
  writing either back.
- [ ] 🧪 **Nothing logged is lost**: every message goes to Lite's log whatever
  is on screen (playing, editor hidden, Log tab closed), so opening the Log
  tab later shows all of it; what came before Lite started is replayed into
  it. Also written as it happens to `.log.txt` in the project folder
  (emptied at each start; never over 8 MB: past it the oldest half is
  dropped and logging carries on, so it always has the latest), to read
  after a run or a crash.

**Inspect**
- [x] Right-click in the game: the instance under the mouse; Alt+right-click:
  the asset/class part it was drawn from. Its source opens in the editor
  (folder: its files; script: the line that creates it).
- [x] Selection outlines; gizmos for every node (toggle); picking debug view.

**Overlay (editor/overlay.h)**
- [x] `dd.*` debug draw from Lua and code leaves: line, arrow, rect, circle,
  tri, cross, text — world or screen space. No-ops in standalone.
- [x] `dd.log` / `dd.warn` / `dd.error`, one atomic entry each, with
  `file:line`. `dd.log("!msg")` adds a compact traceback.
- [x] Stats top-right (fps, zoom/fade or mouse, mode, dpi); messages
  top-left (fading); bottom-right: keys/buttons/gamepad, frame, time + speed + state.

**Console**
- [x] One line of Lua on the live world (`w`, `sel`, `ls()`, `print()`),
  with history and clipboard keys.

**Embedded editor (Lite)**
- [x] Lite runs behind the game area. Two views for now: running (playing or
  paused) shows the **game**, stopped shows the **editor**. A short ESC while
  running stops (back to the editor); in the editor ESC does nothing; a long
  ESC goes to the game. Starts playing (`--stopped`: stopped, in the editor).
- [ ] **Ctrl+O: the system's file dialog** (SDL3's; Windows, macOS, Linux
  with a portal or zenity), starting in the loaded game's folder (a folder
  game: `games/<name>/`), else `games/`; the file opens as a click in the tree
  would (a plugin's file in its plugin). No dialog on the system: Lite's own
  prompt, as before.
- [ ] 🧪 **Gamepads are always the game's**, in any view: buttons reach it like
  keys (`w.on_key(w, "pad a", down)`, `"pad dpup"`..., as the overlay names
  them); the left stick past half way as `"pad left"` / `"pad right"` /
  `"pad up"` / `"pad down"`, the triggers as `"pad lt"` / `"pad rt"`; not
  while stopped. Analog values: no game API yet. Every demo plays with a
  gamepad (dpad or left stick to move, A to jump / fire / play again, START
  to play again).
- [ ] 🧪 **A release goes where its press went**: a mouse button pressed into
  the editor is released there, wherever the mouse is by then and whatever
  the view; any release ends a camera drag, and the drag also stops when
  no button is held. (Before: a right-press on a graph released over the
  game's picture left the graph panning with no button down.)
- [ ] 🧪 **Classes in the property panel**: a node's component that has a
  class (`/classes/<name>`) says "class" on its header row and lists the
  class's fields too: those the node lacks dim (inherited: the class's
  value; changing one sets it on the node), those that differ from the
  class with a teal bar (the tooltip says the class's value; right-click:
  back to it). A value keeps its class's type (typing text into a number
  field is refused: "speed: a number, like in its class"). Selecting a
  class shows who uses it ("used by 2: /objects/a, /objects/b"). Test:
  `runtime/tests/classes_props.lua` (runs the viewer's Lua headless).
- [ ] 🧪 **Class members, described**: a class's components are its members,
  each one value saying its type and start value, and maybe its range or
  options: `hp = { type = "int", value = 10, min = 1, max = 20 }`,
  `mode = { type = "string", value = "slow", options = { "slow", "fast" } }`,
  `tint = { type = "color", value = { 255, 0, 0 } }`. Collections:
  `container = "array"`, `"set"` (`{ [k] = true }`) or `"map"` (keys of
  `type`, values of `values`; never a collection). A folder world writes
  the same thing as one file per member
  (`classes/shot/life.lua`: `return { type = "number", value = 1.5, min = 0.2, max = 5 }`),
  so the script and the folder read alike. A plain value is short for one
  (`life = 1.5`). On nodes they become widgets: min..max a slider (drag;
  steps of a hundredth of the range, or whole; CTRL+click types it; values
  kept in it), options a drop-down, a colour a swatch; values keep to
  their type (an `int` takes whole numbers only). `ecs.member` and
  `ecs.start_value` in ecs.lua. (Replaces the old `meta` component.)
- [ ] 🧪 **Editing a class upgrades its nodes**: change a class's field (in
  the panel, or its file on disk in a folder world) and every node using it
  whose value was still the class's old one (never overridden) takes the
  new one; a value the node set itself (`image = "my_player.png"`) stays.
  A field the class gains is filled where nodes lack it. The log says how
  many values moved. A class's Save / Undo carries its nodes along (they
  changed with it). "Overridden" means "differs from the class's value":
  a node that set the very same value counts as not overridden.
  `w:upgrade_class(name, before)` in ecs.lua does it.
- [ ] 🧪 **Components from a class**: an object (a node under `/objects` or
  `/entities`; not those folders themselves) and a `/data` node get a
  `+ component` row: a drop-down of your classes it has none of, then the
  plain types. A class adds that component, the class's values (copies).
  Right-click on an inherited (dim) field sets it on the node.
- [ ] 🧪 **Typed fields of its own (meta)**: picking a plain type in
  `+ component` (`vec3`, `node`, `int`...) adds a field named after it, its
  name open for typing right away (Enter keeps it), its type's starting
  value, and its type kept in the node's `meta` component:
  `meta = { velocity = { type = "vec3" }, target = { type = "node" } }`
  (a folder world: `objects/ball/meta.lua`). The values stay plain (game
  code reads `n.c.velocity.x`); `meta` holds the same descriptions as class
  members, so the field shows like one: `name [type ▾] [kind ▾]`, its range
  or options, then its **value**. Double-click / right-click the name:
  rename, remove (its meta entry follows; no typed fields left: no meta);
  retype, change its kind, its range or options: its value is kept if it
  still fits. `meta` is reserved (no member, field or class of that name;
  hidden in the panel), and a class's leftover `meta` (the old way) is
  ignored. `/data/rules` can have `win: int 1..20` with a slider, no class
  needed. The graph reads it too: in a script, a `w:spawn(path, { ...,
  meta = { ... } })` table's fields get their widgets (sliders, drop-downs,
  colours) and its meta's entries are "class member" nodes; in a folder
  world, `objects/ball/speed.lua` gets its type from `objects/ball/meta.lua`
  (a slider for a range...), `meta.lua`'s entries and `classes/<x>/<m>.lua`
  are "class member" nodes.
- [ ] 🧪 **New nodes**: `/objects` has `+ object`, `/data` has `+ data`, and
  any node under them has `+ child`: click, type a name (letters, digits,
  `_`, `-`), Enter. The new node is selected (an object starts with
  `xform = { x = 0, y = 0 }`); `+ component` gives it more. `/systems` has
  `+ system`: a node with an empty system
  (`return function(w, dt) end`), last in the run order: click its system
  row to write it.
- [ ] 🧪 **The tree's menu**: right-click a node: **Rename** (a `name` row at
  the top of the panel, typed: Enter renames it and what's below it; ESC
  keeps the name), **Duplicate** (a copy beside it, `ball2`, `ball3`...,
  with what's below it; selected, its name typed at once), **Delete** (it
  and what's below it, after asking; its parent is selected; Undo or not
  saving brings it back). Not for the root, the layout's roots or the
  built-in types. A class renamed renames its nodes' components too; a
  class deleted leaves them as plain components (the question says how
  many). A system renamed or deleted updates `/systems`' run order.
- [ ] 🧪 **/classes is a data editor**: selecting a class shows each member
  in two or three rows, a thin line between members:
  `name type kind` (type and kind: links), then, when it applies, its **range** (numbers:
  type `1..20`, `0..`, `..5` or `none`; both ends make a slider) or
  **options** (text: `w, up, i`, or `none`), then its **default** (last: it
  keeps to the range or options above it; edited with its widget). The kind
  is short: `var`, `[]` array, `()` set, `{}` map ( its tooltip says which, and a map's values), its list says
  `var`, `[] array`, `() set`, `{} map`. It all fits the tab's default width. Double-click the name to rename it, right-click it for Rename /
  Remove (its nodes follow). **type** lists the plain types and your
  classes; **kind** lists single, array, set and map, and map opens a
  sub-list of the types its values can have (its keys: the type; values
  are never collections). `+ member` asks for a name only: the member
  starts as a `bool` (false), and you pick its type after, as in UE5. A
  change keeps the default if it still fits, else it starts again; the
  class's nodes follow (never overridden values upgrade; their own values
  that no longer fit start again, and the log says so). A member of one of
  your classes' type is a copy of that class's members, their widgets
  inside it. Collections, on a class or a node: `+ item` (an array:
  appends its type's start value), `+ key` (a set or a map: type the key),
  right-click an item: out. `/classes` itself has `+ class` (a name;
  `boss ship`: a copy of ship's members); the new class is selected. The
  plain types are classes too, built in ("(built in)" in the tree, after
  your own classes): never saved, not editable, and not a component's class
  (a `rect` component stays yours). ecs.lua: `ecs.BUILTIN`, `w:builtins()`.
  - numbers: `int`, `number`, `angle` (degrees: a slider -180..180, wraps
    around; a range of its own if you give one)
  - text: `string` (options: a drop-down), `key` (a drop-down of input
    keys: space, enter, escape, tab, arrows, shift, ctrl, alt, a-z, 0-9),
    `asset` (a drop-down of `/assets/*`, or none), `node` (a drop-down of
    the nodes under `/objects`, or none; only ones that exist)
  - `bool`
  - vectors, one row typed `1, 2, 3` (or `{ x = 1, ... }`): `vec2`
    `{ x, y }`, `vec3`, `vec4`, `quat` `{ x, y, z, w }` (a rotation: kept
    normalized; starts at 0, 0, 0, 1), `rect` `{ x, y, w, h }` (no negative
    size)
  - colours, a swatch: `color3` `{ r, g, b }`, `color4` `{ r, g, b, a }`
    (0..255). (`color`, 3 or 4, is still understood, not listed.)
- [ ] 🧪 **Drop-downs in the property panel**: a member's type / kind, a
  value's options, a member's menu. Each shows as a link, like the node
  graph's "3 warnings": its value in its colour, underlined, bright under
  the mouse (no box, no arrow: it takes only its text's room). A click
  opens a list under the row
  (the current one marked); an item with a sub-list (kind's map) opens it
  beside the list when hovered; a click picks, a click elsewhere or ESC
  closes it. While open it has the mouse: a hand over its items, the arrow
  anywhere else, and nothing under it lights up or shows a tooltip.
  Typing filters it (any part of a name, any case: `co` leaves `color3`,
  `color4`); a search line sits on top (always on a list of values, an
  enum's options or a type, and on any list of more than 6; a short menu,
  like the kinds or Rename / Remove: once you type), `(none)` when nothing matches. Up / Down / PageUp /
  PageDown / Home / End move, Enter picks, Backspace takes a letter back.
  While a sub-list is open (hovered, or Right / Enter on its item; Left or
  Backspace on an empty filter goes back), typing filters it instead: `{}
  map`, then `ve` leaves `vec2`, `vec3`, `vec4`. A list taller than the
  window scrolls: the wheel, its scrollbar, the keys. The tree's RMB menu too.
- [ ] 🧪 **The graph reads /classes**: `w:spawn("/classes/paddle", { ... })`
  in a script, or a folder world's `classes/<name>/*.lua`, makes `paddle`
  a class in the graph too: a table that is a `paddle` component
  (`{ paddle = { ... } }`) is a `paddle` node with its members' widgets
  (sliders, drop-downs, colours; arrays `number[]`, maps `table<K, V>`) and
  `+ field: type` rows for the members it leaves out (one click: the
  member's value). In the class's own table each description is a "class
  member" node (its type and kind: drop-downs), and the Add menu's Types lists the classes
  (`w:spawn("/objects/x", { paddle = {} })`). The panel and the graph
  share one definition; pong's old LuaLS `local p` demo is gone
  (plugins/nodegraph/tests/playground.lua keeps LuaLS classes for the graph).
- [ ] 🧪 **The properties' right margin**: the rows end 14 px before the
  tab's edge; the scrollbar is drawn in that margin, never over a value.
- [ ] 🧪 **The left tab looks like Lite**: the tree, the properties, their
  drop-downs and tooltips draw with Lite's UI font (`style.font`: the
  same glyphs Lite bakes, uploaded once as textures) and its theme's
  colours: the side bar's background, `text` for names, `accent` for the
  hovered / selected item and headers, `selection` / `line_highlight`
  behind them, values coloured as Lite colours code (numbers, strings,
  literals, keywords), the caret's colour for `+` actions. Rows are as tall
  as the font. A theme or font change in Lite (e.g. `require
  "themes.github"`) shows at once, light themes too. The bottom bar's
  background, icons, timeline and console follow the theme as well, and
  the main menu. Rows start 12 px in (a margin like Lite's side
  bar). Scrollbars as Lite draws them (a 4 px thumb, `style.scrollbar`,
  `scrollbar2` under the mouse) on the tree, the properties and the
  drop-downs: drawn over what they scroll (the profiler's bars too); drag
  the thumb, or the wheel (fine wheels and touchpads add up their
  fractions). Without Lite (game only)
  it falls back to SDL's small font. (editor/ui.h: ui_begin, ui_text;
  editor/editor.c: editor_ui_*)
- [ ] 🧪 **The left tab's width**: drag its right edge (the line between it
  and the editor: a left / right cursor over it, the line bright) to make
  the tree and the properties (the class editor) wider or narrower. Its
  width is saved in `.preferences.lua` (`tab_width`, px, default 216);
  `--tab N` wins. A double-click on the edge: 216 again.
- [ ] 🧪 **The left tab's font size**: CTRL+wheel over the tree or the
  properties makes their font larger / smaller, a px a step (8..32), as
  CTRL+wheel does to Lite's code; the rows follow it. Saved as `tab_font`
  (unset: Lite's UI font, 14 px).
- [ ] 🧪 **Export**: the toolbar's second button (a box, an arrow out of it,
  right after Save) asks for a folder, then puts the open game there, ready
  to share: `pong.exe` (this exe, renamed: with no `.c` files beside it it
  runs standalone and opens `pong/` or `pong.lua` beside it), the DLLs
  beside the editor (`SDL3.dll`), `pong.png` (the game's icon:
  `games/pong/pong.png`, else `games/pong.png`, else `play.png`),
  `runtime/` (its `.lua` modules and `hurdyl/`; not `tests/`, `meta/` or
  the template) and the game (`pong/`, all but its dot files, or
  `pong.lua` and its `pong.overrides.lua`). It exports what's on disk: the
  message says so when there are unsaved changes. Done or not, it beeps
  (the system's sound: `rundll32 user32.dll,MessageBeep` on Windows,
  `afplay` on macOS, `paplay` on Linux, else a terminal bell) and says how
  it went in a message box and the log: OK (where, how many files, how
  big) or FAIL (what failed, gently; nothing outside that folder touched).
  It refuses the editor's own folder and one inside the game. Before it
  asks where, the game stops (if it was playing) and every Lua file it
  reads must compile as saved on disk (what it packs; Play's check, the
  editor's unsaved texts left out): one that doesn't opens at its line,
  with a message box, and nothing is exported. Elsewhere
  than Windows a folder game's exe is `pong.bin` (a file `pong` and a
  folder `pong/` can't share a name). editor/export.h; `--export-dir DIR`
  for tests.
- [ ] 🧪 **The left tab's split**: the line between the tree and the
  properties can be dragged up or down (an up / down cursor over it);
  it's drawn like Lite's draggable splits (3 px, teal, lighter under the
  mouse, aqua while dragged: `style.pane_divider*`), as is the tab's right
  edge; where it is, a % of the tab, is saved in `.preferences.lua`
  (`tree_split`), so it stays for the next session. A double-click: half
  and half again. Lite's own splits too: a double-click on one puts it half
  way (or its `default_divider`).
- [ ] 🧪 **How many nodes a folder holds**: each tree row with children shows
  it after its name, dimmed: `/ (44)`, `data (5)`, `input (2)` (all
  levels below it). The "tree N" header row is gone: the tree starts right
  under the toolbar.
- [ ] 🧪 **Lite's draw commands**: its frame's command buffer (lite.h
  rencache) is 8 MB. A frame that doesn't fit (`exhausted command
  buffer`, printed once) makes the next frame redraw everything, so no
  region is left stale (the dirty rects seen after dragging a tiny graph,
  then maximizing).
- [ ] 🧪 **Project plugins** (`plugins/`, next to `games/`; docs/PLUGINS.md):
  pure Lua. Every folder's `editor.lua` loads into Lite at start
  (`editor/3rd/lite/data/plugins/projectplugins.lua`); every folder shows in the
  tree as `/plugins/<name>`, its data leaves (`files.lua`, `config.lua`...)
  as components you edit and Save back to their files (Undo reads them
  again; never saved with the game). `P.open_with(exts, View)`: those files
  open in the plugin's tab instead of the text editor (the workspace reopens
  it). `P.menu(View, items)`: its right-click menu; `P.source()` /
  `P.reload()`: its code opened here / run again (its tabs swap to the new
  code, their state kept); saving its `editor.lua` reloads it too, and the
  tree's `/plugins/<name>` has `source` and `reload` links. A plugin's tab
  gets the wheel with CTRL too. Test: runtime/tests/plugins_mount.lua.
- [ ] 🧪 **Context menus with a search line** (`editor/3rd/lite/data/plugins/contextmenu.lua`):
  every right-click menu (the text, a tab, the plugins') is the node graph's
  (`canvas.menu` draws and drives them all: one look); it filters as you
  type (every item of every submenu, best first); Up / Down / PageUp /
  PageDown / Home / End, Right / Left into / out of a submenu (any depth),
  Enter, Backspace, Esc. The standard for
  plugins: `menu:register(predicate, items [, key])`, items a list or a
  function building it ({ text, command, info, checked }). A menu or
  submenu taller than the window scrolls: the wheel, a scroll bar to drag,
  the keys keep the selected item in view.
- [ ] 🧪 **Images in Lite**: `renderer.image.load(path)` (stb_image: PNG, JPG,
  BMP, TGA, GIF), `img:get_size()`, `renderer.draw_image(img, x, y, w, h
  [, color])`: a draw command Lite's redraw cache tracks (scaled, nearest,
  alpha-blended, only the visible part drawn).
- [ ] 🧪 **Texture viewer** (`plugins/texviewer`): PNG / JPG / BMP / TGA / GIF
  open in a tab: checkerboard behind (or dark / light), fit or 100%, the
  wheel zooms around the mouse, drag pans, double-click toggles fit / 100%,
  a pixel grid from x8; the file is read again when it changes; its
  `config` and `files` (the registry) are edited in the tree and apply at
  once. Right-click: fit, 100%, zoom, background, pixel grid, reload image,
  copy path, plugin source, reload plugin. CTRL+wheel zooms the image too.
  The checker's squares are a share of the monitor's height (`checker =
  1.5`: 1.5%), so they look the same at any resolution. A `canvas.View`.
  `plugins/texviewer/sample.png` to try it.
- [ ] 🧪 **Canvas API** (`editor/3rd/lite/data/plugins/canvas`; docs/PLUGINS.md): the
  node graph's visual language for any plugin's editor. `canvas.View` (a
  tab with a camera: pan, zoom, fit, grid, RMB menu, save / unsaved prompt),
  `canvas.GraphView` (a node editor: kinds of node, typed pins, wires;
  select, move, connect, add from a searchable menu, duplicate, delete),
  `canvas.draw` (rounded boxes, curves, wires, sockets, checker, fonts at any
  size, `vh` / `vw`: a share of the monitor), the shared colours, `to_lua`.
  The node graph draws with the same shapes and colours. Test:
  runtime/tests/canvas_graph.lua.
- [ ] 🧪 **Markdown viewer, HTML and GitHub's extras**: `<p>` / `<div>` /
  `<center>` (centred lines with `align="center"`), `<h1>`..`<h6>`, `<br>`,
  `<a href>`, `<b>` / `<strong>`, `<i>` / `<em>`, `<code>` / `<kbd>`,
  `<hr>`, `<img>`; task lists (`- [x]` a ticked box, `- [ ]` an empty one);
  web links end in a small arrow (part of the link); the emoji our docs use
  (🎮 ✔️ ✅ 🧪 💤 🔜 💡) drawn as pictures of our own as tall as the text
  (`plugins/markdown/emoji/`, drawn by `tools/make_emoji.py`: the fonts have
  none). Enough for docs/README.md as GitHub shows it.
- [ ] 🧪 **docs/images/**: small pictures for the docs (README, HELP): square
  crops of screenshots, 320 x 320, never scaled (its README.md lists them).
- [ ] 🧪 **Markdown viewer** (`plugins/markdown`): `.md` files open rendered
  on a canvas view: headings (anchors as GitHub makes them), paragraphs,
  bold / italic / code spans, links (`#heading`: scrolls there; another
  `.md`: shown in the same tab, Backspace back; any other file: its tab; a
  folder: its README.md; `http...`: the browser; paths next to the file,
  else from a folder above it or the project's), images (`![alt](file)`,
  `<img src= width=>`, `<br>`: their pixels at the text's zoom, never wider
  than the column; the web's: their alt text), nested and numbered lists (code blocks inside items), fenced code, quotes,
  tables (columns shrink and wrap to fit), rules; HTML tags dropped. The
  text flows to the tab's width (at most `width` px, config.lua); the wheel
  scrolls, CTRL+wheel sizes the text; keys: arrows, page up / down, home /
  end, backspace (back after a link). RMB: back, size, Edit as text (the
  file in Lite's editor), reload, copy path, the contents (sections, their
  headings in submenus; type to find), source. Read again when the file changes. Backgrounds take the
  opacity (the game shows through).
- [ ] 🧪 **/docs**: a folder game's `docs/` (made the first time) as the tree's
  `/docs` root, after `/config`: its `.md` / `.txt` files, in folders
  (`ecs.is_file`: never in the world's save). RMB: New document (`<name>.md`
  with a `# title`, selected and opened), New folder; Rename / Duplicate /
  Delete on disk at once, with Undo. Click: open (rendered). Props: edit,
  title, words and bytes, file. Test: runtime/tests/config_saves.lua.
- [ ] 🧪 **Folders end in `/` in the tree**: a node with children, a layout
  root, a folder of `/assets`, `/docs` or `/saves` (`docs/`, `rocks/`);
  files (`design.md`) and leaf nodes don't.
- [ ] 🧪 **Every tab's menu** (`editor/3rd/lite/data/plugins/tabmenu.lua`, RMB on a
  tab): close it, the ones to its right, the unmodified ones; copy path,
  browse folder; a tab that flips: its toggle (`Toggle graph / Lua`,
  `Toggle preview / text`).
- [ ] 🧪 **"Plugin: <name>" last in a plugin's menus** (after a divider; alone
  when the menu has nothing else): a submenu with its
  common commands: Source (editor.lua and its data), Reload ("restart" for
  the node graph), Settings (config.lua), Files it opens (files.lua), About
  (README.md), Browse folder, and any a plugin adds (`P.menu_items`). On
  every plugin view's right-click menu (contextmenu.lua: `ContextMenu.last`),
  and on the node graph's background menu. Plugins' own "Plugin source /
  Reload plugin" items moved there.
- [ ] 🧪 **Submenus in right-click menus** (contextmenu.lua): an item `{ text,
  sub = items }` opens beside it when hovered (or Right / Enter; Left
  closes it); typing searches their items too ("Plugin: x > Reload").
- [ ] 🧪 **The node graph's settings** (`plugins/nodegraph/config.lua`): grid
  (snap), rebuild delay (typing), the flow's colour and fade, the zoom under
  which nodes are plain boxes, the most zoom, the header colour per kind of
  node. Saved (in the tree or as text): every open graph takes them at once.
- [ ] 🧪 **A bold font for the canvases** (`data/fonts/font_bold.ttf`: Roboto
  Bold 2.137, the same family and version as `font.ttf`, Apache 2.0):
  `canvas.draw.font(px, mono, bold)`. The markdown viewer's bold text and
  headings use it (before: each glyph drawn twice, a pixel apart).
- [ ] 🧪 **Atlas packer** (`plugins/atlaspacker`): an atlas is two files,
  `<name>.atlas.lua` (Lua data: `sources` = files, folders or names with `*`
  next to it, `exclude`, padding, max size, power of two, rotate; and,
  written by CTRL+S, `image, w, h, frames = { { path, x, y, w, h, deg }... }`)
  and `<name>.atlas.png` (the sheet; no `*.atlas.png` is ever packed). Its tab: a toolbar (*+ Add...* with path
  suggestions, files dropped on the tab, *Remove*, *Save* lit while the
  sheet on disk is older, Fit / 100% / Text), the sprites by source with
  thumbnails (hover: `x` out, `+` back in for the left-out ones), the sheet
  as it will be written (C: `renderer.image.compose`) with the hovered and
  selected images framed, and a settings panel (steppers, checkboxes; the
  output; the selected image). Every edit goes into the `.atlas.lua`'s text
  (unsaved, undoable there) and packs again; changed images too. MaxRects
  (best short side fit, the biggest first, turned a quarter when that fits
  better: `deg = 90`), the smallest sheet that fits. The tab flips to the
  text (its own icon: a framed grid). `New atlas` in `/assets` (its
  template). In the game: `image = { "/assets/<name>.atlas.lua", frame =
  "ship" }` (C: the frame, turned back upright; the atlas read again when it
  changes), or any part of a picture with `src = { x, y, w, h }`.
- [ ] 🧪 **Cut atlases** (`cut = "lcd_on.png"` in an `.atlas.lua`): no packing;
  each frame a named part of one picture (`{ name, x, y, w, h }`). Its tab:
  *Find segments* (C: `renderer.image.regions`, every 8-connected patch that
  shows, a frame `seg<n>`), drag on the picture to mark one (asks its name),
  double-click to rename, Delete, Ctrl+S; *Cut from a picture instead...*
  turns a packed one into it. The game: frames by name, and `at = "sheet"`
  (render.h): drawn where the part is in the picture, the picture centred
  on the node.
- [ ] 🧪 **Parcels** (`games/lcd/`): a Game & Watch-like game, offline, one
  player. An LCD "off" picture (glass, printed chutes, every segment faint)
  as the root's image, a cut atlas of the "on" picture (51 segments: the
  worker, parcels by chute and row, breaks, misses, a seven-segment score),
  a node per segment (`at = "sheet"`), a game system on a beat (it
  quickens), an lcd system lighting the segments; taps count (a press and
  its release in one frame). Stopped: every segment shows.
- [ ] 🧪 **Two-part extensions** for plugins (`files.lua`: `"atlas.lua"`):
  `ui.atlas.lua` is the atlas plugin's, not a Lua file's (Lite's
  projectplugins, the tree's `/assets`, its templates, `edit file`). A name
  with a dot is never a world leaf, so it stays an asset.
- [ ] 🧪 **Plugins in several files**: `P.require(mod)` / `require
  "plugins.<name>.<mod>"` load `plugins/<name>/<mod>.lua` (ahead of Lite's
  own plugins); `P.reloadable = false` for one that can't reload live (the
  node graph: a restart).
- [ ] 🧪 **Tabs that flip** (`editor/3rd/lite/data/plugins/tabflip.lua`): the icon left
  of a tab's name shows the file the other way, in place: a Lua file's text
  <-> its node graph, a markdown file's text <-> its preview (which shows
  the editor's text as you type, saved or not, and keeps the place: the
  caret's line one way, the top line the other). Each side is kept for the
  next flip. Icons: a Lua text tab shows two nodes and a wire (to its graph),
  a markdown text tab a book (to its preview); the other view's tab shows
  Lite's text lines (back to the text). The tab's tooltip and its menu's toggle say which. Plugins add
  kinds with `tabflip.register` (docs/PLUGINS.md); the node graph is one.
- [ ] 🧪 **Help** (F1, or the main menu's *Help*, the build's year and month): `docs/HELP.md` (in a plugin's tab: `plugins/<name>/HELP.md` when there is one; next to
  the exe, else the working folder) in the markdown viewer; from the game
  view the view turns to the editor. F1 is the viewer's (never the game's;
  not standalone).
- [ ] 🧪 **Material editor** (`plugins/materials`): `.mat` files as node graphs
  (colour, value, UV, texture, mix, multiply, scale, output), the example of
  a plugin on `canvas.GraphView`. `plugins/materials/sample.mat` to try it.
- [ ] 🧪 **Hex editor** (`plugins/hexedit`): any file, any size: read off disk
  in 1 MiB chunks (eight kept), so gigabytes open at once. Offset, hex, text;
  type hex digits or text (TAB) to change bytes, kept aside (lit) until
  CTRL+S writes only those bytes in place; undo; find hex or text forward /
  back (F3), replace all (the same length: edits; another: the file streamed
  to a copy and swapped), go to an offset, copy the selection, the values at
  the cursor (u8 .. f64, LE / BE). Long searches run in the background with
  their progress (ESC stops). Any file: *Open tab with > Hex editor*.
  Tests: runtime/tests/hexedit_file.lua, plugins_new.lua.
- [ ] 🧪 **Particle editor** (`plugins/particles`): `.pfx` effects (rate, burst,
  max, cycle, loop, emitter shape, life, angle / spread, speed, gravity, drag,
  spin, size and its variety, colours start / end, blend, squares) played live
  in the middle (drag the emitter); fire, smoke, sparks, explosion, fountain,
  rain, snow, magic built in (`samples/`). The simulation (`sim.lua`) has no
  Lite in it: a game can run it.
- [ ] 🧪 **sfxr editor** (`plugins/sfxr`): `.sfx` sound effects. DrPetter's
  sfxr (MIT) ported to Lua (`runtime/sfxr.lua`: the synth, the seven
  generators, randomize, mutate); its sliders, the waveform with a playhead,
  every change played (the editor's sound: `host_audio_play`, editor/editor.c),
  undo / redo, Export .wav. Seven samples (`samples/`). Games play them:
  `w:sound("jump")` plays `assets/jump.sfx` (`runtime/sound.lua` renders it
  once, again when the file changes; `editor/sound.h`: eight voices mixed by
  SDL). Not while replaying (rewind, scrub) nor from a peer's world.
- [ ] 🧪 **Tilemap editor** (`plugins/tilemap`): `.tmap` maps in layers (a
  row of hex cells per line: diffs show the cells changed); Paint (a stamp:
  one tile or a rectangle of them), Rect, Fill, Erase (RMB), Alt+LMB picks;
  layers shown / hidden, added, removed; resize; undo / redo; the cell under
  the mouse. Its tileset: 62 tiles of 16 x 16 in a 256 x 256 sheet, drawn by
  code (`tools/make_tiles.py`), ours, CC0. `map.lua` has no Lite in it (a
  game can read the maps). `samples/island.tmap`. Test: plugins_more.lua.
  In the game: the `tilemap` component, `{ "/assets/level.tmap", layer =
  "ground" }` (or a layer's number; none: all of them), drawn from the node's
  top left in one batch, reloaded when the file changes (edit it while the
  game plays). Its tileset beside the .tmap, or the plugin's own
  (`plugin:tiles.png`: from plugins/tilemap, exported with the game).
  `w:asset("level.tmap")`: the map's data, for the game's rules. A layer
  given in place: `tilemap = { rows = { "0001..", ... }, tileset, tile, size }`
  (maps a game makes as it plays: `w:generate`).
- [ ] 🧪 **Bullet editor** (`plugins/bullets`): `.bullets` files: patterns
  (kind ring / fan / random, count, spread, aim or angle, spin, rate, volleys,
  delay, speed, accel, curve, life, size, colour, sprite, split into another
  pattern at an age), ships (hp, score, size, speed, the pattern they fire),
  waves (when, which ship, count, gap, path: down / sine / dive / zigzag /
  sweep / arc, x, a sweep's height, spacing, mirrored, a pattern of their
  own) and a boss (hp, size, score, phases: from what part of its hp, which
  patterns). The preview: the pattern at a draggable player, or the stage
  played (a Time slider replays it up to a moment). Undo / redo, renames
  follow everywhere, untitled files (the main menu's Plugins >; saved where
  the open game reads them: games/common/ or assets/), Import from... (another
  file's patterns and ships, names made unique), the play field's size in
  the file. The stage (waves, the boss's arrival, sway and phases) is one
  runner in runtime/bullets.lua (`stage_new`, `stage_step` -> events,
  `stage_kill`), used by the preview and by Starfall alike. The
  simulation is `runtime/bullets.lua`, the same in games (`w:bullets(name)`,
  plain-data state: it saves and rewinds; a `bullets` component draws
  hundreds in one batch). Tests: `bullets.lua`, `bullets_edit.lua`.
- [ ] 🧪 **Dungeon generator** (`plugins/dungeon`): `.dungeon` settings
  (seed, size, rooms, room sizes, loops, theme stone / cave / crypt / wood,
  torches, clutter, doors, the map's path, the tileset) make a `.tmap` in
  three layers (ground, decor, top): rooms placed without overlap, joined
  by a spanning tree plus some loops, doors where corridors meet rooms. A
  live preview, undo / redo; Ctrl+S writes the map and reloads its open
  tilemap tab. The generator (`gen.lua`) needs no editor. The stone
  theme's walls are auto-tiles (`auto_walls`: outlined where they meet the
  floor).
- [ ] 🧪 **Terrain generator** (`plugins/terrain`): `.terrain` settings
  (seed, size, scale, octaves, island, the heights of water, beach, hills
  and snow, dry land, trees, flowers, shores) make a `.tmap`: value noise
  (a seeded lattice, smoothstep-blended, octaves), a second noise for dry
  land; bushes, flowers, tall grass, cacti, rocks on `decor`; the water's
  shores as auto-tiles. The second maker of `.tmap` (plugins/chain).
- [ ] 🧪 **A generator's tab** (`plugins/genview`): the settings on the
  right, the map made at once in the middle, what it made and the file it
  writes on the left; Seed / New seed, undo / redo, Save and make, Open the
  map, the chain registration. The dungeon and terrain generators are each
  a gen.lua and a few lines of panel.
- [ ] 🧪 **Auto-tiles** (`plugins/tilemap`): the tileset gains four kinds
  of 47 ("blob" sets: water with shores 64.., stone walls with edges 111..,
  lava with a crust 158.., grass with ragged edges 205..: drawn by
  tools/make_tiles.py, the old tiles unchanged); `tiles.lua` names them
  (`auto`); map.lua `M.autotile` sums the 8 neighbours of the same kind (N
  1, NE 2, E 4, SE 8, S 16, SW 32, W 64, NW 128; a corner only with both its
  sides; off the map counts as the same) and picks the mask's place among
  the 47 (`M.BLOB`): inner corners too. 16-tile kinds (4 neighbours) still work. The
  editor re-picks round each edit (Paint, Rect, Fill, Erase), *Auto-tiles*
  off / on, *Auto-tile this layer*. Tests: `autotile.lua`,
  `dungeon_chain.lua` (paints water, the terrain generator).
- [ ] 🧪 **Plugins that feed other plugins** (`plugins/chain`): a maker
  registers what it makes (`chain.register{ ext, makes, build }`); its
  results carry `made_by`, and the tilemap editor's *Made by* section
  regenerates or opens the source; two makers of `.tmap` now (dungeon,
  terrain). Test: `dungeon_chain.lua`.
- [ ] 🧪 **Game input: the mouse and analog pads**: `w.mouse` (world units,
  buttons held, inside) and `w.pads` (sticks, triggers) every frame; a world
  that asks (`/config` `window.mouse`) gets presses on the game area while it
  plays (no camera drag), `window.cursor = false` hides the pointer there.
  Scripts' assets in `games/common/` (shared; exported with the script).
- [ ] 🧪 **Dialog plugin** (`plugins/dialog`, first take): `.dialog` files, a
  character's lines and the player's answers (`0 Hi! [1,2]`, `1 Yes -> 3`,
  `#topic ...` lines: the answers to "Tell me more about <topic>" once the
  player knows it, `:emote:`, `{...}`, `{wait 2}`, `//` comments; `--` ends a
  conversation: a line leading past it, or back up to an earlier line,
  ends the talk, and the next one starts there). Opened
  as a chart (the lines, the answers beside them, arrows to what's next, the
  topics below; double-click: its line in the text; the tab's icon flips to
  the text, coloured by `language_dialog.lua`; the chart follows the typing).
  **Edited in the chart**, all through the text (undoable): drag a box (its
  place kept as `//@dx,dy` at the end of its line, ignored by games); drag
  from its right edge (a socket) onto a line: a choice of it if it has
  choices, else its `-> N`; onto nothing: a new line `N ...` there, linked;
  RMB: Add answer, Add next line (in the chain), Unlink, Delete line / topic
  (the arrows to it go too), Reset position, New line, New #topic; Ctrl+Z /
  Ctrl+Y, Delete, Ctrl+S. (test: `runtime/tests/dialog_edit.lua`)
  Games: `w:dialog(name)` and `d:begin / update / typed / choices / advance`
  (`runtime/dialog.lua`, one parser for both; its state is world data). Demo:
  `games/fairyland/`. Open questions in its README.
- [ ] 🧪 **Open tab with >** / **Open beside with >**: every way a file opens
  (text, node graph, preview, its plugin, hex), in a tab here or in the pane
  beside (the way it shows: a copy; its other view: kept in step), in a
  tab's, the text's and a plugin view's right-click menu, once each (a tab's
  menu leaves out its view's own items); the tree's assets: both.
  `plugins/openwith.lua`: plugins register more.
- [ ] 🧪 **Main Menu > Plugins >**: the plugins that show a tab, each opened in a
  tab apart (the particle, sfxr and tilemap editors: untitled, saved where
  asked; the others ask for a file). Hovering one: its menu, its commands
  with their keys (`P.commands`: the node graph's Find, Changes and diff,
  breakpoints...; the hex editor's, the tilemap's tools...), then its
  settings, about, source, reload.
- [ ] 🧪 **Node graph: RMB on a chip** (a variable read, left of its pin): that
  pin's menu, as on the pin.
- [ ] 🧪 **Shared widgets** (plugins/canvas): the node graph's popup menus
  (`canvas.menu`), its text field (`canvas.field`), its tooltips and notes
  (`canvas.tip`) are now everyone's; a scroll bar (`canvas.scrollbar`, the
  hex editor's and the panels': drag it); `canvas.ui` gained a list, a
  stepper, a text field and tooltips. The atlas's panels are `canvas.ui`
  now (they were its own); the tilemap's layers are a list, renamed in a
  field. The node graph's own right-click menu got *Open tab with >* / *Open beside with >*. Canvas
  tabs say "Saved" on themselves (`self:flash`). Test: plugins_more.lua.
- [ ] 🧪 **canvas.picker**: the node graph's colour picker, shared (the graph
  uses it, and `canvas.ui`'s colour rows); `canvas.ui:tiles` (a tile sheet
  to pick from); `renderer.draw_image` draws a part of an image (a tile).
- [ ] 🧪 **canvas.ui**: a side panel of widgets for plugins (headings, buttons,
  sliders, checkboxes, choices, colours; it scrolls), shared by the particle
  and sfxr editors (docs/PLUGINS.md).
- [ ] 🧪 **Gizmos for the selection**: the toolbar's Gizmos button shows the
  gizmos of the selected nodes and everything under them (`/` selected: all
  of them, as before).
- [ ] 🧪 **Tree filter**: the box above `/`. Typing shows the nodes whose name
  holds the text (any case) and the nodes leading to them, folded or not;
  with a `/` in it, their paths (`/rocks`: what's under any rocks). Enter
  keeps it, ESC or its x empties it.
- [ ] 🧪 **Game modules and ownership** (runtime/ecs.lua): a code leaf named
  `module` (e.g. `data/lib/space/module.lua`) is loaded with `require "space"`
  from any system, never run as one; edit it and the systems using it
  rebuild (through other modules too). `w:owns(node)`: does this world decide
  for it (the replicate tag, its own or a parent's) or only predict it.
  Test: runtime/tests/modules.lua.
- [ ] 🧪 **Textures in the game**: the `image` component, `{ "/assets/ship.png",
  w = 36, h = 36, color = {...}, smooth = false }` (or just the path): a
  picture from the game's `assets/` folder, centred on the node, turning and
  scaling with it, tinted by `color`. Loaded once (stb_image, an SDL texture),
  read again when the file changes. A missing one: a magenta box.
- [ ] 🧪 **Asteroids** (`games/asteroids/`): two ships against rocks that keep
  coming, who lives longest wins, the record top-centre. Player 2 is a coop
  AI until a second player joins. Textures from `assets/`; over the network
  the host owns the round and the rocks, each player its ship and shots.
  Test: runtime/tests/asteroids.lua (AI vs AI for 4 minutes, and two players
  over a bad simulated network).
- [ ] 🧪 **Starting**: no file = the project launcher; a `.lua` / `.hurdy` /
  folder = a game, it runs; any other file = an asset, opened by its plugin
  (the game it's in loads, stopped; else no world), and exit code -1 when no
  plugin opens it. Opened from the project launcher, quitting the editor
  goes back to the launcher; quitting the launcher quits.
- [ ] **Retina / HiDPI** (on by default; `retina = false` in `.preferences.lua`
  turns it off, read at start; no effect where the display has no more pixels
  than points): the window gets the display's own pixels; everything is laid out in
  points at the display's scale, Lite runs with `SCALE` = the density on a
  surface of real pixels (its text, graphs and previews sharp), the left
  tab's text from Lite's glyphs baked at that size (sharp too); the game area
  and the overlay drawn into textures of the display's pixels (a render
  target keeps its own scale: set to the density), the launcher's window and
  a game played on its own (`--standalone`, an export) too. `REPLAY_SCALE=2`
  tries it in a 2x window (the launcher too).
- [x] **`--help`** (`-h`, `-?`): every flag, printed (the list is
  [CMDLINE.md](CMDLINE.md)).
- [ ] 🧪 **No console window on Windows** (MSVC): the GUI subsystem
  (`/SUBSYSTEM:WINDOWS`, main as the entry); started from a console, output
  still goes there (AttachConsole).
- [ ] 🧪 **Assets in the tree** (`/assets`): a folder game's `assets/` files that
  a plugin opens (texture, material...), never saved with the world; click /
  `edit` opens one in its plugin; `+ folder`, `+ <kind>` from the plugins'
  `templates/`. Test: runtime/tests/assets_mount.lua.
- [ ] 🧪 **The tree's menu** (RMB): `New folder` / `New <kind>` in `/assets`,
  `New node` / `New component` on `/objects`, `/data`, `/systems` and below,
  `New component` on `/config`: the new row is typed at once in props (as
  Rename). `Rename`, `Duplicate`, `Delete` act on the whole selection when
  the right-clicked node is in it (Rename: one after another). Under
  `/assets` (and `/saves`) they happen on disk at once: a rename renames the
  file or folder, a delete moves it into the game's `.trash`.
- [ ] 🧪 **Thumbnails in /assets**: the files a plugin previews (its
  `config.lua`: `thumbnails = "image"`; the texture viewer's are on) show
  under their folder as a matrix of cells, after its other rows: the
  picture (aspect kept; small art in whole pixels) and its name without the
  extension. A cell is a node: click selects (CTRL adds), RMB its menu,
  double-click opens it. Size: the main menu's Thumbnails slider (off,
  16..80 px; drag it, or LMB / RMB / wheel a step), saved as `thumbnails`
  in .preferences.lua (default: off). Each line of cells is a few tree rows
  (viewer_outline's kind `g`), so scrolling and the scrollbar stay in rows.
  Later: animated previews, overlay buttons (play / pause). Test:
  runtime/tests/assets_mount.lua.
- [ ] 🧪 **Undo** (the tree's menu: `Undo <what>`, or CTRL+Z with the mouse over
  the tree / props, not while typing): New, Rename, Duplicate and Delete,
  last first; a multiselect action is one level. A folder game keeps the
  stack on disk: level n is `.trash/<day>/<n>/` (n: its place in the
  stack), with its `undo.lua` (the steps) and the files it moved; the top is
  the highest n, an undo empties and removes it, and the next load reads
  them back. A clean quit forgets the stack (`viewer_history_forget`, from
  replay.c after its main loop): each `undo.lua` goes, a level with files
  becomes `.trash/<day>/deleted-<hhmmss>-<n>/`, an empty one goes. After a
  crash the levels are still there: the next session can undo. Undoing a New
  moves what it made to `.trash/<day>/undone/`. No redo yet. Tests:
  runtime/tests/assets_mount.lua, tree_undo.lua.
- [ ] 🧪 **/config**: the project's settings, as the `/config` node's
  components (`config/window.lua`: `{ w =, h =, title = }`, the game area's
  size and the window's title when it opens; else the root's `screen`).
  Edited in props like any node, saved with Save. Test:
  runtime/tests/config_saves.lua.
- [ ] 🧪 **/saves**: savegames. A game calls `w:savegame(name, t)` (data only,
  a name of `[%w_-]`) and `w:loadgame(name)`; a folder game's go to
  `saves/<name>.sav` (else memory), shown in the tree as `/saves/<name>.sav`
  files (never in the world's save): props show what's in one, `edit` opens
  it as text, the menu renames / duplicates / deletes it. Local to the
  machine (Export leaves `.sav` files out). Asteroids keeps its record there. Test: runtime/tests/config_saves.lua.
- [ ] 🧪 **A Lite frame that fails still ends**: its update and its draw run
  protected (core/init.lua: `core.frame_try`): an error in one view's draw
  leaves just that view short; the frame ends (`renderer.end_frame`, its
  command buffer emptied), the clip stack is reset each frame. Before, the
  first error stopped the frame for good: Lite's area stayed black (only a
  divider line drawn) and the commands piled up to `exhausted command
  buffer`. The error goes to lite's log and `.log.txt` once per distinct
  message (editor/editor.c `host_error`, replay.c logs `editor_error()` when
  `editor_error_seq()` moves). The whole traceback (the error buffer is 8 KB).
  The black area / "exhausted command buffer" / hover glitches came from
  `nodegraph/theme.lua` losing `C.active` and `C.hover` (behind a comment):
  restored; `runtime/tests/theme_colors.lua` now checks every `C.<name>`
  the graph uses exists, in both palettes.
- [ ] 🧪 **A narrow tab's toolbar**: buttons that don't fit before the menu
  are left out, instead of drawn over each other and into the editor.
- [ ] 🧪 **Window changes repaint Lite whole**: maximize, restore, resize,
  shown, another display, fullscreen: Lite redraws everything and sends it
  all, then again 3 and 15 frames later (Windows can drop a texture's
  contents after the event; the text editor, the only part not redrawn
  every frame, kept old pixels).
- [ ] 🧪 **The tree's rows**: drawn as a tree (Windows style): each level has
  a line down its siblings (├ / └ on each row, from `/` down), and a node
  with children has a small `-` / `+` box centred on that line (the box's
  middle pixel is the line's: both come from the same constants in tab.h);
  a stub runs from the line to the name, and an open branch's children
  hang from that stub, 11 px a level. The editor starts with every branch
  closed but `/` (its roots show). A click on the box closes / opens that
  branch (for this session; selecting a node, from the game or a new one,
  opens its branch). In a layout world every root shows, in the layout's order, even
  when it isn't there (dim, empty); `/classes` is dimmed, `/entities` and `/tmp` are
  teal and say "(not saved)"; the roots can't be dragged.
- [ ] 🧪 **Hovering a tree item** while the game runs or is paused and shows
  (opacity over 0%): what that node draws, and its children, outlined in
  teal (the selection stays yellow).
- [ ] 🧪 **`set global`**: an assignment to a name no local declares (a
  global) is titled `set global`, not `set`.
- [ ] 🧪 **A syntax error in a graph shows where it is**: the text doesn't
  parse, the graph is the last good one; the node closest to the error
  (the last statement starting at or before its line) gets a pulsing red
  halo, and the message (top-left, red) is a link: a click glides there,
  selects that node and puts the text's cursor on the error's line.
- [ ] 🧪 **Coloured warnings and errors in Lite**: the status bar's message
  (icon and text) and the Log tab's line are amber for a warning and red
  for an error, the node graph's own colours (`style.warn`, `style.error`
  in Lite's style.lua: the graph's theme takes them from there). The
  viewer's messages map by level (info, warning, error: `core.log`,
  `core.warn`, `core.error`).
- [ ] 🧪 **Play checks that the code compiles first**: every Lua file the
  game reads (the script, or every `.lua` / `.hurdy` file of the world
  folder, and every module it required), as the editor has them (unsaved
  text wins). The first one that doesn't compile: logged with its
  `file:line` (a click in the log opens it), shown in the editor (its graph
  if one is open and has nodes: that line's node selected and centred, the
  message flashed on it; else its text, cursor on that line), and the game
  doesn't start. Rewind (when stopped) checks too. Test:
  `runtime/tests/play_check.lua`.
- [ ] 🧪 **Play uses the editor's unsaved files**: Play runs the game as it is
  on disk, except files changed in the editor and not saved yet: those win
  (like UE), so small changes show live before saving. The world is built
  again from them when they change what the game reads (scripts, required
  modules, folder worlds, systems' source), the viewer's own edits since it
  was loaded go on top, and the log says "play: with the editor's unsaved
  changes". Nothing is written. (`viewer_unsaved`: reads through io.open and
  require see the editor's text.)
- [ ] 🧪 **The view is the game's opacity** over the editor (the 2nd toolbar
  button, an eye), in any state: 0% the editor only, 100% the game only, between:
  the **mixed** view. Layers: the game (with its overlay: selection,
  gizmos) at the back, Lite on top; Lite's backgrounds (views, the current
  line, the active tab, the minimap, canvases: node graph, materials, the
  texture viewer's checker and grid) take 100% minus the opacity as their
  alpha, so the game shows through; text, selection and popups stay opaque
  (Lite renders premultiplied ARGB from transparent; `lite_bg(c)` in
  replay.lua). Each state keeps
  its own: playing starts at 100%, paused at 75%, stopped at 0%. A click
  cycles 0% (editor) -> 75% (mixed) -> 100% (game) (from another value: the
  next one up), the wheel 5% up / down; the tooltip says which.
  Play/pause only moves time. Input follows the view: the game view (100%)
  gives the game the mouse and the keys (RMB picks); mixed and editor give
  them all to the editor (keys the game held are released when it loses
  them). Gamepads always go to the game. ESC stays the viewer's (short:
  stop; held: the game's ESC). The flow
  (orange wires, beads, values) shows whenever the game runs or is paused
  and its opacity is under 100% (at 100% the editor is hidden: none). Stopped, keys never reach
  the authored world. ESC while running still stops.
- [x] Lite's Log opens as a tab (one only); tab close buttons; Hurdy syntax highlighting.
- [ ] 🧪 **Node graph view** (`plugins/nodegraph/`, a project plugin since
  2026-10-14; it was in Lite's folder): a Lua file as a
  graph, in a Lite tab beside its text. Right-click in a Lua file (editor view)
  > "Open as node graph". One node per statement (expressions as code),
  functions as frames, control flow top-down (branches side by side, loops
  indented with a wire back), nested functions as their own frames. Hover a
  node: its data wires (where its values come from / go). Click: jump to the
  line. Rebuilt live as the text changes; a syntax error keeps the last graph.
  Lua only (Hurdy later). The tab is restored with the workspace.
- [ ] 🧪 **Diff changes since opened (graph diff sketch)**: "N changes" top-right
  of a graph (teal, a link like the error / warning / breakpoint counts)
  opens a list of the texts the graph was rebuilt from (newest first, time
  and "line 45: +2 -1"). Undo takes one off the count and the list, redo
  puts it back (each state keeps the document's undo position); a new edit
  after an undo drops what was undone. Kept per document: a graph tab closed and opened again
  keeps it; a document already changed when its first graph opens starts
  from the file as saved. A click on one diffs that state against now, on
  the current graph: added nodes outlined green, changed amber, removed ones
  as red ghosts where they were, moved ones (dragged: their offsets changed)
  also where they were, at 25%; a second click or the list's [x] goes back
  to the graph as it is. Nodes pair by kind, title and which of the alike.
  64 states. In `nodegraph/diff.lua`, apart, to become a plugin with its own
  tab later.
- [ ] 🧪 **The workspace is relocatable**: `.workspace.lua` keeps files inside
  the project folder relative to it (`./games/pong.lua`), so the project can
  be moved or its folder renamed; files outside it stay absolute. Always
  with `/` (Windows takes it too): the same file on every platform.
  `.preferences.lua` holds no paths.
- [ ] 🧪 **Graph layout lives in the source**: drag a node (or a function's header)
  to move it, right-click it to cycle its colour. Written as comments through
  Lite's document (undo works): `--@node dx=60 dy=20 color=#e06c75 alpha=0.6`
  on its own line above a statement, `--@frame dx=40` at the top of a function
  body. Code sharing its line takes inline ones right before it:
  `if hit then --[[@node dx=48 dy=72]] tp = 0 end`, a one-line function
  `function(who) --[[@frame dx=40]] print(who) end`, an `until` or
  `elseif` that doesn't start its line. Expression nodes: `--@expr slot=2`
  for the one feeding pin 2, `slot=3.2` for the one feeding pin 2 of that
  one (`math.sqrt` inside `string.format` inside `dd.text`). Every node can
  be moved: `runtime/tests/nodegraph_moves.lua` drags each node of every
  file headless (move, move again, back: the text as it was); tests.lua runs
  it on tests/. Far out (under 40% zoom) the sockets don't take clicks, so
  a drag always moves the node. dx/dy are offsets from the automatic layout, so placed nodes keep
  their spot when other code changes. A frame (a function) and floating code
  carry everything in them; a node moves alone (UE style: its expression
  inputs, an `if`'s branches and a loop's body stay). The automatic
  layout snaps every node to the grid; an override (dx / dy) applies on top
  exactly as written, and floating code keeps its own place. An `elseif`
  keeps its tag on the line above its `elseif`. Dragging back to 0 removes
  the line.
- [ ] 🧪 **Edit expressions in the graph**: click a node to select it (every text
  view of the file follows: one in another pane is brought up, one in a tab
  of the same pane scrolls there too). The other way too: a click in the text
  selects, in every open graph tab of the file, the innermost node holding the
  clicked code (an expression node over its statement, a statement over its
  function) and scrolls it into view if it's off screen; double-click its expressions — or the title of a `set` for its
  targets — to edit them in place (Enter applies, a click elsewhere cancels).
  Only that span of text is rewritten, and only if the whole file still parses
  (otherwise the error shows and you keep editing); comments and formatting
  elsewhere are untouched. Undo works. Expressions holding a function are
  edited inside that function's own frame.
- [ ] 🧪 **Rename variables in the graph**: double-click the title of a node that
  declares names — `local a` (no value), a loop's variables, a function header
  `name(params)` or a lambda's `(params)` — and type the new names. The
  declaration and every use follow, by Lua's scoping rules (`resolve.lua`),
  not by text search. The edit is refused if any name would end up reading a
  different variable (a capture, or hiding a global such as `math`).
  A "new local" (`local x = …`) renames on its pins instead: double-click a
  variable's name, or RMB on its row > "Rename variable b" (its title isn't a
  name). A "set" (`p.speed = 3`) works the same way: double-click a pin's name
  to change what's set (`p.mode`), its box to change the value; the title
  edits nothing.
- [ ] 🧪 **Flow pins (UE style)**: statements have a white flow input (left of the
  header) and flow outputs (right): one unnamed for plain statements,
  `then` / `else` for if and elseif, `done` / `body` for loops (titled
  `for`, `for each`, `while`; the loop variables are output pins), `body`
  for repeat and `done` for until; return / break end the flow; a
  function's header starts one. White wires join them (filled pins are
  wired, hollow ones aren't). As in UE, a loop body's end isn't wired back
  to the loop. A `goto` has a faint wire to its label (same function). A
  function definition isn't a step of the flow around it.
- [x] **Node graph tests**: `runtime/tests/tests.lua` checks the parser, layout,
  names and diagnostics headless on every game file; `runtime/tests/nodegraph_ui.lua`
  drives the editor itself (clicks, drags, menus, keys; 41 checks):
  `play games\pong.lua --stopped --lite "dofile('runtime/tests/nodegraph_ui.lua')@3" --frames 900 --shot ui.bmp`.
- [ ] 🧪 **Rebuild pacing**: typing in the text rebuilds the graph once the typing
  pauses (0.2 s); edits made in the graph rebuild it right away.
- [ ] 🧪 **Start node**: every graph has a red "start" node at the top left: the
  file's flow (what runs when it's loaded) begins there. Wiring its flow out
  into floating code puts that code first in the file.
- [ ] 🧪 **Deleting (UE style)**: the Delete key or RMB > Delete removes the
  selection after disconnecting it: reads of the variables a deleted
  statement declared become `nil` (and show their red error), the
  statements after it in its block lose their flow in and float (they stop
  running) instead of joining up with what came before; a deleted
  expression node leaves `nil` in the pin it fed, and only it goes: the
  expression nodes that fed it stay, as floating code where they were
  (`math.max(-lim, math.min(...))` deleted: `-lim` and `math.min(...)`
  float, ready to wire elsewhere; a call floats as `(f(x))`, a value with
  its result pin, and goes back in as `f(x)`); floating code goes whole.
  The same for statements: their expression nodes stay, floating; a
  deleted branch or loop (if, while, for, repeat, do) takes only itself:
  its bodies float where they were drawn, and an if's `elseif ... end`
  chain floats as an if of its own. An elseif can be deleted on its own
  (its clause goes, its body and condition float). Code sharing its line
  (`if c then b.hidden = true return end`) deletes just its text. Checked
  by deleting every node of pong.lua, plugins/nodegraph/tests/playground.lua and
  plugins/nodegraph/tests/move-00.lua in turn, each time checking that the file still parses,
  no floating code breaks and no node is lost. A repeat and its until go
  together: select both (either alone refuses). A label goes alone: the
  flow runs on through where it was (a goto to it then shows "no visible
  label"). A function's header takes the whole function (and its `---@`
  lines); a lambda's header leaves `nil` in its pin. A call statement of a
  deleted function reads `;(nil)(...)` (the `;` keeps the line above from
  swallowing it). Select all + Delete empties the file of code. An
  expression inside floating code (an `ipairs`'s table) deletes on its own,
  like in the flow. A
  function written into a deleted statement floats as its frame (its body's
  nodes shown; its `fn` out wires it back). Floating code keeps its names
  (only live code reads `nil` for a deleted variable; a write keeps its name).
  What's left keeps its place: the nodes that would slide into the room the
  deleted ones took get offsets (`--@node dx=`) holding them where they were
  drawn (one undo brings it all back).
- [ ] 🧪 **Floating nodes**: the Add menu (RMB on the background) drops the new
  statement right under the mouse, out of the flow (it doesn't run until
  wired; its flow in stays hollow). It's kept in the text as a comment block,
  `--[==[@float dx= dy= ... ]==]`, right before the end of its function (or of the file), placed
  from the function's header. Drag a flow out (white) onto its flow in (or
  its flow out onto a statement's flow in) and the code moves into the flow
  there: after the statement; first in a `then` / `else` (an `else` is added
  when there is none) / loop body / function. ALT+click a statement's flow
  in (or the wire into it) takes it and what follows it in its block out of
  the flow: they float where they were (refused while something after them
  reads what they declare). Floating code can be dragged, coloured and
  deleted (RMB); its values wire among themselves. A bare expression floats as
  just its node (the Add menu's Table and Math expression): wire its result
  into an input and it moves into that pin (in parentheses only where
  operators or indexing touch it).
- [ ] 🧪 **Keys**: ctrl+s saves from the graph too (ctrl+z still undoes after a
  save); F3 / shift+F3 find the next / previous node matching the last
  ctrl+f search (with the box open: the next / previous result); ctrl+d
  deselects all (as ctrl+shift+a, or ctrl+a twice); ctrl+shift+n or
  ctrl+shift+t duplicates the current tab, text or graph (same file, a new
  tab beside it, keeping its scroll / pan and zoom).
- [ ] 🧪 **Hex colour strings preview their colour**: a literal like
  `"#ff965a80"` (also `#rgb`, `#rgba`, `#rrggbb`) gets its box tinted with
  that colour (alpha blended over the field), its text black or white after
  how light the result is. A click opens the colour picker (square, hue,
  alpha when the string has it, a hex row); it writes `"#rrggbb"` (`aa`
  kept) and stays open. A double-click still edits the text.
- [ ] 🧪 **Colour squares**: a node's menu (RMB) has a row of small squares,
  the palette; a click colours the node (or the selection), the first one
  (crossed) takes the colour off; the current one is ringed.
- [ ] 🧪 **Find (ctrl+f)**: a box in the graph's top-right corner. Typing
  filters every node by its title, code and pins' names (`speed` finds the
  local that declares it), fuzzy and best first (`mth mn`:
  math.min), each with its line. The best one is shown at once: selected,
  the camera glides to it, and the text beside (if open) goes to its line.
  Up / down go through the others (wrapping), page up / down a page at a
  time and home / end to the first / last (no wrap; the Add menu's search
  too); enter or a click keeps it and closes;
  ctrl+f again or a click elsewhere closes.
- [ ] 🧪 **Search in the Add menu**: a box on top; just type and every item of
  every submenu is filtered, fuzzy and best first (`math e`: Math
  expression, then math.huge, math.ceil), each with where it lives
  (Values, Library > math); items also answer to their aliases (`eval`,
  `loadstring`: Load (code); `loop`: the loops; `log`: print). Up / down choose, enter or a click adds it,
  backspace erases, ctrl+backspace clears. Also in the menu of a flow wire
  dropped on the background.
- [ ] 🧪 **The Add menu** (RMB on the background) has submenus (hover opens them;
  a long one scrolls with the wheel): **Flow** (if, while,
  repeat, numeric and generic for, do, break, return), **Variables** (local,
  `<const>`, two locals, functions, **Load (code)**: `local chunk, err =
  load("...")`, a string of Lua made a function), **Values** (math, comparison, and / or,
  not, `#`, `..`, literals, tables, lambdas, a call), **Types** (each
  `---@class` of the file: a `---@type Name` local with its required fields,
  already a typed table node while it floats), **Functions** (a call of each
  function the file defines at its top level, `M.f`, `M:method` and table
  fields included; arguments start at their `---@param` type's default or
  `nil`) and **Library** (base, math, string, table).
- [ ] 🧪 **Clipboard and undo** in the graph: ctrl+c copies the selected nodes'
  code (found in the source: whole statements, floating code, expressions; in
  text order, layout tags left out); ctrl+x copies and deletes (UE style,
  like Delete); ctrl+v drops clipboard Lua under the mouse as floating code
  (wire it in to run it); ctrl+z / ctrl+y (or ctrl+shift+z) are Lite's undo
  / redo of the file, one graph action a step. While a field is being
  edited, the keys edit the field.
- [ ] 🧪 **One If node**: the menu has a single If (then / else outs, like UE's
  Branch); an `elseif` is drawn as an if wired into the else before it.
  Wiring a floating `if` into the last (empty or missing) else writes it as
  `elseif`; wiring other code into an else that leads to an elseif splits it
  (`else <code> if ... end`); ALT on an elseif floats it (with what follows
  it in the chain) as an `if ... end` of its own. Names keep their bindings.
- [ ] 🧪 **Rows that wrap**: a function's flow runs left to right and wraps onto
  a new row once it passes 16000 px from where its body starts (graph.lua
  `WRAP_W`); the flow wire snakes back to the left in the gap above the row
  (ALT+click works on it like any other). A statement moves whole, with its
  expressions, branches and lambdas.
- [ ] 🧪 **Variable chips instead of busy wires** (UE's "get" nodes): a
  function's parameters, and any variable read 4+ times (graph.lua
  `CHIP_READS`), get no wires. Each pin that reads one shows a chip with its
  name on the node's edge, left of the socket like a pin (the layout keeps
  room for it), and the function header shows its parameters as chips.
  Hover a chip: the variable lights up everywhere (every chip, its
  declaration) with its wires and a tip ("w - parameter of run - read 4
  times"); click it to keep it lit (click again, or the background, to
  stop). Drag from a chip to rewire that pin, like from its socket;
  ALT+click a chip to remove that wire (the slot becomes `nil`).
- [ ] 🧪 **Far reads are chips, getters**: a variable read more than 40 lines
  below its declaration (graph.lua `CHIP_LINES`) shows as a chip too, not a
  long wire (pong.lua's last `w:spawn`: input, paddles, ball, score, banner).
  The Add menu has a **Get** group, a getter per variable visible where it
  lands (`get ball`, found by typing "get ba"): on the background, the
  file's top-level locals; on a function, its own variables first (marked
  "here"), then the ones around it; locals inside other functions never.
  It floats as a small `get ball`
  node; wire its out into any input and that input reads `ball` (refused
  where ball isn't visible), and the get node stays there, wired into it
  (no chip, no long wire), kept by a tag: `--@expr slot=3.3 get=ball`
  (slot 3.3: pin 3 of the node feeding pin 3). Move it like any node;
  ALT+click the pin and it floats again; delete it and the pin reads nil.
- [ ] 🧪 **Typed pins and wires**: when a value's type is certain, its sockets and
  wires take a colour: boolean red, integer orange, number (float) yellow,
  string green, table blue, function teal, nil grey; hover a socket for its
  type. Known from literals, operators (`a / b` is a number, `..` a string,
  comparisons and `not` booleans, `#` an integer), `---@param` / `---@type` /
  `---@return`, numeric `for` and `ipairs` indices, some library calls
  (`math.floor`, `tostring`, `string.*`...), and variables never written
  again after their declaration (a reassigned one stays uncoloured).
  Arithmetic on unknowns stays unknown (tables can have metamethods).
- [ ] 🧪 **Compact expression nodes**: a one-line expression shows its inputs'
  names in a column, its code right of them and its result at the right
  edge (no "result" label). Plain expression nodes are titled "expression"
  (clipped when the node is narrower). Checkboxes are a green tick, no `true` / `false`.
- [ ] 🧪 **"set" nodes**: an assignment shows as "set" with one input per value,
  named after what it's written to (`score.serve`); several targets, several
  pins. "new local" has a "+ add value" row: `local a = 1` becomes
  `local a, value = 1, 0`.
- [ ] 🧪 **Comment boxes**: select nodes > RMB > "Add comment" frames them in a
  dashed, tinted box (`--@comment dx= dy= w= h= title=...` at the top of
  their function's body). Double-click the headline to name it, drag the
  headline to move the box with the nodes inside it, RMB on it to rename or
  delete it (its nodes stay). The box wraps the selection wherever it is:
  nodes of a one-line function, or of several functions, get their box in
  the function around them all (or the top level). Gray unless coloured.
  Resize it by dragging an edge or its bottom-right corner (a small grip);
  the left / top edges move it too. Never smaller than 80 x 50. Its title
  can have several lines: SHIFT+ENTER while naming it (`\n` in the tag,
  which stays one line).
- [ ] 🧪 **Keys bound for other views don't eat typing** (Lite's keymap): a key
  only counts as taken when its command ran, so space, letters and digits
  bound by a plugin (the particle editor's space, the tilemap's B R F E 1..9)
  still type text everywhere else. While a right-click menu is open its keys
  (arrows, Enter, Escape, backspace) come first.
- [ ] 🧪 **"new local" nodes**: `local x = …` shows as "new local" with an input
  pin named `x` (several names: one pin each); its output, the variable
  wired to its readers, carries no label.
- [ ] 🧪 **Expressions apart from statements (UE-style pins)**: a statement node
  has one input pin per slot: `return` value(s), `if` / `while` condition,
  `for` start / stop / step, `local` / assignment value(s) and target, a
  call's arguments (named after a local function's parameters, else arg1..).
  A variable is a wire from where it is declared; a literal (or a global's
  name) sits in a box on the pin, double-click to edit it; anything else
  (`2 + 3`, `a.b * sin(t)`) is an expression node of its own, left of the
  statement, wired into the pin. The text doesn't change: `return 2 + 3` is
  still one line. Dragging a variable onto any pin replaces what fed it;
  ALT+click on a pin or its wire leaves `nil` there.
- [ ] 🧪 **Call nodes**: a call feeding a pin is a node of its own (`math.max`,
  `w:query`, `add`): its arguments are pins (named after a local function's
  parameters), its results are outputs; calls inside calls nest further left.
  Arithmetic and other expressions stay one "expression" node.
- [ ] 🧪 **Table nodes (property sheets)**: a table constructor feeding a pin is
  a table node: a row per field (`name`, `[1]`, `[key]`). Literals get
  widgets: booleans a checkbox (click), numbers a field you drag sideways
  (integers by 1, decimals by their last digit), strings a field
  (double-click edits); `{ x = .., y = .. }` / `{ 1, 2 }` show as one row of
  number fields, `color = { r, g, b }` as a swatch + fields, and a click on
  the swatch opens a colour picker (saturation / value square, hue bar).
  Variables, calls and expressions in fields are wired in like any pin;
  nested tables are table nodes of their own; a field's function hangs below,
  named after the field. Each change rewrites only that literal (undo works).
- [ ] 🧪 **Editing a table's shape**: "+ add field" at the bottom asks for a type
  (number, string, boolean, vector, colour, table, function) and adds a
  field with a free name and that type's start value (`color = { 255, 255,
  255 }`...); in a list it adds just the value; in a one-field-a-line table
  on a line of its own. RMB on a row: "Make <field> a <type>" replaces its
  value (a colour also renames a key without "color" in it, so it shows as
  one), "Remove field" removes it with its comma (its whole line, comment
  included, when it had one); double-click a field's name to rename it.
  Tables over 12 fields show their first 10 and "+ N more fields" (click to
  show all, "- show fewer" to fold back).
- [ ] 🧪 **Widget hints** in a comment at the end of a field's line:
  `speed = 1.5, --@range 0 10 0.5` makes a slider (click or drag anywhere on
  it; step optional), `mode = "fast", --@enum slow|fast|insane` a drop-down.
- [ ] 🧪 **Typed tables from LuaLS classes**: `---@class Paddle` with
  `---@field speed number @range 0 10`, `---@field mode Mode` (where
  `---@alias Mode "slow"|"fast"`, `---|` lines too) and `---@field tint Color`
  gives a table node titled `Paddle` with a slider, a drop-down and a colour
  swatch. A table is a `Paddle` when `---@type Paddle` (or `---@class Paddle`)
  sits right above its `local`, when its function says `---@return Paddle`,
  or when its parent's field is typed `Paddle`. Fields the class declares but
  the table lacks show as `+ name: type` rows: one click adds them with a
  default for the type (0, "", false, the alias's first value, {}, white,
  `function() end`). A hint on the field's line still wins. The world's
  classes (`/classes`) are typed tables too: see "The graph reads /classes".
- [ ] 🧪 **Colour picker extras**: an alpha bar for `{ r, g, b, a }`, a hex field
  (click it, type `#ff8000` or `#f80`), and it stays open while you adjust.
- [ ] 🧪 **Share an expression**: drag an expression's (or call's) result onto
  another pin: it becomes a `local` declared right above the first statement
  using it, and both pins read it (`local value = a > b`). Refused when the
  local wouldn't be visible from the second pin, when what it reads isn't
  visible up there, or for while / until / elseif conditions (evaluated
  again and again). Expression nodes can be dragged and nudged on their own
  (`--@expr slot=N dx= dy=` above the statement).
- [ ] 🧪 **Flow wiring, UE style**: drop a flow wire on a flow in that's
  already taken and the old wire goes: that statement (and what follows it
  in its block) moves to run there (refused if a name would then read
  another variable). Drop it on a node: its flow in. Drop it on the
  background: the Add menu opens there, and what you pick is added and
  wired at once (after the pin it came from, or before it from a flow in).
- [ ] 🧪 **A new graph tab** opens with the whole graph centred, filling 75% of
  the view (tabs restored from the workspace keep their view); double-click
  the background to fit it again. The **start** node can be moved too
  (a `--@start dx= dy=` line at the top of the file).
- [ ] 🧪 **Call pins named after the parameters** of the function called when
  the file defines it: a local function, a global `function f(a, b)`, a
  field `function M.f(a)` or a method `function M:m(dt)` (called `M:m(x)`:
  `self`, then `dt`); else from the API definitions in `runtime/meta/`
  (LuaLS `---@meta` stubs: `dd.lua` for the debug draw API written in C,
  `lua.lua` for the standard library; add a file there for any other API);
  else from the modules: the engine's (`runtime/*.lua`, their classes'
  methods: `World:query`) and those the file requires, recursively
  (`local ecs = require("ecs")`: `ecs.world()`, and what it returns, a
  World, so `w:spawn(path, components)`). An object of unknown class (a
  system's `w` parameter) uses the only method of that name, if there's
  one. A vararg is named by `---@param ... string component`: `component 1`,
  `component 2`... Read again when a module changes. Any module style is
  read: `function M.f()`, `M.f = function()`, `M.f = f` (a local
  function), `M.alias = M.g`, `local M = { f = function() }`, `return {
  f = f }`; a field of the local a module was required into works too
  (`local ecs = require("ecs")`: `ecs.system(f)`). `arg1`, `arg2`...
  otherwise.
- [ ] 🧪 **Two panes side by side** (`tabflip.lua`, `tabmenu.lua`): a tab's
  menu (and the text's) has *Open beside with >* (each way the file opens:
  its graph, preview or atlas, its text, a copy) and *Move to the pane
  beside*; `Ctrl+\` its other view (a copy for a tab that doesn't flip). Beside: the pane right of it (left of it, for the right
  one), split off when there's none. Commands `tab:open-beside`,
  `tab:copy-beside`, `tab:move-beside`.
- [ ] 🧪 **First open of a project**: with no Lite workspace saved there yet,
  Lite starts on the project's root file (the world script, or a folder
  world's outermost `.lua`, e.g. `order.lua`); after that Lite restores its
  own tabs. The game still starts as usual.
- [ ] 🧪 **A poor man's profiler in the tree**: while the game runs or is paused,
  each tree row has a bar behind it, from the right: the time that node's
  systems took a tick, with its children's (ms, smoothed over a few frames),
  out of a frame's budget (1000 / 60 ms) across the tree's width, coloured
  by a turbo-like scale in 10 bands, one per 10% of the budget (blue, cyan,
  green, lime, yellow, orange, red): from 90% on it's the last, brightest red. Hover a
  row: its ms, and its share of the budget (`0.42ms  2.52%`). Every tick's costs are kept by game time (the last 5 minutes):
  paused, scrubbing the timeline shows the costs of the frame shown. A system run per node counts for that node, one run once for
  the node it lives on (`ecs.profiler`, set by the editor; not standalone).
- [ ] 🧪 **Pinned references** (RMB on a variable: a pin reading it, the node
  declaring it, a get node, a chip > "Pin references of x"): every node that
  declares, writes or reads it is outlined (the declaration thicker) and a
  crosshair runs through each one across the whole view, so they stand out
  zoomed out on a big graph. Each pinned variable gets a colour of its own
  (the palette). They stay until "Unpin references of x" (or "Unpin all
  references", RMB on the background); kept across edits (by name, nearest
  line) and in `.workspace.lua`.
- [ ] 🧪 **The flow that ran, values on wires** (the probe): while a graph tab is
  shown, the running world records what that file's code did each frame
  (a C line hook, on only while the systems of watched files run, calling
  Lua only on their own lines; only while some graph asks: `editor/probe.h`,
  `host_probe` in Lite). It costs next to nothing while playing. Shown while the game runs or is
  paused and the editor is visible (the game under 100%): the flow wires
  that ran in the frame shown turn orange, blending back to white over
  0.6 s once they don't (e.g. scrubbing the timeline); each data wire carries a small tag with the value it had (where it's
  read); hovering a wire, a pin or a chip shows `name = value`, its type when
  known, and how many times that line ran (the last value). A wire from an
  expression node carries the expression's value too: the world evaluates
  its text with the locals it recorded at that line (only expressions that
  can't change the game: calls only of functions that just compute, `math.*`,
  string functions that make a new string, `tostring`, `tonumber`, `type`,
  `select`; anything else, or a local shadowing one of those, is refused;
  `host_probe_eval`). A call node's result pin and an input pin fed by an
  expression or call node show that value too; stopped on that very line
  (before it ran) the tooltip says `name ~ value (not run yet: computed)`. Systems cut from a script map back to
  its lines (`ecs.chunk_origins`), a folder world's leaves through their
  files. The last 1500 frames are kept, by game time. Stopped: no flow.
  Three white beads slide along each orange wire, out to in, on the
  editor's clock (stepped at 30 Hz, so Lite repaints nothing in between);
  going back in time (the timeline dragged left, rewound) they slide
  backwards for half a second after each step back.
  A graph opened while paused, on a file that frame didn't record (nothing
  watched it yet): the editor runs one frame more (1/60 s) and stays paused,
  so the flow shows at once (not after a timeline seek: that would cut the
  timeline's future).
- [ ] 🧪 **The graph's status**: errors, warnings, breakpoints top-left, and a
  refusal (what you asked didn't happen: "can't wire it there...", "drop it
  on an input...") in red for a few seconds; the file's name, node
  count, zoom, the flow's frame (`flow at t=`), what an edit
  expects and the last message on a line at the bottom of the canvas,
  after an (i) icon: hovered, a tip lists the mouse and keys, a line each,
  shortest first (LMB, ALT+LMB: unlink, RMB, CTRL+WHEEL, DOUBLE-CLICK, F9,
  CTRL+F, ALT+LEFT, DEL, CTRL+Z / CTRL+Y; stopped at a breakpoint: F5, F10,
  F11, SHIFT+F11). Modifiers are written
  in capitals everywhere (CTRL, ALT, SHIFT). Each on a
  small dark backdrop, no bar across.
- [ ] 🧪 **Errors and warnings are links**: click "N errors" or "N warnings"
  (top-left): the view glides to the next node with one (in the order of
  the text, around again after the last; zooms in when far out), selects it
  and says what it is: `warning 2/6 (line 150): 'p' hides the local of
  line 119`.
- [ ] 🧪 **Warnings**: a row each in an amber footer under the node (like the
  errors' red one; errors first when a node has both; the count next to the
  errors, top-left): unused locals
  (and local functions; their pin dimmed; `_name` is exempt), a local or
  loop variable hiding another of its name ("'x' hides the local of line
  7"; parameters don't count: `function(w)` inside a `w` is the usual
  pattern), statements that can't run (after a break or a goto, up to the
  next label), and arguments of a type their parameter's `---@param` doesn't
  take (`'a': number expected, got string`; only when both are certain; an
  integer fits a number). Floating code gets none. They're known only after
  the layout (types come last), so each build sizes in the rows the last
  one found (by node key) and builds once more when they changed: nothing
  overlaps. (`graph.lua`, after the types; `resolve.lua` records what each
  declaration hides.)
- [ ] 🧪 **Doc tooltips on calls**: hover a call node's title: its signature
  with the parameters' types and what it returns (`add(a: number, b: number)
  -> number`), then its description (the `---` lines above the function,
  not the `---@` ones). From this file's functions, the API stubs
  (runtime/meta) and modules (runtime/ecs.lua...).
- [ ] 🧪 **Split table pins** (UE's "split struct pin"): RMB on a table input >
  "Split <pin>": a pin per field on the same node (`p.x`,
  `p.y`), each wired / edited on its own. A pin holding a table constructor
  just splits; one reading a table (`f(pos)`) is written as one first,
  `f({ x = pos.x, y = pos.y })`, its fields from the table the variable was
  declared with or its parameter's / field's `---@class`. "Merge <pin>"
  shows one pin again, writing `pos` back when every field is still
  `pos.<field>`. Kept in the text, like a getter: `--@expr slot=1.2 split=1`
  above the statement, so every view of the file shows it (tags count a
  statement's pins as written: a split pin's fields are `2f1`, `2f2`...).
- [ ] 🧪 **Split table outputs**: a table node assigned to a variable (`local p
  = {...}`, `p.q = {...}`): RMB on it (its result pin, its title, a row) >
  "Split p" (the menu names the output pin; a table not assigned yet is assigned first:
  floating, `{...}` becomes `local tbl = {...}` there; fed into a pin, a
  `local tbl = {...}` goes right above that statement and the pin reads
  `tbl`): an
  output per field, on that field's row (mirrored: `speed` in, `speed`
  out), the whole table's result in its header. Wiring from one writes
  `p.speed` into the pin; reads of `p.speed` elsewhere are drawn from it
  (no expression node). A field holding a table (a colour) splits too ("Split
  p.color": `color.r`, `color.g`, `color.b` on the rows below).
  "Merge p" (or just a field's: "Merge p.color"). In the text: the table node's tag,
  `--@expr slot=1 outs=1,color`. Values on those wires: the field, where it's read.
- [ ] 🧪 **Function parameters**: a function's header has a "+ add parameter"
  row (a click: `arg1`, `arg2`, `arg3`... after its last `argN`, skipping a
  name the function already uses; other variables elsewhere don't matter;
  before `...` if it has one), so the Add menu has a single "Function" (and a
  single "Return": its "+ add value" row makes "return a value"). RMB on a
  parameter's pin or its name > "Rename parameter a" (edits the header's names,
  `step(a, b)`: change any of them; also a double-click on the title) or
  "Remove parameter a": refused while the body uses it; the calls of that
  local function in the file lose that argument (`f(1, 2)` -> `f(2)`).
- [ ] 🧪 **A variable's members where its wire is dropped**: drag from an output
  (`ecs`, `cfg`, a split `p.color`, a "get ecs" node) and let go on the background: a menu
  "Members of ecs" there (searchable): its module's functions (a
  `require`: `ecs.world()`, `ecs.match(pattern, path)`), its class's
  methods and fields (`---@type`, or what made it: a call's `---@return`
  class), the fields and functions of the table it was made with, and
  whatever the file already reads from it (`cfg.extra`, `w:spawn(...)`).
  The pick floats there, reading the variable (wired); a call that gives a
  value is added as that value (`(ecs.world())`), one that doesn't as a
  call statement.
- [ ] 🧪 **Autoconversion on wiring**: a variable (or a floating expression)
  wired into a pin of a type it doesn't take, both certain (the pin's
  `---@param` or class field type; the value's type), is converted: a
  number or boolean into a string -> `tostring(x)`; a string into a number
  -> `tonumber(x)`; anything into a boolean -> `x ~= nil`. The message says
  so ("s now reads tostring(n) (converted: string expected)").
- [ ] 🧪 **Breakpoints**: RMB on a statement node > Add / Remove breakpoint, a
  click in the code's gutter (an arrow cursor there), or F9 (the caret's
  line; in a graph, the selected node): a red dot on the node and in the
  gutter (a click on either dot removes it). A breakpoint is a line (Lua stops at lines): on a line holding
  several statements (`if c then f() end`) it's the first's. "N
  breakpoints" top-left (next to the errors and warnings): a click goes to
  the next one. Stopped: F5 (or play) continues, F10 steps over (the next
  line of this function or its caller), F11 steps into (the next line
  anywhere watched), shift+F11 steps out (the next line of a caller); a
  frame ending while stepping stops at the next frame's first line. (F5 /
  F10 / F11 do what they did when nothing is stopped.) When the world
  reaches that line its tick stops there: the game pauses mid-frame, the
  graph shows that frame so far (the flow up to there, the values) with the
  node outlined in yellow, the view glides to it (a code tab of the file
  jumps to the line; none open: one opens), and the status says
  "breakpoint: pong.lua:152 (play: continue)". Play runs the rest of that
  frame (and stops again if it gets there again); stop, a timeline seek or
  a reload drop the half-done frame. How: with breakpoints set, the tick
  runs as a coroutine and the C line hook yields at one (where Lua can't
  yield, inside a C call, it runs on). Only in systems' code (what runs
  each frame) and in code that runs when its file loads: a system file's or
  a module's top level stops at Play / Rewind (the systems are built again
  in that first tick, and the modules they require run again; with
  breakpoints set, a build outside a tick waits for the next one:
  `ecs.DEFER`; test: `runtime/tests/break_load.lua`); kept per file in the
  graph tabs' workspace state.
  (`breaks.lua`, `editor/probe.h`, `editor/world.h`; test:
  `runtime/tests/nodegraph_break.lua`.)
- [ ] 🧪 **Debugging in the text** (Lite's code tab, stopped): the lines that
  ran tinted; a variable under the mouse shows `name = value   (at line N)`:
  the last line that changed it before the stop (from the probe's run order:
  a line that assigns it, `x.x, x.y = ...`, or after which its value
  differs), else the line declaring it (a parameter: its function's); a dot
  is the field after it (`v.a` on v.a.b's first dot). **Watches**: RMB > Add watch / Remove watch; listed top right
  under "N breakpoints", per file, with their values (at the stop's line, else
  the last run); `+` / `-` unfolds a table's fields, a click on the name goes
  to where it was set, `x` removes it. (`plugins/nodegraph/init.lua`,
  `breaks.lua`; test: `runtime/tests/text_debug.lua`.)
  The world's main script (the file the game was opened with): its top
  level stops too. Play / Rewind run it again first, in the first frame (a
  dry run: the world it builds is dropped, the game goes on with the
  edited world; only when that file has breakpoints). Other files' top
  level runs once, when required, and the world can't stop there: such a
  breakpoint is drawn hollow, the status says "(1 at load: won't stop)",
  and setting one (graph or text gutter / F9) says so. Continuing from a
  statement over several lines (a call with a table) doesn't stop on it
  again when the call comes back to its first line.
  Stopped, the game view says so too (the overlay): a red frame round the
  game and "BREAKPOINT pong.lua:152" low in the middle, with the keys; F5 /
  F10 / F11 / shift+F11 work in every view then (the game doesn't get them).
  A system's setup (the code in `ecs.system(function()` before its run
  function) stops too: it runs when the system is built, the first frame
  after Play / Rewind (both build the systems again: their setup starts
  fresh) or after an edit of it. A breakpoint on a function's header
  (`local function f(...)`) stops where Lua defines it (on its `end` line,
  reported as the header's line), not at that function's own return.
- [ ] 🧪 **Go to definition** (RMB on a node): where what it uses is defined. A
  call: its function's frame in this file (`add(1, 2)`, `Counter:bump(2)`),
  else the module that defines it (`ecs.world()`: runtime/ecs.lua, opened as
  a graph in a tab of the same pane, on that function) or its API stub
  (runtime/meta). A get node, a variable's pin (RMB on its row): the node
  that declares it. The view glides there and selects it. "Go back" (RMB on
  the background), alt+left or alt+up returns, across tabs too. "Show source code" is
  the old "go to its line".
- [ ] 🧪 **Collapse to function** (RMB on the selection, or on one statement):
  statements that follow one another in a block become a local function
  defined right before them, and a call of it in their place. The variables
  they read from outside become its parameters; the outside ones they assign
  and the ones they declare that are read later come back as its return
  values (`local s; total, s = new_function(a, b, total)`). Refused when
  control would leave them (a return, a break of a loop around them, a goto
  out, the function's `...`). Its header is selected: double-click it to
  rename it. Their layout tags are dropped (the new function is laid out
  afresh). No expand (yet).
- [ ] 🧪 **Library values are values**: Add > Library entries that return
  something (`tostring(v)`, `tonumber(s)`, `math.*`, `string.*`...) come as
  a call node with its result (typed: tostring's is a string), not a call
  statement throwing it away (they're added as `(tostring(0))`).
- [ ] 🧪 **Pending wires**: floating code is its own block (a comment), so a read
  in it can't see another block's variable (nor real code a floating one).
  Wired anyway (a local into a print, both just added), the text reads it
  (`print(value)`) and the wire stays drawn, dashed, until the flows are
  wired and it's a real one. Pin references follow them too.
- [ ] 🧪 **Library pins are typed** (`runtime/meta/lua.lua`: `---@param` /
  `---@return` on math, string, table): string.rep's `s` wants a string (a
  number wired in: `tostring(...)`), its result is a string.
- [ ] 🧪 **Floating code, renaming and moving**: a function still floating
  (just added from the menu) renames like any (its names resolve in the
  float's own text); an expression node inside floating code moves on its
  own (its `--@expr` offset goes inside the float), the rest of the float
  stays. The menu's Functions are "call f(a, b)" (type "call f"), floating
  ones too (marked: wire it in to run).
- [ ] 🧪 **Collapsible nodes** (Blender style): a chevron left of a node's title
  folds it into its header, its pins gathered on its edges (the wires stay).
  A function's header folds the whole function: its frame shrinks to the
  header, the nodes inside are hidden, wires reaching them end on the header.
  Nothing else moves. Also RMB > Minimize / Expand (on a selection: all of it).
  Comment boxes fold too: the chevron left of their title (or RMB >
  Minimize / Expand) shrinks the box to its headline, hides what's wholly
  inside it (nodes, functions, smaller boxes) and ends the wires reaching it
  on the headline; dragging the folded box moves them all. Which nodes are folded is
  view state, not code: kept per graph tab in `.workspace.lua` (by a key that
  survives edits: kind, title, pin names, which of the alike).
- [ ] 🧪 **A line between panes**: a split you can drag is drawn as a line of its
  own: dark teal (`style.pane_divider`), lighter under the mouse
  (`pane_divider_hover`), aqua while dragged (`pane_divider_drag`), so two
  graphs side by side don't blur into one grid. Splits that can't be moved
  (the status bar's, side panels') stay thin and dim, and don't change the
  cursor.
- [ ] 🧪 **Hidden graph tabs wait**: a graph tab behind another one in its pane
  isn't built (nor rebuilt as its file changes) until it's shown, so a
  workspace with many graph tabs opens without building them all.
- [ ] 🧪 **Tabs move between panes**: drag a tab onto another pane (it joins its
  tabs), near a pane's edge (the outer fifth: a new pane on that side), or
  along its own tab bar (reorder). The target is outlined while dragging.
- [ ] 🧪 **RMB menu order**: colours; what every node has, shortest first
  (Minimize / Expand, Add comment, Go to definition (dim when there's none),
  Show source code); then what's particular to that node (Collapse to
  function, field and pin options); then a separator and Delete, always last.
- [ ] 🧪 **Colours first**: in a node's RMB menu the row of colour squares comes
  right under its title. A comment box's menu has it too (`color=` in its
  `--@comment` tag; the first square: none).
- [ ] 🧪 **Add menu: Label, Goto, Set**: Flow > Label (`::label::`) and a
  "Goto <label>" per label of the function under the mouse; Set > "new
  local" and "set <variable>" (`x = nil`, wire its value in) for each
  variable visible there, like Get.
- [ ] 🧪 **Copy keeps a local's type**: copying a statement takes its `---@type`
  / `---@param` lines along, so a pasted `---@type Paddle` local is a Paddle
  table node again (its title, its missing fields' "+" rows).
- [ ] 🧪 **Unlink a field's function**: ALT+click the pin of a function written
  into a table field (`on_hit = function ... end`): it floats as its frame,
  the field reads nil. Wire it back by dropping the pin's wire on the
  floating function: its `fn` out, any pin of its header, its header or its
  frame.
- [ ] 🧪 **For each (pairs / ipairs)** from the Add menu reads `ipairs(nil)`: an
  empty pin to wire any table into (no table node made). Floating code shows
  no run-time errors (it doesn't run).
- [ ] 🧪 **Copy a typed table alone**: copying just a Paddle table node writes
  `{ ... } --[[@as Paddle]]` (LuaLS's cast), and a table followed by such a
  cast is a Paddle node: the copy keeps its title and "+ alive" rows.
- [ ] 🧪 **Titles always fit**: a node is never narrower than its title
  (a floating `1` shows "expression" whole).
- [ ] 🧪 **Tree clicks while playing** open the node's source in Lite but leave the
  game in front (no flicker); the line found skips comments (pong's ball:
  its `w:spawn("/objects/ball"`, not the header comment), and a node made by
  its children (`/objects/field`) finds its first child's spawn.
- [ ] 🧪 **A file on the command line always opens in Lite** (`play games\pong.lua`),
  in front of the restored tabs (it keeps its cursor). A folder world opens its
  root file when the saved workspace has no tabs.
- [ ] 🧪 **A world that doesn't load opens in Lite**: when the script fails
  (a syntax error, an error while it runs), the file opens in Lite at the
  line the error names, even when a saved workspace would restore other tabs.
- [ ] 🧪 **Window icon** (`<exe name>.png` next to the exe) on the project
  picker too.
- [ ] 🧪 **Flip icon on tabs**: a small icon at the left of a Lua file's tab
  (the close cross is at the right) flips it between text and graph; a
  right-click on the tab still does too.
- [x] **`plugins/nodegraph/tests/`**: small node graph samples (for, for each, while, repeat,
  if / elseif / nested, calls, tables, classes, functions, types, goto,
  floating code), each saying what its graph should show; open them to
  check by eye. `runtime/tests/tests.lua` lays them all out headless too.
- [ ] 🧪 **Pin names from LuaLS annotations**: `---@return number sum` above a
  function names its `return` pins and the outputs of call nodes calling it;
  `---@param a number` shows the type on the header. Double-click a return
  pin's name to rename it: the `---@return` line is rewritten (or added).
- [ ] 🧪 **Blender-style nodes and wires**: rounded nodes on a grid, a coloured
  header per kind of statement, the code in a field. Each node has sockets:
  the variables its expressions read on the left, the ones it declares on the
  right (a function's header: its name and parameters), joined by curved
  wires. Socket colours: grey local, purple parameter, yellow loop variable,
  teal function, dark grey global. Hover or select a node to light its wires.
- [ ] 🧪 **Graph mouse scheme** (Blender-like): LMB selects a node (shift/ctrl:
  toggle), LMB+drag on empty space draws an orange box that selects what it
  touches, LMB+drag on a node moves it (or the whole selection),
  LMB+drag on a socket wires it; ALT+LMB on a socket or a wire
  disconnects it (those reads become `nil`, refused where the variable is
  assigned); RMB+drag pans; RMB opens a menu: on the background "Add"
  (math expression, variable, call, if, if/else, for range, for each,
  while, function, return, table: it floats where you clicked), on a node
  colour / delete / go to its line
  (on a selection: colour or delete them all).
  Added statements get free names and float (see floating nodes); deleting
  is refused while something still reads what the node declares. Double-click edits a row (background:
  show the whole graph).
- [ ] 🧪 **More return values**: drop a variable's wire on a return node (or
  click its `+ add value`) and the function returns one more value: that
  variable in this return, a placeholder in every other return of the
  function (0, false, "" after the variable's type, else nil; nil where a
  return had fewer values), so all its paths return the same values. Its
  pins stay; the new one is named after the variable by a `---@return type
  name` line above the function. Returns ending in a call or `...` are left
  alone (they return a list).
- [ ] 🧪 **Select all / none**: ctrl+a selects every node; ctrl+a again (all
  selected) clears it, and so does ctrl+shift+a (as in Illustrator, GIMP,
  Inkscape). ctrl+d is left free for a future multi-selection feature.
- [ ] 🧪 **Arrow keys move the selection** on the grid: its top-left corner first
  snaps to the grid in that direction, then each press moves it one cell
  (24 units). Written as `--@node` / `--@frame` offsets like a drag.
- [ ] 🧪 **Run-time errors on nodes**: a node whose code will certainly fail
  when it runs (indexing, calling or doing arithmetic on a literal `nil`, as
  a disconnect leaves behind; `pairs(nil)`; `for i = nil, ...`) gets a red
  outline and a red footer with Lua's message; the graph's header counts
  the errors. More checks (warnings too) will land here.
- [ ] 🧪 **Flip a tab between text and graph**: the icon left of a Lua file's
  tab name (or its menu's Toggle graph / Lua) shows its graph in the same
  tab; again for the text. Each side keeps its scroll / pan / zoom, and a
  node clicked in the graph is where the text opens. "Open as node graph"
  (right-click in the text) flips too. Hovering such a tab says so.
- [ ] 🧪 **Tab menu** (RMB on any tab): Close tab, Close tabs to the right,
  Close unmodified tabs | Copy path (absolute, `/`), Browse folder (the file
  selected in Explorer / Finder; its folder elsewhere) | Toggle graph / Lua.
  Closing several with Confirm close on asks for each unsaved one. Middle
  click and the cross still close. Its separators (and every Lite menu's)
  are the caret's cyan faded into the menu.
  Tabs now always show, even for a lone file.
- [ ] 🧪 **Left-to-right flow**: the file's top-level statements (functions,
  events) are stacked top to bottom; inside a function the statements run
  left to right from its header. An `if` puts each branch on its own row
  (condition on the left), a loop's body runs on the row under it, and
  lambdas hang under the statement that holds them.
- [ ] 🧪 **Graph navigation**: wheel scrolls; shift+wheel or a horizontal wheel /
  trackpad scrolls sideways; ctrl+wheel zooms the graph around the mouse
  (10%..300%, nodes, text and wires together; boxes only when far out). The
  graph has its own fonts, so Lite's own zoom no longer distorts it. Zoom and
  pan are remembered with the workspace. Double-click the background to see
  the whole graph; it can't be scrolled out of sight. With nothing selected
  the keys move the camera, eased (in-out cubic; presses add up): arrows 20%
  of the view, page up / down 75% vertically, home / end 75% sideways.
- [ ] 🧪 **Remove an input pin** (RMB on its row): a value of `local a, b = 1, 2`
  ("Remove b (its 3 reads become nil)": the menu counts them; each node that
  still reads b then shows "attempt to index a nil value"), of a multiple
  assignment, of a return, an argument of a call, a concat's 3rd+ operand.
  Table fields: "Remove field". (A lone value can't go: delete the node.)
- [ ] 🧪 **Concat nodes**: `a .. b .. c` is a "concat (..)" node, a pin per
  operand (a, b, c: literals editable in place, or wired) and a result out;
  the Add menu's Concat gives one with two string pins. "+ add string" appends
  `.. ""`; a and b always stay, c, d... can be removed (RMB on the row).
- [ ] 🧪 **Hover lights things up**: a pin under the mouse lights up with its
  wires and the pins at their other ends (their names too); off the pins, the
  wires under the mouse (overlapping ones all together) and their end pins.
  Chip wires show while lit.
- [ ] 🧪 **Wires snap to pins**: dragging a wire, the nearest pin it can end on
  within 22 px (`NodeGraphView.SNAP`) takes it (ringed); dropping there
  connects.
- [ ] 🧪 **An input's wire dropped on the background offers what can feed it**:
  the Add menu's values that fit its type (a condition: booleans, a number
  pin: numbers...) and the variables visible there (get ...), with search;
  the one picked floats there and is wired in. (A flow input's wire offers
  statements to run before it, as before.)
- [ ] 🧪 **plugins/nodegraph/tests/playground.lua**: every kind of node in one file, to look at
  them together. `runtime/tests/nodegraph_deletes.lua` (in the editor) deletes
  every node of it, of plugins/nodegraph/tests/move-00.lua and of pong.lua in turn and checks
  nothing breaks or is lost.
- [ ] 🧪 **A replaced input keeps its old node**: wiring something else into a
  pin fed by an expression node (or a function), or ALT+clicking that pin,
  leaves the old node floating where it was (calls as `(f(x))`), UE style,
  instead of deleting it.
- [ ] 🧪 **Rewire by dragging sockets**: drag from an input to an output (or from
  an output to an input, or an input onto a node) and that input reads that
  variable instead. Refused when the variable isn't visible there (declared
  later, or in another scope).
- [x] Right-click in the editor view (game hidden) goes to Lite (its context
  menu); in the game view it inspects the game, as before.
- [x] Mouse-driven: ESC is the only keyboard shortcut of the viewer.

**Toolbar / buttons**
- [x] Save | Overlay, Gizmos, Picking, Camera … Menu; bottom: Play, Stop,
  Rewind, Players, Network, Speed. One rule: enabled = bright + hover + hand cursor;
  disabled = dim; toggles that are on are yellow. Tooltips everywhere.
- [ ] 🧪 Rewind: from the start, always: t=0, speed x1, playing (stopped: it
  starts the game).

**Testing hooks**
- [ ] 🧪 `--prof`: where each frame's time goes, averaged over a second, in the
  window title (and on stderr): events, Lite (its Lua; raster = drawing its
  changed cells, of which upload = sending them to the GPU; how many frames
  it redrew), poll (a folder world's files checked, twice a second),
  status (unsaved? the save button), the world's tick, drawing the game,
  blitting the layers, the overlay, the tab (tree, properties), the other
  panels (bar, menus), present, wait (the frame limiter's sleep: idle).
- [x] `--shot out.bmp --frames N`, `--events` (clicks, drags, wheel, Alt/Ctrl
  clicks, ESC), `--key`, `--type`; deterministic dt in shot mode.
- [x] `runtime/tests/tests.lua` (match, serialize, diff/patch, disk, code
  leaves, overrides, Hurdy) on Lua 5.4 and LuaJIT.

## Demos (games/)

- [x] `scene1.lua` / `scene2/` — the same demo as a script and as a folder
  (both follow the layout; `scene2/`: `assets/ship` drawn through `ref`,
  `objects/`, `data/`, `systems/`, `classes/shot`). While it plays the
  ships shoot now and then: each shot an entity under `/entities/shots`
  (watch the tree), gone when its life (from `/classes/shot`) runs out;
  random from a seed in `data/state`, so rewinds replay the same shots.
- [x] `pong.lua` / `pong/` — pong, single file vs folder (byte-identical worlds).
  Swept collisions, AI paddle, game-over banner with countdown.
- [ ] 🧪 pong for two: player 2 plays the right paddle (W / S in its view)
  when it's in the game, else the computer does (the left one too, when
  player 1 is out). Tagged: the score `replicate = true`; the ball and the
  left paddle `{ by = 1, predict = true }`; the right paddle `{ by = 2,
  predict = true }` (player 2's own while it plays: no lag for it);
  `data/input/p1` and `p2` (each player's held keys) `1` / `2`. Any
  player's space / enter / escape restarts after a game over.
- [ ] 🧪 `hop/` — a tiny platformer: the level is a tile map (`assets/level1.tmap`,
  drawn by `tilemap` components, one node per layer; the ground layer is
  solid, lava hurts, the items layer becomes gems and a door), the sounds
  are `.sfx` (`w:sound`). Edit the map or a sound while it plays: it shows
  / sounds so at once.
- [x] `snake.hurdy` / `snake/` — snake with every system in Hurdy; after a game
  over a new one starts in `restart_after` seconds (space skips it); the RNG
  seed is world data, so rewinds replay exactly. The layout: `systems/`,
  `data/`, `objects/`, and the body cells in `/entities/snake` (spawned
  while playing).
- [ ] 🧪 `orbitbreak.lua` — a Super Hexagon-like game in one file (ported from
  `orbitbreak.html`): rings close in, turn round the orbit to pass through
  their gaps; passes build a combo, a gold spark in the middle of every gap fills the pulse (space) that
  breaks the rings near you; the arena spins, flips and changes colour as it
  speeds up (the rings start slow). The rings can throb on a beat (`shake`
  in `/data/state`, off for now; `beat`, 0..1, for a music track to set);
  the orbit, the core and the player never do. Drawn with `tris` (thick arcs), layers (`/data/layers`: sky,
  back, default, front); the RNG seed is in `/data/state`.
- [ ] 🧪 `starfall.lua` — a shoot'em up in one file: the orange ship follows
  the mouse on a spring (it speeds up and slows down by itself; a pad's stick
  or WASD / arrows fly it too), LMB (or A / RT / SPACE) fires; ten waves of blue
  ships on their paths, then a boss made of rocks (a big one, two rings of
  smaller ones turning and breathing, a glow) in three phases. Its patterns,
  ships, waves and boss: `games/common/starfall.bullets` (the bullet editor);
  every enemy bullet drawn as a round dot (11 px or more, whatever sprite its
  pattern asks for) with a white glint; only the ship's small core is hit; the sky scrolls (the space picture,
  every other copy upside down: no seam), stars at three depths, sparks.
  Which stage: `/data/rules.stage` (a .bullets of games/common/); the window is its play field.
  Test: run.lua's `starfall` (a scripted mouse plays to the boss and wins).
- [ ] 🧪 `fairy/` — a room (a tile map) and a fairy to talk to (`assets/fairy.dialog`,
  the dialog plugin's sample): walk, talk (space / A), pick answers (up /
  down); carry the bananas and you can ask her about them.

---

## Upcoming

**Editing**
- [ ] 🧪 **One undo for everything**: the tree's stack also takes every
  property edit (viewer_prop_* wrapped: the components they change, as
  they were) and every move in the game view; the same edit again within a
  second joins its step (sliders, scrubbing). Ctrl+Z over the tree, the
  properties, or the game view (stopped / paused). In memory only (the
  tree's file steps stay on disk as before); Stop drops the steps made
  while playing; reading the same world again keeps the stack. Test:
  runtime/tests/tree_undo.lua.
- [ ] 🧪 **Headless runs** (`edit <game> --headless [--ticks N]`): no window or
  renderer; the world played N ticks of 1/60 s as Play would, `--key
  "space@30"` / `"w@10-90"` (held), `--type "assert(...)@600"` (Lua on the
  world, as the console); prints each check and a summary, exit code 0 / 1
  (a failed check, a tick's error, broken code). For CI and scripts.
- [ ] 🔜 Create / delete / rename / duplicate nodes from the tree (right-click menu).
- [ ] 🧪 **Drag nodes in the game view** (100%, stopped or paused): LMB drag on
  a node moves it (into its parent's space: the parents' turn and scale
  undone), Alt+drag turns it around its middle, the wheel while dragging
  scales it; the picked instance moves (as RMB picks). Selected on release;
  Save writes it. One undo level per drag. replay.c: move_start / move_drag
  / move_finish; boot.lua: viewer_move_begin / by / end.
- [ ] 🔜 Tree search box with glob patterns.
- [ ] 💡 Grid and snap; layers / draw order; camera follow (double-click).

**Time**
- [ ] 🔜 Step mode (advance one tick).
- [ ] 💡 Quick-save / restore slots on the timeline; diff view of what changed on disk.

**Code**
- [ ] 🔜 **Sandbox budgets** for code leaves: CPU (instruction count), memory and
  stack limits, so no script can hurt the host.
- [ ] 💡 Error overlay per node: mark the failing system red in the tree.
- [ ] 💡 More languages through `ecs.languages` (anything that compiles to Lua).

**Node graph (next steps)**
- [ ] 🔜 Widgets from LuaLS types (`---@class` / `---@field`, `---@alias` enums),
  so a field shows the right widget even when its value is `nil` or a variable.
- [ ] 🔜 Multiple results: `local a, b = f()` wires each call output to its local;
  annotations of functions in other files (modules).
- [ ] 💡 Operator nodes: not planned. A node holds a whole expression
  (`3 + 5 * 2 + sin(t)`), like UE5's "math expression" node.
- [ ] 🔜 Structure editing: add / remove statements and branches; opaque "code"
  nodes for anything that doesn't map to nodes.
- [ ] 🔜 Hurdy files (hurdyl's syntax tree).

**Order**
- [ ] 🔜 Scoped order lists (an `order` per subtree, not only at the root).

**Multiplayer**
- [ ] 💡 Prediction with exact timing (the owner's frame in each state, input
  sequence numbers) instead of half the round trip.
- [ ] 🔜 NAT traversal (hole punching through the host as introducer is half
  there: everyone pings everyone): a ticket of its own (docs/ROADMAP.md),
  then WebRTC for browsers.
- [ ] 🔜 The game travels too (assets, modules) when a joiner doesn't have it.
- [ ] 🔜 **Admin nodes**: privileged peers that review external games' proposals
  (pending patches, accept / reject). They can play, but never administer
  their own games. A plan, in steps (identity keys, game manifests with
  authors, signed proposals, a review tab, observers): docs/ROADMAP.md.
- [ ] 💡 Ownership colouring in the tree (mine / peer / shared / admin-reviewed).

**Assets and packaging**
- [ ] 💡 Textures by content hash (the first binary asset, p2p friendly).
- [ ] 💡 Zip the whole world tree; send deltas between zipped snapshots.
- [ ] 💡 Profiler row: time per system while hovering the timeline.

-- net_ghosts.lua: the Players harness (runtime/players.lua) headless, on
-- games/asteroids: two players on a fair network; each view's ghost holds
-- the last state the owners sent of what it predicts; a cut line stops what
-- a player hears (and heals); the send rate reaches every peer; three
-- players make a star (each talks to the host only).
-- Run from runtime/tests: luajit net_ghosts.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs, disk = require("ecs"), require("disk")
dofile(here .. "../players.lua")
local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end

local _, blob = disk.new(here .. "../../games/asteroids"):read("/**")
local _, host = ecs.load(blob, "/")
viewer_players_net(0.5)                            -- fair: 100 ms
viewer_players_rate(10)
local dt = 1 / 60
local function run(s) for _ = 1, math.floor(s * 60) do host:tick("/**", dt); viewer_players_tick(dt) end end
viewer_players_sync(host, 3)                       -- players 1 and 2
run(3)
local p2 = viewer_players_world(2)
check(p2 and p2 ~= host, "player 2: a world of its own (the network is up)")
local g2 = viewer_players_ghost(2)
check(g2 and g2:node("/entities/rocks") and #g2:children(g2:node("/entities/rocks")) > 0, "player 2's ghost: the host's rocks, as last sent")
check(g2 and g2:node("/objects/ship2"), "player 2's ghost: its own ship, as the host last sent it (what it reconciles with)")
check(viewer_players_ghost(1) == nil, "the host's ghost: none (everything is the host's)")
check(viewer_players.peers[2].peer.replica.rate == 10 and viewer_players.peers[1].peer.replica.rate == 10, "the rate: on every peer")
viewer_players_ghosts(false)
check(viewer_players_ghost(2) == nil, "ghosts off: none")
viewer_players_ghosts(true)

local function seq() local s = 0 for _, st in pairs(viewer_players.peers[2].peer.replica.streams) do s = s + st.last end return s end
viewer_players_link(2, -2)                         -- player 2 unplugged
run(0.5)
local before = seq()
run(1)
check(seq() == before, "a cut line: player 2 hears nothing new")
viewer_players_link(2, -1)                         -- back: as everyone's
run(1)
check(seq() > before, "healed: it hears again")
check(viewer_players_bandwidth() > 0, "bandwidth: measured")
viewer_players_sync(host, 7)                       -- players 1, 2 and 3: a star (each player talks to the host only)
run(1)
local p2, p3 = viewer_players.peers[2].peer.replica.peers, viewer_players.peers[3].peer.replica.peers
check(#p2 == 1 and p2[1] == "p1" and #p3 == 1 and p3[1] == "p1", "a star: players 2 and 3 talk to the host only (" .. table.concat(p2, ",") .. " / " .. table.concat(p3, ",") .. ")")
check(#viewer_players.peers[1].peer.replica.peers == 2, "... and the host to both")
local s3 = viewer_players_world(3)
check(s3 and s3:node("/objects/ship2") and math.abs(s3:node("/objects/ship2").c.xform.x - host:node("/objects/ship2").c.xform.x) < 60, "player 3 sees player 2's ship (through the host)")
viewer_players_stop()
print(fails == 0 and "net ghosts: all ok" or ("net ghosts: " .. fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

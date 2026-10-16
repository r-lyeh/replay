-- bullets.lua - runtime/bullets.lua: patterns fired and flown, splits, hits,
-- the drawing lists, saving, paths; Starfall's own file (games/common/starfall.bullets).
--   cd runtime/tests && luajit bullets.lua   (or lua5.4)
package.path = "../?.lua;" .. package.path
local B = require "bullets"
local n, fails = 0, 0
local function check(c, m) n = n + 1; if not c then fails = fails + 1; print("  FAIL: " .. m) end end
local function near(a, b, e) return math.abs(a - b) < (e or 1e-6) end

local d = assert(B.parse([[return { patterns = {
  { name = "ring", kind = "ring", count = 12, rate = 2, speed = 100 },
  { name = "fan", kind = "fan", count = 3, spread = 30, aim = true, rate = 1, volleys = 2, speed = 200 },
  { name = "spin", kind = "ring", count = 1, spin = 90, rate = 4, angle = 0, speed = 100 },
  { name = "seed", kind = "fan", count = 1, angle = 90, speed = 50, volleys = 1, split = { at = 0.5, pattern = "ring" } },
  { name = "slow", kind = "fan", count = 1, angle = 90, speed = 100, accel = -400, volleys = 1 },
} }]]))

local st = d:new(1)
d:emit(st, "ring", 0, 0, "a")
d:step(st, 0.01, 0, 100)
check(#st.bullets == 12, "a ring: 12 bullets at once: " .. #st.bullets)
local angles = {}
for _, b in ipairs(st.bullets) do angles[#angles + 1] = b.a end
check(near(angles[2] - angles[1], 30), "evenly round: 30 degrees apart")
d:step(st, 0.5, 0, 100)
check(#st.bullets == 24, "2 a second: the second volley after 0.5 s: " .. #st.bullets)

st = d:new(1)
d:emit(st, "fan", 0, 0, "b")
d:step(st, 0.01, 0, 100)                           -- the target straight below: aimed at 90 degrees
check(#st.bullets == 3 and near(st.bullets[2].a, 90, 1e-3) and near(st.bullets[1].a, 75, 1e-3), "a fan of 3, aimed: 75, 90, 105")
for _ = 1, 30 do d:step(st, 0.1, 0, 100) end
check(#st.emitters == 0, "volleys = 2: the emitter is done (and gone)")
check(#st.bullets == 0, "the bullets left the field (and went)")

st = d:new(1)
d:emit(st, "spin", 0, 0, "c")
d:step(st, 0.01, 0, 0)
d:step(st, 0.25, 0, 0)
check(#st.bullets == 2 and near(st.bullets[2].a - st.bullets[1].a, 22.5, 1e-3), "spin 90 a second, 4 volleys a second: 22.5 degrees on")

st = d:new(1)
d:emit(st, "seed", 0, 0, "d")
d:step(st, 0.01, 0, 0)
for _ = 1, 6 do d:step(st, 0.1, 0, 0) end
check(#st.bullets == 12 and st.bullets[1].p == "ring", "a split: the seed became a ring of 12: " .. #st.bullets)

st = d:new(1)
d:emit(st, "slow", 0, 0)
d:step(st, 0.01, 0, 0)
for _ = 1, 10 do d:step(st, 0.1, 0, 0) end
check(st.bullets[1] and st.bullets[1].v == 0, "accel slows a bullet down to a stop (not backwards)")

st = d:new(1)
d:emit(st, "ring", 0, 0, "boss")
d:step(st, 0.01, 0, 0)
check(d:hit(st, 0, 0, 4) and #st.bullets == 11, "a hit: true, that bullet gone")
check(not d:hit(st, 300, 300, 4), "no bullet there: no hit")
d:stop(st, "boss")
check(#st.emitters == 0, "stop: its emitters go")
d:emit(st, "ring", 0, 0, "fader")
d:step(st, 0.01, 0, 0)
local before = #st.bullets
d:clear(st, 0.8)
check(#st.bullets == before and not d:hit(st, 0, 0, 40), "a fading clear: the bullets stay, harmless")
d:step(st, 0.4, 0, 0)
local o = d:look(st).dot.o[1]
check(#st.bullets == before and o < 1 and o > 0, "half way: still there, fading: " .. tostring(o))
d:stop(st, "fader")
d:step(st, 0.5, 0, 0)
check(#st.bullets == 0, "then gone")
d:emit(st, "ring", 0, 0, "boss")
d:step(st, 0.01, 0, 0)
local look = d:look(st)
check(#look.dot.s == 12 and #look.dot.xy == 24 and look.dot.rgb[1] == 0xff7ab0 and look.dot.o[1] == 1, "look: the dots, their sizes, the default colour")
check(B.rgb("#102030") == 0x102030, "colours as numbers")

local again = assert(B.parse(B.to_lua(d)))
check(#again.patterns == 5 and again.patterns[4].split.pattern == "ring", "saved and read back")

local x1, y1 = B.path("down", 0, 50, nil, 100)
local x2, y2 = B.path("down", 1, 50, nil, 100)
check(x1 == 50 and near(y2 - y1, 100), "a path: down at its speed")
local sx = B.path("sweep", 0, -1, -150, 100)
check(sx < -400, "a sweep from the left starts off the left edge")
check(B.path_done(0, 400) and not B.path_done(0, 0), "past the field: done")

-- the stage: waves, then the boss through its phases; the game deals the damage
do
  local sd = assert(B.parse([[return {
    patterns = { { name = "p", kind = "ring", count = 4, rate = 2 }, { name = "q", kind = "fan", count = 1 } },
    enemies = { { name = "s", hp = 2, size = 40, speed = 200, pattern = "p" } },
    waves = { { at = 0.5, enemy = "s", count = 3, gap = 0.2, path = "down", x = 0 } },
    boss = { hp = 10, size = 100, phases = { { hp = 1, patterns = { "p" } }, { hp = 0.5, patterns = { "q" } } } },
    field = { w = 600, h = 400 },
  } ]]))
  local sg = sd:stage_new(3)
  local evs = {}
  for _ = 1, 30 do for _, e in ipairs(sd:stage_step(sg, 1 / 30, 0, 150)) do evs[#evs + 1] = e[1] end end
  check(#sg.ships == 3 and evs[1] == "wave" and sg.wave == 1, "the wave's three ships came in")
  check(#sg.bul.emitters == 3, "each firing its pattern")
  sd:stage_kill(sg, 1)
  check(#sg.ships == 2 and #sg.bul.emitters == 2, "one shot down: its emitter stops")
  for _ = 1, 150 do sd:stage_step(sg, 1 / 30, 0, 150) end
  check(#sg.ships == 0 and sg.mode == "boss" and sg.boss, "the ships flew off (a 400 high field): the boss")
  for _ = 1, 150 do sd:stage_step(sg, 1 / 30, 0, 150) end
  local px, py = sd:boss_place()
  check(sg.boss.in_ and near(py, -70) and sg.boss.phase == 1, "at its place (130 below the top), phase 1")
  sg.boss.hp = 4
  local ph
  for _, e in ipairs(sd:stage_step(sg, 1 / 30, 0, 150)) do if e[1] == "phase" then ph = e end end
  check(ph and ph[2] == 2 and ph[3] == 1, "half its hp: phase 2")
  sg.boss.hp = 0
  local beaten
  for _, e in ipairs(sd:stage_step(sg, 1 / 30, 0, 150)) do if e[1] == "beaten" then beaten = true end end
  check(beaten and sg.mode == "done", "beaten: done")
  local x, y = sd:path("sweep", 0, -1, nil, 100)
  check(x < -300 and near(y, -100), "paths in the file's field: a sweep starts off a 600 wide field, at a quarter")
  -- import: another file's patterns and ships, names taken get a number
  local other = assert(B.parse([[return { patterns = { { name = "p", split = { at = 1, pattern = "r" } }, { name = "r" } },
                                          enemies = { { name = "s", pattern = "p" } } }]]))
  local np, ns = B.import(sd, other)
  check(np == 2 and ns == 1 and B.pattern(sd, "p2") and B.pattern(sd, "p2").split.pattern == "r" and B.enemy(sd, "s2").pattern == "p2",
        "imported: p as p2 (its split still names r), the ship as s2, firing p2")
  check(B.to_lua(sd):find("field = { h = 400, w = 600 }", 1, true), "the field is saved")
end

-- the game's file: every name it uses is there
local f = assert(io.open("../../games/common/starfall.bullets", "rb"))
local sd = assert(B.parse(f:read("*a")))
f:close()
local missing = {}
for _, e in ipairs(sd.enemies) do if not B.pattern(sd, e.pattern) then missing[#missing + 1] = e.pattern end end
for _, w in ipairs(sd.waves) do if not B.enemy(sd, w.enemy) then missing[#missing + 1] = w.enemy end end
for _, ph in ipairs(sd.boss.phases) do for _, p in ipairs(ph.patterns) do if not B.pattern(sd, p) then missing[#missing + 1] = p end end end
for _, p in ipairs(sd.patterns) do if p.split and not B.pattern(sd, p.split.pattern) then missing[#missing + 1] = p.split.pattern end end
check(#missing == 0, "starfall.bullets: every pattern and ship it names is there: " .. table.concat(missing, ", "))

print(string.format("bullets: %s", fails == 0 and ("all ok (" .. n .. " checks)") or (fails .. " failed")))

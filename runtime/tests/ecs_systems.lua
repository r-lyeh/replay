-- ecs_systems.lua: systems with filters and their kept lists (after
-- tiny-ecs): requires / any / none, on_add / on_remove, structure changes
-- counted between systems, interval, active = false (or an `active`
-- component), the same in code leaves; and a stress world.
-- Run from runtime/tests: luajit ecs_systems.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs = require("ecs")
local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end

local w = ecs.world()
w:spawn("/a", { pos = { x = 0 }, vel = 1 })
w:spawn("/b", { pos = { x = 0 }, vel = 1, frozen = true })
w:spawn("/c", { pos = { x = 0 }, spin = 1 })
local added, removed = {}, {}
w:system("move", { "pos" }, function(_, n, dt) n.c.pos.x = n.c.pos.x + dt end,
  { any = { "vel", "spin" }, none = { "frozen" },
    on_add = function(_, n) added[#added + 1] = n.path end,
    on_remove = function(_, n) removed[#removed + 1] = n.path end })
w:tick("/**", 1)
check(w:node("/a").c.pos.x == 1 and w:node("/b").c.pos.x == 0 and w:node("/c").c.pos.x == 1, "any / none")
check(table.concat(added, ",") == "/a,/c", "on_add, in order: " .. table.concat(added, ","))
w:remove("/a")
w:set("/b", "frozen", nil)
w:tick("/**", 1)
check(table.concat(removed, ",") == "/a", "on_remove: " .. table.concat(removed, ","))
check(added[3] == "/b" and w:node("/b").c.pos.x == 1, "a component gone (w:set): it joins")
w:node("/c").c.frozen = true                       -- (by hand: skipped at once; on_remove at the next refresh)
w:tick("/**", 1)
check(w:node("/c").c.pos.x == 2, "a filter checked as it runs")
w:refresh(); w:tick("/**", 1)
check(removed[2] == "/c", "w:refresh: on_remove")

-- structure changes count between systems
local v = ecs.world()
local ran = {}
v:system("spawner", {}, function(wv) if not wv:node("/x") then wv:spawn("/x", { mark = true }) end end)
v.systems.spawner.once = true
v:system("after", { "mark" }, function(_, n) ran[#ran + 1] = n.path end)
v:spawn("/y", { mark = true, doomed = true })
v:system("killer", { "doomed" }, function(wv, n) wv:remove(n.path) end)
v:system("last", { "mark" }, function(_, n) ran[#ran + 1] = "last" .. n.path end)
v.order = { "spawner", "after", "killer", "last" }
v:tick("/**", 1)
check(table.concat(ran, ",") == "/x,/y,last/x", "spawned: run by the systems after it; removed: skipped (" .. table.concat(ran, ",") .. ")")

-- interval, active
local u = ecs.world()
local runs, dts = 0, {}
u:system("think", {}, function(_, dt) runs = runs + 1; dts[#dts + 1] = dt end, { interval = 0.5 })
u.systems.think.once = true
for _ = 1, 60 do u:tick("/**", 1 / 60) end
check(runs == 2 and math.abs(dts[1] - 0.5) < 1e-6, "interval: twice a second, dt = the time since (" .. runs .. ")")
u:system("off", {}, function() runs = runs + 100 end, { active = false })
u.systems.off.once = true
u:tick("/**", 1 / 60)
check(runs < 100, "active = false: not run")

-- code leaves: the same fields; an `active` component on its node
local z = ecs.world()
z:spawn("/objects/e", { hp = 3 })
z:spawn("/objects/f", { hp = 3, shield = true })
z:spawn("/systems/hurt", { system = ecs.code([[
  return { requires = { "hp" }, filter = { none = { "shield" } }, interval = 1,
           run = function(w, n, dt) n.c.hp = n.c.hp - 1 end,
           on_add = function(w, n) n.c.seen = true end }
]]) })
for _ = 1, 3 do z:tick("/**", 0.5) end
check(z:node("/objects/e").c.hp == 2 and z:node("/objects/f").c.hp == 3, "code: filter and interval (hp " .. z:node("/objects/e").c.hp .. ")")
check(z:node("/objects/e").c.seen and not z:node("/objects/f").c.seen, "code: on_add")
z:set("/systems/hurt", "active", false)
for _ = 1, 4 do z:tick("/**", 0.5) end
check(z:node("/objects/e").c.hp == 2, "an active component = false: switched off")

-- stress: 3000 entities, 3 systems, half of them moving
local s = ecs.world()
for i = 1, 3000 do s:spawn("/entities/e" .. i, { pos = { x = 0 }, vel = (i % 2 == 0) and 1 or nil, hp = 1 }) end
s:system("move", { "pos", "vel" }, function(_, n, dt) n.c.pos.x = n.c.pos.x + n.c.vel * dt end)
s:system("age", { "hp" }, function(_, n) n.c.hp = n.c.hp end)
s:system("none", { "nothing" }, function() end)
s:tick("/**", 1)
local t0 = os.clock()
for _ = 1, 60 do s:tick("/**", 1 / 60) end
local ms = (os.clock() - t0) * 1000 / 60
print(string.format("  stress: 3000 entities, %.2f ms a tick", ms))
check(s:node("/entities/e2").c.pos.x > 1.9, "stress: they moved")

print(fails == 0 and "ecs systems: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

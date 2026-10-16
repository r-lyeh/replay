-- modules.lua: game modules and w:owns (headless). A code leaf named
-- `module` (under /data/lib) is loaded by require, never run as a system;
-- editing it rebuilds the systems that use it, through other modules too;
-- errors say what's missing or circular. w:owns(node): who decides for it.
-- Run from runtime/tests: luajit modules.lua (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
local ecs = require("ecs")
local fails = 0
local function check(c, what) if not c then fails = fails + 1; print("  FAIL: " .. what) end end

local w = ecs.world()
w:spawn("/data/lib/num", { module = ecs.code("return { k = 2 }\n") })
w:spawn("/data/lib/math2", { module = ecs.code('local num = require "num"\nreturn { twice = function(x) return x * num.k end }\n') })
w:spawn("/data/out", { v = 0, p = 0 })
w:spawn("/systems/use", { system = ecs.code('local m = require "math2"\nreturn function(w) w:node("/data/out").c.v = m.twice(5) end\n') })
w:spawn("/systems/bypath", { system = ecs.code('local num = require "/data/lib/num"\nreturn function(w) w:node("/data/out").c.p = num.k end\n') })
w:tick("/**", 1)
local out = w:node("/data/out").c
check(next(w.code_err) == nil, "no errors: " .. tostring((select(2, next(w.code_err)))))
check(out.v == 10 and out.p == 2, "require by name and by path (" .. tostring(out.v) .. ", " .. tostring(out.p) .. ")")
check(not w.systems["/data/lib/num/module"], "a module isn't a system")

w:node("/data/lib/num").c.module = ecs.code("return { k = 3 }\n")   -- edited: its users are built again, through math2
w:tick("/**", 1)
check(out.v == 15 and out.p == 3, "a module edited: the systems using it, directly or not, rebuilt (" .. out.v .. ", " .. out.p .. ")")

w:spawn("/systems/missing", { system = ecs.code('local x = require "nope"\nreturn function() end\n') })
w:tick("/**", 1)
check(tostring(w.code_err["/systems/missing/system"]):find("no module /data/lib/nope", 1, true), "a missing module: says which")
w:spawn("/data/lib/a", { module = ecs.code('return require "b"\n') })
w:spawn("/data/lib/b", { module = ecs.code('return require "a"\n') })
w:spawn("/systems/cycle", { system = ecs.code('local a = require "a"\nreturn function() end\n') })
w:tick("/**", 1)
check(tostring(w.code_err["/systems/cycle/system"]):find("cycle", 1, true), "a cycle: says so")
check(out.v == 15, "the others keep running")
w:node("/data/lib/num").c.module = ecs.code("return { k = 'x' .. nil }\n")   -- broken: its users keep their old version
w:tick("/**", 1)
check(w.code_err["/systems/use/system"] and out.v == 15, "a broken module: an error, the old version runs on")
w:node("/data/lib/num").c.module = ecs.code("return { k = 4 }\n")
w:tick("/**", 1)
check(out.v == 20 and not w.code_err["/systems/use/system"], "fixed: running again")

-- w:owns
local h = ecs.world()
h:spawn("/objects/free", {})
h:spawn("/objects/mine", { replicate = true })
h:spawn("/objects/p2", { replicate = { by = 2 } })
h:spawn("/objects/p2/child", {})
check(h:owns("/objects/p2") and h:owns(h:node("/objects/free")), "no session: this world decides everything")
h.peer, h.players = 1, { true, true }
check(h:owns("/objects/mine") and h:owns("/objects/free") and not h:owns("/objects/p2") and not h:owns("/objects/p2/child"), "the host: its own and the untagged, not player 2's (nor its children)")
h.players = { true }
check(h:owns("/objects/p2"), "player 2 not in the game: the host decides for it")
h.peer, h.players = 2, { true, true }
check(h:owns("/objects/p2/child") and not h:owns("/objects/mine"), "player 2: its own")

print(fails == 0 and "modules: all ok" or ("modules: " .. fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

-- classes_props.lua - the property panel and /classes (headless): the
-- viewer's Lua (runtime/boot.lua)
-- runs here on a small world.
--   /classes/ship: its members, each described ({ type, value, min, max,
--   options, container, values }); what every `ship` component starts with
--   a node's ship: shows the members it lacks (inherited), marks the ones
--   that differ, values keep to their member (slider, choice, colour); RMB
--   goes back to the class. An object: "+ component" (a drop-down of the classes).
--   a class's panel: per member a row (name: rename / remove; type, kind:
--   drop-downs, map > its values), its default, its range or options, "+ member" (a name:
--   a bool); /classes: "+ class". Built in: /classes/int number string bool
--   color (never saved). Collections: + item / + key, RMB removes one.
-- Run: luajit classes_props.lua   (or lua5.4)

local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path

-- the BOOT string: its C literals, joined (// comments between them skipped)

hostfs = { isdir = function() return false end }   -- (the viewer's host functions it may touch)
dofile(here .. "../boot.lua")                     -- (the viewer's Lua)
local ecs = require("ecs")

local w = ecs.world()
w:spawn("/classes/ship", {
  speed = { type = "number", value = 3, min = 0, max = 10 },
  hp = { type = "int", value = 10, min = 1, max = 20 },
  name = "ship",                                    -- (a plain value: short for { type = "string", value = "ship" })
  shield = { type = "bool", value = false },
  mode = { type = "string", value = "slow", options = { "slow", "fast", "off" } },
  tint = { type = "color3", value = { 255, 0, 0 } },
})
w:spawn("/objects/c", { xform = { x = 9 } })
w:spawn("/objects/a", { xform = { x = 0 } })
w:node("/objects/a").c.ship = { speed = 5 }       -- (set after spawn: not filled, like a folder world's)
w:spawn("/objects/b", { ship = { hp = 7 } })

local fails = 0
local function check(c, m) print((c and "ok   " or "FAIL ") .. m); if not c then fails = fails + 1 end end
local function rows(p)                              -- label -> row (a label's first row)
  local t = {}
  for _, r in ipairs(viewer_props(w, { p })) do if not t[r[2]] then t[r[2]] = r end end
  return t
end
local function all(p) return viewer_props(w, { p }) end
local E = ecs.encode
check(w:node("/objects/b").c.ship.speed == 3 and w:node("/objects/b").c.ship.name == "ship", "spawn fills the members' values")
local r = rows("/objects/a")
check(r.ship and r.ship[3] == "class", "the component has a class")
check(r.hp and r.hp[8] == "i" and r.hp[3] == "10", "hp: inherited, the class's value")
check(r.speed and r.speed[8] == "d" and r.speed[9] == "3", "speed: differs (the class says 3)")
check(r.shield and r.shield[8] == "i", "shield: inherited")
local id = E({ "ship", "speed" })
local ok, err = viewer_prop_set(w, { "/objects/a" }, id, '"fast"', "lit")
check(not ok and tostring(err):find("a number"), "a number member stays a number: " .. tostring(err))
check(viewer_prop_set(w, { "/objects/a" }, E({ "ship", "hp" }), "12", "num"), "set an inherited one")
check(w:node("/objects/a").c.ship.hp == 12, "... it's in the node now")
viewer_prop_toggle(w, { "/objects/a" }, E({ "ship", "shield" }))
check(w:node("/objects/a").c.ship.shield == true, "toggle an inherited bool: from the class's false")
viewer_prop_class_revert(w, { "/objects/a" }, id)
check(w:node("/objects/a").c.ship.speed == 3, "RMB: back to the class's value")
check(rows("/objects/a").speed[8] == nil, "... no longer marked")
r = rows("/classes/ship")
check(r["used by"] and r["used by"][3] == "2: /objects/a, /objects/b", "a class: who uses it")
-- widgets from the members
r = rows("/objects/a")
check(r.speed[10] == "range 0 10 0" and r.hp[10] == "range 1 20 1", "ranges: speed 0..10, hp int 1..20")
check(r.mode[4] == "choice" and r.mode[11] == "slow|fast|off", "mode: a drop-down of its options")
check(r.tint[4] == "color" and r.tint[3] == "255, 0, 0", "tint: a colour, one row")
viewer_prop_set(w, { "/objects/a" }, E({ "ship", "speed" }), "42", "num")
check(w:node("/objects/a").c.ship.speed == 10, "typed past its range: kept at 10")
viewer_prop_add(w, { "/objects/a" }, E({ "ship", "hp" }), -100)
check(w:node("/objects/a").c.ship.hp == 1, "scrubbed past its range: kept at 1")
viewer_prop_slide(w, { "/objects/a" }, E({ "ship", "hp" }), 0.5)
check(w:node("/objects/a").c.ship.hp == 11, "the slider at half of 1..20: 11 (whole)")
viewer_prop_slide(w, { "/objects/a" }, E({ "ship", "speed" }), 0.5319)
check(w:node("/objects/a").c.ship.speed == 5.3, "the slider on 0..10: steps of 0.1 (" .. tostring(w:node("/objects/a").c.ship.speed) .. ")")
check(viewer_prop_pick(w, { "/objects/a" }, E({ "ship", "mode" }), "fast") and w:node("/objects/a").c.ship.mode == "fast", "a pick from the drop-down")
viewer_prop_cycle(w, { "/objects/a" }, E({ "ship", "mode" }), -1)
viewer_prop_cycle(w, { "/objects/a" }, E({ "ship", "mode" }), -1)
check(w:node("/objects/a").c.ship.mode == "off", "cycle: the one before (around)")
ok, err = viewer_prop_set(w, { "/objects/a" }, E({ "ship", "mode" }), "medium", "str")
check(not ok and tostring(err):find("one of"), "options: only them")
check(viewer_prop_set(w, { "/objects/a" }, E({ "ship", "tint" }), "0, 128, 255", "lit"), "a colour typed without braces")
check(w:node("/objects/a").c.ship.tint[2] == 128, "... is a colour")
check(not viewer_prop_set(w, { "/objects/a" }, E({ "ship", "tint" }), "{ 300, 0, 0 }", "lit"), "a colour: 0..255")
-- + a component from a class
r = rows("/objects/c")
check(r["+ component"] and r["+ component"][4] == "pick" and r["+ component"][11]:find("^ship|") and r["+ component"][11]:find("|vec3|", 1, true),
      "an object without a ship: + component, a drop-down of the classes, then the plain types (" .. tostring(r["+ component"] and r["+ component"][11]) .. ")")
w:spawn("/data/rules", { win = 7 })
w:spawn("/systems/move", { system = 1 })
check(not rows("/objects")["+ component"] and not rows("/systems/move")["+ component"] and rows("/data/rules")["+ component"],
      "... not on /objects itself nor /systems; on /data nodes too")
check(viewer_prop_pick(w, { "/objects/c" }, r["+ component"][1], "ship", ""), "+ component > ship")
local sc = w:node("/objects/c").c.ship
check(sc and sc.speed == 3 and sc.tint[1] == 255 and sc.name == "ship", "+ ship: the members' values")
check(sc.tint ~= w:node("/classes/ship").c.tint.value, "... copies")
check(not rows("/objects/c")["+ component"][11]:find("ship", 1, true), "... no more ship in its list (it has one)")
w:spawn("/objects/d", { ship = {} })
-- a class's panel: a block per member
r = rows("/classes/ship")
check(r.hp and r.hp[4] == "member_row" and r.hp[3] == "int" and r.hp[13] == "var", "a member's row: its name, type, kind (var)")
local blk = {}
for _, x in ipairs(all("/classes/ship")) do local k = ecs.decode(x[1]) if k[2] == "hp" or k[1] == "hp" then blk[#blk + 1] = x[2] end end
check(table.concat(blk, ",") == "hp,range,default", "hp's rows (default last): " .. table.concat(blk, ","))
check(r.hp[11]:find("bool") and r.hp[11]:find("ship"), "type: a drop-down of the classes (" .. tostring(r.hp[11]) .. ")")
check(r.hp[14]:find("^var|%[%] array|%(%) set|{} map>") and r.hp[14]:find("ship", 1, true), "kind: var, [] array, () set, {} map > its values' types")
check(rows("/classes/ship").range[3] == "1..20" and rows("/classes/ship").options, "a range row (numbers), an options row (text)")
-- editing the class: its default, its nodes follow
viewer_note = nil
local before_b = w:node("/objects/b").c.ship.hp
check(viewer_prop_set(w, { "/classes/ship" }, E({ "speed" }), "4", "num"), "the class's speed (default): 3 -> 4")
check(w:node("/classes/ship").c.speed.value == 4, "... into its description's value")
check(w:node("/objects/c").c.ship.speed == 4 and w:node("/objects/d").c.ship.speed == 4, "nodes that had the class's 3: now 4")
check(w:node("/objects/a").c.ship.speed == 5.3, "a's own speed (5.3): kept")
check(viewer_note and viewer_note:find("upgraded"), "said so: " .. tostring(viewer_note))
viewer_prop_set(w, { "/classes/ship" }, E({ "hp" }), "15", "num")
check(w:node("/objects/b").c.ship.hp == before_b and w:node("/objects/c").c.ship.hp == 15, "b's own hp kept, c's (the class's) 15")
check(not viewer_prop_set(w, { "/classes/ship" }, E({ "mode" }), "medium", "str"), "the default keeps to the options too")
-- min / max / options
check(viewer_prop_set(w, { "/classes/ship" }, E({ "?range", "hp" }), "1..12", "lit"), "hp: range 1..12")
check(w:node("/classes/ship").c.hp.max == 12 and w:node("/classes/ship").c.hp.value == 12, "... the default kept in it (15 -> 12)")
check(w:node("/objects/b").c.ship.hp == 7 and w:node("/objects/a").c.ship.hp == 11, "... nodes' own values that fit: kept")
check(viewer_prop_set(w, { "/classes/ship" }, E({ "?range", "hp" }), "..12", "lit") and w:node("/classes/ship").c.hp.min == nil, "range ..12: no min")
check(not viewer_prop_set(w, { "/classes/ship" }, E({ "?range", "hp" }), "20..12", "lit"), "min more than max: no")
check(not viewer_prop_set(w, { "/classes/ship" }, E({ "?range", "hp" }), "1.5..3", "lit"), "an int's range: whole")
check(not viewer_prop_set(w, { "/classes/ship" }, E({ "?range", "hp" }), "abc", "lit"), "a range: min..max")
check(viewer_prop_set(w, { "/classes/ship" }, E({ "?options", "mode" }), "slow, fast", "lit"), "options: slow, fast")
check(w:node("/objects/a").c.ship.mode == "slow", "a's mode (off) no longer fits: the default")
-- + member: a name, a bool; then its type, kind
local member = E({ "?member" })
check(viewer_prop_set(w, { "/classes/ship" }, member, "armor", "lit"), "+ member armor")
local arm = w:node("/classes/ship").c.armor
check(arm.type == "bool" and arm.value == false and w:node("/objects/c").c.ship.armor == false, "... a bool, false, in its nodes too")
check(not viewer_prop_set(w, { "/classes/ship" }, member, "hp", "lit"), "a member it has: no")
check(not viewer_prop_set(w, { "/classes/ship" }, member, "2x", "lit"), "a name: not first a digit")
check(viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "armor" }), "int", "type"), "armor: type int (the drop-down)")
check(w:node("/classes/ship").c.armor.value == 0 and w:node("/objects/c").c.ship.armor == 0, "... its value starts again: 0, nodes too")
viewer_prop_set(w, { "/objects/c" }, E({ "ship", "armor" }), "3", "num")
ok, err = viewer_prop_set(w, { "/objects/c" }, E({ "ship", "armor" }), "2.5", "num")
check(not ok and err:find("whole"), "an int: whole numbers only")
check(viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "armor" }), "number", "type") and w:node("/objects/c").c.ship.armor == 3, "int -> number: values that fit stay (3)")
-- rename, remove
check(viewer_prop_set(w, { "/classes/ship" }, E({ "?m", "armor" }), "plates", "lit"), "rename armor -> plates")
check(w:node("/classes/ship").c.plates and not w:node("/classes/ship").c.armor and w:node("/objects/c").c.ship.plates == 3, "... in its nodes too (c's 3)")
check(viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "plates" }), "Remove", "name") and w:node("/objects/c").c.ship.plates == nil, "remove: gone, from its nodes too")
-- collections
viewer_prop_set(w, { "/classes/ship" }, member, "path", "lit")
viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "path" }), "number", "type")
check(viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "path" }), "array", "kind"), "path: kind array")
local pth = w:node("/classes/ship").c.path
check(pth.container == "array" and type(pth.value) == "table" and #pth.value == 0, "... an empty list")
r = rows("/objects/c")
check(r.path and r.path[3] == "array of number (0)" and r["+ item"], "a node: the list, + item")
viewer_prop_add_class(w, { "/objects/c" }, r["+ item"][1])
viewer_prop_add_class(w, { "/objects/c" }, r["+ item"][1])
check(#w:node("/objects/c").c.ship.path == 2, "+ item twice: 2 items")
check(viewer_prop_set(w, { "/objects/c" }, E({ "ship", "path", 2 }), "7", "num") and w:node("/objects/c").c.ship.path[2] == 7, "an item set")
r = rows("/objects/c")
check(r["[1]"] and r["[1]"][8] == "e", "items: RMB removes them")
viewer_prop_remove(w, { "/objects/c" }, E({ "ship", "path", 1 }))
check(#w:node("/objects/c").c.ship.path == 1 and w:node("/objects/c").c.ship.path[1] == 7, "... removed: [1]")
viewer_prop_set(w, { "/classes/ship" }, member, "hits", "lit")
viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "hits" }), "string", "type")
check(viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "hits" }), "map:int", "kind"), "kind: map > int (the sub-list)")
check(w:node("/classes/ship").c.hits.container == "map" and w:node("/classes/ship").c.hits.values == "int", "... a map of string -> int")
check(rows("/classes/ship").hits[13] == "{} map:int", "... its row says so")
check(not rows("/classes/ship").hits[14]:match(">.*array"), "map values: types (no collections)")
check(not viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "hits" }), "map:nothing", "kind"), "map > a type that isn't: no")
r = rows("/objects/c")
check(r["+ key"] and r.hits[3] == "map string -> int (0)", "a map on a node: + key")
local keyid
for _, x in ipairs(all("/objects/c")) do if x[2] == "+ key" then keyid = x[1] end end
check(viewer_prop_set(w, { "/objects/c" }, keyid, "laser", "lit") and w:node("/objects/c").c.ship.hits.laser == 0, "+ key laser: its value starts at 0")
check(viewer_prop_set(w, { "/objects/c" }, E({ "ship", "hits", "laser" }), "4", "num") and w:node("/objects/c").c.ship.hits.laser == 4, "a map's value set")
check(not viewer_prop_set(w, { "/objects/c" }, E({ "ship", "hits", "laser" }), "4.5", "num"), "... an int")
viewer_prop_set(w, { "/classes/ship" }, member, "tags", "lit")
viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "tags" }), "string", "type")
viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "tags" }), "set", "kind")
for _, x in ipairs(all("/classes/ship")) do if x[2] == "+ key" and ecs.decode(x[1])[2] == "tags" then keyid = x[1] end end
check(viewer_prop_set(w, { "/classes/ship" }, keyid, "boss", "lit") and w:node("/classes/ship").c.tags.value.boss == true, "a set's default: + key boss")
check(w:node("/objects/c").c.ship.tags.boss == true, "... its nodes follow (never overridden)")
-- classes: + class; a member of a class type
check(rows("/classes")["+ class"], "/classes: a + class row")
local newc = E({ "?class" })
check(viewer_prop_set(w, { "/classes" }, newc, "engine", "lit") and w:node("/classes/engine"), "+ class engine")
check(viewer_select == "/classes/engine", "... selected")
viewer_prop_set(w, { "/classes/engine" }, member, "power", "lit")
viewer_prop_pick(w, { "/classes/engine" }, E({ "?m", "power" }), "number", "type")
viewer_prop_set(w, { "/classes/engine" }, E({ "?range", "power" }), "0..100", "lit")
viewer_prop_set(w, { "/classes/ship" }, member, "motor", "lit")
check(viewer_prop_pick(w, { "/classes/ship" }, E({ "?m", "motor" }), "engine", "type"), "ship's motor: type engine")
check(type(w:node("/objects/c").c.ship.motor) == "table" and w:node("/objects/c").c.ship.motor.power == 0, "... an engine's members, in its nodes too")
r = rows("/objects/c")
check(r.power and r.power[10] == "range 0 100 0", "a member of a class type: its members' widgets")
viewer_prop_set(w, { "/objects/c" }, E({ "ship", "motor", "power" }), "500", "num")
check(w:node("/objects/c").c.ship.motor.power == 100, "... and their ranges")
check(not viewer_prop_pick(w, { "/classes/engine" }, E({ "?m", "power" }), "engine", "type"), "a class can't hold itself")
check(viewer_prop_set(w, { "/classes" }, newc, "boss ship", "lit") and w:node("/classes/boss").c.hp.max == 12, "+ class boss ship: a copy of ship's members")
check(not viewer_prop_set(w, { "/classes" }, newc, "boss", "lit"), "a class that's there: no")
-- the built-in classes
check(w:node("/classes/int"), "/classes/int: built in")
check(rows("/classes/int")["built in"] and rows("/classes/int")["+ member"] == nil, "... no members to edit")
check(not select(2, w:save()):find("/classes/int", 1, true), "... never saved")
w:spawn("/objects/e", { color = { 1, 2, 3 } })
check(rows("/objects/e").color[3] ~= "class" and #w:node("/objects/e").c.color == 3, "a color component: not the built-in class's")
-- the plain types: vectors, angles, quaternions, rects, colours, keys, assets, nodes
local tw = ecs.world()
tw:spawn("/objects/o", {})
tw:spawn("/assets/ship", {})
tw:spawn("/classes/thing", { pos = { type = "vec3" }, heading = { type = "angle", value = 90 }, spin = { type = "quat" },
  area = { type = "rect" }, glow = { type = "color4" }, fire = { type = "key", value = "space" },
  look = { type = "asset" }, target = { type = "node" } })
tw:spawn("/objects/t", { thing = {} })
local th = tw:node("/objects/t").c.thing
check(th.pos.x == 0 and th.pos.z == 0 and th.spin.w == 1 and th.area.w == 1 and #th.glow == 4 and th.look == "", "the plain types start at their values")
local ww = w
w = tw
local tr = rows("/objects/t")
check(tr.pos[3] == "0, 0, 0" and tr.pos[10] == "vec", "a vec3: one row (" .. tostring(tr.pos[3]) .. ")")
check(viewer_prop_set(tw, { "/objects/t" }, E({ "thing", "pos" }), "1, 2.5, -3", "lit") and th.pos.y == 2.5 and th.pos.z == -3, "... typed 1, 2.5, -3")
check(not viewer_prop_set(tw, { "/objects/t" }, E({ "thing", "pos" }), "1, 2", "lit"), "... 3 numbers")
check(tr.heading[10] == "range -180 180 0", "an angle: a slider, -180..180")
viewer_prop_set(tw, { "/objects/t" }, E({ "thing", "heading" }), "270", "num")
check(th.heading == -90, "... 270 is -90 (around)")
viewer_prop_set(tw, { "/objects/t" }, E({ "thing", "spin" }), "0, 0, 2, 2", "lit")
check(math.abs(th.spin.z - 0.707107) < 1e-5 and math.abs(th.spin.w - 0.707107) < 1e-5, "a quat: kept normalized")
check(not viewer_prop_set(tw, { "/objects/t" }, E({ "thing", "area" }), "0, 0, -1, 2", "lit"), "a rect: no negative size")
check(tr.glow[4] == "color" and not viewer_prop_set(tw, { "/objects/t" }, E({ "thing", "glow" }), "1, 2, 3", "lit"), "a color4: a swatch, 4 numbers")
check(tr.fire[4] == "choice" and tr.fire[11]:find("|up|", 1, true), "a key: a drop-down of keys")
check(not viewer_prop_set(tw, { "/objects/t" }, E({ "thing", "fire" }), "zz", "str"), "... only keys")
check(tr.look[4] == "choice" and tr.look[11] == "none|/assets/ship", "an asset: a drop-down of the assets (" .. tostring(tr.look[11]) .. ")")
check(viewer_prop_pick(tw, { "/objects/t" }, E({ "thing", "look" }), "/assets/ship") and th.look == "/assets/ship", "... picked")
check(viewer_prop_pick(tw, { "/objects/t" }, E({ "thing", "look" }), "none") and th.look == "", "... none: \"\"")
check(not viewer_prop_set(tw, { "/objects/t" }, E({ "thing", "target" }), "/objects/nobody", "str"), "a node: only one that's there")
check(viewer_prop_set(tw, { "/objects/t" }, E({ "thing", "target" }), "/objects/o", "str") and tr.target[11]:find("/objects/o", 1, true), "... /objects/o, in its list")
local trow = rows("/classes/thing")
check(trow.heading and trow.range and trow.range[3] == "none", "an angle member: a range row too")
local tn = rows("/classes/ship")
w = ww
local names = ""
for _, x in ipairs(viewer_props(tw, { "/classes/thing" })) do if x[2] == "pos" then names = x[11] end end
for _, t in ipairs({ "vec2", "vec3", "vec4", "quat", "rect", "angle", "color3", "color4", "key", "asset", "node" }) do
  check(("|" .. names .. "|"):find("|" .. t .. "|", 1, true), "the type list has " .. t)
end
check(not ("|" .. names .. "|"):find("|color|", 1, true), "... not the old color")
-- a node's own typed fields (meta): + component > a plain type, named, its type kept
local mw = ecs.world()
mw:spawn("/objects/o", {})
mw:spawn("/classes/ship", { hp = { type = "int", value = 3 } })
mw:spawn("/systems/move", { system = 1 })
mw:spawn("/data/rules", { win = 7 })
local ww2 = w
w = mw
viewer_rename = nil
check(viewer_prop_pick(mw, { "/data/rules" }, E({ "?add" }), "vec3", ""), "/data/rules: + component > vec3")
local rc = mw:node("/data/rules").c
check(type(rc.vec3) == "table" and rc.vec3.z == 0 and rc.meta.vec3.type == "vec3", "... a field vec3 = { 0, 0, 0 }, its type in meta")
check(viewer_rename == E({ "?m", "vec3" }), "... and its name is typed at once (viewer_rename)")
check(viewer_prop_set(mw, { "/data/rules" }, E({ "?m", "vec3" }), "velocity", "lit"), "renamed: velocity")
check(rc.velocity and not rc.vec3 and rc.meta.velocity and not rc.meta.vec3, "... its value and its type")
r = rows("/data/rules")
check(r.velocity and r.velocity[4] == "member_row" and r.velocity[3] == "vec3" and r.value and r.value[3] == "0, 0, 0", "its rows: name, type, kind; its value (one row)")
check(not r.meta and r.win and r.win[4] == "num", "meta hidden; an untyped field as before")
check(viewer_prop_set(mw, { "/data/rules" }, E({ "velocity" }), "1, 2, 3", "lit") and rc.velocity.y == 2, "its value set: 1, 2, 3")
check(viewer_prop_pick(mw, { "/data/rules" }, E({ "?m", "velocity" }), "int", "type") and rc.velocity == 0 and rc.meta.velocity.type == "int", "retyped: int, its value starts again")
check(viewer_prop_set(mw, { "/data/rules" }, E({ "?range", "velocity" }), "1..5", "lit") and rc.velocity == 1 and rows("/data/rules").value[10] == "range 1 5 1", "a range: 1..5, a slider")
check(not viewer_prop_set(mw, { "/data/rules" }, E({ "velocity" }), "9.5", "num") , "... an int")
viewer_prop_set(mw, { "/data/rules" }, E({ "velocity" }), "9", "num")
check(rc.velocity == 5, "... kept in its range")
viewer_prop_pick(mw, { "/objects/o" }, E({ "?add" }), "node", "")
check(mw:node("/objects/o").c.node == "" and rows("/objects/o").value[4] == "choice", "an object: + component > node: none, a drop-down")
check(viewer_prop_pick(mw, { "/objects/o" }, E({ "node" }), "/objects/o") and mw:node("/objects/o").c.node == "/objects/o", "... a node picked")
viewer_prop_pick(mw, { "/objects/o" }, E({ "?add" }), "key", "")
check(mw:node("/objects/o").c.key == "space" and mw:node("/objects/o").c.meta.key.type == "key", "+ component > key: space")
check(viewer_prop_pick(mw, { "/objects/o" }, E({ "?m", "key" }), "[] array", "kind") and #mw:node("/objects/o").c.key == 0, "its kind: [] array")
check(not viewer_prop_set(mw, { "/objects/o" }, E({ "?m", "key" }), "meta", "lit"), "meta: reserved")
check(viewer_prop_pick(mw, { "/objects/o" }, E({ "?m", "key" }), "Remove", "name") and mw:node("/objects/o").c.key == nil and not mw:node("/objects/o").c.meta.key, "removed: value and type")
viewer_prop_pick(mw, { "/objects/o" }, E({ "?m", "node" }), "Remove", "name")
check(mw:node("/objects/o").c.meta == nil, "no typed fields left: no meta")
check(not viewer_prop_set(mw, { "/classes/ship" }, E({ "?member" }), "meta", "lit") and not viewer_prop_set(mw, { "/classes" }, E({ "?class" }), "meta", "lit"),
      "meta: no member, no class of that name")
-- + object, + child, + data
check(rows("/objects")["+ object"] and rows("/data")["+ data"] and rows("/objects/o")["+ child"] and rows("/data/rules")["+ child"], "+ object, + data, + child")
check(not rows("/systems/move")["+ child"] and not rows("/systems")["+ object"], "... not in /systems")
check(viewer_prop_set(mw, { "/objects" }, E({ "?new" }), "crate", "lit") and mw:node("/objects/crate") and mw:node("/objects/crate").c.xform.x == 0, "+ object crate: at 0, 0")
check(viewer_select == "/objects/crate", "... selected")
check(not viewer_prop_set(mw, { "/objects" }, E({ "?new" }), "crate", "lit"), "... one that's there: no")
check(not viewer_prop_set(mw, { "/objects" }, E({ "?new" }), "a/b", "lit"), "... a name: no slashes")
check(viewer_prop_set(mw, { "/objects/crate" }, E({ "?new" }), "lid", "lit") and mw:node("/objects/crate/lid"), "+ child lid")
check(viewer_prop_set(mw, { "/data" }, E({ "?new" }), "levels", "lit") and mw:node("/data/levels") and next(mw:node("/data/levels").c) == nil, "+ data levels: empty")
-- a leftover meta on a class (the old way): ignored
mw:spawn("/classes/old", { life = 1.5, meta = { life = "number 0.2..5" } })
mw:spawn("/objects/x", { old = {} })
check(mw:node("/objects/x").c.old.life == 1.5 and mw:node("/objects/x").c.old.meta == nil, "a class's leftover meta: not a member, not copied")
check(not rows("/classes/old").meta, "... not shown")
w = ww2
-- the tree's menu: rename, duplicate, delete; + system
local tw2 = ecs.world()
tw2:spawn("/systems/move", { system = ecs.code("return function(w, dt) end") })
tw2:spawn("/systems", { order = { "move" } })
tw2:spawn("/classes/ship", { hp = { type = "int", value = 3 } })
tw2:spawn("/objects/a", { ship = { hp = 5 } })
tw2:spawn("/objects/a/gun", { xform = { x = 1, y = 0 } })
viewer_history = {}  -- (the tree's Undo: nothing done yet here)
check(viewer_tree_menu(tw2, "/objects/a") == "New node|New component|Rename|Duplicate|Delete", "the tree's menu: new node / component, rename, duplicate, delete")
check(viewer_tree_menu(tw2, "/objects") == "New node" and viewer_tree_menu(tw2, "/") == "" and viewer_tree_menu(tw2, "/classes/int") == "", "... a root: only new; not for /, nor built-ins")
viewer_naming, viewer_rename = nil, nil
check(viewer_tree_action(tw2, "/objects/a", "Rename") and viewer_select == "/objects/a" and viewer_rename == E({ "?name" }), "Rename: selected, its name typed")
local nr
for _, x in ipairs(viewer_props(tw2, { "/objects/a" })) do if x[1] == E({ "?name" }) then nr = x end end
check(nr and nr[3] == "a" and viewer_props(tw2, { "/objects/a" })[1][1] == E({ "?name" }), "... a name row, first")
check(viewer_prop_set(tw2, { "/objects/a" }, E({ "?name" }), "hero", "lit"), "typed: hero")
check(tw2:node("/objects/hero") and tw2:node("/objects/hero/gun") and not tw2:node("/objects/a") and tw2:node("/objects/hero").c.ship.hp == 5, "... moved, with what's below it")
check(viewer_select == "/objects/hero" and viewer_naming == nil, "... selected; the name row gone")
local hr = false
for _, x in ipairs(viewer_props(tw2, { "/objects/hero" })) do if x[1] == E({ "?name" }) then hr = true end end
check(not hr, "... no name row now")
check(viewer_tree_action(tw2, "/objects/hero", "Duplicate") and tw2:node("/objects/hero2") and tw2:node("/objects/hero2/gun"), "Duplicate: hero2, what's below it too")
check(tw2:node("/objects/hero2").c.ship ~= tw2:node("/objects/hero").c.ship and viewer_select == "/objects/hero2" and viewer_naming == "/objects/hero2", "... copies; selected, its name typed")
viewer_tree_action(tw2, "/objects/hero2", "Duplicate")
check(tw2:node("/objects/hero3"), "... again: hero3")
check(viewer_tree_delete_what(tw2, "/objects/hero3"):find("1 node below it", 1, true), "Delete asks: " .. viewer_tree_delete_what(tw2, "/objects/hero3"))
check(viewer_tree_action(tw2, "/objects/hero3", "Delete") and not tw2:node("/objects/hero3") and not tw2:node("/objects/hero3/gun") and viewer_select == "/objects", "Delete: gone; its parent selected")
check(viewer_tree_delete_what(tw2, "/classes/ship"):find("keep", 1, true), "deleting a class says its nodes keep the component: " .. viewer_tree_delete_what(tw2, "/classes/ship"))
check(viewer_tree_action(tw2, "/classes/ship", "Rename") and viewer_prop_set(tw2, { "/classes/ship" }, E({ "?name" }), "boat", "lit"), "a class renamed: boat")
check(tw2:node("/classes/boat") and tw2:node("/objects/hero").c.boat and not tw2:node("/objects/hero").c.ship, "... its nodes' components too")
viewer_tree_action(tw2, "/classes/boat", "Rename")
check(not viewer_prop_set(tw2, { "/classes/boat" }, E({ "?name" }), "meta", "lit"), "... not meta")
viewer_tree_action(tw2, "/objects/hero2", "Rename")
check(not viewer_prop_set(tw2, { "/objects/hero2" }, E({ "?name" }), "hero", "lit"), "a name that's there: no")
local sr = {}
for _, x in ipairs(viewer_props(tw2, { "/systems" })) do sr[x[2]] = x end
check(sr["+ system"], "/systems: + system")
check(viewer_prop_set(tw2, { "/systems" }, E({ "?new" }), "spin", "lit") and ecs.is_code(tw2:node("/systems/spin").c.system), "+ system spin: its code, empty")
check(tw2:node("/systems").c.order[2] == "spin", "... last in the run order")
viewer_tree_action(tw2, "/systems/spin", "Rename")
viewer_prop_set(tw2, { "/systems/spin" }, E({ "?name" }), "turn", "lit")
check(tw2:node("/systems").c.order[2] == "turn", "a system renamed: the run order too")
viewer_tree_action(tw2, "/systems/turn", "Delete")
check(#tw2:node("/systems").c.order == 1, "... deleted: out of the order")
-- the old shorthand: plain values
local u = ecs.world()
u:spawn("/objects/x", {})
u:spawn("/classes/shot", { life = 1.5 })
u:spawn("/objects/s", { shot = {} })
check(u:node("/objects/s").c.shot.life == 1.5, "a plain value: short for a member (life = 1.5)")
local bf = ecs.copy(u:node("/classes/shot").c)
u:node("/classes/shot").c.life = { type = "number", value = 2, min = 0.2, max = 5 }
check(u:upgrade_class("shot", bf) == 1 and u:node("/objects/s").c.shot.life == 2, "... described later: its nodes upgrade")
print(fails == 0 and "classes props: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

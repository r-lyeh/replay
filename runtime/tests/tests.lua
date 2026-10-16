-- tests.lua  (run: luajit tests.lua)
local here = (arg and arg[0] or ""):match("^(.*[/\\\\])") or ""
package.path = here .. "../?.lua;" .. here .. "../?/init.lua;" .. here .. "?.lua;" .. package.path
local ecs=require"ecs"
local m=ecs.match
assert(m("/**","/")) assert(m("/**","/a/b")) assert(m("/a/**","/a")) assert(m("/a/**","/a/b/c"))
assert(not m("/a/*","/a")) assert(m("/a/*","/a/b")) assert(not m("/a/*","/a/b/c"))
assert(m("/a/p*/m?rio","/a/players/mario")) assert(not m("/a/b","/a/bc"))
assert(m("/a/**/c","/a/c")) assert(m("/a/**/c","/a/x/y/c"))
local w=ecs.world() w:spawn("/s",{t={"a\nb\0c", 0.1, 1/0, -3, [10]=true, ["weird key"]=1, [true]=false}})
local ok,b=ecs.save(w,"/**") assert(ok,b)
local ok2,w2=ecs.load(b) assert(ok2,w2)
local ok3,b2=ecs.save(w2,"/**") assert(b==b2, "roundtrip") print("serialize ok")
do
local function S(w) return select(2, ecs.save(w,"/**")) end
local function mk(paths) local w=ecs.world() for _,p in ipairs(paths) do w:spawn(p,{v=p}) end return w end
-- nested removal: only top removed path listed
local a=mk{"/a/b/c","/a/b/d","/x"} local b=mk{"/x"}
local ok,p=ecs.diff(a,b) assert(ok,p) assert(p:find('"/a"') and not p:find('/a/b"'), p)
assert(ecs.patch(p,"/",a)) assert(S(a)==S(b))
-- diff to empty world empties root
local a=mk{"/a","/b"} local ok,p=ecs.diff(a,ecs.world()) assert(ecs.patch(p,"/",a)) assert(S(a)==S(ecs.world()), S(a))
-- random fuzz: diff/patch always converges
math.randomseed(1)
for i=1,300 do
  local function rnd() local w=ecs.world() for k=1,math.random(0,8) do local p="" for d=1,math.random(1,3) do p=p.."/"..string.char(96+math.random(1,3)) end w:spawn(p,{n=math.random(1,3)}) end return w end
  local a,b=rnd(),rnd() local ok,p=ecs.diff(a,b) assert(ok,p) assert(ecs.patch(p,"/",a)) assert(S(a)==S(b), "fuzz "..i)
  -- scoped save/load also converges
  local c,d=rnd(),rnd() local _,blob=ecs.save(d,"/a/**") assert(ecs.load(blob,"/",c))
  assert(select(2,ecs.save(c,"/a/**"))==blob, "scope "..i)
end
-- scope with * mounted elsewhere
local w=mk{"/m/p/x","/m/p/y","/m/q"} local _,blob=ecs.save(mk{"/p/x"},"/p/*")
assert(ecs.load(blob,"/m",w)) assert(w:node("/m/p/x") and not w:node("/m/p/y") and w:node("/m/q"))
-- bad blob is atomic
local w=mk{"/a"} local before=S(w)
print(ecs.load('return {version=1, removed={"/a"}, nodes={["/b"]=5}}',"/",w)) assert(S(w)==before)
print("all ok")
end
do -- disk: world <-> folder
  local disk, fs = require("disk"), require("fs")
  local dir = here .. "test_world_tmp"
  local function rmtree(d)
    for _, e in ipairs(fs.list(d)) do
      local p = fs.join(d, e.name)
      if e.dir then rmtree(p) else fs.rmfile(p) end
    end
    fs.rmdir(d)
  end
  rmtree(dir)
  local w = ecs.world()
  w:spawn("/a/x.lua", { ["weird name"] = { 1, 2 }, CON = true })
  w:spawn("/a/CON/b c", { v = "é\n\"q\"" })
  w:spawn("/a/empty")
  w:spawn("/big", { lines = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 } })
  local d = disk.new(dir)
  assert(d:flush(w, "/**"))
  local ok, blob = d:read("/**") assert(ok, blob)
  assert(blob == select(2, w:save("/**")), "disk round trip")
  -- stale nodes and leaves are removed, foreign files kept
  fs.write(dir .. "/a/notes.txt", "keep me")
  w:remove("/a/CON")
  w:unset("/a/x.lua", "CON")
  assert(d:flush(w, "/**"))
  assert(select(2, d:read("/**")) == select(2, w:save("/**")), "disk mirror")
  assert(fs.read(dir .. "/a/notes.txt") == "keep me")
  -- scoped read/pull and changes()
  fs.write(dir .. "/a/empty/n.lua", "return 7")
  local ch = d:changes("/**") assert(#ch == 1 and ch[1] == "/a/empty", table.concat(ch, ","))
  local w2 = ecs.world() w2:spawn("/a/empty/old", {}) w2:spawn("/other", { k = 1 })
  assert(d:pull(w2, "/a/**"))
  assert(w2:node("/a/empty").c.n == 7 and not w2:node("/a/empty/old") and w2:node("/other"))
  -- a bad leaf (syntax error) fails the whole read, nothing applied
  fs.write(dir .. "/big/bad.lua", "return { 1, ")
  local before = select(2, w2:save("/**"))
  assert(not d:pull(w2, "/**"))
  assert(select(2, w2:save("/**")) == before)
  -- a leaf that needs globals is code, not data: kept as source, and in
  -- the code sandbox it has no os
  fs.write(dir .. "/big/bad.lua", "return os.exit()")
  assert(d:pull(w2, "/**"))
  assert(ecs.is_code(w2:node("/big").c.bad))
  w2:tick("/**", 0.1)
  assert(w2.code_err["/big/bad"]:find("os"), w2.code_err["/big/bad"])
  -- code leaves round-trip verbatim
  local src = "-- move\nreturn { requires = { 'pos', 'vel' }, run = function(w, n, dt)\n  n.c.pos.x = n.c.pos.x + n.c.vel.x * dt\nend }\n"
  w2:unset("/big", "bad")
  w2:spawn("/game/systems", { move = ecs.code(src) })
  assert(d:flush(w2, "/**"))
  assert(fs.read(dir .. "/game/systems/move.lua") == src)
  local ok3, blob3 = d:read("/**") assert(ok3, blob3)
  assert(blob3 == select(2, w2:save("/**")), "code leaf round trip")
  -- foreign names are ignored and kept; same-value leaves keep their formatting
  fs.write(dir .. "/.workspace.lua", "return { x = 1 }")
  fs.mkdir(dir .. "/.git")
  fs.write(dir .. "/game/systems/../../a/pretty.lua", "-- my comment\nreturn {\n  1,\n  2,\n}\n")
  local okp, w4 = ecs.load(select(2, d:read("/**")))
  assert(okp and not w4:node("/").c[".workspace"] and not w4:node("/.git"), "foreign names ignored")
  assert(w4:node("/a").c.pretty[2] == 2)
  assert(d:flush(w4, "/**"))
  assert(fs.read(dir .. "/.workspace.lua") == "return { x = 1 }", "foreign file kept")
  assert(fs.read(dir .. "/a/pretty.lua"):find("my comment"), "same value: file untouched")
  w4:node("/a").c.pretty[2] = 3
  assert(d:flush(w4, "/**"))
  assert(not fs.read(dir .. "/a/pretty.lua"):find("my comment"), "changed value: rewritten")
  rmtree(dir .. "/.git")
  fs.rmfile(dir .. "/.workspace.lua")
  rmtree(dir)
  print("disk ok")
end
do -- code leaves -> systems
  local w = ecs.world()
  w:spawn("/ball", { pos = { x = 0 }, vel = { x = 10 } })
  w:spawn("/game/systems", {
    move = ecs.code("return { requires = { 'pos', 'vel' }, run = function(w, n, dt) n.c.pos.x = n.c.pos.x + n.c.vel.x * dt end }"),
    count = ecs.code("return function(w, dt) w:node('/ball').c.ticks = (w:node('/ball').c.ticks or 0) + 1 end"),
  })
  w:system("script", { "pos" }, function(w, n) n.c.seen = true end)
  w:tick("/**", 1)
  local b = w:node("/ball").c
  assert(b.pos.x == 10 and b.ticks == 1 and b.seen, "code systems run")
  assert(w.order[1] == "script" and w.order[2] == "/game/systems/count" and w.order[3] == "/game/systems/move")
  -- hot swap: same slot, new behaviour
  w:set("/game/systems", "move", ecs.code("return { requires = { 'pos' }, run = function(w, n, dt) n.c.pos.x = -1 end }"))
  w:tick("/**", 1)
  assert(b.pos.x == -1 and w.order[3] == "/game/systems/move", "hot swap")
  -- compile error: old version keeps running, error reported
  w:set("/game/systems", "move", ecs.code("return { run = function( end }"))
  b.pos.x = 5 w:tick("/**", 1)
  assert(b.pos.x == -1 and w.code_err["/game/systems/move"], "keeps old on syntax error")
  -- runtime error: only that system stops, until its source changes
  w:set("/game/systems", "move", ecs.code("return function(w) error('boom') end"))
  w:tick("/**", 1) w:tick("/**", 1)
  assert(b.ticks == 5 and w.code_err["/game/systems/move"]:find("boom"), "runtime error isolated")
  w:set("/game/systems", "move", ecs.code("return function(w) w:node('/ball').c.fixed = true end"))
  w:tick("/**", 1)
  assert(b.fixed and not w.code_err["/game/systems/move"], "fixed by editing")
  -- sandbox: no io/os/load; libs are copies; require loads the world's modules only (never the host's)
  w:set("/game/systems", "move", ecs.code("return function(w) local ok, e = pcall(require, 'io') ; w:node('/ball').c.env = tostring(io) .. tostring(os) .. tostring(load) .. tostring(ok) .. tostring(e):match('no module') ; math.pi = 3 end"))
  w:tick("/**", 1)
  assert(b.env == "nilnilnilfalseno module" and math.pi ~= 3, "sandbox")
  -- removing the component removes the system; snapshots carry the code
  local _, blob = w:save("/**")
  w:unset("/game/systems", "move")
  w:tick("/**", 1)
  assert(not w.systems["/game/systems/move"] and #w.order == 2, "unsystem")
  local ok, w3 = ecs.load(blob) assert(ok, w3)
  w3:tick("/**", 1)
  assert(w3.systems["/game/systems/move"] and w3:node("/ball").c.ticks == 8, "code replicates as data")
  -- the root's order list: systems and children sorted by first matching line
  local wo = ecs.world()
  wo:spawn("/n", { log = {} })
  wo:spawn("/sys", { a = ecs.code("return function(w) table.insert(w:node('/n').c.log, 'a') end"),
                   z = ecs.code("return { requires = { 'log' }, run = function(w, n) table.insert(n.c.log, 'z') end }") })
  wo:tick("/**", 1)
  assert(table.concat(wo:node("/n").c.log) == "az", "alphabetical by default")
  wo:node("/").c.order = { "/sys/z" }
  wo:node("/n").c.log = {}
  wo:tick("/**", 1)
  assert(table.concat(wo:node("/n").c.log) == "za", table.concat(wo:node("/n").c.log))
  for _, p in ipairs({ "/k/a", "/k/b", "/k/ship1", "/k/ship2", "/k/c" }) do wo:spawn(p, {}) end
  wo:node("/").c.order = { "/k/c", "/k/ship*", "/s/z" }
  local names = {}
  for _, ch in ipairs(wo:children("/k")) do names[#names + 1] = ch.name end
  assert(table.concat(names, " ") == "c ship1 ship2 a b", table.concat(names, " "))
  print("code ok")
end
do -- the layout: /systems (their order), /classes defaults, live /objects and /entities, /tmp never saved
  local w = ecs.world()
  w:spawn("/classes/paddle", { speed = 3, up = "w" })
  w:spawn("/systems/b", { system = ecs.code("return { requires = { 'log' }, run = function(w, n) table.insert(n.c.log, 'b') end }") })
  w:spawn("/systems/a", { system = ecs.code("return { requires = { 'log' }, run = function(w, n) table.insert(n.c.log, 'a') end }") })
  w:spawn("/data/rules", { log = {} })             -- (not live: no system runs on it)
  w:spawn("/objects/thing", { log = {}, paddle = { up = "i" } })
  w:tick("/**", 1)
  assert(table.concat(w:node("/objects/thing").c.log) == "ab", "systems by name: " .. table.concat(w:node("/objects/thing").c.log))
  assert(#w:node("/data/rules").c.log == 0, "/data is not live")
  w:node("/systems").c.order = { "b", "a" }
  w:node("/objects/thing").c.log = {}
  w:tick("/**", 1)
  assert(table.concat(w:node("/objects/thing").c.log) == "ba", "/systems' order is the run order")
  local p = w:node("/objects/thing").c.paddle
  assert(p.up == "i" and p.speed == 3, "spawn fills a component's missing fields from /classes")
  local names = {}
  w:spawn("/tmp/scratch", { x = 1 })
  for _, ch in ipairs(w:children("/")) do names[#names + 1] = ch.name end
  assert(table.concat(names, " ") == "data classes objects systems tmp", "the roots in the layout's order: " .. table.concat(names, " "))
  local _, blob = w:save("/**")
  assert(not blob:find("scratch", 1, true), "/tmp is never saved")
  assert(w:load(blob, "/") and w:node("/tmp/scratch").c.x == 1, "/tmp survives a load")
  w:spawn("/entities/bullet", { log = {} })
  w:tick("/**", 1)
  assert(#w:node("/entities/bullet").c.log == 2, "/entities is live")
  names = {}
  for _, ch in ipairs(w:children("/")) do names[#names + 1] = ch.name end
  assert(table.concat(names, " ") == "data classes objects systems entities tmp", "objects, systems, entities: " .. table.concat(names, " "))
  -- /entities: in saves (the timeline, the network), never on disk
  assert(select(2, w:save("/**")):find("bullet", 1, true), "/entities is in saves")
  assert(not select(2, w:save("/**", true)):find("bullet", 1, true), "/entities is not in disk saves")
  local base = select(2, w:save("/**", true))
  local _, ov, count = ecs.overrides(base, w)
  assert(count == 0 and not ov:find("bullet", 1, true), "/entities is not an override")
  local disk, fs = require("disk"), require("fs")
  local dir = here .. "test_layout_tmp"
  local d = disk.new(dir)
  assert(d:flush(w, "/**"))
  assert(not fs.isdir(dir .. "/entities") and not fs.isdir(dir .. "/tmp"), "/entities and /tmp: no folders written")
  fs.mkdir(dir .. "/entities"); fs.mkdir(dir .. "/entities/old"); fs.write(dir .. "/entities/old/hp.lua", "return 1")
  assert(not select(2, d:read("/**")):find("old", 1, true), "/entities on disk: not read")
  assert(d:flush(w, "/**") and fs.read(dir .. "/entities/old/hp.lua") == "return 1", "/entities on disk: left alone")
  fs.rmfile(dir .. "/entities/old/hp.lua"); fs.rmdir(dir .. "/entities/old"); fs.rmdir(dir .. "/entities")
  local function rmtree(x)
    for _, e in ipairs(fs.list(x)) do
      local q = fs.join(x, e.name)
      if e.dir then rmtree(q) else fs.rmfile(q) end
    end
    fs.rmdir(x)
  end
  rmtree(dir)
  -- a class edited: its nodes' values that were never overridden follow
  do
    local u = ecs.world()
    u:spawn("/classes/ship", { image = "ship.png", hp = 10, tint = { 1, 2, 3 } })
    u:spawn("/objects/a", { ship = {} })                       -- all from the class
    u:spawn("/objects/b", { ship = { image = "my_player.png" } })   -- its own image
    local before = ecs.copy(u:node("/classes/ship").c)
    local cls = u:node("/classes/ship").c
    cls.image, cls.hp, cls.tint[1], cls.speed = "ship2.png", 12, 9, 4
    local k = u:upgrade_class("ship", before)
    local a, b = u:node("/objects/a").c.ship, u:node("/objects/b").c.ship
    assert(a.image == "ship2.png" and a.hp == 12 and a.tint[1] == 9 and a.speed == 4, "never overridden: upgraded")
    assert(b.image == "my_player.png" and b.hp == 12 and b.speed == 4, "overridden: kept (the rest upgraded)")
    assert(a.tint ~= cls.tint, "copies, not the class's own tables")
    assert(k == 7, "7 values upgraded: " .. k)
    assert(u:upgrade_class("ship", ecs.copy(cls)) == 0, "nothing changed: nothing to do")
  end
  print("layout ok")
end
do -- field-level overrides
  local function S(w) return select(2, w:save("/**")) end
  local base = ecs.world()
  base:spawn("/box", { xform = { x = 330, y = 150, r = 0.3 }, color = { 255, 90, 200 }, spin = -0.5,
                       sys = ecs.code("return function() end") })
  base:spawn("/old/child", { v = 1 })
  base:spawn("/keep", { arr = { 1, 2, 3 } })
  local ok, edited = ecs.load(S(base)) assert(ok)
  edited:node("/box").c.xform.x = 380              -- one field
  edited:node("/box").c.spin = nil                 -- unset
  edited:node("/keep").c.arr = { 1, 2 }            -- shrink an array
  edited:remove("/old")
  edited:spawn("/new/thing", { hp = 3 })
  local ok2, ov, n = ecs.overrides(base, edited) assert(ok2, ov)
  assert(ov:find("x = 380") and not ov:find("330") and not ov:find("color"), "only changed fields:\n" .. ov)
  -- the base changes elsewhere (e.g. the script): those changes still come through
  base:node("/box").c.color = { 1, 2, 3 }
  local ok3, w = ecs.load(S(base)) assert(ok3)
  assert(ecs.apply_overrides(w, ov))
  local b = w:node("/box").c
  assert(b.xform.x == 380 and b.xform.y == 150 and b.spin == nil and b.color[1] == 1, "merge")
  assert(ecs.is_code(b.sys))
  assert(not w:node("/old") and w:node("/new/thing").c.hp == 3, "removed / new nodes")
  assert(#w:node("/keep").c.arr == 2, "array shrink")
  -- no differences: nothing to store
  local ok4, ov2, n2 = ecs.overrides(base, base) assert(ok4 and n2 == 0, ov2)
  assert(not ecs.apply_overrides(w, "return { version = 1, nodes = {} }"), "rejects other blobs")
  print("overrides ok")
end
do -- hurdy code leaves: compile, run, error lines, folder round trip
  if not pcall(require, "hurdyl") then print("hurdy skipped (no runtime/hurdyl)") else
  local disk, fs = require("disk"), require("fs")
  local w = ecs.world()
  w:spawn("/n", { x = 0 })
  w:spawn("/sys", { inc = ecs.code("return { requires = { 'x' }, run = function(w, n, dt) {\n  n.c.x += dt\n} }\n", "hurdy") })
  assert(ecs.is_code(w:node("/sys").c.inc))
  local src, lang = ecs.code_source(w:node("/sys").c.inc) assert(lang == "hurdy" and src:find("+="))
  w:tick("/**", 2) assert(w:node("/n").c.x == 2, "hurdy system ran")
  w:node("/sys").c.inc = ecs.code("return function(w, dt) {\n\n  var t = nil\n  t.x = 1\n}\n", "hurdy")
  w:tick("/**", 1) assert(w.code_err["/sys/inc"]:find("^/sys/inc:4:"), w.code_err["/sys/inc"])
  w:node("/sys").c.inc = ecs.code("return function(w, dt) {\n  var = 1\n}\n", "hurdy")
  w:tick("/**", 1) assert(w.code_err["/sys/inc"]:find("^/sys/inc:2:"), w.code_err["/sys/inc"])
  -- folder: name.hurdy <-> { __hurdy = src }; switching language swaps the file
  local dir = here .. "test_hurdy_tmp"
  local function rmtree(p)
    for _, e in ipairs(fs.list(p)) do
      local q = fs.join(p, e.name)
      if e.dir then rmtree(q) else fs.rmfile(q) end
    end
    fs.rmdir(p)
  end
  rmtree(dir) fs.mkdir(dir)
  local d = disk.new(dir)
  w:node("/sys").c.inc = ecs.code("return function(w, dt) { }\n", "hurdy")
  assert(d:flush(w))
  assert(fs.read(dir .. "/sys/inc.hurdy") == "return function(w, dt) { }\n", "written as .hurdy")
  local ok, blob = d:read() assert(ok, blob)
  local w2 = ecs.world() assert(w2:load(blob, "/"))
  assert(select(2, ecs.code_source(w2:node("/sys").c.inc)) == "hurdy", "read back as hurdy")
  w:node("/sys").c.inc = ecs.code("return function(w, dt) end\n")
  assert(d:flush(w))
  assert(fs.read(dir .. "/sys/inc.lua") and not fs.read(dir .. "/sys/inc.hurdy"), "now .lua, .hurdy gone")
  fs.write(dir .. "/sys/inc.hurdy", "return function(w, dt) { }\n")
  assert(not d:read(), "inc.lua + inc.hurdy: refused")
  rmtree(dir)
  print("hurdy ok")
  end
end
do -- ecs.system(function() ... end): the body becomes a code leaf (Lua and hurdy)
  local src = "local ecs = require('ecs')\nlocal w = ecs.world()\n"
           .. "local inc = ecs.system(function()\n  -- adds dt\n  return { requires = { 'x' }, run = function(w, n, dt)\n    n.c.x = n.c.x + dt\n  end }\nend)\n"
           .. "w:spawn('/n', { x = 0 })\nw:spawn('/sys', { inc = inc })\nreturn w\n"
  local w = assert(ecs.loadscript(src, "sys_test.lua"))()
  local body, lang = ecs.code_source(w:node("/sys").c.inc)
  assert(lang == "lua" and body:sub(1, 10) == "-- adds dt" and body:find("\nend }\n$"), body)
  w:tick("/**", 3) assert(w:node("/n").c.x == 3)
  local bad = "local ecs = require('ecs')\nlocal k = 1\nreturn ecs.system(function()\n  return function() return k end\nend)\n"
  local ok, err = pcall(assert(ecs.loadscript(bad, "sys_bad.lua")))
  assert(not ok and err:find("outer local%(s%) k"), err)
  if pcall(require, "hurdyl") then
    local h = "var ecs = require(\"ecs\")\nvar w = ecs.world()\nvar inc = ecs.system(function() {\n"
           .. "  var s = \"}\" -- a } in a string\n  return function(w, dt) {\n    w:node(\"/n\").c.x += dt\n  }\n})\n"
           .. "w:spawn(\"/n\", { x = 0 })\nw:spawn(\"/sys\", { inc = inc })\nreturn w\n"
    local hw = assert(ecs.loadscript(h, "sys_test.hurdy", "hurdy"))()
    local hb, hl = ecs.code_source(hw:node("/sys").c.inc)
    assert(hl == "hurdy" and hb:sub(1, 9) == 'var s = "' and hb:find("\n}\n$"), hb)
    hw:tick("/**", 2) assert(hw:node("/n").c.x == 2)
  end
  print("ecs.system ok")
end
do -- nodegraph plugin (lite): the parser and the graph layout, headless
  local root = here .. "../../"
  local saved = package.path
  package.path = root .. "plugins/nodegraph/?.lua;" .. package.path
  local okp, P = pcall(require, "luaparse")
  local okg, G = pcall(require, "graph")
  local okr, R = pcall(require, "resolve")
  package.path = saved
  assert(okp and okg, "nodegraph: plugins/nodegraph/luaparse.lua, graph.lua: " .. tostring(not okp and P or G))
  do
    local font = { get_width = function(_, s) return #s * 7 end, get_height = function() return 14 end }
    local files, n = {}, 0
    local p = io.popen('find "' .. root .. 'games" "' .. root .. 'plugins/nodegraph/tests" -name "*.lua" 2>/dev/null')   -- (plugins/nodegraph/tests/: node graph samples)
    if p then for f in p:lines() do files[#files + 1] = f end p:close() end
    for _, f in ipairs(files) do
      local src = io.open(f):read("*a")
      local ast, err = P.parse(src)
      assert(ast, f .. ": " .. tostring(err))
      assert((load or loadstring)(src) ~= nil, f .. ": parses but Lua says no")
      local g = G.build(ast, { font = font, res = okr and R.resolve(ast) or nil })
      for _, l in ipairs(g.links) do                 -- a link joins an output to an input of the same variable
        local o, i = g.nodes[l.from].outs[l.out], g.nodes[l.to].ins[l.inp]
        if l.expr then                               -- or an expression node to the slot it stands for
          local en = g.nodes[l.from]
          assert(o and o.value and i and i.kind == "expr" and en.kind == "expr", f .. ": a bad expression link")
          assert(src:sub(i.pos, i.epos) == src:sub(en.fields.body.pos, en.fields.body.epos), f .. ": expression node and slot differ")
        else
          assert(o and i and o.decl == i.decl, f .. ": a link joins different variables")
        end
      end
      for _, nd in ipairs(g.nodes) do                -- every expression node feeds exactly one slot
        if nd.kind == "expr" then
          local k = 0
          for _, l in ipairs(g.links) do if l.expr and l.from == nd.id then k = k + 1 end end
          assert(k == 1, f .. ": an expression node wired " .. k .. " times")
        end
      end
      for _, nd in ipairs(g.nodes) do                -- editable spans are exact expressions
        for which, fl in pairs(nd.fields or {}) do if fl.blocked then -- (not editable there)
        elseif fl.rename then
          for _, sp in ipairs(fl.spans) do         -- rename fields: each span is one name
            assert(src:sub(sp[1], sp[2]):match("^[%a_][%w_]*$"), f .. ": rename span is not a name")
          end
        else
          local txt = src:sub(fl.pos, fl.epos)
          local probe = (which == "title" or which:match("^var")) and (txt .. " = nil") or ("local _ = " .. txt)
          assert(P.parse(probe), f .. ":" .. tostring(nd.line) .. ": field is not an expression: " .. txt:sub(1, 40))
        end end
      end
      for i = 1, #g.nodes do for j = i + 1, #g.nodes do
        local a, b = g.nodes[i], g.nodes[j]
        assert(not (a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h),
               f .. ": nodes " .. i .. " and " .. j .. " overlap")
      end end
      n = n + 1
    end
    assert(not P.parse("local x = "), "syntax errors are reported")
    -- layout tags: --@node above a statement, --@frame at the top of a function body
    local tsrc = "local function f(w)\n  --@frame dx=100 dy=50\n  local a = 1\n"
              .. "  --@node dx=7 dy=-3 color=#e06c75 alpha=0.5\n  local b = a + 1\nend\nlocal x = 1 local y = 2\n"
    local plain = tsrc:gsub("[^\n]*%-%-@[^\n]*\n", "")
    local g0, g1 = G.build(P.parse(plain), { font = font }), G.build(P.parse(tsrc), { font = font })
    local function find(g, title)                  -- "local a": the "new local" node whose pin is a
      local var = title:match("^local ([%w_]+)$")
      for _, nd in ipairs(g.nodes) do
        if nd.title == title or (var and nd.kind == "local" and nd.ins[1] and nd.ins[1].name == var) then return nd end
      end
    end
    local a0, a1 = find(g0, "local a"), find(g1, "local a")
    assert(a1.x - a0.x == 100 and a1.y - a0.y == 50, "a frame tag moves its body")
    local b0, b1 = find(g0, "local b"), find(g1, "local b")
    assert(b1.x - b0.x == 107 and b1.y - b0.y == 47, "a node tag adds to its frame's")
    assert(b1.color and b1.color[1] == 224 and b1.alpha == 0.5, "colour and alpha")
    assert(find(g1, "local x").edit and find(g1, "local y").edit.inline, "a statement sharing its line takes an inline tag")
    assert(G.tag_text(G.parse_tag("--@node dx=3 dy=4")) == "--@node dx=3 dy=4")
    assert(G.tag_text({ kind = "node", keys = { "dx" }, vals = {} }) == nil, "empty tag: no line")
    -- names: rename every declaration of every file; the globals each chunk
    -- reads must not change (no capture), and the program must still load
    assert(okr, "resolve.lua loads")
    local function globals(src)
      local res = R.resolve(P.parse(src)); local t = {}
      for _, u in ipairs(res.uses) do if not u.decl then t[#t + 1] = u.name end end
      return table.concat(t, " ")
    end
    local renamed = 0
    for _, f in ipairs(files) do
      local src = io.open(f):read("*a")
      local res = R.resolve(P.parse(src))
      local edits = {}
      for i, d in ipairs(res.decls) do if d.pos > 0 then
        local nm = "v" .. i .. "_" .. d.name
        edits[#edits + 1] = { pos = d.pos, epos = d.epos, text = nm }
        for _, r in ipairs(d.refs) do edits[#edits + 1] = { pos = r[1], epos = r[2], text = nm } end
      end end
      local new, map = R.apply(src, edits)
      assert((load or loadstring)(new), f .. ": renamed file does not load")
      assert(globals(new) == globals(src), f .. ": a rename changed the globals")
      assert(R.same_bindings(res, R.resolve(P.parse(new)), map), f .. ": a rename moved a binding")
      renamed = renamed + #res.decls
    end
    -- a capture is refused: renaming b to a makes print(b) read the other a
    local cs = "local a = 1\nlocal b = 2\nprint(a, b)\n"
    local cr = R.resolve(P.parse(cs))
    local bd = cr.decl_at[cs:find("b =")]
    local ce = { { pos = bd.pos, epos = bd.epos, text = "a" } }
    for _, r in ipairs(bd.refs) do ce[#ce + 1] = { pos = r[1], epos = r[2], text = "a" } end
    local cn, cm = R.apply(cs, ce)
    assert(not R.same_bindings(cr, R.resolve(P.parse(cn)), cm), "a capture is detected")
    -- a rewire: c = a + b reads b instead of a; a scope it can't see is refused
    local ws = "local a = 1\nlocal b = 2\nlocal c = a + b\ndo local d = 4 end\nprint(c)\n"
    local wr = R.resolve(P.parse(ws))
    local ua = ws:find("a +", 1, true)
    local wn, wm = R.apply(ws, { { pos = ua, epos = ua, text = "b" } })
    local wres = R.resolve(P.parse(wn))
    assert(R.same_bindings(wr, wres, wm, { [ua] = true }), "a rewire keeps the other bindings")
    local nu; for _, u in ipairs(wres.uses) do if u.pos == wm(ua) then nu = u end end
    assert(nu.decl and nu.decl.pos == wm(ws:find("b =")), "the rewired use reads b")
    local dn, dm = R.apply(ws, { { pos = ua, epos = ua, text = "d" } })
    for _, u in ipairs(R.resolve(P.parse(dn)).uses) do
      if u.pos == dm(ua) then assert(u.decl == nil, "d is not visible there") end
    end
    assert(R.is_name("foo_1") and not R.is_name("end") and not R.is_name("1x"), "is_name")
    -- slots: return 2 + 3 -> a "value" pin fed by an expression node; literals in place
    do
      local code = "local function f(a)\n  local t = 0\n  print(a, \"x\")\n  return 2 + 3\nend\n"
      local ast = P.parse(code)
      local gg = G.build(ast, { font = font, res = R.resolve(ast) })
      local by = {}
      for _, nd in ipairs(gg.nodes) do
        by[nd.title] = nd
        if nd.kind == "local" and nd.ins[1] then by["local " .. nd.ins[1].name] = nd end
      end
      assert(by["local t"].title == "new local" and by["local t"].ins[1].name == "t" and by["local t"].outs[1].silent,
             "set local: the pin carries the name, the output is silent")
      local ret = by["return"]
      assert(ret and ret.ins[1].name == "value" and ret.ins[1].kind == "expr", "return has an expression pin")
      local fed
      for _, l in ipairs(gg.links) do if l.expr and gg.nodes[l.to] == ret then fed = gg.nodes[l.from] end end
      assert(fed and fed.lines[1] == "2 + 3", "fed by the expression node 2 + 3")
      assert(by["local t"].ins[1].kind == "literal" and by["local t"].ins[1].text == "0", "a literal stays in place")
      -- an --@expr line above the statement moves the expression node feeding that pin
      local tagged = code:gsub("  return 2 %+ 3", "  --@expr slot=1 dx=-30 dy=12\n  return 2 + 3")
      local ast2 = P.parse(tagged)
      local g2 = G.build(ast2, { font = font, res = R.resolve(ast2) })
      local function fed_of(gr)
        for _, l in ipairs(gr.links) do if l.expr and gr.nodes[l.to].title == "return" then return gr.nodes[l.from], gr.nodes[l.to] end end
      end
      local e1, r1 = fed_of(gg)
      local e2, r2 = fed_of(g2)
      assert(e2.x - r2.x == e1.x - r1.x - 30 and e2.y - r2.y == e1.y - r1.y + 12, "an expr tag moves its expression node")
      assert(e2.edit and e2.edit.kind == "expr" and tostring(e2.edit.slot) == "1", "expression nodes take tags")
      assert(G.tag_text({ kind = "expr", keys = { "slot" }, vals = { slot = "1" } }) == nil, "a bare slot is no tag")
      -- LuaLS annotations name pins: ---@return on returns and call nodes, ---@param types on the header
      do
        local acode = "---@param a number\n---@return number sum\nlocal function add(a, b)\n  return a + b\nend\n"
                   .. "local s = add(1, math.max(2, 3))\n"
        local aast = P.parse(acode)
        local ag = G.build(aast, { font = font, res = R.resolve(aast) })
        local ab = {}
        for _, nd in ipairs(ag.nodes) do ab[nd.title] = ab[nd.title] or nd end
        assert(ab["return"].ins[1].name == "sum", "---@return names the return pin")
        assert(ab["add"] and ab["add"].callee and ab["add"].outs[1].name == "sum", "and the call node's output")
        assert(ab["add"].ins[2].name == "a" and ab["add"].ins[2].text == "1", "call node pins: parameters, literals")
        assert(ab["math.max"] and ab["math.max"].ins[1].text == "2", "a call inside a call is a call node too")
        local hint
        for _, o in ipairs(ab["local function add"].outs) do if o.name == "a" then hint = o.hint end end
        assert(hint == "number", "---@param types show on the header")
      end
      -- a table constructor: a table node, a row per field; small number tables inline
      do
        local tcode = "return { xform = { x = -176, y = 216 }, color = { 90, 96, 120 }, text = \"hi\", on = true, n = 1.5, tags = { \"a\" } }\n"
        local tast = P.parse(tcode)
        local tg = G.build(tast, { font = font, res = R.resolve(tast) })
        local tn
        for _, nd in ipairs(tg.nodes) do if nd.table and #nd.ins == 7 then tn = nd end end
        assert(tn, "a table node with a row per field (and + add field)")
        assert(tn.ins[7].action == "add", "the last row adds a field")
        local k = {}
        for _, p in ipairs(tn.ins) do k[p.name] = p end
        assert(k.xform.kind == "vector" and #k.xform.comps == 2 and k.xform.comps[1].text == "-176", "a vector row")
        assert(k.color.kind == "color" and k.color.comps[3].label == "b", "a colour row")
        assert(k.text.lit == "string" and k.on.lit == "boolean" and k.n.lit == "number", "literal widgets")
        assert(k.tags.kind == "expr", "a nested table: its own node")
        assert(k.xform.field and k.xform.field.key_pos and tn.fields["key1"], "fields can be renamed and removed")
        -- hints from comments at the end of a field's line; big tables collapse
        local hcode = "return {\n  speed = 1.5, --@range 0 10 0.5\n  mode = \"a\", --@enum a|b\n"
                   .. "  list = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 },\n}\n"
        local hast = P.parse(hcode)
        local hg = G.build(hast, { font = font, res = R.resolve(hast) })
        local hn, ln
        for _, nd in ipairs(hg.nodes) do
          if nd.table and nd.ins[1].name == "speed" then hn = nd end
          if nd.table and nd.ins[1].name == "[1]" then ln = nd end
        end
        assert(hn.ins[1].hint.range[2] == 10 and hn.ins[1].hint.range[3] == 0.5, "--@range")
        assert(hn.ins[2].hint.enum[2] == "b", "--@enum")
        assert(#ln.ins == 12 and ln.ins[11].action == "more", "13 items: 10 shown, + 3 more, + add field")
        local eg = G.build(hast, { font = font, res = R.resolve(hast), expanded = { [ln.ins[11].tpos] = true } })
        for _, nd in ipairs(eg.nodes) do if nd.table and nd.ins[1].name == "[1]" then ln = nd end end
        assert(#ln.ins == 15 and ln.ins[14].action == "less", "expanded: all 13, - show fewer, + add field")
      end
      -- flow pins (UE style) and floating code
      do
        local fcode = "local function f(a)\n  if a then\n    print(1)\n  else\n    print(2)\n  end\n"
                   .. "  for i = 1, 3 do print(i) end\n  return a\n"
                   .. "  --[==[@float dx=40 dy=150\n  local v = 0\n  print(\"x\", v)\n  ]==]\nend\n"
        local fast = P.parse(fcode)
        local fg = G.build(fast, { font = font, res = R.resolve(fast), parse = P.parse, resolve = R.resolve })
        local fb, floats = {}, {}
        for _, nd in ipairs(fg.nodes) do
          fb[nd.title] = fb[nd.title] or nd
          if nd.edit and nd.edit.kind == "float" then floats[#floats + 1] = nd end
        end
        assert(fb["if"].xouts[1].name == "then" and fb["if"].xouts[2].name == "else" and fb["if"].xin, "if: in, then, else")
        assert(fb["for"].xouts[1].name == "done" and fb["for"].xouts[2].name == "body", "loop: done, body")
        assert(#fb["return"].xouts == 0 and fb["local function f"].xin == nil, "return ends the flow; a header starts one")
        assert(#fg.floats == 1 and #floats == 2 and fg.floats[1].dx == 40, "floating code: its nodes")
        local F = fg.floats[1]
        assert(fg.nodes[F.first].ins[1].name == "v", "the first floating statement (set local v)")
        local into = false
        for _, e in ipairs(fg.exec) do if fg.nodes[e.to] == fg.nodes[F.first] then into = true end end
        assert(not into, "nothing flows into floating code")
        local wired = false
        for _, l in ipairs(fg.links) do local tn = fg.nodes[l.to]; if tn.title == "call print" and tn.edit and tn.edit.kind == "float" then wired = true end end
        assert(wired, "floating code resolves its own names")
        assert(fg.start and fg.start.kind == "start", "a start node")
        -- "set": a pin per value, named after its target; comment boxes
        local scode = "local function f(score)\n  --@comment dx=10 dy=-20 w=300 h=90 title=Scoring rules\n"
                   .. "  score.serve = -score.serve\n  local up = 1\nend\n"
        local sast = P.parse(scode)
        local sg = G.build(sast, { font = font, res = R.resolve(sast), parse = P.parse, resolve = R.resolve })
        local setn, locn
        for _, nd in ipairs(sg.nodes) do
          if nd.title == "set" then setn = nd end
          if nd.kind == "local" then locn = nd end
        end
        assert(#setn.ins == 1 and setn.ins[1].name == "score.serve", "set: one pin, named score.serve")
        assert(locn.ins[2] and locn.ins[2].action == "addvar", "set local: + add value")
        -- written to a global (no local declares it): "set global"
        local gast = P.parse("local a = 1\na = 2\ncount = a\nlocal t = {}\nt.x = count\n")
        local gg = G.build(gast, { font = font, res = R.resolve(gast), parse = P.parse, resolve = R.resolve })
        local titles = {}
        for _, nd in ipairs(gg.nodes) do if nd.kind == "set" then titles[#titles + 1] = nd.title end end
        assert(table.concat(titles, ",") == "set,set global,set", "set / set global: " .. table.concat(titles, ","))
        -- an input's own input (s.n under the concat) clears the next input (the table)
        local oast = P.parse('local s\ng(s.n .. "x", { c = { 1, 2 } })\n')
        local og = G.build(oast, { font = font, res = R.resolve(oast) })
        for i = 1, #og.nodes do for j = i + 1, #og.nodes do
          local a, b = og.nodes[i], og.nodes[j]
          assert(not (a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h), "stacked inputs overlap: " .. a.title .. " / " .. b.title)
        end end
        assert(#sg.notes == 1 and sg.notes[1].title == "Scoring rules" and sg.notes[1].w == 300, "a comment box")
        assert(G.parse_tag("--@comment dx=1 w=2 title=Two words").title == "Two words", "a comment's title keeps its spaces")
        -- an expression floats on its own: just its node (a table here)
        local xcode = "local function f()\n  return 1\n  --[[@float dx=0 dy=90\n  { value = 0 }\n  ]]\nend\n"
        local xast = P.parse(xcode)
        local xg = G.build(xast, { font = font, res = R.resolve(xast), parse = P.parse, resolve = R.resolve })
        local XF = xg.floats[1]
        assert(XF.expr and XF.root and xg.nodes[XF.root].table and not XF.first, "a floating table: one table node")
        local into_start
        for _, e in ipairs(xg.exec) do if xg.nodes[e.from] == xg.start then into_start = xg.nodes[e.to] end end
        assert(into_start == nil, "start leads nowhere when the file runs nothing but definitions")
        for _, e in ipairs(fg.exec) do                -- each flow edge leaves from a real out pin
          assert(fg.nodes[e.from].xouts[e.out], "an edge from a missing pin")
        end
      end
      local call = by["call print"]
      assert(call and call.ins[1].name == "arg1" and call.ins[1].kind == "var" and call.ins[2].text == '"x"', "call pins")
    end
    -- diagnostics: what will fail at run time (a literal nil where a value is needed)
    local function diags(code)
      local ast = P.parse(code)
      local gg = G.build(ast, { font = font, res = R.resolve(ast) })
      local t = {}
      for _, nd in ipairs(gg.nodes) do for _, d in ipairs(nd.diags) do t[#t + 1] = d.msg end end
      return t, gg.errors or 0
    end
    assert(diags("local a = (nil).x")[1] == "attempt to index a nil value", "index nil")
    assert(diags("local a = nil + 1")[1] == "attempt to perform arithmetic on a nil value", "arith nil")
    assert(diags("for k in pairs(nil) do end")[1]:match("^bad argument #1 to 'pairs'"), "pairs(nil)")
    assert(diags("for i = nil, 3 do end")[1] == "'for' initial value must be a number", "for nil")
    assert(select(2, diags("local a = nil local b = a == nil")) == 0, "comparing with nil is fine")
    do -- ---@class / ---@field / ---@alias drive the table widgets
      local csrc = '---@alias Mode "slow"|"fast"\n---| "turbo"\n---@class Vec\n---@field x number\n---@field y number\n' ..
        '---@class Paddle\n---@field speed number @range 0 10\n---@field mode Mode\n---@field tint Color\n---@field pos Vec\n---@field alive? boolean\n\n' ..
        '---@type Paddle\nlocal p = { speed = 3, mode = "slow", tint = { 1, 2, 3 }, pos = { x = 1 } }\n---@return Paddle\nlocal function make() return { speed = 1 } end\n'
      local cast = P.parse(csrc)
      local cg = G.build(cast, { font = font, res = R.resolve(cast) })
      local tabs = {}
      for _, nd in ipairs(cg.nodes) do if nd.table then tabs[#tabs + 1] = nd end end
      local function pin(nd, name) for _, q in ipairs(nd.ins) do if q.name == name then return q end end end
      assert(#cg.aliases.Mode == 3 and cg.classes.Paddle.by.alive.optional, "classes and aliases parsed")
      local pad = tabs[2]
      assert(tabs[1].title == "Vec" and pad.title == "Paddle" and tabs[3].title == "Paddle", "titled by class (@type, nested, @return)")
      assert(pin(pad, "speed").hint.range[2] == 10, "@range in a @field")
      assert(#pin(pad, "mode").hint.enum == 3, "an alias is an enum")
      assert(pin(pad, "tint").kind == "color", "a Color-typed field is a colour")
      assert(pin(pad, "+ alive: boolean").action == "classfield", "missing fields are one click away")
      assert(pin(tabs[1], "+ y: number") and pin(tabs[3], "+ mode: Mode"), "nested and returned tables too")
    end
    do -- the world's classes: w:spawn("/classes/x", {...}) (or a folder's classes/) type the x components
      local wsrc = 'local w = ecs.world()\n' ..
        'w:spawn("/classes/ship", { hp = { type = "int", value = 10, min = 1, max = 20 },\n' ..
        '  mode = { type = "string", value = "slow", options = { "slow", "fast" } }, tint = { type = "color", value = { 255, 0, 0 } },\n' ..
        '  motor = { type = "engine" }, label = "a", path = { type = "number", container = "array", value = {} },\n' ..
        '  hits = { type = "string", container = "map", values = "int" } })\n' ..
        'w:spawn("/classes/engine", { power = { type = "number", value = 1, min = 0, max = 100 } })\n' ..
        'w:spawn("/objects/a", { ship = { hp = 3, motor = { power = 2 } } })\n'
      local wast = P.parse(wsrc)
      local wg = G.build(wast, { font = font, res = R.resolve(wast) })
      local ship = wg.classes.ship
      assert(ship and ship.world and ship.by.hp.type == "integer" and ship.by.hp.range[2] == 20, "a world class: int 1..20")
      assert(ship.by.mode.type == "ship.mode" and #wg.aliases["ship.mode"] == 2, "options: an enum")
      assert(ship.by.tint.type == "Color" and ship.by.label.type == "string" and ship.by.motor.type == "engine", "colour, plain, a class")
      assert(ship.by.path.type == "number[]" and ship.by.hits.type == "table<string, integer>", "array, map")
      assert(ship.by.hp.default == "10" and ship.by.hits.default == "{}", "its default: the member's value")
      local tabs = {}
      for _, nd in ipairs(wg.nodes) do if nd.table and nd.class then tabs[#tabs + 1] = nd end end
      local function pin(nd, name) for _, q in ipairs(nd.ins) do if q.name == name then return q end end end
      local comp, motor, members = nil, nil, 0
      for _, nd in ipairs(tabs) do
        if nd.class == "ship" then comp = nd elseif nd.class == "engine" then motor = nd
        elseif nd.class == "class member" then members = members + 1 end
      end
      assert(comp and pin(comp, "hp").hint.range[2] == 20 and pin(comp, "+ mode: ship.mode").cfield.default == '"slow"',
             "a ship component: widgets, the class's other members (with their values)")
      assert(motor and pin(motor, "power").hint.range[2] == 100, "a member of a class type: that class's widgets")
      assert(members == 7, "the class's own table: each description a class member node (" .. members .. ")")
      local some
      for _, nd in ipairs(tabs) do if nd.class == "class member" and pin(nd, "type") and pin(nd, "type").hint then some = pin(nd, "type").hint end end
      assert(some and some.enum and table.concat(some.enum, " "):find("engine", 1, true), "... its type: a drop-down of the types")
      -- a folder world: classes/<name>/<member>.lua (games/pong/)
      local function sh(c) local f = io.popen(c) local o = f:read("*a") f:close() return o end
      local fs = {
        list = function(d) local t = {} for l in sh('ls "' .. d .. '" 2>/dev/null'):gmatch("[^\n]+") do t[#t + 1] = l end return t end,
        is_dir = function(d) return sh('[ -d "' .. d .. '" ] && echo y') ~= "" end,
      }
      local fc = G.folder_classes(root .. "games/pong/systems/paddles/system.lua", fs)
      local pad = {}
      for _, f in ipairs(fc and fc.paddle or {}) do pad[f.name] = f end
      assert(pad.player and pad.player.text == "1" and pad.player.d.max == 2 and pad.up.d.options[2] == "up",
             "a folder's classes/: members, their values and descriptions")
    end
    do -- a node's meta types its own fields in the graph (scripts; a folder's data files)
      local msrc = 'local w = ecs.world()\n' ..
        'w:spawn("/objects/ball", { speed = 3, mode = "slow", hp = 2,\n' ..
        '  meta = { speed = { type = "number", min = 0, max = 10 }, mode = { type = "string", options = { "slow", "fast" } }, hp = { type = "int" } } })\n'
      local mast = P.parse(msrc)
      local mg = G.build(mast, { font = font, res = R.resolve(mast) })
      local function pin(nd, name) for _, q in ipairs(nd.ins) do if q.name == name then return q end end end
      local ball, members = nil, 0
      for _, nd in ipairs(mg.nodes) do
        if nd.table and pin(nd, "speed") and pin(nd, "meta") then ball = nd end
        if nd.table and nd.class == "class member" then members = members + 1 end
      end
      assert(ball and pin(ball, "speed").hint.range[2] == 10 and #pin(ball, "mode").hint.enum == 2 and pin(ball, "hp").ftype == "integer",
             "a spawn's meta: its fields' widgets (slider, drop-down, int)")
      assert(members == 3, "... its meta's entries: class member nodes (" .. members .. ")")
      -- folder files: classes/<x>/<m>.lua, <node>/meta.lua, <node>/<f>.lua
      local tmp = os.tmpname()
      os.remove(tmp)
      os.execute('mkdir -p "' .. tmp .. '/objects/ball" "' .. tmp .. '/classes/ship"')
      local function wf(p, t) local fh = io.open(tmp .. p, "w") fh:write(t) fh:close() end
      wf("/objects/ball/meta.lua", 'return { speed = { type = "number", min = 0, max = 10 } }\n')
      wf("/objects/ball/speed.lua", 'return 3\n')
      wf("/classes/ship/hp.lua", 'return { type = "int", value = 3 }\n')
      local k, d = G.file_info(tmp .. "/objects/ball/speed.lua")
      assert(k == "value" and d and d.max == 10, "a data file: its type from meta.lua")
      assert(G.file_info(tmp .. "/objects/ball/meta.lua") == "meta" and G.file_info(tmp .. "/classes/ship/hp.lua") == "member", "meta.lua, a member's file")
      local vast = P.parse('return 3\n')
      local vg = G.build(vast, { font = font, res = R.resolve(vast), file_kind = k, file_desc = d })
      local ret
      for _, nd in ipairs(vg.nodes) do for _, q in ipairs(nd.ins) do if q.hint and q.hint.range then ret = q end end end
      assert(ret and ret.hint.range[2] == 10, "... its value: a slider")
      local hast = P.parse('return { type = "int", value = 3 }\n')
      local hg = G.build(hast, { font = font, res = R.resolve(hast), file_kind = "member" })
      local cm = false
      for _, nd in ipairs(hg.nodes) do if nd.class == "class member" then cm = true end end
      assert(cm, "a member's file: a class member node")
      os.execute('rm -rf "' .. tmp .. '"')
    end
    do -- long functions wrap onto rows; the flow wire into a row is marked
      local lines = { "local function f()" }
      for i = 1, 40 do lines[#lines + 1] = "  local v" .. i .. " = " .. i .. " + 1" end
      lines[#lines + 1] = "end"
      local wsrc = table.concat(lines, "\n")
      local wast = P.parse(wsrc)
      local saved_wrap = G.WRAP_W
      G.WRAP_W = 1600                              -- (narrow, so 40 statements wrap)
      local wg = G.build(wast, { font = font, res = R.resolve(wast) })
      local wraps = 0
      for _, e in ipairs(wg.exec) do if e.wrap then wraps = wraps + 1 end end
      local fr = wg.frames[1]
      assert(wraps >= 2, "rows wrap (" .. wraps .. ")")
      assert(fr.w <= G.WRAP_W + 400 and fr.h > 200, "a frame of rows, not one long row")
      for _, nd in ipairs(wg.nodes) do
        if nd.kind ~= "start" then assert(nd.x >= fr.x and nd.x + nd.w <= fr.x + fr.w, "nodes stay in their frame") end
      end
      G.WRAP_W = saved_wrap
    end
    do -- value types where they're certain (pins and wires take their colour)
      local tsrc = "---@param s string\nlocal function f(s)\n  local a, b = 1, 2.5\n  local ok = a < b\n  local c = s .. a\n" ..
                   "  local z = 1\n  z = 'x'\n  for i = 1, 3 do end\n  return ok, c, #s, a + 1, a / 2, z, math.floor(b)\nend\n"
      local tast = P.parse(tsrc)
      local tg = G.build(tast, { font = font, res = R.resolve(tast) })
      local ret, loop
      for _, nd in ipairs(tg.nodes) do
        if nd.kind == "return" and #nd.ins > 3 then ret = nd end
        if nd.kind == "loop" then loop = nd end
      end
      local got = {}
      for _, q in ipairs(ret.ins) do if not q.action then got[#got + 1] = tostring(q.vtype) end end   -- (not its "+ add value")
      assert(table.concat(got, ",") == "boolean,string,integer,integer,number,nil,integer", "return types: " .. table.concat(got, ","))
      assert(loop.outs[1].vtype == "integer", "a numeric for's variable")
    end
    do -- loops and flow: titles, no wire back from a body's end, args named from the file's functions
      local lsrc = table.concat({
        "function other(a, b) end",
        "local M = {}",
        "function M:draw(dt) end",
        "local t = {}",
        "for i = 1, 3 do other(i, i) end",
        "for k, v in pairs(t) do print(k) end",
        "while #t > 0 do table.remove(t) end",
        "repeat t[#t + 1] = 1 until #t > 3",
        "M:draw(1)",
      }, "\n")
      local last = P.parse(lsrc)
      local lg = G.build(last, { font = font, res = R.resolve(last) })
      local by = {}
      for _, nd in ipairs(lg.nodes) do by[nd.title] = by[nd.title] or nd end
      assert(by["for"] and by["for each"] and by["while"] and by["repeat"] and by["until"], "loop titles")
      for _, e in ipairs(lg.exec) do assert(not e.back, "no wire back from a loop body's end") end
      assert(#by["until"].xouts == 1 and by["until"].xouts[1].name == "done", "until: done only")
      local co = by["call other"]
      assert(co and co.ins[1].name == "a" and co.ins[2].name == "b", "a global function's parameters name the pins")
      local cm = by["call M:draw"]
      assert(cm and cm.ins[2].name == "dt", "a method's parameters (after self) name the pins")
      for _, t in ipairs({ "for", "for each", "while" }) do   -- loop: body and done outs, both wired when used
        local nd = by[t]
        assert(nd.xouts[1].name == "done" and nd.xouts[2].name == "body", t .. ": done, body")
      end
    end
    do -- API definitions (runtime/meta): calls to dd.text etc. get their parameters' names
      local api = {}
      for _, f in ipairs({ "dd.lua", "lua.lua" }) do
        local fh = assert(io.open(root .. "runtime/meta/" .. f, "rb"))
        G.read_meta(fh:read("*a"), P.parse, api)
        fh:close()
      end
      assert(api["dd.text"] and table.concat(api["dd.text"].params, ",") == "x,y,text,color", "dd.text from runtime/meta")
      local asrc = 'dd.text(1, 2, "hi")\nlocal dd2 = dd\nlocal function dd3(a) end\ndd3(1)\nmath.floor(1.5)\n'
      local aast = P.parse(asrc)
      local ag = G.build(aast, { font = font, res = R.resolve(aast), api = api })
      local by = {}
      for _, nd in ipairs(ag.nodes) do by[nd.title] = by[nd.title] or nd end
      local dt = by["call dd.text"]
      assert(dt and dt.ins[1].name == "x" and dt.ins[2].name == "y" and dt.ins[3].name == "text", "dd.text pins: x, y, text")
      assert(by["call math.floor"] and by["call math.floor"].ins[1].name == "x", "math.floor(x)")
      assert(by["call dd3"].ins[2].name == "a", "the file's own function still wins")
    end
    do -- chips: parameters and variables read 4+ times get no wires, a named chip on each pin
      local csrc = "local function f(a, b)\n  local x = a + b\n  local k = 1\n  print(k)\n  print(k)\n  print(k)\n  print(k)\n  return x + a\nend\nreturn f\n"
      local cast = P.parse(csrc)
      local cg = G.build(cast, { font = font, res = R.resolve(cast) })
      local chips, wired = {}, {}
      for _, nd in ipairs(cg.nodes) do
        for _, q in ipairs(nd.ins) do if q.decl then (q.chip and chips or wired)[q.decl.name] = true end end
      end
      assert(chips.a and chips.b and chips.k and not chips.x and wired.x, "chips: params a, b and k (read 4 times); x keeps its wire")
      for _, l in ipairs(cg.links) do
        local d = cg.nodes[l.from].outs[l.out].decl
        if d and (d.name == "a" or d.name == "k") then assert(l.chip, "a chipped variable's links are marked") end
        if d and d.name == "x" then assert(not l.chip, "x's link is a wire") end
      end
    end
    do -- modules: a required module's functions (by the file's alias) and its classes' methods name call pins
      local fh = assert(io.open(root .. "runtime/ecs.lua", "rb"))
      local entries, info = G.read_meta(fh:read("*a"), P.parse, {})
      fh:close()
      assert(info.ret == "ecs", "ecs.lua returns ecs")
      local api, methods = {}, {}
      G.add_module(api, methods, entries, info, "ecs")
      assert(api["ecs.world"] and api["ecs.world"].ret_class == "World", "ecs.world() returns a World")
      local msrc = 'local ecs = require("ecs")\nlocal w = ecs.world()\nw:spawn("/a", {})\nlocal function sys(v)\n  local l = v:query("a", "b")\nend\nreturn sys\n'
      local mast = P.parse(msrc)
      local mg = G.build(mast, { font = font, res = R.resolve(mast), api = api, api_methods = methods })
      local by = {}
      for _, nd in ipairs(mg.nodes) do by[nd.title] = by[nd.title] or nd end
      local sp, q = by["call w:spawn"], by["v:query"]
      assert(sp and sp.ins[2].name == "path" and sp.ins[3].name == "components", "w:spawn(path, components): w = ecs.world(), a World")
      assert(q and q.ins[2].name == "component 1" and q.ins[3].name == "component 2", "v:query: the only query method, its ---@param ... names")
    end
    do -- any module style names call pins: M.f = function, M.f = local f, return { ... }, a local alias
      local styles = {
        "local M = {}\nfunction M.a(x, y) end\nM.b = function(speed) end\nlocal function c(name) end\nM.c = c\nM.d = M.a\nreturn M\n",
        "local function a(x, y) end\nreturn { a = a, b = function(speed) end, c = function(name) end, d = a }\n",
        "local M = { a = function(x, y) end, b = function(speed) end }\nfunction M.c(name) end\nM.d = M.a\nreturn M\n",
      }
      for i, msrc in ipairs(styles) do
        local entries, info = G.read_meta(msrc, P.parse, {})
        local api, methods = {}, {}
        G.add_module(api, methods, entries, info, "mod")
        local csrc = 'local mod = require("mod")\nmod.a(1, 2)\nmod.b(3)\nmod.c("x")\nmod.d(4, 5)\n'
        local cast = P.parse(csrc)
        local cg = G.build(cast, { font = font, res = R.resolve(cast), api = api, api_methods = methods })
        local got = {}
        for _, nd in ipairs(cg.nodes) do
          local f = nd.title:match("^call mod%.(%a)$")
          if f then local t = {}; for _, q in ipairs(nd.ins) do t[#t + 1] = q.name end; got[f] = table.concat(t, ",") end
        end
        assert(got.a == "mod,x,y" and got.b == "mod,speed" and got.c == "mod,name" and got.d == "mod,x,y",
               "module style " .. i .. ": " .. tostring(got.a) .. " | " .. tostring(got.b) .. " | " .. tostring(got.c) .. " | " .. tostring(got.d))
      end
    end
    do -- every node can be moved (the samples in tests/; all files: lua runtime/tests/nodegraph_moves.lua)
      local mv = dofile(here .. "nodegraph_moves.lua")
      local list = {}
      for _, f in ipairs(files) do if f:match("[/\\]tests[/\\][^/\\]+%.lua$") then list[#list + 1] = f end end
      local total, fails = mv.run(list, true)
      assert(#fails == 0, "a node can't be moved: " .. tostring(fails[1]))
      assert(total > 100, "moves: the samples were found")
    end
    print("nodegraph ok (" .. n .. " files, tags, fields, " .. renamed .. " renames)")
  end
end

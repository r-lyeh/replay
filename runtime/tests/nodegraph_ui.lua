-- nodegraph_ui.lua - interaction tests for the node graph (runs inside lite).
--
--   play games/pong.lua --stopped --lite "dofile('runtime/tests/nodegraph_ui.lua')@3" --frames 900 --shot ui.bmp
--
-- Each test writes a small Lua file to a temp folder, opens it as a graph,
-- drives the view the way the mouse and keys would (presses, drags, menus,
-- commands), lets frames pass (the graph rebuilds between edits) and checks
-- the text. Prints one line per test and a summary; exits the editor at the end.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local U = require "plugins.nodegraph.util"
local ng = require "plugins.nodegraph"

local ok_n, fail_n, log = 0, 0, {}
local function say(s) print(s); log[#log + 1] = s end

local dir = (os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp")   -- files: ng_ui_<time>_<n>.lua there
local stamp = "ng_ui_" .. tostring(os.time())

local V                                            -- the graph view under test
local function wait(n)                             -- let frames pass (and make sure the graph caught up)
  for _ = 1, n or 3 do                             -- (threads run many times a frame: count frames)
    core.redraw = true
    local f0 = core.frame_start
    repeat coroutine.yield() until core.frame_start ~= f0
  end
  if V then V:update() end
end
local function txt() return V.doc:get_text(1, 1, math.huge, math.huge) end
local function note() local t = V.note and V.note.text; V.note = nil; return t end
local function find(pred) for _, n in ipairs(V.g.nodes) do if pred(n) then return n end end end
local function titled(t) return find(function(n) return n.title == t end) end
local function xy(n, dx, dy) local ox, oy = V:origin(); return ox + (n.x + (dx or 20)) * V.zoom, oy + (n.y + (dy or 6)) * V.zoom end
local function drag(x1, y1, x2, y2, button)
  button = button or "left"
  V:on_mouse_pressed(button, x1, y1, 1)
  V:on_mouse_moved((x1 + x2) / 2, (y1 + y2) / 2, 0, 0)
  V:on_mouse_moved(x2, y2, 0, 0)
  V:on_mouse_released(button, x2, y2)
end
local function click(x, y, mods)
  for _, m in ipairs(mods or {}) do keymap.modkeys[m] = true end
  V:on_mouse_pressed("left", x, y, 1)
  V:on_mouse_released("left", x, y)
  for _, m in ipairs(mods or {}) do keymap.modkeys[m] = false end
end
local function menu_pick(path)                     -- click an item of the open menu ("Flow>If": through submenus)
  local m = V.menu
  for part in path:gmatch("[^>]+") do
    local found
    for i, it in ipairs(m and m.items or {}) do
      if it.text == part then found = true
        if i > m.scroll + m.rows then m.scroll = i - m.rows end   -- (scroll it into view)
        local y = m.y + 4 * SCALE + (m.top or 0) + (i - 1 - m.scroll) * m.ih + m.ih / 2
        if it.sub then V:on_mouse_moved(m.x + 20, y, 0, 0)
          m = m.child
        else
          V:on_mouse_pressed("left", m.x + 20, y, 1)
          V:on_mouse_released("left", m.x + 20, y)
          return true
        end
        break
      end
    end
    if not found then return false end
  end
end
local function menu_texts(path)                    -- the items of a submenu ("Types")
  local m = V.menu
  for part in path:gmatch("[^>]+") do
    for i, it in ipairs(m.items) do
      if it.text == part and it.sub then
        V:on_mouse_moved(m.x + 20, m.y + 4 * SCALE + (m.top or 0) + (i - 1 - m.scroll) * m.ih + m.ih / 2, 0, 0); m = m.child; break
      end
    end
  end
  local t = {}
  for _, it in ipairs(m and m.items or {}) do t[#t + 1] = it.text end
  return t
end
local function check(cond, what)
  if cond then ok_n = ok_n + 1 else fail_n = fail_n + 1; say("  FAIL: " .. what) end
end

-- open `src` as a graph (a fresh file each test)
local count = 0
-- NG_FLOAT (an audit of floating code, how new code starts out in the editor):
-- 1: every test's code floats as one block; 2: each top-level statement floats
-- on its own (nothing wired, like a fresh canvas)
local FLOAT_MODE = tonumber(os.getenv("NG_FLOAT") or "")
local function floatify(src)
  if not FLOAT_MODE then return src end
  if FLOAT_MODE == 1 then return "--[[@float dx=40 dy=40\n" .. src .. (src:sub(-1) == "\n" and "" or "\n") .. "]]\n" end
  local lp = require "plugins.nodegraph.luaparse"
  local ast = lp.parse(src)
  if not ast then return src end
  local out, y = {}, 40
  for _, st in ipairs(ast.body.stmts) do
    local a = src:sub(1, st.pos - 1):match(".*\n()") or 1
    out[#out + 1] = "--[[@float dx=40 dy=" .. y .. "\n" .. src:sub(a, st.epos) .. "\n]]"
    y = y + 160
  end
  return table.concat(out, "\n") .. "\n"
end
local function open(src)
  src = floatify(src)
  count = count + 1
  local path = dir .. "/" .. stamp .. "_" .. count .. ".lua"
  local f = io.open(path, "w"); f:write(src); f:close()
  if V then                                        -- one graph tab for all: it shows the next file
    V.doc:clean()
    V.doc = core.open_doc(path)
    V.sel, V.selected, V.menu, V.picker, V.editing, V.preview, V.press = {}, nil, nil, nil, nil, nil, nil
    V.change_id = nil
  else
    V = ng.open(path)
    local node = core.root_view.root_node:get_node_for_view(V)   -- give it room
    local function parent_of(n, p)
      if n == node then return p end
      if n.type ~= "leaf" then return parent_of(n.a, n) or parent_of(n.b, n) end
    end
    local p = parent_of(core.root_view.root_node)
    if p then p.divider = p.b == node and 0.05 or 0.95 end
  end
  core.set_active_view(V)
  wait(3)
  V:rebuild()
  V.pan.x, V.pan.y = 40, 60
  core.redraw = true
  wait(2)
  return txt()                                     -- (as lite holds it: no final newline)
end
local function undo_all(orig)
  for _ = 1, 60 do V.doc:undo() end
  return txt() == orig
end

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name, fn } end

test("edit a literal in place, undo", function()
  local orig = open("local function f(a)\n  local t = 0\n  return t\nend\nreturn f\n")
  local n = find(function(n) return n.kind == "local" end)
  local ox, oy = V:origin()
  local which = V:row_at(n, oy + (n.y + n.ins[1].y) * V.zoom)
  check(which == "slot1", "the value row is slot1")
  V:begin_edit(n, which); V.editing.text = "42"; V:commit_edit(); wait()
  check(txt():find("local t = 42", 1, true), "literal rewritten")
  check(undo_all(orig), "undo restores")
end)

test("a syntax error: its node haloed, the message a link to it", function()
  local orig = open("local a = 1\nlocal b = 2\nlocal c = 3\nreturn a + b + c\n")
  V.doc:insert(3, 1, "local = =\n"); wait()
  check(V.err and V.err_line == 3, "the error and its line: " .. tostring(V.err))
  local n = V:err_node()
  check(n and n.line == 3, "its node: the last good graph's statement at that line")
  check(V.err_n == n, "drawn with a halo")
  local h
  for _, s in ipairs(V.status_hits or {}) do if s.kind == "syntax" then h = s end end
  check(h, "the message (top-left) is a link")
  if h then click(h.x + 2, h.y + 4); wait() end
  check(V.selected == n, "a click on it: its node selected")
  check(select(1, V.doc:get_selection()) == 3, "... the text's cursor on its line")
  local back = undo_all(orig); wait()
  check(back and not V.err and not V.err_n, "undo restores, no halo left")
end)

test("rename a local, refuse a capture", function()
  local orig = open("local function f(a)\n  local t = a\n  return t + a\nend\nreturn f\n")
  local n = find(function(n) return n.kind == "local" end)
  V:begin_edit(n, "title")
  check(not V.editing and (note() or ""):find("on its pin"), "set local: the title doesn't rename (its pins do)")
  local ox, oy = V:origin()
  check(V:row_at(n, oy + (n.y + n.ins[1].y) * V.zoom, ox + (n.x + 10 * SCALE + 2) * V.zoom) == "var1", "the pin's name is var1: " .. tostring(V:row_at(n, oy + (n.y + n.ins[1].y) * V.zoom, ox + (n.x + 10 * SCALE + 2) * V.zoom)) .. " " .. tostring(n.fields.var1))
  V:begin_edit(n, "var1"); V.editing.text = "total"; V:commit_edit(); wait()
  check(txt():find("local total = a", 1, true) and txt():find("return total + a", 1, true), "renamed with its uses")
  n = find(function(n) return n.kind == "local" end)
  V:begin_edit(n, "var1"); V.editing.text = "a"; V:commit_edit()
  check(V.editing and V.editing.err, "capturing a is refused")
  V:cancel_edit()
  check(undo_all(orig), "undo restores")
end)

test("rewire by dragging a socket", function()
  local orig = open("local function f(a, b)\n  local t = a\n  return t\nend\nreturn f\n")
  local head = titled("local function f")
  local n = find(function(n) return n.kind == "local" end)
  local ox, oy = V:origin()
  local bo; for k, o in ipairs(head.outs) do if o.name == "b" then bo = k end end
  local x1, y1 = V:socket_xy(head, "out", bo, ox, oy)
  local x2, y2 = V:socket_xy(n, "in", 1, ox, oy)
  drag(x1, y1, x2, y2); wait()
  check(txt():find("local t = b", 1, true), "t reads b now")
  check(undo_all(orig), "undo restores")
end)

test("number drag, checkbox, colour picker", function()
  local orig = open("local cfg = { speed = 1.5, on = true, color = { 90, 96, 120 } }\nreturn cfg\n")
  local function hit(kind, text) for _, h in ipairs(V.hits) do if h.kind == kind and (not text or h.text == text) then return h end end end
  local h = hit("num", "1.5")
  drag(h.x + 4, h.y + 4, h.x + 44, h.y + 4); wait()
  check(txt():find("speed = 3.5", 1, true), "dragged 1.5 by 40px to 3.5")
  local b = hit("bool"); click(b.x + 2, b.y + 2); wait()
  check(txt():find("on = false", 1, true), "checkbox toggled")
  local sw = hit("swatch"); click(sw.x + 2, sw.y + 2)
  check(V.picker ~= nil, "picker opens")
  local _, sv = V:picker_rects()
  drag(sv.x + sv.w * 0.9, sv.y + 2, sv.x + sv.w * 0.95, sv.y + 3); wait()
  check(not txt():find("{ 90, 96, 120 }", 1, true), "picker writes the colour")
  V.picker = nil
  check(undo_all(orig), "undo restores")
end)

test("table fields: add (typed), retype, rename, remove", function()
  local orig = open("local cfg = {\n  speed = 1.5,\n  mode = \"fast\",\n}\nreturn cfg\n")
  local tn = find(function(n) return n.table end)
  local add; for _, h in ipairs(V.hits) do if h.kind == "action" and h.pin.action == "add" then add = h end end
  click(add.x + 3, add.y + 3)
  check(menu_pick("Colour"), "the add menu offers Colour"); wait()
  check(txt():find("color = { 255, 255, 255 }", 1, true), "a colour field on its own line")
  tn = find(function(n) return n.table end)
  local mode; for _, p in ipairs(tn.ins) do if p.name == "mode" then mode = p end end
  V:retype_field(tn, mode, V.FIELD_TYPES[3]); wait()
  check(txt():find("mode = false", 1, true), "mode retyped to a boolean")
  tn = find(function(n) return n.table end)
  local i; for k, p in ipairs(tn.ins) do if p.name == "speed" then i = k end end
  V:begin_edit(tn, "key" .. i); V.editing.text = "velocity"; V:commit_edit(); wait()
  check(txt():find("velocity = 1.5", 1, true), "key renamed")
  tn = find(function(n) return n.table end)
  local vp; for _, p in ipairs(tn.ins) do if p.name == "velocity" then vp = p end end
  V:remove_field(vp); wait()
  check(not txt():find("velocity", 1, true) and load(txt()) ~= nil, "field removed, file still loads")
  check(undo_all(orig), "undo restores")
end)

test("---@class: typed widgets, missing fields one click away", function()
  local orig = open('---@alias Mode "slow"|"fast"\n---@class Paddle\n---@field speed number @range 0 10\n---@field mode Mode\n---@field alive boolean\n\n---@type Paddle\nlocal p = { speed = 3 }\nreturn p\n')
  local tn = find(function(n) return n.table end)
  check(tn and tn.title == "Paddle", "the table node is titled by its class")
  local function hit(name) for _, h in ipairs(V.hits) do if h.kind == "action" and h.pin.name:find(name, 1, true) then return h end end end
  local h = hit("+ mode"); check(h, "a missing field shows as '+ mode: Mode'")
  click(h.x + 3, h.y + 3); wait()
  check(txt():find('mode = "slow"', 1, true), "clicking adds it with the alias's first value")
  h = hit("+ alive"); click(h.x + 3, h.y + 3); wait()
  check(txt():find("alive = false", 1, true), "a boolean starts false")
  tn = find(function(n) return n.table end)
  local mp; for _, p in ipairs(tn.ins) do if p.name == "mode" then mp = p end end
  check(mp and mp.hint and mp.hint.enum and #mp.hint.enum == 2, "an alias field is a drop-down")
  check(undo_all(orig), "undo restores")
end)

test("add from the menu floats; wire it in; take it out; delete", function()
  local orig = open("local function f(a)\n  local t = 0\n  if a then\n    print(a)\n  end\n  return t\nend\nreturn f\n")
  local head = titled("local function f")
  local x, y = xy(head, 60, head.h + 120)
  V:on_mouse_pressed("right", x, y, 1); V:on_mouse_released("right", x, y)
  check(menu_pick("Values>Call"), "the Add menu has Values > Call"); wait()
  check(txt():find("@float", 1, true), "it floats (a comment block)")
  local fl = find(function(n) return n.edit and n.edit.kind == "float" end)
  local ifn = titled("if")
  local ox, oy = V:origin()
  local x1, y1 = V:exec_xy(ifn, "out", 1, ox, oy)
  local x2, y2 = V:exec_xy(fl, "in", 1, ox, oy)
  drag(x1, y1, x2, y2); wait()
  check(not txt():find("@float", 1, true) and txt():find("if a then\n    print(\"hello\")", 1, true), "wired into then: it runs")
  ifn = titled("if")
  ox, oy = V:origin()
  local ex, ey = V:exec_xy(ifn, "in", 1, ox, oy)
  click(ex, ey, { "alt" }); wait()
  check(txt():find("@float", 1, true) and load(txt()) ~= nil, "ALT on the flow in: the if and what follows float")
  fl = find(function(n) return n.edit and n.edit.kind == "float" end)
  V:select({ fl }); core.set_active_view(V)
  command.perform("nodegraph:delete-selection"); wait()
  check(not txt():find("@float", 1, true) and not txt():find("if a", 1, true), "Delete key removes the floating code")
  check(undo_all(orig), "undo restores")
end)

test("floating table wired into an input", function()
  local orig = open("local function f(a)\n  print(\"x\", a)\nend\nreturn f\n")
  local head = titled("local function f")
  V:add_node({ name = "Table", text = "{ value = 0 }" }, head.x + 40, head.y + head.h + 60); wait()
  local tn = find(function(n) return n.table and n.edit and n.edit.kind == "float" end)
  local pr = titled("call print")
  V:connect({ node = tn, side = "out", i = 1, sock = tn.outs[1] }, { node = pr, side = "in", i = 2, sock = pr.ins[2] }); wait()
  check(txt():find('print("x", { value = 0 })', 1, true), "the table moved into arg2")
  check(undo_all(orig), "undo restores")
end)

test("delete disconnects (UE style)", function()
  local orig = open("local function f(a)\n  local u = a + 1\n  print(u)\n  return a\nend\nreturn f\n")
  local un = find(function(n) return n.kind == "local" end)
  V:select({ un }); core.set_active_view(V)
  command.perform("nodegraph:delete-selection"); wait()
  check(not txt():find("local u", 1, true), "deleted")
  check(txt():find("@float[^\n]*\n%s*print%(u%)\n"), "its reader floats, keeping the name (floating code doesn't resolve)")
  check(txt():find("@float", 1, true), "what followed floats")
  check(undo_all(orig), "undo restores")
end)

test("deleting a call node: only it goes, its inputs float (UE style)", function()
  local orig = open("local function f(x, lim, dy)\n  x.y = math.max(-lim, math.min(lim, (x.y or 0) + dy))\nend\nreturn f\n")
  core.set_active_view(V)
  V:select({ titled("math.max") })
  command.perform("nodegraph:delete-selection"); wait()
  local t = txt()
  check(t:find("  x.y = nil\n", 1, true), "the pin it fed reads nil")
  check(t:find("@float[^\n]*\n%s*%-lim\n") and t:find("@float[^\n]*\n%s*%(math%.min%(lim, %(x%.y or 0%) %+ dy%)%)\n"),
        "-lim and math.min(...) stay, floating: " .. t)
  check(titled("math.min") ~= nil and titled("math.max") == nil, "math.min is still a call node (with its result); math.max is gone")
  local mn = titled("math.min")                    -- wire its result back into x.y: as it was, without the parentheses
  local st = titled("set")
  local ox, oy = V:origin()
  V.zoom = 1; V.pan.x, V.pan.y = 40, 60; wait(); mn, st = titled("math.min"), titled("set"); ox, oy = V:origin()
  local mx, my = V:socket_xy(mn, "out", 1, ox, oy)
  local sx, sy = V:socket_xy(st, "in", 1, ox, oy)
  drag(mx, my, sx, sy); wait()
  check(txt():find("  x.y = math.min(lim, (x.y or 0) + dy)\n", 1, true), "wired back in: x.y = math.min(...): " .. tostring(V.note and V.note.text))
  check(undo_all(orig), "undo restores")
  wait()
  V:select({ titled("math.max"), titled("math.min") })
  command.perform("nodegraph:delete-selection"); wait()
  t = txt()
  check(t:find("@float[^\n]*\n%s*%-lim\n") and t:find("@float[^\n]*\n%s*%(x%.y or 0%) %+ dy\n") and not t:find("math.min", 1, true),
        "both deleted: what fed them floats (-lim, (x.y or 0) + dy): " .. t .. tostring(V.note and V.note.text))
  check(undo_all(orig), "undo restores")
end)

test("deleting a branch / loop: only it goes; its bodies, condition and elseif chain float", function()
  local orig = open("local function f(p, x)\n  local a = 1\n  if p.ai and x > a then\n    print(\"ai\")\n  elseif x then\n    print(\"x\")\n  else\n    print(\"none\")\n  end\n  print(a)\nend\nreturn f\n")
  core.set_active_view(V)
  local ifn = find(function(n) return n.title == "if" and not n.clause end)
  V:select({ ifn })
  command.perform("nodegraph:delete-selection"); wait()
  local t = txt()
  check(not t:find("if p.ai", 1, true), "the if is gone")
  check(t:find("@float[^\n]*\n%s*print%(\"ai\"%)\n"), "its then-body floats")
  check(t:find("@float[^\n]*\n%s*if x then\n%s*print%(\"x\"%)\n%s*else\n%s*print%(\"none\"%)\n%s*end\n"), "the elseif chain floats as an if of its own")
  check(t:find("@float[^\n]*\n%s*p%.ai and x > a\n"), "the condition floats")
  check(t:find("@float[^\n]*\n%s*print%(a%)\n"), "what followed floats (no flow in), as before")
  check(undo_all(orig), "undo restores")
  orig = open("local function f(p, x)\n  if p then\n    print(1)\n  elseif x > 2 then\n    print(2)\n  else\n    print(3)\n  end\nend\nreturn f\n")
  V:select({ find(function(n) return n.clause == 2 end) })
  command.perform("nodegraph:delete-selection"); wait()
  t = txt()
  check(t:find("  if p then\n    print%(1%)\n  else\n[^\n]*\n?%s*print%(3%)\n  end\n") and not t:find("elseif", 1, true), "an elseif: only its clause goes: " .. t)
  check(t:find("@float[^\n]*\n%s*print%(2%)\n") and t:find("@float[^\n]*\n%s*x > 2\n"), "its body and condition float")
  check(undo_all(orig), "undo restores")
  orig = open("local function f(p, x)\n  if p.ai then dd.cross(x, 1, 5, \"#fff\") end\n  local fn = function(who) print(who) end\n  return fn\nend\nreturn f\n")
  V:select({ find(function(n) return n.title == "if" end) })
  command.perform("nodegraph:delete-selection"); wait()
  t = txt()
  check(t:find("@float[^\n]*\n%s*dd%.cross%(x, 1, 5, \"#fff\"%)\n"), "a one-line if: its body floats, without the if: " .. t)
  check(undo_all(orig), "undo restores")
  wait()
  V:select({ find(function(n) return n.kind == "local" end) })
  command.perform("nodegraph:delete-selection"); wait()
  t = txt()
  check(t:find("@float[^\n]*\n%s*function%(who%) print%(who%) end\n"), "a deleted local's lambda floats: " .. t .. tostring(V.note and V.note.text))
  check(find(function(n) return n.title == "function" and n.edit and n.edit.kind == "float" end) ~= nil, "as a frame (its body's nodes shown)")
  check(undo_all(orig), "undo restores")
  orig = open("local function f(t)\n  local s = 0\n  for i = 1, #t do\n    s = s + t[i]\n  end\n  return s\nend\nreturn f\n")
  V:select({ titled("for") })
  command.perform("nodegraph:delete-selection"); wait()
  t = txt()
  check(not t:find("for i", 1, true) and t:find("@float[^\n]*\n%s*s = s %+ t%[i%]\n"), "a loop: its body floats")
  check(undo_all(orig), "undo restores")
end)

test("a statement sharing its line can be deleted (if c then b.hidden = true return end)", function()
  local orig = open("local function f(b, score)\n  if not score.over then b.hidden = true return end\n  print(1)\nend\nreturn f\n")
  core.set_active_view(V)
  V:select({ titled("set") })
  command.perform("nodegraph:delete-selection"); wait()
  local t = txt()
  check(t:find("  if not score.over then end\n", 1, true), "only its text went: " .. t)
  check(t:find("@float[^\n]*\n%s*return\n"), "the return after it floats (no flow in)")
  check(undo_all(orig), "undo restores")
end)

test("after a deletion, what's left keeps its place; one undo", function()
  local orig = open("local function f(x, lim, dy)\n  local a = 1\n  x.y = math.max(-lim, math.min(lim, (x.y or 0) + dy))\n  print(x.y + a)\nend\nreturn f\n")
  core.set_active_view(V)
  local function at(t) local n = titled(t); return n and { n.x, n.y } end
  local set0, pr0, loc0 = at("set"), at("call print"), at("new local")
  local pe0                                        -- print's expression input
  for _, n in ipairs(V.g.nodes) do if n.title == "expression" and n.fields.body and V.doc:get_text(1, 1, math.huge, math.huge):sub(n.fields.body.pos, n.fields.body.epos) == "x.y + a" then pe0 = { n.x, n.y } end end
  V:select({ titled("math.max") })
  command.perform("nodegraph:delete-selection"); wait()
  local set1, pr1, loc1 = at("set"), at("call print"), at("new local")
  check(set1[1] == set0[1] and set1[2] == set0[2], "set (x.y) stays where it was: " .. set0[1] .. "," .. set0[2] .. " -> " .. set1[1] .. "," .. set1[2])
  check(pr1[1] == pr0[1] and pr1[2] == pr0[2], "and what follows it too")
  check(loc1[1] == loc0[1] and loc1[2] == loc0[2], "what came before didn't need to move")
  local pe1
  for _, n in ipairs(V.g.nodes) do if n.title == "expression" and n.fields.body and txt():sub(n.fields.body.pos, n.fields.body.epos) == "x.y + a" then pe1 = { n.x, n.y } end end
  check(pe1 and pe1[1] == pe0[1] and pe1[2] == pe0[2], "print's expression node too")
  V.doc:undo(); wait()
  check(txt() == orig, "one undo brings it all back")
end)

test("box select, drag together, arrows, comment box", function()
  local orig = open("local function f(a)\n  local x = 1\n  local y = 2\n  return x + y\nend\nreturn f\n")
  local a = find(function(n) return n.kind == "local" and n.ins[1].name == "x" end)
  local b = find(function(n) return n.kind == "local" and n.ins[1].name == "y" end)
  local x1, y1 = xy(a, -10, -10)
  local x2, y2 = xy(b, b.w + 5, b.h + 5)
  drag(x1, y1, x2, y2); wait()
  check(#V:selection() >= 2, "the box selects both")
  local hx, hy = xy(a, 30, 6)
  drag(hx, hy, hx + 30, hy + 40); wait()
  local _, c = txt():gsub("%-%-@node dx=", "")
  check(c >= 2, "both moved (two --@node lines)")
  core.set_active_view(V)
  command.perform("nodegraph:nudge-right"); wait()
  check(txt():find("@node", 1, true) ~= nil, "arrows move the selection")
  V:add_comment(V:selection()); wait()
  check(#V.g.notes == 1 and txt():find("--@comment", 1, true), "a comment box")
  V:rename_note(V.g.notes[1]); V.editing.text = "Inputs"; V:commit_edit(); wait()
  check(txt():find("title=Inputs", 1, true), "renamed")
  check(undo_all(orig), "undo restores")
end)

test("share an expression as a local", function()
  local orig = open("local function f(a, b)\n  if a > b then\n    print(a)\n  end\n  return 0\nend\nreturn f\n")
  local ifn = titled("if")
  local en; for _, l in ipairs(V.g.links) do if l.expr and V.by_id[l.to] == ifn then en = V.by_id[l.from] end end
  local ret = titled("return")
  V:share(en, ret.ins[1], ret); wait()
  check(txt():find("local value = a > b", 1, true) and txt():find("return value", 1, true), "shared as local value")
  check(undo_all(orig), "undo restores")
end)

test("clicking a text line selects its node in the open graph", function()
  open("local a = 1\nlocal function f(x)\n  local y = x * 2\n  return y + 3\nend\nreturn f\n")
  local DocView = require "core.docview"
  local mine = core.root_view.root_node:get_node_for_view(V)
  local other
  local function walk(n)
    if n.type == "leaf" then if n ~= mine and not n.locked and not other then other = n end
    else walk(n.a); walk(n.b) end
  end
  walk(core.root_view.root_node)
  local dv = DocView(V.doc)
  other:add_view(dv)
  local function parent_of(n, p)                   -- give the text room
    if n == mine then return p end
    if n.type ~= "leaf" then return parent_of(n.a, n) or parent_of(n.b, n) end
  end
  local par = parent_of(core.root_view.root_node)
  local div = par and par.divider
  if par then par.divider = 0.5 end
  wait(3)
  local function click_at(line, col)
    local x, y = dv:get_line_screen_position(line)
    x = x + dv:get_col_x_offset(line, col) + 1
    y = y + dv:get_line_height() / 2
    core.root_view:on_mouse_pressed("left", x, y, 1)
    core.root_view:on_mouse_released("left", x, y)
    wait()
  end
  click_at(3, 5)
  check(V.selected and V.selected.line == 3 and V.selected.kind ~= "expr", "line 3: its statement")
  click_at(4, 13)
  local sel = V.selected
  check(sel and sel.kind == "expr" and txt():sub(sel.fields.body.pos, sel.fields.body.epos) == "y + 3", "inside `y + 3`: the expression node")
  V.pan.x = -5000; click_at(1, 3)
  local n = V.selected
  check(n and n.line == 1 and V.pan.x > -5000, "line 1: selected and scrolled into view")
  other:set_active_view(dv); other:close_active_view(core.root_view.root_node)
  if par then par.divider = div end
  core.set_active_view(V)
end)

test("RMB menu: keywords, this file's types and functions", function()
  local orig = open('---@class Paddle\n---@field speed number\n---@field ai? boolean\n\nlocal function hit(a, b)\n  return a\nend\nlocal M = {}\nfunction M:draw(dt) end\nreturn hit\n')
  local ox, oy = V:origin()
  local function rmb()                             -- on an empty spot (each pick drops its code where it was clicked)
    local x, y
    for yy = V.position.y + V.size.y - 30, V.position.y + 60, -30 do
      for xx = V.position.x + V.size.x - 40, V.position.x + 40, -40 do
        if not x and not V:node_at(xx, yy) and not V:note_at(xx, yy) then x, y = xx, yy end
      end
    end
    for try = 1, 3 do                              -- (rarely the first click lands mid-rebuild: again)
      core.root_view:on_mouse_pressed("right", x, y, 1); core.root_view:on_mouse_released("right", x, y)
      if V.menu then break end
      say("  (no menu on try " .. try .. ")"); wait()
    end
    return x, y end
  rmb()
  local tops = menu_texts("")
  check(table.concat(tops, ","):find("Flow,Variables,Values,Types,Functions,Get,Set,Library", 1, true), "groups: " .. table.concat(tops, ","))
  local types = menu_texts("Types")
  check(types[1] == "Paddle", "Types lists the file's classes")
  V.menu = nil; rmb()
  local fns = table.concat(menu_texts("Functions"), ",")
  check(fns:find("hit(a, b)", 1, true) and fns:find("M:draw(dt)", 1, true), "Functions lists the file's functions: " .. fns)
  V.menu = nil; rmb()
  check(menu_pick("Types>Paddle"), "pick Types > Paddle"); wait()
  check(txt():find("---@type Paddle", 1, true) and txt():find("speed = 0", 1, true) and not txt():find("ai = ", 1, true),
        "a typed local with its required fields")
  check(find(function(n) return n.table and n.title == "Paddle" end), "floating, it's already a Paddle node")
  rmb(); check(menu_pick("Functions>call hit(a, b)"), "pick Functions > hit"); wait()
  check(txt():find("hit(nil, nil)", 1, true), "a call to it")
  rmb(); check(menu_pick("Flow>Repeat / until"), "pick Flow > Repeat"); wait()
  check(txt():find("repeat\n", 1, true), "a repeat loop")
  rmb(); check(menu_pick("Library>math>math.floor(x)"), "two levels deep"); wait()
  check(txt():find("math.floor(0)", 1, true), "a library call")
  check(undo_all(orig), "undo restores")
end)

test("wrapped rows: the snake wire is hit where it's drawn", function()
  local lines = { "local function f()" }
  for i = 1, 30 do lines[#lines + 1] = "  local v" .. i .. " = " .. i .. " + 1" end
  lines[#lines + 1] = "end"
  local G = require "plugins.nodegraph.graph"
  local saved_wrap = G.WRAP_W
  G.WRAP_W = 1600                                  -- (narrow, so 30 statements wrap)
  open(table.concat(lines, "\n") .. "\n")
  G.WRAP_W = saved_wrap
  local e; for _, x in ipairs(V.g.exec) do if x.wrap then e = x; break end end
  check(e, "a wrapped flow wire")
  local a, b = V.by_id[e.from], V.by_id[e.to]
  local ox, oy = V:origin()
  local x1 = V:exec_xy(a, "out", e.out, ox, oy)
  local x2 = V:exec_xy(b, "in", 1, ox, oy)
  check(V:exec_wire_at((x1 + x2) / 2, V:wrap_y(b, oy)) == e, "its run back left is that wire")
end)

test("one If: wired into an else it's an elseif; taken out it's an if again", function()
  local orig = open("local function f(a)\n  if a > 1 then\n    print(1)\n  end\nend\nreturn f\n")
  local head = titled("local function f")
  local x, y = xy(head, 40, head.h + 160)
  V:on_mouse_pressed("right", x, y, 1); V:on_mouse_released("right", x, y)
  local flow = table.concat(menu_texts("Flow"), ",")
  check(flow:find("If,", 1, true) and not flow:find("If / else", 1, true), "Flow has a single If")
  V.menu = nil
  V:on_mouse_pressed("right", x, y, 1); V:on_mouse_released("right", x, y)
  check(menu_pick("Flow>If"), "add an If"); wait()
  local function float_if() return find(function(n) return n.title == "if" and n.edit and n.edit.kind == "float" end) end
  local main = find(function(n) return n.title == "if" and not (n.edit and n.edit.kind == "float") end)
  local fl = float_if()
  local ox, oy = V:origin()
  local x1, y1 = V:exec_xy(main, "out", 2, ox, oy)       -- else
  local x2, y2 = V:exec_xy(fl, "in", 1, ox, oy)
  drag(x1, y1, x2, y2); wait()
  check(txt():find("    print(1)\n  elseif true then\n  end", 1, true) and not txt():find("@float", 1, true), "an elseif in the text")
  local ei = find(function(n) return n.clause == 2 end)
  check(ei and ei.title == "if", "drawn as an if")
  V:disconnect_exec(ei); wait()
  check(txt():find("    print(1)\n  end", 1, true) and txt():find("@float", 1, true) and txt():find("if true then", 1, true)
        and load(txt()) ~= nil, "ALT: it floats as an if of its own")
  check(undo_all(orig), "undo restores")
end)

test("code wired before an elseif splits it into else + if", function()
  local orig = open("local function f(a, b)\n  if a then\n    print(1)\n  elseif b then\n    print(2)\n  end\nend\nreturn f\n")
  local head = titled("local function f")
  local x, y = xy(head, 40, head.h + 220)
  V:on_mouse_pressed("right", x, y, 1); V:on_mouse_released("right", x, y)
  check(menu_pick("Values>Call"), "add a call"); wait()
  local main = find(function(n) return n.title == "if" and n.clause == nil and not (n.edit and n.edit.kind == "float") end)
  local fl = find(function(n) return n.edit and n.edit.kind == "float" end)
  local ox, oy = V:origin()
  local x1, y1 = V:exec_xy(main, "out", 2, ox, oy)
  local x2, y2 = V:exec_xy(fl, "in", 1, ox, oy)
  drag(x1, y1, x2, y2); wait()
  check(txt():find('  else\n    print("hello")\n    if b then\n      print(2)\n    end\n  end', 1, true) and load(txt()) ~= nil,
        "else <code> if b ... end")
  check(undo_all(orig), "undo restores")
end)

test("elseif edge cases: detach one that reads names; merge into an empty else", function()
  local orig = open("local function f(a, b)\n  if a then\n    print(a)\n  elseif b > 2 then\n    print(b)\n  else\n    print(0)\n  end\nend\nreturn f\n")
  V:disconnect_exec(find(function(n) return n.clause == 2 end)); wait()
  check(txt():find("    print(a)\n  end", 1, true) and txt():find("  if b > 2 then\n    print(b)\n  else\n    print(0)\n  end\n  ]]", 1, true),
        "the elseif (and the else after it) float as one if")
  check(undo_all(orig), "undo restores")
  orig = open("local function f(a)\n  if a then\n    print(a)\n  else\n  end\nend\nreturn f\n")
  local head = titled("local function f")
  local x, y = xy(head, 40, head.h + 160)
  V:on_mouse_pressed("right", x, y, 1); V:on_mouse_released("right", x, y)
  check(menu_pick("Flow>If"), "add an If"); wait()
  local main = find(function(n) return n.title == "if" and not (n.edit and n.edit.kind == "float") end)
  local fl = find(function(n) return n.title == "if" and n.edit and n.edit.kind == "float" end)
  local ox, oy = V:origin()
  local x1, y1 = V:exec_xy(main, "out", 2, ox, oy)
  local x2, y2 = V:exec_xy(fl, "in", 1, ox, oy)
  drag(x1, y1, x2, y2); wait()
  check(txt():find("    print(a)\n  elseif true then\n  end\nend", 1, true), "the empty else becomes the elseif")
  check(undo_all(orig), "undo restores")
end)

test("ctrl+c / ctrl+v / ctrl+x / ctrl+z / ctrl+y", function()
  local orig = open("local function f(a)\n  local t = a + 1\n  print(t)\n  return t\nend\nreturn f\n")
  local function key(k) core.set_active_view(V); keymap.modkeys["ctrl"] = true; core.on_event("keypressed", k); keymap.modkeys["ctrl"] = false; wait() end
  V:select({ titled("new local") })
  key("c")
  check(system.get_clipboard() == "local t = a + 1", "ctrl+c copies the statement: " .. tostring(system.get_clipboard()))
  local head = titled("local function f")
  V.mx, V.my = xy(head, 60, head.h + 160)
  key("v")
  local _, n = txt():gsub("local t = a %+ 1", "")
  check(n == 2 and txt():find("@float", 1, true), "ctrl+v drops it as floating code")
  key("z")
  check(txt() == orig, "ctrl+z undoes the paste in one step")
  key("y")
  check(txt():find("@float", 1, true), "ctrl+y redoes it")
  key("z")
  V:select({ find(function(n) return n.title:find("print", 1, true) end) })
  key("x")
  check(system.get_clipboard() == "print(t)" and not txt():find("print(t)", 1, true) and load(txt()) ~= nil,
        "ctrl+x copies and deletes")
  check(undo_all(orig), "undo restores")
end)

test("moving nodes moves only them; an elseif moves too", function()
  local orig = open("local function f(v, t)\n  for _ = 1, 8 do\n    if v.y < 0 then\n      t = 1\n    elseif v.y > 0 then\n      t = 2\n    end\n    print(t)\n  end\nend\nreturn f\n")
  local function pos() local m = {}; for _, n in ipairs(V.g.nodes) do m[#m + 1] = { n.title, n.x, n.y, n.clause, n.kind } end; return m end
  local ei = find(function(n) return n.clause == 2 end)
  V:select({ ei }); V.note = nil; V:nudge(1, 0); wait()
  check(not (V.note and V.note.text:find("can be moved", 1, true)) and txt():find("    %-%-@node dx=%d+\n    elseif"), "an elseif can be moved")
  local before = pos()
  local ifs = {}
  for _, n in ipairs(V.g.nodes) do if n.title == "if" then ifs[#ifs + 1] = n end end
  V:select(ifs); V:nudge(1, 0); wait()
  local after, moved, stayed = pos(), 0, true
  for i, b in ipairs(before) do
    local a = after[i]
    if b[2] ~= a[2] or b[3] ~= a[3] then
      moved = moved + 1
      if b[1] ~= "if" then stayed = false end
    end
  end
  check(stayed and moved >= 2, "only the two ifs moved, not their conditions (" .. moved .. ")")
  check(undo_all(orig), "undo restores")
end)

test("a new tab fits the graph; the start node moves", function()
  check(V.fitted, "the first graph opened was fitted")
  open("local a = 1\nlocal b = 2\nprint(a + b)\n")
  V:fit(0.75)
  local g, z = V.g, V.zoom
  local ox, oy = V:origin()
  local cx = ox + ((g.x0 or 0) + g.w) / 2 * z
  check(math.abs(cx - (V.position.x + V.size.x / 2)) < 2 and (g.w - (g.x0 or 0)) * z <= V.size.x * 0.75 + 1, "fit: centred, 75%")
  V:select({ titled("start") }); V.note = nil; V:nudge(1, 1); wait()
  check(txt():find("^%-%-@start dx=%d+ dy=%d+\n") ~= nil, "the start node keeps its place in a --@start line")
  check(titled("start").x > 0, "and it moved")
end)

test("flow wire onto a taken flow in: the old wire goes, the code moves", function()
  local orig = open("local function f()\n  print(1)\n  print(2)\nend\nlocal function g()\n  print(3)\nend\nreturn f, g\n")
  local function call(arg)
    return find(function(n) return n.title == "call print" and n.ins[1] and n.ins[1].text == arg end)
  end
  local ox, oy = V:origin()
  local x1, y1 = V:exec_xy(call("3"), "out", 1, ox, oy)
  local x2, y2 = V:exec_xy(call("2"), "in", 1, ox, oy)
  drag(x1, y1, x2, y2); wait()
  check(txt():find("  print(1)\nend", 1, true) and txt():find("  print(3)\n  print(2)\nend", 1, true), "print(2) runs after print(3) now")
  check(undo_all(orig), "undo restores")
end)

test("flow wire dropped on the background: the Add menu, then wired", function()
  local orig = open("local function g()\n  print(3)\nend\nreturn g\n")
  local n = find(function(n) return n.title == "call print" end)
  local ox, oy = V:origin()
  local x1, y1 = V:exec_xy(n, "out", 1, ox, oy)
  drag(x1, y1, x1 + 40, y1 + 160)
  check(V.menu ~= nil, "the Add menu opens where it was dropped")
  check(menu_pick("Values>Call"), "pick a call"); wait()
  check(txt():find('  print(3)\n  print("hello")\nend', 1, true) and not txt():find("@float", 1, true), "added and wired: it runs after print(3)")
  check(undo_all(orig), "undo restores")
end)

test("chips: parameters show chips, no wires; click lights one up; drag from it rewires", function()
  local orig = open("local function f(a, b)\n  return a\nend\nreturn f\n")
  local ret = titled("return")
  local chip
  for _, h in ipairs(V.hits) do if h.kind == "chip" and h.node == ret then chip = h end end
  check(chip and chip.decl.name == "a", "return's pin shows a chip: a")
  click(chip.x + 3, chip.y + 3); wait()
  check(V.lit_decl and V.lit_decl.name == "a", "a click keeps a lit")
  for _, h in ipairs(V.hits) do if h.kind == "chip" and h.node == ret then chip = h end end
  click(chip.x + 3, chip.y + 3); wait()
  check(V.lit_decl == nil, "a second click: off")
  for _, h in ipairs(V.hits) do if h.kind == "chip" and h.node == ret then chip = h end end
  local head = titled("local function f")
  local ox, oy = V:origin()
  local bi; for k, o in ipairs(head.outs) do if o.decl and o.decl.name == "b" then bi = k end end
  local bx, by = V:socket_xy(head, "out", bi, ox, oy)
  drag(chip.x + 3, chip.y + 3, bx, by); wait()
  check(txt():find("  return b\n", 1, true), "dragged from the chip onto b: return b")
  wait(); ret = titled("return"); chip = nil
  for _, h in ipairs(V.hits) do if h.kind == "chip" and h.node == ret then chip = h end end
  check(chip and chip.decl.name == "b", "now the chip says b")
  if chip then click(chip.x + 3, chip.y + 3, { "alt" }); wait() end
  check(not txt():find("  return b\n", 1, true), "alt+click on the chip removes that wire: " .. txt():match("\n(  return[^\n]*)") )
  check(undo_all(orig), "undo restores")
end)

test("a statement sharing its line (if c then tp = 0 end) moves: an inline tag", function()
  local orig = open("local tp, x = -1, 2\nif tp < 0 and x > 1 then tp = 0 end\nprint(tp)\n")
  local st = titled("set")
  check(st and U.movable(st), "the set node can be moved")
  local hx, hy = xy(st, 20, 6)
  local sx, sy = st.x, st.y                        -- (the drag moves the node object itself)
  drag(hx, hy, hx + 48, hy + 72); wait()
  check(txt():find("then %-%-%[%[@node dx=%-?%d+ dy=%-?%d+%]%] tp = 0 end"), "an inline --[[@node]]: " .. txt():match("\n(if[^\n]*)"))
  local st2 = titled("set")
  check(st2 and st2.x > sx and st2.y > sy, "and it stays where it was dropped")
  V:select({ st2 }); V:nudge(-1, 0); wait()
  check(txt():find("--[[@node", 1, true), "nudged: still inline")
  check(undo_all(orig), "undo restores")
end)

test("nothing selected: arrows, page up/down, home/end scroll the camera, eased", function()
  open("local a = 1\n" .. string.rep("print(a)\n", 60))
  V:select({}); core.set_active_view(V)
  V.zoom = 1; V.pan.x, V.pan.y = 0, 0; V.scroll_anim = nil; wait()
  local x0, y0 = V.pan.x, V.pan.y
  core.on_event("keypressed", "down"); wait(2)
  check(V.scroll_anim ~= nil, "it animates")
  local t0 = system.get_time(); repeat wait() until not V.scroll_anim or system.get_time() - t0 > 2
  local _, want = V:clamp_pan(x0, y0 - 0.20 * V.size.y)
  check(want < y0 and math.abs(V.pan.y - want) < 1, "down: 20% of the view (" .. (y0 - V.pan.y) .. ")")
  local y1 = V.pan.y
  core.on_event("keypressed", "pagedown"); t0 = system.get_time(); repeat wait() until not V.scroll_anim or system.get_time() - t0 > 2
  check(y1 - V.pan.y > 0.20 * V.size.y, "page down: further (" .. (y1 - V.pan.y) .. ")")
  V:select({ titled("new local") })
  local py = V.pan.y
  core.on_event("keypressed", "down"); wait(4)
  check(V.pan.y == py and txt():find("@node", 1, true), "with a selection the arrows move it instead")
end)

test("every node of plugins/nodegraph/tests/move-00.lua can be dragged by its title", function()
  local file = rawget(_G, "MOVE_FILE") or "plugins/nodegraph/tests/move-00.lua"   -- (any other: MOVE_FILE = "games/pong.lua")
  local fh = io.open(file) or io.open(DATADIR .. "/../../../" .. file)
  local src = fh:read("*a"); fh:close()
  local orig = open(src)
  local count, bad = #V.g.nodes, {}
  for i = 1, count do
    local n = V.g.nodes[i]
    local title, x0, y0 = n.title, n.x, n.y
    V.scroll_anim = nil; V.zoom = 1                -- (in view: a big graph doesn't fit)
    V.pan.x, V.pan.y = V.size.x / 3 - n.x * V.zoom, V.size.y / 3 - n.y * V.zoom
    local hx, hy = xy(n, math.min(n.w / 2, 40), 6)
    V:select({})
    drag(hx, hy, hx + 48, hy + 48); wait()
    local m = V.g.nodes[i]
    if txt() == orig or not m or m.title ~= title or m.x - x0 < 24 or m.y - y0 < 24 then
      bad[#bad + 1] = title
      if #bad <= 3 then say(string.format("  %s: changed %s, now %s, by %s, %s, zoom %.2f, hit %s", title, tostring(txt() ~= orig), m and m.title, m and (m.x - x0), m and (m.y - y0), V.zoom, tostring(V:node_at(hx, hy) and V:node_at(hx, hy).title))) end
    end
    for _ = 1, 3 do if txt() ~= orig then V.doc:undo() end end
    wait()
  end
  check(#bad == 0, count .. " nodes dragged" .. (#bad > 0 and ("; stuck: " .. table.concat(bad, ", ")) or ""))
  local n = V.g.nodes[3]                           -- far out (10%): a drag moves the node, no wire
  V.zoom = 0.1; V.pan.x, V.pan.y = V.size.x / 3 - n.x * V.zoom, V.size.y / 3 - n.y * V.zoom
  local hx, hy = xy(n, 40, 6)
  drag(hx, hy, hx + 30, hy + 30); wait()
  check(txt() ~= orig and txt():find("@", 1, true), "zoomed far out, a drag still moves the node")
  check(undo_all(orig), "undo restores")
end)

test("ctrl+a selects all, again none; ctrl+shift+a none", function()
  open("local a = 1\nprint(a)\nprint(a + 1)\n")
  core.set_active_view(V); V:select({})
  local function key(k, shift)
    keymap.modkeys["ctrl"] = true; keymap.modkeys["shift"] = shift or false
    core.on_event("keypressed", k)
    keymap.modkeys["ctrl"] = false; keymap.modkeys["shift"] = false
    wait()
  end
  key("a")
  check(#V:selection() == #V.g.nodes and #V.g.nodes > 2, "ctrl+a: all " .. #V.g.nodes)
  key("a")
  check(#V:selection() == 0, "ctrl+a again: none")
  key("a"); key("a", true)
  check(#V:selection() == 0, "ctrl+shift+a: none")
end)

test("the Add menu filters as you type (fuzzy); enter or a click adds", function()
  local orig = open("local a = 1\nprint(a)\n")
  core.set_active_view(V)
  local function bg()                              -- an empty spot
    for yy = V.position.y + V.size.y - 40, V.position.y + 40, -20 do
      for xx = V.position.x + V.size.x - 40, V.position.x + 40, -20 do
        if not V:node_at(xx, yy) and not V:note_at(xx, yy) then return xx, yy end
      end
    end
  end
  local x, y = bg()
  V:on_mouse_pressed("right", x, y, 1); V:on_mouse_released("right", x, y); wait()
  check(V.menu and V.menu.search == "", "the Add menu has a search box")
  for c in ("math e"):gmatch(".") do core.on_event("textinput", c) end
  wait()
  local m = V.menu
  check(m.items[1] and m.items[1].text == "Math expression" and m.hot == 1, "math e: Math expression first (" .. tostring(m.items[1] and m.items[1].text) .. ")")
  check(m.items[1].hint == "Values", "it says where it lives")
  core.on_event("keypressed", "backspace"); core.on_event("keypressed", "backspace"); wait()
  check(V.menu.search == "math", "backspace erases")
  local found
  for _, it in ipairs(V.menu.items) do if it.text == "math.sqrt(x)" then found = true end end
  check(found, "math: math.sqrt(x) among them")
  for c in (" sqr"):gmatch(".") do core.on_event("textinput", c) end
  wait()
  check(V.menu.items[1].text == "math.sqrt(x)", "math sqr: math.sqrt(x)")
  core.on_event("keypressed", "return"); wait()
  check(not V.menu and txt():find("math.sqrt(2)", 1, true), "enter adds it")
  check(undo_all(orig), "undo restores")
  wait(); x, y = bg()
  V:on_mouse_pressed("right", x, y, 1); V:on_mouse_released("right", x, y); wait()
  check(V.menu and V.menu.search, "open again")
  for c in ("xyzzyq"):gmatch(".") do core.on_event("textinput", c) end
  wait()
  check(V.menu.items[1].text == "(no match)", "no match says so")
  keymap.modkeys["ctrl"] = true; core.on_event("keypressed", "backspace"); keymap.modkeys["ctrl"] = false; wait()
  check(V.menu.search == "" and V.menu.items[1].text ~= "(no match)", "ctrl+backspace clears: the full menu again")
  for c in ("if"):gmatch(".") do core.on_event("textinput", c) end
  wait()
  check(menu_pick("If"), "a click on a result adds it"); wait()
  check(txt():find("if true then", 1, true), "the If is there")
  check(undo_all(orig), "undo restores")
end)

test("a variable wired onto a return: one more value, every return padded, named", function()
  local orig = open("local function f(a, b)\n  local x = a + b\n  local ok = a > b\n  if a then\n    return x\n  end\n  return\nend\nreturn f\n")
  local function rets() local l = {}; for _, n in ipairs(V.g.nodes) do if n.title == "return" and n.ret_fn then l[#l + 1] = n end end; return l end
  V.zoom = 1; V.pan.x, V.pan.y = 40, 60; wait()
  local function drop(var, target)
    local ox, oy = V:origin()
    local src
    for _, n in ipairs(V.g.nodes) do
      for k, o in ipairs(n.outs) do if o.decl and o.decl.name == var and n.kind == "local" then src = { n, k } end end
    end
    local sx, sy = V:socket_xy(src[1], "out", src[2], ox, oy)
    local tx, ty = xy(target, target.w / 2, target.h - 6)
    drag(sx, sy, tx, ty); wait()
  end
  drop("ok", rets()[2])                            -- the bare return at the end
  check(txt():find("    return x, false\n", 1, true) and txt():find("  return nil, ok\n", 1, true),
        "a second value for every path: ok here (nil before it), false in the other (ok is a boolean): " .. tostring(V.note and V.note.text))
  check(txt():find("---@return any\n---@return boolean ok\nlocal function f", 1, true), "named by ---@return lines")
  local r2 = rets()[2]
  check(r2.ins[1] and r2.ins[1].name == "value 1" and r2.ins[2] and r2.ins[2].name == "ok", "its pins: value 1, ok")
  drop("x", rets()[1])
  check(txt():find("    return x, false, x\n", 1, true) and txt():find("  return nil, ok, nil\n", 1, true), "again: old pins stay, x added, the other padded (x's type isn't known: nil)")
  check(txt():find("---@return any x\nlocal function f", 1, true), "x named too")
  local add, r1 = nil, rets()[1]
  V.pan.x, V.pan.y = V.size.x / 3 - r1.x, V.size.y / 3 - r1.y; wait()
  for _, h in ipairs(V.hits) do if h.kind == "action" and h.pin and h.pin.action == "addret" and h.node and h.node.ret_fn then add = h end end
  check(add ~= nil, "a + add value row")
  if add then click(add.x + 3, add.y + 3); wait() end
  check(txt():find("return x, false, x, nil", 1, true) and txt():find("return nil, ok, nil, nil", 1, true), "a click adds nil everywhere: " .. tostring(V.note and V.note.text) .. txt())
  check(undo_all(orig), "undo restores")
end)

test("ctrl+f finds a node: as you type it's selected and shown; enter keeps it", function()
  open("local function f(x, lim, dy)\n  local speed = 4\n  x.y = math.max(-lim, math.min(lim, (x.y or 0) + dy))\n  print(speed)\nend\nreturn f\n")
  core.set_active_view(V); V:select({})
  local function ctrl(k) keymap.modkeys["ctrl"] = true; core.on_event("keypressed", k); keymap.modkeys["ctrl"] = false; wait() end
  ctrl("f")
  local m = V.menu
  check(m and m.find and m.search == "", "a find box")
  check(m and m.x + m.w > V.position.x + V.size.x - 40 and m.y < V.position.y + 80, "in the top-right corner")
  for c in ("mth mn"):gmatch(".") do core.on_event("textinput", c) end
  wait()
  check(V.menu.items[1] and V.menu.items[1].text:find("^math%.min"), "fuzzy: mth mn -> math.min first: " .. tostring(V.menu.items[1] and V.menu.items[1].text))
  check(V.selected and V.selected.title == "math.min", "already selected")
  check(V.scroll_anim ~= nil, "and the camera glides to it")
  ctrl("a")                                        -- (all of it: typing replaces it; lite's editing, plugins/textproxy.lua)
  for c in ("speed"):gmatch(".") do core.on_event("textinput", c) end
  wait()
  local first = V.selected
  core.on_event("keypressed", "down"); wait()
  local its = {}; for _, it in ipairs(V.menu and V.menu.items or {}) do its[#its + 1] = it.text end
  check(V.selected and V.selected ~= first, "down: the next one shown: hot " .. tostring(V.menu and V.menu.hot) .. " of " .. table.concat(its, " | "))
  core.on_event("keypressed", "return"); wait()
  check(V.menu == nil and V.selected ~= nil, "enter keeps it and closes")
  ctrl("f"); ctrl("f")
  check(V.menu == nil, "ctrl+f again closes")
end)

test("ctrl+s saves from the graph, and ctrl+z still undoes after", function()
  local orig = open("local a = 1\nprint(a)\n")
  core.set_active_view(V)
  local function ctrl(k) keymap.modkeys["ctrl"] = true; core.on_event("keypressed", k); keymap.modkeys["ctrl"] = false; wait() end
  local lit
  for _, n in ipairs(V.g.nodes) do for _, q in ipairs(n.ins) do if q.kind == "literal" and q.text == "1" then lit = q end end end
  V:set_literal(lit.pos, lit.epos, "5"); wait()
  check(txt():find("local a = 5", 1, true) and V.doc:is_dirty(), "edited")
  local t0 = system.get_time(); repeat wait() until system.get_time() - t0 > 0.5   -- (undo merges what's closer)
  ctrl("s")
  local fh = io.open(V.doc.filename, "rb"); local disk = fh:read("*a"); fh:close()
  check(disk:find("local a = 5", 1, true) and not V.doc:is_dirty(), "ctrl+s in the graph saved it")
  ctrl("z")
  check(txt() == orig, "one ctrl+z after the save undoes the edit: " .. txt())
end)

test("ctrl+d deselects; F3 / shift+F3 find again; colour squares; ctrl+shift+n duplicates", function()
  local orig = open("local speed = 1\nprint(speed)\nprint(speed + 1)\nprint(2)\n")
  core.set_active_view(V)
  local function ctrl(k, shift) keymap.modkeys["ctrl"] = true; keymap.modkeys["shift"] = shift or false; core.on_event("keypressed", k); keymap.modkeys["ctrl"] = false; keymap.modkeys["shift"] = false; wait() end
  V:select(V.g.nodes); ctrl("d")
  check(#V:selection() == 0, "ctrl+d: none selected")
  ctrl("f"); for c in ("print"):gmatch(".") do core.on_event("textinput", c) end; wait()
  core.on_event("keypressed", "return"); wait()
  local first = V.selected
  core.on_event("keypressed", "f3"); wait()
  local second = V.selected
  check(first and second and second ~= first and second.title == "call print", "F3: the next print")
  keymap.modkeys["shift"] = true; core.on_event("keypressed", "f3"); keymap.modkeys["shift"] = false; wait()
  check(V.selected == first or (V.selected and V.selected.title == first.title and V.selected.line == first.line), "shift+F3: back")
  -- colour: a row of squares in the node's menu
  local n = titled("call print")
  local x, y = xy(n, 20, 6)
  V:on_mouse_pressed("right", x, y, 1); V:on_mouse_released("right", x, y); wait()
  local m, row = V.menu, nil
  for i, it in ipairs(m and m.items or {}) do if it.swatches then row = i end end
  check(row ~= nil, "a row of colour squares")
  if row then
    local step = V.SWATCH_STEP * SCALE
    local sy = m.y + 4 * SCALE + (m.top or 0) + (row - 1 - m.scroll) * m.ih + m.ih / 2
    V:on_mouse_pressed("left", m.x + 12 * SCALE + 2 * step + 4, sy, 1); V:on_mouse_released("left", m.x + 12 * SCALE + 2 * step + 4, sy); wait()
    check(txt():find("color=#e5a050", 1, true), "the third square: its colour (#e5a050)")
    n = titled("call print"); x, y = xy(n, 20, 6)
    V:on_mouse_pressed("right", x, y, 1); V:on_mouse_released("right", x, y); wait()
    m = V.menu
    for i, it in ipairs(m.items) do if it.swatches then row = i end end
    sy = m.y + 4 * SCALE + (m.top or 0) + (row - 1 - m.scroll) * m.ih + m.ih / 2
    V:on_mouse_pressed("left", m.x + 12 * SCALE + 4, sy, 1); V:on_mouse_released("left", m.x + 12 * SCALE + 4, sy); wait()
    check(not txt():find("color=", 1, true), "the first square: no colour")
  end
  check(undo_all(orig), "undo restores")
  -- duplicate the tab
  local node = core.root_view.root_node:get_node_for_view(V)
  local before = #node.views
  V.zoom = 0.8
  ctrl("n", true)
  local dup = core.active_view
  check(#node.views == before + 1 and dup ~= V and dup.doc == V.doc and dup.zoom == 0.8, "ctrl+shift+n: the same graph in a new tab")
  if dup ~= V then node:set_active_view(dup); node:close_active_view(core.root_view.root_node) end
  core.set_active_view(V); wait()
  ctrl("t", true)
  dup = core.active_view
  check(dup ~= V and dup.doc == V.doc, "ctrl+shift+t too")
  if dup ~= V then node:set_active_view(dup); node:close_active_view(core.root_view.root_node) end
  core.set_active_view(V); wait()
end)

test("a hex colour string: a click opens the picker, a double-click still edits the text", function()
  local orig = open('dd.cross(1, 2, 5, "#ff965a80")\n')
  V.zoom = 1; V.pan.x, V.pan.y = 60, 60; wait()
  local sw
  for _, h in ipairs(V.hits) do if h.kind == "swatch" and h.hexstr then sw = h end end
  check(sw ~= nil, "the tinted box is a colour widget")
  if not sw then return end
  click(sw.x + 4, sw.y + 4); wait()
  check(V.picker ~= nil and V.picker.a ~= nil, "a click: the picker (with alpha: the string has 8 digits)")
  local _, sv = V:picker_rects()
  drag(sv.x + 2, sv.y + sv.h - 2, sv.x + 3, sv.y + sv.h - 3); wait()      -- (bottom-left: black)
  check(txt():find('dd.cross(1, 2, 5, "#0', 1, true) and txt():match('"#%x%x%x%x%x%x80"'), "picked: a new #rrggbb, alpha kept (80): " .. txt())
  check(V.picker ~= nil, "the picker stays open for more")
  V.picker = nil; wait()
  for _, h in ipairs(V.hits) do if h.kind == "swatch" and h.hexstr then sw = h end end
  V:on_mouse_pressed("left", sw.x + 4, sw.y + 4, 1); V:on_mouse_released("left", sw.x + 4, sw.y + 4)
  V:on_mouse_pressed("left", sw.x + 4, sw.y + 4, 2); V:on_mouse_released("left", sw.x + 4, sw.y + 4); wait()
  check(V.editing ~= nil, "a double-click: editing the text, as before")
  if V.editing then
    V.editing.text, V.editing.cur = '"#fff"', 7
    V:commit_edit(); wait()
    check(txt():find('dd.cross(1, 2, 5, "#fff")', 1, true), "typed: #fff")
  end
  V.picker = nil
  check(undo_all(orig), "undo restores")
end)

test("find list: up/down wrap; page up/down and home/end jump, no wrap", function()
  local src = "local a = 1\n" .. string.rep("print(a)\n", 30)
  open(src)
  core.set_active_view(V)
  V:open_find(); for c in ("print"):gmatch(".") do core.on_event("textinput", c) end; wait()
  local m = V.menu
  local n = #m.items
  check(m.hot == 1 and n == 30, "30 results, the first hot")
  core.on_event("keypressed", "up"); wait()
  check(m.hot == n, "up on the first: wraps to the last")
  core.on_event("keypressed", "down"); wait()
  check(m.hot == 1, "down on the last: wraps to the first")
  core.on_event("keypressed", "pagedown"); wait()
  check(m.hot == 1 + math.max(1, m.rows - 1), "page down: a page further (" .. m.hot .. ")")
  core.on_event("keypressed", "end"); wait()
  check(m.hot == n, "end: the last")
  core.on_event("keypressed", "pagedown"); wait()
  check(m.hot == n, "page down on the last: stays (no wrap)")
  core.on_event("keypressed", "home"); wait()
  check(m.hot == 1, "home: the first")
  core.on_event("keypressed", "pageup"); wait()
  check(m.hot == 1, "page up on the first: stays")
  check(V.selected == m.node_of[m.items[1].fn], "and the graph follows the hot one")
  V.menu = nil
end)

test("get: RMB, type 'get ba', pick it: a getter to wire anywhere; far reads are chips", function()
  local body = string.rep("  print(1)\n", 45)
  local orig = open("local ball, banner = 1, 2\nlocal function f()\n  local inner = 3\n" .. body .. "  print(0)\nend\nreturn f\n")
  core.set_active_view(V)
  V.zoom = 1; V.pan.x, V.pan.y = 40, 60; wait()
  local function bg()
    for yy = V.position.y + V.size.y - 40, V.position.y + 40, -20 do
      for xx = V.position.x + V.size.x - 40, V.position.x + 40, -20 do
        local ox, oy = V:origin()
        local gx, gy = (xx - ox) / V.zoom, (yy - oy) / V.zoom
        local in_frame = false                     -- (outside every function's frame: the top level)
        for _, f in ipairs(V.g.frames) do
          if gx >= f.x and gx <= f.x + f.w and gy >= f.y and gy <= f.y + f.h then in_frame = true end
        end
        if not in_frame and not V:node_at(xx, yy) and not V:note_at(xx, yy) then return xx, yy end
      end
    end
  end
  local x, y = bg()
  V:on_mouse_pressed("right", x, y, 1); V:on_mouse_released("right", x, y); wait()
  for c in ("get ba"):gmatch(".") do core.on_event("textinput", c) end; wait()
  local texts = {}
  for _, it in ipairs(V.menu.items) do texts[#texts + 1] = it.text end
  local all = {}
  for _, it in ipairs(V.menu.flat) do if it.text:find("^get ") then all[#all + 1] = it.text end end
  check(not table.concat(all, ","):find("get inner", 1, true), "outside f: f's locals aren't listed: " .. table.concat(all, ","))
  check(table.concat(texts, ","):find("get ball", 1, true) and table.concat(texts, ","):find("get banner", 1, true), "get ba: ball and banner: " .. table.concat(texts, ",") .. " | decls " .. #(V.res and V.res.decls or {}) .. " file " .. tostring(V.doc.filename) .. " flat " .. #(V.menu.flat or {}))
  check(menu_pick("get ball"), "pick get ball"); wait()
  local gn = find(function(n) return n.getter == "ball" end)
  check(gn ~= nil and gn.outs[1] and gn.outs[1].name == "ball", "a get ball node, its out: ball")
  -- wire it into the last print's pin
  local pr
  for _, n in ipairs(V.g.nodes) do if n.title == "call print" and n.ins[1] and n.ins[1].text == "0" then pr = n end end
  V.pan.x, V.pan.y = V.size.x / 3 - pr.x, V.size.y / 3 - pr.y; wait()
  gn = find(function(n) return n.getter == "ball" end)
  for _, n in ipairs(V.g.nodes) do if n.title == "call print" and n.ins[1] and n.ins[1].text == "0" then pr = n end end
  V.pan.x, V.pan.y = V.size.x / 2 - (gn.x + pr.x) / 2, V.size.y / 2 - (gn.y + pr.y) / 2; wait()
  gn = find(function(n) return n.getter == "ball" end)
  for _, n in ipairs(V.g.nodes) do if n.title == "call print" and n.ins[1] and n.ins[1].text == "0" then pr = n end end
  local ox, oy = V:origin()
  local gx, gy = V:socket_xy(gn, "out", 1, ox, oy)
  local px, py = V:socket_xy(pr, "in", 1, ox, oy)
  drag(gx, gy, px, py); wait()
  check(txt():find("  --@expr slot=1 get=ball\n  print(ball)\nend", 1, true), "wired: print(ball), the get node kept by a tag: " .. tostring(V.note and V.note.text))
  check(find(function(n) return n.getter == "ball" and not (n.edit and n.edit.kind == "float") end) ~= nil, "a get ball node feeds the print")
  check(undo_all(orig), "undo restores")
  wait()
  -- inside f: its own locals first, then the outer ones
  local fr = V.g.frames[1]
  local ox2, oy2 = V:origin()
  local ix, iy
  for gy2 = fr.y + fr.h - 10, fr.y + 10, -10 do
    for gx2 = fr.x + 10, fr.x + fr.w - 10, 20 do
      local sx, sy = ox2 + gx2 * V.zoom, oy2 + gy2 * V.zoom
      if not ix and sx > V.position.x and sx < V.position.x + V.size.x and sy > V.position.y and sy < V.position.y + V.size.y
         and not V:node_at(sx, sy) then ix, iy = sx, sy end
    end
  end
  if not ix then V.pan.x, V.pan.y = V.size.x / 2 - (fr.x + 20) * V.zoom, V.size.y / 2 - (fr.y + fr.h - 20) * V.zoom; wait(); ox2, oy2 = V:origin(); ix, iy = ox2 + (fr.x + 20) * V.zoom, oy2 + (fr.y + fr.h - 20) * V.zoom end
  V:on_mouse_pressed("right", ix, iy, 1); V:on_mouse_released("right", ix, iy); wait()
  local order = {}
  for _, it in ipairs(V.menu and V.menu.flat or {}) do if it.text:find("^get ") then order[#order + 1] = it.text end end
  check(order[1] == "get inner" and table.concat(order, ","):find("get ball", 1, true), "inside f: inner first, then the outer ones: " .. table.concat(order, ","))
  V.menu = nil
end)

test("replacing or cutting a pin's input: the old expression node stays, floating", function()
  local orig = open("local function f(a, b)\n  local t = math.abs(a - 1)\n  return t\nend\nreturn f\n")
  V.zoom = 1; V.pan.x, V.pan.y = 40, 60; wait()
  local st = find(function(n) return n.kind == "local" end)
  local head = titled("local function f")
  local ox, oy = V:origin()
  local bi; for k, o in ipairs(head.outs) do if o.decl and o.decl.name == "b" then bi = k end end
  local bx, by = V:socket_xy(head, "out", bi, ox, oy)
  local sx, sy = V:socket_xy(st, "in", 1, ox, oy)
  drag(bx, by, sx, sy); wait()
  local t = txt()
  check(t:find("  local t = b\n", 1, true), "the pin reads b now")
  check(t:find("@float[^\n]*\n%s*%(math%.abs%(a %- 1%)%)\n"), "the old math.abs node stays, floating: " .. t)
  check(titled("math.abs") ~= nil, "and it's still a node")
  check(undo_all(orig), "undo restores")
  wait()
  st = find(function(n) return n.kind == "local" end)
  ox, oy = V:origin()
  sx, sy = V:socket_xy(st, "in", 1, ox, oy)
  click(sx, sy, { "alt" }); wait()
  t = txt()
  check(t:find("  local t = nil\n", 1, true) and t:find("@float[^\n]*\n%s*%(math%.abs%(a %- 1%)%)\n"), "alt+click: nil there, the node floats")
  check(undo_all(orig), "undo restores")
end)

test("a getter wired into a pin stays a get node there (the chip goes); cut: it floats again", function()
  local body = string.rep("print(1)\n", 45)
  local orig = open("local ball = 1\n" .. body .. "w:spawn(\"/a\", { ball = ball })\nreturn ball\n")
  core.set_active_view(V)
  local tbl = find(function(n) return n.table end)
  local pin
  for _, q in ipairs(tbl.ins) do if q.name == "ball" then pin = q end end
  check(pin and pin.chip == "ball", "before: a ball chip (read far from its declaration)")
  V:add_node({ name = "get ball", text = "ball", raw = true }, tbl.x - 200, tbl.y + 120); wait()
  local gn = find(function(n) return n.getter == "ball" and n.edit and n.edit.kind == "float" end)
  tbl = find(function(n) return n.table end)
  V.zoom = 1; V.pan.x, V.pan.y = V.size.x / 2 - tbl.x, V.size.y / 2 - tbl.y; wait()
  gn = find(function(n) return n.getter == "ball" and n.edit and n.edit.kind == "float" end)
  tbl = find(function(n) return n.table end)
  local pi; for k, q in ipairs(tbl.ins) do if q.name == "ball" then pi = k end end
  local ox, oy = V:origin()
  local gx, gy = V:socket_xy(gn, "out", 1, ox, oy)
  local px, py = V:socket_xy(tbl, "in", pi, ox, oy)
  drag(gx, gy, px, py); wait()
  local t = txt()
  check(t:find("%-%-@expr slot=3%.1 get=ball\nw:spawn") and t:find('{ ball = ball }', 1, true), "the read is the same; a get tag keeps the node: " .. t:sub(-120))
  local g2 = find(function(n) return n.getter == "ball" end)
  check(g2 and not (g2.edit and g2.edit.kind == "float"), "a get ball node wired into the table")
  tbl = find(function(n) return n.table end)
  for _, q in ipairs(tbl.ins) do if q.name == "ball" then pin = q end end
  check(pin and not pin.chip and pin.kind == "expr", "no chip on that pin now")
  local wired = false
  for _, l in ipairs(V.g.links) do if l.expr and V.g.nodes[l.from] == g2 and V.g.nodes[l.to] == tbl then wired = true end end
  check(wired, "the get node's wire goes into the table")
  -- ALT+click the pin: nil there, the get node floats, its tag goes
  V.pan.x, V.pan.y = V.size.x / 2 - tbl.x, V.size.y / 2 - tbl.y; wait()
  tbl = find(function(n) return n.table end)
  for k, q in ipairs(tbl.ins) do if q.name == "ball" then pi = k end end
  ox, oy = V:origin()
  px, py = V:socket_xy(tbl, "in", pi, ox, oy)
  click(px, py, { "alt" }); wait()
  t = txt()
  check(t:find("{ ball = nil }", 1, true) and not t:find("get=ball", 1, true) and t:find("@float[^\n]*\n%s*ball\n"), "cut: nil, no tag, the getter floats")
  check(undo_all(orig), "undo restores")
end)

test("hover lights wires and pins; wires snap to pins; an input dropped on the background offers what fits", function()
  local orig = open("local function f(a, b)\n  local x = a + b\n  if true then\n    print(x)\n  end\nend\nreturn f\n")
  core.set_active_view(V)
  V.zoom = 1; V.pan.x, V.pan.y = 40, 60; wait()
  local ox, oy = V:origin()
  local loc = find(function(n) return n.kind == "local" end)
  local pr = titled("call print")
  local x1, y1 = V:socket_xy(loc, "out", 1, ox, oy)
  local pi; for k, q in ipairs(pr.ins) do if q.decl and q.decl.name == "x" then pi = k end end
  local x2, y2 = V:socket_xy(pr, "in", pi, ox, oy)
  V:on_mouse_moved(x1, y1, 0, 0); wait()
  check(V.hl and V.hl.socks[pr.ins[pi]], "hovering x's output: print's x pin lights up too")
  local mx, my
  for t = 0.05, 0.95, 0.05 do                      -- a point on the wire, off the nodes
    local u = 1 - t
    local d = math.max(math.abs(x2 - x1) * 0.5, 40 * SCALE)
    local cx = u*u*u*x1 + 3*u*u*t*(x1 + d) + 3*u*t*t*(x2 - d) + t*t*t*x2
    local cy = u*u*u*y1 + 3*u*u*t*y1 + 3*u*t*t*y2 + t*t*t*y2
    if not V:node_at(cx, cy) and not V:socket_at(cx, cy) then mx, my = cx, cy; break end
  end
  check(mx ~= nil, "a point on the wire off the nodes (" .. x1 .. "," .. y1 .. " -> " .. x2 .. "," .. y2 .. ")")
  if mx then
    V:on_mouse_moved(mx, my, 0, 0); wait()
    local nl = 0; for _ in pairs(V.hl and V.hl.links or {}) do nl = nl + 1 end
    check(nl >= 1 and V.hl.socks[pr.ins[pi]] and V.hl.socks[loc.outs[1]], "hovering the wire: it and both its pins")
  end
  V:on_mouse_moved(V.position.x + 5, V.position.y + V.size.y - 5, 0, 0); wait()
  -- snap: drag b (header out) to 12 px off print's pin
  local head = titled("local function f")
  local bi; for k, o in ipairs(head.outs) do if o.decl and o.decl.name == "b" then bi = k end end
  local bx, by = V:socket_xy(head, "out", bi, ox, oy)
  drag(bx, by, x2 + 12, y2 + 9); wait()
  check(txt():find("print(b)", 1, true), "dropped 12 px off the pin: it snapped, print(b)")
  check(undo_all(orig), "undo restores")
  wait()
  -- the if's condition dragged to the background: values that give a boolean
  local ifn = titled("if"); ox, oy = V:origin()
  local cx, cy = V:socket_xy(ifn, "in", 1, ox, oy)
  local ex, ey = cx - 60, cy + 160
  while V:node_at(ex, ey) do ey = ey + 30 end
  drag(cx, cy, ex, ey); wait()
  local texts = {}
  for _, it in ipairs(V.menu and V.menu.items or {}) do texts[#texts + 1] = it.text end
  local all = table.concat(texts, ",")
  check(V.menu and all:find("Comparison", 1, true) and all:find("Not", 1, true) and not all:find("Math expression", 1, true), "a condition: booleans (Comparison, Not), no Math expression: " .. all)
  check(menu_pick("Comparison"), "pick Comparison"); wait()
  check(txt():find("  if 1 < 2 then\n", 1, true), "it's wired in: if 1 < 2 then: " .. tostring(V.note and V.note.text))
  check(undo_all(orig), "undo restores")
end)

test("remove an input pin: a local's value, an argument, a concat operand, a return value; concat has pins", function()
  local orig = open("local function f()\n  local a, b = 1, 2\n  print(a, b)\n  local s = \"x\" .. \"y\" .. \"z\"\n  return 1, s\nend\nreturn f\n")
  core.set_active_view(V)
  local cc = titled("concat (..)")
  check(cc and #cc.ins == 4 and cc.ins[4].action and cc.ins[1].lit == "string" and cc.outs[1] and cc.outs[1].name == "result", "concat: a pin per operand (3 strings), a result out")
  -- via the menu: RMB on b's row of the set local
  V.zoom = 1; wait()
  local loc = find(function(n) return n.kind == "local" and n.ins[2] and n.ins[2].name == "b" end)
  V.pan.x, V.pan.y = V.size.x / 3 - loc.x, V.size.y / 3 - loc.y; wait()
  loc = find(function(n) return n.kind == "local" and n.ins[2] and n.ins[2].name == "b" end)
  local ox, oy = V:origin()
  local rx, ry = ox + (loc.x + 40) * V.zoom, oy + (loc.y + loc.ins[2].y) * V.zoom
  V:on_mouse_pressed("right", rx, ry, 1); V:on_mouse_released("right", rx, ry); wait()
  check(menu_pick("Remove b (its read becomes nil)"), "RMB on b: Remove b (its read becomes nil)"); wait()
  check(txt():find("  local a = 1\n  print(a, nil)\n", 1, true), "b and 2 gone; its read reads nil: " .. txt())
  local pr = titled("call print")
  check(V:removable(pr, #pr.ins) ~= nil, "an argument can go")
  V:remove_pin(pr, #pr.ins); wait()
  check(txt():find("  print(a)\n", 1, true), "print(a)")
  cc = titled("concat (..)")
  check(V:removable(cc, 1) == nil and V:removable(cc, 2) == nil and V:removable(cc, 3), "concat: a and b stay, c can go")
  V:remove_pin(cc, 3); wait()
  check(txt():find('local s = "x" .. "y"\n', 1, true), "the third operand gone: \"x\" .. \"y\"")
  cc = titled("concat (..)")
  local add = cc.ins[#cc.ins]
  check(add.action == "addcat" and add.name == "+ add string", "concat: a + add string row")
  ox, oy = V:origin()
  click(ox + (cc.x + 30) * V.zoom, oy + (cc.y + add.y) * V.zoom); wait()
  check(txt():find('local s = "x" .. "y" .. ""\n', 1, true), "+ add string: .. \"\": " .. txt())
  cc = titled("concat (..)")
  check(#cc.ins == 4 and cc.ins[3].name == "c", "three pins and the + row")
  local ret = find(function(n) return n.title == "return" and n.ret_fn end)
  V:remove_pin(ret, 1); wait()
  check(txt():find("  return s\nend", 1, true), "return s")
  check(V:removable(find(function(n) return n.kind == "local" and n.ins[1] and n.ins[1].name == "a" end), 1) == nil, "a lone local's value can't go (delete the node)")
  check(undo_all(orig), "undo restores")
end)

test("remove a local's pin read elsewhere (pong's banner): the menu says how many reads go nil", function()
  local orig = open(io.open("games/pong.lua"):read("a"))
  local loc = find(function(n) return n.kind == "local" and n.ins[1] and n.ins[1].name == "score" and n.ins[2] and n.ins[2].name == "rules" end)
  check(loc and V:removable(loc, 1) == "Remove score (its 12 reads become nil)", "score: " .. tostring(loc and V:removable(loc, 1)))
  check(loc and V:removable(loc, 2) == "Remove rules (its read becomes nil)", "rules: " .. tostring(loc and V:removable(loc, 2)))
  check(undo_all(orig), "undo restores")
end)

test("alt+click a table field's function: it floats, the field reads nil", function()
  local orig = open("local cfg = {\n  name = \"p\",\n  on_hit = function(who) print(\"hit\", who) end,\n}\nprint(cfg)\n")
  local tn = find(function(n) for _, p in ipairs(n.ins) do if p.name == "on_hit" then return true end end end)
  local pin
  for i, p in ipairs(tn and tn.ins or {}) do if p.name == "on_hit" then pin = i end end
  check(pin, "the table has an on_hit pin")
  V:disconnect_socket({ node = tn, side = "in", i = pin, sock = tn.ins[pin] }); wait()
  check(txt():find("on_hit = nil,", 1, true) and txt():find("%-%-%[=*%[@float.-function%(who%) print%(\"hit\", who%) end"), "on_hit = nil, the function floats: " .. txt())
  check(undo_all(orig), "undo restores")
end)

test("repeat and until delete together; a label deletes alone (its goto shows an error)", function()
  local orig = open("local t = 3\nrepeat\n  t = t - 1\nuntil t <= 0\nlocal count = 0\n::again::\ncount = count + 1\nif count < 3 then goto again end\nprint(count)\n")
  local rep, unt = titled("repeat"), titled("until")
  V:delete_nodes({ rep }); wait()
  check(txt() == orig and (note() or ""):find("go together"), "repeat alone refuses")
  V:delete_nodes({ titled("until") }); wait()
  check(txt() == orig, "until alone refuses")
  V:delete_nodes({ titled("repeat"), titled("until") }); wait()
  check(not txt():find("repeat") and not txt():find("until"), "both selected: they go (the body floats): " .. txt())
  check(undo_all(orig), "undo restores")
  wait(); V:delete_nodes({ titled("::again::") }); wait()
  local bare = txt():gsub("%-%-@[^\n]*\n", ""):gsub("%-%-%[%[@[^%]]*%]%] ", "")
  check(bare:find("local count = 0\ncount = count + 1\nif count < 3 then goto again end\nprint(count)", 1, true), "only the label goes, the rest stays in the flow (where they were drawn): " .. bare)
  local gt = titled("goto again")
  check(gt and gt.diags and gt.diags[1] and gt.diags[1].msg:find("no visible label"), "the goto shows its label is gone")
  check(undo_all(orig), "undo restores")
end)

test("Add menu: Label, Goto <label>, Set > set x / new local", function()
  local orig = open("local count = 0\n::again::\ncount = count + 1\nprint(count)\n")
  local items = V:add_menu(-400, 400)
  local flow, set
  for _, it in ipairs(items) do if it.text == "Flow" then flow = it.sub elseif it.text == "Set" then set = it.sub end end
  local ft, st = {}, {}
  for _, it in ipairs(flow or {}) do ft[#ft + 1] = it.text end
  for _, it in ipairs(set or {}) do st[#st + 1] = it.text end
  check(table.concat(ft, ","):find("Label", 1, true) and table.concat(ft, ","):find("Goto again", 1, true), "Flow: Label, Goto again: " .. table.concat(ft, ","))
  check(st[1] == "new local" and table.concat(st, ","):find("set count", 1, true), "Set: new local, set count: " .. table.concat(st, ","))
  for _, it in ipairs(set) do if it.text == "set count" then it.fn() end end; wait()
  check(txt():find("count = nil", 1, true), "set count floats: count = nil: " .. txt())
  check(undo_all(orig), "undo restores"); wait()
  items = V:add_menu(-400, 400)
  for _, it in ipairs(items) do if it.text == "Flow" then for _, f in ipairs(it.sub) do if f.text == "Label" then f.fn() end end end end; wait()
  check(txt():find("::label::", 1, true), "a label floats: " .. txt())
  check(undo_all(orig), "undo restores")
end)

test("copy a typed local: its ---@type comes along, the pasted table is a Paddle", function()
  local orig = open("---@class Paddle\n---@field speed number\n---@field alive boolean\n\n---@type Paddle\nlocal paddle = { speed = 3 }\nprint(paddle)\n")
  local loc = find(function(n) return n.kind == "local" and n.ins[1] and n.ins[1].name == "paddle" end)
  V:select({ loc })
  check(V:copy_selection(), "copied")
  check(system.get_clipboard():find("^%-%-%-@type Paddle\nlocal paddle"), "the clipboard has ---@type: " .. system.get_clipboard())
  V:paste(-300, 600); wait()
  local tables = 0
  for _, n in ipairs(V.g.nodes) do if n.title == "Paddle" then tables = tables + 1 end end
  check(tables == 2, "two Paddle table nodes: " .. tables)
  local rows = {}
  for _, n in ipairs(V.g.nodes) do if n.title == "Paddle" then
    local t = {}; for _, p in ipairs(n.ins) do t[#t + 1] = p.name end; rows[#rows + 1] = table.concat(t, ",") end end
  check(rows[1] == rows[2] and rows[1]:find("alive", 1, true), "the copy has the same rows (+ alive): " .. table.concat(rows, " | "))
  check(undo_all(orig), "undo restores")
end)

test("for each (ipairs): an empty pin to wire (no table made), no error while it floats; deleting ipairs keeps the loop", function()
  local orig = open("local x = 1\nprint(x)\n")
  local function add_foreach()
    for _, it in ipairs(V:add_menu(-300, 500)) do if it.text == "Flow" then for _, f in ipairs(it.sub) do if f.text == "For each (ipairs)" then f.fn() end end end end; wait()
  end
  add_foreach()
  check(txt():find("for i, value in ipairs(nil) do", 1, true) and not find(function(n) return n.table end), "ipairs(nil): no table node")
  local ip = titled("ipairs")
  check(ip and #(ip.diags or {}) == 0, "floating: no red error on it")
  check(undo_all(orig), "undo restores"); wait()
  add_foreach()
  V:delete_nodes({ titled("ipairs") }); wait()
  check(txt():find("for i, value in nil do", 1, true), "delete ipairs: the loop stays: " .. txt())
  check(undo_all(orig), "undo restores")
end)

test("ctrl+a, Delete on the playground: no error, the file still parses", function()
  local orig = open(io.open("plugins/nodegraph/tests/playground.lua"):read("a"))
  local all = {}
  for _, n in ipairs(V.g.nodes) do all[#all + 1] = n end
  local ok, err = pcall(V.delete_nodes, V, all); wait()
  check(ok, "no error: " .. tostring(err))
  check(require("plugins.nodegraph.luaparse").parse(txt()), "it parses: " .. txt())
  check(not txt():gsub("%-%-[^\n]*", ""):match("%S"), "only comments are left: " .. txt())
  check(undo_all(orig), "undo restores")
end)

test("delete a function's header: the whole function goes; a call statement of it reads ;(nil)", function()
  local orig = open("---@param a number\nlocal function move(a)\n  print(a)\nend\nlocal x = 1\nmove(x)\nreturn x\n")
  V:delete_nodes({ titled("local function move") }); wait()
  check(txt():match("^local x = 1\n;%(nil%)%(x%)\nreturn x"), "the function and its ---@param gone, move(x) -> ;(nil)(x): " .. txt())
  check(undo_all(orig), "undo restores")
end)

test("a floating lambda wired back into a table field's pin (its fn out, its header, its frame)", function()
  local orig = open("local cfg = {\n  name = \"p\",\n  on_hit = function(who) print(\"hit\", who) end,\n}\nprint(cfg)\n")
  local function fpin() local tn = find(function(n) for _, p in ipairs(n.ins) do if p.name == "on_hit" then return true end end end)
    for i, p in ipairs(tn.ins) do if p.name == "on_hit" then return tn, i end end end
  local function head() return find(function(n) return n.kind == "function" and n.edit and n.edit.kind == "float" end) end
  local function cut() local tn, pin = fpin(); V:disconnect_socket({ node = tn, side = "in", i = pin, sock = tn.ins[pin] }); wait() end
  local back = "on_hit = function%(who%) print%(\"hit\", who%) end,"
  V.zoom = 1
  for _, where in ipairs({ "fn", "who", "header", "frame" }) do
    cut()
    local tn, pin = fpin()
    local h = head()
    local ox, oy = V:origin()
    local ax, ay = V:socket_xy(tn, "in", pin, ox, oy)
    local bx, by
    if where == "fn" or where == "who" then
      for i, o in ipairs(h.outs) do if (where == "fn") == (o.value == true) then bx, by = V:socket_xy(h, "out", i, ox, oy) end end
    elseif where == "header" then bx, by = ox + (h.x + h.w / 2) * V.zoom, oy + (h.y + h.h - 4) * V.zoom
    else bx, by = ox + (h.frame.x + h.frame.w - 6) * V.zoom, oy + (h.frame.y + h.frame.h - 6) * V.zoom end
    drag(ax, ay, bx, by); wait()
    check(txt():find(back), "dropped on its " .. where .. ": wired back: " .. tostring(note()))
    check(undo_all(orig), "undo restores"); wait()
  end
end)

test("copy the playground's paddle: the set local, or its Paddle table alone (--[[@as Paddle]])", function()
  local orig = open(io.open("plugins/nodegraph/tests/playground.lua"):read("a"))
  local function rows()
    local out = {}
    for _, n in ipairs(V.g.nodes) do if n.title == "Paddle" then
      local t = {}; for _, p in ipairs(n.ins) do t[#t + 1] = p.name end; out[#out + 1] = table.concat(t, ",") end end
    return out
  end
  local loc = find(function(n) return n.kind == "local" and n.ins[1] and n.ins[1].name == "paddle" end)
  V:select({ loc }); V:copy_selection()
  V:paste(-600, 300); wait()
  local r = rows()
  check(#r == 2 and r[1] == r[2] and r[1]:find("+ alive", 1, true), "set local copied: 2 Paddles with + alive: " .. table.concat(r, " | "))
  check(undo_all(orig), "undo restores"); wait()
  V:select({ find(function(n) return n.title == "Paddle" end) }); V:copy_selection()
  check(system.get_clipboard():find("%-%-%[%[@as Paddle%]%]$"), "the table alone: --[[@as Paddle]]: " .. system.get_clipboard())
  V:paste(-600, 300); wait()
  r = rows()
  check(#r == 2 and r[1] == r[2], "the table copied: 2 Paddles: " .. table.concat(r, " | "))
  check(undo_all(orig), "undo restores")
end)

test("set: the title doesn't edit; a pin's name edits what's set, its box the value", function()
  local orig = open("local p = { speed = 1, mode = 2 }\np.speed = 3\nprint(p)\n")
  V.zoom = 1; wait()
  local n = titled("set")
  V:begin_edit(n, "title")
  check(not V.editing and (note() or ""):find("on its pin"), "title: a hint, no edit")
  local ox, oy = V:origin()
  local y = oy + (n.y + n.ins[1].y) * V.zoom
  check(V:row_at(n, y, ox + (n.x + 10 * SCALE + 2) * V.zoom) == "var1", "the pin's name: var1")
  check(V:row_at(n, y, ox + (n.x + n.w - 8) * V.zoom) == "slot1", "the value box: slot1")
  V:begin_edit(n, "var1"); V.editing.text = "p.mode"; V:commit_edit(); wait()
  check(txt():find("\np.mode = 3\n", 1, true), "retargeted: p.mode = 3: " .. txt())
  n = titled("set")
  V:begin_edit(n, "slot1"); V.editing.text = "4"; V:commit_edit(); wait()
  check(txt():find("\np.mode = 4\n", 1, true), "the value: p.mode = 4")
  check(undo_all(orig), "undo restores")
end)

test("RMB: colours come first; a comment box takes a colour too", function()
  local orig = open("--@comment dx=-20 dy=-60 w=300 h=200 title=box\nlocal a = 1\nprint(a)\n")
  V.zoom = 1; wait()
  local n = titled("call print")
  local ox, oy = V:origin()
  V:context_menu(ox + (n.x + n.w / 2) * V.zoom, oy + (n.y + n.h - 4) * V.zoom)
  check(V.menu and V.menu.items[2] and V.menu.items[2].swatches, "a node's menu: the colours right under its title")
  V.menu = nil
  local nt = V.g.notes[1]
  local hx, hy = ox + (nt.x + 20) * V.zoom, oy + (nt.y + 6) * V.zoom
  V:context_menu(hx, hy)
  local sw = V.menu and V.menu.items[2]
  check(sw and sw.swatches, "a comment's menu: colours too")
  if sw then sw.fn(sw.swatches[3]) end; V.menu = nil; wait()
  check(txt():find("^%-%-@comment [^\n]*color=#"), "the comment has a colour: " .. txt())
  V:set_note_color(V.g.notes[1], nil); wait()
  check(txt():find("^%-%-@comment dx=%-20 dy=%-60 w=300 h=200 title=box\n"), "and none again: " .. txt())
  check(undo_all(orig), "undo restores")
end)

test("add a comment around the selection: the box wraps it", function()
  for _, src in ipairs({ io.open("plugins/nodegraph/tests/playground.lua"):read("a"), "local a = 1\nlocal function f(x)\n  print(x)\n  return x\nend\nprint(a)\n" }) do
    local orig = open(src)
    for _, pick in ipairs({ "call print", "return", "Counter:bump", "new local" }) do
      local function get() return titled(pick) or find(function(m) return m.title:find(pick, 1, true) end) end
      local n = get()
      if n then
        local nx, ny, nw, nh = n.x, n.y, n.w, n.h
        V:add_comment({ n }); wait()
        local nt
        for _, m in ipairs(V.g.notes) do if m.title == "Comment" then nt = m end end
        n = get()
        check(nt and nt.x <= n.x and nt.y <= n.y and nt.x + nt.w >= n.x + n.w and nt.y + nt.h >= n.y + n.h, "the box wraps " .. pick)
        check(undo_all(orig), "undo restores"); wait()
      end
    end
    local a, b = titled("return"), find(function(m) return m.kind == "local" end)   -- (in a function and outside it)
    V:add_comment({ a, b }); wait()
    local nt
    for _, m in ipairs(V.g.notes) do if m.title == "Comment" then nt = m end end
    a, b = titled("return"), find(function(m) return m.kind == "local" end)
    check(nt and nt.x <= math.min(a.x, b.x) and nt.y <= math.min(a.y, b.y) and nt.x + nt.w >= math.max(a.x + a.w, b.x + b.w)
          and nt.y + nt.h >= math.max(a.y + a.h, b.y + b.h), "the box wraps nodes of two functions")
    check(undo_all(orig), "undo restores"); wait()
  end
end)

test("resize a comment box: its corner, an edge (the left one moves it too)", function()
  local orig = open("--@comment dx=-20 dy=-60 w=300 h=200 title=box\nlocal a = 1\nprint(a)\n")
  V.zoom = 1; wait()
  local nt = V.g.notes[1]
  local ox, oy = V:origin()
  local cx, cy = ox + (nt.x + nt.w) - 3, oy + (nt.y + nt.h) - 3
  check(select(2, V:note_edge_at(cx, cy)) == "rb", "the corner grip")
  drag(cx, cy, cx + 100, cy + 40); wait()
  check(txt():find("^%-%-@comment dx=%-20 dy=%-60 w=400 h=240 title=box\n"), "corner: w=400 h=240: " .. txt())
  nt = V.g.notes[1]; ox, oy = V:origin()
  local lx, ly = ox + nt.x + 1, oy + nt.y + nt.h / 2
  check(select(2, V:note_edge_at(lx, ly)) == "l", "the left edge")
  drag(lx, ly, lx - 50, ly); wait()
  check(txt():find("^%-%-@comment dx=%-70 dy=%-60 w=450 h=240 title=box\n"), "left edge: dx=-70 w=450: " .. txt())
  nt = V.g.notes[1]; ox, oy = V:origin()
  local bx, by = ox + nt.x + nt.w / 2, oy + nt.y + nt.h - 2
  drag(bx, by, bx, by - 500); wait()
  check(txt():find("^%-%-@comment dx=%-70 dy=%-60 w=450 h=50 title=box\n"), "never smaller than 80 x 50: " .. txt())
  check(undo_all(orig), "undo restores")
end)

test("collapse: the chevron folds a node; a function's header folds the whole function; kept in the workspace", function()
  local orig = open("local a, b = 1, 2\nlocal function add(x, y)\n  local s = x + y\n  return s\nend\nprint(add(a, b))\n")
  V.zoom = 1; wait()
  local loc = titled("new local")
  local h0 = loc.h
  local ox, oy = V:origin()
  local cx, cy = ox + (loc.x + 12) * V.zoom, oy + (loc.y + loc.head_h / 2) * V.zoom
  check(V:chevron_at(cx, cy) == loc, "the chevron, left of the title")
  click(cx, cy); wait()
  loc = titled("new local")
  check(loc.collapsed and loc.h == loc.head_h and loc.h < h0, "folded: its header only")
  check(txt() == orig, "the text doesn't change")
  local st = V:get_state()
  check(st.collapsed and #st.collapsed == 1, "the workspace keeps it: " .. tostring(st.collapsed and st.collapsed[1]))
  local W = require("plugins.nodegraph.class")(st)   -- (a tab restored from the workspace)
  check(W.collapsed[st.collapsed[1]], "restored from the workspace state")
  ox, oy = V:origin()
  click(ox + (loc.x + 12) * V.zoom, oy + (loc.y + loc.head_h / 2) * V.zoom); wait()
  check(not titled("new local").collapsed and not V:get_state().collapsed, "unfolded again")
  -- the function
  local head = find(function(n) return n.kind == "function" end)
  local fw, fh = head.frame.w, head.frame.h
  V:toggle_collapse(head); wait()
  head = find(function(n) return n.kind == "function" end)
  local inner = find(function(n) return n.title == "return" end)
  check(head.collapsed and head.frame.w < fw and head.frame.h < fh, "its frame shrinks to the header")
  check(inner.hidden and inner.proxy == head, "the nodes inside are hidden")
  ox, oy = V:origin()
  check(V:node_at(ox + (inner.x + 5) * V.zoom, oy + (inner.y + 5) * V.zoom) ~= inner, "and can't be clicked")
  local x1, y1 = V:socket_xy(inner, "in", 1, ox, oy)
  check(x1 == ox + head.x * V.zoom, "wires to them end on the header")
  -- an edit elsewhere keeps it folded
  V:begin_edit(titled("new local"), "slot1"); V.editing.text = "5"; V:commit_edit(); wait()
  head = find(function(n) return n.kind == "function" end)
  check(head.collapsed, "still folded after an edit")
  check(undo_all(orig), "undo restores")
  V.collapsed = {}; V:rebuild()
end)

test("go to definition: a local function's call, a get, a method, a module's function (another tab); go back", function()
  local orig = open("local ecs = require(\"ecs\")\nlocal Counter = { n = 0 }\nfunction Counter:bump(by) self.n = self.n + by end\nlocal function add(x, y)\n  return x + y\nend\nprint(add(1, 2))\nCounter:bump(2)\n--@expr slot=1 get=add\nprint(add)\nlocal w = ecs.world()\n")
  V.zoom = 1; wait()
  local call = titled("call add") or titled("add")
  local t = V:definition_of(call)
  check(t and t.node and t.node.title:find("local function add", 1, true), "call add -> local function add: " .. tostring(t and t.node and t.node.title))
  V:goto_definition(call); wait(10)
  check(V.selected and V.selected.title:find("add", 1, true) and #V.back == 1, "it glides there and selects it")
  V:go_back(); wait(10)
  check(#V.back == 0, "go back")
  local gn = find(function(n) return n.getter == "add" end)
  t = gn and V:definition_of(gn)
  check(t and t.node and t.node.title:find("local function add", 1, true), "get add -> its function")
  t = V:definition_of(titled("call Counter:bump"))
  check(t and t.node and t.node.title:find("Counter:bump", 1, true), "Counter:bump -> its function")
  local wc = titled("ecs.world")
  t = wc and V:definition_of(wc)
  check(t and t.file and t.file:find("ecs.lua", 1, true) and t.line > 1, "ecs.world -> runtime/ecs.lua: " .. tostring(t and t.file) .. ":" .. tostring(t and t.line))
  local me = V
  V:goto_definition(wc); wait(10)
  local other = core.active_view
  check(other ~= me and other.doc and other.doc.filename:find("ecs.lua", 1, true), "its graph opens in a tab")
  check(other.selected and other.selected.line and math.abs(other.selected.line - t.line) <= 1, "on that function: " .. tostring(other.selected and other.selected.title))
  other:go_back(); wait()
  check(core.active_view == me, "go back: this tab again")
  local nd = core.root_view.root_node:get_node_for_view(other)
  if nd then nd:set_active_view(other); nd:close_active_view(core.root_view.root_node) end
  core.set_active_view(me)
  check(undo_all(orig), "undo restores")
end)

test("collapse to function: params in, assigned and later-read names out; refused when control leaves", function()
  local orig = open("local function f(a, b)\n  local total = 0\n  local s = a + b\n  total = total + s\n  print(s)\n  return total, s\nend\nreturn f\n")
  local function stmt(title, nth)
    local k = 0
    for _, n in ipairs(V.g.nodes) do if n.title == title and n.edit and n.edit.kind == "node" then k = k + 1; if k == (nth or 1) then return n end end end
  end
  local n1 = find(function(n) return n.kind == "local" and n.ins[1] and n.ins[1].name == "s" end)
  local n2, n3 = stmt("set"), stmt("call print")
  V:collapse_to_function({ n1, n2, n3 }); wait()
  check(txt():find("  local function new_function%(a, b, total%)\n    local s = a %+ b\n    total = total %+ s\n    print%(s%)\n    return total, s\n  end\n  local s\n  total, s = new_function%(a, b, total%)\n  return total, s\n"),
        "the function, then its call: " .. txt())
  check(load(txt()) ~= nil, "it loads")
  local f = load(txt())()
  local t, s = f(2, 3)
  check(t == 5 and s == 5, "and runs the same: " .. tostring(t) .. ", " .. tostring(s))
  check(V.selected and V.selected.title == "local function new_function", "its header is selected")
  check(undo_all(orig), "undo restores"); wait()
  -- one statement, nothing out
  V:collapse_to_function({ stmt("call print") }); wait()
  check(txt():find("  local function new_function%(s%)\n    print%(s%)\n  end\n  new_function%(s%)\n"), "print(s) alone: new_function(s): " .. txt())
  check(undo_all(orig), "undo restores"); wait()
  -- a gap, a return
  V:collapse_to_function({ n1 and find(function(n) return n.kind == "local" and n.ins[1] and n.ins[1].name == "s" end), stmt("call print") }); wait()
  check(txt() == orig and (note() or ""):find("follow one another"), "a gap: refused")
  V:collapse_to_function({ stmt("call print"), stmt("return") }); wait()
  check(txt() == orig and (note() or ""):find("a return"), "a return: refused")
  check(undo_all(orig), "undo restores")
end)

test("tabs move between panes: drag one onto another pane, or near its edge (a new pane)", function()
  local rv = core.root_view
  local orig = open("local a = 1\nprint(a)\n")
  local Node = require "core.node"
  local na = rv.root_node:get_node_for_view(V)
  local DocView = require "core.docview"
  local d1 = DocView(core.open_doc(V.doc.filename))
  na:add_view(d1)
  na:split("right", DocView(core.open_doc(V.doc.filename)))
  wait()
  local nb = rv.root_node:get_node_for_view(d1) == na and nil
  local function node_of(v) return rv.root_node:get_node_for_view(v) end
  local right
  for _, v in ipairs(rv.root_node:get_children()) do if node_of(v) ~= node_of(V) and getmetatable(v) == DocView then right = v end end
  local rn = node_of(right)
  check(rn and rn ~= node_of(V), "two panes")
  -- drag V's tab onto the right pane's middle
  local an = node_of(V)
  local idx = an:get_view_idx(V)
  local tx, ty, tw, th = an:get_tab_rect(idx)
  local mx, my = rn.position.x + rn.size.x / 2, rn.position.y + rn.size.y / 2
  rv:on_mouse_pressed("left", tx + tw / 2, ty + th / 2, 1)
  rv:on_mouse_moved(mx, my, mx - tx, my - ty)
  check(rv.tab_drag and rv.tab_drag.moved, "dragging the tab")
  rv:on_mouse_released("left", mx, my); wait()
  check(node_of(V) == rn and an:get_view_idx(V) == nil, "it moved to the other pane")
  -- and near that pane's right edge: a new pane
  rn = node_of(V)
  idx = rn:get_view_idx(V)
  tx, ty, tw, th = rn:get_tab_rect(idx)
  mx, my = rn.position.x + rn.size.x - 5, rn.position.y + rn.size.y / 2
  rv:on_mouse_pressed("left", tx + tw / 2, ty + th / 2, 1)
  rv:on_mouse_moved(mx, my, 1, 1)
  rv:on_mouse_released("left", mx, my); wait()
  local nn = node_of(V)
  check(nn and #nn.views == 1 and nn.position.x > rn.position.x - 1, "near the edge: a pane of its own, on the right")
  core.set_active_view(V)
  check(undo_all(orig), "undo restores")
end)

test("RMB menu order: palette, the common ones shortest first, the node's own, a separator, Delete", function()
  local orig = open("local function f(a)\n  print(a)\nend\nf(1)\n")
  V.zoom = 1; wait()
  local n = titled("call print")
  local ox, oy = V:origin()
  V:context_menu(ox + (n.x + n.w / 2) * V.zoom, oy + (n.y + 8) * V.zoom)
  local t = {}
  for _, it in ipairs(V.menu.items) do t[#t + 1] = it.swatches and "Palette" or it.sep and "---" or it.header and "#" or it.text end
  V.menu = nil
  check(table.concat(t, ",") == "#,Palette,Minimize,Add comment,Go to definition,Show source code,Collapse to function,Add breakpoint,---,Delete", table.concat(t, ","))
  check(undo_all(orig), "undo restores")
end)

test("a graph tab behind another isn't built until it's shown", function()
  local orig = open("local a = 1\nprint(a)\n")
  local NG = require("plugins.nodegraph.class")
  local node = core.root_view.root_node:get_node_for_view(V)
  local hidden = NG(core.open_doc("games/pong.lua"))
  node:add_view(hidden)                            -- (added: it's the active one now)
  node:set_active_view(V); core.set_active_view(V)
  wait(5)
  check(hidden.g == nil, "behind V: not built")
  node:set_active_view(hidden); core.set_active_view(hidden)
  wait(3)
  check(hidden.g ~= nil and #hidden.g.nodes > 100, "shown: built")
  node:set_active_view(hidden); node:close_active_view(core.root_view.root_node)
  node = core.root_view.root_node:get_node_for_view(V)
  if node then node:set_active_view(V) end
  core.set_active_view(V)
  check(undo_all(orig), "undo restores")
end)

test("pin references: a toggle per variable, each its own colour; kept across an edit, a background click, the workspace", function()
  local orig = open("local n = 1\nn = n + 1\nprint(n)\nlocal m = 2\nprint(m)\n")
  V.zoom = 1; wait()
  V:unpin_all()
  local function decl_of(name) local nd = find(function(x) return x.kind == "local" and x.outs[1] and x.outs[1].decl and x.outs[1].decl.name == name end); return nd, nd.outs[1].decl end
  local nd, d = decl_of("n")
  local ox, oy = V:origin()
  check(V:decl_at(nd, ox + (nd.x + 20) * V.zoom, oy + (nd.y + nd.ins[1].y) * V.zoom) == d, "the variable under the mouse")
  V:toggle_pin(d); wait()
  local p = V.pins[1]
  check(p and p.nodes[titled("new local")] == "decl" and p.nodes[titled("set")] == "write", "n: decl, write")
  local prints = 0
  for x, k in pairs(p.nodes) do if x.title == "call print" and k == "read" then prints = prints + 1 end end
  check(prints == 1, "one print reads n (not the one of m)")
  check((note() or ""):find("pinned n: 2 reads, 1 write", 1, true), "the count")
  local _, dm = decl_of("m")
  V:toggle_pin(dm); wait()
  check(#V.pins == 2 and V.pins[1].color ~= V.pins[2].color, "m too, another colour")
  V:begin_edit(decl_of("m"), "slot1"); V.editing.text = "3"; V:commit_edit(); wait()
  check(#V.pins == 2 and V.pins[1].decl and V.pins[1].decl.name == "n", "kept across an edit")
  ox, oy = V:origin()
  click(ox - 200, oy - 200); wait()
  check(#V.pins == 2, "a click on the background keeps them")
  local st = V:get_state()
  check(st.pins and #st.pins == 2 and st.pins[1].name == "n" and st.pins[1].color, "kept in the workspace state")
  local W = require("plugins.nodegraph.class")(st)
  check(#W.pins == 2 and W.pins[2].name == "m", "restored from it")
  V:toggle_pin(select(2, decl_of("n"))); wait()
  check(#V.pins == 1 and V.pins[1].name == "m", "unpinned n")
  V:unpin_all()
  check(undo_all(orig), "undo restores")
end)

test("warnings (amber, in the title's tip) and doc tooltips on calls", function()
  open(table.concat({
    "--- Adds two numbers.",
    "---@param a number",
    "---@param b number",
    "---@return number",
    "local function add(a, b) return a + b end",
    "local unused = 1",
    "local x = 1",
    "do",
    "  local x = 2",
    "  print(x)",
    "end",
    "for i = 1, 3 do",
    "  break",
    "  print(\"never\")",
    "end",
    "local r = add(\"one\", 2)",
    "print(r, x)",
    "dd.line(0, 0, 1, 1)",
    "" }, "\n"))
  local function warns(pred)
    local out = {}
    for _, n in ipairs(V.g.nodes) do if n.warns and pred(n) then for _, w in ipairs(n.warns) do out[#out + 1] = w end end end
    return table.concat(out, " | ")
  end
  check(V.g.warnings == 4, "4 warnings (" .. tostring(V.g.warnings) .. ")")
  local rows = 0
  for _, n in ipairs(V.g.nodes) do for _, d in ipairs(n.diags) do if d.level == "warning" then rows = rows + 1 end end end
  check(rows == 4 and (V.g.errors or 0) == 0, "each one a row under its node (not counted as errors): " .. rows)
  check(warns(function() return true end):find("unused local 'unused'", 1, true), "an unused local")
  check(warns(function() return true end):find("'x' hides the local of line 7", 1, true), "a hidden local")
  check(warns(function() return true end):find("unreachable (after break)", 1, true), "a statement after break")
  check(warns(function() return true end):find("'a': number expected, got string", 1, true), "an argument of the wrong type")
  local call = find(function(n) return n.doc and n.doc.sig:find("^add%(") end)
  check(call and call.doc.sig == "add(a: number, b: number) -> number" and call.doc.lines[1] == "Adds two numbers.", "doc of a local function: " .. tostring(call and call.doc.sig))
  local dl = find(function(n) return n.doc and n.doc.sig:find("^dd%.line") end)
  check(dl and dl.doc.sig:find("x1: number", 1, true), "doc of an API call (runtime/meta): " .. tostring(dl and dl.doc.sig))
  local x, y = xy(call, 30, call.head_h / 2)
  V:on_mouse_moved(x, y, 0, 0); wait()
  check(V.hover_head == call, "hovering its title: its tip")
  local x2, y2 = xy(call, 30, call.head_h + 8)
  V:on_mouse_moved(x2, y2, 0, 0); wait()
  check(V.hover_head ~= call, "below the title: no tip")
  core.redraw = true; wait()
  local wh
  for _, h in ipairs(V.status_hits or {}) do if h.kind == "warning" then wh = h end end
  check(wh, "the warning count is a link")
  if wh then
    click(wh.x + 4, wh.y + wh.h / 2); wait()
    local s1, t1 = V.selected, note() or ""
    check(s1 and s1.warns and t1:find("^warning 1/4"), "a click: the first one, selected (" .. t1 .. ")")
    core.redraw = true; wait()
    for _, h in ipairs(V.status_hits or {}) do if h.kind == "warning" then wh = h end end
    click(wh.x + 4, wh.y + wh.h / 2); wait()
    local s2, t2 = V.selected, note() or ""
    check(s2 and s2 ~= s1 and s2.warns and t2:find("^warning 2/4"), "again: the next one (" .. t2 .. ")")
  end
end)

test("comment boxes fold: a click on the chevron; its nodes hidden, wires on its headline", function()
  local orig = open("local function f(a)\n  local x = 1\n  local y = x + 2\n  return y\nend\nreturn f\n")
  local a = find(function(n) return n.kind == "local" and n.ins[1].name == "x" end)
  V:select({ a }); V:add_comment(V:selection()); wait()
  check(#V.g.notes == 1, "a comment box")
  local text0 = txt()
  local nt = V.g.notes[1]
  local hit
  for _, h in ipairs(V.note_hits or {}) do if h.note == nt then hit = h end end
  check(hit, "drawn, with a hit box")
  click(hit.x + 6 * SCALE, hit.y + hit.h / 2); wait()
  nt = V.g.notes[1]
  local x = find(function(n) return n.kind == "local" and n.ins[1].name == "x" end)
  check(nt.collapsed and x.hidden and x.proxy == nt, "folded: the node inside is hidden, on the box")
  check(nt.h < (nt.full_h or 0), "the box is its headline")
  check(txt() == text0, "no text change (view state)")
  check((function() for _, k in ipairs(V:get_state().collapsed or {}) do if k == nt.key then return true end end end)(), "kept in the workspace state")
  local items = {}
  local bx, by = hit.x + hit.w / 2, hit.y + hit.h / 2
  V:context_menu(bx, by)
  check(menu_texts and (function() for _, t in ipairs(menu_texts("")) do if t == "Expand" then return true end end end)(), "RMB: Expand")
  V.menu = nil
  V:toggle_collapse(nt); wait()
  nt = V.g.notes[1]
  x = find(function(n) return n.kind == "local" and n.ins[1].name == "x" end)
  check(not nt.collapsed and not x.hidden, "unfolded")
  check(undo_all(orig), "undo restores")
end)

test("split a table pin into fields (and merge it back)", function()
  local orig = open("local pos = { x = 1, y = 2 }\nlocal function f(p) return p.x + p.y end\nprint(f(pos))\nprint(f({ x = 3, y = 4 }))\n")
  local function call_f(k)
    local i = 0
    return find(function(n) if n.title == "f" then i = i + 1; return i == k end end)
  end
  local function pin(n, nm) for _, p in ipairs(n and n.ins or {}) do if p.name == nm then return p end end end
  local n = call_f(1)
  check(pin(n, "p") and V:split_fields_of(n, pin(n, "p")), "f(pos): its pin can split (pos's fields)")
  V:split_pin(n, pin(n, "p")); wait()
  check(txt():find("print(f({ x = pos.x, y = pos.y }))", 1, true), "written as a table of pos's fields")
  check(txt():find("--@expr slot=1.2 split=1\nprint(f(", 1, true), "split in the text (every view shows it): " .. (txt():match("%-%-@expr[^\n]*") or "no tag"))
  n = call_f(1)
  check(pin(n, "p.x") and pin(n, "p.y") and pin(n, "p.x").split_of and not pin(n, "p"), "a pin per field on the node")
  local tables = 0
  for _, m in ipairs(V.g.nodes) do if m.table and m.slot and m.slot.name == "p" then tables = tables + 1 end end
  check(tables == 1, "no table node for it (only the other call's): " .. tables)
  V:merge_pin(n, pin(n, "p.x")); wait()
  check(txt():find("print(f(pos))", 1, true) and not txt():find("split=", 1, true), "merged: pos again, the tag gone")
  local m = call_f(2)
  check(pin(m, "p") and V:split_fields_of(m, pin(m, "p")) == "here", "f({ x = 3, y = 4 }): splits as it is")
  V:split_pin(m, pin(m, "p")); wait()
  m = call_f(2)
  check(pin(m, "p.x") and pin(m, "p.x").text == "3" and pin(m, "p.y").text == "4", "its literals on the pins")
  check(txt():find("split=1", 1, true), "its tag in the text")
  V:merge_pin(m, pin(m, "p.x")); wait()
  check(txt():find("f({ x = 3, y = 4 })", 1, true) and pin(call_f(2), "p") ~= nil and not txt():find("split=", 1, true), "merged: the table stays (its own values)")
  check(undo_all(orig), "undo restores")
end)

test("autoconversion on wiring: a number into a string parameter -> tostring(n)", function()
  local orig = open(table.concat({
    "---@param s string",
    "local function say(s) print(s) end",
    "---@param x number",
    "local function twice(x) return x * 2 end",
    "local n = 5",
    "local name = \"ten\"",
    "local ok = true",
    "say(\"hi\")",
    "print(twice(1))",
    "" }, "\n"))
  local function node_titled(t) return find(function(m) return m.title == t end) end
  local function pin(m, nm) for _, p in ipairs(m and m.ins or {}) do if p.name == nm then return p end end end
  local function decl(nm) for _, d in ipairs(V.res.decls) do if d.name == nm then return d end end end
  local say = node_titled("call say")
  check(say and pin(say, "s") and pin(say, "s").want_type == "string", "say's s wants a string")
  V:rewire(pin(say, "s"), decl("n")); wait()
  check(txt():find("say(tostring(n))", 1, true), "n (a number) -> tostring(n): " .. (txt():match("say%b()") or "?"))
  check((note() or ""):find("converted", 1, true), "it says so")
  local tw = node_titled("twice")
  V:rewire(pin(tw, "x"), decl("name")); wait()
  check(txt():find("twice(tonumber(name))", 1, true), "name (a string) -> tonumber(name)")
  tw = node_titled("twice")
  V:rewire(pin(tw, "x"), decl("n")); wait()
  check(txt():find("twice(n)", 1, true), "n (a number) into a number: as it is")
  check(undo_all(orig), "undo restores")
end)

test("breakpoints: graph menu, the code's gutter, a dot each", function()
  local B = require "plugins.nodegraph.breaks"
  open("local a = 1\nprint(a)\nprint(a + 1)\n")
  local n = find(function(m) return m.title == "call print" end)
  local ox, oy = V:origin()
  V:context_menu(ox + (n.x + 20) * V.zoom, oy + (n.y + 4) * V.zoom)
  local has = false
  for _, t in ipairs(menu_texts("")) do if t == "Add breakpoint" then has = true end end
  check(has, "RMB on a statement: Add breakpoint")
  V.menu = nil
  B.set(V.doc.filename, n.line, true)
  check(B.has(V.doc.filename, n.line) and V:get_state().breaks[1] == n.line, "set, kept in the graph's workspace state")
  core.redraw = true; wait()
  local bh
  for _, h in ipairs(V.status_hits or {}) do if h.kind == "breakpoint" then bh = h end end
  check(bh, "a '1 breakpoint' link top-left")
  if bh then click(bh.x + 4, bh.y + bh.h / 2); wait() end
  check(V.selected == n and (note() or ""):find("^breakpoint 1/1"), "a click: its node")
  V:flash("can't wire it there: x is not visible")
  check(V.note.err, "a refusal: shown top-left in red")
  V:flash("wired: a = 1")
  check(not V.note.err, "a confirmation: the bottom line")
  local DocView = require "core.docview"
  local dv = DocView(V.doc)
  dv.position.x, dv.position.y, dv.size.x, dv.size.y = 0, 0, 600, 400
  local _, ly = dv:get_line_screen_position(3)
  dv:on_mouse_pressed("left", dv.position.x + 3, ly + 2, 1)
  check(B.has(V.doc.filename, 3), "a click in the code's gutter: line 3")
  dv:on_mouse_pressed("left", dv.position.x + 3, ly + 2, 1)
  check(not B.has(V.doc.filename, 3), "again: off")
  B.set(V.doc.filename, n.line, false)
  check(#B.lines(V.doc.filename) == 0, "none left")
end)

test("split a table's outputs: a field each, wired reads (and a nested one)", function()
  local orig = open(table.concat({
    "local p = { speed = 3, color = { r = 1, g = 2, b = 3 } }",
    "print(p.speed)",
    "print(p.color.r)",
    "local q = 0",
    "" }, "\n"))
  local function tbl() return find(function(m) return m.table and m.split_base and m.split_base.text == "p" end) end
  local t = tbl()
  check(t and not t.split_outs, "the table assigned to p: can split")
  local ox, oy = V:origin()
  local sx, sy = V:socket_xy(t, "out", 1, ox, oy)
  V:context_menu(sx, sy)
  local has = false
  for _, tx in ipairs(menu_texts("")) do if tx == "Split p" then has = true end end
  check(has, "RMB on its result pin: Split p (its node's menu)")
  V.menu = nil
  V:split_outputs(t); wait()
  check(txt():find("--@expr slot=1 outs=1\nlocal p", 1, true), "its tag: " .. (txt():match("%-%-@expr[^\n]*") or "none"))
  t = tbl()
  local function out(m, nm) for k, o in ipairs(m and m.outs or {}) do if o.name == nm then return o, k end end end
  check(out(t, "result") and out(t, "speed") and out(t, "color") and out(t, "speed").field_path == "p.speed", "result + an output per field")
  local sp = out(t, "speed")
  local inrow
  for _, q in ipairs(t.ins) do if q.name == "speed" then inrow = q.y end end
  check(sp.y == inrow, "on its field's row")
  local linked = false
  for _, l in ipairs(V.g.links) do if l.field == "p.speed" and V.by_id[l.from] == t then linked = true end end
  check(linked, "print(p.speed) is wired from it")
  -- wire speed into q's value: local q = p.speed
  local qn = find(function(m) return m.kind == "local" and m.ins[1] and m.ins[1].name == "q" end)
  local _, k = out(t, "speed")
  V:connect({ node = t, side = "out", i = k, sock = t.outs[k] }, { node = qn, side = "in", i = 1, sock = qn.ins[1] }); wait()
  check(txt():find("local q = p.speed", 1, true), "wired from it: reads p.speed")
  t = tbl()
  V:split_outputs(t, "color"); wait()
  t = tbl()
  check(out(t, "color.r") and out(t, "color.r").field_path == "p.color.r", "the colour split too: color.r")
  check(txt():find("outs=1,color", 1, true), "in its tag")
  V:merge_outputs(t); wait()
  check(not txt():find("outs=", 1, true) and not tbl().split_outs, "merged: one result again")
  check(undo_all(orig), "undo restores")
end)

test("a table not assigned yet splits into outputs (assigned first); library values are values", function()
  local orig = open("print(1)\n")
  local ox, oy = V:origin()
  V:context_menu(ox + 400, oy + 250)
  menu_pick("Values>Table"); wait()
  local t = find(function(m) return m.table end)
  check(t and not t.split_base, "a floating table: not assigned")
  V:split_outputs(t); wait()
  check(txt():find("--@expr slot=1 outs=1\nlocal tbl = { value = 0 }", 1, true), "assigned in place, split: " .. (txt():gsub("\n", " / ")))
  t = find(function(m) return m.table end)
  check(t and t.split_outs and t.outs[2] and t.outs[2].field_path == "tbl.value", "its outputs: tbl.value")
  open("print({ a = 1 })\n")
  t = find(function(m) return m.table end)
  V:split_outputs(t); wait()
  check(txt():find("--@expr slot=1 outs=1\nlocal tbl = { a = 1 }\nprint(tbl)", 1, true), "fed into a pin: a local above, the pin reads it: " .. (txt():gsub("\n", " / ")))
  open("print(1)\n")
  V:context_menu(ox + 400, oy + 250)
  menu_pick("Library>base>tostring(v)"); wait()
  local ts = find(function(m) return m.title == "tostring" end)
  check(ts and not ts.xin and ts.outs[1] and ts.outs[1].vtype == "string", "tostring(v): a value (its string result), not a statement: " .. (txt():gsub("\n", " / ")))
  check(undo_all(orig), "undo restores")
end)

-- from scratch: an empty file, everything added from the menu (so it starts
-- out floating, like any new code), wired, and each feature used on it. (The
-- tests above mostly start from code that's already wired.)
local function add(path, gx, gy)                   -- RMB on the background at graph (gx, gy) > path
  local ox, oy = V:origin()
  V:context_menu(ox + gx * V.zoom, oy + gy * V.zoom)
  local ok = menu_pick(path)
  wait()
  return ok
end
local function pin(m, nm) for i, p in ipairs(m and m.ins or {}) do if p.name == nm then return p, i end end end
local function wire(a, ai, b, bi)                  -- a value: out ai of a -> in bi of b
  V:connect({ node = a, side = "out", i = ai, sock = a.outs[ai] }, { node = b, side = "in", i = bi, sock = b.ins[bi] }); wait()
end
local function flow(a, b)                          -- the flow: a's first out -> b's in
  V:connect({ node = a, side = "out", i = 1, sock = a.xouts[1], exec = true }, { node = b, side = "in", i = 1, sock = b.xin, exec = true }); wait()
end
local function start() return find(function(m) return m.kind == "start" end) end
local function T1(t) return find(function(m) return m.title == t end) end
local function oneline() return (txt():gsub("\n", " / ")) end

test("scratch: a local into print, then the flow: real code", function()
  open("")
  add("Set>new local", 100, 100); add("Library>base>print(...)", 100, 400)
  local loc, pr = find(function(m) return m.kind == "local" end), T1("call print")
  wire(loc, 1, pr, 1)
  check(txt():find("print(value)", 1, true), "a floating local wired into a floating print: " .. oneline())
  local drawn = false
  for _, l in ipairs(V.g.links) do if V.by_id[l.from].kind == "local" and V.by_id[l.to].title == "call print" then drawn = l.pending end end
  check(drawn, "and the wire stays drawn (two floating blocks: pending, dashed)")
  flow(start(), find(function(m) return m.kind == "local" end))
  flow(find(function(m) return m.kind == "local" end), T1("call print"))
  check(txt():match("^local value = 0\nprint%(value%)\n?$"), "the flow wired: real code: " .. oneline())
end)

test("scratch: autoconversion from the library (a number into string.rep's s)", function()
  open("")
  add("Values>Math expression", 100, 100); add("Library>string>string.rep(s, n)", 100, 400)
  local ex, rep = T1("expression"), T1("string.rep") or T1("call string.rep")
  local _, si = pin(rep, "s")
  check(rep and si and rep.ins[si].want_type == "string", "string.rep's s wants a string (its stub's ---@param)")
  wire(ex, 1, rep, si)
  check(txt():find("string.rep(tostring(1 + 2 * 3)", 1, true), "converted: " .. oneline())
  rep = T1("string.rep") or T1("call string.rep")
  check(rep and rep.outs[1] and rep.outs[1].vtype == "string", "its result is a string (---@return)")
end)

test("scratch: a table from the menu: split its outputs, wire one into print", function()
  open("")
  add("Values>Table", 100, 100); add("Library>base>print(...)", 400, 400)
  V:split_outputs(find(function(m) return m.table end)); wait()
  local t = find(function(m) return m.table end)
  check(t and t.split_outs and t.outs[2] and t.outs[2].field_path == "tbl.value", "assigned, split: " .. oneline())
  wire(t, 2, T1("call print"), 1)
  check(txt():find("print(tbl.value)", 1, true), "print reads tbl.value: " .. oneline())
end)

test("scratch: a table wired into print, its pin split into fields", function()
  open("")
  add("Values>Table", 100, 100); add("Library>base>print(...)", 400, 400)
  wire(find(function(m) return m.table end), 1, T1("call print"), 1)
  check(txt():find("print({ value = 0 })", 1, true), "wired in: " .. oneline())
  local pr = T1("call print")
  local p1 = pr and pr.ins[1]
  check(p1 and V:split_fields_of(pr, p1) == "here", "its pin can split")
  if p1 then V:split_pin(pr, p1); wait() end
  pr = T1("call print")
  check(pr and pin(pr, "....value"), "split: a pin per field: " .. oneline() .. " | " .. tostring(V.note and V.note.text))
end)

test("scratch: a new function: rename it, call it from the menu, go to its definition", function()
  open("")
  add("Variables>Function", 100, 100)
  local h = find(function(m) return m.kind == "function" end)
  V:begin_edit(h, "title")
  if V.editing then V.editing.text = V.editing.text:gsub("func", "jump"); V:commit_edit(); wait() end
  check(txt():find("local function jump()", 1, true), "renamed while floating: " .. oneline())
  local ox, oy = V:origin()
  V:context_menu(ox + 100, oy + 500)
  local has = false
  for _, tx in ipairs(menu_texts("Functions")) do if tx:find("^call jump%(") then has = true end end
  check(has, "Functions > call jump()")
  V.menu = nil
  add("Functions>call jump()", 100, 500)
  local c = T1("call jump")
  check(c, "a call of it, floating: " .. oneline())
  check(c and V:definition_of(c), "go to definition: its function")
end)

test("scratch: library values are values; a floating node: comment, minimize, move, delete", function()
  open("")
  add("Library>base>tostring(v)", 100, 100)
  local ts = T1("tostring")
  check(ts and not ts.xin and ts.outs[1].vtype == "string", "tostring: a value with a string result")
  V:select({ ts }); V:add_comment(V:selection()); wait()
  check(#V.g.notes == 1, "a comment around it: " .. oneline())
  ts = T1("tostring")
  V:toggle_collapse(ts); wait()
  check(T1("tostring").collapsed, "minimized")
  V:toggle_collapse(T1("tostring")); wait()
  ts = T1("tostring")
  local x, y = xy(ts, 20, 6)
  drag(x, y, x + 60, y + 40); wait()
  check(txt():find("dx=1", 1, true) or txt():find("dx=", 1, true), "moved")
  V:delete_node(T1("tostring")); wait()
  check(not T1("tostring"), "deleted: " .. oneline())
end)

test("scratch: once wired into the flow: warnings and breakpoints", function()
  open("")
  add("Set>new local", 100, 100)
  local loc = find(function(m) return m.kind == "local" end)
  check(loc and not loc.warns, "floating: no warnings (it doesn't run)")
  local ox, oy = V:origin()
  V:context_menu(ox + (loc.x + 20) * V.zoom, oy + (loc.y + 5) * V.zoom)
  local has = false
  for _, tx in ipairs(menu_texts("")) do if tx == "Add breakpoint" then has = true end end
  check(not has, "floating: no breakpoint (it doesn't run)")
  V.menu = nil
  flow(start(), find(function(m) return m.kind == "local" end))
  loc = find(function(m) return m.kind == "local" end)
  check(loc and loc.warns and loc.warns[1]:find("unused local 'value'", 1, true), "wired: unused local 'value'")
  V:context_menu(ox + (loc.x + 20) * V.zoom, oy + (loc.y + 5) * V.zoom)
  has = false
  for _, tx in ipairs(menu_texts("")) do if tx == "Add breakpoint" then has = true end end
  check(has, "wired: Add breakpoint")
  V.menu = nil
end)

test("scratch: pin references of a floating variable", function()
  open("")
  add("Set>new local", 100, 100); add("Library>base>print(...)", 100, 400)
  wire(find(function(m) return m.kind == "local" end), 1, T1("call print"), 1)
  local loc = find(function(m) return m.kind == "local" end)
  local d = loc.outs[1].decl
  V:toggle_pin(d); wait()
  local p = V.pins[1]
  local n = 0
  for _ in pairs(p and p.nodes or {}) do n = n + 1 end
  check(n >= 2, "its declaration and its read: " .. n)
  V:unpin_all()
end)

test("scratch: the Add menu: one Return, one Function (parameters come from + add parameter)", function()
  open("")
  local ox, oy = V:origin()
  V:context_menu(ox + 100 * V.zoom, oy + 100 * V.zoom)
  local flow = table.concat(menu_texts("Flow"), ",")
  V.menu = nil
  V:context_menu(ox + 100 * V.zoom, oy + 100 * V.zoom)
  local vars = table.concat(menu_texts("Variables"), ",")
  V.menu = nil
  check(flow:find("Return", 1, true) and not flow:find("Return a value", 1, true), "Flow: Return only: " .. flow)
  check(vars:find("Function", 1, true) and not vars:find("Function (a, b)", 1, true), "Variables: Function only: " .. vars)
end)

test("scratch: a function's parameters: + add parameter, rename, remove", function()
  open("")
  add("Variables>Function", 100, 100)
  local head = find(function(m) return m.kind == "function" end)
  local ap
  for _, p in ipairs(head and head.ins or {}) do if p.action == "addparam" then ap = p end end
  check(ap and ap.name == "+ add parameter", "its header: a + add parameter row")
  local hit                                          -- a click on it (as drawn)
  for _, h in ipairs(V.hits or {}) do if h.kind == "action" and h.pin == ap then hit = h end end
  check(hit, "drawn as a button")
  if hit then click(hit.x + hit.w / 2, hit.y + hit.h / 2); wait() end
  check(txt():find("local function func(arg1)", 1, true), "a click: one parameter: " .. oneline())
  head = find(function(m) return m.kind == "function" end)
  for _, p in ipairs(head.ins) do if p.action == "addparam" then V:add_param(p.stmt) end end; wait()
  check(txt():find("local function func(arg1, arg2)", 1, true), "again: two (in order): " .. oneline())
  head = find(function(m) return m.kind == "function" end)
  local oi
  for i, o in ipairs(head.outs) do if o.name == "arg1" then oi = i end end
  local ox, oy = V:origin()
  local sx, sy = V:socket_xy(head, "out", oi or 1, ox, oy)
  V:context_menu(sx - 20 * V.zoom, sy)             -- (on its name, left of the pin)
  local items = table.concat(menu_texts(""), ",")
  check(items:find("Rename parameter arg1", 1, true) and items:find("Remove parameter arg1", 1, true), "RMB on its name: rename / remove: " .. items)
  V.menu = nil
  V:context_menu(sx, sy)
  items = table.concat(menu_texts(""), ",")
  check(items:find("Remove parameter arg1", 1, true), "RMB on its pin too: " .. items)
  check(menu_pick("Remove parameter arg1")); wait()
  check(txt():find("local function func(arg2)", 1, true), "removed: " .. oneline())
  head = find(function(m) return m.kind == "function" end)
  for _, p in ipairs(head.ins) do if p.action == "addparam" then V:add_param(p.stmt) end end; wait()
  check(txt():find("local function func(arg2, arg3)", 1, true), "and one more after it (arg3): " .. oneline())
  open("local arg1 = 5\n")
  add("Variables>Function", 100, 300)
  head = find(function(m) return m.kind == "function" end)
  for _, p in ipairs(head.ins) do if p.action == "addparam" then V:add_param(p.stmt) end end; wait()
  check(txt():find("local function func(arg1)", 1, true), "a variable elsewhere named arg1 doesn't matter: " .. oneline())
end)

test("removing a parameter: refused while used; its calls lose that argument", function()
  local orig = open("local function f(a, b, ...)\n  return b\nend\nprint(f(1, 2, 3))\nlocal g = function(x) end\ng(5)\n")
  local fr
  for _, F in ipairs(V.g.frames) do if F.func and F.func.params[1] == "a" then fr = F end end
  V:remove_param(fr.func, 2); wait()
  check(V.note and V.note.text:find("uses it", 1, true) and txt():find("f(a, b, ...)", 1, true), "b is read: refused: " .. tostring(V.note and V.note.text))
  V:remove_param(fr.func, 1); wait()
  check(txt():find("local function f(b, ...)", 1, true) and txt():find("print(f(2, 3))", 1, true), "a removed, and f(1, 2, 3) -> f(2, 3): " .. oneline())
  for _, F in ipairs(V.g.frames) do if F.func and F.func.params[1] == "x" then fr = F end end
  V:remove_param(fr.func, 1); wait()
  check(txt():find("local g = function() end\ng()", 1, true), "a lambda in a local too: " .. oneline())
  for _, F in ipairs(V.g.frames) do if F.func and F.func.params[1] == "b" then fr = F end end
  local head = fr.head
  for _, p in ipairs(head.ins) do if p.action == "addparam" then V:add_param(p.stmt) end end; wait()
  check(txt():find("local function f(b, arg1, ...)", 1, true), "added before the ...: " .. oneline())
  check(undo_all(orig), "undo restores")
end)

test("a variable's wire dropped on the background: its members, there", function()
  local orig = open('local ecs = require "ecs"\nlocal cfg = { speed = 1, go = function(a) end }\nprint(cfg.extra)\n')
  local function out_of(name)
    for _, n in ipairs(V.g.nodes) do
      for i, o in ipairs(n.outs) do if o.decl and o.decl.name == name then return n, i end end
    end
  end
  local n, i = out_of("ecs")
  local ox, oy = V:origin()
  local x, y = ox + (n.x + n.w + 300) * V.zoom, oy + (n.y + 200) * V.zoom
  V:connect({ node = n, side = "out", i = i, sock = n.outs[i] }, nil, nil, x, y)
  local items = V.menu and table.concat(menu_texts(""), ",") or ""
  check(items:find("Members of ecs", 1, true) and items:find("ecs.world()", 1, true) and items:find("ecs.match(pattern, path)", 1, true),
        "a menu of ecs's functions: " .. items)
  check(menu_pick("ecs.world()"), "pick"); wait()
  check(txt():find("(ecs.world())", 1, true), "picked: a floating ecs.world() (its value): " .. oneline())
  local fl = find(function(m) return m.floating and m.title and m.title:find("world") end)
  check(fl and math.abs(fl.x - (n.x + n.w + 300)) < 80, "where it was dropped")
  n, i = out_of("cfg")
  V:connect({ node = n, side = "out", i = i, sock = n.outs[i] }, nil, nil, x, y + 200)
  items = V.menu and table.concat(menu_texts(""), ",") or ""
  check(items:find("cfg.speed", 1, true) and items:find("cfg.go(a)", 1, true) and items:find("cfg.extra", 1, true),
        "a table's fields, its functions, what the file reads from it: " .. items)
  V.menu = nil
  check(undo_all(orig), "undo restores")
end)

test("scratch: get ecs (a floating getter): its wire dropped on the background lists ecs's members", function()
  open('local ecs = require "ecs"\n')
  add("Get>get ecs", 100, 300)
  local gn = find(function(m) return m.floating and m.outs[1] and m.outs[1].name == "ecs" and m.kind == "expr" end)
  check(gn, "a get ecs node")
  if not gn then return end
  local ox, oy = V:origin()
  V:connect({ node = gn, side = "out", i = 1, sock = gn.outs[1] }, nil, nil, ox + (gn.x + 400) * V.zoom, oy + gn.y * V.zoom)
  local items = V.menu and table.concat(menu_texts(""), ",") or ""
  check(items:find("Members of ecs", 1, true) and items:find("ecs.world()", 1, true), "its members: " .. items)
  check(menu_pick("ecs.world()"), "pick"); wait()
  check(txt():find("(ecs.world())", 1, true), "picked: " .. oneline())
end)

test("a breakpoint on code that runs at load: when it stops is said (Play / Rewind)", function()
  open("local x = 1\nlocal function f()\n  print(x)\nend\nreturn f\n")
  local B = require "plugins.nodegraph.breaks"
  local top, inner = V:line_node(1), V:line_node(3)
  check(top and V.at_load(top) and inner and not V.at_load(inner), "line 1 runs at load, line 3 in a function")
  V.selected = top
  V:context_menu(xy(top))
  check(menu_pick("Add breakpoint")); wait()
  check(V.note and V.note.text:find("when its file loads", 1, true) and V.note.text:find("Play", 1, true), "said: " .. tostring(V.note and V.note.text))
  check(not V:wont_stop(top), "not hollow: it stops")
  B.set(V.doc.filename, 1, false)
end)

test("a click on a breakpoint's dot removes it (like the text's gutter)", function()
  open("local a = 1\nprint(a)\n")
  local B = require "plugins.nodegraph.breaks"
  B.set(V.doc.filename, 2, true); wait()
  local hit
  for _, h in ipairs(V.hits or {}) do if h.kind == "breakpoint" and h.line == 2 then hit = h end end
  check(hit, "its dot is drawn (and clickable)")
  if hit then click(hit.x + hit.w / 2, hit.y + hit.h / 2); wait() end
  check(not B.has(V.doc.filename, 2), "a click: removed")
  B.set(V.doc.filename, 2, false)
end)

test("scratch: changes since opened: a list, a diff against one, [x] back", function()
  open("print(1)\n")
  add("Set>new local", 100, 300)                     -- change 1: a node added
  local loc = find(function(m) return m.kind == "local" end)
  check(loc, "a local added")
  local pr = T1("call print")
  local p1 = pr and pr.ins[1]
  if p1 then V:set_literal(p1.pos, p1.epos, "2"); wait() end   -- change 2: print(1) -> print(2)
  check(txt():find("print(2)", 1, true), "print(2): " .. oneline())
  local pn = T1("call print")                         -- change 3: print dragged
  if pn then local hx, hy = xy(pn); drag(hx, hy, hx + 60, hy + 40); wait() end
  check(txt():find("dx=", 1, true), "dragged: an offset tag: " .. oneline())
  check(#(V.history or {}) >= 4, "kept: as opened + 3 changes (" .. #(V.history or {}) .. ")")
  local link
  for _, h in ipairs(V.status_hits or {}) do if h.kind == "changes" then link = h end end
  check(link and V:n_changes() >= 3, "a 'N changes' link top-right: " .. tostring(V:n_changes()))
  if link then click(link.x + 2, link.y + link.h / 2); wait() end
  check(V.changes, "a click on it: the list")
  if link then click(link.x + 2, link.y + link.h / 2); wait() end
  check(not V.changes, "again: closed")
  V:context_menu(V.position.x + V.size.x - 40, V.position.y + V.size.y - 40)
  local has
  for _, t in ipairs(menu_texts("")) do if t:find("^Changes since opened") then has = t end end
  V.menu = nil
  check(not has, "not in the RMB menu (the link is enough)")
  local NG = require "plugins.nodegraph.view"     -- the tab closed and opened again: the same list (per document)
  local v2 = NG(V.doc)
  v2:rebuild()
  check(v2:n_changes() == V:n_changes() and v2:n_changes() >= 3, "another graph tab of it: " .. v2:n_changes() .. " changes too")
  if link then click(link.x + 2, link.y + link.h / 2); wait() end
  check(V.changes, "the list is open")
  local x, y, w, rh, rows = 0, 0, 0, 0, {}
  local hit                                          -- the oldest row: as opened
  for yy = V.position.y, V.position.y + V.size.y, 4 do
    for xx = V.position.x + V.size.x - 300, V.position.x + V.size.x - 20, 40 do
      if V:changes_at(xx, yy) == 1 then hit = { xx, yy } end
    end
  end
  check(hit, "a row for the state as opened")
  if hit then click(hit[1], hit[2]); wait() end
  local d = V.diff
  check(d and d.n_add >= 1 and d.n_chg >= 1, "diff vs as opened: added " .. tostring(d and d.n_add) .. ", changed " .. tostring(d and d.n_chg))
  check(d and d.added[find(function(m) return m.kind == "local" end)], "the new local: added")
  check(d and d.changed[T1("call print")], "print: changed")
  check(d and #d.moved == 1 and d.moved[1].title == "call print", "print: moved (drawn where it was, at 25%)")
  local close
  for xx = V.position.x + V.size.x - 60, V.position.x + V.size.x - 10, 2 do
    for yy = V.position.y + 30, V.position.y + 70, 2 do if V:changes_at(xx, yy) == "close" then close = { xx, yy } end end
  end
  check(close, "an [x]")
  if close then click(close[1], close[2]); wait() end
  check(not V.changes and not V.diff, "[x]: the list and the diff gone (the graph as it is)")
end)

test("changes: undo takes one off the count (and the list), redo puts it back", function()
  local function pause(s)                          -- (edits closer than config.undo_merge_timeout undo as one)
    local t0 = system.get_time()
    repeat wait(1) until system.get_time() - t0 > s
  end
  open("print(1)\n")
  local pr = T1("call print")
  pause(0.4); V:set_literal(pr.ins[1].pos, pr.ins[1].epos, "2"); wait()
  pr = T1("call print")
  pause(0.4); V:set_literal(pr.ins[1].pos, pr.ins[1].epos, "3"); wait()
  check(V:n_changes() == 2, "2 changes: " .. V:n_changes())
  V.doc:undo(); wait()
  check(txt():find("print(2)", 1, true) and V:n_changes() == 1, "undo: print(2), 1 change: " .. V:n_changes())
  V.doc:undo(); wait()
  check(V:n_changes() == 0, "undo again: as opened, 0 changes: " .. V:n_changes())
  local link
  for _, h in ipairs(V.status_hits or {}) do if h.kind == "changes" then link = h end end
  check(not link, "no link at 0")
  V.doc:redo(); wait()
  check(txt():find("print(2)", 1, true) and V:n_changes() == 1, "redo: 1 change: " .. V:n_changes())
  pr = T1("call print")
  pause(0.4); V:set_literal(pr.ins[1].pos, pr.ins[1].epos, "7"); wait()
  check(V:n_changes() == 2 and #V.history == 3, "a new change after an undo: on top (the undone one dropped): " .. V:n_changes() .. ", " .. #V.history)
end)

test("changes before any graph: the list starts from the file as saved", function()
  open("print(1)\n")
  local NG = require "plugins.nodegraph.view"
  -- a document already changed when its first graph opens: a fresh one here
  local Doc = require "core.doc"
  local fresh = Doc(V.doc.filename)
  fresh:insert(1, 1, "local q = 1\n")
  local v3 = NG(fresh)
  v3:rebuild()
  check(v3:n_changes() == 1 and v3.history[1].label == "as saved", "1 change, from 'as saved': " .. v3:n_changes() .. " " .. tostring(v3.history and v3.history[1] and v3.history[1].label))
end)

test("tab flips text <-> graph", function()
  open("return 1\n")
  local node = core.root_view.root_node:get_node_for_view(V)
  local idx = node:get_view_idx(V)
  local x, y, w, h = node:get_tab_rect(idx)
  local menu = require "plugins.contextmenu"
  local function pick(text)                          -- RMB on the tab, then that item of its menu
    core.root_view:on_mouse_pressed("right", x + w / 2, y + h / 2, 1)
    local m = menu.m                                 -- (canvas.menu's: its rows)
    for i, it in ipairs(m and m.items or {}) do
      if it.text == text and i > m.scroll and i <= m.scroll + m.rows then
        local mx, my = m.x + 10, m.y + 4 * SCALE + m.top + (i - 1 - m.scroll) * m.ih + m.ih / 2
        core.root_view:on_mouse_moved(mx, my, 0, 0); core.root_view:on_mouse_pressed("left", mx, my, 1); return true
      end
    end
  end
  check(pick("Toggle graph / Lua"), "right-click on the tab: its menu, with Toggle graph / Lua")
  local back = node.views[idx]
  check(back ~= V and back.doc == V.doc, "Toggle graph / Lua shows the text")
  pick("Toggle graph / Lua")
  check(node.views[idx] == V, "and the same graph again")
  check(not menu.show_context_menu, "the menu closes after a pick")
  local style = require "core.style"
  local ix = x + style.padding.y + 3                 -- the flip icon, left of the name
  core.root_view:on_mouse_pressed("left", ix, y + h / 2, 1)
  check(node.views[idx] ~= V and node.views[idx].doc == V.doc, "a click on the tab's icon shows the text")
  core.root_view:on_mouse_pressed("left", ix, y + h / 2, 1)
  check(node.views[idx] == V, "and again the graph")
  core.root_view:on_mouse_pressed("left", x + w / 2, y + h / 2, 1)
  check(node.views[idx] == V, "a click elsewhere on the tab doesn't flip")
end)

core.add_thread(function()
  wait(2)
  for _, t in ipairs(tests) do
    if not rawget(_G, "ONLY_TEST") or t[1]:find(rawget(_G, "ONLY_TEST"), 1, true) then
    local before = fail_n
    local okk, err = pcall(t[2])
    if not okk then fail_n = fail_n + 1; say("  ERROR: " .. tostring(err)) end
    say((fail_n == before and "ok   " or "FAIL ") .. t[1])
    wait(2)
    end
  end
  say(string.format("nodegraph ui: %d checks ok, %d failed", ok_n, fail_n))
  if V then V.doc:clean() end
  local f = io.open(dir .. "/" .. stamp .. "_result.txt", "w")
  if f then f:write(table.concat(log, "\n"), "\n"); f:close() end
  if os.getenv("NG_EXIT") then os.exit(fail_n == 0 and 0 or 1) end   -- (scripted runs: quit when done)
end)

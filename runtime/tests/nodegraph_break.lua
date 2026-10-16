-- nodegraph_break.lua - breakpoints: the world stops its tick at one (paused
-- mid-frame), the graph shows that node; play continues; removed, it runs on.
--   play games/pong.lua --lite "dofile('runtime/tests/nodegraph_break.lua')@3"
--        --events "l16,494@300 l16,494@500" --frames 100000 --shot x.bmp
-- (the events: Play at frame 300 (continue) and 500 (after the breakpoint is
-- removed)). Prints a line per check; NG_EXIT exits.
local core = require "core"
local B = require "plugins.nodegraph.breaks"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local function wait_for(f, secs)
    local t0 = system.get_time()
    repeat coroutine.yield(); local r = f(); if r then return r end until system.get_time() - t0 > (secs or 20)
  end
  local v = require("plugins.nodegraph").open("games/pong.lua")
  wait_for(function() v:update(); return v.g end)
  local LINE = 0                                   -- (in a system: runs every frame: the paddles' "AI or keys")
  do local n = 0; for l in io.lines("games/pong.lua") do n = n + 1; if l:find("if not (w.players or { true })[p.player or 1] then", 1, true) then LINE = n; break end end end
  B.set(v.doc.filename, LINE, true)
  check(B.has(v.doc.filename, LINE), "set")
  local P = wait_for(function() v:update(); return v.probe and v.probe.brk == LINE and v.probe end)
  check(P, "the world stopped there (the graph's frame: brk = " .. tostring(v.probe and v.probe.brk) .. ")")
  local file, line, n1 = B.where()   -- (n1: which stop; updated after the steps)
  check(line == LINE and file and file:find("pong.lua", 1, true), "host_break_where: " .. tostring(file) .. ":" .. tostring(line))
  local node = v.selected
  check(node and node.line == LINE, "the graph glided to its node, selected")
  local st = v:get_state()
  check(st.breaks and st.breaks[1] == LINE, "kept in the workspace state")
  -- an output pin's value (the variable a node sets): read after its line
  local function out_of(line, name)
    for _, nd in ipairs(v.g.nodes) do
      if nd.line == line then for _, o in ipairs(nd.outs) do if o.decl and o.decl.name == name then return nd, o end end end
    end
  end
  local nd, o = out_of(LINE - 1, "dy")
  local val = nd and v:out_value(nd, o)
  check(val == "0", "the dy pin's value (local dy = 0, before the stop): " .. tostring(val))
  local nl, ol = out_of(LINE + 11, "lim")
  check(nl and v:out_value(nl, ol) == nil, "a pin after the stop: no value yet")
  -- stepping (F10 over, F11 into, shift+F11 out): it stops again, elsewhere
  local function step(mode)
    local _, _, before = B.where()
    host_break_step(mode)
    return wait_for(function() local f, l, n = B.where(); return n and n ~= before and { f, l, n } end, 10)
  end
  local s1 = step("over")
  check(s1 and s1[2] ~= LINE and s1[2] > LINE - 5, "F10 (over): the next line of that function: " .. tostring(s1 and s1[2]))
  local s2 = step("in")
  check(s2 and s2[2], "F11 (into): the next line anywhere: " .. tostring(s2 and s2[2]))
  local s3 = step("out")
  check(s3 and s3[2], "shift+F11 (out): stops again (a caller's line, or the next frame's first): " .. tostring(s3 and s3[2]))
  n1 = select(3, B.where())
  -- Play (frame 300): the rest of that tick runs; the next one stops there again
  local n2 = wait_for(function() local _, _, n = B.where(); return n and n ~= n1 and n end, 30)
  check(n2, "continued, and stopped there again on the next frame")
  B.set(v.doc.filename, LINE, false)
  -- Play (frame 500): it runs on
  local ran = wait_for(function() v:update(); return not B.where() and v.probe == nil end, 30)
  check(ran, "removed, play: it runs on (nothing stopped)")
  -- a line inserted above (a graph edit's --@node line): the breakpoint moves with its statement
  local doc = v.doc
  B.set(doc.filename, LINE, true)
  doc:insert(LINE, 5, "--@node dx=-8 dy=-1\n    ")
  check(B.has(doc.filename, LINE + 1) and not B.has(doc.filename, LINE), "moved down with its line (an insert above)")
  doc:undo()
  check(B.has(doc.filename, LINE) and not B.has(doc.filename, LINE + 1), "and back up (undone)")
  doc:insert(LINE, #doc.lines[LINE], "\n    local extra = 1")   -- (at the line's end: it stays)
  check(B.has(doc.filename, LINE), "a line added below it: it stays")
  doc:undo()
  B.set(doc.filename, LINE, false)
  print(string.format("nodegraph break: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

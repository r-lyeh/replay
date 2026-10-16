-- nodegraph_values.lua - values the graph works out while stopped: a call of
-- a function that only computes (math.max) shows its result, an input pin fed
-- by it shows it too, marked "not run yet" on the stop's own line; a call
-- that could change the game is never made.
--   replay games/pong.lua --lite "dofile('runtime/tests/nodegraph_values.lua')@3" --frames 100000 --shot x.bmp
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
  local LINE = 0                                   -- (the computer's paddle: runs every frame)
  do local n = 0; for l in io.lines("games/pong.lua") do n = n + 1; if l:find("dy = math.max(-step, math.min(step, d))", 1, true) then LINE = n; break end end end
  B.set(v.doc.filename, LINE, true)
  check(wait_for(function() v:update(); return v.probe and v.probe.brk == LINE end, 30), "stopped at line " .. LINE)
  local call, inner
  for _, n in ipairs(v.g.nodes) do
    if n.vexpr and n.vexpr.tag == "Call" and n.line == LINE then
      local f = n.vexpr.fn
      if f.name == "max" then call = n elseif f.name == "min" then inner = n end
    end
  end
  check(call and inner, "the math.max and math.min call nodes")
  local val, _, line, computed = v:expr_value(call)
  check(tonumber(val) ~= nil and computed and line == LINE, "math.max(...) worked out: " .. tostring(val))
  local ival = v:expr_value(inner)
  check(tonumber(ival) ~= nil, "math.min(...) too: " .. tostring(ival))
  local fed                                        -- the link from math.min into math.max's pin
  for _, l in ipairs(v.g.links) do if l.from == inner.id and l.to == call.id then fed = l end end
  local lv, lcomp
  if fed then local _x, _y, _z; lv, _x, _y, _z, lcomp = v:link_value(fed) end
  check(lv == ival and lcomp, "its wire / the pin it feeds: " .. tostring(lv))
  -- a call that could change the game is never made
  local ev = rawget(_G, "host_probe_eval")
  check(ev(v.abs_file, LINE, "math.random(1, 9)") == nil, "math.random: refused (it changes the generator)")
  check(ev(v.abs_file, LINE, "print('x')") == nil, "print: refused")
  check(ev(v.abs_file, LINE, "math.max(step, 0)") ~= nil, "math.max with locals: allowed")
  B.set(v.doc.filename, LINE, false)
  print(string.format("nodegraph values: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

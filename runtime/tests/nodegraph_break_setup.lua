-- nodegraph_break_setup.lua - a breakpoint in a system's setup (the code in
-- ecs.system(function() ... before its run function): Rewind builds the
-- systems again, the world stops there; Play continues, and it runs on (the
-- setup runs once per build).
--   play games/pong.lua --lite "dofile('runtime/tests/nodegraph_break_setup.lua')@3"
--        --events "l72,494@200 l16,494@400" --frames 100000 --shot x.bmp
-- (the events: Rewind at frame 200, Play (continue) at 400). NG_EXIT exits.
local core = require "core"
local B = require "plugins.nodegraph.breaks"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1; print("  ok: " .. m) else fail_n = fail_n + 1; print("  FAIL: " .. m) end io.stdout:flush() end
  local function wait_for(f, secs)
    local t0 = system.get_time()
    repeat coroutine.yield(); local r = f(); if r then return r end until system.get_time() - t0 > (secs or 20)
  end
  local v = require("plugins.nodegraph").open("games/pong.lua")
  wait_for(function() v:update(); return v.g end)
  local LINE                                       -- banner's setup: local function centre(...)
  local n = 0
  for l in (v.doc:get_text(1, 1, math.huge, math.huge) .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if l:find("local function centre", 1, true) then LINE = n; break end
  end
  check(LINE, "found the banner's setup line")
  local node = LINE and v:line_node(LINE)
  check(node and not v.at_load(node) and v:at_setup(node), "a system's setup (not at load): " .. tostring(node and node.title))
  B.set(v.doc.filename, LINE, true)
  -- Rewind (frame 200): the systems are built again, the setup runs: it stops
  local hit = wait_for(function() local f, l = B.where(); return l == LINE and f end, 30)
  check(hit and hit:find("pong.lua", 1, true), "stopped in the setup, at line " .. tostring(LINE) .. ": " .. tostring(select(2, B.where())))
  local P = wait_for(function() v:update(); return v.probe and v.probe.brk == LINE and v.probe end, 10)
  check(P, "the graph shows it (brk = " .. tostring(v.probe and v.probe.brk) .. ")")
  -- Play (frame 400): it continues; the setup doesn't run again: it runs on
  local ran = wait_for(function() return not B.where() end, 30)
  check(ran, "continued")
  local t0 = system.get_time()
  local again = false
  while system.get_time() - t0 < 2 do coroutine.yield(); if B.where() then again = true end end
  check(not again, "and runs on (the setup runs once per build)")
  B.set(v.doc.filename, LINE, false)
  print(string.format("nodegraph break setup: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

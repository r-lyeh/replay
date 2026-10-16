-- nodegraph_break_boot.lua - a breakpoint in the world's main script, at its
-- top level (runs when the world is built): Play / Rewind run that script
-- again first (a dry run, the boot step: probe.h), so the world stops there;
-- Play continues and the game runs on, with its world as it was.
--   play games/pong.lua --lite "dofile('runtime/tests/nodegraph_break_boot.lua')@3"
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
  local LINE
  local n = 0
  for l in (v.doc:get_text(1, 1, math.huge, math.huge) .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if l:find('w:spawn("/systems/input"', 1, true) then LINE = n; break end
  end
  check(LINE, "found the top-level line")
  local node = LINE and v:line_node(LINE)
  check(node and v.at_load(node) and v.is_root(v.doc.filename) and not v:wont_stop(node),
        "top level, but the main script: it can stop (" .. tostring(rawget(_G, "host_world_file") and host_world_file()) .. ")")
  B.set(v.doc.filename, LINE, true)
  local hit = wait_for(function() local f, l = B.where(); return l == LINE and f end, 30)
  check(hit, "Rewind: stopped at the top level, line " .. tostring(LINE) .. ": " .. tostring(select(2, B.where())))
  local P = wait_for(function() v:update(); return v.probe and v.probe.brk == LINE and v.probe end, 10)
  check(P, "the graph shows it (brk = " .. tostring(v.probe and v.probe.brk) .. ")")
  local ran = wait_for(function() return not B.where() end, 30)
  check(ran, "Play: continued")
  local t0 = system.get_time()                     -- (a multi-line call comes back to its first line:
  local again = false                              --  not a stop again; the dry run happens once)
  while system.get_time() - t0 < 3 do coroutine.yield(); if B.where() then again = true end end
  check(not again, "and the game runs on, not stopping again")
  B.set(v.doc.filename, LINE, false)
  print(string.format("nodegraph break boot: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

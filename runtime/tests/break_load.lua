-- break_load.lua - breakpoints in code that runs when its file loads: a
-- module's top level (asteroids' /data/lib/space) and a system file's (its
-- sparks system). Play builds the systems again in the next frame, as part of
-- the tick (a coroutine), and the modules they require run again with them:
-- both stop.
--   replay games/asteroids --stopped --lite "dofile(REPLAY_ROOT .. '/runtime/tests/break_load.lua')@3"
--        --events "l16,574@60" --frames 100000 --shot x.bmp
-- (the event: Play). Prints the failures and a count; NG_EXIT exits.
local core = require "core"
local B = require "plugins.nodegraph.breaks"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local function wait_for(f, secs)
    local t0 = system.get_time()
    repeat coroutine.yield(); local r = f(); if r then return r end until system.get_time() - t0 > (secs or 20)
  end
  local root = rawget(_G, "REPLAY_ROOT") or "."
  local mod = root .. "/games/asteroids/data/lib/space/module.lua"
  local sys = root .. "/games/asteroids/systems/sparks/system.lua"
  local function line_of(file, text)
    local n = 0
    for l in io.lines(file) do n = n + 1; if l:find(text, 1, true) then return n end end
  end
  local ML, SL = line_of(mod, "local space = {}"), line_of(sys, "local made = 0")
  B.set(core.open_doc(mod).filename, ML, true)
  B.set(core.open_doc(sys).filename, SL, true)
  local NG = require "plugins.nodegraph"
  local v = NG.open(sys)
  wait_for(function() v:update(); return v.g end, 10)
  local node = v.g and v:line_node(SL)
  check(node and v.at_load(node) and not v:wont_stop(node), "a system file's top level: drawn as a breakpoint that stops")
  local f1, l1 = wait_for(function() local f, l = B.where(); return l and f end, 30), select(2, B.where())
  check(f1 and f1:find("space/module.lua", 1, true) and l1 == ML, "Play: stopped in the module's top level, line " .. tostring(ML) .. ": " .. tostring(f1) .. ":" .. tostring(l1))
  local _, _, n1 = B.where()
  host_break_step("continue")
  local f2 = wait_for(function() local f, l, n = B.where(); return n and n ~= n1 and f end, 20)
  check(f2 and f2:find("sparks/system.lua", 1, true) and select(2, B.where()) == SL, "continued: stopped in the system file's top level, line " .. tostring(SL) .. ": " .. tostring(f2) .. ":" .. tostring(select(2, B.where())))
  host_break_step("continue")
  local ran = wait_for(function() return not B.where() end, 10)
  check(ran, "continued: it runs")
  local t0, again = system.get_time(), false
  while system.get_time() - t0 < 2 do coroutine.yield(); if B.where() then again = true end end
  check(not again, "and runs on: built once, not stopping again")
  B.set(core.open_doc(mod).filename, ML, false)
  B.set(core.open_doc(sys).filename, SL, false)
  print(string.format("break load: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

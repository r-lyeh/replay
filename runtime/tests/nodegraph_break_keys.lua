-- nodegraph_break_keys.lua - stopped at a breakpoint in the game view (the
-- game at 100%: lite hidden), F5 still continues (replay.c takes F5 / F10 /
-- F11 while stopped, in any view; the overlay says where it stopped).
--   play games/pong.lua --lite "dofile('runtime/tests/nodegraph_break_keys.lua')@3"
--        --events "l80,14@250 m500,300@260 k5,1@400 K5,1@405" --frames 100000 --shot x.bmp
-- (the events: paused at 100% (the opacity button), the mouse over the game,
-- F5 at frame 400). NG_EXIT exits.
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
  local n1 = wait_for(function() local _, l, n = B.where(); return l == LINE and n end, 20)
  check(n1, "stopped at " .. LINE)
  local n2 = wait_for(function() local _, _, n = B.where(); return n and n ~= n1 and n end, 30)
  check(n2, "F5 in the game view: continued (and stopped there again the next frame): " .. tostring(n1) .. " -> " .. tostring(n2))
  B.set(v.doc.filename, LINE, false)
  print(string.format("nodegraph break keys: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

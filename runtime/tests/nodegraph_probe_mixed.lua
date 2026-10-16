-- nodegraph_probe_mixed.lua - the mixed view while playing shows the flow live
-- (the 2nd toolbar button: the game's opacity over the editor, while playing):
--   play games/pong.lua --lite "dofile('runtime/tests/nodegraph_probe_mixed.lua')@3" --events "l80,14@30 l80,14@40" --frames 100000 --shot x.bmp
-- (the events: playing 100% -> 0% (editor) -> 75% (mixed)). Prints one line; NG_EXIT exits.
-- NG_EXPECT=none: the game at 100% (no events, or a 3rd click): no flow at all (after 5 s).
local core = require "core"
core.add_thread(function()
  local v = require("plugins.nodegraph").open("games/pong.lua")
  local none = os.getenv("NG_EXPECT") == "none"
  local t0 = system.get_time()
  local ran, ts = 0, {}
  repeat
    coroutine.yield(); v:update(); ran = 0
    for _, n in ipairs(v.g and v.g.nodes or {}) do if v:ran(n) then ran = ran + 1 end end
    if v.probe and v.probe.t then ts[v.probe.t] = true end
  until (ran > 10 and #(function() local k = {} for t in pairs(ts) do k[#k + 1] = t end return k end)() > 3)
        or system.get_time() - t0 > (none and 5 or 15)
  local nt = 0; for _ in pairs(ts) do nt = nt + 1 end
  local ok = none and (ran == 0 and nt == 0) or (not none and ran > 10 and nt > 3)
  print(string.format("nodegraph probe mixed: %s (nodes that ran: %d, frames seen: %d)", ok and "ok" or "FAIL", ran, nt))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

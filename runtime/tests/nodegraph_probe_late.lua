-- nodegraph_probe_late.lua - a graph opened after the game was paused still shows the flow
-- (the paused frame ran before the file was watched: the editor steps one frame):
--   play games/pong.lua --lite "dofile('runtime/tests/nodegraph_probe_late.lua')@3" --events "l16,494@60" --frames 100000 --shot x.bmp
-- (the event: Pause at frame 60). Prints one line; NG_EXIT exits.
local core = require "core"
core.add_thread(function()
  local t0 = system.get_time()
  while system.get_time() - t0 < 8 do coroutine.yield() end   -- (well after the pause)
  local v = require("plugins.nodegraph").open("games/pong.lua")
  t0 = system.get_time()
  local ran = 0
  repeat
    coroutine.yield(); v:update(); ran = 0
    for _, n in ipairs(v.g and v.g.nodes or {}) do if v:ran(n) then ran = ran + 1 end end
  until ran > 10 or system.get_time() - t0 > 10
  print(string.format("nodegraph probe late: %s (nodes that ran: %d)", ran > 10 and "ok" or "FAIL", ran))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

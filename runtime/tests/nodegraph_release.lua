-- nodegraph_release.lua - a right-press into a graph (mixed view, outside the
-- game's picture) released over the game's picture: the graph must see the
-- release (else it keeps panning with no button down):
--   play games/pong.lua --lite "dofile('runtime/tests/nodegraph_release.lua')@3"
--        --events "W520,240@20 W520,240@21 W520,240@22 W520,240@23 W520,240@24 W520,240@25 W520,240@26 W520,240@27
--                  l16,494@40 x230,100@200 m300,120@205 m520,240@210 X520,240@215" --frames 100000 --shot x.bmp
-- (the game camera zoomed out, paused (mixed), the right button pressed in a
-- corner, moved, released over the game). Prints one line; NG_EXIT exits.
local core = require "core"
core.add_thread(function()
  local v = require("plugins.nodegraph").open("games/pong.lua")
  local t0 = system.get_time()
  local pressed = false
  while system.get_time() - t0 < 20 do
    coroutine.yield()
    if v.rpress then pressed = true end
    if pressed and not v.rpress then break end
  end
  local held = v.rpress ~= nil
  local px = v.pan.x
  print(string.format("nodegraph release: %s (pressed: %s, still held: %s)", (pressed and not held) and "ok" or "FAIL", tostring(pressed), tostring(held)))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

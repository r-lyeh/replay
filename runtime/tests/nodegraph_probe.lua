-- nodegraph_probe.lua - the editor's probe into the running world (needs it playing):
--   play games/pong.lua --lite "dofile('runtime/tests/nodegraph_probe.lua')@3" --events "l16,494@240 l44,494@600" --frames 100000 --shot x.bmp
-- (the events: Pause at frame 240, Stop at frame 600)
-- Opens pong's graph, lets the game run, checks the graph got what ran (lines,
-- the flow pulse) and values on its wires. Prints a line per check; NG_EXIT exits.
local core = require "core"
core.add_thread(function()
  for _ = 1, 5 do coroutine.yield() end
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local v = require("plugins.nodegraph").open("games/pong.lua")
  local t0 = system.get_time()
  repeat coroutine.yield() ; v:update() until (v.probe and v.g) or system.get_time() - t0 > 30   -- (the game at 100%: none until the pause)
  check(rawget(_G, "host_probe") ~= nil, "host_probe is there")
  check(v.probe and v.probe.lines, "a record of the frame shown")
  local ran, valued = 0, 0
  for _, n in ipairs(v.g and v.g.nodes or {}) do if v:ran(n) then ran = ran + 1 end end
  for _, l in ipairs(v.g and v.g.links or {}) do if v:link_value(l) then valued = valued + 1 end end
  check(ran > 10, "nodes that ran: " .. ran)
  check(valued > 10, "wires with a value: " .. valued)
  local ball                                       -- the ball system's `local x, v, r = ...`: its readers have values
  for _, l in ipairs(v.g and v.g.links or {}) do
    local val, name = v:link_value(l)
    if name == "dt" and val and tonumber(val) then ball = val end
  end
  check(ball ~= nil, "dt has a number: " .. tostring(ball))
  -- paused (Play/Pause, clicked by --events at frame 240): the flow of the frame shown stays
  t0 = system.get_time()
  local t1
  repeat coroutine.yield(); v:update(); t1 = v.probe and v.probe.t; coroutine.yield(); v:update()
  until (t1 and v.probe and v.probe.t == t1 and system.get_time() - t0 > 2) or system.get_time() - t0 > 10
  check(v.probe and v.probe.t == t1, "paused: the flow of the frame shown stays (t=" .. tostring(t1) .. ")")
  local ev, sample = 0, nil                        -- wires from expression nodes: the expression's value
  for _, l in ipairs(v.g and v.g.links or {}) do
    if l.expr then local val, name = v:link_value(l); if val then ev = ev + 1; sample = sample or (name .. " = " .. val) end end
  end
  check(ev > 3, "expression wires with a value: " .. ev .. " (" .. tostring(sample) .. ")")
  -- stopped (Stop, at frame 600): no flow
  t0 = system.get_time()
  repeat coroutine.yield(); v:update() until not v.probe or system.get_time() - t0 > 30
  check(v.probe == nil, "stopped: no flow shown: " .. tostring(v.probe_src and v.probe_src:sub(1, 40)))
  print(string.format("nodegraph probe: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

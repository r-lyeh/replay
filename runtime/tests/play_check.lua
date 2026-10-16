-- play_check.lua - Play checks first that every Lua file the game reads
-- compiles. pong.lua gets a syntax error in the editor (not saved), then
-- Play: it doesn't start; the error is logged and the editor shows the
-- line (its text). Then the same with pong.lua open as a graph: Play shows
-- that line's node in the graph, the message on it. (A graph that never
-- parsed has no nodes to show: then its text, as in 1.)
--   play games/pong.lua --stopped --lite "dofile('runtime/tests/play_check.lua')@3"
--        --events "l16,494@400 l16,494@1000" --frames 100000 --shot x.bmp
-- (the events: Play at frames 400 and 1000). NG_EXIT exits.
local core = require "core"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local f = io.open("games/pong.lua", "rb"); local disk = f:read("*a"); f:close()
  local doc = core.open_doc("games/pong.lua")
  core.root_view:open_doc(doc)
  coroutine.yield(0.2)
  local bad
  for i, l in ipairs(doc.lines) do
    if l:find("local input = ecs.system(function()", 1, true) then bad = i + 1; break end
  end
  doc:insert(bad, 1, "  local oops = = 1\n")
  local function logged(text, from)
    for k = from or 1, #(core.log_items or {}) do
      if tostring(core.log_items[k].text):find(text, 1, true) then return k end
    end
  end
  local function wait(text, from)
    local t0 = system.get_time()
    repeat coroutine.yield(0.1) until logged(text, from) or system.get_time() - t0 > 20
    return logged(text, from)
  end

  -- 1. its text
  local at = wait("unexpected symbol")
  local function count(text) local n = 0 for _, it in ipairs(core.log_items or {}) do if tostring(it.text):find(text, 1, true) then n = n + 1 end end return n end
  local n0 = count("unexpected symbol")
  check(at, "Play: the compile error is logged")
  check(at and core.log_items[at].at and core.log_items[at].at:find("pong.lua:" .. bad, 1, true),
        "... with its place: pong.lua:" .. bad)
  local v = core.active_view
  check(v and v.doc == doc and v.locate == nil, "the editor shows pong.lua's text")
  check(v and v.doc == doc and select(1, doc:get_selection()) == bad, "... at that line")
  check(not logged("play: with the editor's unsaved changes"), "the game didn't start")

  -- 2. its graph (built while the file was fine: it keeps that graph)
  doc:remove(bad, 1, bad + 1, 1)
  local g = require("plugins.nodegraph").open("games/pong.lua")
  coroutine.yield(0.5)
  check(g.g ~= nil, "the graph is built")
  doc:insert(bad, 1, "  local oops = = 1\n")
  core.root_view:open_doc(core.open_doc("games/scene1.lua"))   -- (another file in front: the graph must come back by itself)
  check(core.active_view ~= g, "another tab in front")
  local t0 = system.get_time()                     -- (counted, not by index: the log keeps its last 80 lines only)
  repeat coroutine.yield(0.1) until count("unexpected symbol") > n0 or system.get_time() - t0 > 20
  local at2 = count("unexpected symbol") > n0
  check(at2, "Play again: logged again")
  v = core.active_view
  check(v == g, "the editor shows pong.lua's graph")
  check(v == g and g.note and tostring(g.note.text):find("unexpected symbol", 1, true), "... the message flashed on it")
  check(v == g and g.selected and g.selected.line and g.selected.line <= bad, "... the node of that line selected")

  f = io.open("games/pong.lua", "rb"); local now = f:read("*a"); f:close()
  check(now == disk, "the file on disk: untouched")
  doc:clean()                                      -- (nothing to save at exit)
  print(string.format("play check: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

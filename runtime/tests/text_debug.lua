-- text_debug.lua - debugging in the text (Lite's code view), stopped at a
-- breakpoint: a local's value under the mouse, the lines that ran tinted,
-- "N breakpoints" (a click: the next one).
--   replay games/pong.lua --stopped --lite "dofile('runtime/tests/text_debug.lua')@3"
--        --events "l16,494@60" --frames 100000 --shot x.bmp
-- (the event: Play). Prints a line per check; NG_EXIT exits.
local core = require "core"
local B = require "plugins.nodegraph.breaks"
local NG = require "plugins.nodegraph"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local function wait_for(f, secs)
    local t0 = system.get_time()
    repeat coroutine.yield(); local r = f(); if r then return r end until system.get_time() - t0 > (secs or 20)
  end
  local view = core.root_view:open_doc(core.open_doc("games/pong.lua"))
  local LINE, L2 = 0, 0
  do local n = 0; for l in io.lines("games/pong.lua") do n = n + 1
    if l:find("if not (w.players or { true })[p.player or 1] then", 1, true) then LINE = n end
    if l:find("local lim = rules.arena.h", 1, true) then L2 = n end end end
  B.set(view.doc.filename, LINE, true)
  B.set(view.doc.filename, L2, true)
  check(NG.bp_label(view) == "2 breakpoints", "the label: " .. tostring(NG.bp_label(view)))
  local okm, errm = pcall(view.on_mouse_moved, view, view.position.x + 100, view.position.y + 50, 0, 0)
  check(okm, "moving the mouse over the text: no error (" .. tostring(errm) .. ")")
  local _, lx0, ly0, lw0, lh0 = NG.bp_label(view)
  view:on_mouse_moved(lx0 + 2, ly0 + 2, 0, 0)
  check(view.cursor == "hand", "over the label: a hand")
  check(NG.expr_at("    if held[p.up] then", 13) == "p", "the name under a column: p")
  check(NG.expr_at("    if held[p.up] then", 15) == "p.up", "a field: p.up")
  check(NG.expr_at("    local x = 1", 6) == nil, "a keyword: nothing")
  check(NG.expr_at("  v.a.b.c = 1", 4) == "v.a" and NG.expr_at("  v.a.b.c = 1", 8) == "v.a.b.c", "on a dot: the field after it (v.a; the last dot: v.a.b.c)")
  do                                             -- "(at line N)" of a field: the last line before the stop that assigns it
    local lines = { [28] = "    local x, v = n.c.xform, n.c.vel", [31] = "    x.x, x.y = x.x + v.x * dt, x.y + v.y * dt",
                    [32] = "    if a then x.y = 0 end", [33] = "    sp.life = sp.life - dt" }
    local P = { brk = 33, lines = { [28] = { s = 1, v = {} }, [31] = { s = 2, v = {} }, [32] = { s = 3, v = {} }, [33] = { s = 4, v = {} } } }
    check(B.assigned_at(P, "x.y", 33, lines) == 31, "x.y, stopped at 33: set at line 31 (32's `if` may not run it)")
    check(B.assigned_at(P, "x.y", 31, lines) == nil, "x.y, stopped at 31: not set yet (then: where x is declared)")
  end
  local stopped = wait_for(function() local _, l = B.where(); return l == LINE end, 30)
  check(stopped, "stopped at line " .. LINE)
  local v = wait_for(function() return NG.text_value(view, LINE - 1, "dy") end, 5)
  check(v == "0", "dy's value (local dy = 0): " .. tostring(v))
  local pv = NG.text_value(view, LINE, "p.player")
  check(pv == "1" or pv == "2", "a field's value (p.player): " .. tostring(pv))
  check(NG.text_value(view, LINE, "nosuchname") == nil, "an unknown name: no tooltip")
  -- "(at line N)": the line that last set it (here: declared the line before), else where it's declared
  local FN = 0                                   -- (the paddles' run = function(w, n, dt))
  do local n = 0; for l in io.lines("games/pong.lua") do n = n + 1; if n < LINE and l:find("run = function(w, n, dt)", 1, true) then FN = n end end end
  local probe = NG.text_probe_of(view)
  check(probe and NG.set_at(probe, view.doc, LINE - 1, 11, "dy", LINE - 1) == LINE - 1, "dy: at line " .. (LINE - 1) .. " (" .. tostring(probe and NG.set_at(probe, view.doc, LINE - 1, 11, "dy", LINE - 1)) .. ")")
  local dtcol = (view.doc.lines[FN] or ""):find("dt", 1, true)
  local got = probe and dtcol and NG.set_at(probe, view.doc, FN, dtcol, "dt", LINE); check(got == FN, "dt (a parameter): where it is declared, line " .. FN .. " got " .. tostring(got) .. " col " .. tostring(dtcol))
  -- watches: added from the text's menu, shown with their value, a table unfolds
  NG.add_watch(B.abs(view.doc.filename), "p")
  NG.add_watch(B.abs(view.doc.filename), "dy")
  local rows = NG.watch_rows(view)
  check(#rows == 2 and rows[1].text:match("^%+ p = {") and rows[2].text:match("dy = 0"), "two watches: " .. tostring(rows[1] and rows[1].text) .. " | " .. tostring(rows[2] and rows[2].text))
  rows[1].wt.open = true
  rows = NG.watch_rows(view)
  local fields = {}
  for _, r in ipairs(rows) do if r.kind == "field" then fields[#fields + 1] = r.text end end
  check(#fields >= 3 and table.concat(fields, "|"):find(".player = ", 1, true), "p unfolded: " .. table.concat(fields, "|"))
  coroutine.yield(0.2)                             -- (drawn: the rows placed)
  local wr = view.watch_hits and view.watch_hits[1]
  if wr then view:on_mouse_moved(wr.x + 4, wr.y + 2, 0, 0) end
  check(wr and view.cursor == "hand", "over a watch: a hand")
  NG.remove_watch(B.abs(view.doc.filename), "p")
  check(#NG.watch_rows(view) == 1, "a watch removed")
  -- the letter under the mouse (Lite's caret column goes past a letter's middle): p.player's "l"
  do
    local t = view.doc.lines[LINE] or ""
    local c = t:find("p.player", 1, true)
    view:scroll_to_line(LINE, true, true)
    coroutine.yield(0.1)
    local sx, sy = view:get_line_screen_position(LINE)
    local font = view:get_font()
    local px = sx + font:get_width(t:sub(1, c + 2)) + font:get_width(t:sub(c + 3, c + 3)) * 0.7
    local _, cc = NG.char_at(view, px, sy + 2)
    check(c and cc == c + 3 and NG.expr_at(t, cc) == "p.player", "the letter under the mouse: " .. tostring(cc) .. " (" .. tostring(c and c + 3) .. ")")
  end
  local items = require("plugins.contextmenu").docview_extras[1]
  view.hover_x, view.hover_y = nil, nil
  check(items and items(view) == nil, "the menu: nothing without a name under the mouse")
  NG.remove_watch(B.abs(view.doc.filename), "dy")
  -- the label's click: the next breakpoint after the caret
  view.doc:set_selection(LINE, 1)
  local _, lx, ly, lw, lh = NG.bp_label(view)
  view:on_mouse_pressed("left", lx + lw / 2, ly + lh / 2, 1)
  check(view.doc:get_selection() == L2, "a click on the label: the next breakpoint (" .. L2 .. "): " .. view.doc:get_selection())
  view:on_mouse_pressed("left", lx + lw / 2, ly + lh / 2, 1)
  check(view.doc:get_selection() == LINE, "and round to the first")
  -- for the screenshot: the mouse over "dy" on the stop's line
  local text = view.doc.lines[LINE + 9] or ""
  local col = text:find("dy", 1, true)
  if col then
    view:scroll_to_line(LINE, true, true)
    coroutine.yield(0.3)
    local sx, sy = view:get_line_screen_position(LINE + 9)
    sx = sx + view:get_font():get_width(text:sub(1, col))
    view.hover_x, view.hover_y = sx, sy + 4
    core.redraw = true
  end
  print(string.format("text debug: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

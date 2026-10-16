-- textproxy.lua - Lite's editing for our text boxes (plugins/textproxy.lua):
-- the tree's filter and the bar's prompt typed through core.on_event, as
-- real keys arrive (keypressed, then its textinput). run.lua: "text boxes".
local core = require "core"
local keymap = require "core.keymap"
local ok, bad = 0, 0
local function check(c, what) if c then ok = ok + 1 else bad = bad + 1; print("FAIL: " .. what) end end
local function key(k) local r = core.on_event("keypressed", k); return r end
local function up(k) core.on_event("keyreleased", k) end
local function text(t) core.on_event("textinput", t) end
local function with(mod, k) key(mod); key(k); up(mod) end
core.add_thread(function()
  coroutine.yield(0.3)
  local TP = require "plugins.textproxy"
  local S = require "plugins.sidetab"
  local before = core.active_view
  -- the tree's filter
  S:focus_filter()
  check(TP.active and core.active_view == TP.active.view, "the filter types in lite (its view active)")
  key("h"); text("h"); text("ello world")
  check(S.filter.text == "hello world", "letters: " .. S.filter.text)
  with("left ctrl", "backspace")
  check(S.filter.text == "hello ", "CTRL+BACKSPACE: a word back: " .. S.filter.text)
  key("left shift"); key("home"); up("left shift")
  local a, b = TP.active:range()
  check(a == 1 and b == 7, "SHIFT+HOME selects to the start: " .. a .. ".." .. b)
  text("x")
  check(S.filter.text == "x", "typing replaces the selection: " .. S.filter.text)
  text("yz"); key("left"); key("left")
  key("left shift"); key("right"); up("left shift")
  with("left ctrl", "x")
  check(S.filter.text == "xz" and system.get_clipboard() == "y", "CTRL+X cuts the selection: " .. S.filter.text)
  with("left ctrl", "a"); with("left ctrl", "c")
  check(system.get_clipboard() == "xz", "CTRL+A, CTRL+C: " .. tostring(system.get_clipboard()))
  system.set_clipboard("a\nb")
  key("end"); with("left ctrl", "v")
  check(S.filter.text == "xza b", "a pasted newline: a space (one line): " .. S.filter.text)
  with("left ctrl", "z")
  check(S.filter.text ~= "xza b", "CTRL+Z undoes: " .. S.filter.text)
  local was = TP.active
  with("left ctrl", "s")
  check(TP.active == was and core.active_view == was.view, "CTRL+S does nothing to the box")
  key("return")
  check(not TP.active and not S.filter_focus, "Enter leaves the filter")
  check(core.active_view == before, "the view active before has the keyboard again")
  -- the bar's prompt (replay.c asks through lite_prompt)
  lite_prompt("focus", "w.a = 1")
  check(TP.active ~= nil, "the prompt types in lite")
  with("left ctrl", "left")
  key("left shift"); with("left ctrl", "left"); up("left shift")
  local t, cur, s1, s2 = lite_prompt("get")
  check(t == "w.a = 1" and s2 > s1, "the prompt: CTRL+SHIFT+LEFT selects a word: " .. tostring(s1) .. ".." .. tostring(s2))
  lite_prompt("set", "join(\"\")", 6)
  t, cur = lite_prompt("get")
  check(cur == 7, "the host puts the caret where it wants: " .. tostring(cur))
  lite_prompt("blur")
  check(not TP.active, "the prompt left")
  -- a right-click menu's search box
  local CMn = require "plugins.contextmenu"
  CMn:show_items(100, 100, { { text = "alpha" }, { text = "beta" }, { text = "gamma" } }, {})
  check(TP.active ~= nil and CMn.m and CMn.m.tp == TP.active, "a menu's search types in lite")
  text("alp"); with("left shift", "left")
  local x1, x2 = TP.active:range()
  check(CMn.m.search == "alp" and x2 - x1 == 1, "its search: typed, SHIFT+LEFT selects a letter")
  key("down")
  check(CMn.show_context_menu and TP.active ~= nil, "down: the menu's (it stays open, still typing)")
  key("escape")
  check(not CMn.show_context_menu and not TP.active and core.active_view == before, "escape closes it: the focus back")
  -- the colour picker's hex row (plugins/canvas/picker.lua)
  local P = require "plugins.canvas.picker"
  local got
  local pk = P.new(10, 10, { 255, 0, 0, 255 }, function(c) got = c end)
  pk:type_hex(0, 0)
  check(TP.active ~= nil and pk.typing == "#ff0000", "the hex row types in lite, the colour now in it: " .. tostring(pk.typing))
  text("zz00f"); text("f00")
  check(pk.typing == "00ff00", "typing replaces it, only what a hex holds: " .. tostring(pk.typing))
  key("return")
  check(not TP.active and got and got[2] == 255 and got[1] == 0, "Enter keeps it: the colour")
  -- a click elsewhere in lite: the box closes and hears so
  local blurred = false
  local h = TP.open("abc", { on_blur = function() blurred = true end })
  core.set_active_view(before)
  core.on_event("mousemoved", 1, 1, 0, 0)
  check(blurred and not TP.active, "focus elsewhere: the box closes (on_blur)")
  print(string.format("text boxes: %d checks ok, %d failed", ok, bad))
  os.exit(0)
end)

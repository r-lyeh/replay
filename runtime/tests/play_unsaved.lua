-- play_unsaved.lua - Play runs the game from the disk, but the editor's
-- unsaved files win (like UE): pong.lua's hint text changed in the editor,
-- not saved, then Play: the world is built from the editor's text (the log
-- says so), the file on disk is untouched.
--   play games/pong.lua --stopped --lite "dofile('runtime/tests/play_unsaved.lua')@3"
--        --events "l16,494@120" --frames 100000 --shot x.bmp
-- (the event: Play at frame 120). NG_EXIT exits.
local core = require "core"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local f = io.open("games/pong.lua", "rb"); local disk = f:read("*a"); f:close()
  local doc = core.open_doc("games/pong.lua")
  core.root_view:open_doc(doc)
  coroutine.yield(0.2)
  for i, l in ipairs(doc.lines) do
    local s, e = l:find("the computer plays until", 1, true)
    if s then doc:remove(i, s, i, e + 1); doc:insert(i, s, "UNSAVED EDIT WINS"); break end
  end
  check(doc:is_dirty(), "the editor's pong.lua: changed, not saved")
  local t0, said = system.get_time(), false
  repeat
    coroutine.yield(0.1)
    for _, it in ipairs(core.log_items or {}) do if tostring(it.text):find("unsaved changes", 1, true) then said = true end end
  until said or system.get_time() - t0 > 20
  check(said, "Play: built with the editor's unsaved changes (the log)")
  f = io.open("games/pong.lua", "rb"); local now = f:read("*a"); f:close()
  check(now == disk, "the file on disk: untouched")
  doc:clean()                                      -- (nothing to save at exit)
  print(string.format("play unsaved: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

-- sidetab_typing.lua - typing into the left tab (plugins/sidetab.lua) when a
-- key and its text arrive in the same frame, as on a real keyboard: the
-- text must not be dropped (core.step drops a text right after a key the
-- keymap took). run.lua: a click on the filter box, then "p" as a key and
-- its text together (--events k... --type "p@N", which also presses Enter).
local core = require "core"
core.add_thread(function()
  local S = require "plugins.sidetab"
  local t0 = system.get_time()
  repeat coroutine.yield() until (S.filter and S.filter.text ~= "") or system.get_time() - t0 > 6
  local got = S.filter and S.filter.text or "?"
  print(string.format("sidetab typing: %s (the filter: %q)", got == "p" and "ok" or "FAIL", got))
  os.exit(0)
end)

-- bullets_edit.lua - the bullet editor (plugins/bullets) on a copy of
-- Starfall's file: the lists, a pattern previewed, edits, renames, undo, the
-- stage played, saving.
--   replay games/pong.lua --stopped --lite "dofile(REPLAY_ROOT .. '/runtime/tests/bullets_edit.lua')@3" --frames 100000 --shot x.bmp
-- Prints the failures and a count; NG_EXIT exits. SHOW=1: stays open (a screenshot).
local core = require "core"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local root = rawget(_G, "REPLAY_ROOT") or "."
  local path = root .. "/bullets_edit_test.bullets"
  do
    local f = io.open(root .. "/games/common/starfall.bullets", "rb"); local s = f:read("*a"); f:close()
    f = io.open(path, "wb"); f:write(s); f:close()
  end
  local v = require("plugins.openwith").open("bullets", path)
  coroutine.yield(0.3)
  check(v and v.d and #v.d.patterns > 5 and #v.d.waves > 5 and v.d.boss, "the file is open: patterns, waves, a boss")
  if not (v and v.d) then print(string.format("bullets edit: %d checks ok, %d failed", ok_n, fail_n)); if os.getenv("NG_EXIT") then os.exit(0) end return end
  local B = dofile(root .. "/runtime/bullets.lua")
  check(v.sel and v.sel[1] == "pattern" and v.sel[2] == 1, "the first pattern selected")
  v:advance(1)
  check(#v.st.bullets > 0, "its preview fires: " .. #v.st.bullets)
  -- an edit: a slider's change, then undo
  local p = v.d.patterns[1]
  local before = p.count
  v:edit(function() p.count = 9 end)
  v:advance(1.2)
  check(v.d.patterns[1].count == 9 and #v.st.bullets >= 9, "count 9: nine a volley")
  v:undo_step(true)
  check(v.d.patterns[1].count == before, "undo: back to " .. tostring(before))
  -- rename a pattern: its users follow
  local i_fan
  for i, q in ipairs(v.d.patterns) do if q.name == "fan3" then i_fan = i end end
  v:select("pattern", i_fan)
  v:edit(function(d) local q = d.patterns[i_fan]; q.name = "fan_three" end)
  -- (the field's commit renames everywhere: as the panel does)
  v:undo_step(true)
  local q = v.d.patterns[i_fan]
  v:edit(function(d) local old = q.name; q.name = "fan_three"
    for _, e in ipairs(d.enemies) do if e.pattern == old then e.pattern = "fan_three" end end end)
  check(B.enemy(v.d, "gunner").pattern == "fan_three", "renamed: the gunner fires fan_three")
  -- add and duplicate
  local n0 = #v.d.patterns
  v:add("pattern", true)
  check(#v.d.patterns == n0 + 1 and v.d.patterns[n0 + 1].name == "fan_three2", "duplicated: fan_three2")
  v:remove("pattern", n0 + 1)
  check(#v.d.patterns == n0, "deleted")
  v:add("wave")
  check(#v.d.waves == 11 and v.sel[1] == "wave", "a new wave, selected")
  v:undo_step(true)
  -- the stage
  v.mode = "stage"
  v:seek(5)
  check(#v.stage.ships > 0 and #v.st.bullets > 0, "the stage at 5 s: ships and their bullets: " .. #v.stage.ships)
  v:seek(55)
  check(v.stage.boss ~= nil, "at 55 s: the boss")
  v:seek(66)
  local bb = v.stage.boss
  check(bb and bb.phase >= 2, "and it goes through its phases: " .. tostring(bb and bb.phase) .. " hp " .. tostring(bb and bb.hp) .. " y " .. tostring(bb and bb.y) .. " t " .. tostring(bb and bb.t))
  -- import another file's patterns and ships (the template: names taken get a number)
  local tpl = B.parse(io.open(root .. "/plugins/bullets/templates/stage.bullets", "rb"):read("*a"))
  local np0, ns0 = #v.d.patterns, #v.d.enemies
  v:edit(function(d) B.import(d, tpl) end)
  check(#v.d.patterns == np0 + #tpl.patterns and #v.d.enemies == ns0 + #tpl.enemies and B.enemy(v.d, "fighter2"), "imported the template's patterns and ships (fighter as fighter2)")
  v:undo_step(true)
  check(#v.d.patterns == np0, "undo: the import is gone")
  -- the play field: the preview follows it; it's saved
  v:edit(function(d) d.field = { w = 640, h = 480 } end)
  local bx, by, bw, bh = v:bounds()
  check(bw == 680 and bh == 520, "the field: 640 x 480 (the canvas around it)")
  check(v:assets_dir() and v:assets_dir():find("games/common$"), "pong.lua is a script: new files go to games/common/ (" .. tostring(v:assets_dir()) .. ")")
  -- the panels draw (each kind selected)
  for _, sel in ipairs({ { "pattern", 1 }, { "ship", 1 }, { "wave", 1 }, { "boss", 1 } }) do
    v.sel = sel
    local okd, err = pcall(v.draw, v)
    check(okd, "drawn with a " .. sel[1] .. " selected: " .. tostring(err))
  end
  -- save
  v:save()
  local f = io.open(path, "rb"); local text = f:read("*a"); f:close()
  local back = B.parse(text)
  check(back and B.pattern(back, "fan_three") and B.enemy(back, "gunner").pattern == "fan_three", "saved: read back")
  check(back and back.field and back.field.w == 640, "saved: the field too")
  check(not v.dirty, "not dirty after saving")
  if os.getenv("SHOW") then
    v.sel = { "pattern", 5 }
    v.mode = "pattern"
    v:restart()
    v:fit()
    return
  end
  os.remove(path)
  print(string.format("bullets edit: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

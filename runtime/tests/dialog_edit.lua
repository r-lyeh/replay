-- dialog_edit.lua - editing a .dialog in its chart (plugins/dialog): move
-- boxes, link lines, add answers and lines, delete, undo; all through the text.
--   replay games/pong.lua --stopped --lite "dofile('runtime/tests/dialog_edit.lua')@3" --frames 100000 --shot x.bmp
-- Prints a line per failed check, then the count; NG_EXIT exits.
local core = require "core"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local path = "dialog_edit_test.dialog"
  do
    local f = io.open("plugins/dialog/sample.dialog", "rb"); local s = f:read("*a"); f:close()
    f = io.open(path, "wb"); f:write(s); f:close()
  end
  local v = require("plugins.openwith").open("dialog", path)
  coroutine.yield(0.2)
  check(v and v.boxes and #v.boxes > 10, "the chart is open")
  if not (v and v.boxes) then print(string.format("dialog edit: %d checks ok, %d failed", ok_n, fail_n)); if os.getenv("NG_EXIT") then os.exit(0) end return end
  local function text() return v:edit_doc():get_text(1, 1, math.huge, math.huge) end
  local function row_of(n) return v.by[n] and v:get_row(v.by[n].row) end

  -- the row helpers keep comments, arrows and tags
  local t = v.row_parts("5 Do you want? [6,7] // why  //@10,-4")
  check(t.n == 5 and t.body == "Do you want?" and #t.choices == 2 and t.comment == "// why" and t.dx == 10 and t.dy == -4, "row_parts")
  t.dx, t.dy = 0, 0
  check(v.row_text(t) == "5 Do you want? [6,7]  // why", "row_text: a 0,0 tag dropped: " .. v.row_text(t))

  -- move a box by dragging it: the tag written, the others stay
  local b3 = v.by[3]
  local x0, y0, other = b3.x, b3.y, v.by[4].y
  v:on_canvas_pressed("left", b3.x + 20, b3.y + 5, 1)
  v:on_canvas_moved(b3.x + 60, b3.y + 35)
  v:on_canvas_released("left", b3.x + 60, b3.y + 35)
  check(row_of(3) == "3 Awesome! Have fun! -> 5  //@40,30", "moved: its tag: " .. tostring(row_of(3)))
  check(v.by[3].x == x0 + 40 and v.by[3].y == y0 + 30 and v.by[4].y == other, "moved: there; line 4 stays")
  check(v.dirty == true, "the chart has unsaved changes")

  -- link from a socket (the right edge) to another box
  local b11 = v.by[11]
  v:on_canvas_pressed("left", b11.x + b11.w, b11.y + b11.h / 2, 1)
  check(v.wiring and v.wiring.from == 11, "a press on the right edge: a link starts")
  local tgt = v.by[14]
  v:on_canvas_moved(tgt.x + 10, tgt.y + 5)
  v:on_canvas_released("left", tgt.x + 10, tgt.y + 5)
  check(row_of(11) == "11 Awwww -> 14", "linked 11 -> 14: " .. tostring(row_of(11)))
  -- onto a line with choices: one more choice
  local b0 = v.by[0]
  v:on_canvas_pressed("left", b0.x + b0.w, b0.y + b0.h / 2, 1)
  v:on_canvas_released("left", v.by[8].x + 10, v.by[8].y + 5)
  check(row_of(0):find("[1,2,8]", 1, true), "0's choices gain 8: " .. tostring(row_of(0)))
  -- dropped on nothing: a new line, linked, where it was dropped
  local b14 = v.by[14]
  v:on_canvas_pressed("left", b14.x + b14.w, b14.y + b14.h / 2, 1)
  local dropx, dropy = b14.x + b14.w + 200, b14.y + 100
  v:on_canvas_moved(dropx, dropy)
  v:on_canvas_released("left", dropx, dropy)
  check(row_of(14):find("-> 15$"), "a new line from 14: " .. tostring(row_of(14)))
  check(v.by[15] and v.by[15].x == dropx and v.by[15].row == v.by[14].row + 1, "line 15: after 14, at the drop")

  -- the menu on a box, and its commands
  v.hot = 5
  local names = {}
  for _, it in ipairs(v:menu_items()) do if it.text then names[#names + 1] = it.text end end
  local ns = table.concat(names, ",")
  check(ns:find("Add answer", 1, true) and ns:find("Unlink", 1, true) and ns:find("Delete line", 1, true), "the menu on line 5: " .. ns)
  local n = v:new_line(5, "answer")
  check(n == 16 and row_of(5):find("[6,7,8,9,16]", 1, true) and v.by[16].kind == "answer", "Add answer: 16, an answer of 5")
  check(v.by[16].row == v.by[9].row + 1, "after the last answer")
  n = v:new_line(10, "next")
  check(row_of(10):find("-> 17$") and row_of(17) == "17 ... -> 13", "Add next line: in the chain (10 -> 17 -> 13)")
  v:unlink(17)
  check(row_of(17) == "17 ...", "Unlink")
  v:delete(16)
  check(not v.by[16] and row_of(5):find("[6,7,8,9]", 1, true), "Delete line: gone, and from 5's choices: " .. tostring(row_of(5)))
  v:delete(12)
  check(not v.by[12] and row_of(8) == "8 Maybe" and row_of(9) == "9 Not sure", "deleted 12: the arrows to it gone")
  coroutine.yield(0.5)                             -- (edits close in time undo together)
  local before = text()
  local name = v:new_topic(10, 2000)
  check(name == "topic" and v.d.topics.topic and text():find("\n#topic ...  //@", 1, true), "New #topic")
  v.hot = nil
  names = {}
  for _, it in ipairs(v:menu_items()) do if it.text then names[#names + 1] = it.text end end
  check(table.concat(names, ","):find("New line", 1, true), "the menu on the background: New line")

  -- undo: back to the text before the topic
  local doc = v:edit_doc()
  doc:undo(); v:changed()
  check(text() == before and not v.d.topics.topic, "undo: the topic gone, the rest kept")
  -- save
  v:save()
  check(v.dirty == false, "saved")
  local f = io.open(path, "rb"); local disk = f:read("*a"); f:close()
  check(disk:gsub("\r", ""):gsub("%s+$", "") == text():gsub("\r", ""):gsub("%s+$", ""), "saved: the disk has it")
  os.remove(path)
  print(string.format("dialog edit: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)

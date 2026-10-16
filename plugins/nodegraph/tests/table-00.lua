-- table-00: a table node with widgets.
-- Expect: checkbox (on: green tick), number fields (drag sideways), a
--   string, a vector (x, y), a colour swatch (opens a picker), a slider
--   (--@range), a drop-down (--@enum), "+ add field" at the bottom.
local cfg = {
  enabled = true,
  speed = 2.5,
  name = "paddle",
  pos = { x = 10, y = 20 },
  color = { 255, 128, 0 },
  volume = 7,          --@range 0 10
  mode = "fast",       --@enum slow|fast|insane
}
return cfg

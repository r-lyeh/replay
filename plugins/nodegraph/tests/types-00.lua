-- types-00: pins and wires coloured by type, when it's certain.
-- Expect: b red (boolean), i orange (integer), f yellow (number), s green
--   (string), t blue (table), fn teal (function); z uncoloured (it's
--   assigned again later, so its type isn't certain). Hover a pin: its type.
local b = 1 < 2
local i = 3 + 4
local f = 1 / 3
local s = "a" .. "b"
local t = {}
local fn = function() end
local z = 1
z = "now a string"
print(b, i, f, s, t, fn, z)

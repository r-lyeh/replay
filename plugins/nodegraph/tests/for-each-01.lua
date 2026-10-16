-- for-each-01: ipairs (its index is an integer: orange) and an early exit.
-- Expect: "for each" with outputs i (orange) and v; body: an if (v < 0)
--   then -> set found = i -> break; else -> nothing (the body ends).
local list = { 4, 8, -1, 16 }
local found = nil
for i, v in ipairs(list) do
  if v < 0 then
    found = i
    break
  end
end
print(found)

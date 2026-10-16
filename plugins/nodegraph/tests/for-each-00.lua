-- for-each-00: pairs over a table.
-- Expect: a table node (3 fields: a, b, c) -> set local t; "for each"
--   (iterator: a pairs call node fed by t; outputs k, v) -> body: print(k, v)
--   -> done: print("end").
local t = { a = 1, b = 2, c = 3 }
for k, v in pairs(t) do
  print(k, v)
end
print("end")

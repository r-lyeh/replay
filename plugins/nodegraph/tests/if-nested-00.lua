-- if-nested-00: ifs inside ifs.
-- Expect: if (a) then -> if (b) then -> print("a and b"), else ->
--   print("a only"); outer else -> print("not a").
local a, b = true, false
if a then
  if b then
    print("a and b")
  else
    print("a only")
  end
else
  print("not a")
end

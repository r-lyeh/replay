-- if-elseif-00: an elseif chain, drawn as ifs wired into the else before them.
-- Expect: if (n < 0) then -> print("negative"); else -> if (n == 0)
--   then -> print("zero"); else -> print("positive"). Each "if" node can
--   be moved on its own (an elseif keeps its --@node line above it).
local n = 3
if n < 0 then
  print("negative")
elseif n == 0 then
  print("zero")
else
  print("positive")
end

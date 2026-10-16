-- if-00: an if with no else.
-- Expect: "if" (condition: x > 5, red pin: boolean) then -> print("big");
--   else (empty) and the print's end both lead to print("after").
local x = 7
if x > 5 then
  print("big")
end
print("after")

-- while-00: a while loop.
-- Expect: set local n = 10 -> "while" (condition: an expression n > 0) ->
--   body: set n = n - 1 (no wire back to the while) ; done -> print(n).
local n = 10
while n > 0 do
  n = n - 1
end
print(n)

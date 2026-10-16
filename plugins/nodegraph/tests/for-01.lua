-- for-01: a step, nested loops, a break.
-- Expect: outer "for" (start 0, stop 100, step 10) -> body: inner "for"
--   (j); the inner body: an if (j > 2) whose then is "break" (ends the
--   flow). The inner for's done -> print(i). Loop variables are output pins.
for i = 0, 100, 10 do
  for j = 1, 3 do
    if j > 2 then break end
    print(i, j)
  end
  print(i)
end

-- for-00: a numeric for loop.
-- Expect: start -> "for" (start 1, stop 10; output pin i, orange: integer)
--   body -> call print (arg: i), wired from the for's i pin
--   done -> the last print. Nothing wired back from the body's end.
for i = 1, 10 do
  print(i)
end
print("done")

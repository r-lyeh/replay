-- repeat-00: repeat ... until.
-- Expect: "repeat" -> body: set tries -> "until" (condition tries >= 3,
--   one out: done) -> print. No "again" pin, no wire back.
local tries = 0
repeat
  tries = tries + 1
until tries >= 3
print(tries)

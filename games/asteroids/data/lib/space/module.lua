-- space: what the systems share. `local space = require "space"` in a
-- system loads this (it's /data/lib/space's module); edit it and save, and
-- every system that uses it is built again. Plain helpers, no state: the
-- game's state lives in the world (/data/state), so it saves, rewinds and
-- travels.
local space = {}

space.atan2 = math.atan2 or math.atan             -- (Lua 5.4: math.atan(y, x); LuaJIT: math.atan2)

function space.wrap(x, a)                          -- leave one edge, come back at the other
  if x.x < -a.w / 2 then x.x = x.x + a.w elseif x.x > a.w / 2 then x.x = x.x - a.w end
  if x.y < -a.h / 2 then x.y = x.y + a.h elseif x.y > a.h / 2 then x.y = x.y - a.h end
end

function space.delta(from, to, size)               -- the shortest way, across the wrap
  local d = to - from
  if d > size / 2 then d = d - size elseif d < -size / 2 then d = d + size end
  return d
end

function space.angle(a)                            -- into -pi..pi
  return (a + math.pi) % (2 * math.pi) - math.pi
end

function space.rand(s)                             -- 0..1, Park-Miller on s.seed (/data/state: a rewind replays it)
  s.seed = (s.seed * 16807) % 2147483647
  return s.seed / 2147483647
end

return space

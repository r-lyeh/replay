-- walk: the player moves (arrows / WASD / a pad), not through walls or
-- furniture, and not while talking; walking over the bananas takes them
local room = require "room"
return function(w, dt)
  local st, rl, input = w:node("/data/state"), w:node("/data/rules"), w:node("/data/input/p1")
  if not (st and rl and input) then return end
  local s, talk, R = st.c.walk, st.c.talk, rl.c.room
  local m = w:asset(R.map)
  if not m then return end
  local h = input.c.held
  local dx = (room.any(h, room.RIGHT) and 1 or 0) - (room.any(h, room.LEFT) and 1 or 0)
  local dy = (room.any(h, room.DOWN) and 1 or 0) - (room.any(h, room.UP) and 1 or 0)
  if talk.on then dx, dy = 0, 0 end
  if dx ~= 0 then s.facing = dx end
  local step = R.speed * math.min(dt, 1 / 30)
  local function free(x, y)                        -- the feet: a small box
    return not (room.solid(m, R.solid, x - 5, y + 2) or room.solid(m, R.solid, x + 5, y + 2)
             or room.solid(m, R.solid, x - 5, y + 7) or room.solid(m, R.solid, x + 5, y + 7))
  end
  if dx ~= 0 and free(s.x + dx * step, s.y) then s.x = s.x + dx * step end
  if dy ~= 0 and free(s.x, s.y + dy * step) then s.y = s.y + dy * step end
  local p = w:node("/objects/player")
  if p then p.c.xform.x, p.c.xform.y, p.c.xform.sx = s.x, s.y, s.facing end
  local b = w:node("/objects/bananas")
  if b and not s.carrying and math.abs(b.c.xform.x - s.x) < 12 and math.abs(b.c.xform.y - s.y) < 12 then
    s.carrying = "bananas"                         -- carried: the fairy may have something to say about them
    talk.known.bananas = true
    w:remove("/objects/bananas")
  end
end

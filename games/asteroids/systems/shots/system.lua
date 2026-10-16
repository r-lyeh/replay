-- shots: fly straight (wrapping), and go when their life runs out or they
-- hit a rock. The shots are the host's (/entities/shots<N>, one box a
-- player): it removes them, when one hit (/data/state's `spent`) or ran
-- out; the others fly them (predicted) until the host's state says gone.
-- Online, your own SPACE shows a shot at once: a stand-in (/entities/mine,
-- this world's only), replaced by the host's shot of that number when it
-- comes (or gone when it runs out, or hits a rock as seen here).

local space = require "space"                     -- (data/lib/space: shared helpers)
local wrap, delta = space.wrap, space.delta

return { requires = { "shot", "xform", "vel" }, run = function(w, n, dt)
  local rules, s = w:node("/data/rules").c, w:node("/data/state").c
  local x, v, a = n.c.xform, n.c.vel, rules.arena
  x.x, x.y = x.x + v.x * dt, x.y + v.y * dt
  wrap(x, a)
  n.c.shot.life = n.c.shot.life - dt
  if n.c.shot.stand_in then                        -- ours, shown at once: the host's of that number came? it takes
    local real = w:node("/entities/shots" .. n.c.shot.by .. "/" .. n.name)   -- our place (our guess is
    if real then                                   -- ahead of the host's state), and the stand-in goes
      real.c.xform.x, real.c.xform.y = x.x, x.y
      w:remove(n.path)
      return
    end
  end
  if not w:owns(n) then return end
  local gone = n.c.shot.life <= 0 or s.spent[n.path]
  local rocks = w:node("/entities/rocks")
  if not gone and rocks and not w:owns(rocks) then   -- (not the host: a hit as we see it)
    for _, r in ipairs(w:children(rocks)) do
      local rr = rules.rocks.sizes[r.c.rock.size].r + 4
      local dx, dy = delta(x.x, r.c.xform.x, a.w), delta(x.y, r.c.xform.y, a.h)
      if dx * dx + dy * dy < rr * rr then gone = true break end
    end
  end
  if gone then w:remove(n.path) end
end }

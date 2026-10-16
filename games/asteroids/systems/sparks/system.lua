-- sparks: a burst where a rock broke or a ship died (the event "boom", from
-- the host: systems/rocks, systems/director), made by every player itself
-- from the event's numbers and seed (the same burst everywhere, nothing
-- sent but the event). Each spark flies out, slows down, fades, and goes.
-- /entities/sparks isn't replicated: each world has its own.

local space = require "space"                     -- (data/lib/space: shared helpers)
local made = 0                                     -- (sparks' names: this world's own count)

local function burst(w, e)
  if not w:node("/entities/sparks") then w:spawn("/entities/sparks", { layer = "fx" }) end   -- (drawn over the ships: data/layers)
  local r = { seed = tonumber(e.seed) or 1 }       -- (the event's seed: the same sparks on every side)
  local c = type(e.color) == "table" and e.color or { 255, 255, 255 }
  for _ = 1, tonumber(e.n) or 8 do
    local a, sp = space.rand(r) * 2 * math.pi, e.v0 + space.rand(r) * (e.v1 - e.v0)
    repeat made = made + 1 until not w:node("/entities/sparks/" .. made)   -- (a reload starts the count again)
    w:spawn("/entities/sparks/" .. made, {
      xform = { x = e.x, y = e.y },
      vel = { x = math.cos(a) * sp, y = math.sin(a) * sp },
      spark = { life = e.l0 + space.rand(r) * (e.l1 - e.l0), max = e.l1 },
      image = { "/assets/spark.png", w = e.size, h = e.size, color = { c[1], c[2], c[3], 255 } },
    })
  end
end

return { requires = { "spark", "xform", "vel" },
  run = function(w, n, dt)
    local x, v, sp = n.c.xform, n.c.vel, n.c.spark
    local k = math.max(0, 1 - 2.5 * dt)
    v.x, v.y = v.x * k, v.y * k
    x.x, x.y = x.x + v.x * dt, x.y + v.y * dt
    sp.life = sp.life - dt
    n.c.image.color[4] = math.floor(255 * math.max(0, math.min(1, sp.life / sp.max)))
    if sp.life <= 0 then w:remove(n.path) end
  end,
  on_event = function(w, name, e)
    if name == "boom" and type(e) == "table" then burst(w, e) end
  end,
}

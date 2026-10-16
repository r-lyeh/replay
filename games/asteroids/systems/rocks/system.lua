-- rocks: drift, spin, wrap. A shot that hits one splits it in two of the
-- next size (big -> medium -> small -> gone), faster, with sparks. The rocks
-- are the host's (player 1): it decides the hits, from everyone's shots;
-- the others guess where rocks drift. A shot spent on a rock is listed in
-- /data/state's `spent`, so its owner (the host) removes it.

local space = require "space"                     -- (data/lib/space: shared helpers)
local wrap, delta, rand, atan2 = space.wrap, space.delta, space.rand, space.atan2

local function sparks(w, s, x, y, n, color)       -- (an event: every player makes the same burst itself, systems/sparks)
  w:event("boom", { x = x, y = y, n = n, v0 = 40, v1 = 180, l0 = 0.4, l1 = 0.9, size = 10, color = color,
                    seed = math.floor(rand(s) * 2147483646) + 1 })
end

local function split(w, n, s, rules)
  local rk, x, v = n.c.rock, n.c.xform, n.c.vel
  local size = rules.rocks.sizes[rk.size]
  sparks(w, s, x.x, x.y, size.next and 10 or 6, { 255, 210, 150 })
  if size.next then
    local nx = rules.rocks.sizes[size.next]
    local speed = math.max(rules.rocks.speed_min, math.sqrt(v.x * v.x + v.y * v.y)) * (1.2 + rand(s) * 0.4)
    local base = atan2(v.y, v.x)
    if v.y == 0 and v.x == 0 then base = rand(s) * 2 * math.pi end
    for _, turn in ipairs({ -0.7, 0.7 }) do
      local a = base + turn + (rand(s) - 0.5) * 0.4
      s.rocks = s.rocks + 1
      w:spawn("/entities/rocks/" .. s.rocks, {
        xform = { x = x.x, y = x.y, r = x.r },
        vel = { x = math.cos(a) * speed, y = math.sin(a) * speed },
        rock = { size = size.next, spin = (rand(s) - 0.5) * 2 * rules.rocks.spin },
        image = { nx.image, w = nx.w, h = nx.w },
      })
    end
  end
  w:remove(n.path)
end

return { requires = { "rock", "xform", "vel" }, run = function(w, n, dt)
  local rules, s = w:node("/data/rules").c, w:node("/data/state").c
  local x, v, a = n.c.xform, n.c.vel, rules.arena
  x.x, x.y, x.r = x.x + v.x * dt, x.y + v.y * dt, (x.r or 0) + n.c.rock.spin * dt
  wrap(x, a)
  local box = w:node("/entities/rocks")
  if not (box and w:owns(box)) then return end
  local r = rules.rocks.sizes[n.c.rock.size].r
  for _, b in ipairs(w:select("/entities/shots*/*")) do   -- (every player's shots)
    if b.c.shot and not s.spent[b.path] then
      local dx, dy = delta(x.x, b.c.xform.x, a.w), delta(x.y, b.c.xform.y, a.h)
      if dx * dx + dy * dy < (r + 4) * (r + 4) then
        s.spent[b.path] = true
        split(w, n, s, rules)
        return
      end
    end
  end
end }

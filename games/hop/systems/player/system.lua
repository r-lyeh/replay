-- player: runs, jumps (higher while the key's held; a moment after leaving
-- an edge still counts), lands on the map's ground layer, takes gems, goes
-- through the open door. Lava or falling off: back to the start. Sounds
-- are sfxr's (assets/*.sfx): w:sound("jump").
local hop = require "hop"

local function held(i, ...) for _, k in ipairs({ ... }) do if i[k] then return true end end end

local function box(s, P) return s.x - P.w / 2, s.y - P.h / 2, s.x + P.w / 2, s.y + P.h / 2 end

local function die(w, s, rules)
  w:sound("hurt")
  s.deaths = s.deaths + 1
  s.x, s.y = hop.centre(rules.start[1], rules.start[2])
  s.vx, s.vy, s.jumping = 0, 0, 0
end

local function move(m, rules, s, P, dx, dy)          -- one axis at a time, pushed out of what's solid
  if dx ~= 0 then
    s.x = s.x + dx
    local x0, y0, x1, y1 = box(s, P)
    if hop.solid(m, rules, x0, y0, x1, y1) then
      if dx > 0 then s.x = (hop.cell_of(x1, 0)) * hop.TILE + hop.OX - P.w / 2
      else s.x = (hop.cell_of(x0, 0) + 1) * hop.TILE + hop.OX + P.w / 2 end
      s.vx = 0
    end
  end
  s.on_ground = false
  if dy ~= 0 then
    s.y = s.y + dy
    local x0, y0, x1, y1 = box(s, P)
    if hop.solid(m, rules, x0, y0, x1, y1) then
      if dy > 0 then
        local _, cy = hop.cell_of(0, y1)
        s.y = cy * hop.TILE + hop.OY - P.h / 2
        s.on_ground = true
      else
        local _, cy = hop.cell_of(0, y0)
        s.y = (cy + 1) * hop.TILE + hop.OY + P.h / 2
        s.jumping = 0
      end
      s.vy = 0
    end
  end
end

return function(w, dt)
  local st, rl, me = w:node("/data/state"), w:node("/data/rules"), w:node("/objects/player")
  if not (st and rl and me) then return end
  local s, rules, phys = st.c.round, rl.c.level, rl.c.physics
  if not s.started then return end
  local m = hop.map(w, rules.map)
  if not m then return end
  local P = rules.player
  local input = w:node("/data/input/p1")
  local i, taps = input and input.c.held or {}, input and input.c.taps or {}
  if input then input.c.taps = {} end
  dt = math.min(dt, 1 / 30)
  s.time = s.time + dt

  if not s.won then
    local dir = (held(i, "right", "d", "pad dpright", "pad right") and 1 or 0) - (held(i, "left", "a", "pad dpleft", "pad left") and 1 or 0)
    if dir ~= 0 then
      s.vx = math.max(-phys.run, math.min(phys.run, s.vx + dir * phys.accel * dt))
      s.facing = dir
    else
      local f = phys.friction * dt
      s.vx = math.abs(s.vx) <= f and 0 or s.vx - f * (s.vx > 0 and 1 or -1)
    end
    s.air = s.on_ground and 0 or s.air + dt
    if (taps.space or taps.up or taps.w or taps.z or taps["pad a"]) and s.air <= phys.coyote then
      s.vy, s.jumping, s.air = -phys.jump, phys.hold, phys.coyote + 1
      w:sound("jump")
    end
    local holding = held(i, "space", "up", "w", "z", "pad a")
    if s.jumping > 0 and holding and s.vy < 0 then s.jumping = s.jumping - dt
    else s.jumping = 0 end
    local g = s.jumping > 0 and phys.gravity * 0.5 or phys.gravity   -- (held: lighter, so higher)
    s.vy = math.min(phys.fall_max, s.vy + g * dt)
    move(m, rules, s, P, s.vx * dt, s.vy * dt)

    local x0, y0, x1, y1 = box(s, P)
    if hop.hurts(m, rules, x0 + 2, y0 + 2, x1 - 2, y1) or y0 > hop.OY + (m.h or 17) * hop.TILE then die(w, s, rules) end
    for _, g in ipairs(w:node("/entities") and w:children("/entities") or {}) do
      local x = g.c.xform
      if x and math.abs(x.x - s.x) < (P.w / 2 + 6) and math.abs(x.y - s.y) < (P.h / 2 + 6) then
        if g.c.gem then
          w:remove(g.path); s.gems = s.gems + 1
          w:sound("coin")
        elseif g.c.door and g.c.door.open then
          s.won, s.time = true, 0
          w:sound("win")
        end
      end
    end
  end
  me.c.xform.x, me.c.xform.y = math.floor(s.x + 0.5), math.floor(s.y + 0.5)
  me.c.xform.sx = s.facing < 0 and -1 or nil
end

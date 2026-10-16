-- ships: turn, thrust and drift, wrap around the arena, shoot, and die on a
-- rock. A ship whose player isn't in the game flies itself: the coop AI
-- (aims ahead of the nearest rock, gets out of the way of one coming at it).
-- Online, everything is the host's (classic client / server): each ship is
-- flown by its player's keys (replicate.lua: input = N), which reach the
-- host as numbered commands; the host decides its shots and its death. Its
-- player flies it at once here (prediction) and replays its keys on each of
-- the host's states (reconciliation); the others show it a little late,
-- smoothly (interp).

local space = require "space"                     -- (data/lib/space: shared helpers)
local wrap, delta, angle, atan2 = space.wrap, space.delta, space.angle, space.atan2

local KEYS = { left = { "a", "left", "pad dpleft", "pad left" }, right = { "d", "right", "pad dpright", "pad right" },   -- (a gamepad: dpad or left stick,
  thrust = { "w", "up", "pad dpup", "pad up", "pad rt" }, fire = { "space", "s", "down", "pad a", "pad x", "pad dpdown", "pad down" } }   --  A / X fire, RT thrusts)
local function any(held, keys) for _, k in ipairs(keys) do if held[k] then return true end end return false end

-- the AI: -> turn (-1..1), thrust, fire. A rock about to pass too close
-- (within 1.6 s, its path against ours): fly off its path, sideways (and
-- shoot it if it's dead ahead). Else: turn to where the nearest rock will
-- be when a shot gets there, and fire when lined up.
local function ai(w, n, rules)
  local x, v, a, R = n.c.xform, n.c.vel, rules.arena, rules.ship
  local near, nd, ndx, ndy, threat, tt, tdx, tdy, tvx, tvy
  for _, r in ipairs(w:select("/entities/rocks/*")) do
    local rx, size = r.c.xform, rules.rocks.sizes[r.c.rock.size]
    local dx, dy = delta(x.x, rx.x, a.w), delta(x.y, rx.y, a.h)
    local d = math.sqrt(dx * dx + dy * dy) - size.r
    if not nd or d < nd then near, nd, ndx, ndy = r, d, dx, dy end
    local rvx, rvy = r.c.vel.x - v.x, r.c.vel.y - v.y   -- (its speed, as we see it)
    local vv = rvx * rvx + rvy * rvy
    local t = vv > 0 and math.max(0, -(dx * rvx + dy * rvy) / vv) or 0   -- when it's closest
    local cx, cy = dx + rvx * t, dy + rvy * t
    local reach = size.r + R.r + 22
    if t < 1.6 and cx * cx + cy * cy < reach * reach and (not tt or t < tt) then
      threat, tt, tdx, tdy, tvx, tvy = r, t, dx, dy, rvx, rvy
    end
  end
  if not near then return 0, false, false end
  if threat then
    local px, py = -tvy, tvx                       -- off its path: square to it, on our side
    if px * -tdx + py * -tdy < 0 then px, py = -px, -py end
    if tvx == 0 and tvy == 0 then px, py = -tdx, -tdy end
    local diff = angle(atan2(px, -py) - x.r)
    local ahead = math.abs(angle(atan2(tdx, -tdy) - x.r)) < 0.2
    return math.max(-1, math.min(1, diff * 3)), math.abs(diff) < 0.9, ahead
  end
  local t = (nd + 20) / rules.shot.speed           -- where it'll be when a shot gets there
  local tx, ty = ndx + near.c.vel.x * t, ndy + near.c.vel.y * t
  local diff = angle(atan2(tx, -ty) - x.r)         -- (forward is (sin r, -cos r))
  return math.max(-1, math.min(1, diff * 3)), false, math.abs(diff) < 0.18 and nd < 340
end

local function die(n)
  n.c.ship.alive = false
  n.c.hidden = true
  n.c.vel.x, n.c.vel.y = 0, 0
end

return { requires = { "ship", "xform", "vel" }, run = function(w, n, dt)
  local rules, s = w:node("/data/rules").c, w:node("/data/state").c
  local sh, x, v, R = n.c.ship, n.c.xform, n.c.vel, rules.ship
  local me = w:owns(n)
  local flame = w:node(n.path .. "/flame")
  if me and sh.round ~= s.round then              -- a new round: back to its start, safe for a while
    x.x, x.y, x.r, v.x, v.y = sh.x, sh.y, 0, 0, 0
    sh.alive, sh.time, sh.safe, sh.cool, sh.round = true, 0, R.safe, 0, s.round
    n.c.hidden = nil
  end
  if flame then flame.c.hidden = true end
  if not sh.alive then return end

  local turn, thrust, fire
  if (w.players or { true })[sh.player] then
    local input = w:node("/data/input/p" .. sh.player)
    local held = input and input.c.held or {}
    turn = (any(held, KEYS.right) and 1 or 0) - (any(held, KEYS.left) and 1 or 0)
    thrust, fire = any(held, KEYS.thrust), any(held, KEYS.fire)
  else
    turn, thrust, fire = ai(w, n, rules)
  end

  x.r = angle(x.r + turn * R.turn * dt)
  local fx, fy = math.sin(x.r), -math.cos(x.r)
  if thrust then v.x, v.y = v.x + fx * R.thrust * dt, v.y + fy * R.thrust * dt end
  local k = math.max(0, 1 - R.drag * dt)
  v.x, v.y = v.x * k, v.y * k
  local speed = math.sqrt(v.x * v.x + v.y * v.y)
  if speed > R.max then v.x, v.y = v.x / speed * R.max, v.y / speed * R.max end
  x.x, x.y = x.x + v.x * dt, x.y + v.y * dt
  wrap(x, rules.arena)
  if flame and thrust then
    flame.c.hidden = nil
    flame.c.xform.sy = 0.85 + 0.25 * math.sin(sh.time * 37)   -- (a flicker)
  end

  sh.time = sh.time + dt                           -- (seconds alive: who lives longest wins)
  sh.safe = math.max(0, sh.safe - dt)
  n.c.image.color[4] = sh.safe > 0 and (math.floor(sh.time * 8) % 2 == 0 and 90 or 255) or 255   -- (blinks while safe)
  sh.cool = math.max(0, sh.cool - dt)
  local mine = not me and w.peer == sh.player      -- (our own ship, flown here at once: predicted)

  if fire and sh.cool <= 0 and (me or mine) then   -- a shot, out of the nose, the ship's speed added
    sh.shots = sh.shots + 1
    sh.cool = R.cool
    local shot = {
      xform = { x = x.x + fx * 18, y = x.y + fy * 18 },
      vel = { x = fx * rules.shot.speed + v.x, y = fy * rules.shot.speed + v.y },
      shot = { life = rules.shot.life, by = sh.player },
      image = { "/assets/shot.png", w = 12, h = 12 },
    }
    if me then                                     -- the host's: the real one
      local box = "/entities/shots" .. sh.player
      if not w:node(box) then w:spawn(box, { replicate = { by = 1, predict = true, snap = { x = 200, y = 200 }, rate = 2 }, layer = "fx" }) end
      w:spawn(box .. "/" .. sh.shots, shot)
    elseif not w.replaying then                    -- ours, at once: a stand-in until the host's shot of that
      shot.shot.stand_in = true                    -- number comes (systems/shots); not again when replayed
      if not w:node("/entities/mine") then w:spawn("/entities/mine", { layer = "fx" }) end
      w:spawn("/entities/mine/" .. sh.shots, shot)
    end
  end
  if not me then return end                        -- (the rest: the owner's to decide)
  if sh.safe > 0 or s.over then return end
  local a = rules.arena
  for _, r in ipairs(w:select("/entities/rocks/*")) do
    local dx, dy = delta(x.x, r.c.xform.x, a.w), delta(x.y, r.c.xform.y, a.h)
    local reach = rules.rocks.sizes[r.c.rock.size].r + R.r
    if dx * dx + dy * dy < reach * reach then die(n) return end
  end
end }

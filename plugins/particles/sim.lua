-- sim.lua - particles: an effect's settings and the simulation (no lite here:
-- the editor draws it, a game can run it the same way, a test can check it).
--
--   local fx = require "sim"                   -- (plugins/particles/sim.lua)
--   local def = fx.preset("fire")              -- an effect: plain data (a .pfx file's)
--   local e = fx.new(def, seed)                -- an emitter of it, at 0, 0
--   fx.step(e, dt)                             -- spawn, move, age, drop the dead
--   for _, p in ipairs(e.ps) do                -- what to draw:
--     local x, y, size, r, g, b, a = fx.look(e, p)
--   end
--
-- An effect (all optional; fx.check fills in the rest):
--   rate      particles a second            burst     particles at once, each cycle
--   max       at most this many alive       duration  a cycle, seconds (0: forever)
--   loop      a cycle starts again          life      { min, max } seconds
--   shape     "point" | "circle" | "box"    radius    the circle's; width, height: the box's
--   angle     where they go, degrees (0: right, -90: up)   spread: +- degrees
--   speed     { min, max } px / s           gravity   { x, y } px / s^2
--   drag      0..: the speed lost a second  spin      { min, max } degrees / s
--   size      { start, end } px             size_var  0..1: each one's size, +- that much
--   color     { start, end }: { r, g, b, a } 0..255 each
--   blend     "alpha" | "add"               square    true: squares (else discs)
local M = {}

M.DEFAULTS = {
  rate = 40, burst = 0, max = 400, duration = 0, loop = true,
  life = { 0.8, 1.4 }, shape = "point", radius = 8, width = 32, height = 8,
  angle = -90, spread = 20, speed = { 60, 120 }, gravity = { 0, 0 }, drag = 0, spin = { 0, 0 },
  size = { 10, 2 }, size_var = 0.2, color = { { 255, 220, 120, 255 }, { 255, 80, 20, 0 } },
  blend = "alpha", square = false,
}
M.SHAPES = { "point", "circle", "box" }
M.BLENDS = { "alpha", "add" }

local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end
M.copy = copy

local function num(v, d) return type(v) == "number" and v == v and v or d end
local function pair(v, d) return type(v) == "table" and { num(v[1], d[1]), num(v[2], d[2]) } or { d[1], d[2] } end
local function rgba(v, d)
  if type(v) ~= "table" then return copy(d) end
  local c = {}
  for i = 1, 4 do c[i] = math.max(0, math.min(255, math.floor(num(v[i], d[i]) + 0.5))) end
  return c
end

-- an effect read from a file: whatever is missing or wrong, the default's
function M.check(t)
  local d = M.DEFAULTS
  t = type(t) == "table" and t or {}
  local e = {}
  for _, k in ipairs({ "rate", "burst", "max", "duration", "radius", "width", "height", "angle", "spread", "drag", "size_var" }) do
    e[k] = num(t[k], d[k])
  end
  e.rate, e.burst, e.duration, e.drag = math.max(0, e.rate), math.max(0, math.floor(e.burst)), math.max(0, e.duration), math.max(0, e.drag)
  e.max = math.max(1, math.min(20000, math.floor(e.max)))
  e.size_var = math.max(0, math.min(1, e.size_var))
  e.loop = t.loop == nil and d.loop or t.loop == true
  e.square = t.square == true
  e.life, e.speed, e.gravity, e.spin, e.size = pair(t.life, d.life), pair(t.speed, d.speed), pair(t.gravity, d.gravity), pair(t.spin, d.spin), pair(t.size, d.size)
  e.life[1] = math.max(0.01, e.life[1]); e.life[2] = math.max(e.life[1], e.life[2])
  local col = type(t.color) == "table" and t.color or {}
  e.color = { rgba(col[1], d.color[1]), rgba(col[2], d.color[2]) }
  e.shape = (t.shape == "circle" or t.shape == "box") and t.shape or "point"
  e.blend = t.blend == "add" and "add" or "alpha"
  return e
end

-- the effects it comes with
M.PRESETS = { "fire", "smoke", "sparks", "explosion", "fountain", "rain", "snow", "magic" }
M.PRESET_NAMES = { fire = "Fire", smoke = "Smoke", sparks = "Sparks", explosion = "Explosion", fountain = "Fountain",
                   rain = "Rain", snow = "Snow", magic = "Magic" }
local P = {
  fire = { rate = 90, max = 300, life = { 0.5, 1.0 }, shape = "circle", radius = 10, angle = -90, spread = 12,
           speed = { 50, 110 }, gravity = { 0, -40 }, drag = 0.6, size = { 18, 3 }, size_var = 0.3,
           color = { { 255, 210, 90, 230 }, { 220, 40, 10, 0 } }, blend = "add" },
  smoke = { rate = 18, max = 120, life = { 2.0, 3.5 }, shape = "circle", radius = 6, angle = -90, spread = 15,
            speed = { 20, 45 }, gravity = { 8, -10 }, drag = 0.2, spin = { -40, 40 }, size = { 12, 46 }, size_var = 0.25,
            color = { { 120, 120, 120, 150 }, { 70, 70, 70, 0 } } },
  sparks = { rate = 60, max = 250, life = { 0.3, 0.8 }, angle = -90, spread = 70, speed = { 120, 260 },
             gravity = { 0, 420 }, drag = 0.4, size = { 4, 1 }, size_var = 0.4,
             color = { { 255, 240, 160, 255 }, { 255, 120, 30, 0 } }, blend = "add", square = true },
  explosion = { rate = 0, burst = 140, max = 400, duration = 1.6, loop = true, life = { 0.4, 1.1 }, shape = "circle", radius = 4,
                angle = 0, spread = 180, speed = { 60, 300 }, drag = 2.2, size = { 16, 2 }, size_var = 0.5,
                color = { { 255, 230, 140, 255 }, { 200, 50, 20, 0 } }, blend = "add" },
  fountain = { rate = 120, max = 500, life = { 1.4, 1.9 }, angle = -90, spread = 10, speed = { 240, 300 },
               gravity = { 0, 330 }, size = { 5, 3 }, size_var = 0.2,
               color = { { 140, 200, 255, 230 }, { 60, 120, 255, 0 } } },
  rain = { rate = 160, max = 700, life = { 0.9, 1.1 }, shape = "box", width = 360, height = 4, angle = 100, spread = 2,
           speed = { 420, 520 }, size = { 3, 3 }, color = { { 160, 190, 255, 200 }, { 160, 190, 255, 120 } }, square = true },
  snow = { rate = 40, max = 400, life = { 4, 6 }, shape = "box", width = 360, height = 4, angle = 90, spread = 25,
           speed = { 20, 50 }, gravity = { 6, 4 }, spin = { -60, 60 }, size = { 5, 4 }, size_var = 0.5,
           color = { { 255, 255, 255, 240 }, { 230, 240, 255, 0 } } },
  magic = { rate = 70, max = 300, life = { 0.8, 1.6 }, shape = "circle", radius = 24, angle = -90, spread = 180,
            speed = { 5, 30 }, gravity = { 0, -30 }, spin = { -180, 180 }, size = { 7, 0 }, size_var = 0.4,
            color = { { 200, 140, 255, 255 }, { 80, 220, 255, 0 } }, blend = "add" },
}
function M.preset(name) return P[name] and M.check(copy(P[name])) end

-- random numbers, repeatable (a seed: the same particles)
local function rng(seed)
  local s = math.floor(tonumber(seed) or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  for _ = 1, 3 do s = s * 48271 % 2147483647 end
  return function(a, b) s = s * 48271 % 2147483647; local t = (s - 1) / 2147483646; return a + (b - a) * t end
end

function M.new(def, seed)
  return { def = M.check(def), ps = {}, t = 0, acc = 0, cycle = -1, x = 0, y = 0, rnd = rng(seed or 1), spawned = 0 }
end

local function spawn(e, n)
  local d, R, ps = e.def, e.rnd, e.ps
  local rad = math.pi / 180
  for _ = 1, n do
    if #ps >= d.max then return end
    local x, y = e.x, e.y
    if d.shape == "circle" then
      local a, r = R(0, 2 * math.pi), d.radius * math.sqrt(R(0, 1))
      x, y = x + math.cos(a) * r, y + math.sin(a) * r
    elseif d.shape == "box" then
      x, y = x + R(-d.width / 2, d.width / 2), y + R(-d.height / 2, d.height / 2)
    end
    local a = (d.angle + R(-d.spread, d.spread)) * rad
    local v = R(d.speed[1], d.speed[2])
    ps[#ps + 1] = { x = x, y = y, vx = math.cos(a) * v, vy = math.sin(a) * v, age = 0, life = R(d.life[1], d.life[2]),
                    k = 1 + R(-d.size_var, d.size_var), rot = R(0, 360), spin = R(d.spin[1], d.spin[2]) }
    e.spawned = e.spawned + 1
  end
end

function M.step(e, dt)
  local d = e.def
  e.t = e.t + dt
  local cycle = d.duration > 0 and math.floor(e.t / d.duration) or 0
  local on = d.duration == 0 or d.loop or cycle == 0
  if cycle ~= e.cycle then                         -- a new cycle: its burst
    e.cycle = cycle
    if on and d.burst > 0 then spawn(e, d.burst) end
  end
  if on and d.rate > 0 then
    e.acc = e.acc + d.rate * dt
    local n = math.floor(e.acc)
    e.acc = e.acc - n
    spawn(e, n)
  end
  local ps, gx, gy = e.ps, d.gravity[1] * dt, d.gravity[2] * dt
  local keep = math.max(0, 1 - d.drag * dt)
  local i, n = 1, #ps
  while i <= n do
    local p = ps[i]
    p.age = p.age + dt
    if p.age >= p.life then                        -- gone: the last one takes its place
      ps[i] = ps[n]; ps[n] = nil; n = n - 1
    else
      p.vx, p.vy = (p.vx + gx) * keep, (p.vy + gy) * keep
      p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
      p.rot = p.rot + p.spin * dt
      i = i + 1
    end
  end
end

-- a particle now: where, how big, its colour (start -> end over its life)
function M.look(e, p)
  local d = e.def
  local t = p.age / p.life
  local c0, c1 = d.color[1], d.color[2]
  local size = (d.size[1] + (d.size[2] - d.size[1]) * t) * p.k
  return p.x, p.y, size, c0[1] + (c1[1] - c0[1]) * t, c0[2] + (c1[2] - c0[2]) * t,
         c0[3] + (c1[3] - c0[3]) * t, c0[4] + (c1[4] - c0[4]) * t, p.rot
end

return M

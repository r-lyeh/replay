-- ORBITBREAK: a Super Hexagon-like game for Replay, in one file.
-- Run with: replay games/orbitbreak.lua
-- Rings close in on the core; each has a gap: turn around the orbit to be in
-- it when the ring passes. A pass builds the combo; the gold spark in each gap refills
-- the pulse (SPACE), which breaks the rings close to you. The arena spins,
-- flips and changes colour as it gets faster.
-- Keys: A / D or the arrows turn, SPACE pulses, R (or SPACE) plays again.
-- A gamepad: dpad / left stick turn, A / X pulse, START / A play again.
-- (Ported from orbitbreak.html, the web prototype: same rules and numbers.)
local ecs = require("ecs")
local w = ecs.world()

local R = 78                                       -- the orbit's radius
w:spawn("/config", { window = { w = 800, h = 500, title = "ORBITBREAK" } })
w:spawn("/data/state", {
  t = 0, angle = -math.pi / 2, score = 0, best = 0, combo = 1, energy = 1, pulse = 0,
  spawn = 1, dead = false, flash = 0, near = 0, spin = 0, spin_dir = 1, flip_in = 8,
  seed = 20261021, rings = {}, sparks = {}, particles = {}, held = {}, taps = {},
  shake = false,   -- the rings throb on the beat (off for now: a music track will turn it on and off)
  beat = nil,      -- that beat's strength now, 0..1 (set by the music; nil: a clock, twice a second)
})

-- the screen: background, a starfield, the arena (it spins: all inside it turns with it).
-- Siblings draw in name order; layers say what goes under / over (/data/layers)
w:spawn("/data/layers", { order = { "sky", "back", "default", "front" } })
w:spawn("/objects/background", { xform = { x = 0, y = 0 }, color = { 8, 13, 24 }, rect = { w = 800, h = 500, fill = true }, layer = "sky" })
for i = 0, 79 do
  local sx, sy = (i * 137.5) % 800 - 400, (i * 73.7) % 500 - 250
  w:spawn("/objects/stars/" .. (i + 1), { xform = { x = sx, y = sy }, color = { 120, 160, 220, 30 + (i % 4) * 10 }, rect = { w = 1.5, h = 1.5, fill = true }, layer = "sky" })
end
w:spawn("/objects/arena", { xform = { x = 0, y = 0, r = 0, s = 1 } })
w:spawn("/objects/arena/spokes", { xform = { x = 0, y = 0 }, color = { 16, 24, 40 }, tris = {}, layer = "back" })
for r = 40, 400, 40 do                             -- a faint orbital grid
  w:spawn("/objects/arena/grid/r" .. r, { xform = { x = 0, y = 0 }, color = r == 80 and { 38, 54, 80 } or { 20, 30, 48 }, circle = { r = r, n = 72 }, layer = "back" })
end
w:spawn("/objects/arena/anchor", { xform = { x = 0, y = 0 }, color = { 53, 70, 96 }, circle = { r = 4, fill = true } })
w:spawn("/objects/arena/rings", { xform = { x = 0, y = 0 }, color = { 255, 83, 107 }, tris = {} })
w:spawn("/objects/arena/gaps", { xform = { x = 0, y = 0 }, color = { 255, 176, 167 }, tris = {} })
w:spawn("/objects/arena/sparks", { xform = { x = 0, y = 0 }, color = { 255, 198, 109 }, tris = {} })
w:spawn("/objects/arena/bits/cyan", { xform = { x = 0, y = 0 }, color = { 98, 233, 255, 200 }, tris = {} })
w:spawn("/objects/arena/bits/gold", { xform = { x = 0, y = 0 }, color = { 255, 198, 109, 200 }, tris = {} })
w:spawn("/objects/arena/bits/red", { xform = { x = 0, y = 0 }, color = { 255, 83, 107, 200 }, tris = {} })
w:spawn("/objects/arena/pulse", { xform = { x = 0, y = -R }, color = { 98, 233, 255 }, circle = { r = 18, n = 40 }, hidden = true, layer = "front" })
w:spawn("/objects/arena/player", { xform = { x = 0, y = -R }, color = { 244, 248, 255 }, circle = { r = 11, fill = true }, layer = "front" })
w:spawn("/objects/arena/player/core", { xform = { x = 0, y = 0 }, color = { 98, 233, 255 }, circle = { r = 4, fill = true } })
w:spawn("/objects/flash", { xform = { x = 0, y = 0 }, color = { 255, 70, 100, 0 }, rect = { w = 800, h = 500, fill = true }, layer = "front" })

-- the HUD (text: its top-left corner at xform; 8 px a letter, times size)
w:spawn("/objects/hud", { layer = "front" })
w:spawn("/objects/hud/title", { xform = { x = -385, y = -236 }, color = { 234, 242, 255 }, text = { "ORBITBREAK", size = 3 } })
w:spawn("/objects/hud/tag", { xform = { x = -385, y = -206 }, color = { 131, 147, 173 }, text = "ALIGN. THREAD THE GAP. SURVIVE." })
w:spawn("/objects/hud/score", { xform = { x = 140, y = -236 }, color = { 255, 255, 255 }, text = { "SCORE 0", size = 2 } })
w:spawn("/objects/hud/info", { xform = { x = 140, y = -214 }, color = { 169, 186, 213 }, text = "BEST 0   COMBO x1   PULSE READY" })
w:spawn("/objects/hud/help", { xform = { x = -385, y = 232 }, color = { 137, 154, 181 }, text = "A/D OR ARROWS TURN   SPACE PULSE   R RESTART   (A PAD TOO)" })
w:spawn("/objects/hud/over", { xform = { x = 0, y = 0 }, color = { 5, 8, 16, 184 }, rect = { w = 800, h = 500, fill = true }, hidden = true })
w:spawn("/objects/hud/over/title", { xform = { x = -156, y = -40 }, color = { 244, 248, 255 }, text = { "CORE BREACHED", size = 3 } })
w:spawn("/objects/hud/over/score", { xform = { x = -56, y = 4 }, color = { 255, 113, 132 }, text = { "SCORE 0", size = 2 } })
w:spawn("/objects/hud/over/again", { xform = { x = -156, y = 42 }, color = { 154, 171, 198 }, text = "PRESS R (OR START) TO RE-ENTER THE ORBIT" })

-- input: the keys held, and the presses since the game last looked (taps)
-- (systems run sandboxed: each keeps what it needs inside its function)
local input = ecs.system(function()
  return { on_key = function(w, key, down, player)
    local s = w:node("/data/state").c
    local was = s.held[key]
    s.held[key] = down or nil
    if down and not was then s.taps = s.taps or {}; s.taps[key] = true end
  end }
end)

local play = ecs.system(function()
  local R = 78
  local PULSE = { space = true, ["pad a"] = true, ["pad x"] = true }
  local AGAIN = { r = true, space = true, ["return"] = true, ["pad start"] = true, ["pad a"] = true }
  local function any(h, ...) for _, k in ipairs({ ... }) do if h[k] then return true end end return false end
  local function rand(s)                           -- 0..1, on the state's seed (a rewind replays it)
    s.seed = (s.seed * 16807) % 2147483647
    return s.seed / 2147483647
  end
  local atan2 = math.atan2 or math.atan             -- (LuaJIT: atan2; Lua 5.3+: atan(y, x))
  local function wrap(a) return atan2(math.sin(a), math.cos(a)) end
  local function reset(s)
    s.t, s.angle, s.score, s.combo, s.energy, s.pulse = 0, -math.pi / 2, 0, 1, 1, 0
    s.spawn, s.dead, s.flash, s.near, s.spin, s.spin_dir, s.flip_in = 1, false, 0, 0, 0, 1, 8
    s.rings, s.sparks, s.particles = {}, {}, {}
  end
  local function particle(s, x, y, kind, size)
    s.particles[#s.particles + 1] = { x = x, y = y, vx = (rand(s) - 0.5) * 170, vy = (rand(s) - 0.5) * 170,
                                      life = 0.45 + rand(s) * 0.4, kind = kind, size = size }
  end
  local function pulse(s)                          -- SPACE: breaks the rings near the orbit (a full pulse only)
    s.energy, s.pulse, s.flash = 0, 0.48, 0.22
    for _, r in ipairs(s.rings) do if math.abs(r.r - R) < 110 then r.dead = true end end
    local px, py = math.cos(s.angle) * R, math.sin(s.angle) * R
    for _ = 1, 32 do particle(s, px, py, "cyan", 1 + rand(s) * 3) end
  end
  return function(w, dt)
    local s = w:node("/data/state").c
    local taps = s.taps or {}
    s.taps = {}
    local function tapped(set) for k in pairs(taps) do if set[k] then return true end end return false end
    if s.dead and tapped(AGAIN) then reset(s)
    elseif not s.dead and s.energy >= 1 and tapped(PULSE) then pulse(s) end
    dt = math.min(dt, 0.035)
    s.t = s.t + dt
    s.flash = math.max(0, s.flash - dt)
    s.pulse = math.max(0, s.pulse - dt)
    if s.energy < 1 then s.energy = math.min(1, s.energy + dt * 0.11) end
    if not s.dead then
      local h = s.held
      local turn = (any(h, "a", "left", "pad dpleft", "pad left") and -1 or 0) + (any(h, "d", "right", "pad dpright", "pad right") and 1 or 0)
      s.angle = s.angle + turn * 4.2 * dt
      s.spin = s.spin + s.spin_dir * (0.35 + math.min(1.2, s.t * 0.012)) * dt   -- the arena turns, faster and faster
      s.flip_in = s.flip_in - dt
      if s.flip_in <= 0 then s.spin_dir, s.flip_in = -s.spin_dir, 5 + rand(s) * 6 end
      s.spawn = s.spawn - dt
      if s.spawn <= 0 then                           -- a new ring, its gap somewhere, narrower as time goes
        local gap, width = rand(s) * math.pi * 2, math.max(0.43, 0.9 - s.t * 0.002)
        local speed = 45 + math.min(115, s.t * 1.5)  -- (slow at first: 45, up to 160)
        s.rings[#s.rings + 1] = { r = 340, gap = gap, width = width, speed = speed }
        s.sparks[#s.sparks + 1] = { a = gap, r = 340, speed = speed }   -- every gap: a spark in its middle, riding with it
        s.spawn = math.max(0.52, 1.18 - s.t * 0.008) + rand(s) * 0.3
      end
      s.score = s.score + dt * 10 * s.combo
      local px, py = math.cos(s.angle) * R, math.sin(s.angle) * R
      for _, r in ipairs(s.rings) do
        r.r = r.r - r.speed * dt
        if not r.scored and r.r < R then             -- it reaches the orbit: in its gap, or not
          r.scored = true
          if math.abs(wrap(s.angle - r.gap)) < r.width / 2 then
            s.combo = math.min(9, s.combo + 1)
            s.score = s.score + 80 * s.combo
            s.near = 0.3
            for _ = 1, 8 do particle(s, px, py, "gold", 2) end
          else
            s.dead, s.flash = true, 0.5
            for _ = 1, 42 do particle(s, px, py, "red", 2 + rand(s) * 3) end
            if math.floor(s.score) > s.best then s.best = math.floor(s.score) end
          end
        end
      end
      local keep = {}
      for _, r in ipairs(s.rings) do if r.r > -20 and not r.dead then keep[#keep + 1] = r end end
      s.rings = keep
      keep = {}
      for _, sp in ipairs(s.sparks) do
        sp.r = sp.r - (sp.speed or 90) * dt
        if math.abs(sp.r - R) < 10 and math.abs(wrap(s.angle - sp.a)) < 0.24 then   -- caught: score, and the pulse fills
          s.score = s.score + 150 * s.combo
          s.energy = math.min(1, s.energy + 0.32)
          for _ = 1, 12 do particle(s, px, py, "gold", 2) end
        elseif sp.r > R - 12 then keep[#keep + 1] = sp end   -- (past the orbit: missed, gone)
      end
      s.sparks = keep
      if s.near > 0 then s.near = s.near - dt end
    end
    local keep = {}
    for _, p in ipairs(s.particles) do
      p.x, p.y, p.life = p.x + p.vx * dt, p.y + p.vy * dt, p.life - dt
      if p.life > 0 then keep[#keep + 1] = p end
    end
    s.particles = keep
  end
end)

-- what's drawn, from the state (every frame)
local draw = ecs.system(function()
  local R = 78
  local PALETTES = {                               -- one after another as the run goes on: rings, gaps, background
    { { 255, 83, 107 }, { 255, 176, 167 }, { 8, 13, 24 } },
    { { 214, 92, 255 }, { 240, 190, 255 }, { 14, 8, 26 } },
    { { 255, 150, 60 }, { 255, 214, 160 }, { 22, 12, 6 } },
    { { 60, 220, 160 }, { 190, 255, 225 }, { 4, 20, 18 } },
  }
  local function tri(out, ax, ay, bx, by, cx, cy)
    local k = #out
    out[k + 1], out[k + 2], out[k + 3], out[k + 4], out[k + 5], out[k + 6] = ax, ay, bx, by, cx, cy
  end
  local function arc(out, r, a0, a1, thick)        -- a thick arc as triangles (r: its middle)
    if r <= 0 then return end
    local n = math.max(2, math.ceil((a1 - a0) * r / 10))
    local ri, ro = math.max(0, r - thick / 2), r + thick / 2
    for i = 0, n - 1 do
      local b0, b1 = a0 + (a1 - a0) * i / n, a0 + (a1 - a0) * (i + 1) / n
      local c0, s0, c1, s1 = math.cos(b0), math.sin(b0), math.cos(b1), math.sin(b1)
      tri(out, ri * c0, ri * s0, ro * c0, ro * s0, ro * c1, ro * s1)
      tri(out, ri * c0, ri * s0, ro * c1, ro * s1, ri * c1, ri * s1)
    end
  end
  local function square(out, x, y, half, rot)     -- a square (two triangles), turned
    local c, s = math.cos(rot) * half, math.sin(rot) * half
    tri(out, x - c + s, y - s - c, x + c + s, y + s - c, x + c - s, y + s + c)
    tri(out, x - c + s, y - s - c, x + c - s, y + s + c, x - c - s, y - s + c)
  end
  local function mix(a, b, k) return { a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k } end
  return function(w, dt)
    local s = w:node("/data/state").c
    -- the colours: a palette every 15 s, blended over its last 2
    local i = math.floor(s.t / 15)
    local k = math.max(0, (s.t % 15 - 13) / 2)
    local A, B = PALETTES[i % #PALETTES + 1], PALETTES[(i + 1) % #PALETTES + 1]
    w:node("/objects/background").c.color = mix(A[3], B[3], k)
    local beat = s.beat or math.max(0, 1 - (s.t * 2.2 % 1) * 4)   -- (no music: a throb twice a second or so)
    local arena = w:node("/objects/arena").c
    arena.xform.r = s.spin                           -- (the arena turns; only the rings throb: the orbit, the core
    local throb = s.shake and (1 + beat * 0.025 + math.max(0, s.near) * 0.06) or 1   --  and the player never shake)
    for _, p in ipairs({ "rings", "gaps", "sparks" }) do w:node("/objects/arena/" .. p).c.xform.s = throb end
    for r = 120, 400, 40 do w:node("/objects/arena/grid/r" .. r).c.xform.s = throb end
    local spokes = {}                                -- six spokes, the hexagon's
    for j = 0, 5 do
      local a = j * math.pi / 3
      local c, sn = math.cos(a), math.sin(a)
      tri(spokes, 0, 0, c * 460 - sn * 3, sn * 460 + c * 3, c * 460 + sn * 3, sn * 460 - c * 3)
    end
    w:node("/objects/arena/spokes").c.tris = spokes
    local rings, gaps = {}, {}
    for _, r in ipairs(s.rings) do
      arc(rings, r.r, r.gap + r.width / 2, r.gap + math.pi * 2 - r.width / 2, 5)
      arc(gaps, r.r, r.gap - r.width / 2, r.gap + r.width / 2, 2)
    end
    local rn, gn = w:node("/objects/arena/rings").c, w:node("/objects/arena/gaps").c
    rn.tris, rn.color, gn.tris, gn.color = rings, mix(A[1], B[1], k), gaps, mix(A[2], B[2], k)
    local sparks = {}
    for _, sp in ipairs(s.sparks) do square(sparks, math.cos(sp.a) * sp.r, math.sin(sp.a) * sp.r, 5, s.t * 3) end
    w:node("/objects/arena/sparks").c.tris = sparks
    local bits = { cyan = {}, gold = {}, red = {} }
    for _, p in ipairs(s.particles) do square(bits[p.kind], p.x, p.y, p.size * math.min(1, p.life * 2), 0.785) end
    for kind, t in pairs(bits) do w:node("/objects/arena/bits/" .. kind).c.tris = t end
    local px, py = math.cos(s.angle) * R, math.sin(s.angle) * R
    local pl = w:node("/objects/arena/player").c
    pl.xform.x, pl.xform.y, pl.hidden = px, py, s.dead
    local pu = w:node("/objects/arena/pulse").c
    pu.xform.x, pu.xform.y, pu.hidden = px, py, s.pulse <= 0
    pu.circle.r = 18 + (1 - s.pulse / 0.48) * 70
    w:node("/objects/flash").c.color[4] = math.floor(s.flash * 0.25 * 255)
    w:node("/objects/hud/score").c.text[1] = "SCORE " .. math.floor(s.score)
    w:node("/objects/hud/info").c.text = string.format("BEST %d   COMBO x%d   PULSE %s", s.best, s.combo,
      s.energy >= 1 and "READY" or (math.ceil((1 - s.energy) / 0.11) .. "s"))
    w:node("/objects/hud/over").c.hidden = not s.dead
    if s.dead then
      local sc = w:node("/objects/hud/over/score").c
      sc.text[1] = "SCORE " .. math.floor(s.score)
      sc.xform.x = -#sc.text[1] * 8                  -- (centred: size 2, 16 px a letter)
    end
  end
end)

w:spawn("/systems", { order = { "input", "play", "draw" } })
w:spawn("/systems/input", { system = input })
w:spawn("/systems/play", { system = play })
w:spawn("/systems/draw", { system = draw })
return w

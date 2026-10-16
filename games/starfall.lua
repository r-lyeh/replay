-- STARFALL: a shoot'em up for Replay, in one file.
-- Run with: replay games/starfall.lua
-- Fly the orange ship with the mouse (it follows the pointer, with some
-- weight), hold the left button to fire. Waves of blue ships come in, then a
-- boss made of rocks. What it plays is a stage file: its bullet patterns,
-- its ships, its waves, the boss's phases and the size of the play field
-- (games/common/starfall.bullets, made with the bullet editor: plugins/bullets).
-- Another stage: /data/rules' `stage` (a .bullets of games/common/). The
-- waves and the boss run as runtime/bullets.lua's stage says (the editor's
-- preview runs the same); this file adds the player, the shots, the damage
-- and the looks. The art is the asteroids game's, in games/common/.
-- Also: a gamepad (left stick flies, A / RT fire), or WASD / arrows and SPACE.
-- Only the small core in the ship's middle is hit by bullets.
local ecs = require("ecs")
local w = ecs.world()

local STAGE = "starfall.bullets"                   -- (the stage played: change it here, or /data/rules.stage in the tree)
local d0 = w:bullets(STAGE)
local field = d0 and d0:field() or { w = 800, h = 600 }
local FW, FH = field.w, field.h                    -- (the window: the stage's play field)

w:spawn("/config", { window = { w = FW, h = FH, title = "STARFALL", mouse = true, cursor = false } })
w:spawn("/data/rules", { stage = STAGE, w = FW, h = FH })
w:spawn("/data/state", {
  t = 0, score = 0, lives = 3, mode = "play",      -- mode: play, won, over
  x = 0, y = FH / 2 - 80, vx = 0, vy = 0, safe = 2, cool = 0, seed = 20261022,
  held = {}, taps = {}, use_pad = false,
  shots = {}, fx = {}, banner = "", banner_t = 0,
})

-- the screen, back to front (/data/layers): the sky, the enemy ships, the boss, our shots,
-- the bullets, our ship (on top of it all: always in sight), the HUD
w:spawn("/data/layers", { order = { "sky", "enemies", "boss", "shots", "bullets", "player", "front" } })
w:spawn("/objects/sky", { layer = "sky" })
local SKY = { "/assets/space.png", w = FW, h = FH, color = { 150, 150, 190, 255 } }
w:spawn("/objects/sky/a", { xform = { x = 0, y = 0 }, image = SKY })
w:spawn("/objects/sky/b", { xform = { x = 0, y = -FH, sy = -1 }, image = SKY })   -- (upside down: its edges meet the others')
w:spawn("/objects/sky/c", { xform = { x = 0, y = -2 * FH }, image = SKY })
w:spawn("/objects/sky/stars", { bullets = { size = 2, xy = {} } })
w:spawn("/objects/boss", { xform = { x = 0, y = -FH, r = 0 }, hidden = true, layer = "boss",   -- (a glow behind it; its parts drawn by name: arms, bits, core, eyes)
                          bullets = { "/assets/spark.png", size = 330, xy = { 0, 0 }, color = { 255, 60, 40, 90 } } })
w:spawn("/objects/boss/core", { xform = { x = 0, y = 0, r = 0 }, image = { "/assets/rocks/big.png", w = 150, h = 150, color = { 255, 255, 255, 255 } } })
for i = 1, 7 do                                    -- its body: rocks round the core, and smaller ones further out
  w:spawn("/objects/boss/arm" .. i, { xform = { x = 0, y = 0, r = 0 }, image = { "/assets/rocks/medium.png", w = 70, h = 70, color = { 255, 255, 255, 255 } } })
end
for i = 1, 11 do
  w:spawn("/objects/boss/bit" .. string.format("%02d", i), { xform = { x = 0, y = 0, r = 0 }, image = { "/assets/rocks/small.png", w = 38, h = 38, color = { 255, 255, 255, 255 } } })
end
w:spawn("/objects/boss/eyes", { xform = { x = 0, y = 0 }, bullets = { "/assets/spark.png", size = 22, xy = { -26, -18, 26, -18 }, color = { 255, 70, 60, 255 } } })
w:spawn("/objects/ship", { xform = { x = 0, y = FH / 2 - 80, r = 0 }, layer = "player", image = { "/assets/ship.png", w = 46, h = 46, color = { 255, 170, 90, 255 } } })
w:spawn("/objects/ship/flame", { xform = { x = 0, y = 30, sx = 1, sy = 1 }, image = { "/assets/flame.png", w = 18, h = 28, color = { 255, 255, 255, 220 } } })
w:spawn("/objects/ship/core", { xform = { x = 0, y = 2 }, color = { 255, 255, 255 }, circle = { r = 4, fill = true } })
w:spawn("/objects/shots", { layer = "shots", bullets = { "/assets/shot.png", size = 14, xy = {}, color = { 255, 210, 140, 255 } } })
w:spawn("/objects/bullets", { layer = "bullets" })
w:spawn("/objects/bullets/dots", { bullets = { xy = {} } })                       -- (every enemy bullet: a round dot, its colour,
w:spawn("/objects/bullets/glint", { bullets = { xy = {}, color = { 255, 255, 255, 230 } } })   --  a white glint on it: always easy to see)
w:spawn("/objects/sparks", { layer = "bullets", bullets = { "/assets/spark.png", size = 10, xy = {} } })

local L, T = -FW / 2 + 12, -FH / 2 + 10            -- (the HUD: from the top left corner)
w:spawn("/objects/hud", { layer = "front" })
w:spawn("/objects/hud/score", { xform = { x = L, y = T }, color = { 255, 230, 140 }, text = { "SCORE 0", size = 2 } })
w:spawn("/objects/hud/lives", { xform = { x = FW / 2 - 150, y = T }, color = { 255, 170, 90 }, text = { "SHIPS 3", size = 2 } })
w:spawn("/objects/hud/wave", { xform = { x = L, y = T + 24 }, color = { 140, 160, 200 }, text = "WAVE 1" })
w:spawn("/objects/hud/bossbar", { xform = { x = 0, y = T + 44 }, color = { 60, 20, 30, 200 }, rect = { w = 500, h = 8, fill = true }, hidden = true })
w:spawn("/objects/hud/bossbar/fill", { xform = { x = 0, y = 0 }, color = { 255, 80, 110 }, rect = { w = 500, h = 8, fill = true } })
w:spawn("/objects/hud/banner", { xform = { x = 0, y = -40 }, color = { 255, 240, 220 }, text = { "", size = 3 } })
w:spawn("/objects/hud/sub", { xform = { x = 0, y = 0 }, color = { 160, 175, 210 }, text = "" })

-- input: keys held, and the presses since the game last looked
local input = ecs.system(function()
  return { on_key = function(w, key, down)
    local s = w:node("/data/state").c
    local was = s.held[key]
    s.held[key] = down or nil
    if down and not was then s.taps[key] = true end
  end }
end)

local play = ecs.system(function()
  local FIRE = { space = true, ["pad a"] = true, ["pad rt"] = true, z = true }
  local AGAIN = { space = true, ["return"] = true, r = true, ["pad a"] = true, ["pad start"] = true }
  local function any(h, set) for k in pairs(set) do if h[k] then return true end end return false end
  local function rand(s) s.seed = (s.seed * 16807) % 2147483647; return s.seed / 2147483647 end
  local function boom(s, x, y, n, rgb, size, speed)  -- sparks flying out
    for _ = 1, n do
      local a, v = rand(s) * math.pi * 2, (0.3 + rand(s)) * (speed or 160)
      local life = 0.35 + rand(s) * 0.45
      s.fx[#s.fx + 1] = { x = x, y = y, vx = math.cos(a) * v, vy = math.sin(a) * v, life = life, max = life, size = size or 10, rgb = rgb }
    end
  end
  local function banner(s, text, secs) s.banner, s.banner_t = text, secs or 2 end
  local function reset(s, d, R)
    s.t, s.score, s.lives, s.mode = 0, 0, 3, "play"
    s.x, s.y, s.vx, s.vy, s.safe, s.cool = 0, R.h / 2 - 80, 0, 0, 2, 0
    s.shots, s.fx, s.msg = {}, {}, nil
    s.sg = d:stage_new(20261022)                     -- (the stage: its ships, the boss, their bullets)
    banner(s, "STAGE 1", 2)
  end
  local function hurt(s, d)                          -- our core was hit
    if s.safe > 0 or s.mode ~= "play" then return end
    s.lives = s.lives - 1
    boom(s, s.x, s.y, 40, 0xffaa5a, 14, 260)
    d:clear(s.sg.bul, 0.8)                           -- (a breather: the bullets on screen fade away, harmless)
    if s.lives <= 0 then s.mode = "over"; banner(s, "GAME OVER", 1e9); s.msg = "CLICK OR SPACE TO PLAY AGAIN"
    else s.safe = 2.5 end
  end
  return function(w, dt)
    local s, R = w:node("/data/state").c, w:node("/data/rules").c
    local d, err = w:bullets(R.stage)
    if not d then s.msg = tostring(R.stage) .. ": " .. tostring(err) return end
    if not s.sg then reset(s, d, R) end
    local sg = s.sg
    dt = math.min(dt, 1 / 30)
    local taps = s.taps
    s.taps = {}
    local m, pad = w.mouse, w.pads and w.pads[1]
    local click = m and m.left and not s.was_down
    s.was_down = m and m.left or false
    if s.mode ~= "play" and (click or any(taps, AGAIN)) then reset(s, d, R); sg = s.sg end
    s.t = s.t + dt
    s.safe = math.max(0, s.safe - dt)
    s.banner_t = s.banner_t - dt

    -- the ship: to the mouse (a spring: it speeds up and slows down by itself),
    -- or flown by the stick / the keys (accelerated toward the speed asked)
    local h = s.held
    local kx = (h.right or h.d or h["pad dpright"] or h["pad right"]) and 1 or ((h.left or h.a or h["pad dpleft"] or h["pad left"]) and -1 or 0)
    local ky = (h.down or h.s or h["pad dpdown"] or h["pad down"]) and 1 or ((h.up or h.w or h["pad dpup"] or h["pad up"]) and -1 or 0)
    local sx, sy = pad and pad.lx or 0, pad and pad.ly or 0
    if sx ~= 0 or sy ~= 0 or kx ~= 0 or ky ~= 0 then s.use_pad = true end
    if m and m.inside and (m.left or (s.mx and (math.abs(m.x - s.mx) + math.abs(m.y - s.my)) > 2)) then s.use_pad = false end
    if m then s.mx, s.my = m.x, m.y end
    if s.mode ~= "over" then
      if s.use_pad or not (m and m.inside) then
        local ax, ay = sx ~= 0 and sx or kx, sy ~= 0 and sy or ky
        local k = 1 - math.exp(-10 * dt)
        s.vx, s.vy = s.vx + (ax * 430 - s.vx) * k, s.vy + (ay * 430 - s.vy) * k
      else
        local ax, ay = (m.x - s.x) * 90 - s.vx * 17, (m.y - s.y) * 90 - s.vy * 17   -- (stiff, damped: no overshoot)
        s.vx, s.vy = s.vx + ax * dt, s.vy + ay * dt
      end
      local sp = math.sqrt(s.vx * s.vx + s.vy * s.vy)
      if sp > 700 then s.vx, s.vy = s.vx / sp * 700, s.vy / sp * 700 end
      s.x = math.max(-R.w / 2 + 20, math.min(R.w / 2 - 20, s.x + s.vx * dt))
      s.y = math.max(-R.h / 2 + 30, math.min(R.h / 2 - 20, s.y + s.vy * dt))
    end

    -- firing: two shots ten times a second while held; they hurt the ships and the boss
    s.cool = s.cool - dt
    local firing = (m and m.left) or any(h, FIRE) or (pad and (pad.rt or 0) > 0.3)
    if firing and s.cool <= 0 and s.mode == "play" then
      s.cool = 0.1
      s.shots[#s.shots + 1] = { x = s.x - 9, y = s.y - 20 }
      s.shots[#s.shots + 1] = { x = s.x + 9, y = s.y - 20 }
    end
    local keep, b = 0, sg.boss
    for i = 1, #s.shots do
      local sh = s.shots[i]
      sh.y = sh.y - 900 * dt
      local alive = sh.y > -R.h / 2 - 20
      for _, e in ipairs(sg.ships) do
        if alive and e.hp > 0 and (sh.x - e.x) ^ 2 + (sh.y - e.y) ^ 2 < (e.size * 0.45) ^ 2 then
          e.hp, e.hit, alive = e.hp - 1, 0.08, false
          boom(s, sh.x, sh.y, 3, 0xffd890, 6, 120)
        end
      end
      if alive and b and b.hp > 0 and b.in_ and (sh.x - b.x) ^ 2 + (sh.y - b.y) ^ 2 < (b.size * 0.62) ^ 2 then
        b.hp, b.hit, alive = b.hp - 1, 0.06, false
        s.score = s.score + 5
        boom(s, sh.x, sh.y, 2, 0xc8b8a8, 7, 140)
      end
      if alive then keep = keep + 1; s.shots[keep] = sh end
    end
    for i = #s.shots, keep + 1, -1 do s.shots[i] = nil end
    for i = #sg.ships, 1, -1 do                      -- ships shot down; ships that ram us
      local e = sg.ships[i]
      if e.hp > 0 and s.safe <= 0 and (e.x - s.x) ^ 2 + (e.y - s.y) ^ 2 < (e.size * 0.4) ^ 2 then e.hp = 0; hurt(s, d) end
      if e.hp <= 0 then
        local def = d:enemy(e.kind)
        s.score = s.score + (def and def.score or 100)
        boom(s, e.x, e.y, 24, 0x7ad0ff, 12, 220)
        d:stage_kill(sg, i)
      end
    end

    -- the stage: the waves, the boss (what happened: banners and sparks)
    for _, ev in ipairs(d:stage_step(sg, dt, s.x, s.y)) do
      if ev[1] == "boss" then banner(s, "WARNING", 2.5)
      elseif ev[1] == "phase" and ev[3] > 0 then boom(s, sg.boss.x, sg.boss.y, 50, 0xff8a60, 16, 300); banner(s, "PHASE " .. ev[2], 1.2)
      elseif (ev[1] == "beaten" or ev[1] == "done") and s.mode == "play" then
        if b then
          for k = 1, 6 do boom(s, b.x + (rand(s) - 0.5) * 160, b.y + (rand(s) - 0.5) * 160, 40, k % 2 == 0 and 0xffb060 or 0xc8b8a8, 16, 320) end
          s.score = s.score + (d.boss and d.boss.score or 5000)
        end
        s.score = s.score + s.lives * 1000
        s.mode = "won"
        banner(s, "STAGE CLEAR", 1e9)
        s.msg = "CLICK OR SPACE TO PLAY AGAIN"
      end
    end
    b = sg.boss
    if b and b.hp > 0 then                           -- (its rocks turn faster as it weakens: angles go on from where they are)
      local rage = math.max(1, b.phase)
      b.spin1 = (b.spin1 or 0) + (0.45 + rage * 0.15) * dt
      b.spin2 = (b.spin2 or 0) - (0.3 + rage * 0.1) * dt
      if b.in_ and s.safe <= 0 and (b.x - s.x) ^ 2 + (b.y - s.y) ^ 2 < (b.size * 0.55) ^ 2 then hurt(s, d) end
    end

    -- bullets hit our core (the small dot); sparks fly
    if s.mode == "play" and s.safe <= 0 and d:hit(sg.bul, s.x, s.y + 2, 4) then hurt(s, d) end
    for i = #s.fx, 1, -1 do
      local f = s.fx[i]
      f.life = f.life - dt
      f.x, f.y = f.x + f.vx * dt, f.y + f.vy * dt
      f.vx, f.vy = f.vx * (1 - 2 * dt), f.vy * (1 - 2 * dt)
      if f.life <= 0 then table.remove(s.fx, i) end
    end
  end
end)

local draw = ecs.system(function()
  local function tint(w, node, base, hurt)
    local c = w:node(node).c.image.color
    local k = hurt and 0.35 or 0                     -- (hit: a little lighter, not a white flicker)
    c[1], c[2], c[3] = math.floor(base[1] + (255 - base[1]) * k), math.floor(base[2] + (255 - base[2]) * k), math.floor(base[3] + (255 - base[3]) * k)
  end
  return function(w, dt)
    local s, R = w:node("/data/state").c, w:node("/data/rules").c
    local d = w:bullets(R.stage)
    local sg = s.sg or {}
    -- the sky scrolls; stars at three depths
    local off = (s.t * 40) % (2 * R.h)
    w:node("/objects/sky/a").c.xform.y = off
    w:node("/objects/sky/b").c.xform.y = off - R.h
    w:node("/objects/sky/c").c.xform.y = off - 2 * R.h
    local st = w:node("/objects/sky/stars").c.bullets
    st.xy, st.s, st.rgb = st.xy or {}, st.s or {}, st.rgb or {}
    for i = 1, 90 do
      local depth = 1 + i % 3
      st.xy[i * 2 - 1] = (i * 137.5) % R.w - R.w / 2
      st.xy[i * 2] = ((i * 73.7) + s.t * 30 * depth) % R.h - R.h / 2
      st.s[i], st.rgb[i] = depth, depth == 3 and 0xe8f0ff or depth == 2 and 0x9fb4e0 or 0x5a6a90
    end
    -- the ship
    local ship = w:node("/objects/ship").c
    ship.xform.x, ship.xform.y = s.x, s.y
    ship.xform.r = math.max(-0.35, math.min(0.35, s.vx / 1400))
    ship.hidden = s.mode == "over" or (s.safe > 0 and math.floor(s.t * 14) % 2 == 0)
    local fl = w:node("/objects/ship/flame").c
    local thrust = math.max(0.4, math.min(1.4, 0.7 - s.vy / 600))
    fl.xform.sy, fl.xform.sx = thrust, 0.8 + math.sin(s.t * 40) * 0.1
    fl.xform.y = 22 + 10 * thrust
    -- shots, enemy bullets, sparks
    local sh = w:node("/objects/shots").c.bullets
    sh.xy = {}
    for i, p in ipairs(s.shots) do                   -- (a shot: two glows, one behind the other: a streak)
      sh.xy[i * 4 - 3], sh.xy[i * 4 - 2], sh.xy[i * 4 - 1], sh.xy[i * 4] = p.x, p.y, p.x, p.y + 9
    end
    if d and sg.bul then
      local dots = { xy = {}, s = {}, rgb = {}, o = {} }
      local glint = w:node("/objects/bullets/glint").c.bullets
      glint.xy, glint.s, glint.o = {}, {}, {}
      local n = 0
      for _, c in pairs(d:look(sg.bul)) do           -- (whatever sprite a pattern asks for: dots here, at least 11 px)
        for i = 1, #c.s do
          n = n + 1
          local size = math.max(11, c.s[i])
          dots.xy[n * 2 - 1], dots.xy[n * 2] = c.xy[i * 2 - 1], c.xy[i * 2]
          dots.s[n], dots.rgb[n], dots.o[n] = size, c.rgb[i], c.o[i]
          glint.xy[n * 2 - 1], glint.xy[n * 2] = c.xy[i * 2 - 1], c.xy[i * 2]
          glint.s[n], glint.o[n] = size * 0.45, c.o[i]
        end
      end
      w:node("/objects/bullets/dots").c.bullets = dots
    end
    local sp = w:node("/objects/sparks").c.bullets
    sp.xy, sp.s, sp.rgb = {}, {}, {}
    for i, f in ipairs(s.fx) do
      sp.xy[i * 2 - 1], sp.xy[i * 2] = f.x, f.y
      sp.s[i] = f.size * (f.life / f.max)
      sp.rgb[i] = f.rgb
    end
    -- the enemies: one node each, in /entities
    local seen = {}
    for _, e in ipairs(sg.ships or {}) do
      local path = "/entities/enemies/" .. e.id
      seen[path] = true
      local n = w:node(path) or w:spawn(path, { layer = "enemies", xform = { x = e.x, y = e.y, r = math.pi },
                                                image = { "/assets/ship.png", w = e.size, h = e.size, color = { 120, 200, 255, 255 } } })
      n.c.xform.x, n.c.xform.y = e.x, e.y
      local c = n.c.image.color
      if (e.hit or 0) > 0 then c[1], c[2], c[3] = 255, 255, 255 else c[1], c[2], c[3] = 120, 200, 255 end
    end
    if w:node("/entities/enemies") then
      for _, ch in ipairs(w:children("/entities/enemies")) do if not seen[ch.path] then w:remove(ch.path) end end
    end
    -- the boss: a living pile of rocks
    local b = sg.boss
    local bn = w:node("/objects/boss").c
    bn.hidden = not (b and b.hp > 0)
    if b and b.hp > 0 then
      bn.xform.x, bn.xform.y = b.x, b.y
      local t, hurt, rage = b.t, b.hit > 0, math.max(1, b.phase or 1)
      bn.xform.s = 1 + math.sin(t * 1.6) * 0.035      -- (it breathes, slowly)
      bn.bullets.color[4] = 60 + rage * 30 + math.floor(math.sin(t * 1.6) * 20)
      w:node("/objects/boss/core").c.xform.r = t * 0.15
      tint(w, "/objects/boss/core", { 230, 200 - rage * 25, 190 - rage * 30 }, hurt)
      for i = 1, 7 do
        local a = (b.spin1 or 0) + i / 7 * math.pi * 2
        local r = 78 + math.sin(t * 1.1 + i) * 6
        local n = w:node("/objects/boss/arm" .. i).c
        n.xform.x, n.xform.y, n.xform.r = math.cos(a) * r, math.sin(a) * r * 0.85, -t * 0.5 + i
        tint(w, "/objects/boss/arm" .. i, { 210, 190, 180 }, hurt)
      end
      for i = 1, 11 do
        local a = (b.spin2 or 0) + i / 11 * math.pi * 2
        local r = 122 + math.sin(t * 1.3 + i * 1.7) * 10
        local key = "/objects/boss/bit" .. string.format("%02d", i)
        local n = w:node(key).c
        n.xform.x, n.xform.y, n.xform.r = math.cos(a) * r, math.sin(a) * r * 0.8, t * 0.7 + i
        n.xform.s = 0.85 + 0.12 * math.sin(t * 1.5 + i)
        tint(w, key, { 180, 165, 160 }, hurt)
      end
      w:node("/objects/boss/eyes").c.bullets.size = 18 + math.sin(t * 2.5) * 3 + rage * 3
    end
    -- the HUD
    w:node("/objects/hud/score").c.text[1] = "SCORE " .. math.floor(s.score)
    w:node("/objects/hud/lives").c.text[1] = "SHIPS " .. math.max(0, s.lives)
    w:node("/objects/hud/wave").c.text = sg.mode == "waves" and ("WAVE " .. math.max(1, sg.wave or 0) .. " / " .. (d and #d.waves or 0))
                                         or (sg.mode == "boss" and "BOSS" or "")
    w:node("/objects/hud/bossbar").c.hidden = not (b and b.hp > 0 and b.in_)
    if b then
      local f = w:node("/objects/hud/bossbar/fill").c
      f.rect.w = math.max(0, 500 * b.hp / b.max)
      f.xform.x = -(500 - f.rect.w) / 2
    end
    local bt = w:node("/objects/hud/banner").c
    bt.text[1] = s.banner_t > 0 and s.banner or ""
    bt.xform.x = -#bt.text[1] * 12                   -- (centred: size 3, 24 px a letter)
    local sub = w:node("/objects/hud/sub").c
    sub.text = s.msg or ""
    sub.xform.x = -#sub.text * 4
  end
end)

w:spawn("/systems", { order = { "input", "play", "draw" } })
w:spawn("/systems/input", { system = input })
w:spawn("/systems/play", { system = play })
w:spawn("/systems/draw", { system = draw })
return w

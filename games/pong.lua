-- pong.lua
-- Pong as ONE file: a script that builds the world and returns it.
--   play.exe games\pong.lua
--
-- games\pong\ is the very same game as a FOLDER of data files: every node is
-- a folder and every component a small .lua file (objects/ball/vel.lua
-- holds `return { x = 260, y = 90 }`). Compare them side by side:
--
--   one file (this)                            folder (games\pong\)
--   w:spawn("/objects/ball", { vel = ... })    objects/ball/vel.lua
--   local ball = ecs.system(function()         systems/ball/system.lua
--   w:spawn("/systems", { order = { ... } })   systems/order.lua
--
-- The tree: /data rules and state, /classes components' defaults, /objects
-- what you see (saved), /systems the code (one per node, run in /systems'
-- order), /entities what is spawned while playing (none in pong), /tmp
-- scratch (never saved).
--
-- One file is easy to read top to bottom, share and diff. A folder lets the
-- editor (and other peers) change one tiny piece at a time, and every piece
-- shows up as a file you can open. In the editor both behave the same; Save
-- writes a script world's edits next to it, in pong.overrides.lua.
--
-- Press play, then ESC to give the keyboard to the game:
-- W / S move the left paddle; the right one is played by the computer,
-- until player 2 joins (the Players button: 2): then W / S in its view.
--
-- Two players over a network, and the game doesn't know: for it, both are
-- local (on_key says who pressed, w.players who is in). What travels is
-- tagged: the host decides everything (`replicate = true`, `by = 1`);
-- player 2's keys go to it as numbered commands (`{ by = 2, cmd = true }`);
-- each paddle is driven by its player's keys (`input = N`): its player moves
-- it at once and replays its keys on the host's states, the other sees it a
-- little late and smoothly (`interp`). The ball is predicted (`predict`):
-- every player simulates it, the host's state corrects the guess.
-- See docs/NETWORK.md.

local ecs = require("ecs")
local w = ecs.world()

-- classes: a component's members (type, value...); w:spawn fills them in -----
w:spawn("/classes/paddle", {
  player = { type = "int", value = 1, min = 1, max = 2 },
  up     = { type = "string", value = "w", options = { "w", "up", "i" } },
  down   = { type = "string", value = "s", options = { "s", "down", "k" } },
})

-- rules: tuning ----------------------------------------------------------------
w:spawn("/data/rules", {
  arena         = { h = 400, w = 600 },
  win           = 7,
  serve_speed   = 260,
  speedup       = 1.06,
  max_speed     = 720,
  english       = 4,
  paddle_speed  = 340,
  ai_speed      = 230,
  restart_after = 5,
})

-- state: plain data, so it saves, rewinds and replicates ------------------------
w:spawn("/data/score", { left = 0, right = 0, serve = 1, over = false, wait = 0, replicate = true })
w:spawn("/data/input/p1", { held = {}, replicate = 1 })   -- keys each player holds down (/systems/input)
w:spawn("/data/input/p2", { held = {}, replicate = { by = 2, cmd = true } })

-- objects: what you see ----------------------------------------------------------
w:spawn("/objects/left", {
  xform = { x = -280 },
  color = { 120, 220, 255 },
  rect = { fill = true, h = 72, w = 12 },
  paddle = { player = 1, down = "s", up = "w" },
  replicate = { by = 1, input = 1, interp = true },   -- (the host's; its player's keys drive it: shown to the others a little late)
})
w:spawn("/objects/right", {
  xform = { x = 280 },
  color = { 255, 150, 90 },
  rect = { fill = true, h = 72, w = 12 },
  paddle = { player = 2, down = "s", up = "w" },
  replicate = { by = 1, input = 2, interp = true },   -- (player 2's keys drive it while it plays, else the computer)
})
w:spawn("/objects/ball", {
  xform = { x = 0, y = 0 },
  color = { 240, 240, 240 },
  circle = { fill = true, r = 7 },
  vel = { x = 260, y = 90 },
  replicate = { by = 1, predict = true, snap = 40 },   -- (a serve, a bounce: at once)
})
w:spawn("/objects/field/top", {
  xform = { y = -203 },
  color = { 90, 96, 120 },
  rect = { fill = true, h = 6, w = 610 },
})
w:spawn("/objects/field/bottom", {
  xform = { y = 203 },
  color = { 90, 96, 120 },
  rect = { fill = true, h = 6, w = 610 },
})
w:spawn("/objects/field/net", { color = { 60, 64, 80 }, rect = { fill = true, h = 400, w = 2 } })
w:spawn("/objects/hud/left", {
  xform = { x = -70, y = -185 },
  color = { 120, 220, 255 },
  text = { "0", size = 4 },
})
w:spawn("/objects/hud/right", {
  xform = { x = 46, y = -185 },
  color = { 255, 150, 90 },
  text = { "0", size = 4 },
})
w:spawn("/objects/hud/help", {
  xform = { x = -176, y = 216 },
  color = { 90, 96, 120 },
  text = "W / S move; the computer plays until player 2 joins",
})
w:spawn("/objects/hud/banner", {
  xform = { x = 0, y = -12 },
  color = { 240, 240, 240 },
  text = { "", size = 3 },
  hidden = true,
})
w:spawn("/objects/hud/banner/countdown", {
  xform = { x = 0, y = 34 },
  color = { 150, 155, 175 },
  text = { "", size = 1 },
})

-- systems -------------------------------------------------------------------
-- Each one is real code: ecs.system() keeps the body of the function as a
-- code leaf (it saves, rewinds and hot-swaps like any other component).
-- The body runs on its own: it can't use locals from outside it.
-- In the folder version each body is a file: systems/<name>/system.lua

local input = ecs.system(function()
  -- input: remember which keys each player holds (data, so it saves, rewinds
  -- and replicates like everything else). The viewer sends every key while
  -- playing, and who pressed it.
  return { on_key = function(w, key, down, player)
    local me = w:node("/data/input/p" .. (player or 1))
    if not me then return end                        -- (players 3, 4: watching)
    me.c.held[key] = down or nil
    local PAD = { ["pad dpup"] = "w", ["pad up"] = "w", ["pad dpdown"] = "s", ["pad down"] = "s" }   -- (a gamepad: dpad / stick)
    if PAD[key] then me.c.held[PAD[key]] = down or nil end
  end }
end)

local paddles = ecs.system(function()
  -- paddles: move with their player's up/down keys, or follow the ball while
  -- that player isn't in the game (the computer plays it). Kept inside the
  -- arena. Runs before the ball (see /systems' order), so the ball always collides
  -- with where the paddles are this tick.
  return { requires = { "xform", "paddle", "rect" }, run = function(w, n, dt)
    local rules = w:node("/data/rules").c
    local x, p = n.c.xform, n.c.paddle
    local input = w:node("/data/input/p" .. (p.player or 1))
    local held = input and input.c.held or {}
    local dy = 0
    if not (w.players or { true })[p.player or 1] then
      local ball = w:node("/objects/ball").c
      local coming = (ball.vel.x > 0) == (x.x > 0)    -- the ball is heading this way
      local target = coming and ball.xform.y or 0
      local d = target - (x.y or 0)
      local step = rules.ai_speed * dt
      dy = math.max(-step, math.min(step, d))
    else
      if held[p.up] then dy = dy - rules.paddle_speed * dt end
      if held[p.down] then dy = dy + rules.paddle_speed * dt end
    end
    local lim = rules.arena.h / 2 - n.c.rect.h / 2
    x.y = math.max(-lim, math.min(lim, (x.y or 0) + dy))
  end }
end)

local ball = ecs.system(function()
  -- ball: moves, bounces off the top and bottom, off the paddles (faster each
  -- hit, angled by where it hits), and scores when it leaves the arena.
  -- Collisions are swept (see move): no tunnelling at high speed or x4.
  local function serve(w, ball, rules, score)
    score.serve = -score.serve                       -- alternate sides
    local up = (score.left + score.right) % 2 == 0 and 1 or -1
    ball.xform.x, ball.xform.y = 0, 0
    ball.vel.x = rules.serve_speed * score.serve
    ball.vel.y = rules.serve_speed * 0.35 * up
  end

  -- Swept collision: the ball moves along a segment each tick. Find the first
  -- thing that segment hits (top/bottom wall, the front face of a paddle,
  -- both pushed out by the ball's radius), bounce at that exact point, and
  -- spend the rest of the move from there. Exact at any speed or dt.
  local function hit_paddle(v, rules, x, p, py, ph)
    local speed = math.min(math.sqrt(v.x * v.x + v.y * v.y) * rules.speedup, rules.max_speed)
    local off = (x.y - py) / ph                      -- -1 top edge .. 1 bottom edge
    v.x = -v.x
    v.y = v.y + off * rules.english * 60
    local k = speed / math.sqrt(v.x * v.x + v.y * v.y)
    v.x, v.y = v.x * k, v.y * k
    -- at most 60 degrees from horizontal: the ball must keep crossing the field
    local minx = speed * 0.5
    if math.abs(v.x) < minx then
      v.x = (v.x < 0 and -1 or 1) * minx
      v.y = (v.y < 0 and -1 or 1) * math.sqrt(speed * speed - minx * minx)
    end
  end

  local function move(w, x, v, r, rules, dt)
    local hh = rules.arena.h / 2
    local paddles = w:query("paddle", "xform", "rect")
    for _ = 1, 8 do                                  -- a few bounces per tick at most
      local t, what, pad = dt, nil, nil
      -- walls
      if v.y < 0 then
        local tw = (-hh + r - x.y) / v.y
        if tw < t then t, what = math.max(0, tw), "wall" end
      elseif v.y > 0 then
        local tw = (hh - r - x.y) / v.y
        if tw < t then t, what = math.max(0, tw), "wall" end
      end
      -- paddles: the face the ball is moving toward
      for _, p in ipairs(paddles) do
        local px, py = p.c.xform.x, p.c.xform.y or 0
        local pw, ph = p.c.rect.w / 2, p.c.rect.h / 2
        local dir = px > x.x and 1 or -1             -- the paddle is to the right (1) or left
        if v.x * dir > 0 then
          local face = px - dir * (pw + r)
          local tp = (face - x.x) / v.x
          if tp < 0 and math.abs(x.x - px) < pw + r then tp = 0 end   -- already touching
          if tp >= 0 and tp < t then
            local y = x.y + v.y * tp
            if math.abs(y - py) <= ph + r then t, what, pad = tp, "paddle", { p, py, ph, face } end
          end
        end
      end
      x.x, x.y = x.x + v.x * t, x.y + v.y * t        -- to the impact (or the whole way)
      dt = dt - t
      if what == "wall" then v.y = -v.y
      elseif what == "paddle" then
        x.x = pad[4]
        hit_paddle(v, rules, x, pad[1], pad[2], pad[3])
      else break end
      if dt <= 0 then break end
    end
  end

  return { requires = { "xform", "vel", "circle" }, run = function(w, n, dt)
    local rules, score = w:node("/data/rules").c, w:node("/data/score").c
    if score.over then return end                    -- game over: the ball waits (banner.lua)
    local x, v, r = n.c.xform, n.c.vel, n.c.circle.r
    move(w, x, v, r, rules, dt)

    local hw = rules.arena.w / 2
    local side = x.x < -hw - 20 and "right" or x.x > hw + 20 and "left" or nil
    if side then
      score[side] = score[side] + 1
      if score[side] >= rules.win then               -- game over: banner.lua shows it,
        score.over = side                            -- a key (or the timer) starts again
        score.wait = 0
        dd.log(side .. " wins " .. score.left .. " - " .. score.right)
      end
      serve(w, n.c, rules, score)
    end
  end }
end)

local score = ecs.system(function()
  -- score: the HUD shows the score
  return function(w, dt)
    local s = w:node("/data/score").c
    w:node("/objects/hud/left").c.text[1] = tostring(s.left)
    w:node("/objects/hud/right").c.text[1] = tostring(s.right)
  end
end)

local banner = ecs.system(function()
  -- banner: when the game is over, "left wins 7 - 3" big and centred, in the
  -- winner's colour (its paddle's colour), with a countdown under it. Space,
  -- enter or escape (any player's) or the end of the countdown
  -- (rules.restart_after) plays again.
  local restart = { "space", "return", "keypad enter", "escape", "pad a", "pad start" }
  local function centre(node, text, size)            -- debug font: 8 px per char
    return -#text * 8 * size / 2
  end
  local function pressed(w)                          -- a restart key held, by anyone
    for _, i in ipairs(w:select("/data/input/*")) do
      for _, k in ipairs(restart) do if i.c.held and i.c.held[k] then return true end end
    end
  end

  return function(w, dt)
    local score, rules = w:node("/data/score").c, w:node("/data/rules").c
    local b = w:node("/objects/hud/banner").c
    local t = w:node("/objects/hud/banner/countdown").c
    if not score.over then b.hidden = true return end

    score.wait = (score.wait or 0) + dt
    local left = (rules.restart_after or 5) - score.wait
    if left <= 0 or pressed(w) then                  -- a key, or nobody pressed one: play again
      score.left, score.right, score.over, score.wait = 0, 0, false, 0
      b.hidden = true
      return
    end

    local text = string.format("%s wins %d - %d", score.over, score.left, score.right)
    local size = b.text.size or 3
    b.text[1] = text
    b.xform.x = centre(b, text, size)
    b.xform.y = -60 - 4 * size                       -- above the ball waiting in the middle
    local c = w:node("/objects/" .. score.over).c.color
    b.color = { c[1], c[2], c[3] }
    b.hidden = nil

    local line = string.format("new game in %d", math.ceil(left))
    local ts = t.text.size or 1
    t.text[1] = line
    t.xform.x = centre(t, line, ts) - b.xform.x      -- child of the banner: relative to it
    t.xform.y = 8 * size + 10
  end
end)

local debugdraw = ecs.system(function()   -- not "debug": that would hide the debug library
  -- debug: debugdraw on the dev overlay (nothing in a standalone game):
  -- the ball's velocity and speed, and where each paddle is aiming
  return function(w, dt)
    local b = w:node("/objects/ball").c
    local x, v = b.xform, b.vel
    dd.arrow(x.x, x.y, x.x + v.x * 0.15, x.y + v.y * 0.15, "#ffd04090")
    dd.text(x.x + 10, x.y + 10, string.format("%.0f", math.sqrt(v.x * v.x + v.y * v.y)), { 255, 208, 64, 140 })
    for _, p in ipairs(w:query("paddle", "xform")) do
      if not (w.players or { true })[p.c.paddle.player or 1] then dd.cross(p.c.xform.x, x.y, 5, "#ff965a80") end
    end
  end
end)

-- systems: a node each; /systems' order is the run order (drag them in the tree)
w:spawn("/systems", { order = { "input", "paddles", "ball", "score", "banner", "debug" } })
w:spawn("/systems/input", { system = input })
w:spawn("/systems/paddles", { system = paddles })
w:spawn("/systems/ball", { system = ball })
w:spawn("/systems/score", { system = score })
w:spawn("/systems/banner", { system = banner })
w:spawn("/systems/debug", { system = debugdraw })

return w

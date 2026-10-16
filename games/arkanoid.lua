-- arkanoid.lua
-- Move with A/D or left/right. Press Space to launch or restart.

local ecs = require("ecs")
local w = ecs.world()

local arena = { w = 600, h = 400 }
local paddle_speed = 420
local rows, cols = 5, 10
local brick_w, brick_h, gap = 48, 18, 5

-- Input state ----------------------------------------------------------------

w:spawn("/data/input", { held = {} })
w:spawn("/data/game", {
  score = 0,
  lives = 3,
  started = true,
  over = false,
  bricks_left = rows * cols,
})

local input = ecs.system(function()
  return {
    on_key = function(w, key, down)
      local n = w:node("/data/input")
      if n then n.c.held[key] = down or nil end
    end
  }
end)

-- Playfield ------------------------------------------------------------------

w:spawn("/objects/paddle", {
  xform = { x = 0, y = 165 },
  color = { 110, 210, 255 },
  rect = { fill = true, w = 88, h = 12 },
  paddle = {},
})

w:spawn("/objects/ball", {
  xform = { x = 0, y = 145 },
  color = { 255, 255, 255 },
  circle = { fill = true, r = 7 },
  vel = { x = 120, y = -275 },
})

local colors = {
  { 255, 100, 100 },
  { 255, 170, 80 },
  { 245, 220, 90 },
  { 110, 220, 130 },
  { 120, 170, 255 },
}

local start_x = -((cols * (brick_w + gap) - gap) / 2) + brick_w / 2
for row = 1, rows do
  for col = 1, cols do
    local x = start_x + (col - 1) * (brick_w + gap)
    local y = -75 + (row - 1) * (brick_h + gap)
    w:spawn("/objects/bricks/" .. row .. "/" .. col, {
      xform = { x = x, y = y },
      color = colors[row],
      rect = { fill = true, w = brick_w, h = brick_h },
      brick = { broken = false },
    })
  end
end

w:spawn("/objects/hud/score", {
  xform = { x = -280, y = -185 },
  color = { 240, 240, 240 },
  text = { "Score: 0", size = 2 },
})

w:spawn("/objects/hud/lives", {
  xform = { x = 180, y = -185 },
  color = { 240, 240, 240 },
  text = { "Lives: 3", size = 2 },
})

w:spawn("/objects/hud/message", {
  xform = { x = -100, y = 30 },
  color = { 255, 255, 255 },
  text = { "", size = 3 },
  hidden = true,
})

-- Systems --------------------------------------------------------------------

local move_paddle = ecs.system(function()
  return {
    requires = { "xform", "paddle", "rect" },
    run = function(w, n, dt)
      local held = w:node("/data/input").c.held
      local x = n.c.xform
      local half = n.c.rect.w / 2
      local direction = 0

      if held.a or held.left then direction = direction - 1 end
      if held.d or held.right then direction = direction + 1 end

      x.x = x.x + direction * 420 * dt
      x.x = math.max(-300 + half, math.min(300 - half, x.x))
    end
  }
end)

local ball_system = ecs.system(function()
  local ball_speed = 300
  local function reset_ball(w)
    local ball = w:node("/objects/ball").c
    local paddle = w:node("/objects/paddle").c
    ball.xform.x, ball.xform.y = paddle.xform.x, 145
    ball.vel.x, ball.vel.y = 120, -275
  end

  return {
    requires = { "xform", "vel", "circle" },
    run = function(w, n, dt)
      local game = w:node("/data/game").c
      local held = w:node("/data/input").c.held
      local ball, paddle = n.c, w:node("/objects/paddle").c
      local x, v, r = ball.xform, ball.vel, ball.circle.r

      if game.over then
        if held.space then
          game.score, game.lives = 0, 3
          game.bricks_left = 50
          game.over, game.started = false, true

          for _, b in ipairs(w:query("brick", "xform", "rect")) do
            b.c.brick.broken = false
            b.c.hidden = nil
          end

          reset_ball(w)
          held.space = nil
        end
        return
      end

      -- Start the next ball after losing a life.
      if not game.started then
        x.x, x.y = paddle.xform.x, 145
        if held.space then
          game.started = true
          held.space = nil
        end
        return
      end

      x.x, x.y = x.x + v.x * dt, x.y + v.y * dt

      -- Side and ceiling walls.
      if x.x - r < -300 then x.x, v.x = -300 + r, math.abs(v.x) end
      if x.x + r > 300 then x.x, v.x = 300 - r, -math.abs(v.x) end
      if x.y - r < -200 then x.y, v.y = -200 + r, math.abs(v.y) end

      -- Paddle collision: only bounce when the ball is travelling downward.
      local px, py = paddle.xform.x, paddle.xform.y
      local pw, ph = paddle.rect.w / 2, paddle.rect.h / 2
      if v.y > 0
        and x.y + r >= py - ph
        and x.y - r <= py + ph
        and x.x + r >= px - pw
        and x.x - r <= px + pw then

        x.y = py - ph - r
        local offset = (x.x - px) / pw
        v.x = offset * 260
        v.y = -math.sqrt(math.max(1, ball_speed * ball_speed - v.x * v.x))
      end

      -- Brick collision. Each brick disappears after its first hit.
      for _, b in ipairs(w:query("brick", "xform", "rect")) do
        local brick = b.c.brick
        if not brick.broken then
          local bx, by = b.c.xform.x, b.c.xform.y
          local bw, bh = b.c.rect.w / 2, b.c.rect.h / 2

          if math.abs(x.x - bx) <= bw + r
            and math.abs(x.y - by) <= bh + r then

            brick.broken = true
            b.c.hidden = true
            game.score = game.score + 10
            game.bricks_left = game.bricks_left - 1

            -- Reflect along the axis with the smaller overlap.
            local ox = bw + r - math.abs(x.x - bx)
            local oy = bh + r - math.abs(x.y - by)
            if ox < oy then
              v.x = -v.x
            else
              v.y = -v.y
            end
            break
          end
        end
      end

      -- Lose a life below the paddle.
      if x.y - r > 200 then
        game.lives = game.lives - 1
        if game.lives <= 0 then
          game.over = true
        else
          game.started = false
          reset_ball(w)
        end
      end

      if game.bricks_left <= 0 then game.over = true end

      w:node("/objects/hud/score").c.text[1] = "Score: " .. game.score
      w:node("/objects/hud/lives").c.text[1] = "Lives: " .. game.lives

      local message = w:node("/objects/hud/message").c
      if game.over then
        message.hidden = nil
        message.text[1] = game.bricks_left <= 0 and "You win!" or "Game over"
      else
        message.hidden = true
      end
    end
  }
end)

w:spawn("/systems", { order = { "input", "paddle", "ball" } })
w:spawn("/systems/input", { system = input })
w:spawn("/systems/paddle", { system = move_paddle })
w:spawn("/systems/ball", { system = ball_system })

return w


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

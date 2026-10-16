-- ball: moves, bounces off the top and bottom, off the paddles (faster each
-- hit, angled by where it hits), and scores when it leaves the arena.
-- Collisions are swept (see move): no tunnelling at high speed or x4.
--
-- Online, the host decides (it owns the ball and the score), and the ball
-- meeting another player's paddle is decided the way that player saw it
-- (lag compensation): their commands reach the host a moment late, so the
-- host notes where and when the ball crossed the paddle's face and waits
-- until that player has seen that moment. Then it asks where their paddle
-- was as they watched it (w.net:as_seen): a hit bounces the ball
-- from there and then, and moves it on to now. Meanwhile the ball isn't
-- sent (replicate.hold): the others keep their guess, which already
-- bounced off their own paddle at once. Only the host scores.
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

-- a paddle another player plays, online, while this world decides for the
-- ball (the host): decided later, as that player saw it
local function later(w, p)
  local who = p.c.paddle.player or 1
  return w.net and w:owns("/objects/ball") and who ~= w.peer and (w.players or {})[who] and true or false
end

local function move(w, x, v, r, rules, dt, crossed)
  local hh = rules.arena.h / 2
  local paddles = {}
  for _, p in ipairs(w:query("paddle", "xform", "rect")) do
    if later(w, p) then                            -- (its face crossed: noted for later; the ball goes on)
      local px, pw = p.c.xform.x, p.c.rect.w / 2
      local dir = px > x.x and 1 or -1
      local face = px - dir * (pw + r)
      local tp = v.x * dir > 0 and (face - x.x) / v.x or -1
      if crossed and tp >= 0 and tp <= dt then crossed(p, tp, face) end
    else paddles[#paddles + 1] = p end
  end
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

-- lag compensation (the host, online): the ball crossed another player's
-- paddle's face at our time `t`; once they have seen that (and we have run
-- the command they gave then), hit or miss: where their paddle was then
local function decide(w, n, rules)
  local pd = n.c.pending
  local p = w:node(pd.path)
  local now = w.net:now()
  local as = p and w.net:as_seen(pd.path, pd.t, n.path)
  if not as and now - pd.t < 1 then return false end      -- (not yet: wait; a second at most)
  as = as or (p and p.c)
  local x, v, r = n.c.xform, n.c.vel, n.c.circle.r
  n.c.pending, n.c.replicate.hold = nil, nil
  if not (as and as.xform and p) then return false end
  local py, ph = as.xform.y or 0, p.c.rect.h / 2
  if math.abs(pd.y - py) > ph + r then return false end   -- a miss: the ball went on (it's there)
  x.x, x.y, v.x, v.y = pd.face, pd.y, pd.vx, pd.vy        -- a hit: back to then and there, bounce,
  hit_paddle(v, rules, x, p, py, ph)
  move(w, x, v, r, rules, now - pd.t)                     -- and on to now
  return true
end

return { requires = { "xform", "vel", "circle" }, run = function(w, n, dt)
  local rules, score = w:node("/data/rules").c, w:node("/data/score").c
  if score.over then return end                    -- game over: the ball waits (banner.lua)
  local x, v, r = n.c.xform, n.c.vel, n.c.circle.r
  if n.c.pending and decide(w, n, rules) then return end
  local t0 = w.net and w.net:now() - dt            -- (the tick's start, our clock)
  move(w, x, v, r, rules, dt, not n.c.pending and function(p, tp, face)
    n.c.pending = { path = p.path, t = t0 + tp, face = face, y = x.y + v.y * tp, vx = v.x, vy = v.y }
    n.c.replicate.hold = true
  end)
  if n.c.pending or not w:owns("/data/score") then return end   -- (a hit may come: no point yet; and only the host scores)

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

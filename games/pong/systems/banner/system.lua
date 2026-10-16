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

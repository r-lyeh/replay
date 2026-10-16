-- hud: the gems taken, and a word when the door's been reached
return function(w, dt)
  local st = w:node("/data/state")
  if not st then return end
  local s = st.c.round
  local score, banner = w:node("/objects/hud/score"), w:node("/objects/hud/banner")
  if score then
    local t = string.format("gems %d / %d", s.gems, s.total)
    if s.total > 0 and s.gems >= s.total and not s.won then t = t .. "   the door is open!" end
    score.c.text[1] = t
  end
  if banner then banner.c.text[1] = s.won and "you made it!  (space: again)" or "" end
end

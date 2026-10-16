-- score: the HUD shows the score
return function(w, dt)
  local s = w:node("/data/score").c
  w:node("/objects/hud/left").c.text[1] = tostring(s.left)
  w:node("/objects/hud/right").c.text[1] = tostring(s.right)
end

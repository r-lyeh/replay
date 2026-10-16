-- input: the keys player 1 holds, and the ones pressed since the game last
-- looked (taps). Data, so it saves and rewinds like everything else.
return { on_key = function(w, key, down, player)
  local me = w:node("/data/input/p" .. (player or 1))
  if not me then return end
  local was = me.c.held[key]
  me.c.held[key] = down or nil
  if down and not was then me.c.taps = me.c.taps or {}; me.c.taps[key] = true end
end }

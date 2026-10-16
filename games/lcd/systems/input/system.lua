-- input: the keys player 1 holds, and the ones pressed since the game last
-- looked (taps: a press and its release in the same frame still counts).
-- Data, so it saves and rewinds like everything else.
return { on_key = function(w, key, down, player)
  local me = w:node("/data/input/p" .. (player or 1))
  if not me then return end
  me.c.held[key] = down or nil
  if down then me.c.taps = me.c.taps or {}; me.c.taps[key] = true end
end }

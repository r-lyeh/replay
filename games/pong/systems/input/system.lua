-- input: remember which keys each player holds (data, so it saves, rewinds
-- and replicates like everything else). The viewer sends every key while
-- playing, and who pressed it.
return { on_key = function(w, key, down, player)
  local me = w:node("/data/input/p" .. (player or 1))
  if me then me.c.held[key] = down or nil end      -- (players 3, 4: watching)
end }

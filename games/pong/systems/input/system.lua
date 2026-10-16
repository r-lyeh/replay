-- input: remember which keys each player holds (data, so it saves, rewinds
-- and replicates like everything else). The viewer sends every key while
-- playing, and who pressed it. A gamepad (pad N: player N) holds the keys
-- its dpad / left stick stand for: up = w, down = s.
local PAD = { ["pad dpup"] = "w", ["pad up"] = "w", ["pad dpdown"] = "s", ["pad down"] = "s" }
return { on_key = function(w, key, down, player)
  local me = w:node("/data/input/p" .. (player or 1))
  if not me then return end                        -- (players 3, 4: watching)
  me.c.held[key] = down or nil
  if PAD[key] then me.c.held[PAD[key]] = down or nil end
end }

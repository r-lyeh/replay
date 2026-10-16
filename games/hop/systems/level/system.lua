-- level: a round. When it starts (and again after a win), the map's items
-- layer becomes nodes: a gem per crystal tile (/entities/gem<n>), the door
-- (/entities/door, dim while locked). The layer itself is then hidden.
local hop = require "hop"

local function start(w, s, rules)
  local m = hop.map(w, rules.map)
  if not m then return end
  if w:node("/entities") then for _, n in ipairs(w:children("/entities")) do w:remove(n.path) end end
  local items = w:node("/objects/level/items")
  if items then items.c.hidden = true end
  local n = 0
  for _, c in ipairs(hop.cells(m, "items")) do
    local x, y = hop.centre(c.x, c.y)
    local img = { "/assets/tiles.png", src = hop.tile_src(c.tile), smooth = false }
    if c.tile == rules.gem then
      n = n + 1
      w:spawn("/entities/gem" .. n, { xform = { x = x, y = y }, layer = "items", image = img, gem = { cx = c.x, cy = c.y } })
    elseif c.tile == rules.door then
      img.color = { 110, 110, 130 }
      w:spawn("/entities/door", { xform = { x = x, y = y }, layer = "items", image = img, door = { open = false } })
    end
  end
  local sx, sy = hop.centre(rules.start[1], rules.start[2])
  s.x, s.y, s.vx, s.vy, s.gems, s.total, s.won, s.time = sx, sy, 0, 0, 0, n, false, 0
  s.started = true
end

return function(w, dt)
  local st, rl = w:node("/data/state"), w:node("/data/rules")
  if not (st and rl) then return end
  local s, rules = st.c.round, rl.c.level
  local input = w:node("/data/input/p1")
  local taps = input and input.c.taps or {}
  local again = rules.restart_after or 5           -- (a win: again after that many seconds, or space / enter after one)
  if not s.started or (s.won and (s.time > again or (s.time > 1 and (taps.space or taps["return"] or taps["pad a"] or taps["pad start"])))) then start(w, s, rules) end
  local door = w:node("/entities/door")
  if door and not door.c.door.open and s.total > 0 and s.gems >= s.total then
    door.c.door.open = true
    door.c.image.color = nil
  end
end

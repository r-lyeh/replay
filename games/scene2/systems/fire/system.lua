-- fire: every ship of the fleet shoots now and then, after a random wait
-- between data/rules/fire's every_min and every_max seconds. A shot is an
-- entity: spawned under /entities/shots while playing, never saved (Stop
-- clears them: watch the tree while it plays). Its `shot` component is
-- filled from /classes/shot (its life). The randomness comes from
-- data/state's seed (world data), so a rewind replays the same shots.
local function rand(s)                             -- 0..1 (Park-Miller)
  s.seed = (s.seed * 16807) % 2147483647
  return s.seed / 2147483647
end

return function(w, dt)
  local s, f = w:node("/data/state").c, w:node("/data/rules").c.fire
  local fleet = w:node("/objects/fleet")
  if not fleet then return end
  for _, ship in ipairs(w:children(fleet)) do
    local x, v = ship.c.xform, ship.c.vel
    if x and v then
      local left = (s.cool[ship.name] or rand(s) * f.every_max) - dt
      if left <= 0 then
        local len = math.sqrt(v.x * v.x + v.y * v.y)
        if len > 0 then                            -- out of the nose, the ship's speed added
          local dx, dy = v.x / len, v.y / len
          s.shots = s.shots + 1
          w:spawn("/entities/shots/" .. s.shots, {
            xform = { x = x.x + dx * 16, y = x.y + dy * 16 },
            move = { x = dx * f.speed + v.x, y = dy * f.speed + v.y },
            circle = { r = 2, fill = true },
            color = { 255, 230, 120 },
            shot = {},                             -- (its life: from /classes/shot)
          })
        end
        left = f.every_min + rand(s) * (f.every_max - f.every_min)
      end
      s.cool[ship.name] = left
    end
  end
end

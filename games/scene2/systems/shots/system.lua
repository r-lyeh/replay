-- shots: fly straight, and go away when their life runs out or they leave
-- the arena (w:remove: gone from /entities/shots)
return function(w, dt)
  local shots = w:node("/entities/shots")
  if not shots then return end
  for _, n in ipairs(w:children(shots)) do
    local x, m, s = n.c.xform, n.c.move, n.c.shot
    x.x, x.y = x.x + m.x * dt, x.y + m.y * dt
    s.life = s.life - dt
    if s.life <= 0 or math.abs(x.x) > 480 or math.abs(x.y) > 300 then w:remove(n.path) end
  end
end

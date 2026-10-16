-- fly: nodes with xform + vel move, bounce off the arena edges and face
-- where they are going. Edit and save while the game runs: it swaps live.
return { requires = { "xform", "vel" }, run = function(w, n, dt)
  local x, v = n.c.xform, n.c.vel
  x.x, x.y = x.x + v.x * dt, x.y + v.y * dt
  if x.x < -450 or x.x > 450 then v.x = -v.x end
  if x.y < -280 or x.y > 280 then v.y = -v.y end
  x.r = math.atan2 and math.atan2(v.y, v.x) or math.atan(v.y, v.x)
end }

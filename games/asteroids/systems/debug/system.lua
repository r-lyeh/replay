-- debug: debugdraw on the dev overlay (nothing in a standalone game): each
-- ship's velocity, and how many rocks and shots there are
return function(w, dt)
  for p = 1, 2 do
    local sh = w:node("/objects/ship" .. p)
    if sh and sh.c.ship.alive then
      local x, v = sh.c.xform, sh.c.vel
      dd.arrow(x.x, x.y, x.x + v.x * 0.3, x.y + v.y * 0.3, "#ffd04090")
    end
  end
  local rocks = w:node("/entities/rocks")
  local n = rocks and #w:children(rocks) or 0
  dd.text(-392, 262, string.format("rocks %d", n), { 255, 208, 64, 140 })
end

-- debug: debugdraw on the dev overlay (nothing in a standalone game):
-- the ball's velocity and speed, and where each paddle is aiming
return function(w, dt)
  local b = w:node("/objects/ball").c
  local x, v = b.xform, b.vel
  dd.arrow(x.x, x.y, x.x + v.x * 0.15, x.y + v.y * 0.15, "#ffd04090")
  dd.text(x.x + 10, x.y + 10, string.format("%.0f", math.sqrt(v.x * v.x + v.y * v.y)), { 255, 208, 64, 140 })
  for _, p in ipairs(w:query("paddle", "xform")) do
    if not (w.players or { true })[p.c.paddle.player or 1] then dd.cross(p.c.xform.x, x.y, 5, "#ff965a80") end
  end
end

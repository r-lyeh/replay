-- move-00: every node can be dragged, even code sharing a line.
-- Expect: each node moves (runtime/tests/nodegraph_moves.lua). One-line
--   statements, expressions inside calls inside calls (slot=3.2), one-line
--   functions, until, elseif and break get --[[@node]] style inline tags
--   when they have no line of their own.
local function f(x, v, p, list)
  local t = { a = 1, b = x.y + 2 }
  dd.text(x.x + 10, x.y + 10, string.format("%.0f", math.sqrt(v.x * v.x + v.y * v.y)), { 255, 208, 64, 140 })
  if p then dd.cross(p.c.xform.x, x.y, 5, "#ff965a80") end
  if x.y < 0 and math.abs(x.x - p) < 3 then x.y = 0 end
  local fn = function(who) print(who) end
  local nop = function() end
  repeat x.x = x.x + 1 until x.x > 3
  for _, q in ipairs(list) do if q then break end end
  if x.x then print(1) elseif v then print(2) end
  return t, fn, nop, math.max(-1, math.min(1, x.x))
end
return f

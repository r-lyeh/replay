-- hud: the round's time top-centre, the record under it, each ship's time in
-- its corner (in its colour; "AI" when the computer flies it), the banner
-- when the round is over. Runs on every player's world: it only shows the
-- state (/data/state, the host's) and the ships.
local function text(w, path, s, align, x)          -- set a HUD line: centred (or right-aligned) at x
  local n = w:node(path)
  if not n then return end
  local t = n.c.text
  t[1] = s
  local width = #s * 8 * (t.size or 1)             -- (the debug font: 8 px a character)
  if align == "centre" then n.c.xform.x = x - width / 2
  elseif align == "right" then n.c.xform.x = x - width end
  return n
end

return function(w, dt)
  local s, a = w:node("/data/state").c, w:node("/data/rules").c.arena
  text(w, "/objects/hud/timer", string.format("%.1f", s.time), "centre", 0)
  text(w, "/objects/hud/record", s.record.time > 0 and string.format("record %.1f s  %s", s.record.time, s.record.who) or "no record yet", "centre", 0)
  for p = 1, 2 do
    local sh = w:node("/objects/ship" .. p)
    if sh then
      local human = (w.players or { true })[p]
      local label = string.format("P%d%s  %.1f", p, human and "" or " AI", sh.c.ship.time)
      local n = text(w, "/objects/hud/p" .. p, label, p == 1 and "left" or "right", a.w / 2 - 16)
      if n then
        local c = sh.c.image.color
        n.c.color = { c[1], c[2], c[3], sh.c.ship.alive and 255 or 110 }
      end
    end
  end
  local help = w:node("/objects/hud/help")
  if help then help.c.hidden = s.time > 5 or s.over or nil end

  local b = w:node("/objects/hud/banner")
  if not b then return end
  if not s.over then b.c.hidden = true return end
  local line = s.winner == "" and string.format("a draw: %.1f s", s.best) or string.format("%s wins: %.1f s", s.winner, s.best)
  local record = s.record.round == s.round
  text(w, b.path, line, "centre", 0)
  b.c.xform.y = -40
  local win = w:node("/objects/ship" .. s.winner:sub(2))
  local c = win and win.c.image.color or { 240, 240, 240 }
  b.c.color = { c[1], c[2], c[3] }
  b.c.hidden = nil
  local left = math.max(0, (w:node("/data/rules").c.restart_after or 6) - s.wait)
  local sub = (record and "a new record!   " or "") .. string.format("again in %d", math.ceil(left))
  local cd = text(w, b.path .. "/countdown", sub, "centre", 0)
  if cd then cd.c.xform.x = cd.c.xform.x - b.c.xform.x end   -- (a child: relative to the banner)
end

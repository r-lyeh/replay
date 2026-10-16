-- director: the round. New rocks keep coming from the edges, a little
-- sooner each time; a ship that dies bursts into sparks; when every ship is
-- gone the one that lived longest wins, and beats the record (the longest
-- life yet: a savegame, saves/record.sav, kept between runs) or not. Space, enter or escape (anyone's, after a
-- second) or rules.restart_after seconds: the next round.
-- It lives on /objects/game, the host's (replicate.lua: true): only the
-- host runs it; /data/state, its state, travels to the others.

local space = require "space"                     -- (data/lib/space: shared helpers)
local rand = space.rand

local restart = { "space", "return", "keypad enter", "escape", "pad a", "pad start" }
local function pressed(w)
  for _, i in ipairs(w:select("/data/input/*")) do
    for _, k in ipairs(restart) do if i.c.held and i.c.held[k] then return true end end
  end
end

local function rock(w, s, rules)                   -- a big one, from an edge, heading across
  local R, a = rules.rocks, rules.arena
  local t, x, y = rand(s), 0, 0
  if rand(s) < 0.5 then x, y = (t - 0.5) * a.w, (rand(s) < 0.5 and -1 or 1) * a.h / 2
  else x, y = (rand(s) < 0.5 and -1 or 1) * a.w / 2, (t - 0.5) * a.h end
  local tx, ty = (rand(s) - 0.5) * a.w * 0.5, (rand(s) - 0.5) * a.h * 0.5   -- (aimed near the middle)
  local d = math.max(1, math.sqrt((tx - x) ^ 2 + (ty - y) ^ 2))
  local speed = R.speed_min + rand(s) * (R.speed_max - R.speed_min)
  s.rocks = s.rocks + 1
  local big = R.sizes.big
  w:spawn("/entities/rocks/" .. s.rocks, {
    xform = { x = x, y = y, r = rand(s) * 6.28 },
    vel = { x = (tx - x) / d * speed, y = (ty - y) / d * speed },
    rock = { size = "big", spin = (rand(s) - 0.5) * 2 * R.spin },
    image = { big.image, w = big.w, h = big.w },
  })
end

local function ships(w)
  local out = {}
  for _, n in ipairs(w:select("/objects/*")) do if n.c.ship then out[#out + 1] = n end end
  return out
end

local function new_round(w, s, rules)
  s.round, s.over, s.winner, s.time, s.wait = s.round + 1, false, "", 0, 0
  s.every, s.next, s.spent, s.boom = rules.rocks.every, rules.rocks.every, {}, {}
  local box = w:node("/entities/rocks")
  if box then w:remove(box.path) end
  w:spawn("/entities/rocks", { replicate = { by = 1, predict = true, snap = { x = 200, y = 200 }, rate = 2 } })
  for _ = 1, rules.rocks.first do rock(w, s, rules) end
end

return { requires = { "director" }, run = function(w, n, dt)
  local rules, s = w:node("/data/rules").c, w:node("/data/state").c
  if s.round == 0 then
    local r = w:loadgame("record")                 -- (the record of earlier runs: w:savegame wrote it)
    if type(r) == "table" and tonumber(r.time) then s.record = { time = tonumber(r.time), who = tostring(r.who or ""), round = -1 } end
    new_round(w, s, rules)
    return
  end
  local list = ships(w)
  for _, sh in ipairs(list) do                     -- a ship gone this round: a burst, in its colour
    local p = sh.c.ship
    if not p.alive and p.round == s.round and s.boom[p.player] ~= s.round then
      s.boom[p.player] = s.round
      local c = sh.c.image.color
      local x = sh.c.xform
      w:event("boom", { x = x.x, y = x.y, n = 26, v0 = 60, v1 = 280, l0 = 0.6, l1 = 1.4, size = 12, color = { c[1], c[2], c[3] },
                        seed = math.floor(rand(s) * 2147483646) + 1 })   -- (systems/sparks: everyone makes it)
    end
  end
  for path in pairs(s.spent) do if not w.nodes[path] then s.spent[path] = nil end end   -- (shots gone: forget them)

  if s.over then                                   -- the banner's up: wait, or a key
    s.wait = s.wait + dt
    if s.wait >= (rules.restart_after or 6) or (s.wait > 1 and pressed(w)) then new_round(w, s, rules) end
    return
  end
  s.time = s.time + dt
  s.next = s.next - dt
  local box = w:node("/entities/rocks")
  if s.next <= 0 then
    if #w:children(box) < rules.rocks.max then rock(w, s, rules) end
    s.every = math.max(rules.rocks.every_min, s.every * rules.rocks.ramp)
    s.next = s.every
  end

  local alive, best, who = false, -1, ""
  for _, sh in ipairs(list) do
    local p = sh.c.ship
    if p.alive or p.round ~= s.round then alive = true end
    if p.time > best then best, who = p.time, "P" .. p.player
    elseif p.time == best then who = "" end
  end
  if alive or s.time < 0.5 then return end
  s.over, s.winner, s.best, s.wait = true, who, best, 0   -- everyone's gone: who lived longest, how long
  if who ~= "" and best > s.record.time then
    local p = tonumber(who:sub(2))
    s.record = { time = best, who = who .. ((w.players or { true })[p] and "" or " (AI)"), round = s.round }
    w:savegame("record", { time = s.record.time, who = s.record.who })   -- (kept for the next run: /saves/record.sav)
  end
end }

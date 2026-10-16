-- DEEPISLE: a small roguelite for Replay, in one file.
-- Run with: replay games/deepisle.lua
-- You wake on an island. Three stairs lead down into dungeons, and some
-- dungeons go deeper. Kill every monster in every dungeon to win.
--   Arrows / WASD (a gamepad: dpad, left stick) walk. Walk into a monster to
--   hit it with your weapon: each hit wears the weapon down, and a broken
--   one leaves you your fists. Walk into chests to open them, over bones to
--   search them; E / SPACE (a pad's A) takes a weapon lying on the ground
--   (yours is left in its place). Potions heal, gold is gold. Stairs take
--   you down, and back up. R starts a new island when it's over.
-- The world is made when the game starts, from a seed: the island by the
-- terrain generator, each dungeon level by the dungeon generator
-- (w:generate: plugins/terrain/gen.lua, plugins/dungeon/gen.lua, the code
-- the editor's generator tabs run). Their tiles are the tilemap plugin's
-- (plugin:tiles.png: auto-tiles for the shores and the walls); the hero, the
-- monsters and the loot are games/common/deepisle.png (drawn by
-- games/common/tools/make_deepisle.py). The rules are data (/data/rules:
-- weapons, monsters, depths...), everything that changes is /data/state:
-- it saves and rewinds.
local ecs = require("ecs")
local w = ecs.world()

local VW, VH = 512, 288                            -- (the window)
local SHEET = "/assets/deepisle.png"
w:spawn("/config", { window = { w = VW, h = VH, title = "DEEPISLE" } })
-- the rules: plain data (edit them in the tree while it plays); the systems read them
local solid_ground = { 8, 9, 2, 6, 21, 61 }       -- (water, stone, snow, walls; and the auto-tiles below)
for t = 64, 110 do solid_ground[#solid_ground + 1] = t end    -- (water with shores)
for t = 111, 157 do solid_ground[#solid_ground + 1] = t end   -- (stone walls with edges)
w:spawn("/data/rules", {
  seed = 0,                                        -- 0: a new island each game; another number: always that one
  view = { w = VW, h = VH }, tile = 16, sheet = SHEET, pool = { things = 48, monsters = 40 },
  frames = { hero = 0, hero2 = 1, skeleton = 2, slime = 3, bat = 4, spider = 5, ghost = 6, imp = 7,
             chest = 8, chest_open = 9, bones = 10, stairs_down = 11, stairs_up = 12, potion = 13, gold = 14,
             heart = 15, heart_empty = 16, fists = 17, dagger = 18, club = 19, sword = 20, axe = 21, mace = 22, spear = 23 },
  weapons = {                                      -- dmg: a hit's damage; dur: hits before it breaks
    fists = { dmg = 1 }, dagger = { dmg = 2, dur = 30 }, club = { dmg = 3, dur = 24 }, sword = { dmg = 4, dur = 40 },
    spear = { dmg = 4, dur = 55 }, axe = { dmg = 6, dur = 22 }, mace = { dmg = 5, dur = 35 } },
  tiers = { { "dagger", "club" }, { "sword", "spear", "club" }, { "axe", "mace", "sword" } },   -- (what's found at each depth)
  monsters = {                                     -- hp, a bite's damage, speed (px/s), how far it sees (px)
    slime = { hp = 3, dmg = 1, speed = 26, sight = 80 }, bat = { hp = 2, dmg = 1, speed = 58, sight = 110 },
    skeleton = { hp = 6, dmg = 2, speed = 40, sight = 110 }, spider = { hp = 5, dmg = 2, speed = 54, sight = 100 },
    ghost = { hp = 8, dmg = 2, speed = 34, sight = 130 }, imp = { hp = 11, dmg = 3, speed = 48, sight = 120 } },
  kinds = { { "slime", "bat" }, { "skeleton", "spider", "bat" }, { "ghost", "imp", "skeleton" } },   -- (who lives at each depth)
  themes = { "stone", "cave", "crypt" },          -- (dungeon 1, 2, 3)
  depths = { 3, 2, 3 },                            -- (how deep each goes)
  solid_ground = solid_ground,                     -- what can't be walked through: these tiles (ground)...
  solid_decor = { 51, 48, 39, 40 },                -- ...and rocks, cacti, crates, barrels (decor)
  hero = { hp = 10, speed = 72 },
})
w:spawn("/data/state", { mode = "new", next_seed = 20261022 })   -- (the play system makes the world on its first tick)

-- the screen: the world (moved under the camera), then the HUD
w:spawn("/data/layers", { order = { "ground", "decor", "things", "monsters", "player", "front" } })
w:spawn("/objects/world", { xform = { x = 0, y = 0 } })
w:spawn("/objects/world/ground", { layer = "ground", xform = { x = 0, y = 0 }, tilemap = { rows = {}, tileset = "plugin:tiles.png", tile = 16 } })
w:spawn("/objects/world/decor", { layer = "decor", xform = { x = 0, y = 0 }, tilemap = { rows = {}, tileset = "plugin:tiles.png", tile = 16 } })
local function sprite(path, layer)
  w:spawn(path, { layer = layer, hidden = true, xform = { x = 0, y = 0, sx = 1 },
                  image = { SHEET, src = { 0, 0, 16, 16 }, w = 16, h = 16, smooth = false, color = { 255, 255, 255, 255 } } })
end
for i = 1, 48 do sprite(string.format("/objects/world/thing%02d", i), "things") end   -- (pools: image nodes the draw system fills)
for i = 1, 40 do sprite(string.format("/objects/world/mon%02d", i), "monsters") end
sprite("/objects/world/hero", "player")
w:spawn("/objects/hud", { layer = "front" })
w:spawn("/objects/hud/bar", { xform = { x = 0, y = -VH / 2 + 10 }, color = { 10, 10, 16, 190 }, rect = { w = VW, h = 20, fill = true } })
for i = 1, 10 do
  w:spawn("/objects/hud/heart" .. string.format("%02d", i), { xform = { x = -VW / 2 + 10 + (i - 1) * 11, y = -VH / 2 + 10 },
          image = { SHEET, src = { 0, 0, 16, 16 }, w = 10, h = 10, smooth = false } })
end
w:spawn("/objects/hud/weapon", { xform = { x = -VW / 2 + 128, y = -VH / 2 + 10 }, image = { SHEET, src = { 0, 0, 16, 16 }, w = 14, h = 14, smooth = false } })
w:spawn("/objects/hud/wtext", { xform = { x = -VW / 2 + 138, y = -VH / 2 + 6 }, color = { 230, 225, 210 }, text = "" })
w:spawn("/objects/hud/gold", { xform = { x = 30, y = -VH / 2 + 6 }, color = { 250, 210, 70 }, text = "" })
w:spawn("/objects/hud/left", { xform = { x = 110, y = -VH / 2 + 6 }, color = { 230, 120, 110 }, text = "" })
w:spawn("/objects/hud/where", { xform = { x = -VW / 2 + 8, y = VH / 2 - 14 }, color = { 170, 180, 200 }, text = "" })
w:spawn("/objects/hud/hint", { xform = { x = 0, y = VH / 2 - 30 }, color = { 250, 240, 200 }, text = "" })
w:spawn("/objects/hud/msg", { xform = { x = 0, y = -VH / 2 + 34 }, color = { 255, 240, 220 }, text = "" })
w:spawn("/objects/hud/banner", { xform = { x = 0, y = -20 }, color = { 255, 240, 200 }, text = { "", size = 3 } })
w:spawn("/objects/hud/sub", { xform = { x = 0, y = 12 }, color = { 190, 200, 220 }, text = "" })

-- input: keys held, and the presses since the game last looked
local input = ecs.system(function()
  return { on_key = function(w, key, down)
    local s = w:node("/data/state").c
    s.held = s.held or {}
    s.taps = s.taps or {}
    local was = s.held[key]
    s.held[key] = down or nil
    if down and not was then s.taps[key] = true end
  end }
end)

-- play: the world made (at the start, and on R), then walking, fighting, looting, stairs
local play = ecs.system(function()
  local function rng(s) s.seed = (s.seed * 16807) % 2147483647; return s.seed / 2147483647 end
  local function ri(s, a, b) return a + math.floor(rng(s) * (b - a + 1)) end
  local function pick(s, list) return list[ri(s, 1, #list)] end
  local solid_g, solid_d, solid_for                -- (sets of the rules' lists, made again when the rules change)
  local function solids(R)
    if solid_for == R then return end
    solid_g, solid_d, solid_for = {}, {}, R
    for _, t in ipairs(R.solid_ground) do solid_g[t] = true end
    for _, t in ipairs(R.solid_decor) do solid_d[t] = true end
  end
  local function cell_at(rows, x, y)               -- (0-based) -> tile | nil
    local r = rows[y + 1]
    local hx = r and r:sub(x * 2 + 1, x * 2 + 2)
    if not hx or hx == "" or hx == ".." then return nil end
    return tonumber(hx, 16)
  end
  local function solid_cell(L, x, y)
    if x < 0 or y < 0 or x >= L.w or y >= L.h then return true end
    local g = cell_at(L.ground, x, y)
    return g == nil or solid_g[g] or solid_d[cell_at(L.decor, x, y) or -1] or false
  end
  local TS = 16
  local function center(cx, cy) return cx * TS + TS / 2, cy * TS + TS / 2 end
  local function weapon(R, name, worn, s)          -- a weapon, new or worn
    local d = R.weapons[name]
    local dur = d.dur and (worn and math.max(3, math.floor(d.dur * (0.3 + 0.4 * rng(s)))) or d.dur)
    return { name = name, dmg = d.dmg, dur = dur, max = d.dur }
  end
  local function monster(R, kind, x, y, boost)
    local m = R.monsters[kind]
    local hp = math.floor(m.hp * boost + 0.5)
    return { kind = kind, x = x, y = y, hp = hp, max = hp, dmg = m.dmg, speed = m.speed, sight = m.sight,
             cool = 0, stun = 0, wx = 0, wy = 0, wt = 0, flash = 0 }
  end
  local function reachable(L, sx, sy)              -- the cells walkable from (sx, sy)
    local seen, list, stack = {}, {}, { { sx, sy } }
    while #stack > 0 do
      local p = table.remove(stack)
      local k = p[2] * L.w + p[1]
      if not seen[k] and not solid_cell(L, p[1], p[2]) then
        seen[k] = true
        list[#list + 1] = p
        stack[#stack + 1] = { p[1] + 1, p[2] }; stack[#stack + 1] = { p[1] - 1, p[2] }
        stack[#stack + 1] = { p[1], p[2] + 1 }; stack[#stack + 1] = { p[1], p[2] - 1 }
      end
    end
    return list
  end
  local function farthest(list, from)             -- the cell of list farthest from all of `from`
    local best, bd = nil, -1
    for _, p in ipairs(list) do
      local d = math.huge
      for _, f in ipairs(from) do d = math.min(d, (p[1] - f[1]) ^ 2 + (p[2] - f[2]) ^ 2) end
      if d > bd then best, bd = p, d end
    end
    return best
  end
  local function make_island(w, R, s)
    for _ = 1, 20 do                               -- (an island with enough land in one piece)
      local data = assert(w:generate("terrain", { seed = ri(s, 1, 999999), w = 64, h = 44, scale = 14, octaves = 4, island = true,
                                                  water = 0.36, trees = 0.22, flowers = 0.06, dry = 0.15 }))
      local L = { id = "isle", name = "The island", w = data.w, h = data.h, ground = data.layers[1].rows, decor = data.layers[2].rows,
                  monsters = {}, chests = {}, bones = {}, items = {}, stairs = {} }
      local cx, cy = math.floor(L.w / 2), math.floor(L.h / 2)
      local start
      for r = 0, 20 do                             -- (the land nearest the middle)
        for dy = -r, r do for dx = -r, r do
          if not start and not solid_cell(L, cx + dx, cy + dy) then start = { cx + dx, cy + dy } end
        end end
      end
      local land = start and reachable(L, start[1], start[2])
      if land and #land > 500 then
        L.start = start
        local taken = { start }
        for i = 1, #R.depths do                    -- a stair down to each dungeon, far from the start and each other
          local p = farthest(land, taken)
          taken[#taken + 1] = p
          local x, y = center(p[1], p[2])
          L.stairs[#L.stairs + 1] = { x = x, y = y, down = true, to = "d" .. i .. "-1" }
        end
        for _, o in ipairs({ { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } }) do   -- (bones near the start: a dagger in them)
          if not solid_cell(L, start[1] + o[1], start[2] + o[2]) then
            local bx, by = center(start[1] + o[1], start[2] + o[2])
            L.bones[1] = { x = bx, y = by, loot = weapon(R, "dagger", true, s) }
            break
          end
        end
        return L
      end
    end
    error("no island")
  end
  local function make_level(w, R, s, d, depth, deepest)
    local data, info = assert(w:generate("dungeon", { seed = ri(s, 1, 999999), w = 40 + depth * 4, h = 28 + depth * 2, rooms = 6 + depth * 2,
                                                      room_min = 4, room_max = 8, loops = 0.3, theme = R.themes[d], torches = 0.15, clutter = 0.06 }))
    local id = "d" .. d .. "-" .. depth
    local L = { id = id, name = "Dungeon " .. d .. ", depth " .. depth, w = data.w, h = data.h,
                ground = data.layers[1].rows, decor = data.layers[2].rows, monsters = {}, chests = {}, bones = {}, items = {}, stairs = {} }
    local rooms = info.list
    local first = rooms[1]
    local ux, uy = center(first.cx, first.cy)
    L.stairs[1] = { x = ux, y = uy, up = true, to = depth == 1 and "isle" or ("d" .. d .. "-" .. (depth - 1)) }
    local far, fd = nil, -1
    for i = 2, #rooms do
      local r = rooms[i]
      local dd = (r.cx - first.cx) ^ 2 + (r.cy - first.cy) ^ 2
      if dd > fd then far, fd = r, dd end
    end
    if depth < deepest and far then
      local dx, dy = center(far.cx, far.cy)
      L.stairs[2] = { x = dx, y = dy, down = true, to = "d" .. d .. "-" .. (depth + 1) }
    end
    local function free_cell(r)                    -- a walkable cell of room r, not its middle (where stairs go)
      for _ = 1, 20 do
        local x, y = ri(s, r.x, r.x + r.w - 1), ri(s, r.y, r.y + r.h - 1)
        if not solid_cell(L, x, y) and not (x == r.cx and y == r.cy) then return center(x, y) end
      end
    end
    local function other_room() return rooms[ri(s, 2, math.max(2, #rooms))] or first end
    local boost = 1 + 0.25 * (d - 1)
    for _ = 1, 2 + depth * 2 + math.floor(#rooms / 2) do   -- monsters: anywhere but the room you arrive in
      local x, y = free_cell(other_room())
      if x then L.monsters[#L.monsters + 1] = monster(R, pick(s, R.kinds[depth]), x, y, boost) end
    end
    for _ = 1, 1 + math.floor(depth / 2) + (depth == deepest and 1 or 0) do   -- chests (more at the bottom)
      local x, y = free_cell(other_room())
      if x then L.chests[#L.chests + 1] = { x = x, y = y, open = false } end
    end
    for _ = 1, ri(s, 1, 2) do                      -- the bones of those who came before (some armed)
      local x, y = free_cell(rooms[ri(s, 1, #rooms)])
      if x then L.bones[#L.bones + 1] = { x = x, y = y, loot = rng(s) < 0.6 and weapon(R, pick(s, R.tiers[depth]), true, s) or nil } end
    end
    return L
  end
  local function new_game(w, R, seed)
    local s = { seed = seed % 2147483647 }
    if s.seed <= 0 then s.seed = s.seed + 2147483646 end
    solids(R)
    local levels = { isle = make_island(w, R, s) }
    local total = 0
    for d = 1, #R.depths do
      for depth = 1, R.depths[d] do
        local L = make_level(w, R, s, d, depth, R.depths[d])
        levels[L.id] = L
        total = total + #L.monsters
      end
    end
    local px, py = center(levels.isle.start[1], levels.isle.start[2])
    return {
      seed = seed, rng = { seed = s.seed }, t = 0, mode = "play", level = "isle", levels = levels, left = total, total = total,
      p = { x = px, y = py, hp = R.hero.hp, max = R.hero.hp, weapon = weapon(R, "fists"), gold = 0, kills = 0, cool = 0, hurt = 0,
            face = 1, step = 0, lock = nil },      -- lock: the stair we stand on (stepped off before it works again)
      held = {}, taps = {}, msg = "Find the stairs. Clear every dungeon.", msg_t = 5, hint = "",
    }
  end

  local function any(h, set) for k in pairs(set) do if h[k] then return true end end return false end
  local UP = { up = true, w = true, ["pad up"] = true }
  local DOWN = { down = true, s = true, ["pad down"] = true }
  local LEFT = { left = true, a = true, ["pad left"] = true }
  local RIGHT = { right = true, d = true, ["pad right"] = true }
  local ACT = { space = true, e = true, ["return"] = true, ["pad a"] = true }
  local function say(s, text, secs) s.msg, s.msg_t = text, secs or 2.5 end
  local HALF = 5                                   -- (a body's half size, px: what hits the walls)
  local function blocked(L, x, y)
    for _, c in ipairs({ { -HALF, -HALF }, { HALF, -HALF }, { -HALF, HALF }, { HALF, HALF } }) do
      if solid_cell(L, math.floor((x + c[1]) / TS), math.floor((y + c[2]) / TS)) then return true end
    end
    return false
  end
  local function move(L, b, dx, dy)                -- along each axis, as far as the walls allow
    if dx ~= 0 and not blocked(L, b.x + dx, b.y) then b.x = b.x + dx end
    if dy ~= 0 and not blocked(L, b.x, b.y + dy) then b.y = b.y + dy end
  end
  local function drop(L, x, y, item)               -- something on the ground, beside (x, y) if it can
    for _, o in ipairs({ { 0, 12 }, { 12, 0 }, { -12, 0 }, { 0, -12 } }) do
      if not blocked(L, x + o[1], y + o[2]) then item.x, item.y = x + o[1], y + o[2]; break end
    end
    item.x, item.y = item.x or x, item.y or y
    L.items[#L.items + 1] = item
  end
  local function depth_of(L) return tonumber(L.id:match("%-(%d+)$")) or 1 end
  local function loot(R, s, depth)                 -- what a chest holds: a weapon, a potion, gold
    local r = rng(s.rng)
    if r < 0.5 then return { kind = "weapon", weapon = weapon(R, pick(s.rng, R.tiers[math.max(1, math.min(#R.tiers, depth))]), false, s.rng) } end
    if r < 0.75 then return { kind = "potion" } end
    return { kind = "gold", n = ri(s.rng, 5, 15) * depth }
  end
  local function hit(R, s, L, m)                   -- the hero's weapon on monster m
    local wp = s.p.weapon
    m.hp = m.hp - wp.dmg
    m.flash, m.stun = 0.15, 0.3
    local dx, dy = m.x - s.p.x, m.y - s.p.y
    local d = math.max(1, math.sqrt(dx * dx + dy * dy))
    move(L, m, dx / d * 10, dy / d * 10)           -- (knocked back)
    if wp.dur then
      wp.dur = wp.dur - 1
      if wp.dur <= 0 then say(s, "Your " .. wp.name .. " breaks!"); s.p.weapon = weapon(R, "fists") end
    end
    if m.hp <= 0 then
      m.dead = true
      s.left, s.p.kills = s.left - 1, s.p.kills + 1
      local r = rng(s.rng)
      if r < 0.35 then drop(L, m.x, m.y, { kind = "gold", n = ri(s.rng, 2, 8) })
      elseif r < 0.5 then drop(L, m.x, m.y, { kind = "potion" }) end
      if s.left <= 0 then s.mode, s.won_t = "won", s.t end
    end
  end
  local function go(s, to, from_id)                -- down or up the stairs: onto the stair that leads back
    local L = s.levels[to]
    if not L then return end
    s.level = to
    for _, st in ipairs(L.stairs) do
      if st.to == from_id then s.p.x, s.p.y, s.p.lock = st.x, st.y, st; break end
    end
    say(s, L.name, 2)
  end
  local function replace(s, fresh) for k in pairs(s) do s[k] = nil end; for k, v in pairs(fresh) do s[k] = v end end

  return function(w, dt)
    local R = w:node("/data/rules").c
    local s = w:node("/data/state").c
    solids(R)
    if s.mode == "new" then replace(s, new_game(w, R, R.seed ~= 0 and R.seed or s.next_seed)) end
    s.t = s.t + dt
    s.msg_t = math.max(0, s.msg_t - dt)
    local taps = s.taps
    s.taps = {}
    if s.mode ~= "play" then                       -- won / dead: R, a new island
      if taps.r or taps["pad start"] then replace(s, { mode = "new", next_seed = math.floor(rng(s.rng) * 999999) + 1 }) end
      return
    end
    local L = s.levels[s.level]
    local p = s.p
    -- walking
    local mx = (any(s.held, RIGHT) and 1 or 0) - (any(s.held, LEFT) and 1 or 0)
    local my = (any(s.held, DOWN) and 1 or 0) - (any(s.held, UP) and 1 or 0)
    local pad = w.pads and w.pads[1]
    if pad and mx == 0 and my == 0 and (math.abs(pad.lx or 0) > 0.3 or math.abs(pad.ly or 0) > 0.3) then mx, my = pad.lx, pad.ly end
    local len = math.sqrt(mx * mx + my * my)
    if len > 0 then
      local sp = R.hero.speed * dt / math.max(1, len)
      move(L, p, mx * sp, my * sp)
      if mx ~= 0 then p.face = mx > 0 and 1 or -1 end
      p.step = p.step + dt
    end
    p.cool, p.hurt = math.max(0, p.cool - dt), math.max(0, p.hurt - dt)
    -- monsters: wander, chase what they see, bite what they touch; walked into: hit
    for _, m in ipairs(L.monsters) do
      m.cool, m.stun, m.flash = math.max(0, m.cool - dt), math.max(0, m.stun - dt), math.max(0, m.flash - dt)
      local dx, dy = p.x - m.x, p.y - m.y
      local d = math.max(0.001, math.sqrt(dx * dx + dy * dy))
      if m.stun <= 0 then
        if d < m.sight then
          local jitter = m.kind == "bat" and (rng(s.rng) - 0.5) * 1.6 or 0
          move(L, m, (dx / d + jitter) * m.speed * dt, (dy / d - jitter) * m.speed * dt)
        else
          m.wt = m.wt - dt
          if m.wt <= 0 then m.wt = 1 + rng(s.rng) * 2; local a = rng(s.rng) * math.pi * 2; m.wx, m.wy = math.cos(a), math.sin(a) end
          move(L, m, m.wx * m.speed * 0.4 * dt, m.wy * m.speed * 0.4 * dt)
        end
      end
      if d < 13 and not m.dead then
        if len > 0 and p.cool <= 0 and (mx * dx + my * dy) < 0 then   -- (walking into it: a hit)
          p.cool = 0.35
          hit(R, s, L, m)
        elseif m.cool <= 0 and m.stun <= 0 and p.hurt <= 0 then        -- (it bites)
          m.cool, p.hurt = 0.9, 0.8
          p.hp = p.hp - m.dmg
          move(L, p, dx / d * 8, dy / d * 8)
          if p.hp <= 0 then s.mode = "dead"; say(s, "", 0) end
        end
      end
    end
    for i = #L.monsters, 1, -1 do if L.monsters[i].dead then table.remove(L.monsters, i) end end
    if s.mode ~= "play" then return end
    -- chests (walked into), bones (walked over)
    for _, c in ipairs(L.chests) do
      if not c.open and math.abs(c.x - p.x) < 13 and math.abs(c.y - p.y) < 13 then
        c.open = true
        local item = loot(R, s, depth_of(L))
        drop(L, c.x, c.y, item)
        say(s, "A chest: " .. (item.kind == "weapon" and ("a " .. item.weapon.name) or item.kind == "potion" and "a potion" or (item.n .. " gold")))
      end
    end
    for _, b in ipairs(L.bones) do
      if not b.searched and math.abs(b.x - p.x) < 10 and math.abs(b.y - p.y) < 10 then
        b.searched = true
        if b.loot then drop(L, b.x, b.y, { kind = "weapon", weapon = b.loot }); say(s, "Bones, and a " .. b.loot.name .. " in them")
        else say(s, "Just bones.") end
        b.loot = nil
      end
    end
    -- things on the ground: gold and potions taken, weapons taken with E (or at once, bare-handed)
    s.hint = ""
    for i = #L.items, 1, -1 do
      local it = L.items[i]
      if math.abs(it.x - p.x) < 10 and math.abs(it.y - p.y) < 10 then
        if it.kind == "gold" then p.gold = p.gold + it.n; table.remove(L.items, i); say(s, "+" .. it.n .. " gold", 1)
        elseif it.kind == "potion" and p.hp < p.max then p.hp = math.min(p.max, p.hp + 4); table.remove(L.items, i); say(s, "A potion: you feel better", 1.5)
        elseif it.kind == "weapon" then
          local nw = it.weapon
          if p.weapon.name == "fists" or any(taps, ACT) then
            table.remove(L.items, i)
            if p.weapon.name ~= "fists" then L.items[#L.items + 1] = { kind = "weapon", weapon = p.weapon, x = it.x, y = it.y } end
            p.weapon = nw
            say(s, "You take the " .. nw.name, 1.5)
            break
          else
            s.hint = string.format("E: take the %s (hits %d, %d left)", nw.name, nw.dmg, nw.dur or 0)
          end
        end
      end
    end
    -- stairs: walked onto (not the one we arrived on, until we step off it)
    local on
    for _, st in ipairs(L.stairs) do if math.abs(st.x - p.x) < 8 and math.abs(st.y - p.y) < 8 then on = st end end
    if p.lock and (not on or on.to ~= p.lock.to) then p.lock = nil end
    if on and not p.lock then go(s, on.to, L.id) end
  end
end)

-- what the player sees
local draw = ecs.system(function()
  local function frame(R, img, name)
    local f = R.frames[name] or 0
    img.src[1], img.src[2] = (f % 8) * 16, math.floor(f / 8) * 16
  end
  return function(w, dt)
    local R = w:node("/data/rules").c
    local s = w:node("/data/state").c
    if not s.levels then return end
    local L = s.levels[s.level]
    local p = s.p
    local VW, VH, TS = R.view.w, R.view.h, R.tile
    -- the camera: on the hero, inside the map (the HUD's bar above it)
    local mw, mh = L.w * TS, L.h * TS
    local cx = mw <= VW and mw / 2 or math.max(VW / 2, math.min(mw - VW / 2, p.x))
    local cy = mh <= VH - 20 and mh / 2 - 10 or math.max(VH / 2 - 20, math.min(mh - VH / 2, p.y))
    local wx = w:node("/objects/world").c.xform
    wx.x, wx.y = -math.floor(cx), -math.floor(cy)
    w:node("/objects/world/ground").c.tilemap.rows = L.ground
    w:node("/objects/world/decor").c.tilemap.rows = L.decor
    -- the things: stairs, bones, chests, what lies on the ground (a pool of image nodes)
    local list = {}
    for _, st in ipairs(L.stairs) do list[#list + 1] = { st.x, st.y, st.down and "stairs_down" or "stairs_up" } end
    for _, b in ipairs(L.bones) do list[#list + 1] = { b.x, b.y, "bones" } end
    for _, c in ipairs(L.chests) do list[#list + 1] = { c.x, c.y, c.open and "chest_open" or "chest" } end
    for _, it in ipairs(L.items) do
      list[#list + 1] = { it.x, it.y + math.sin(s.t * 4 + it.x) * 1.5, it.kind == "weapon" and it.weapon.name or it.kind }
    end
    for i = 1, R.pool.things do
      local n = w:node(string.format("/objects/world/thing%02d", i)).c
      local e = list[i]
      n.hidden = e == nil
      if e then n.xform.x, n.xform.y = e[1], e[2]; frame(R, n.image, e[3]) end
    end
    for i = 1, R.pool.monsters do
      local n = w:node(string.format("/objects/world/mon%02d", i)).c
      local m = L.monsters[i]
      n.hidden = m == nil
      if m then
        n.xform.x, n.xform.y = m.x, m.y + (m.kind == "bat" and math.sin(s.t * 9 + i) * 2 or 0)
        n.xform.sx = (p.x < m.x) and -1 or 1
        frame(R, n.image, m.kind)
        local c = n.image.color
        if m.flash > 0 then c[1], c[2], c[3] = 255, 110, 110 else c[1], c[2], c[3] = 255, 255, 255 end
        c[4] = m.kind == "ghost" and 190 or 255
      end
    end
    local h = w:node("/objects/world/hero").c
    h.hidden = s.mode == "dead"
    h.xform.x, h.xform.y, h.xform.sx = p.x, p.y, p.face
    frame(R, h.image, (math.floor(p.step * 6) % 2 == 1) and "hero2" or "hero")
    h.image.color[4] = (p.hurt > 0 and math.floor(s.t * 20) % 2 == 0) and 90 or 255
    -- the HUD
    for i = 1, 10 do
      local n = w:node("/objects/hud/heart" .. string.format("%02d", i)).c
      n.hidden = i > p.max
      frame(R, n.image, i <= p.hp and "heart" or "heart_empty")
    end
    frame(R, w:node("/objects/hud/weapon").c.image, p.weapon.name)
    w:node("/objects/hud/wtext").c.text = p.weapon.dur and string.format("%s %d/%d", p.weapon.name, p.weapon.dur, p.weapon.max) or "fists"
    w:node("/objects/hud/gold").c.text = "GOLD " .. p.gold
    w:node("/objects/hud/left").c.text = "MONSTERS " .. s.left .. "/" .. s.total
    w:node("/objects/hud/where").c.text = L.name
    local hint = w:node("/objects/hud/hint").c
    hint.text = s.hint
    hint.xform.x = -#s.hint * 4
    local msg = w:node("/objects/hud/msg").c
    msg.text = s.msg_t > 0 and s.msg or ""
    msg.xform.x = -#msg.text * 4
    local banner, sub = w:node("/objects/hud/banner").c, w:node("/objects/hud/sub").c
    if s.mode == "won" then
      banner.text[1] = "THE ISLE IS AT PEACE"
      sub.text = string.format("%d monsters, %d gold, in %d:%02d.   R: a new island", s.total, p.gold, math.floor(s.won_t / 60), math.floor(s.won_t % 60))
    elseif s.mode == "dead" then
      banner.text[1] = "YOU DIED"
      sub.text = string.format("%d of %d monsters slain.   R: a new island", p.kills, s.total)
    else banner.text[1], sub.text = "", "" end
    banner.xform.x = -#banner.text[1] * 12
    sub.xform.x = -#sub.text * 4
  end
end)

w:spawn("/systems", { order = { "input", "play", "draw" } })
w:spawn("/systems/input", { system = input })
w:spawn("/systems/play", { system = play })
w:spawn("/systems/draw", { system = draw })
return w

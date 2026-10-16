-- bullets.lua - bullet-hell patterns: .bullets files (plain Lua data) and the
-- simulation that plays them. Games read one with w:bullets(name) (a file of
-- their assets: a script's games/common/, a folder's assets/); the editor
-- (plugins/bullets) previews the same file with the same code.
--
-- A .bullets file:
--   return {
--     patterns = {                   -- emitters: what a ship fires
--       { name = "fan3", kind = "fan", count = 3, spread = 30, aim = true,
--         speed = 160, rate = 1.5, size = 10, color = "#ff6aa0" },
--     },
--     enemies = { { name = "fighter", hp = 3, score = 100, size = 36, speed = 140, pattern = "fan3" } },
--     waves = { { at = 2, enemy = "fighter", count = 5, gap = 0.4, path = "dive", x = -200 } },
--     boss = { hp = 400, size = 150, phases = { { hp = 1, patterns = { "spiral" } }, { hp = 0.5, patterns = { "ring" } } } },
--     field = { w = 800, h = 600 },  -- the play field (default 800 x 600)
--   }
-- A pattern (every field optional, M.DEFAULTS):
--   kind     "ring" (count bullets all round), "fan" (count across `spread`
--            degrees), "random" (count at random within `spread`)
--   angle    where it points, degrees (90: down the screen); aim = true: at the target
--   spin     degrees a second the aim turns while it fires (a ring that spins: a spiral)
--   rate     volleys a second; volleys: how many (0: while its ship lives); delay: s before the first
--   speed, accel (px/s, px/s/s), curve (degrees a second a bullet turns), life (s)
--   size, color ("#rrggbb"), sprite ("dot", "spark", "shot")
--   split = { at = s, pattern = "name" }: at that age a bullet bursts into
--            one volley of another pattern (nested patterns)
-- Coordinates: the play field's middle is 0, 0; y grows down the screen.
--
-- A stage (the waves, then the boss) is played the same way by every game
-- and by the editor's preview: sg = M.stage_new(d, seed), then each frame
-- events = M.stage_step(d, sg, dt, tx, ty); the game deals the damage (a
-- ship's hp, sg.boss.hp) and M.stage_kill(sg, i) takes a ship out.
local M = {}

M.KINDS = { "ring", "fan", "random" }
M.SPRITES = { "dot", "spark", "shot" }
M.PATHS = { "down", "sine", "dive", "zigzag", "sweep", "arc" }
M.DEFAULTS = { kind = "fan", count = 1, spread = 0, angle = 90, aim = false, spin = 0, rate = 1, volleys = 0,
               delay = 0, speed = 150, accel = 0, curve = 0, life = 8, size = 10, color = "#ff7ab0", sprite = "dot" }
M.FIELD = { w = 800, h = 600 }                     -- (the default play field: bullets leave past its edges)
function M.field(d)
  local f = d and type(d.field) == "table" and d.field or M.FIELD
  return { w = math.max(160, tonumber(f.w) or 800), h = math.max(120, tonumber(f.h) or 600) }
end

local D2R = math.pi / 180
local atan2 = math.atan2 or math.atan               -- (LuaJIT: atan2; Lua 5.4: atan(y, x))
local function num(v, d) v = tonumber(v); return v == nil and d or v end

-- a parsed file: its lists, and by name
function M.check(d)
  d = type(d) == "table" and d or {}
  d.patterns = type(d.patterns) == "table" and d.patterns or {}
  d.enemies = type(d.enemies) == "table" and d.enemies or {}
  d.waves = type(d.waves) == "table" and d.waves or {}
  d.boss = type(d.boss) == "table" and d.boss or nil
  d.field = type(d.field) == "table" and d.field or nil
  return d
end
-- a parsed file's methods: d:new(seed), d:emit(st, name, x, y, owner),
-- d:stop(st, owner), d:step(st, dt, tx, ty), d:hit(st, x, y, r), d:look(st, out),
-- d:volley(st, name, x, y, tx, ty), d:pattern(name), d:enemy(name), d:path(...)
M.methods = { __index = {} }
function M.parse(text)
  local f, err = load(text, "=bullets", "t", {})
  if not f then return nil, err end
  local ok, d = pcall(f)
  if not ok then return nil, d end
  return setmetatable(M.check(d), M.methods)
end
local by_name = setmetatable({}, { __mode = "k" })  -- (d.patterns -> name -> pattern: a bullet looks its pattern up each step)
function M.pattern(d, name)
  local m = by_name[d.patterns]
  if not m then m = {}; by_name[d.patterns] = m end
  local p = m[name]
  if p and p.name == name then return p end
  for _, q in ipairs(d.patterns) do if q.name == name then m[name] = q return q end end
  m[name] = nil
end
function M.enemy(d, name)
  for _, e in ipairs(d.enemies) do if e.name == name then return e end end
end
local function get(p, k) local v = p[k]; if v == nil then return M.DEFAULTS[k] end return v end
M.get = get

-- colours: "#rrggbb" -> 0xRRGGBB (the bullets component's rgb)
local hexes = {}
function M.rgb(c)
  if type(c) == "number" then return c end
  local h = hexes[c]
  if h then return h end
  h = tonumber(tostring(c or ""):match("^#?(%x%x%x%x%x%x)$") or "ff7ab0", 16)
  hexes[c] = h
  return h
end

-- the state, plain data (keep it in the world: it saves and rewinds)
function M.new(seed)
  return { t = 0, seed = seed or 1, emitters = {}, bullets = {} }
end
local function rand(st)                            -- 0..1, from the state's seed (the same run every time)
  st.seed = (st.seed * 1103515245 + 12345) % 2147483648
  return st.seed / 2147483648
end

-- an emitter of pattern `name` at x, y; owner: who it follows (the game sets e.x, e.y)
function M.emit(st, name, x, y, owner)
  local e = { pat = name, x = x or 0, y = y or 0, t = 0, fired = 0, owner = owner, spin = 0 }
  st.emitters[#st.emitters + 1] = e
  return e
end
function M.stop(st, owner)                         -- its emitters stop (their bullets fly on)
  for i = #st.emitters, 1, -1 do if st.emitters[i].owner == owner then table.remove(st.emitters, i) end end
end

-- one volley of pattern p from x, y (tx, ty: the target)
local function volley(st, p, x, y, tx, ty, base_turn)
  local n = math.max(1, math.floor(get(p, "count")))
  local kind = get(p, "kind")
  local a0 = get(p, "aim") and atan2(ty - y, tx - x) / D2R or get(p, "angle")
  a0 = a0 + (base_turn or 0)
  local spread = get(p, "spread")
  for i = 1, n do
    local a
    if kind == "ring" then a = a0 + 360 * (i - 1) / n
    elseif kind == "random" then a = a0 + (rand(st) - 0.5) * spread
    else a = n == 1 and a0 or (a0 - spread / 2 + spread * (i - 1) / (n - 1)) end
    st.bullets[#st.bullets + 1] = { x = x, y = y, a = a, v = get(p, "speed"), age = 0, p = p.name }
  end
end
M.volley = function(d, st, name, x, y, tx, ty)
  local p = M.pattern(d, name)
  if p then volley(st, p, x, y, tx or x, ty or y + 1) end
end

-- a step: emitters fire, bullets fly (and split, and go past the field)
function M.step(d, st, dt, tx, ty)
  st.t = st.t + dt
  tx, ty = tx or 0, ty or 0
  for i = #st.emitters, 1, -1 do
    local e = st.emitters[i]
    local p = M.pattern(d, e.pat)
    if not p then table.remove(st.emitters, i)
    else
      e.t = e.t + dt
      local rate, vol = math.max(0.01, get(p, "rate")), get(p, "volleys")
      while e.t >= get(p, "delay") + e.fired / rate and (vol <= 0 or e.fired < vol) do
        local at = get(p, "delay") + e.fired / rate     -- (its own time: the spin where it fired)
        volley(st, p, e.x, e.y, tx, ty, get(p, "spin") * at)
        e.fired = e.fired + 1
      end
      if vol > 0 and e.fired >= vol then table.remove(st.emitters, i) end
    end
  end
  local F = M.field(d)
  local hw, hh = F.w / 2 + 40, F.h / 2 + 40
  local bs, keep = st.bullets, 0
  local born = {}
  for i = 1, #bs do
    local b = bs[i]
    local p = M.pattern(d, b.p) or M.DEFAULTS
    b.age = b.age + dt
    b.v = math.max(0, math.min(1200, b.v + get(p, "accel") * dt))
    b.a = b.a + get(p, "curve") * dt
    b.x = b.x + math.cos(b.a * D2R) * b.v * dt
    b.y = b.y + math.sin(b.a * D2R) * b.v * dt
    local alive = b.age < get(p, "life") and b.x > -hw and b.x < hw and b.y > -hh and b.y < hh
    if b.fade then b.fade = b.fade - dt; alive = alive and b.fade > 0 end   -- (cleared: harmless, fading, flying on)
    local sp = p.split
    if alive and not b.fade and type(sp) == "table" and b.age >= num(sp.at, 1) then
      local q = M.pattern(d, sp.pattern)
      if q and q ~= p then born[#born + 1] = { q, b.x, b.y } end
      alive = false
    end
    if alive then keep = keep + 1; bs[keep] = b end
  end
  for i = #bs, keep + 1, -1 do bs[i] = nil end
  for _, n in ipairs(born) do volley(st, n[1], n[2], n[3], tx, ty, 0) end
end

-- a hit: the first bullet within r of x, y (gone) -> true
function M.hit(d, st, x, y, r)
  for i, b in ipairs(st.bullets) do
    if not b.fade then                               -- (a fading one: harmless)
      local p = M.pattern(d, b.p) or M.DEFAULTS
      local rr = r + get(p, "size") * 0.35
      local dx, dy = b.x - x, b.y - y
      if dx * dx + dy * dy < rr * rr then table.remove(st.bullets, i) return true end
    end
  end
  return false
end
-- clear the bullets: gone at once, or (fade: seconds) harmless, fading out as they fly on
M.FADE = 0.8
function M.clear(st, fade)
  if not fade or fade <= 0 then st.bullets = {} return end
  for _, b in ipairs(st.bullets) do b.fade = math.min(b.fade or fade, fade) end
end
function M.alpha(b) return b.fade and math.max(0, math.min(1, b.fade / M.FADE)) or 1 end

-- for drawing: one bullets component a sprite { "/assets/x.png" | nil, xy =, s =, rgb =, a =, o = (opacity) }
local SPRITE_FILE = { spark = "/assets/spark.png", shot = "/assets/shot.png" }
function M.look(d, st, out)
  out = out or {}
  local by = {}
  for _, s in ipairs(M.SPRITES) do
    local c = out[s] or {}
    c[1], c.xy, c.s, c.rgb, c.a, c.o = SPRITE_FILE[s], {}, {}, {}, {}, {}
    out[s], by[s] = c, c
  end
  for _, b in ipairs(st.bullets) do
    local p = M.pattern(d, b.p) or M.DEFAULTS
    local c = by[get(p, "sprite")] or by.dot
    local n = #c.s + 1
    c.xy[n * 2 - 1], c.xy[n * 2] = b.x, b.y
    c.s[n] = get(p, "size")
    c.rgb[n] = M.rgb(get(p, "color"))
    c.a[n] = (b.a + 90) * D2R                        -- (a shot's picture points up: turned to where it flies)
    c.o[n] = M.alpha(b)
  end
  return out
end

-- where a ship of a wave is, t seconds after it came in (x0: where it came in,
-- y0: a sweep's height, s: its speed; F: the field, default 800 x 600)
function M.path(name, t, x0, y0, s, F)
  F = F or M.FIELD
  local top = -F.h / 2 - 30
  s = s or 140
  if name == "sine" then return x0 + math.sin(t * 2) * 120, top + t * s
  elseif name == "dive" then                         -- down, then a turn toward the middle and away
    local y = top + t * s
    local k = math.max(0, y) / (F.h / 2)
    return x0 + (0 - x0) * math.min(1, k) * 0.6 + (x0 < 0 and -1 or 1) * k * k * 180, y
  elseif name == "zigzag" then
    local ph = (t * s / 160) % 2
    return x0 + (ph < 1 and ph or 2 - ph) * 160 - 80, top + t * s * 0.8
  elseif name == "sweep" then                        -- across, at height y0, from the side x0 is on
    local dir = x0 < 0 and 1 or -1
    return (x0 < 0 and -F.w / 2 - 30 or F.w / 2 + 30) + dir * t * s, y0 or -F.h / 4
  elseif name == "arc" then                          -- in from the top, a half circle, out the top
    local a = math.min(math.pi, t * s / 260)
    return x0 + (1 - math.cos(a)) * 130 * (x0 < 0 and 1 or -1), top + math.sin(a) * F.h * 0.57 - math.max(0, t * s / 260 - math.pi) * 260
  end
  return x0, top + t * s                             -- "down"
end
function M.path_done(x, y, F)                        -- gone past the field?
  F = F or M.FIELD
  return y > F.h / 2 + 60 or y < -F.h / 2 - 80 or x < -F.w / 2 - 80 or x > F.w / 2 + 80
end

-- the stage: the waves' ships when their time comes, on their paths, firing;
-- then the boss: down to its place, then a sway, its phases by its hp.
-- sg (plain data): { t, bul (the bullets' state), ships = { { id, kind, x, y,
-- hp, size, ... } }, boss = { x, y, hp, max, size, phase, in_ } | nil,
-- mode = "waves" | "boss" | "done", wave (the last wave in) }
function M.stage_new(d, seed)
  return { t = 0, bul = M.new(seed or 1), ships = {}, boss = nil, next_id = 0, mode = "waves", wave = 0 }
end
function M.waves_end(d)                              -- when the last ship of the last wave comes in
  local last = 0
  for _, wv in ipairs(d.waves) do last = math.max(last, (wv.at or 0) + ((wv.count or 1) - 1) * (wv.gap or 0)) end
  return last
end
function M.boss_place(d)                             -- where the boss stops and sways from
  local F = M.field(d)
  return 0, -F.h / 2 + 130
end
-- -> events: { "wave", i } a wave came in, { "boss" } the boss comes, { "phase", n, from },
-- { "beaten" } the boss is beaten, { "done" } all over (no boss), { "gone", ship } a ship left the field
function M.stage_step(d, sg, dt, tx, ty)
  local ev = {}
  local F = M.field(d)
  local t0 = sg.t
  sg.t = sg.t + dt
  if sg.mode == "waves" then
    for wi, wv in ipairs(d.waves) do
      for i = 1, wv.count or 1 do
        local at = (wv.at or 0) + (i - 1) * (wv.gap or 0)
        if at > t0 and at <= sg.t or (t0 == 0 and at == 0) then
          local e = M.enemy(d, wv.enemy)
          if e then
            local x = (wv.x or 0) + (i - 1) * (wv.spacing or 0)
            if wv.mirror and i % 2 == 0 then x = -x end
            sg.next_id = sg.next_id + 1
            local id = "e" .. sg.next_id
            local y = -F.h / 2 - 30
            sg.ships[#sg.ships + 1] = { id = id, kind = wv.enemy, x0 = x, y0 = wv.y, path = wv.path or "down", t = 0,
                                        x = x, y = y, hp = e.hp or 3, size = e.size or 40, speed = e.speed or 140, hit = 0 }
            M.emit(sg.bul, wv.pattern or e.pattern, x, y, id)
            if i == 1 then sg.wave = wi; ev[#ev + 1] = { "wave", wi } end
          end
        end
      end
    end
    if sg.t > M.waves_end(d) + 1 and #sg.ships == 0 then
      if d.boss then
        local hp = d.boss.hp or 300
        sg.boss = { x = 0, y = -F.h / 2 - 120, hp = hp, max = hp, size = d.boss.size or 150, t = 0, phase = 0, in_ = false, sway = 0, hit = 0 }
        sg.mode = "boss"
        ev[#ev + 1] = { "boss" }
      else sg.mode = "done"; ev[#ev + 1] = { "done" } end
    end
  end
  for i = #sg.ships, 1, -1 do
    local s = sg.ships[i]
    s.t = s.t + dt
    s.hit = math.max(0, (s.hit or 0) - dt)
    s.x, s.y = M.path(s.path, s.t, s.x0, s.y0, s.speed, F)
    for _, em in ipairs(sg.bul.emitters) do if em.owner == s.id then em.x, em.y = s.x, s.y + 14 end end
    if M.path_done(s.x, s.y, F) and s.t > 1 then
      M.stop(sg.bul, s.id)
      table.remove(sg.ships, i)
      ev[#ev + 1] = { "gone", s }
    end
  end
  local b = sg.boss
  if b and b.hp > 0 then
    b.t, b.hit = b.t + dt, math.max(0, (b.hit or 0) - dt)
    local px, py = M.boss_place(d)
    if not b.in_ and b.y < py then b.y = math.min(py, b.y + 70 * dt)   -- (down to its place first: it attacks from there)
    else
      b.in_ = true
      b.sway = b.sway + dt                            -- (its sway starts where it arrived)
      b.x = px + math.sin(b.sway * 0.45) * F.w * 0.21
      b.y = py + math.sin(b.sway * 0.8) * 22
      local phases, want = d.boss.phases or {}, 0
      for pi, ph in ipairs(phases) do if b.hp / b.max <= (ph.hp or 1) + 1e-6 then want = pi end end
      if want ~= b.phase then                        -- a new phase: its patterns (the bullets on screen fade)
        M.stop(sg.bul, "boss")
        M.clear(sg.bul, M.FADE)
        for _, name in ipairs(phases[want] and phases[want].patterns or {}) do M.emit(sg.bul, name, b.x, b.y, "boss") end
        ev[#ev + 1] = { "phase", want, b.phase }
        b.phase = want
      end
    end
    for _, em in ipairs(sg.bul.emitters) do if em.owner == "boss" then em.x, em.y = b.x, b.y + 20 end end
  end
  if b and b.hp <= 0 and sg.mode == "boss" then
    M.stop(sg.bul, "boss")
    M.clear(sg.bul, M.FADE)
    sg.mode = "done"
    ev[#ev + 1] = { "beaten" }
  end
  M.step(d, sg.bul, dt, tx, ty)
  return ev
end
function M.stage_kill(sg, i)                         -- ship i is out (shot down): its emitters stop -> the ship
  local s = table.remove(sg.ships, i)
  if s then M.stop(sg.bul, s.id) end
  return s
end

-- another file's patterns and ships into d (names taken: a number added; what
-- they name follows) -> how many patterns, how many ships came in
function M.import(d, other)
  local pmap, n_p, n_s = {}, 0, 0
  local function free(list, find, name)
    if not find(d, name) then return name end
    for i = 2, 999 do if not find(d, name .. i) then return name .. i end end
  end
  for _, p in ipairs(other.patterns or {}) do pmap[p.name] = free(d.patterns, M.pattern, p.name) end
  local function copy(v) if type(v) ~= "table" then return v end local t = {} for k, x in pairs(v) do t[k] = copy(x) end return t end
  local added = {}
  for _, p in ipairs(other.patterns or {}) do
    local q = copy(p)
    q.name = pmap[p.name]
    if type(q.split) == "table" and q.split.pattern then q.split.pattern = pmap[q.split.pattern] or q.split.pattern end
    added[#added + 1] = q
  end
  for _, q in ipairs(added) do d.patterns[#d.patterns + 1] = q; n_p = n_p + 1 end
  for _, e in ipairs(other.enemies or {}) do
    local q = copy(e)
    q.name = free(d.enemies, M.enemy, e.name)
    if q.pattern then q.pattern = pmap[q.pattern] or q.pattern end
    d.enemies[#d.enemies + 1] = q
    n_s = n_s + 1
  end
  return n_p, n_s
end

-- a file's text -> Lua source (what the editor saves)
local function ser(v, ind)
  local t = type(v)
  if t == "string" then return string.format("%q", v)
  elseif t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return (string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", ""))
  elseif t == "boolean" then return tostring(v)
  elseif t ~= "table" then return "nil" end
  local n, flat = #v, true
  for k, x in pairs(v) do if type(x) == "table" then flat = false end end
  local parts = {}
  for i = 1, n do parts[#parts + 1] = ser(v[i], ind .. "  ") end
  local keys = {}
  for k in pairs(v) do if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b)
    if a == "name" then return b ~= "name" elseif b == "name" then return false end
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(keys) do
    local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. ser(k, ind) .. "]")
    parts[#parts + 1] = key .. " = " .. ser(v[k], ind .. "  ")
  end
  if flat then return "{ " .. table.concat(parts, ", ") .. " }" end
  return "{\n" .. ind .. "  " .. table.concat(parts, ",\n" .. ind .. "  ") .. ",\n" .. ind .. "}"
end
function M.to_lua(d)
  return "-- bullet patterns, ships, waves and a boss (plugins/bullets; runtime/bullets.lua says what each field is)\nreturn "
    .. ser({ patterns = d.patterns, enemies = d.enemies, waves = d.waves, boss = d.boss, field = d.field }, "") .. "\n"
end

do
  local I = M.methods.__index
  I.new = function(_, seed) return M.new(seed) end
  I.emit = function(_, st, name, x, y, owner) return M.emit(st, name, x, y, owner) end
  I.stop = function(_, st, owner) return M.stop(st, owner) end
  I.step = M.step
  I.hit = M.hit
  I.look = M.look
  I.volley = M.volley
  I.pattern = M.pattern
  I.enemy = M.enemy
  I.clear = function(_, st, fade) return M.clear(st, fade) end
  I.path = function(d, name, t, x0, y0, s) return M.path(name, t, x0, y0, s, M.field(d)) end
  I.path_done = function(d, x, y) return M.path_done(x, y, M.field(d)) end
  I.field = M.field
  I.stage_new = M.stage_new
  I.stage_step = M.stage_step
  I.stage_kill = function(_, sg, i) return M.stage_kill(sg, i) end
  I.boss_place = M.boss_place
end

-- games: w:bullets("starfall.bullets") -> the parsed file (read again when it changes)
local ok, ecs = pcall(require, "ecs")
if ok and type(ecs) == "table" and ecs.assets then
  local cache = {}
  ecs.bullets = function(w, name)
    name = tostring(name):gsub("^/assets/", ""):gsub("^/", "")
    if not name:find("%.%w+$") then name = name .. ".bullets" end
    local text = ecs.assets.read(name)
    if not text then return nil, "no asset " .. name end
    local c = cache[name]
    if not c or c.text ~= text then
      local d, err = M.parse(text)
      if not d then return nil, err end
      c = { text = text, d = d }
      cache[name] = c
    end
    return c.d
  end
end
return M

-- scene1.lua
-- A demo scene for the viewer. It returns a world; the viewer ticks its systems.
-- Edit this file while the viewer runs: it reloads on save.
--
-- Render components (see replay.c header): xform, color, lines, tris, rect,
-- circle, text, sprite, ref, hidden. Picking shape: bounds = { w=, h= } or
-- { r= } (+ aabb = true). Anything else is game data the viewer ignores
-- (it still shows up in the tree panel).

local ecs = require("ecs")
local w = ecs.world()

-- The tree: /assets the parts `ref` draws, /data rules, state and players,
-- /classes components' defaults, /objects what you see (saved), /systems the
-- code, /entities what's spawned while playing (the shots: never saved).
-- games\scene2\ is the same world as a folder.

-- assets: plain data nodes, drawn only through `ref` (only /objects and
-- /entities are drawn) --------------------------------------------------------
w:spawn("/assets/ship", {
  color = { 120, 220, 255 },
  lines = { 14, 0, -10, -9, -5, 0, -10, 9, loop = true },
})
w:spawn("/assets/ship/flame", {
  xform = { x = -8 },
  color = { 255, 140, 40 },
  tris  = { -2, -3, -2, 3, -10, 0 },
})
w:spawn("/assets/invader", {
  sprite = {
    "..#.....#..",
    "...#...#...",
    "..#######..",
    ".##.###.##.",
    "###########",
    "#.#######.#",
    "#.#.....#.#",
    "...##.##...",
    palette = { ["#"] = { 140, 255, 120 } },
    px = 3,
  },
})

-- a small solar system: transforms compose down the tree ------------------
w:spawn("/objects/sun",   { xform = { x = 0, y = 0 }, spin = 0.2,
                            color = { 255, 210, 60 }, circle = { r = 40, fill = true } })
w:spawn("/objects/sun/earth", { xform = { x = 160 }, spin = 1.0,
                                color = { 70, 140, 255 }, circle = { r = 14, fill = true } })
w:spawn("/objects/sun/earth/moon", { xform = { x = 32 }, spin = 3,
                                     color = { 200, 200, 210 }, circle = { r = 5, fill = true } })
w:spawn("/objects/sun/mars", { xform = { x = -250, r = 1 }, spin = 0.6,
                               color = { 230, 90, 60 }, circle = { r = 10 } })
w:spawn("/objects/sun/orbit", { color = { 60, 60, 80 }, circle = { r = 160, n = 64 } })

-- a fleet: five instances of one asset -------------------------------------
for i = 1, 5 do
  w:spawn("/objects/fleet/ship" .. i, {
    xform = { x = -380 + i * 40, y = 220 - i * 25, r = i },
    vel   = { x = 60 * math.cos(i), y = 60 * math.sin(i) },
    ref   = "/assets/ship",
  })
end
for i = 1, 3 do
  w:spawn("/objects/invaders/i" .. i, { xform = { x = 250 + i * 50, y = -200 },
                                        ref = "/assets/invader" })
end

-- misc -----------------------------------------------------------------------
w:spawn("/objects/box",   { xform = { x = 330, y = 150, r = 0.3 }, spin = -0.5,
                            color = { 255, 90, 200 }, rect = { w = 60, h = 40 },
                            bounds = { w = 60, h = 40 } })   -- pick anywhere inside, rotated
w:spawn("/objects/title", { xform = { x = -120, y = -280 },
                            text = "hello, tree world" })
w:spawn("/data/players/player1", { pos = { x = -300, y = -150 }, hp = 3 })  -- no visuals: gizmo only
w:spawn("/data/rules", { gravity = 9.8 })                                   -- not visual at all

-- systems: code leaves --------------------------------------------------------
-- Systems are data too: Lua source stored in a component. ecs.system() keeps
-- the body of the function as that source, so it saves, rewinds and
-- replicates with the world, and editing it swaps the system live. In a world
-- folder each one is a plain file, e.g. systems/fly/system.lua. A system
-- returns function(w, dt) (once per tick) or { requires = {...}, run =
-- function(w, node, dt) } (once per node). The body runs on its own: it
-- can't use locals from outside it.
local spin = ecs.system(function()
  return { requires = { "xform", "spin" }, run = function(w, n, dt)
    n.c.xform.r = (n.c.xform.r or 0) + n.c.spin * dt
  end }
end)

local fly = ecs.system(function()
  return { requires = { "xform", "vel" }, run = function(w, n, dt)
    local x, v = n.c.xform, n.c.vel
    x.x, x.y = x.x + v.x * dt, x.y + v.y * dt
    if x.x < -450 or x.x > 450 then v.x = -v.x end
    if x.y < -280 or x.y > 280 then v.y = -v.y end
    x.r = math.atan2 and math.atan2(v.y, v.x) or math.atan(v.y, v.x)
  end }
end)

local debugdraw = ecs.system(function()   -- not "debug": that would hide the debug library
  -- debugdraw on the dev overlay (does nothing in a standalone game)
  return { requires = { "xform", "vel" }, run = function(w, n, dt)
    local x, v = n.c.xform, n.c.vel
    dd.arrow(x.x, x.y, x.x + v.x * 0.5, x.y + v.y * 0.5, "#ffd04080")
    dd.text(x.x + 8, x.y - 14, n.name, { 150, 220, 255, 160 })
  end }
end)

local fire = ecs.system(function()
  -- fire: every ship of the fleet shoots now and then, after a random wait
  -- between /data/rules' fire.every_min and every_max seconds. A shot is an
  -- entity: spawned under /entities/shots while playing, never saved (Stop
  -- clears them: watch the tree while it plays). Its `shot` component is
  -- filled from /classes/shot (its life). The randomness comes from
  -- /data/state's seed (world data), so a rewind replays the same shots.
  local function rand(s)                           -- 0..1 (Park-Miller)
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
          if len > 0 then                          -- out of the nose, the ship's speed added
            local dx, dy = v.x / len, v.y / len
            s.shots = s.shots + 1
            w:spawn("/entities/shots/" .. s.shots, {
              xform = { x = x.x + dx * 16, y = x.y + dy * 16 },
              move = { x = dx * f.speed + v.x, y = dy * f.speed + v.y },
              circle = { r = 2, fill = true },
              color = { 255, 230, 120 },
              shot = {},                           -- (its life: from /classes/shot)
            })
          end
          left = f.every_min + rand(s) * (f.every_max - f.every_min)
        end
        s.cool[ship.name] = left
      end
    end
  end
end)

local shots = ecs.system(function()
  -- shots: fly straight, and go away when their life runs out or they leave
  -- the arena (w:remove: gone from /entities/shots)
  return function(w, dt)
    local all = w:node("/entities/shots")
    if not all then return end
    for _, n in ipairs(w:children(all)) do
      local x, m, s = n.c.xform, n.c.move, n.c.shot
      x.x, x.y = x.x + m.x * dt, x.y + m.y * dt
      s.life = s.life - dt
      if s.life <= 0 or math.abs(x.x) > 480 or math.abs(x.y) > 300 then w:remove(n.path) end
    end
  end
end)

-- shooting: its tuning and state, and what every shot starts with
w:spawn("/data/rules", { fire = { every_min = 0.4, every_max = 2.5, speed = 320 } })
w:spawn("/data/state", { seed = 20261007, shots = 0, cool = {} })
w:spawn("/classes/shot", { life = { type = "number", value = 1.5, min = 0.2, max = 5 } })   -- (a member: its type, value, range)

-- a node each under /systems; its order is the run order (drag them in the tree)
w:spawn("/systems", { order = { "spin", "fly", "fire", "shots", "debug" } })
w:spawn("/systems/spin", { system = spin })
w:spawn("/systems/fly", { system = fly })
w:spawn("/systems/fire", { system = fire })
w:spawn("/systems/shots", { system = shots })
w:spawn("/systems/debug", { system = debugdraw })

-- input ------------------------------------------------------------------------
-- The viewer sends keys meant for the game here. For now: a long ESC press
-- (hold it for half a second) toggles the title.
function w.on_key(w, key, down)
  if key == "escape" and down then
    local t = w:node("/objects/title").c
    t.text = t.text == "ESC!" and "hello, tree world" or "ESC!"
  end
end

return w

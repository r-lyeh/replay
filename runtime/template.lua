-- {{name}}.lua
-- A new world, made from runtime/template.lua by the launcher's "New project".
-- It returns a world; the editor ticks its systems. Edit it while it runs:
-- it reloads on save. ({{name}} in the template becomes the project's name.)

local ecs = require("ecs")
local w = ecs.world()

-- something to look at: a box that spins, and a title
-- the tree: /data rules and state, /classes components' defaults, /objects
-- what you see (saved), /systems the code, /entities spawned while playing,
-- /tmp scratch
w:spawn("/objects/box", { xform = { x = 0, y = 0 }, spin = 1,
                          color = { 120, 200, 255 }, rect = { w = 60, h = 60, fill = true } })
w:spawn("/objects/title", { xform = { x = -60, y = -120 }, color = { 230, 230, 240 }, text = "{{name}}" })

-- systems: code leaves (each body runs on its own: no locals from outside it)
local spin = ecs.system(function()
  return { requires = { "xform", "spin" }, run = function(w, n, dt)
    n.c.xform.r = (n.c.xform.r or 0) + n.c.spin * dt
  end }
end)

w:spawn("/systems/spin", { system = spin })

-- keys meant for the game (and gamepad buttons: "pad a"...)
function w.on_key(w, key, down)
end

return w

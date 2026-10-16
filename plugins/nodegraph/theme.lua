-- theme.lua - the node graph's colours (part of the nodegraph plugin, ours):
-- fixed, Blender-like (a node editor, not a text theme).
local T = {}
local style = require "core.style"

local CT = require "plugins.canvas.theme"    -- (the canvas colours: C, TYPE; shared)
local rgb, C, TYPE, alpha = CT.rgb, CT.C, CT.TYPE, CT.alpha
local HEAD = {                                     -- header colour per kind of node
  ["function"] = rgb"#2f5b5b", ["local"] = rgb"#246283", set = rgb"#7a4a1f", call = rgb"#3c3c83",
  branch = rgb"#83314a", loop = rgb"#6a5a20", ["return"] = rgb"#5a2d5a", expr = rgb"#3f5a3a", table = rgb"#2e5470",
  start = rgb"#8a2b2b",
}
local SOCK = {                                     -- socket colour per kind of variable
  ["local"] = rgb"#a1a1a1", param = rgb"#6363c7", loop = rgb"#c7c729", ["function"] = rgb"#00d6a3",
}
local GLOBAL = rgb"#5a5a5a"
local VALUE = rgb"#d0d0d0"                         -- an expression's result
local function sock_color(d) return d and (SOCK[d.kind] or SOCK["local"]) or GLOBAL end
local function pin_color(sk)                       -- a socket: by type, else by variable kind, or a value
  if sk.vtype and TYPE[sk.vtype] then return TYPE[sk.vtype] end
  if sk.value or sk.kind == "expr" then return VALUE end
  return sock_color(sk.decl)
end
local function kind_color(kind) return HEAD[kind] or HEAD.call end
local PULSE = rgb"#ff9a2e"                         -- the flow that ran (the probe): bright orange
-- its settings (config.lua, init.lua: apply_config): read by draw.lua and
-- view.lua as they draw, so a change shows at once
T.cfg = { flow_fade = 0.6, far_zoom = 0.3, zoom_max = 3 }


-- doc: a Doc, or the state saved in the workspace ({ filename, pan }), or nil
local EXEC = rgb"#e8e8e8"

-- The light theme (the main menu's Theme, editor/editor.c: lite_theme): the
-- canvas turns a cool light grey, like the editor's; the nodes' bodies a
-- little brighter than it (as the dark theme's are a little brighter than
-- its canvas), their text dark; headers, sockets and value fields (dark
-- insets, light text) keep their colours. What's drawn on the canvas itself
-- (the wires, grey sockets, shadows, frames) darkens to show on it.
-- Changed in place: the other files hold these tables.
local DARK, LIGHT = {}, {
  bg = "#c9ccd1", grid = "#c1c4c9", grid2 = "#b5b9bf",   -- (a grid line every 5: a little darker)
  wire = "#5e626a", exec = "#4a4e55", shadow = "#8e9298", framebg = "#a5a9b0",   -- (framebg: a function's frame, on the canvas)
  body = "#dfe1e5", btext = "#16181d", blabel = "#33363c", bdim = "#7b8088",
  exec_wire = "#2f3237", sock_local = "#6b6f77", value = "#70747c", global = "#4a4d52",
  type_number = "#9a7a00", sock_loop = "#8c8c10",   -- (the yellows: darker, to show on a light body)
}
local function slots()                             -- name -> the table it changes
  return { bg = C.bg, grid = C.grid, grid2 = C.grid2, wire = C.wire, exec = C.exec, shadow = C.shadow, framebg = C.framebg,
           body = C.body, btext = C.btext, blabel = C.blabel, bdim = C.bdim,
           exec_wire = EXEC, sock_local = SOCK["local"], value = VALUE, global = GLOBAL,
           type_number = TYPE.number, sock_loop = SOCK.loop }
end
for k, t in pairs(slots()) do DARK[k] = { t[1], t[2], t[3], t[4] } end
function T.set_light(on)
  for k, t in pairs(slots()) do
    local c = on and rgb(LIGHT[k]) or DARK[k]
    t[1], t[2], t[3], t[4] = c[1], c[2], c[3], c[4]
  end
  T.light = on or nil
  CT.light = on or nil                             -- (the canvas: plugins' editors ask it)
end

T.rgb = rgb
T.C = C
T.HEAD = HEAD
T.PULSE = PULSE
T.SOCK = SOCK
T.TYPE = TYPE
T.GLOBAL = GLOBAL
T.VALUE = VALUE
T.EXEC = EXEC
T.sock_color = sock_color
T.pin_color = pin_color
T.kind_color = kind_color
T.alpha = alpha
return T

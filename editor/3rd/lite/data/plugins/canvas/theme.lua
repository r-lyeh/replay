-- theme.lua - the canvas colours (plugins/canvas): the node graph's, shared by
-- every canvas (the node graph, a plugin's editor), so they all look alike.
-- Fixed, Blender-like (a node editor, not a text theme). The light theme
-- changes them in place (plugins/nodegraph/theme.lua: T.set_light, from the
-- main menu's Theme): hold the tables, don't copy them.
local style = require "core.style"
local T = {}

local function rgb(h, a) return { tonumber(h:sub(2, 3), 16), tonumber(h:sub(4, 5), 16), tonumber(h:sub(6, 7), 16), a or 255 } end
local C = {
  bg = rgb"#1d1d1d", grid = rgb"#242424", grid2 = rgb"#2b2b2b",
  body = rgb"#303030", shadow = rgb"#131313", field = rgb"#222222", text = rgb"#e6e6e6", code = rgb"#cfcfcf",
  label = rgb"#c2c2c2", dim = rgb"#7a7a7a",
  active = rgb"#ffffff", hover = rgb"#707070",
  btext = rgb"#e6e6e6", blabel = rgb"#c2c2c2", bdim = rgb"#7a7a7a",   -- text on a node's body (light: dark)
  frame = rgb"#3a3a3a", framebg = rgb"#3a3a3a", exec = rgb"#5e5e5e", wire = rgb"#9a9a9a", outline = rgb"#101010",
  err = style.error or rgb"#e06c75", sel = rgb"#ffa733", str = rgb"#c3e88d", errbg = rgb"#7a1f1f", errtext = rgb"#ffd7d7",
  warn = style.warn or rgb"#e5a23a", warnbg = rgb"#5a3f12", warntext = rgb"#ffe6bf",   -- warnings: an amber footer under the node
}
local TYPE = {                                     -- a value's type, when it's certain (graph.lua: vtype)
  boolean = rgb"#e05252", integer = rgb"#f0a030", number = rgb"#e8d44d", string = rgb"#7ed07e",
  table = rgb"#4fa8e8", ["function"] = rgb"#00d6a3", ["nil"] = rgb"#6e6e6e",
}
local function alpha(c, a) return { c[1], c[2], c[3], a } end

T.rgb, T.C, T.TYPE, T.alpha = rgb, C, TYPE, alpha
return T

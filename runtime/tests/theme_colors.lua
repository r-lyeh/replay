-- theme_colors.lua: every C.<name> the node graph's files use exists in
-- its theme (plugins/nodegraph/theme.lua); a missing one is nil at draw time
-- (a node's hover outline: "attempt to index a nil value (local 'c')").
-- Run from runtime/tests: luajit theme_colors.lua
local dir = "../../plugins/nodegraph/"
package.loaded["core.style"] = { error = { 1, 2, 3, 255 }, warn = { 1, 2, 3, 255 } }
package.preload["plugins.canvas.theme"] = function() return dofile("../../editor/3rd/lite/data/plugins/canvas/theme.lua") end   -- (C: the canvas's, shared)
local T = dofile(dir .. "theme.lua")
local files = { "draw.lua", "view.lua", "edits.lua", "input.lua", "diff.lua", "init.lua", "graph.lua", "breaks.lua", "class.lua", "util.lua", "resolve.lua" }
local bad = 0
for _, f in ipairs(files) do
  local h = io.open(dir .. f)
  if h then
    local src = h:read("*a"); h:close()
    for name in src:gmatch("%f[%w_]C%.([%a_][%w_]*)") do
      if T.C[name] == nil then print(f .. ": C." .. name .. " missing"); bad = bad + 1 end
    end
  end
end
T.set_light(true); T.set_light(false)               -- (both palettes apply)
for k, v in pairs(T.C) do if type(v) ~= "table" or #v < 3 then print("C." .. k .. ": not a colour"); bad = bad + 1 end end
print(bad == 0 and "theme colours: all ok" or ("theme colours: " .. bad .. " bad"))
os.exit(bad == 0 and 0 or 1)

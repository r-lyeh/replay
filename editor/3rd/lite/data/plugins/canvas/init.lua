-- canvas - the node graph's visual language for any editor (Replay, ours).
-- A plugin's editor (plugins/<name>/editor.lua) builds on it:
--
--   local canvas = require "plugins.canvas"
--   canvas.View        a lite tab with a camera: pan, zoom, fit, grid, the
--                      RMB menu (canvas/view.lua). An image, a curve, a map
--   canvas.GraphView   a node editor: kinds of node, typed pins, wires
--                      (canvas/graph.lua). A material, an animation graph
--   canvas.draw        shapes in pixels: line, disc, rrect, bezier, wire,
--                      socket, arrow, checker, text; font(px [, mono, bold]); vh(p) / vw(p):
--                      p % of the monitor's height / width, in pixels
--   canvas.C           the colours (the node graph's: light / dark follow
--                      the editor's Theme), canvas.TYPE: per value type;
--                      canvas.rgb("#rrggbb"), canvas.alpha(c, a)
--   canvas.to_lua(v)   a table as Lua source (return <that>): to save data
--   canvas.ui          a side panel of widgets: headings, buttons, sliders,
--                      checkboxes, choices, colours (canvas/ui.lua)
--
-- The node graph itself (plugins/nodegraph) draws with canvas.draw and
-- canvas.C. docs/PLUGINS.md: the guide.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local T = require "plugins.canvas.theme"

local canvas = {
  draw = require "plugins.canvas.draw",
  theme = T, C = T.C, TYPE = T.TYPE, rgb = T.rgb, alpha = T.alpha,
}
canvas.View = require "plugins.canvas.view"
canvas.GraphView = require "plugins.canvas.graph"
canvas.field = require "plugins.canvas.field"      -- (a text being typed: caret, keys, its lines)
canvas.scrollbar = require "plugins.canvas.scrollbar"   -- (a scroll bar of its own: panels, the hex editor)
canvas.tip = require "plugins.canvas.tip"          -- (tooltips and flashed notes)
canvas.menu = require "plugins.canvas.menu"        -- (popup menus: the node graph's)
canvas.picker = require "plugins.canvas.picker"    -- (the colour picker, a row of colour squares: the node graph's, shared)
canvas.ui = require "plugins.canvas.ui"            -- (a side panel of widgets: sliders, checkboxes, buttons, colours)

-- an untitled tab's first save (a plugin's tab opened apart: the main menu's
-- Plugins >): asks where, on lite's command line, suggesting
-- assets/untitled.<ext> (the game's folder); on_path(absolute path)
function canvas.save_as(ext, on_path, dir)     -- (dir: where to suggest, default assets/)
  local common = require "core.common"
  dir = (dir or "assets"):gsub("[/\\]+$", "")
  local name = dir .. "/untitled." .. ext
  for i = 2, 99 do                                 -- (not over a file that's there)
    if not system.get_file_info(name) then break end
    name = dir .. "/untitled" .. i .. "." .. ext
  end
  core.command_view:set_text(name)
  core.command_view:enter("Save as", function(text)
    if text == "" then return end
    if not text:lower():match("%." .. ext:lower() .. "$") then text = text .. "." .. ext end
    local dir = text:match("^(.*)[/\\][^/\\]*$")
    if dir and not system.get_file_info(dir) then system.mkdir(dir) end
    on_path(((system.absolute_path(dir or ".") or ".") .. "/" .. text:match("[^/\\]*$")):gsub("\\", "/"))
  end, common.path_suggest)
end

-- a value as Lua source: tables with sorted keys, lists inline when short
local function is_ident(k) return type(k) == "string" and k:match("^[%a_][%w_]*$") and k ~= "end" and k ~= "in" and k ~= "and" and k ~= "or" and k ~= "not" end
function canvas.to_lua(v, indent)
  indent = indent or ""
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" then
    if v == math.floor(v) and v >= -2^53 and v <= 2^53 then return string.format("%d", v) end
    for digits = 6, 17 do                         -- the shortest that reads back the same (0.35, not 0.34999...)
      local s = string.format("%." .. digits .. "g", v)
      if tonumber(s) == v then return s end
    end
  end
  if t ~= "table" then return tostring(v) end
  local n = #v
  local keys = {}
  for k in pairs(v) do
    if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then table.insert(keys, k) end
  end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) == "number"
  end)
  local parts, flat = {}, true
  for i = 1, n do
    local s = canvas.to_lua(v[i], indent .. "  ")
    if s:find("\n") or type(v[i]) == "table" and next(v[i]) and #keys == 0 and n > 4 then flat = false end
    table.insert(parts, s)
  end
  for _, k in ipairs(keys) do
    local s = canvas.to_lua(v[k], indent .. "  ")
    if s:find("\n") then flat = false end
    table.insert(parts, (is_ident(k) and k or "[" .. canvas.to_lua(k) .. "]") .. " = " .. s)
  end
  if #parts == 0 then return "{}" end
  local one = "{ " .. table.concat(parts, ", ") .. " }"
  if flat and #one + #indent <= 100 then return one end
  return "{\n" .. indent .. "  " .. table.concat(parts, ",\n" .. indent .. "  ") .. ",\n" .. indent .. "}"
end

-- the RMB menu of every canvas view: its menu_items() (a plugin's view
-- extends it; or registers its own: a subclass's menu wins)
local menu = require "plugins.contextmenu"
menu:register(canvas.View, function() return core.active_view:menu_items() end, "canvas")

command.add(function()
  return core.active_view and core.active_view:is(canvas.GraphView) and next(core.active_view.sel) ~= nil and not menu.show_context_menu
end, {
  ["canvas:delete"] = function() core.active_view:remove_nodes(core.active_view.sel) end,
  ["canvas:duplicate"] = function() core.active_view:duplicate(core.active_view.sel) end,
})
command.add(function()
  return core.active_view and core.active_view:is(canvas.View) and core.active_view.save ~= nil
end, {
  ["canvas:save"] = function() core.active_view:save() end,
})
keymap.add { ["delete"] = "canvas:delete", ["ctrl+d"] = "canvas:duplicate", ["ctrl+s"] = "canvas:save" }

return canvas

-- editor.lua - the node graph: Lua files as node graphs, in a tab (runs in
-- lite). Its code is this folder's modules (`require "plugins.nodegraph.<mod>"`
-- finds them here: editor/3rd/lite/data/replay.lua); init.lua starts it. A Lua
-- file's tab flips between its text and its graph (plugins/tabflip.lua).
-- Its settings: config.lua (grid, rebuild delay, the flow's colour and fade,
-- zoom, header colours), applied at once when saved. It patches lite in many
-- places (tabs, the wheel, menus), so its code doesn't reload live: restart
-- the editor after changing it.
local P = ...
P.title = "Node graph"                         -- (its name in menus: Open with, the main menu's Plugins)
P.reloadable = false
local core = require "core"
local NG = require "plugins.nodegraph"
local T = require "plugins.nodegraph.theme"
local View = NG.View
P.view(View)                                       -- (its menu: "Plugin: nodegraph", last)
-- the main menu's Plugins > Node graph >: these, on its tab (with their keys)
require("core.command").add(function() local v = core.active_view return v and v:is(View) end, {
  ["nodegraph:changes"] = function() core.active_view:open_changes() end,   -- (diff.lua: the changes since it opened, a diff against any)
})
P.commands = {
  { "Find...", "nodegraph:find" }, { "Find next", "nodegraph:find-next" }, { "Find previous", "nodegraph:find-previous" },
  { "Changes and diff...", "nodegraph:changes" },
  { "Undo", "nodegraph:undo" }, { "Redo", "nodegraph:redo" },
  { "Select all", "nodegraph:select-all" }, { "Copy", "nodegraph:copy" }, { "Cut", "nodegraph:cut" }, { "Paste", "nodegraph:paste" },
  { "Go back", "nodegraph:go-back" }, { "Toggle breakpoint", "nodegraph:toggle-breakpoint" },
  { "Text / graph", "nodegraph:flip" }, { "Duplicate tab", "core:duplicate-tab" },
  { "Save", "nodegraph:save" },
}

local DEFAULTS = { grid = 24, rebuild_delay = 0.2, flow = "#ff9a2e", flow_fade = 0.6, far_zoom = 0.3, zoom_max = 3 }
local HEAD0 = {}                                   -- the header colours it started with (a missing one goes back)
for k, c in pairs(T.HEAD) do HEAD0[k] = { c[1], c[2], c[3], c[4] } end
local function hex(s)                              -- "#rrggbb" -> { r, g, b, 255 }, or nil
  if type(s) ~= "string" or not s:match("^#%x%x%x%x%x%x$") then return nil end
  return T.rgb(s)
end
local function set(t, c) t[1], t[2], t[3], t[4] = c[1], c[2], c[3], c[4] or 255 end

local function each_graph(fn)
  local function walk(node)
    if node.type == "leaf" then for _, v in ipairs(node.views) do if v:is(View) then fn(v) end end
    else walk(node.a); walk(node.b) end
  end
  if core.root_view then walk(core.root_view.root_node) end
end

local function apply()
  local c = P.read("config")
  c = type(c) == "table" and c or {}
  local function num(k, lo, hi)
    local v = type(c[k]) == "number" and c[k] or DEFAULTS[k]
    return math.max(lo, math.min(hi, v))
  end
  local grid = math.floor(num("grid", 0, 200))
  local relayout = grid ~= View.GRID
  View.GRID = grid
  View.REBUILD_DELAY = num("rebuild_delay", 0, 5)
  T.cfg.flow_fade = num("flow_fade", 0.01, 10)
  T.cfg.far_zoom = num("far_zoom", 0, 2)
  T.cfg.zoom_max = num("zoom_max", 1, 10)
  set(T.PULSE, hex(c.flow) or T.rgb(DEFAULTS.flow))
  for k, c0 in pairs(HEAD0) do set(T.HEAD[k], hex(type(c.headers) == "table" and c.headers[k]) or c0) end
  each_graph(function(v)
    if v.zoom and v.zoom > T.cfg.zoom_max then v.zoom = T.cfg.zoom_max end
    if relayout then v.change_id = nil end         -- (a new grid: laid out again)
  end)
  core.redraw = true
end
apply()
core.add_thread(function()                         -- saved (from the tree, or as text): at once
  while true do
    if P.changed("config") then apply() end
    coroutine.yield(0.5)
  end
end)

-- the common commands (source, reload, settings...), last in the graph's own menu
function View.plugin_menu()
  local pp = require "plugins.projectplugins"
  local items = {}
  for _, it in ipairs(pp.common_items(P.name)) do
    items[#items + 1] = { text = it.text, hint = it.info, fn = type(it.command) == "function" and it.command or function() end }
  end
  return items
end

return NG

-- canvas_graph.lua: plugins/canvas headless - a GraphView's model (connect,
-- an input reads one wire, delete, duplicate, typed pins), the camera's
-- maths, and canvas.to_lua (what a plugin saves) reading back the same.
-- Run from runtime/tests: luajit canvas_graph.lua (or lua5.4)
local dir = "../../editor/3rd/lite/data/plugins/canvas/"
SCALE, DATADIR = 1, "."
local View = {}; View.__index = View              -- (lite stubs)
function View:extend() local c = setmetatable({}, { __index = self }); c.__index = c; c.super = self; return c end
function View:new() self.position, self.size = { x = 0, y = 0 }, { x = 800, y = 600 } end
function View:is(c) local m = getmetatable(self) while m do if m == c then return true end m = m.super end return false end
function View:update() end
setmetatable(View, { __call = function(c, ...) local o = setmetatable({}, c); o:new(...); return o end })
local function callable(c) return setmetatable(c, { __index = c.super, __call = getmetatable(View).__call }) end
local stubs = {
  ["core"] = { redraw = false, add_thread = function() end, log = function() end },
  ["core.command"] = { add = function() end },
  ["core.keymap"] = { add = function() end, modkeys = {} },
  ["core.rootview"] = {},
  ["core.style"] = { error = { 1, 2, 3, 255 }, warn = { 1, 2, 3, 255 } },
  ["core.view"] = View,
  ["plugins.contextmenu"] = { DIVIDER = {}, register = function() end },
}
for k, v in pairs(stubs) do package.preload[k] = function() return v end end
for _, m in ipairs({ "theme", "draw", "view", "graph", "field", "scrollbar", "tip", "picker", "menu", "ui" }) do
  package.preload["plugins.canvas." .. m] = function() return dofile(dir .. m .. ".lua") end
end
system = { get_display_size = function() return 1920, 1080 end }
local canvas = dofile(dir .. "init.lua")

local ok, bad = 0, 0
local function check(c, what) if c then ok = ok + 1 else bad = bad + 1; print("FAIL: " .. what) end end

-- a view of two kinds
local G = canvas.GraphView:extend()
G.kinds = {
  col = { title = "Color", outs = { { "color", "color" } } },
  num = { title = "Value", outs = { { "value", "float" } } },
  mix = { title = "Mix", ins = { { "a", "color" }, { "b", "color" }, { "t", "float" } }, outs = { { "out", "color" } } },
}
callable(G)
local changes = 0
function G:on_change() changes = changes + 1 end
local v = G()
local c = v:add_node("col", 0, 0)
local m = v:add_node("mix", 200, 0)
local n = v:add_node("num", 0, 100)
check(c.id == 1 and m.id == 2 and n.id == 3, "ids count up")
v:connect(c.id, "color", m.id, "a")
v:connect(c.id, "color", m.id, "b")
check(#v.graph.links == 2, "an output feeds two inputs")
v:connect(c.id, "color", m.id, "a")
check(#v.graph.links == 2, "an input reads one wire (connecting again replaces)")
check(v:can_connect("float", "float") and not v:can_connect("float", "color") and v:can_connect("any", "color"), "pin types")
-- pins: outs first, then ins; x at the edges
local x, y = v:pin_xy(m, "out", 1)
check(x == m.x + v.node_w and y == m.y + v.head_h + 0.5 * v.row_h, "an output's pin")
x, y = v:pin_xy(m, "in", 2)
check(x == m.x and y == m.y + v.head_h + 2.5 * v.row_h, "an input's pin (after the outputs)")
local pn, side, i = v:pin_at(v:pin_xy(m, "in", 3))
check(pn == m and side == "in" and i == 3, "pin_at finds it")
check(v:node_at(m.x + 5, m.y + 5) == m, "node_at")
-- dragging a wire from Value's output to Mix's t, then a wrong type
v:on_canvas_pressed("left", v:pin_xy(n, "out", 1))
v:on_canvas_released("left", v:pin_xy(m, "in", 3))
check(v:link_into(m.id, "t") ~= nil, "a wire dragged out -> in")
v:on_canvas_pressed("left", v:pin_xy(n, "out", 1))
v:on_canvas_released("left", v:pin_xy(m, "in", 1))
local l = v:link_into(m.id, "a")
check(l and l.from == c.id, "a float can't feed a colour (the old wire stays)")
-- picking up a connected input's wire and dropping it on nothing
v:on_canvas_pressed("left", v:pin_xy(m, "in", 3))
v:on_canvas_released("left", -1000, -1000)
check(v:link_into(m.id, "t") == nil, "a wire picked up and dropped: gone")
-- moving a node drags the selection
v.sel = {}
v:on_canvas_pressed("left", m.x + 20, m.y + 5)
v:on_canvas_moved(m.x + 30, m.y + 15)
v:on_canvas_released("left", m.x + 30, m.y + 15)
check(m.x == 210 and m.y == 10, "a node dragged")
-- duplicate, delete
v:duplicate({ [c] = true })
check(#v.graph.nodes == 4 and v.graph.nodes[4].x == c.x + 24 and v.graph.nodes[4].id == 4, "duplicate")
v:remove_nodes({ [c] = true })
check(#v.graph.nodes == 3 and #v.graph.links == 0, "delete takes its wires")
check(changes > 0 and v.dirty, "edits mark it changed")

-- the camera
local cv = callable(canvas.View:extend())()
cv.position, cv.size = { x = 100, y = 50 }, { x = 400, y = 300 }
cv.cam = { x = 10, y = 20, zoom = 2 }
local sx, sy = cv:to_screen(5, 5)
check(sx == 120 and sy == 80, "to_screen")
local wx, wy = cv:to_world(sx, sy)
check(wx == 5 and wy == 5, "to_world")
cv:zoom_at(2, 300, 200)
local ax, ay = cv:to_world(300, 200)
check(math.abs(ax - (300 - 110) / 2) < 1e-9 and cv.cam.zoom == 4, "zoom_at keeps the point under the mouse")
function cv:bounds() return 0, 0, 100, 50 end
cv:fit(1)
local x1, y1 = cv:to_screen(0, 0)
local x2, y2 = cv:to_screen(100, 50)
check(math.abs((x2 - x1) - 400) < 1e-9 and math.abs((x1 + x2) / 2 - 300) < 1e-9 and math.abs((y1 + y2) / 2 - 200) < 1e-9, "fit: the bounds fill the view, centred")
check(cv.fitting, "fit: fitting (it fits again when resized)")
cv:pan_by(1, 1)
check(not cv.fitting, "a pan stops fitting")
check(canvas.draw.vh(10) == 108 and canvas.draw.vw(50) == 960, "vh / vw: a share of the monitor")

-- to_lua reads back the same
local data = { nodes = { { id = 1, kind = "col", x = -3, y = 0.35, data = { 0.95, 0.55, 0.2 } } },
               links = { { from = 1, out = "color", to = 2, input = "a" } }, ["end"] = true, [10] = "x" }
local src = canvas.to_lua(data)
local back = load("return " .. src, "=to_lua", "t", {})()
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, x in pairs(a) do if not same(x, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
check(same(data, back), "to_lua reads back the same")
check(src:find("0.35", 1, true) and not src:find("0.3499", 1, true), "to_lua: short numbers")

print(bad == 0 and ("canvas graph: " .. ok .. " checks ok") or ("canvas graph: " .. bad .. " failed"))
os.exit(bad == 0 and 0 or 1)

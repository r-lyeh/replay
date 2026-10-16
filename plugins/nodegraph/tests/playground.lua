-- playground: every kind of node the graph shows, in one file, to look at
-- them together and spot problems. Open it as a node graph (right-click the
-- tab). It also runs as a tiny world (edit tests\playground.lua): one node,
-- /playground, and its prints in the log.
-- (runtime/tests/tests.lua lays it out and moves every node of it headless.)
--@comment dx=0 dy=-40 w=420 h=60 title=playground: every node kind

local ecs = require("ecs")                         -- a module: call pins named from it

-- types: a ---@class makes a typed table node (slider, drop-down, colour)
---@alias Mode "slow"|"fast"
---@class Paddle
---@field speed number @range 0 10
---@field mode Mode
---@field tint Color
---@field alive boolean

---@type Paddle
local paddle = { speed = 3, mode = "slow", tint = { 200, 80, 80 } }

local cfg = {                                      -- a plain table: widgets per field
  volume = 7,          --@range 0 10
  level = "fast",      --@enum slow|fast|insane
  on = true,                                       -- a checkbox
  pos = { x = 10, y = 20 },                        -- a vector
  color = { 255, 128, 0 },                         -- a colour swatch
  hex = "#ff965a80",                               -- a hex colour string (tinted, picker on click)
  name = "player",
  list = { 1, 2, 3 },
  on_hit = function(who) print("hit", who) end,    -- a function in a field: its frame
}

-- locals: one, several, a value from a call
local a, b = 1, 2.5
local limit = 100
local w = ecs.world()

-- a local function: header with its parameters, a body flowing right
---@param x number
---@param y number
---@return number sum
---@return boolean big
local function add(x, y)
  local s = x + y
  return s, s > limit
end

-- a global function and a method
function greet(name) print("hi " .. name) end
local Counter = { n = 0 }
function Counter:bump(by) self.n = self.n + by end

-- expressions: math, comparison, and / or, not, #, .., nested calls
local m = (a + b) * 2 - 1
local cmp = a < b and not cfg.on
local len = #cfg.list
local text = cfg.name .. ":" .. tostring(m)
local clamped = math.max(-limit, math.min(limit, m))

-- calls: a statement, a method, the debug draw API, a module's method
print(add(a, b))
Counter:bump(2)
dd.cross(paddle.speed, 2, 5, "#ff965a80")
greet("you")

-- branches: if / elseif / else, a one-line if
if m > 10 then
  print("big")
elseif m > 5 then
  print("medium")
else
  print("small")
end
if cmp then cfg.on = false end

-- loops: numeric for, for each (pairs, ipairs), while, repeat / until, break
for i = 1, 3 do
  print(i)
end
for k, v in pairs(cfg) do
  if k == "stop" then break end
  print(k, v)
end
for _, n in ipairs(cfg.list) do print(n) end
local tries = 0
while tries < 3 do tries = tries + 1 end
repeat
  tries = tries - 1
until tries <= 0

-- do block, goto / label
do
  local inner = 1
  print(inner)
end
local count = 0
::again::
count = count + 1
if count < 3 then goto again end

-- set: fields, several at once
paddle.speed, paddle.alive = 4, true
cfg.pos.x = cfg.pos.x + 1

-- chips: a parameter, and a variable read 4+ times, show chips, not wires
local function step(dt)
  local t = dt * 2
  print(t, dt, dt, dt)
  return t
end

-- a lambda passed to a call (a system): its frame under the call
-- (a system's function takes nothing and returns the one that runs each frame)
local sys = ecs.system(function()
  return function(world, dt)
    local q = world:query("xform", "vel")
    for _, e in ipairs(q) do print(e, dt) end
  end
end)

-- a varargs function, multiple returns
local function pack(...)
  return select("#", ...), ...
end

-- a getter kept by a tag: `a` drawn as a get node feeding print
--@expr slot=1 get=a
print(a)

-- a far read: `paddle` declared ~100 lines above: a chip, not a long wire
print(paddle, clamped, len, text, sys, pack, step)

w:spawn("/playground", { paddle = paddle, score = { left = a, right = b } })   -- (components: data, no functions)

--[==[@float dx=40 dy=120
print("floating code: outside the flow, it doesn't run")
]==]

return w

-- call-00: call pins named after the parameters.
-- Expect: call add -> pins x, y (a local function); call greet -> name
--   (a global function); call Counter:bump -> self, by (a method);
--   call dd.text -> x, y, text (from runtime/meta/dd.lua); call print ->
--   ... ; an unknown function: arg1, arg2.
local function add(x, y) return x + y end
function greet(name) print("hi " .. name) end
local Counter = { n = 0 }
function Counter:bump(by) self.n = self.n + by end

add(1, 2)
greet("you")
Counter:bump(5)
dd.text(10, 20, "hello")
unknown_thing(1, 2)

---@meta
-- lua.lua - the parts of Lua's standard library games use, for the editor:
-- the node graph names call pins after these parameters.

---@param ... any
function print(...) end
---@param modname string
function require(modname) end
---@param v any
---@return string
function tostring(v) end
---@param s string|number
---@param base? integer
---@return number
function tonumber(s, base) end
---@param v any
---@return string
function type(v) end
---@param v any
---@param message? string
function assert(v, message) end
---@param message string
---@param level? integer
function error(message, level) end
---@param f function
function pcall(f, ...) end
---@param n integer|string
function select(n, ...) end
---@param t table
function pairs(t) end
---@param t table
function ipairs(t) end
---@param t table
---@param k? any
function next(t, k) end
---@param t table
---@param mt? table
---@return table
function setmetatable(t, mt) end
---@param t any
---@return table
function getmetatable(t) end
---@param t table
---@param k any
function rawget(t, k) end
---@param t table
---@param k any
---@param v any
function rawset(t, k, v) end

-- (parameter types: the graph colours pins by them, warns on a wrong one,
-- and converts what's wired in: a number into a string pin -> tostring(x))
math = {}
---@param x number
---@return integer
function math.floor(x) end
---@param x number
---@return integer
function math.ceil(x) end
---@param x number
---@return number
function math.abs(x) end
---@param x number
---@return number
function math.min(x, ...) end
---@param x number
---@return number
function math.max(x, ...) end
---@param x number
---@return number
function math.sqrt(x) end
---@param x number
---@return number
function math.sin(x) end
---@param x number
---@return number
function math.cos(x) end
---@param x number
---@return number
function math.tan(x) end
---@param y number
---@param x? number
---@return number
function math.atan(y, x) end
---@param x number
---@return number
function math.exp(x) end
---@param x number
---@param base? number
---@return number
function math.log(x, base) end
---@param m? integer
---@param n? integer
---@return number
function math.random(m, n) end
---@param x number
---@param y number
---@return number
function math.fmod(x, y) end
---@param x number
---@return integer
function math.tointeger(x) end

string = {}
---@param fmt string
---@return string
function string.format(fmt, ...) end
---@param s string
---@param i integer
---@param j? integer
---@return string
function string.sub(s, i, j) end
---@param s string
---@return integer
function string.len(s) end
---@param s string
---@return string
function string.upper(s) end
---@param s string
---@return string
function string.lower(s) end
---@param s string
---@param n integer
---@param sep? string
---@return string
function string.rep(s, n, sep) end
---@param s string
---@param pattern string
---@param init? integer
---@param plain? boolean
---@return integer
function string.find(s, pattern, init, plain) end
---@param s string
---@param pattern string
---@param init? integer
---@return string
function string.match(s, pattern, init) end
---@param s string
---@param pattern string
---@return function
function string.gmatch(s, pattern) end
---@param s string
---@param pattern string
---@param repl string|table|function
---@param n? integer
---@return string
function string.gsub(s, pattern, repl, n) end
---@param s string
---@param i? integer
---@param j? integer
---@return integer
function string.byte(s, i, j) end
---@return string
function string.char(...) end
---@param s string
---@return string
function string.reverse(s) end

table = {}
---@param t table
function table.insert(t, pos_or_value, value) end
---@param t table
---@param pos? integer
function table.remove(t, pos) end
---@param t table
---@param sep? string
---@param i? integer
---@param j? integer
---@return string
function table.concat(t, sep, i, j) end
---@param t table
---@param comp? function
function table.sort(t, comp) end
---@param t table
---@param i? integer
---@param j? integer
function table.unpack(t, i, j) end

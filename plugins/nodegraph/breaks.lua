-- breaks.lua - breakpoints, shared by the graph and the text (ours, not upstream lite).
-- A breakpoint is a line of a file. The world stops its tick there (the game
-- paused mid-frame; play continues it): set in the host with host_break_set.
-- Toggle: RMB on a graph node > Add / Remove breakpoint, a click in the code's
-- gutter, or F9 (the code: the caret's line; a graph: the selected node).
-- Shown: a red dot on the node / in the gutter. Kept per file in the graph
-- tabs' workspace state (nodegraph view get_state).
local core = require "core"

local B = { by = {} }                              -- normalized absolute file -> { [line] = true }

local function norm(f) return (tostring(f):gsub("\\", "/"):lower()) end
local abs_of, key_of = {}, {}                      -- (asked per node per frame: the file system once per name)
function B.abs(filename)
  if not filename then return nil end
  local a = abs_of[filename]
  if not a then a = system.absolute_path(filename) or filename; abs_of[filename] = a end
  return a
end
function B.has(filename, line)
  if not filename then return false end
  local k = key_of[filename]
  if not k then k = norm(B.abs(filename)); key_of[filename] = k end
  local t = B.by[k]
  return t and t[line] or false
end
-- a function defined on that line (local function f(...), x = function...):
-- Lua runs its definition on its "end" line, so the world is told that line
-- too (an alias: a stop there is reported as this line; not when it's the
-- function's own return). nil: no function starts there, or it's one line.
local function parsed(abs)                         -- the file's text (an open doc's, else the disk's) and AST
  local src
  for _, d in ipairs(core.docs or {}) do
    if d.filename and norm(B.abs(d.filename)) == norm(abs) then src = d:get_text(1, 1, math.huge, math.huge) end
  end
  if not src then
    local f = io.open(abs, "rb")
    if not f then return end
    src = f:read("*a"); f:close()
  end
  local ok, ast = pcall(require("plugins.nodegraph.luaparse").parse, src)
  if ok and ast then return src, ast end
end
local function line_of(src, pos)
  local l = 1
  for _ in src:sub(1, pos):gmatch("\n") do l = l + 1 end
  return l
end
local function def_end(abs, line)
  local src, ast = parsed(abs)
  if not src then return end
  local found
  local function walk(e)
    if type(e) ~= "table" or found then return end
    if e.tag == "Function" and e.body and e.line == line and e.epos then found = e; return end
    for _, v in pairs(e) do if type(v) == "table" then walk(v) end end
  end
  walk(ast)
  if not found then return end
  local l = line_of(src, found.epos)
  return l > line and l or nil
end
B.def_end = def_end
-- the last line of what starts on that line (a call over several lines):
-- continued from a stop there, the world doesn't stop again in it
local function stmt_end(abs, line)
  local src, ast = parsed(abs)
  if not src then return end
  local best = 0
  local function walk(e)
    if type(e) ~= "table" then return end
    if e.tag and e.line == line and e.epos and e.epos > best then best = e.epos end
    for _, v in pairs(e) do if type(v) == "table" then walk(v) end end
  end
  walk(ast)
  local l = best > 0 and line_of(src, best)
  return l and l > line and l or nil
end
B.stmt_end = stmt_end

function B.set(filename, line, on)
  local abs = B.abs(filename)
  if not abs or not line then return end
  local k = norm(abs)
  local t = B.by[k] or {}
  t[line] = on or nil
  B.by[k] = next(t) and t or nil
  local hs = rawget(_G, "host_break_set")
  if hs then
    hs(abs, line, on and true or false)
    B.alias = B.alias or {}
    local ak = k .. ":" .. line
    local old = B.alias[ak]
    if old then hs(abs, old, false, line, line); B.alias[ak] = nil end
    local e = on and def_end(abs, line)
    if e then hs(abs, e, true, line, line); B.alias[ak] = e end
    local se = stmt_end(abs, line)                 -- (as < 0: that statement's last line)
    if se then hs(abs, line, on and true or false, -se, 0) end
    if e then hs(abs, e, on and true or false, -e, 0) end
  end
  core.redraw = true
end
function B.toggle(filename, line)
  local on = not B.has(filename, line)
  B.set(filename, line, on)
  return on
end
function B.lines(filename)                        -- sorted, for the workspace
  local t = filename and B.by[norm(B.abs(filename))]
  local l = {}
  for k in pairs(t or {}) do l[#l + 1] = k end
  table.sort(l)
  return l
end
function B.same(a, b) return a and b and norm(B.abs(a)) == norm(B.abs(b)) end

-- where the world stopped (host_break_where): file, line, which stop
function B.where()
  local hw = rawget(_G, "host_break_where")
  if hw then return hw() end
end

return B

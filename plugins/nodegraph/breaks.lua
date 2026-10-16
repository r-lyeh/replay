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

-- the line that last set a variable, in the frame shown (the probe's lines,
-- each with the order it last ran in, s, and the locals as it started): the
-- line after which its value differs (or it first exists). nil: never seen
-- changing (a parameter, or set before the frame: the caller decides).
-- upto: a line (its run): only what ran before it counts. lines: the file's
-- text lines (the line that set it names it: lines run elsewhere don't count).
function B.changed_at(P, name, upto, lines)
  if not (P and P.lines and name) then return nil end
  local list = {}
  for l, r in pairs(P.lines) do if r.s then list[#list + 1] = { l = l, s = r.s, v = r.v[name] } end end
  table.sort(list, function(a, b) return a.s < b.s end)
  local stop = upto and P.lines[upto] and P.lines[upto].s or math.huge
  local at
  for i = 1, #list - 1 do
    local a, b = list[i], list[i + 1]
    if b.s > stop then break end
    if a.v ~= b.v and b.v ~= nil then
      local t = lines and lines[a.l]
      if not lines or (t and t:find("%f[%w_]" .. name:gsub("%p", "%%%0") .. "%f[^%w_]")) then at = a.l end
    end
  end
  return at
end

-- the names a line assigns (its targets: `a.b, c = ...`, `local x = ...`; only a
-- line that starts with the assignment)
function B.targets(text)
  text = (text or ""):gsub("%-%-.*$", "")
  local i = 1
  while true do
    local a = text:find("=", i, true)
    if not a then return {} end
    local before, after = text:sub(a - 1, a - 1), text:sub(a + 1, a + 1)
    if after == "=" then i = a + 2
    elseif before:match("[=~<>]") then i = a + 1
    else
      local out = {}
      local lhs = text:sub(1, a - 1):gsub("^%s*local%s+", "")
      for piece in lhs:gmatch("[^,]+") do         -- (only names: `if c then x = 1` may not run it)
        local t = piece:match("^%s*([%a_][%w_%.]*)%s*$")
        if not t then return {} end
        out[#out + 1] = t
      end
      return out
    end
  end
end
-- the last line (run before `upto`, in the run order) whose text assigns
-- `expr` itself (x.y in `x.x, x.y = ...`); inclusive: `upto` counts too (it ran)
function B.assigned_at(P, expr, upto, lines, inclusive)
  if not (P and P.lines and expr and lines) then return nil end
  local stop = upto and P.lines[upto] and P.lines[upto].s or math.huge
  local at, at_s
  for l, r in pairs(P.lines) do
    local s = r.s or 0
    if (s < stop or (inclusive and s == stop)) and (not at_s or s > at_s) then
      for _, t in ipairs(B.targets(lines[l])) do
        if t == expr then at, at_s = l, s; break end
      end
    end
  end
  return at
end

-- where the world stopped (host_break_where): file, line, which stop
function B.where()
  local hw = rawget(_G, "host_break_where")
  if hw then return hw() end
end

return B

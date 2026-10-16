-- graph.lua - a parsed Lua file (luaparse) -> a laid-out node graph.
-- Part of the nodegraph plugin (ours, not upstream lite). No drawing here:
-- the view (init.lua) draws what this returns, so it can be tested headless.
--
--   local g = graph.build(ast, { font = f, code_font = cf })
--   g.nodes  = { { id, kind, title, lines = {...}, x, y, w, h, line, pos, epos } }
--   g.frames = { { title, x, y, w, h, head = node } }    functions
--   g.exec   = { { from = id, to = id, label, back = bool } }   control flow
--   g.data   = { { from = id, to = id, name, lambda = true } }   a statement -> the functions it holds
--   g.links  = { { from = id, out = k, to = id, inp = i } }  a variable: declared -> read
--
-- Sockets (Blender style), when opts.res (resolve.resolve(ast)) is given:
--   n.outs = { { name, decl, y } }   the variables a node declares (right edge)
--   n.ins  = { { name, decl, uses, y } }   the variables its own expressions read
--            (left edge; decl = nil: a global). y: the socket's row, from n.y.
--   n.head_h: height of the coloured header; n.body_y: where the code starts.
--   n.diags = { { level = "error", msg } }: what will fail when it runs
--            (indexing / calling / arithmetic on a literal nil...), shown at
--            its bottom from n.diag_y; g.errors counts them.
--   g.w, g.h = size of the whole graph
--
-- Layout annotations (step 2): comments that move nodes, kept in the source.
--   --@node dx=40 dy=-12 color=#e06c75 alpha=0.6   on its own line, right above a statement
--   --@frame dx=0 dy=80                            the first line(s) inside a function body
--   --@expr slot=2 dx=-30 dy=12                    above a statement: the expression node feeding its pin 2
--   --@comment dx=0 dy=-20 w=300 h=120 title=Movement   a comment box (from its function's header),
--                                                  first lines of the function body (top of the file)
--
-- Names (LuaLS annotations, right above a function):
--   ---@param a number          a parameter's type, shown on the header's output
--   ---@return number sum       the name of a return value: the pin of its
--                               `return` nodes, and the output of call nodes
-- g.fn_info[func] = { line, indent, params = { name = type }, returns = { { type, name, line } } }
-- dx/dy are offsets from the automatic position (so a placed node stays put
-- relative to its neighbours when other code changes). A frame moves with
-- everything in it (floating code too); a node moves alone (its expression
-- inputs, branches, loop body and lambdas stay put). An
-- elseif keeps its --@node line right above its `elseif`.
-- Each node that can carry a tag gets n.edit = { kind, tag, insert_line, indent }.
--
-- Level of detail (step 1, read-only): one node per statement; expressions
-- are shown as their source text (nested functions as "fn(args)", drawn as
-- their own frame to the right, wired from the statement that holds them).
-- Layout: the file's top-level statements (its functions, its events) are
-- stacked top to bottom; inside a function the flow goes left to right, like
-- Blender / UE5: each statement right of the previous one, an if's branches
-- on rows below each other (the condition on the left), a loop's body on the
-- row under the loop (with a wire back to it), a statement's lambdas under it.

local M = {}

local PADX, PADY, GAPX, GAPY, INDENT, FPAD = 10, 4, 46, 26, 30, 12
local CHEV = 12                                   -- room for a node's collapse chevron, before its title
M.CHEV, M.PADX, M.FPAD = CHEV, PADX, FPAD
-- a function's flow runs left to right and wraps onto a new row past this
-- width (from where the function's body starts): the flow wire snakes back
M.WRAP_W = 16000
-- variables read this many times (and every function parameter) get no
-- wires: each pin that reads one shows a chip with its name instead (UE's
-- "get" nodes); hovering a chip lights up the variable everywhere
M.CHIP_READS = 4
local function chipped(d) return d and (d.kind == "param" or #(d.refs or {}) >= M.CHIP_READS) end
M.CHIP_LINES = 40                                  -- a read this many lines below its declaration: a chip too (no long wire)
M.CHIP_PAD, M.CHIP_GAP = 12, 10                    -- a chip: its name + PAD wide, GAP left of its pin
local SROW = 4                                     -- extra height of a socket row (on top of the font's)
local MAXC = 46                                    -- chars per text line in a node

-- the text of an expression, nested functions shortened to fn(args)
local function text_of(src, e, lambdas)
  local spans = {}
  local function collect(n)
    if type(n) ~= "table" then return end
    if n.tag == "Function" then                    -- shown as fn(args): its body gets its own frame
      spans[#spans + 1] = n
      if lambdas then lambdas[#lambdas + 1] = n end
      return
    end
    for _, v in pairs(n) do
      if type(v) == "table" then
        if v.tag then collect(v) else for _, x in pairs(v) do collect(x) end end
      end
    end
  end
  collect(e)
  table.sort(spans, function(a, b) return a.pos < b.pos end)
  local out, at = {}, e.pos
  for _, f in ipairs(spans) do
    out[#out + 1] = src:sub(at, f.pos - 1)
    out[#out + 1] = "fn(" .. table.concat(f.params, ", ") .. (f.vararg and (#f.params > 0 and ", ..." or "...") or "") .. ")"
    at = f.epos + 1
  end
  out[#out + 1] = src:sub(at, e.epos)
  local s = table.concat(out):gsub("%-%-%[(=*)%[.-%]%1%]", " "):gsub("%-%-[^\n]*", " ")
  return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- wrap a string into lines of at most MAXC chars (at most 4 lines)
local function wrap(s, out)
  while #s > MAXC do
    local cut = MAXC
    for i = MAXC, math.floor(MAXC / 2), -1 do
      if s:sub(i, i):match("[ ,%(%)]") then cut = i; break end
    end
    out[#out + 1] = s:sub(1, cut):gsub(" $", "")
    s = s:sub(cut + 1):gsub("^ ", "")
    if #out >= 4 then out[#out] = out[#out] .. " ..."; return out end
  end
  if s ~= "" then out[#out + 1] = s end
  return out
end

local function list_text(src, list, lambdas)
  local t = {}
  for i, e in ipairs(list) do t[i] = text_of(src, e, lambdas) end
  return table.concat(t, ", ")
end

-- "--@node dx=1 dy=2" -> { kind = "node", keys = { "dx", "dy" }, vals = { dx = "1", dy = "2" } }
function M.parse_tag(text)
  local kind, rest = text:match("^%-%-@(%a+)(.*)$")
  if kind ~= "node" and kind ~= "frame" and kind ~= "expr" and kind ~= "comment" and kind ~= "start" then return nil end
  local t = { kind = kind, keys = {}, vals = {} }
  if kind == "comment" then                        -- a comment box: its title is the rest of the line
    local title = rest:match("title=(.*)$")
    if title then rest = rest:sub(1, #rest - #title - 6); t.title = title:gsub("\\n", "\n") end   -- (its lines: \n in the tag)
  end
  for k, v in rest:gmatch("([%w_]+)=(%S+)") do
    if t.vals[k] == nil then t.keys[#t.keys + 1] = k end
    t.vals[k] = v
  end
  return t
end

-- the comment for a tag, or nil when it holds nothing
function M.tag_text(t)
  local out = {}
  for _, k in ipairs(t.keys) do
    if t.vals[k] ~= nil then out[#out + 1] = k .. "=" .. t.vals[k] end
  end
  if #out == 0 then return nil end
  if t.kind == "expr" and #out == 1 and t.vals.slot then return nil end   -- just its slot: nothing to keep
  if t.kind == "comment" then out[#out + 1] = "title=" .. (t.title or ""):gsub("\n", "\\n") end   -- (one line: its newlines as \n)
  return "--@" .. t.kind .. " " .. table.concat(out, " ")
end

-- diagnostics: what an expression will fail on at run time, statically
-- certain cases only (a literal nil where a value is needed, as left behind
-- by a disconnect). More (warnings) can be added here later.
local function is_nil(e)
  while type(e) == "table" and e.tag == "Paren" do e = e.e end
  return type(e) == "table" and e.tag == "Nil"
end
local ARITH = { ["+"] = "perform arithmetic on", ["-"] = "perform arithmetic on", ["*"] = "perform arithmetic on",
  ["/"] = "perform arithmetic on", ["//"] = "perform arithmetic on", ["%"] = "perform arithmetic on",
  ["^"] = "perform arithmetic on", ["&"] = "perform bitwise operation on", ["|"] = "perform bitwise operation on",
  ["~"] = "perform bitwise operation on", ["<<"] = "perform bitwise operation on", [">>"] = "perform bitwise operation on",
  [".."] = "concatenate", ["<"] = "compare", [">"] = "compare", ["<="] = "compare", [">="] = "compare" }
local NEEDS_TABLE = { pairs = true, ipairs = true, next = true, setmetatable = true, rawget = true, rawset = true }
local function diagnose(e, out)
  if type(e) ~= "table" or e.tag == "Function" then return end   -- a lambda: diagnosed in its own frame
  local t, msg = e.tag, nil
  if t == "Index" and is_nil(e.obj) or t == "Invoke" and is_nil(e.obj) then msg = "attempt to index a nil value"
  elseif t == "Call" and is_nil(e.fn) then msg = "attempt to call a nil value"
  elseif t == "Call" and e.fn.tag == "Id" and NEEDS_TABLE[e.fn.name] and is_nil(e.args[1]) then
    msg = "bad argument #1 to '" .. e.fn.name .. "' (table expected, got nil)"
  elseif t == "Binop" and ARITH[e.op] and (is_nil(e.l) or is_nil(e.r)) then msg = "attempt to " .. ARITH[e.op] .. " a nil value"
  elseif t == "Unop" and is_nil(e.e) and e.op ~= "not" then
    msg = e.op == "#" and "attempt to get length of a nil value" or "attempt to perform arithmetic on a nil value"
  end
  if msg then out[#out + 1] = msg end
  for k, v in pairs(e) do
    if type(v) == "table" and k ~= "body" then
      if v.tag then diagnose(v, out) else for _, x in pairs(v) do diagnose(x, out) end end
    end
  end
end

local function parse_color(v)                      -- "#rrggbb" -> { r, g, b, 255 }
  local r, g, b = tostring(v or ""):match("^#(%x%x)(%x%x)(%x%x)$")
  if r then return { tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), 255 } end
end

-- API definitions (LuaLS ---@meta stubs, runtime/meta/*.lua): the functions
-- they declare, `function dd.text(x, y, text, color) end`, by name ->
-- { params = {...}, types = { name = type } }. Calls to them get their
-- parameters' names on their pins (the file's own functions win).
-- Also any Lua module (runtime/ecs.lua...): its `function M.f()` and
-- `function Class:m()`; what a function returns when it's an object of a
-- class (`return setmetatable(t, World)`, or ---@return World); the name of
-- a vararg's pins (`---@param ... string component` -> component 1, 2...).
-- Second result: { ret = the name it returns (`return ecs`), requires = {...} }.
function M.read_meta(src, parse, into)
  into = into or {}
  local info = { requires = {} }
  local ast = parse(src)
  if not ast then return into, info end
  local above = {}                                 -- line -> the comment that starts it
  for _, c in ipairs(ast.comments or {}) do above[c.line] = c.text end
  local function setmeta_class(e)                  -- setmetatable(..., Class) -> "Class"
    if e and e.tag == "Call" and e.fn.tag == "Id" and e.fn.name == "setmetatable" and e.args[2] and e.args[2].tag == "Id" then
      return e.args[2].name
    end
  end
  local function returned_class(f)
    for _, st in ipairs(f.body.stmts) do
      if st.tag == "Return" and st.exprs[1] then
        local r = st.exprs[1]
        local c = setmeta_class(r)
        if c then return c end
        if r.tag == "Id" then
          for _, s2 in ipairs(f.body.stmts) do
            if s2.tag == "Local" then
              for k, nm in ipairs(s2.names) do if nm == r.name then c = setmeta_class(s2.exprs[k]) end end
            end
          end
          if c then return c end
        end
      end
    end
  end
  -- a function's entry: its parameters, their ---@param types, the vararg's
  -- name, what it returns (a class)
  local function entry_of(func, line, method)
    local ps = {}
    for i, p in ipairs(func.params) do if not (method and i == 1) then ps[#ps + 1] = p end end
    if func.vararg then ps[#ps + 1] = "..." end
    local types, vname, ret, l = {}, nil, nil, (line or 0) - 1
    local doc, rets = {}, {}                       -- (bottom up: inserted at the front)
    while above[l] do
      local n, t = above[l]:match("^%-%-%-@param%s+([%a_][%w_]*%??)%s+(%S+)")
      if n then types[(n:gsub("%?$", ""))] = t end
      local d = not above[l]:match("^%-%-%-@") and above[l]:match("^%-%-%-%s?(.*)$")
      if d then table.insert(doc, 1, d) end
      local rr = above[l]:match("^%-%-%-@return%s+(%S+)")
      if rr then table.insert(rets, 1, rr) end
      local vn = above[l]:match("^%-%-%-@param%s+%.%.%.%s+%S+%s+([%a_][%w_]*)")
      if vn then vname = vn end
      local rt = above[l]:match("^%-%-%-@return%s+([%a_][%w_%.]*)")
      if rt then ret = rt end
      l = l - 1
    end
    return { params = ps, types = types, method = method, vararg_name = vname, ret_class = returned_class(func) or ret, line = line,
             doc = #doc > 0 and doc or nil, rets = #rets > 0 and rets or nil }
  end
  local function path(e)                           -- M.f / M.sub.f as text
    if e.tag == "Id" then return e.name end
    if e.tag == "Index" and e.name then local p = path(e.obj); return p and (p .. "." .. e.name) end
  end
  local locals = {}                                -- local function f(...): reachable when exported
  local function value_entry(e, line)              -- what a value is, when it's a function
    while e and e.tag == "Paren" do e = e.e end
    if not e then return nil end
    if e.tag == "Function" then return entry_of(e, line) end
    local p = path(e)
    return p and (locals[p] or into[p]) or nil
  end
  local function table_fields(prefix, t, line)     -- { f = function() end, g = g }: prefix.f, prefix.g
    for _, fl in ipairs(t.fields or {}) do
      local key = fl.name or (fl.key and fl.key.tag == "String" and fl.key.raw:sub(2, -2))
      local en = key and key:match("^[%a_][%w_]*$") and value_entry(fl.value, fl.value and fl.value.line or line)
      if en then into[prefix .. "." .. key] = en end
    end
  end
  for _, s in ipairs(ast.body.stmts) do
    if s.tag == "Function" and s.func then         -- function M.f() / function Class:m()
      into[s.name] = entry_of(s.func, s.line, s.method)
    elseif s.tag == "LocalFunction" and s.func then
      locals[s.name] = entry_of(s.func, s.line)
    elseif s.tag == "Set" then                     -- M.f = function() end / M.f = f / M.alias = M.g
      for k, tg in ipairs(s.targets) do
        local p = tg.tag == "Index" and path(tg)
        local en = p and value_entry(s.exprs[k], s.line)
        if en then into[p] = en end
        if p and s.exprs[k] and s.exprs[k].tag == "Table" then table_fields(p, s.exprs[k], s.line) end
      end
    elseif s.tag == "Local" then                   -- local X = require("name"); local M = { f = ... }
      for k, e in ipairs(s.exprs) do
        if e.tag == "Call" and e.fn.tag == "Id" and e.fn.name == "require" and e.args[1] and e.args[1].tag == "String" then
          info.requires[#info.requires + 1] = { alias = s.names[k], name = e.args[1].raw:sub(2, -2) }
        elseif e.tag == "Table" and s.names[k] then
          table_fields(s.names[k], e, s.line)
        elseif e.tag == "Function" and s.names[k] then
          locals[s.names[k]] = entry_of(e, s.line)
        end
      end
    elseif s.tag == "Return" and s.exprs[1] and s.exprs[1].tag == "Id" then   -- return M
      info.ret = s.exprs[1].name
    elseif s.tag == "Return" and s.exprs[1] and s.exprs[1].tag == "Table" then   -- return { f = f, ... }
      info.ret = "(module)"
      table_fields("(module)", s.exprs[1], s.line)
    end
  end
  return into, info
end

-- a folder world's classes (graph.lua: world classes): the world is the
-- nearest folder above the file with a classes/ folder and systems/ or
-- objects/ beside it; classes/<name>/<member>.lua each return a member:
-- described ({ type = ..., value = ... }) or a plain value.
-- -> { name = { { name, text, lit, d }, ... } }
-- (the build's opts.world_classes)
function M.folder_classes(filename, fs)   -- fs: { list(dir) -> names, is_dir(path) }
  local is_dir = fs.is_dir
  local dir = filename and filename:match("^(.*)[/\\][^/\\]*$")
  for _ = 1, 8 do
    if not dir then return nil end
    if is_dir(dir .. "/classes") and (is_dir(dir .. "/systems") or is_dir(dir .. "/objects")) then break end
    dir = dir:match("^(.*)[/\\][^/\\]*$")
  end
  if not dir or not is_dir(dir .. "/classes") then return nil end
  local function value(file)                       -- its value (data: no globals)
    local fh = io.open(file, "rb")
    if not fh then return nil end
    local src = fh:read("*a")
    fh:close()
    local fn = load(src, "=" .. file, "t", {})
    local ok, v = pcall(fn or error)
    if ok then return v end
  end
  local function lit(v, depth)                     -- a value as Lua text
    depth = depth or 0
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    if depth > 4 then return "{}" end
    local parts, n, keys = {}, #v, {}
    for i = 1, n do parts[#parts + 1] = lit(v[i], depth + 1) end
    for k in pairs(v) do if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. lit(k) .. "]")
      parts[#parts + 1] = key .. " = " .. lit(v[k], depth + 1)
    end
    return #parts == 0 and "{}" or ("{ " .. table.concat(parts, ", ") .. " }")
  end
  local out = {}
  for _, name in ipairs(fs.list(dir .. "/classes") or {}) do
    local cdir = dir .. "/classes/" .. name
    if name:match("^[%a_][%w_]*$") and is_dir(cdir) then
      local fields = {}
      for _, f in ipairs(fs.list(cdir) or {}) do
        local fname = f:match("^([%a_][%w_]*)%.lua$")
        local v = fname and value(cdir .. "/" .. f)
        if v ~= nil then
          local d = type(v) == "table" and type(v.type) == "string" and v or nil   -- (described, or a plain value)
          local val = d and d.value or (not d and v)
          fields[#fields + 1] = { name = fname, d = d, lit = type(val),
                                  text = val ~= nil and lit(val) or (d.container and "{}" or "nil") }
        end
      end
      out[name] = fields
    end
  end
  return out
end

-- a folder world's file: what its returned value is (the build's
-- opts.file_kind / file_desc): "member" (classes/<x>/<m>.lua: a member's
-- description), "meta" (<node>/meta.lua: its fields' descriptions), "value"
-- (<node>/<f>.lua, and desc: its meta.lua's entry for f, if any), or nil
function M.file_info(filename)
  if not filename then return nil end
  local f = filename:gsub("\\", "/")
  local dir, base = f:match("^(.*)/([^/]+)%.lua$")
  if not dir then return nil end
  if dir:match("/classes/[^/]+$") then return "member" end
  if base == "meta" then return "meta" end
  local fh = io.open(dir .. "/meta.lua", "rb")
  if not fh then return "value" end
  local text = fh:read("*a")
  fh:close()
  local fn = load(text, "=meta", "t", {})
  local ok, meta = pcall(fn or error)
  local d = ok and type(meta) == "table" and meta[base]
  return "value", type(d) == "table" and type(d.type) == "string" and d or nil
end

function M.build(ast, opts)
  local src = ast.src
  local font, cfont = opts.font, opts.code_font or opts.font
  local lh, clh = font:get_height(), cfont:get_height()
  local floating = 0                               -- laying out floating code (> 0): no run-time diagnostics
  local g = { nodes = {}, frames = {}, exec = {}, data = {}, links = {}, w = 0, h = 0, src = src }
  local wrows, wcount = opts.warn_rows or {}, {}    -- warnings of the last build, by node key: rows sized in (see the end)
  local res = opts.res
  local use_at, decl_at = {}, {}                   -- (floating code adds its own: see below)
  if res then
    for _, u in ipairs(res.uses) do use_at[u.pos] = u end
    for p, d in pairs(res.decl_at) do decl_at[p] = d end
  end
  local node_of = {}                               -- AST statement / function -> node id
  local frame_of = {}                              -- Function expr -> frame

  -- source lines: where they start, their indentation, the tags on them
  local line_start = { 1 }
  for i in src:gmatch("()\n") do line_start[#line_start + 1] = i + 1 end
  local function line_of(pos)
    local lo, hi = 1, #line_start
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if line_start[mid] <= pos then lo = mid else hi = mid - 1 end
    end
    return lo
  end
  local function chip_for(d, upos)                 -- a chip instead of a wire (see chipped, CHIP_LINES)
    if chipped(d) then return true end
    return d and upos and d.pos and d.pos > 0 and (line_of(upos) - line_of(d.pos)) > M.CHIP_LINES or false
  end
  local function starts_line(pos)                  -- nothing but spaces before it on its line
    return src:sub(line_start[line_of(pos)], pos - 1):match("^%s*$") ~= nil
  end
  local function indent_of(l)
    local a = line_start[l]
    return a and src:match("^[ \t]*", a) or ""
  end
  local tags = {}                                  -- line -> tag (whole-line --@ comments)
  for _, c in ipairs(ast.comments or {}) do
    local t = M.parse_tag(c.text)
    if t and starts_line(c.pos) then t.line = c.line; tags[c.line] = t end
  end
  -- inline tags, for what shares its line with other code (no line of its own
  -- above it): block comments right before it, e.g.
  --   if hit then --[[@node dx=40]] --[[@expr slot=1 dy=24]] tp = f(x) end
  --   function(who) --[[@frame dx=40]] print(who) end
  -- inline_at: the position they stand before -> { node =, frame =, exprs = { [slot] = } }
  local inline_at = {}
  do
    local list = {}
    for _, c in ipairs(ast.comments or {}) do
      local body = not starts_line(c.pos) and c.text:match("^%-%-%[%[(@%a+[^\n]-)%]%]$")
      local t = body and M.parse_tag("--" .. body)
      if t and (t.kind == "node" or t.kind == "frame" or t.kind == "expr") then
        t.line, t.pos, t.epos, t.inline = c.line, c.pos, c.epos, true
        list[#list + 1] = t
      end
    end
    for i = #list, 1, -1 do                        -- (a run of them: all before the same code)
      local t = list[i]
      local after = src:find("%S", t.epos + 1) or (#src + 1)
      local nxt = list[i + 1]
      if nxt and nxt.pos == after then after = nxt.target end
      t.target = after
      local at = inline_at[after] or { exprs = {} }
      inline_at[after] = at
      if t.kind == "expr" then
        if t.vals.slot and t.vals.slot:match("^%d+[%d%.]*$") then at.exprs[t.vals.slot] = t end
      else
        at[t.kind] = at[t.kind] or t
      end
    end
  end
  local comment_at, trail_at = {}, {}              -- line -> a comment that starts it / ends it
  for _, c in ipairs(ast.comments or {}) do
    if starts_line(c.pos) then comment_at[c.line] = c else trail_at[c.line] = c end
  end
  -- a table field's widget hint, a comment at the end of its line:
  --   speed = 1.5,    --@range 0 10 0.5     a slider (from, to, step)
  --   mode = "fast",  --@enum slow|fast     a drop-down
  local function field_hint(line)
    local c = trail_at[line]
    if not c then return nil end
    local a, b, st = c.text:match("^%-%-@range%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s*(%-?[%d%.]*)")
    if a then return { range = { tonumber(a), tonumber(b), tonumber(st) } } end
    local list = c.text:match("^%-%-@enum%s+(%S+)")
    if list then
      local items = {}
      for it in list:gmatch("[^|]+") do items[#items + 1] = it end
      return { enum = items }
    end
  end
  local expanded = opts.expanded or {}             -- big tables shown whole (by their position)
  -- the LuaLS annotations of the function at line `l`: the comment lines right above it
  g.fn_info = {}
  local function annotations(l)
    local info = { line = l, indent = indent_of(l), params = {}, returns = {} }
    local k = l - 1
    while comment_at[k] do k = k - 1 end
    for cl = k + 1, l - 1 do
      local t = comment_at[cl].text
      local pname, ptype = t:match("^%-%-%-@param%s+([%a_][%w_]*%??)%s+(%S+)")
      if pname then info.params[(pname:gsub("%?$", ""))] = ptype end
      local d = not t:match("^%-%-%-@") and t:match("^%-%-%-%s?(.*)$")   -- its description (doc tooltip)
      if d then info.doc = info.doc or {}; info.doc[#info.doc + 1] = d end
      local rtype, rest = t:match("^%-%-%-@return%s+(%S+)%s*(.*)$")
      if rtype then
        info.returns[#info.returns + 1] = { type = rtype, name = rest:match("^([%a_][%w_]*)"), line = cl,
                                            pos = comment_at[cl].pos, epos = comment_at[cl].epos }
      end
    end
    return info
  end
  local cur_fn                                     -- the function being laid out (its returns)

  -- LuaLS types for tables: classes and their fields, string enums (aliases)
  --   ---@class Paddle                 ---@alias Mode "slow"|"fast"
  --   ---@field speed number @range 0 10   (a slider)
  --   ---@field mode Mode                   (a drop-down)
  --   ---@field color Color                 (a colour: a type named like one)
  -- A table gets a class from ---@type Name (or ---@class Name) right above its
  -- local, from its function's ---@return Name, or from its parent's field type.
  g.classes, g.aliases, g.class_list = {}, {}, {}
  do
    local lines = {}
    for l in pairs(comment_at) do lines[#lines + 1] = l end
    table.sort(lines)
    local cls, alias, last
    for _, l in ipairs(lines) do
      local t = comment_at[l].text
      if last and l ~= last + 1 then cls, alias = nil, nil end
      last = l
      local cn = t:match("^%-%-%-@class%s+([%w_%.]+)")
      local fname, ftype, rest = t:match("^%-%-%-@field%s+([%a_][%w_]*%??)%s+(%S+)%s*(.*)$")
      local an, avals = t:match("^%-%-%-@alias%s+([%w_%.]+)%s*(.*)$")
      local more = t:match("^%-%-%-|%s*(.*)$")
      if cn then
        cls = { name = cn, fields = {}, by = {}, line = l }
        if not g.classes[cn] then g.class_list[#g.class_list + 1] = cls end
        g.classes[cn] = cls; alias = nil
      elseif fname and cls then
        local f = { name = fname:gsub("%?$", ""), type = ftype, optional = fname:find("%?$") ~= nil }
        local a, b, st = rest:match("@range%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s*(%-?[%d%.]*)")
        if a then f.range = { tonumber(a), tonumber(b), tonumber(st) } end
        cls.fields[#cls.fields + 1] = f
        cls.by[f.name] = f
      elseif an then
        alias = {}
        g.aliases[an] = alias
        for v in (avals or ""):gmatch("[\"']([^\"']*)[\"']") do alias[#alias + 1] = v end
        cls = nil
      elseif more and alias then
        for v in more:gmatch("[\"']([^\"']*)[\"']") do alias[#alias + 1] = v end
      end
    end
  end
  -- The world's classes (/classes/<name>: a component's members) are classes
  -- here too: from w:spawn("/classes/name", { ... }) in this file, or (a
  -- folder world) opts.world_classes, read from the folder's classes/ (see
  -- M.folder_classes). Each member is described:
  --   hp = { type = "int", value = 10, min = 1, max = 20 }      a slider
  --   mode = { type = "string", value = "slow", options = { "slow", "fast" } }   a drop-down
  --   tint = { type = "color", ... }   path = { type = "number", container = "array" }
  -- (a plain value is short for one: life = 1.5). A table that is a `name`
  -- component ({ name = { ... } }) is typed by it: widgets, and the class's
  -- other members one click away (with their values). The class's own table:
  -- each description a "class member" node (type, kind: drop-downs).
  -- LuaLS classes win a name.
  do
    local PRIM = { int = "integer", number = "number", angle = "number", string = "string", key = "string",
                   asset = "string", node = "string", bool = "boolean", color = "Color", color3 = "Color", color4 = "Color" }
    local function lua_type(t) return PRIM[t] or t end
    local function cf_of(owner, f)                 -- a field { name, text, lit, d } -> its typed field (type, range, enum alias)
      local cf = { name = f.name, default = f.text }
      local d = f.d
      if not d then cf.type = f.lit
      else
        local base = lua_type(d.type)
        if d.type == "string" and type(d.options) == "table" and #d.options > 0 then
          base = owner .. "." .. f.name
          g.aliases[base] = d.options
        end
        if d.container == "array" then cf.type = base .. "[]"
        elseif d.container == "set" then cf.type = "table<" .. base .. ", boolean>"
        elseif d.container == "map" then cf.type = "table<" .. base .. ", " .. lua_type(d.values or "bool") .. ">"
        else
          cf.type = base
          if (d.type == "int" or d.type == "number" or d.type == "angle") and tonumber(d.min) and tonumber(d.max) then
            cf.range = { d.min, d.max, d.type == "int" and 1 or nil }
          elseif d.type == "angle" then cf.range = { -180, 180 } end
        end
      end
      return cf
    end
    g.cf_of = cf_of
    local function add_class(name, fields, line)    -- fields: { name, text, lit, d (its description, or nil) }
      if g.classes[name] then return end
      local cls = { name = name, fields = {}, by = {}, line = line, world = true }
      table.sort(fields, function(a, b) return a.name < b.name end)
      for _, f in ipairs(fields) do
        local cf = cf_of(name, f)
        cls.fields[#cls.fields + 1] = cf
        cls.by[cf.name] = cf
      end
      g.classes[name] = cls
      g.class_list[#g.class_list + 1] = cls
    end
    g.class_defs = {}                              -- the tables that define a class: Table -> name
    local LIT = { Number = "number", String = "string", True = "boolean", False = "boolean" }
    local function str(e) return e and e.tag == "String" and e.raw:sub(2, -2) or nil end
    local function num(e)
      if e and e.tag == "Number" then return tonumber(e.raw) end
      if e and e.tag == "Unop" and e.op == "-" and e.e.tag == "Number" then return -tonumber(e.e.raw) end
    end
    local function describe(t)                     -- a Table { type = "...", ... } -> its description, its value's expression
      local by = {}
      for _, f in ipairs(t.fields) do if f.name then by[f.name] = f.value end end
      if not str(by.type) then return nil end
      local d = { type = str(by.type), container = str(by.container), values = str(by.values), min = num(by.min), max = num(by.max) }
      if by.options and by.options.tag == "Table" then
        d.options = {}
        for _, o in ipairs(by.options.fields) do d.options[#d.options + 1] = str(o.value) end
      end
      return d, by.value
    end
    local function default_text(d)
      if d.container then return "{}" end
      if d.type == "string" then return d.options and d.options[1] and string.format("%q", d.options[1]) or '""' end
      return ({ int = "0", number = "0", angle = "0", bool = "false", key = '"space"', asset = '""', node = '""',
                color = "{ 255, 255, 255 }", color3 = "{ 255, 255, 255 }", color4 = "{ 255, 255, 255, 255 }",
                vec2 = "{ x = 0, y = 0 }", vec3 = "{ x = 0, y = 0, z = 0 }", vec4 = "{ x = 0, y = 0, z = 0, w = 0 }",
                quat = "{ x = 0, y = 0, z = 0, w = 1 }", rect = "{ x = 0, y = 0, w = 1, h = 1 }" })[d.type] or "{}"
    end
    local seen = {}
    local function walk(e)
      if type(e) ~= "table" or seen[e] then return end
      seen[e] = true
      if e.tag == "Invoke" and e.method == "spawn" and e.args[1] and e.args[1].tag == "String" and e.args[2]
         and e.args[2].tag == "Table" then
        local name = e.args[1].raw:sub(2, -2):match("^/classes/([%a_][%w_]*)$")
        if name then
          local fields = {}
          for _, f in ipairs(e.args[2].fields) do
            if f.name then
              local d, ve = nil, f.value
              if f.value.tag == "Table" then d, ve = describe(f.value) end
              local text = ve and src:sub(ve.pos, ve.epos) or default_text(d)
              fields[#fields + 1] = { name = f.name, text = text, lit = ve and LIT[ve.tag] or "table", d = d }
            end
          end
          add_class(name, fields, e.line)
          g.class_defs[e.args[2]] = name
        end
      end
      for k, v in pairs(e) do if k ~= "parent" and type(v) == "table" then walk(v) end end
    end
    walk(ast.body)
    for name, c in pairs(opts.world_classes or {}) do   -- { name = { { name, text, lit, d }, ... } }
      add_class(name, c)
    end
    -- A node's own typed fields (its `meta`: { field = { type = ... } }): a
    -- table with a meta field (a w:spawn's components) has its other fields
    -- typed by it (g.meta_class_of); the meta table's entries are each a
    -- "class member" (a description), like a class's own table.
    g.meta_tables, g.meta_cls = {}, {}
    function g.meta_class_of(t)
      if g.meta_cls[t] ~= nil then return g.meta_cls[t] or nil end
      local meta, vals = nil, {}
      for _, f in ipairs(t.fields) do
        if f.name == "meta" and f.value.tag == "Table" then meta = f.value elseif f.name then vals[f.name] = f.value end
      end
      if not meta then g.meta_cls[t] = false return nil end
      g.meta_tables[meta] = true
      local owner = "meta@" .. t.pos                 -- (its options' aliases: this table's own)
      local cls = { name = owner, fields = {}, by = {} }
      for _, m in ipairs(meta.fields) do
        local d = m.name and m.value.tag == "Table" and describe(m.value)
        if d then
          local ve = vals[m.name]
          local cf = cf_of(owner, { name = m.name, d = d, text = ve and src:sub(ve.pos, ve.epos) or default_text(d), lit = ve and LIT[ve.tag] or "table" })
          cls.fields[#cls.fields + 1] = cf
          cls.by[cf.name] = cf
        end
      end
      g.meta_cls[t] = cls
      return cls
    end
    g.describe, g.default_text = describe, default_text
    if not g.classes["class member"] then   -- a class's own table, a meta table: its descriptions
      local types = { "bool", "int", "number", "angle", "string", "key", "asset", "node", "vec2", "vec3", "vec4",
                      "quat", "rect", "color3", "color4" }
      for _, c in ipairs(g.class_list) do if c.world then types[#types + 1] = c.name end end
      g.aliases["class member.type"] = types
      g.aliases["class member.container"] = { "array", "set", "map" }   -- (none: a var)
      g.aliases["class member.values"] = types
      local fs = {}
      for _, f in ipairs({ { "type", "class member.type" }, { "value", "any" }, { "container", "class member.container" },
                           { "values", "class member.values" }, { "min", "number" }, { "max", "number" }, { "options", "string[]" } }) do
        fs[#fs + 1] = { name = f[1], type = f[2], optional = f[1] ~= "type" }
      end
      local cm = { name = "class member", fields = fs, by = {} }
      for _, f in ipairs(fs) do cm.by[f.name] = f end
      g.classes["class member"] = cm
    end
  end
  -- the class named right above a statement (---@type Name, ---@class Name)
  local function type_above(line)
    local k = line - 1
    while comment_at[k] do
      local t = comment_at[k].text
      local n = t:match("^%-%-%-@type%s+([%w_%.]+)") or t:match("^%-%-%-@class%s+([%w_%.]+)")
      if n then return n end
      k = k - 1
    end
  end
  -- the functions the file defines (at its top level), to call from the menu:
  --   { name = "M.update", call = "M.update", params = {"dt"}, types = {dt = "number"}, line }
  -- "Paddle:draw" is called as Paddle:draw(...) (its self is implicit)
  g.functions = {}
  local fn_by_name = {}                            -- "M.update" / "Paddle:draw" -> { func, method } (the file's own)
  do
    local function path(e)
      if e.tag == "Id" then return e.name end
      if e.tag == "Index" and e.name then local o = path(e.obj); return o and (o .. "." .. e.name) end
    end
    local function add(name, f, line, method)
      local ps = {}
      for i, p in ipairs(f.params) do if not (method and i == 1) then ps[#ps + 1] = p end end
      if f.vararg then ps[#ps + 1] = "..." end
      g.functions[#g.functions + 1] = { name = name, params = ps, types = annotations(line).params, line = line, method = method }
      if fn_by_name[name] == nil then fn_by_name[name] = { func = f, method = method }
      else fn_by_name[name] = false end            -- (defined twice: which one runs isn't known here)
    end
    local function scan(block)
      for _, st in ipairs(block.stmts) do
        local t = st.tag
        if t == "LocalFunction" then add(st.name, st.func, st.line)
        elseif t == "Function" then add(st.name, st.func, st.line, st.method)
        elseif t == "Local" or t == "Set" then
          for i, e in ipairs(st.exprs) do
            local nm = t == "Local" and st.names[i] or (st.targets[i] and path(st.targets[i]))
            if nm and e.tag == "Function" then add(nm, e, st.line)
            elseif nm and e.tag == "Table" then      -- local M = { update = function(dt) ... end }
              for _, fl in ipairs(e.fields) do
                if fl.name and fl.value.tag == "Function" then add(nm .. "." .. fl.name, fl.value, line_of(fl.value.pos)) end
              end
            end
          end
        elseif t == "Do" then scan(st.body) end
      end
    end
    scan(ast.body)
  end
  local function is_color_type(ty) return ty and ty:lower():find("colou?r") ~= nil end

  local parent                                     -- what new nodes / frames hang from (offsets)
  local function adopt(el)
    el.parent = parent
    if parent then parent.kids = parent.kids or {}; parent.kids[#parent.kids + 1] = el end
  end
  -- a statement node can take a --@node line right above it (if it starts its line)
  -- (its tags: the --@node and --@expr lines right above it; top_line: the first of them)
  -- one sharing its line with what comes before (if c then tp = 0 end) takes an inline
  -- --[[@node dx= dy=]] right before it instead
  -- (expression nodes: --@expr slot=2 for the one feeding pin 2, slot=2.1 for
  -- the one feeding pin 1 of that one...)
  local function stmt_edit(s)
    if not starts_line(s.pos) then
      local at = inline_at[s.pos] or { exprs = {} }
      return { kind = "node", inline = true, insert_pos = s.pos, tag = at.node, expr_tags = at.exprs }
    end
    local e = { kind = "node", insert_line = s.line, indent = indent_of(s.line), top_line = s.line, expr_tags = {} }
    local l = s.line - 1
    while tags[l] and tags[l].kind ~= "frame" and tags[l].kind ~= "comment" and tags[l].kind ~= "start" do
      local t = tags[l]
      if t.kind == "node" then e.tag = e.tag or t
      elseif t.vals.slot and t.vals.slot:match("^%d+[%d%.f]*$") then e.expr_tags[t.vals.slot] = t end
      e.top_line = l
      l = l - 1
    end
    return e
  end
  -- the expression nodes feeding n (and those feeding them...): their tags go with n's
  local function expr_edits(n, e, prefix)
    for _, k in ipairs(n.kids or {}) do
      if k.kind == "expr" and k.slot and k.slot.pin_index and k.parent == n then
        local path = (prefix and (prefix .. ".") or "") .. (k.slot.opath or k.slot.pin_index)
        k.edit = { kind = "expr", slot = path, tag = e.expr_tags[path], insert_line = e.insert_line, indent = e.indent,
                   inline = e.inline, insert_pos = e.insert_pos }
        expr_edits(k, e, path)
      end
    end
  end
  -- a function frame takes --@frame lines at the top of its body
  local function frame_edit(f)
    local hl = line_of(f.params_epos or f.pos)
    local first = f.body.stmts[1]
    local last_line = first and first.line - 1 or line_of(f.epos) - 1
    local tag
    for l = hl + 1, last_line do if tags[l] and tags[l].kind == "frame" then tag = tags[l] end end
    if first then
      if first.line <= hl or not starts_line(first.pos) then   -- on the header's line: inline
        local at = inline_at[first.pos]
        return { kind = "frame", inline = true, insert_pos = first.pos, tag = tag or (at and at.frame) }
      end
      local at = first.line
      while tags[at - 1] and tags[at - 1].kind ~= "frame" and tags[at - 1].kind ~= "comment" do at = at - 1 end   -- above its --@node / --@expr
      return { kind = "frame", tag = tag, insert_line = at, indent = indent_of(first.line) }
    end
    local el = line_of(f.epos)                     -- empty body: right before "end"
    if el <= hl or not starts_line(f.epos - 2) then
      local at = inline_at[f.epos - 2]
      return { kind = "frame", inline = true, insert_pos = f.epos - 2, tag = tag or (at and at.frame) }
    end
    return { kind = "frame", tag = tag, insert_line = el, indent = indent_of(f.line) .. "  " }
  end

  -- sockets: io = { exprs = { expr... }, outs = { {pos, epos}... } }
  local function sockets(io)
    local ins, outs = {}, {}
    if not (res and io) then return ins, outs end
    local by = {}
    local function scan(e)
      if type(e) ~= "table" or e.tag == "Function" then return end   -- a lambda reads in its own frame
      if e.tag == "Id" then
        local u = use_at[e.pos]
        if u then
          local key = u.decl or ("g:" .. u.name)
          local p = by[key]
          if not p then p = { name = u.name, decl = u.decl, uses = {} }; by[key] = p; ins[#ins + 1] = p end
          p.uses[#p.uses + 1] = u
        end
        return
      end
      for _, v in pairs(e) do
        if type(v) == "table" then
          if v.tag then scan(v) else for _, x in pairs(v) do scan(x) end end
        end
      end
    end
    for _, e in pairs(io.exprs or {}) do scan(e) end
    table.sort(ins, function(a, b) return a.uses[1].pos < b.uses[1].pos end)
    for _, sp in ipairs(io.outs or {}) do
      local d = decl_at[sp[1]]
      if d then outs[#outs + 1] = { name = d.name, decl = d } end
    end
    return ins, outs
  end

  -- a node. io:
  --   exprs = { expr... }   an expression node: its inputs are the variables read
  --   slots = { { name, e, kind, need } }   a statement: one input pin per slot
  --   outs = { {pos, epos}... }   the variables it declares; value_out: a "result" output
  local function new_node(kind, title, lines, x, y, ast_node, io)
    local ins, outs = sockets(io)
    local diags, seen = {}, {}
    local found = {}
    for _, m in ipairs(io and io.diags_extra or {}) do found[#found + 1] = m end
    if io and io.slots then                        -- pins from the slots
      for _, sl in ipairs(io.slots) do
        local e = sl.e
        local pin = { name = sl.name, kind = sl.kind, pos = e.pos, epos = e.epos, ret_index = sl.ret_index, e = e,
                      field = sl.field, hint = sl.hint, action = sl.action, tpos = sl.tpos, stmt = sl.stmt,
                      cfield = sl.cfield, ftype = sl.ftype, param = sl.param, opath = sl.opath,
                      split_of = sl.split_of, split_table = sl.split_table, split_src = sl.split_src }
        if sl.kind == "var" or sl.kind == "global" then
          local u = use_at[e.pos]
          pin.uses = u and { u } or {}
          pin.decl = u and u.decl
          if sl.kind == "global" then pin.text = e.name end
        elseif sl.kind == "literal" then
          local t = src:sub(e.pos, e.epos):gsub("%s+", " ")
          pin.text = #t > 24 and (t:sub(1, 22) .. "..") or t
          local i = e
          while i.tag == "Paren" do i = i.e end
          pin.lit = (i.tag == "Number" or i.tag == "Unop") and "number" or i.tag == "String" and "string"
                    or (i.tag == "True" or i.tag == "False") and "boolean" or i.tag == "Nil" and "nil" or "other"
        elseif sl.kind == "vector" or sl.kind == "color" then   -- a small table of numbers, inline
          pin.comps = {}
          local parts = {}
          for k, c in ipairs(sl.comps) do
            local t = src:sub(c.e.pos, c.e.epos)
            pin.comps[k] = { label = c.label, pos = c.e.pos, epos = c.e.epos, text = t }
            parts[#parts + 1] = (c.label or "") .. " " .. t .. "  "
          end
          pin.text = (sl.kind == "color" and "#### " or "") .. table.concat(parts)   -- (its width)
        elseif sl.kind == "lambda" then
          pin.text = "function"
        end
        if sl.need and is_nil(e) then             -- a literal nil where it can't be
          found[#found + 1] = sl.need
        end
        ins[#ins + 1] = pin
        sl.pin_index = #ins
      end
    end
    if io and io.value_out then outs[#outs + 1] = { name = "result", value = true } end
    for _, nm in ipairs(io and io.value_outs or {}) do outs[#outs + 1] = { name = nm, value = true } end
    for _, o in ipairs(outs) do                    -- a parameter's annotated type
      if o.decl and io.hints then o.hint = io.hints[o.decl.name] end
      if io.silent_outs then o.silent = true end   -- (named on the inputs already)
    end
    if io and floating == 0 then                   -- (floating code doesn't run: nothing will fail)
      for _, e in pairs(io.exprs or {}) do diagnose(e, found) end
      for _, m in ipairs(found) do
        if not seen[m] then seen[m] = true; diags[#diags + 1] = { level = "error", msg = m } end
      end
    end
    for _, p in ipairs(ins) do                     -- chips: a parameter, a variable read a lot, or read far away
      local upos = p.uses and p.uses[1] and p.uses[1].pos or (p.e and p.e.pos)
      if p.decl and chip_for(p.decl, upos) then p.chip = p.decl.name end
    end
    for _, o in ipairs(outs) do if o.decl and chipped(o.decl) then o.chip = true end end
    local w = font:get_width(title) + 2 * PADX + CHEV   -- (the chevron left of the title: collapse)
    for _, l in ipairs(lines) do w = math.max(w, cfont:get_width(l) + 2 * PADX + 8) end
    local rows = math.max(#ins, #outs)
    for i = 1, rows do                             -- an input and an output side by side
      local a, b = ins[i] and font:get_width(ins[i].name) or 0, outs[i] and not outs[i].silent and font:get_width(outs[i].name) or 0
      if outs[i] and outs[i].hint then b = b + font:get_width(outs[i].hint) + 8 end
      if ins[i] and ins[i].text then                -- its value, in a box (a checkbox: just the box)
        a = a + (ins[i].lit == "boolean" and clh + 10 or cfont:get_width(ins[i].text) + 18)
      end
      if outs[i] and outs[i].chip and not outs[i].silent then b = b + 14 end   -- (an output's chip: its label in a pill)
      if ins[i] and ins[i].hint and ins[i].hint.range then a = a + 110 end            -- a slider
      if ins[i] and ins[i].hint and ins[i].hint.enum then a = a + 20 end              -- a drop-down arrow
      w = math.max(w, a + b + 2 * PADX + 24)
    end
    local head_h = lh + 2 * PADY + 2
    -- execution pins (UE style): one in, at the header's left; the outs at
    -- its right, the first in the header, the others in rows of their own
    local xin = io and io.exec_in and { y = head_h / 2 } or nil
    local xouts = {}
    for k, nm in ipairs(io and io.exec_outs or {}) do xouts[k] = { name = nm } end
    if xouts[1] then
      xouts[1].y = head_h / 2
      w = math.max(w, font:get_width(title) + font:get_width(xouts[1].name) + 2 * PADX + 30 + CHEV)
    end
    local sy = head_h + 4
    for i = 1, rows do
      if ins[i] then ins[i].y = sy + (lh + SROW) / 2 end
      if outs[i] then outs[i].y = sy + (lh + SROW) / 2 end
      sy = sy + lh + SROW
    end
    for _, p in ipairs(io and io.tail or {}) do    -- a button row under the others: "+ add parameter"
      ins[#ins + 1] = p
      p.y = sy + (lh + SROW) / 2
      w = math.max(w, font:get_width(p.name) + 2 * PADX + 24)
      sy, rows = sy + lh + SROW, rows + 1
    end
    for k = 2, #xouts do                           -- then / else, body / done...
      xouts[k].y = sy + (lh + SROW) / 2
      w = math.max(w, font:get_width(xouts[k].name) + 2 * PADX + 24)
      sy = sy + lh + SROW
    end
    if #xouts > 1 then rows = rows + #xouts - 1 end
    local body_y = sy + (rows > 0 and 2 or 0)
    local h = body_y + (#lines > 0 and (#lines * clh + 6 + 6) or 2)
    local compact = io and io.compact and #lines == 1 and #outs <= 1
    local head_title                               -- (unused: the title always fits)
    local body_x
    if compact then                                -- compact: the inputs' names in a column, the
      local rh = lh + SROW                         -- code right of them, the result at the right
      local block = math.max(#ins * rh, clh + 6)
      local top = head_h + 3
      local labw = 0
      for _, p in ipairs(ins) do if p.chip ~= p.name then labw = math.max(labw, font:get_width(p.name)) end end   -- (a chip names it: no label)
      for i, p in ipairs(ins) do p.y = top + (block - #ins * rh) / 2 + (i - 0.5) * rh end
      if outs[1] then outs[1].y = top + block / 2; outs[1].silent = true end
      body_x = labw > 0 and (PADX + labw + 6) or 6
      body_y = top + (block - clh - 6) / 2
      h = top + block + 3
      w = math.max(body_x + cfont:get_width(lines[1]) + 8 + 6 + 8, font:get_width(title) + 2 * PADX + 4 + CHEV)   -- (its title always fits)
    end
    local pnames = {}                              -- its key across builds: kind, title, pins, which of the alike
    for _, p in ipairs(ins) do pnames[#pnames + 1] = p.name end
    local wkey = kind .. "|" .. title .. "|" .. table.concat(pnames, ",")
    wcount[wkey] = (wcount[wkey] or 0) + 1
    wkey = wkey .. "|" .. wcount[wkey]
    local nerr = #diags
    for _, m in ipairs(wrows[wkey] or {}) do diags[#diags + 1] = { level = "warning", msg = m } end
    local diag_y = h                               -- a row per diagnostic, at the bottom (errors, then warnings)
    for _, d in ipairs(diags) do
      w = math.max(w, font:get_width(d.msg) + 2 * PADX + 14)
      h = h + lh + 6
    end
    if #diags > 0 then h = h + 4 end
    if nerr > 0 then g.errors = (g.errors or 0) + nerr end
    local n = { id = #g.nodes + 1, kind = kind, title = title, lines = lines, ins = ins, outs = outs,
                head_h = head_h, body_y = body_y, diags = diags, diag_y = diag_y, xin = xin, xouts = xouts, wkey = wkey,
                has_error = nerr > 0 or nil,
                x = x, y = y, w = math.max(w, compact and 40 or kind == "expr" and 60 or 100), h = h, compact = compact or nil, head_title = head_title, body_x = body_x,
                line = ast_node and ast_node.line, pos = ast_node and ast_node.pos, epos = ast_node and ast_node.epos }
    n.floating = floating > 0 or nil                -- (floating code doesn't run: no warnings either)
    g.nodes[n.id] = n
    adopt(n)
    if ast_node then
      node_of[ast_node] = n.id
      if ast_node.tag ~= "Function" and ast_node.tag ~= "LocalFunction" and ast_node.pos then n.edit = stmt_edit(ast_node) end
    end
    return n
  end
  local PIN_OF = { ["do"] = "body" }               -- an edge's label -> the out pin it leaves from
  local function edge(from, to, label, back, wrap)
    g.exec[#g.exec + 1] = { from = from, to = to, label = label, back = back, wrap = wrap }
  end
  local wrap_limit                                 -- the right edge rows wrap at (see M.WRAP_W)

  local layout_block, layout_frame, layout_floats

  -- floating code: statements outside the flow, kept in a long comment
  --   --[==[@float dx=40 dy=120
  --   print("hello")
  --   ]==]
  -- placed relative to the header of the function it sits in (the top level:
  -- the graph's origin). Wiring a flow out to its first node moves the code
  -- into the flow there; taking nodes out of the flow parks them like this.
  g.floats = {}
  for _, c in ipairs(opts.parse and ast.comments or {}) do
    local lvl, rest = c.text:match("^%-%-%[(=*)%[@float([^\n]*)\n")
    if lvl then
      local F = { pos = c.pos, epos = c.epos, level = lvl }
      F.header = { pos = c.pos, epos = c.pos + #("--[" .. lvl .. "[@float" .. rest) - 1 }
      F.keys, F.vals = {}, {}                      -- dx, dy, color...
      for k, v in rest:gmatch("([%w_]+)=(%S+)") do F.keys[#F.keys + 1] = k; F.vals[k] = v end
      F.dx, F.dy = tonumber(F.vals.dx) or 0, tonumber(F.vals.dy) or 0
      F.inner_pos, F.inner_epos = F.header.epos + 2, c.epos - (#lvl + 2)
      g.floats[#g.floats + 1] = F
    end
  end


  -- functions held by a statement's expressions: frames under it
  local function side_frames(n, lambdas, names)
    local fx, fy, w, h = n.x, n.y + n.h + GAPY, n.w, n.h   -- under it
    local saved = parent
    parent = n                                     -- they move with the statement
    for i, f in ipairs(lambdas) do
      local fr = layout_frame(f, fx, fy, names and names[f] or "function")
      g.data[#g.data + 1] = { from = n.id, to = fr.head.id, name = names and names[f] or "fn", lambda = true }
      fy = fy + fr.h + GAPY
      w = math.max(w, fx + fr.w - n.x)
      h = math.max(h, fy - GAPY - n.y)
    end
    parent = saved
    return w, h
  end

  -- what each lambda is called: the table key or local it is assigned to
  local function lambda_names(s, lambdas)
    local names = {}
    local function scan(e, label)
      if type(e) ~= "table" then return end
      if e.tag == "Function" then names[e] = label or "function"; return end
      if e.tag == "Table" then
        for _, f in ipairs(e.fields) do scan(f.value, f.name or label) end
      elseif e.tag == "Call" or e.tag == "Invoke" then
        for _, a in ipairs(e.args) do scan(a, label) end
      elseif e.tag == "Paren" then scan(e.e, label) end
    end
    local exprs = s.exprs or (s.call and { s.call }) or {}
    for i, e in ipairs(exprs) do
      local label = s.names and s.names[i] or (s.targets and s.targets[i] and text_of(src, s.targets[i]))
      scan(e, label)
    end
    return names
  end

  -- editable fields: a span of source a node can rewrite: "title" (the
  -- targets of a set, or the names it declares), "body" (all its expressions,
  -- or an expression node's), "slot<i>" (the expression behind input pin i)
  local fn_memo = {}                               -- (asked for every field: remembered per table)
  local function has_fn(e)
    if type(e) ~= "table" then return false end
    if e.tag == "Function" then return true end
    local m = fn_memo[e]
    if m ~= nil then return m end
    m = false
    for _, v in pairs(e) do
      if type(v) == "table" and has_fn(v) then m = true; break end
    end
    fn_memo[e] = m
    return m
  end
  local function field(list)
    local l = {}
    for _, e in pairs(list or {}) do l[#l + 1] = e end
    table.sort(l, function(a, b) return a.pos < b.pos end)
    if #l == 0 then return nil end
    local f = { pos = l[1].pos, epos = l[#l].epos }
    for _, e in ipairs(l) do
      if has_fn(e) then f.blocked = "it holds a function: edit that in its own frame" end
    end
    f.multiline = src:sub(f.pos, f.epos):find("\n") ~= nil
    return f
  end
  -- a title that declares names: renamed everywhere they are used (view.lua)
  local function names_field(spans, fmt)
    local l = {}
    for _, sp in ipairs(spans or {}) do if sp[1] > 0 then l[#l + 1] = sp end end   -- not an implicit self
    if #l == 0 then return nil end
    return { rename = true, spans = l, fmt = fmt or "list" }
  end
  local function with_fields(r, fields)
    local n = r.entry and g.nodes[r.entry]
    if n then
      n.fields = n.fields or {}
      for k, v in pairs(fields) do n.fields[k] = v end
    end
    return r
  end

  -- slots (UE-style pins): what feeds each input of a statement
  --   var: a local, wired from where it is declared; global: its name in a box
  --   literal: its value in a box; lambda: "function" (its frame hangs below)
  --   expr: anything else, an expression node of its own, wired in
  local LITERAL = { Nil = true, True = true, False = true, Number = true, String = true, Vararg = true }
  local function classify(e, force)
    if force then return force end
    local i = e
    while i.tag == "Paren" do i = i.e end
    if i.tag == "Function" then return "lambda" end
    if LITERAL[i.tag] or (i.tag == "Unop" and i.op == "-" and i.e.tag == "Number") then return "literal" end
    if e.tag == "Id" then
      local u = use_at[e.pos]
      return (u and not u.decl) and "global" or "var"
    end
    return "expr", (e.tag == "Call" or e.tag == "Invoke") and res ~= nil and "call"   -- a call: a call node (pins for its arguments)
                   or e.tag == "Table" and res ~= nil and "table"                       -- a table: a row per field
  end
  local function path_of(e)                        -- a.b.c as text, or nil
    if e.tag == "Id" then return e.name, e end
    if e.tag == "Index" and e.name then
      local p, base = path_of(e.obj)
      if p then return p .. "." .. e.name, base end
    end
  end
  local function values(list, single)              -- slots for a list of values
    local sl = {}
    for i, e in ipairs(list) do sl[#sl + 1] = { name = #list == 1 and single or (single .. " " .. i), e = e } end
    return sl
  end
  -- the slots of a call: what is called, then its arguments (named after the
  -- parameters of a local function, else arg1, arg2...)
  local function call_slots(c)
    local slots, title = {}, "call"
    local params, callee
    local skip = 0                                 -- (parameters with no argument: an implicit self)
    local api_entry                                -- (from a module: its vararg's name)
    if c.tag == "Invoke" then
      slots[1] = { name = "self", e = c.obj, need = "attempt to index a nil value" }
      local op = path_of(c.obj)
      title = "call " .. (op or "") .. ":" .. c.method
      local fd = op and fn_by_name[op .. ":" .. c.method]   -- function M:method() of this file
      if fd then params, callee, skip = fd.func.params, fd.func, 1 end
      if not params and opts.api then              -- a module's class: its object's class, else the one class with it
        local entry
        local u = c.obj.tag == "Id" and use_at[c.obj.pos]
        local d = u and u.decl
        if d and d.kind == "local" and d.owner and d.owner.tag == "Local" then   -- local w = ecs.world()
          for k, nm in ipairs(d.owner.names) do
            local ex = d.owner.exprs[k]
            if nm == d.name and ex and ex.tag == "Call" then
              local fe = opts.api[path_of(ex.fn) or ""]
              if fe and fe.ret_class then entry = opts.api[fe.ret_class .. ":" .. c.method] end
            end
          end
        end
        local list = not entry and opts.api_methods and opts.api_methods[c.method]
        if list and #list == 1 then entry = list[1] end
        if entry then params, api_entry = entry.params, entry end
      end
    else
      local p, base = path_of(c.fn)
      if p then
        title = "call " .. p
        local u = use_at[base.pos]
        if u and u.decl then
          slots[1] = { name = base.name, e = base }   -- a local (function or table): wired
          local d = u.decl
          if p == base.name and d.kind == "function" and d.owner and d.owner.func then
            params = d.owner.func.params
            callee = d.owner.func
          end
        end
        if not params and (not (u and u.decl) or p ~= base.name) then   -- a function this file defines
          local fd = fn_by_name[p]                 -- (a global, or a field: M.f), not shadowed by a local
          if fd then params, callee = fd.func.params, fd.func end
        end
        -- an API's (runtime/meta, modules): a global, or a field of a local (local ecs = require("ecs"): ecs.system)
        local api = opts.api and not params and (not (u and u.decl) or p ~= base.name) and opts.api[p]
        if api and not api.method then params, api_entry = api.params, api end
      else
        slots[1] = { name = "fn", e = c.fn, need = "attempt to call a nil value" }
      end
    end
    for i, a in ipairs(c.args) do
      local nm = params and params[i + skip]
      local va = params and params[#params] == "..." and i + skip >= #params   -- (the vararg's pins: "component 1"...)
      if va then
        local vn = api_entry and api_entry.vararg_name
        nm = vn and (vn .. " " .. (i + skip - #params + 1)) or "..."
      end
      slots[#slots + 1] = { name = nm or ("arg" .. i), e = a, param = not va and nm or nil }
    end
    local fname = c.tag == "Call" and c.fn.tag == "Id" and c.fn.name
    if fname and NEEDS_TABLE[fname] and c.args[1] and not (use_at[c.fn.pos] and use_at[c.fn.pos].decl) then
      slots[#slots - #c.args + 1].need = "bad argument #1 to '" .. fname .. "' (table expected, got nil)"
    end
    return slots, title, callee, api_entry
  end

  -- a statement node with its slots: expression nodes in a column on its left
  -- (under the flow line), wired into its pins; lambdas below it.
  -- Returns the node and the size of the whole group.
  local function reparent(el, p)
    local old = el.parent
    if old and old.kids then
      for i, k in ipairs(old.kids) do if k == el then table.remove(old.kids, i); break end end
    end
    el.parent = p
    p.kids = p.kids or {}
    p.kids[#p.kids + 1] = el
  end
  -- a table constructor: one slot (row) per field. Small tables of numbers
  -- become one row: {x=1, y=2} (a vector) or color = {90, 96, 120} (a colour).
  local function is_num(e)
    while e.tag == "Paren" do e = e.e end
    return e.tag == "Number" or (e.tag == "Unop" and e.op == "-" and e.e.tag == "Number")
  end
  local COLOR_KEY = { color = true, colour = true, tint = true, rgb = true, rgba = true, background = true, bg = true, fg = true }
  local function inline_kind(key, t)
    if t.tag ~= "Table" or #t.fields < 2 or #t.fields > 4 then return nil end
    local comps, named, positional = {}, 0, 0
    for k, f in ipairs(t.fields) do
      if f.key or not is_num(f.value) then return nil end
      if f.name then
        if not ({ x = 1, y = 1, z = 1, w = 1, r = 1, g = 1, b = 1, a = 1 })[f.name] then return nil end
        named = named + 1
      else positional = positional + 1 end
      comps[k] = { label = f.name, e = f.value }
    end
    if named > 0 and positional > 0 then return nil end
    local lk = key and key:lower() or ""
    if (COLOR_KEY[lk:gsub("%d+$", "")] or lk:find("colou?r%d*$")) and #t.fields >= 3 then
      local labels = { "r", "g", "b", "a" }
      for k, c in ipairs(comps) do c.label = c.label or labels[k] end
      return "color", comps
    end
    if named > 0 or positional <= 3 then
      local labels = { "x", "y", "z", "w" }
      for k, c in ipairs(comps) do c.label = c.label or labels[k] end
      return "vector", comps
    end
  end
  local MAX_ROWS, SHOW_ROWS = 12, 10               -- a bigger table shows its first rows, and "+ N more"
  local function table_slots(t, cname)
    local slots = {}
    local cls = cname and g.classes[cname] or (not cname and g.meta_class_of(t)) or nil   -- (a table with a meta: typed by it)
    local present = {}
    local nf = #t.fields
    local shown = (nf > MAX_ROWS and not expanded[t.pos]) and SHOW_ROWS or nf
    for i = 1, shown do
      local f = t.fields[i]
      local key = f.name or (f.key and (f.key.tag == "String" and f.key.raw and src:sub(f.key.pos + 1, f.key.epos - 1)
                  or "[" .. src:sub(f.key.pos, f.key.epos) .. "]")) or ("[" .. i .. "]")
      local sl = { name = key, e = f.value,
                   field = { pos = f.pos, epos = f.value.epos, key_pos = f.name_pos, index = i } }
      local vl = line_of(f.value.epos)              -- the last field on its line takes that line's hint
      local nxt = t.fields[i + 1]
      if not nxt or line_of(nxt.value.epos) ~= vl then sl.hint = field_hint(vl) end
      local cf = cls and f.name and cls.by[f.name]  -- its declared type
      local ftype = cf and cf.type
      local kind, comps = inline_kind((is_color_type(ftype) and "color") or f.name, f.value)
      if kind then sl.force, sl.comps = kind, comps end
      if cf then
        present[f.name] = true
        sl.ftype = ftype
        if not sl.hint and cf.range then sl.hint = { range = cf.range } end
        if not sl.hint and g.aliases[ftype] then sl.hint = { enum = g.aliases[ftype] } end
        if g.classes[ftype] and f.value.tag == "Table" then sl.class = ftype end
      elseif (g.class_defs[t] or g.meta_tables[t]) and f.value.tag == "Table" then
        sl.class = "class member"                  -- a class's own table, a meta table: each entry described
      elseif f.name and f.value.tag == "Table" and g.classes[f.name] and g.classes[f.name].world then
        sl.class = f.name                          -- a component: { paddle = { ... } } is a paddle
      end
      slots[#slots + 1] = sl
    end
    if cls then                                    -- the class's fields it doesn't have: one click adds them
      for _, cf in ipairs(cls.fields) do
        if not present[cf.name] then
          slots[#slots + 1] = { name = "+ " .. cf.name .. ": " .. cf.type, e = { tag = "Table", pos = t.pos, epos = t.epos, line = t.line },
                                force = "action", action = "classfield", tpos = t.pos, cfield = cf }
        end
      end
    end
    local anchor = { tag = "Table", pos = t.pos, epos = t.epos, line = t.line }
    if shown < nf then
      slots[#slots + 1] = { name = "+ " .. (nf - shown) .. " more fields", e = anchor, force = "action", action = "more", tpos = t.pos }
    elseif nf > MAX_ROWS then
      slots[#slots + 1] = { name = "- show fewer", e = anchor, force = "action", action = "less", tpos = t.pos }
    end
    slots[#slots + 1] = { name = "+ add field", e = anchor, force = "action", action = "add", tpos = t.pos }
    return slots
  end

  local function shift(el, dx, dy)
    el.x, el.y = el.x + dx, el.y + dy
    for _, k in ipairs(el.kids or {}) do shift(k, dx, dy) end
  end
  local stmt_node
  local get_ctx                                    -- (the --@expr tags and slot path of the statement being built)
  local table_base                                 -- (the variable a table node is assigned to: its outputs can split)
  local split_paths = {}                           -- "p.speed" -> { node =, out =, decl =, path = }: a split table output
  -- the node of an expression: a table node, a call node, or an expression node
  -- (returns it, and the size of its group: its own inputs sit left of it;
  -- then the width of the node and its inputs alone, without the functions
  -- hanging under it: those don't push the statement it feeds to the right)
  -- the room chips need left of a node: the widest of them (0: none)
  local function chip_room(names)
    local r = 0
    for _, nm in ipairs(names) do r = math.max(r, font:get_width(nm) + M.CHIP_PAD + M.CHIP_GAP) end
    return r
  end
  local function expr_node(e, what, x, y, lambdas, cname)
    local en, gw, gh, core
    if what == "table" and not cname then          -- a cast right after it: { ... } --[[@as Paddle]]
      local cast = src:match("^[ \t]*%-%-%[%[@as%s+([%w_%.]+)%s*%]%]", e.epos + 1)
      if cast and g.classes[cast] then cname = cast end
    end
    if what == "table" then                        -- a table node: a row per field, widgets for literals
      -- split outputs (--@expr slot=N outs=1[,field...]): a table assigned to
      -- a variable (local p = {...}, p.q = {...}) gets an output per field on
      -- its row (p.speed), the whole table's in its header; a field holding a
      -- table, split too, its own (p.color.r...) on the rows below
      local tb = table_base
      table_base = nil
      local stag = get_ctx and get_ctx.prefix and get_ctx.tags[get_ctx.prefix]
      local spl = tb and stag and stag.vals.outs
      local tslots = table_slots(e, cname)
      local io2 = { value_out = true }
      local fouts, nested = {}, {}
      if spl then
        local vo = { "result" }
        for _, sl in ipairs(tslots) do if not sl.action then vo[#vo + 1] = sl.name; fouts[#fouts + 1] = sl end end
        for nm in spl:gmatch("[^,]+") do
          for _, sl in ipairs(fouts) do
            local v = sl.e
            while v and v.tag == "Paren" do v = v.e end
            if sl.name == nm and v and v.tag == "Table" then
              for k, f in ipairs(v.fields) do
                local sub = f.name and (nm .. "." .. f.name) or (nm .. "[" .. k .. "]")
                vo[#vo + 1] = sub; nested[#nested + 1] = sub
              end
            end
          end
        end
        io2 = { value_outs = vo }
      end
      en, gw, gh, core = stmt_node("expr", cname or "table", nil, x, y, tslots, io2)
      if tb then en.split_base = tb end
      if spl then
        en.split_outs = spl
        en.outs[1].y = en.head_h / 2               -- the whole table: in the header
        local row = lh + SROW
        local y0 = en.ins[1] and en.ins[1].y or (en.head_h + 4 + row / 2)
        for k = 2, #en.outs do
          local o = en.outs[k]
          local path = tb.text .. (o.name:sub(1, 1) == "[" and "" or ".") .. o.name
          o.field_path, o.base_decl, o.value, o.split_out = path, tb.decl, nil, true
          local at
          for _, p in ipairs(en.ins) do if p.name == o.name then at = p.y end end
          if not at then                           -- a nested field's: the rows after the fields
            for j, nm in ipairs(nested) do if nm == o.name then at = y0 + (#fouts + j - 1) * row end end
          end
          o.y = at or o.y
          split_paths[path] = { node = en.id, out = k, decl = tb.decl, path = path }
        end
      end
      en.class = cname
      en.vexpr = e
      en.table = true
      en.fields.body = field({ e })
      en.tnode = e                                 -- (adding / removing fields)
    elseif e.tag == "Binop" and e.op == ".." then   -- a concat node: each operand a pin (a .. b .. c: 3), the string out
      local ops = {}
      local function flat(x)
        if x.tag == "Binop" and x.op == ".." then flat(x.l); flat(x.r) else ops[#ops + 1] = x end
      end
      flat(e)
      local cslots = {}
      for i, o in ipairs(ops) do cslots[i] = { name = string.char(96 + math.min(i, 26)), e = o } end
      cslots[#cslots + 1] = { name = "+ add string", e = { tag = "Concat", pos = e.pos, epos = e.epos, line = e.line },
                              force = "action", action = "addcat" }   -- (one more operand: .. "")
      en, gw, gh, core = stmt_node("expr", "concat (..)", nil, x, y, cslots, { value_outs = { "result" } })
      en.concat = ops
      en.vexpr = e
      en.fields.body = field({ e })
    elseif what then                               -- a call node: its arguments as pins, its results as outputs
      local cslots, ctitle, callee, capi = call_slots(e)
      local names = {}
      local info = callee and g.fn_info[callee]
      for i, r in ipairs(info and info.returns or {}) do names[i] = r.name or ("result " .. i) end
      if #names == 0 then names[1] = "result" end
      en, gw, gh, core = stmt_node("expr", (ctitle:gsub("^call ", "")), nil, x, y, cslots, { value_outs = names })
      en.callee = true
      en.vexpr, en.vcallee = e, callee
      en.dcall = { title = (ctitle:gsub("^call ", "")), callee = callee, api = capi }
      en.fields.body = field({ e })
    else
      en = new_node("expr", "expression", wrap(text_of(src, e, lambdas), {}), x, y, nil,
                    { exprs = { e }, value_out = true, compact = true })
      en.fields = { body = field({ e }) }
      en.vexpr = e
      local cn = {}
      for _, p in ipairs(en.ins) do if p.chip then cn[#cn + 1] = p.chip end end
      gw, gh = en.w + chip_room(cn), en.h          -- (its chips sit left of it: room for them)
    end
    return en, gw, gh, core or gw
  end
  stmt_node = function(kind, title, s, x, y, slots, io)
    io = io or {}
    -- split pins: a slot holding a table constructor, tagged split in the
    -- text (--@expr slot=N split=1, like a getter's tag: every view shows it),
    -- is a pin per field on this node ("pos.x", "pos.y"), each its field's
    -- value. Paths in tags count the slots as written (opath): a split one's
    -- fields are N f1, N f2... ("2f1"), the slots after it keep their numbers.
    do
      local sctx
      if s and s.pos then local se = stmt_edit(s); sctx = { tags = se and se.expr_tags or {} } else sctx = get_ctx end
      local out
      for i, sl in ipairs(slots) do
        if not sl.action then sl.opath = sl.opath or i end
        local t = sl.e
        while t and t.tag == "Paren" do t = t.e end
        local path = sl.opath and ((sctx and sctx.prefix and (sctx.prefix .. ".") or "") .. sl.opath)
        local tag = path and sctx and sctx.tags[path]
        if tag and tag.vals.split and t and t.tag == "Table" and #t.fields > 0 then
          out = out or { table.unpack(slots, 1, i - 1) }
          for k, f in ipairs(t.fields) do
            local fk = f.name or (f.key and f.key.tag == "String" and src:sub(f.key.pos + 1, f.key.epos - 1)) or ("[" .. k .. "]")
            out[#out + 1] = { name = sl.name .. "." .. fk, e = f.value, split_of = sl.opath, split_table = t,
                              opath = sl.opath .. "f" .. k,
                              field = { pos = f.pos, epos = f.value.epos, key_pos = f.name_pos, index = k } }
          end
        elseif out then out[#out + 1] = sl end
      end
      if out then slots = out end
    end
    local lambdas, enodes, lnames = {}, {}, {}
    local ey, ew = y + lh + 2 * PADY + 14, 0
    -- --@expr slot=N get=name: that pin's read drawn as a get node (slot=2.3: pin 3 of the node feeding pin 2)
    local ctx
    if s and s.pos then
      local se = stmt_edit(s)
      ctx = { tags = se and se.expr_tags or {} }
    else
      ctx = get_ctx                                -- (an expression node: its parent's path)
    end
    for i, sl in ipairs(slots) do
      local is_call
      if not sl.force and not sl.action then         -- reading a split table output (p.speed): wired from it
        local ep = sl.e
        while ep and ep.tag == "Paren" do ep = ep.e end
        if ep and ep.tag == "Index" then
          local p, base = path_of(ep)
          local en = p and split_paths[p]
          local u = base and use_at[base.pos]
          if en and u and u.decl == en.decl then sl.force, sl.split_src = "field", en end
        end
      end
      sl.kind, is_call = classify(sl.e, sl.force)
      local path = (ctx and ctx.prefix and (ctx.prefix .. ".") or "") .. (sl.opath or i)
      local gt = ctx and ctx.tags[path]
      if gt and gt.vals.get and (sl.kind == "var" or sl.kind == "global") and sl.e.tag == "Id" then
        local nm = sl.e.name                       -- a get node (UE's getter) wired into the pin: no chip, no long wire
        local en = new_node("expr", "get " .. nm, {}, x, ey, nil, { value_outs = { nm } })
        en.fields = { body = field({ sl.e }) }
        en.getter, en.slot, en.get_e = nm, sl, sl.e
        en.group_w, en.full_w = en.w, en.w
        en.line = sl.e.line or (s and s.line)
        enodes[#enodes + 1] = en
        ey = ey + en.h + GAPY / 2
        ew = math.max(ew, en.w)
        sl.kind = "expr"
      elseif sl.kind == "lambda" then
        local f = sl.e
        while f.tag == "Paren" do f = f.e end
        lambdas[#lambdas + 1] = f
        lnames[f] = sl.name
      elseif sl.kind == "expr" then
        local saved_ctx = get_ctx
        get_ctx = ctx and { tags = ctx.tags, prefix = path }
        table_base = nil                           -- a table assigned to a variable: its outputs can split
        if s and s.tag == "Local" then
          for k, ex in ipairs(s.exprs) do
            if ex == sl.e and s.names[k] and s.name_pos[k] then
              local d = decl_at[s.name_pos[k][1]]
              if d then table_base = { text = s.names[k], decl = d } end
            end
          end
        elseif s and s.tag == "Set" then
          for k, ex in ipairs(s.exprs) do
            if ex == sl.e and s.targets[k] then
              local p, base = path_of(s.targets[k])
              local u = base and use_at[base.pos]
              if p and u and u.decl then table_base = { text = p, decl = u.decl } end
            end
          end
        end
        local en, gw, gh, core = expr_node(sl.e, is_call, x, ey, lambdas, sl.class)
        table_base = nil
        get_ctx = saved_ctx
        en.slot = sl
        en.group_w, en.full_w = core, gw
        en.line = sl.e.line or (s and s.line)
        enodes[#enodes + 1] = en
        ey = ey + gh + GAPY / 2
        ew = math.max(ew, core)
      end
    end
    local cn = {}                                  -- its chips sit left of it: room for them
    for _, sl in ipairs(slots) do
      if sl.kind == "var" then
        local u = use_at[sl.e.pos]
        if u and chip_for(u.decl, sl.e.pos) then cn[#cn + 1] = u.decl.name end
      end
    end
    local croom = chip_room(cn)
    local sx = (ew > 0 and (x + ew + GAPX) or x) + croom
    io.slots = slots
    if kind ~= "expr" then                         -- a statement: in the flow
      if io.exec_in == nil then io.exec_in = true end
      io.exec_outs = io.exec_outs or { "" }
    end
    local n = new_node(kind, title, {}, sx, y, s, io)
    n.ast = s                                      -- (where its flow outs lead, in the text)
    n.fields = n.fields or {}
    for _, sl in ipairs(slots) do
      if not sl.action then n.fields["slot" .. sl.pin_index] = field({ sl.e }) end
      local kp = sl.field and sl.field.key_pos      -- a table field's name: renamed in place
      if kp then n.fields["key" .. sl.pin_index] = { pos = kp[1], epos = kp[2] } end
    end
    local reach = 0                                -- how far right the groups (and their functions) reach
    for _, en in ipairs(enodes) do                 -- right-aligned, next to the pins they feed
      reparent(en, n)
      local dx = (sx - croom - GAPX - en.w) - en.x  -- (left of the chips, not under them)
      shift(en, dx, 0)                             -- (a call node: with its own inputs)
      reach = math.max(reach, dx + en.full_w)
      g.links[#g.links + 1] = { from = en.id, out = 1, to = n.id, inp = en.slot.pin_index, expr = true }
    end
    if n.edit and n.edit.kind == "node" then expr_edits(n, n.edit) end   -- its place: --@expr tags with the statement's
    local names = s and lambda_names(s, lambdas) or {}
    for f, nm in pairs(lnames) do names[f] = names[f] or nm end   -- a field's lambda: named after its key
    local w, h = side_frames(n, lambdas, names)
    return n, math.max((sx - x) + w, reach), math.max(h, ey - GAPY / 2 - y), (sx - x) + n.w
  end
  local function simple(kind, title, s, x, y, slots, io)
    local n, w, h = stmt_node(kind, title, s, x, y, slots or {}, io)
    return { w = w, h = h, entry = n.id, exits = { { id = n.id } } }
  end
  local function cond_node(title, cond, x, y, owner)
    return stmt_node("branch", title, owner, x, y, { { name = "condition", e = cond } },
                     { exec_outs = title == "until" and { "done" } or { "then", "else" } })
  end

  -- lay out the floating code inside function f (nil: the top level) not
  -- claimed by an inner one yet; returns how far right / down it reaches
  layout_floats = function(f, fr)
    local x2, y2 = -math.huge, -math.huge
    for _, F in ipairs(g.floats) do
      if not F.done and (not f or (f.pos <= F.pos and F.pos <= f.epos)) then
        F.done, F.frame = true, fr
        local shadow = src:sub(1, F.inner_pos - 1):gsub("[^\n]", " ") .. src:sub(F.inner_pos, F.inner_epos)
                       .. src:sub(F.inner_epos + 1):gsub("[^\n]", " ")
        local fast, ferr = opts.parse(shadow)
        if not fast and F.inner_pos - F.pos > 10 then  -- a bare expression (a table, a formula): "local _ =" in the header's room
          local pre = "local _ ="
          local at = F.inner_pos - 1 - #pre
          local ex = shadow:sub(1, at - 1) .. pre .. shadow:sub(at + #pre)
          local east = opts.parse(ex)
          local st = east and east.body.stmts
          if st and #st == 1 and st[1].tag == "Local" and #st[1].exprs == 1 then fast, F.expr = east, st[1].exprs[1] end
          local inner = F.expr and F.expr.tag == "Paren" and F.expr.e   -- (f(x)): a call's value (not a call statement):
          if inner and (inner.tag == "Call" or inner.tag == "Invoke") then F.expr, F.unwrapped = inner, true end   -- its call node
        end
        if not fast then F.err = ferr
        else
          for _, c in ipairs(fast.comments or {}) do   -- its ---@type lines (and other annotations)
            if c.text:match("^%-%-%-@") and starts_line(c.pos) then comment_at[c.line] = comment_at[c.line] or c end
            if c.text:match("^%-%-@expr") and starts_line(c.pos) then   -- its expression nodes' places (they move on their own)
              local t = M.parse_tag(c.text)
              if t then t.line = c.line; tags[c.line] = tags[c.line] or t end
            end
          end
          if opts.resolve then                     -- its own names (it can't see the function's)
            local fres = opts.resolve(fast)
            for _, u in ipairs(fres.uses) do use_at[u.pos] = use_at[u.pos] or u end
            for p, d in pairs(fres.decl_at) do decl_at[p] = decl_at[p] or d end
          end
          local bx, by = fr and fr.head.x or 0, fr and fr.head.y or 0
          local fl = { x = bx + F.dx, y = by + F.dy, float = F }
          floating = floating + 1
          local saved = parent
          parent = fr
          adopt(fl)
          parent = fl
          local b
          if F.expr and F.expr.tag == "Function" then   -- a lambda floats as its frame (its head's fn out: wire it to a pin)
            local fr2 = layout_frame(F.expr, fl.x, fl.y, "function", nil, true)
            F.root = fr2.head.id
            b = { w = fr2.w, h = fr2.h }
          elseif F.expr and F.expr.tag == "Id" then   -- a bare name: a "get" node (UE's getter), its value out
            local en = new_node("expr", "get " .. F.expr.name, {}, fl.x, fl.y, nil, { value_outs = { F.expr.name } })
            en.fields = { body = field({ F.expr }) }
            en.getter, en.get_e = F.expr.name, F.expr
            F.root = en.id
            b = { w = en.w, h = en.h }
          elseif F.expr then                       -- an expression floats on its own (wire its result to a pin)
            local kind, what = classify(F.expr)
            local en, gw, gh = expr_node(F.expr, kind == "expr" and what, fl.x, fl.y, {})
            F.root = en.id
            b = { w = gw, h = gh }
          else
            b = layout_block(fast.body, fl.x, fl.y)
          end
          parent = saved
          floating = floating - 1
          fl.w, fl.h = math.max(b.w, 10), math.max(b.h, 10)
          F.el, F.first = fl, b.entry
          x2, y2 = math.max(x2, fl.x + fl.w), math.max(y2, fl.y + fl.h)
          local function mark(el)                  -- its nodes move (and are dragged) as one
            for _, k in ipairs(el.kids or {}) do
              if k.id then
                k.color = parse_color(F.vals.color)
                if not (k.edit and k.edit.kind == "expr") then
                  if k.edit and k.edit.kind == "node" then k.node_edit = k.edit end   -- (its own tags: split pins, getters)
                  k.edit = { kind = "float", float = F }; k.float_el = fl
                end
              end                                  -- (an expression node feeding a statement: on its own, like outside)
              mark(k)
            end
          end
          mark(fl)
        end
      end
    end
    return x2, y2
  end

  local function layout_stmt(s, x, y, vertical)
    local t = s.tag
    if t == "Local" then
      local names = {}
      for i, nm in ipairs(s.names) do names[i] = nm .. (s.attribs[i] and (" <" .. s.attribs[i] .. ">") or "") end
      -- "new local": an input pin per value, named after its variable(s); the
      -- outputs (the variables, wired to their readers) stay silent
      local slots = {}
      for i, e in ipairs(s.exprs) do
        local nm = names[i] or ("value " .. i)
        if i == #s.exprs and #names > #s.exprs then nm = table.concat(names, ", ", i) end   -- f() feeding the rest
        slots[i] = { name = nm, e = e }
      end
      local ty = type_above(s.line)                -- ---@type Paddle above it: its table is a Paddle
      if ty and g.classes[ty] and slots[1] and slots[1].e.tag == "Table" then slots[1].class = ty end
      if #s.exprs > 0 and #s.exprs == #names then  -- one more name and value: "+ add value"
        slots[#slots + 1] = { name = "+ add value", e = { tag = "Local", pos = s.pos, epos = s.epos, line = s.line },
                              force = "action", action = "addvar", stmt = s }
      end
      local title = #s.exprs > 0 and "new local" or ("local " .. table.concat(names, ", "))
      local fl = { body = field(s.exprs), title = names_field(s.name_pos) }
      if #s.exprs > 0 then                         -- set local: each name is renamed on its own pin
        fl.title = { blocked = "rename a variable on its pin (double-click its name, or right-click it)" }
        for i = 1, #s.exprs do
          local sp = {}
          for k = i, (i == #s.exprs and #s.name_pos or i) do sp[#sp + 1] = s.name_pos[k] end
          fl["var" .. i] = names_field(sp)
        end
      end
      return with_fields(simple("local", title, s, x, y, slots, { outs = s.name_pos, silent_outs = #s.exprs > 0 }), fl)
    elseif t == "Set" then
      -- "set": one input per value, named after what it's written to
      local tnames, extra = {}, {}
      for i, tg in ipairs(s.targets) do
        tnames[i] = text_of(src, tg)
        if tg.tag == "Index" and is_nil(tg.obj) then extra[1] = "attempt to index a nil value" end
      end
      local slots = {}
      for i, e in ipairs(s.exprs) do
        local nm = tnames[i] or ("value " .. i)
        if i == #s.exprs and #tnames > #s.exprs then nm = table.concat(tnames, ", ", i) end
        slots[i] = { name = nm, e = e }
      end
      local fl = { body = field(s.exprs),               -- what's written: on each pin's name (double-click it)
                   title = { blocked = "change what's set on its pin: double-click its name (its value: the box)" } }
      for i = 1, #s.exprs do
        local tg = {}
        for k = i, (i == #s.exprs and #s.targets or i) do tg[#tg + 1] = s.targets[k] end
        fl["var" .. i] = field(tg)
      end
      local global = false                         -- a name no local declares: "set global"
      for _, tg in ipairs(s.targets) do
        local u = tg.tag == "Id" and use_at[tg.pos]
        if u and not u.decl then global = true end
      end
      return with_fields(simple("set", global and "set global" or "set", s, x, y, slots, { diags_extra = extra }), fl)
    elseif t == "CallStat" then
      local slots, title, callee, capi = call_slots(s.call)
      local r = simple("call", title, s, x, y, slots)
      g.nodes[r.entry].dcall = { title = (title:gsub("^call ", "")), callee = callee, api = capi }
      return with_fields(r, { body = field({ s.call }) })
    elseif t == "Return" then
      local info = cur_fn and g.fn_info[cur_fn]
      local slots = values(s.exprs, "value")
      for i, sl in ipairs(slots) do                -- named by ---@return
        local a = info and info.returns[i]
        if a and a.name then sl.name = a.name end
        if a and g.classes[a.type] and sl.e.tag == "Table" then sl.class = a.type end
        sl.ret_index = i
      end
      local fk = not cur_fn and slots[1] and opts.file_kind    -- (a folder world's data file: what it returns, typed)
      if fk == "member" and slots[1].e.tag == "Table" then slots[1].class = "class member"   -- (classes/<x>/<m>.lua: a description)
      elseif fk == "meta" and slots[1].e.tag == "Table" then g.meta_tables[slots[1].e] = true    -- (meta.lua: descriptions)
      elseif fk == "value" and opts.file_desc then                -- (<node>/<f>.lua, its meta.lua says its type)
        local cf = g.cf_of("file", { name = "value", d = opts.file_desc, text = "" })
        local sl = slots[1]
        sl.ftype = cf.type
        if cf.range and not sl.hint then sl.hint = { range = cf.range } end
        if g.aliases[cf.type] and not sl.hint then sl.hint = { enum = g.aliases[cf.type] } end
        if g.classes[cf.type] and sl.e.tag == "Table" then sl.class = cf.type end
      end
      -- one more value: wire a variable in (or click it), every return of the function gets one too
      slots[#slots + 1] = { name = "+ add value", e = { tag = "Return", pos = s.pos, epos = s.epos, line = s.line },
                            force = "action", action = "addret", stmt = s }
      local r = with_fields(simple("return", "return", s, x, y, slots, { exec_outs = {} }), { body = field(s.exprs) })
      g.nodes[r.entry].ret_fn = cur_fn             -- (its pins' names live in that function's annotations)
      r.exits = {}
      return r
    elseif t == "Break" or t == "Goto" or t == "Label" then
      local r = simple(t == "Label" and "call" or "return", t == "Break" and "break" or t == "Goto" and ("goto " .. s.label) or ("::" .. s.name .. "::"),
        s, x, y, nil, { exec_outs = t == "Label" and { "" } or {} })
      if t ~= "Label" then r.exits = {} end
      return r
    elseif t == "LocalFunction" or (t == "Function" and s.func) then
      local title = (t == "LocalFunction" and "local function " or "function ") .. s.name
      local fr = layout_frame(s.func, x, y, title, s)
      fr.head.block_stmt = s
      -- a function's definition isn't a step of the flow around it (its
      -- header starts its own flow): the statements around it connect past it
      return { w = fr.w, h = fr.h }
    elseif t == "Do" then
      return layout_block(s.body, x, y, vertical)
    elseif t == "If" then                          -- one row per branch: its condition, then its body
      local first, fw, fh = cond_node("if", s.clauses[1].cond, x, y, s)
      first.fields.body = field({ s.clauses[1].cond })
      local saved = parent
      parent = first                               -- the branches move with the "if"
      local ry, w = y, fw
      local exits, test, tw = {}, first, fw
      for i, cl in ipairs(s.clauses) do
        local cond, cw, ch = test, tw, (i == 1) and fh or 0
        if i > 1 then                              -- elseif: its condition starts a new row
          cond, cw, ch = cond_node("if", cl.cond, x, ry, nil)   -- an elseif: an if wired into the else before it
          cond.ast, cond.clause = s, i
          local kw, p = nil, s.clauses[i - 1].cond.epos   -- its place: tags above its `elseif` line
          while true do
            local a = src:find("%f[%w]elseif%f[%W]", p)
            if not a or a > cl.cond.pos then break end
            kw, p = a, a + 6
          end
          cond.edit = kw and stmt_edit({ pos = kw, line = line_of(kw) }) or nil
          if cond.edit then cond.edit.clause = true end
          if cond.edit then expr_edits(cond, cond.edit) end   -- (its expression nodes: --@expr tags there too)
          cond.line = cl.line
          cond.fields.body = field({ cl.cond })
          edge(test.id, cond.id, "else")
        end
        local b = layout_block(cl.body, x + cw + GAPX, ry)
        if b.entry then edge(cond.id, b.entry, "then") else exits[#exits + 1] = { id = cond.id, label = "then" } end
        for _, e in ipairs(b.exits) do exits[#exits + 1] = e end
        w = math.max(w, cw + (b.entry and (GAPX + b.w) or 0))
        ry = ry + math.max(ch, b.h) + GAPY
        test, tw = cond, cw
      end
      if s.orelse then                             -- else: a row of its own, under the last condition's
        local b = layout_block(s.orelse, x + tw + GAPX, ry)
        if b.entry then
          edge(test.id, b.entry, "else")
          w = math.max(w, tw + GAPX + b.w)
          ry = ry + b.h + GAPY
        else exits[#exits + 1] = { id = test.id, label = "else" } end
        for _, e in ipairs(b.exits) do exits[#exits + 1] = e end
      else
        exits[#exits + 1] = { id = test.id, label = "else" }
      end
      parent = saved
      return { w = w, h = ry - GAPY - y, entry = first.id, exits = exits }
    elseif t == "While" or t == "Fornum" or t == "Forin" then
      local title, slots
      if t == "While" then title, slots = "while", { { name = "condition", e = s.cond } }
      elseif t == "Fornum" then
        title = "for"                              -- (its variable: the output pin; double-click renames)
        slots = { { name = "start", e = s.start, need = "'for' initial value must be a number" },
                  { name = "stop", e = s.stop, need = "'for' limit must be a number" } }
        if s.step then slots[3] = { name = "step", e = s.step, need = "'for' step must be a number" } end
      else
        title = "for each"
        slots = values(s.exprs, #s.exprs == 1 and "iterator" or "in")
      end
      local n, nw, nh = stmt_node("loop", title, s, x, y, slots,
        { outs = t == "Fornum" and { s.var_pos } or t == "Forin" and s.names_pos or nil, exec_outs = { "done", "body" } })
      n.fields.body = field(t == "While" and { s.cond } or t == "Fornum" and { s.start, s.stop, s.step } or s.exprs)
      n.fields.title = t == "Fornum" and names_field({ s.var_pos }) or t == "Forin" and names_field(s.names_pos) or nil
      local saved = parent
      parent = n                                   -- the body moves with the loop
      local b = layout_block(s.body, x + INDENT, y + nh + GAPY)
      parent = saved
      if b.entry then edge(n.id, b.entry, "do") end   -- (UE style: the body's end isn't wired back to the loop)
      return { w = math.max(nw, INDENT + b.w), h = nh + GAPY + b.h, entry = n.id, exits = { { id = n.id, label = "done" } } }
    elseif t == "Repeat" then
      local n, nw, nh = stmt_node("loop", "repeat", s, x, y, {}, { exec_outs = { "body" } })
      local saved = parent
      parent = n
      local by = y + nh + GAPY
      local b = layout_block(s.body, x + INDENT, by)
      local ux = x + INDENT + (b.entry and (b.w + GAPX) or 0)
      local u, uw, uh = cond_node("until", s.cond, ux, by, nil)   -- at the end of the body's row
      u.ast = s
      u.line = s.cond.line
      do                                           -- its place: tags above its `until` line (or inline)
        local kw, p = nil, s.pos
        while true do
          local a = src:find("%f[%w]until%f[%W]", p)
          if not a or a > s.cond.pos then break end
          kw, p = a, a + 5
        end
        u.edit = kw and stmt_edit({ pos = kw, line = line_of(kw) }) or nil
        if u.edit then expr_edits(u, u.edit) end
      end
      u.fields.body = field({ s.cond })
      parent = saved
      if b.entry then edge(n.id, b.entry, "do") end
      for _, e in ipairs(b.exits) do edge(e.id, u.id, e.label) end
      if not b.entry then edge(n.id, u.id) end

      return { w = math.max(nw, ux + uw - x), h = nh + GAPY + math.max(b.h, uh), entry = n.id, exits = { { id = u.id, label = "done" } } }
    end
    return simple("call", t, s, x, y)
  end

  -- a block: left to right, or top to bottom (vertical: the file's top level)
  layout_block = function(b, x, y, vertical)
    local cx, cy, w, h, entry, exits = x, y, 0, 0, nil, {}
    local saved_limit = wrap_limit
    if not vertical then                           -- (a nested block wraps at the same edge, with some room)
      wrap_limit = math.max(wrap_limit or (x + M.WRAP_W), x + M.WRAP_W / 2)
    end
    local rowh = 0                                 -- the height of the current row
    for si, s in ipairs(b.stmts) do
      local mark = parent and parent.kids and #parent.kids or 0
      local r = layout_stmt(s, cx, cy, vertical)
      local wrapped = false
      if not vertical and parent and cx > x and cx + r.w > wrap_limit then
        -- past the edge: it (and all that hangs from it) starts a new row
        local ny = cy + rowh + 2 * GAPY
        for k = mark + 1, #(parent.kids or {}) do shift(parent.kids[k], x - cx, ny - cy) end
        w = math.max(w, cx - GAPX - x + 50)         -- (room for the wire's turn at the row's end)
        cx, cy, rowh, wrapped = x, ny, 0, true
      end
      if r.entry and g.nodes[r.entry].kind ~= "function" then   -- (taking a statement out of the flow)
        g.nodes[r.entry].block, g.nodes[r.entry].idx = b, si
      end
      if r.entry then
        if not entry then entry = r.entry end
        for _, e in ipairs(exits) do edge(e.id, r.entry, e.label, nil, wrapped or nil) end
        exits = r.exits
      end
      if vertical then cy = cy + r.h + GAPY; w = math.max(w, r.w)
      else cx = cx + r.w + GAPX; rowh = math.max(rowh, r.h) end
    end
    wrap_limit = saved_limit
    if vertical then return { w = w, h = math.max(0, cy - GAPY - y), entry = entry, exits = exits } end
    return { w = math.max(w, cx - GAPX - x, 0), h = (cy - y) + rowh, entry = entry, exits = exits }
  end

  layout_frame = function(f, x, y, title, owner, value)   -- value: a floating lambda (its head has a "fn" out)
    local fr = { title = title, x = x, y = y }
    g.fn_info[f] = g.fn_info[f] or annotations(owner and owner.line or f.line)
    local saved_fn = cur_fn
    cur_fn = f
    adopt(fr)
    local saved = parent
    parent = fr                                    -- the header and the body move with the frame
    local hio = { outs = {}, hints = g.fn_info[f].params, exec_outs = { "" } }   -- its outputs: its name (a local function), its parameters
    if value then hio.value_outs = { "fn" } end
    if owner and owner.tag == "LocalFunction" then hio.outs[1] = owner.name_pos end
    for _, sp in ipairs(f.param_pos or {}) do hio.outs[#hio.outs + 1] = sp end
    hio.tail = { { name = "+ add parameter", action = "addparam", stmt = f, pos = f.pos, epos = f.pos,
                   e = { tag = "Function", pos = f.pos, epos = f.pos, line = f.line } } }
    local htitle = res and (title .. (f.vararg and " (...)" or ""))   -- the parameters are its sockets
                   or (title .. "(" .. table.concat(f.params, ", ") .. (f.vararg and ", ..." or "") .. ")")
    local head = new_node("function", htitle, {}, x + FPAD, y + FPAD, owner or f, hio)
    node_of[f] = head.id
    head.edit = frame_edit(f)
    if owner and owner.tag == "LocalFunction" then   -- its name and parameters: "name(a, b)"
      local spans = { owner.name_pos }
      for _, sp in ipairs(f.param_pos or {}) do spans[#spans + 1] = sp end
      head.fields = { title = { rename = true, spans = spans, fmt = "func", vararg = f.vararg } }
    else                                           -- parameters only: "(a, b)"
      local fl = names_field(f.param_pos, "params") or { rename = true, spans = {}, fmt = "params" }
      fl.vararg = f.vararg
      head.fields = { title = fl }
    end
    fr.tag = head.edit and head.edit.tag
    local saved_limit = wrap_limit
    wrap_limit = nil                               -- (its rows wrap from where its body starts)
    local b = layout_block(f.body, head.x + head.w + GAPX, head.y)   -- the body: right of the header
    wrap_limit = saved_limit
    parent = saved
    if b.entry then edge(head.id, b.entry) end
    local w = head.w + (b.entry and (GAPX + b.w) or 0) + 2 * FPAD
    local h = math.max(head.h, b.h) + 2 * FPAD
    fr.head = head                                 -- (floating code is placed from the header)
    local fx2, fy2 = layout_floats(f, fr)          -- its floating code: inside its frame
    w, h = math.max(w, fx2 + FPAD - x), math.max(h, fy2 + FPAD - y)
    fr.w, fr.h, fr.head, fr.func = w, h, head, f
    head.frame = fr
    -- (the header keeps its own width: its outputs sit right of its names)
    g.frames[#g.frames + 1] = fr
    frame_of[f] = fr
    cur_fn = saved_fn
    return fr
  end

  -- the file's flow starts here (what runs when the file is loaded)
  local start = new_node("start", "start", {}, 0, 0, nil, { exec_outs = { "" } })
  do                                               -- its place: a --@start dx= dy= line (the first one; added at the top)
    local first
    for l, t in pairs(tags) do if t.kind == "start" and (not first or l < first.line) then first = t end end
    start.edit = { kind = "start", tag = first, insert_line = 1, indent = "" }
  end
  g.start, g.top_block = start, ast.body
  local top = layout_block(ast.body, 0, start.h + GAPY, true)
  if top.entry then edge(start.id, top.entry) end
  layout_floats(nil, nil)                          -- the top level's floating code

  -- the automatic layout snaps to the grid (opts.grid: the one drawn, in
  -- graph units); overrides (--@node dx= dy=) then apply as written, and
  -- floating code keeps its own place. A frame follows its header.
  local GRID = opts.grid or 24
  if GRID > 0 then
    local function snap(v) return math.floor(v / GRID + 0.5) * GRID end
    for _, n in ipairs(g.nodes) do
      if not (n.floating or (n.edit and n.edit.kind == "float")) then   -- (floating code keeps its own place)
        local dx, dy = snap(n.x) - n.x, snap(n.y) - n.y
        n.x, n.y = n.x + dx, n.y + dy
        if n.frame and n.frame.head == n then n.frame.x, n.frame.y = n.frame.x + dx, n.frame.y + dy end
      end
    end
    -- rounding can close the small gap between stacked expression inputs: one
    -- that now overlaps one above it (or its own inputs: a concat's operand
    -- hangs below the concat) goes down whole cells, with its own inputs
    local function fixed(k) return k.kind == "expr" and not (k.floating or (k.edit and k.edit.kind == "float")) end
    local function down(el, d)
      el.y = el.y + d
      for _, k in ipairs(el.kids or {}) do if k.kind == "expr" then down(k, d) end end
    end
    local function box(el, b)                      -- an input and its own inputs: x0, y0, x1, y1
      b = b or { el.x, el.y, el.x + el.w, el.y + el.h }
      b[1], b[2] = math.min(b[1], el.x), math.min(b[2], el.y)
      b[3], b[4] = math.max(b[3], el.x + el.w), math.max(b[4], el.y + el.h)
      for _, k in ipairs(el.kids or {}) do if fixed(k) then box(k, b) end end
      return b
    end
    local function unstack(el)
      for _, k in ipairs(el.kids or {}) do unstack(k) end   -- (inside first: their groups settle)
      local ex = {}
      for _, k in ipairs(el.kids or {}) do if fixed(k) then ex[#ex + 1] = k end end
      table.sort(ex, function(a, b) return a.y < b.y end)
      for i = 2, #ex do
        local b = ex[i]
        for j = 1, i - 1 do
          local A, B = box(ex[j]), box(b)
          local gap = B[2] - A[4]
          if gap < 4 and B[1] < A[3] and A[1] < B[3] then
            down(b, math.ceil((4 - gap) / GRID) * GRID)
          end
        end
      end
    end
    for _, n in ipairs(g.nodes) do if not n.parent then unstack(n) end end
    for _, f in ipairs(g.frames) do if not f.parent then unstack(f) end end
    -- those pushes can reach the next statement in the same block (a tall
    -- stack of inputs over what follows it): that one, and everything after
    -- it in the block, goes down whole cells too; a function's frame grows
    -- to hold what moved. Inside first, then the file's top level.
    local function loose(k) return k.floating or (k.edit and k.edit.kind == "float") end
    local function extent(el, b)                   -- el and all that moves with it: x0, y0, x1, y1
      b = b or { math.huge, math.huge, -math.huge, -math.huge }
      b[1], b[2] = math.min(b[1], el.x), math.min(b[2], el.y)
      b[3], b[4] = math.max(b[3], el.x + el.w), math.max(b[4], el.y + el.h)
      for _, k in ipairs(el.kids or {}) do if not loose(k) then extent(k, b) end end
      return b
    end
    local function settle_flow(flow)               -- statements (and frames) of one level, in their order
      table.sort(flow, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
      local boxes = {}
      for i, el in ipairs(flow) do boxes[i] = extent(el) end
      for i = 2, #flow do
        for j = 1, i - 1 do
          local A, B = boxes[j], boxes[i]
          local gap = B[2] - A[4]
          if gap < 4 and B[1] < A[3] and A[1] < B[3] then
            local d = math.ceil((4 - gap) / GRID) * GRID
            for k = i, #flow do                    -- (the flow keeps its order: all after it moves too)
              shift(flow[k], 0, d)
              boxes[k][2], boxes[k][4] = boxes[k][2] + d, boxes[k][4] + d
            end
          end
        end
      end
    end
    local function settle(el)
      local flow = {}
      for _, k in ipairs(el.kids or {}) do
        if k.kids then settle(k) end
        if not loose(k) and (k.block or k.head) then flow[#flow + 1] = k end
      end
      if #flow > 1 then settle_flow(flow) end
      if el.head then                              -- a frame: around all it holds
        local x1, y1 = el.x + el.w, el.y + el.h
        for _, k in ipairs(el.kids or {}) do
          if not loose(k) then local b = extent(k); x1, y1 = math.max(x1, b[3] + FPAD), math.max(y1, b[4] + FPAD) end
        end
        el.w, el.h = x1 - el.x, y1 - el.y
      end
    end
    local tops = {}
    for _, n in ipairs(g.nodes) do if not n.parent and not loose(n) then settle(n); tops[#tops + 1] = n end end
    for _, f in ipairs(g.frames) do if not f.parent then settle(f); tops[#tops + 1] = f end end
    settle_flow(tops)
  end

  -- the tags: offsets (down the parent chain), colours, transparency
  local function own(el)
    local t = el.head and el.tag or (not el.frame and el.edit and el.edit.tag)
    if not t then return 0, 0 end
    return tonumber(t.vals.dx) or 0, tonumber(t.vals.dy) or 0
  end
  -- A node's offset moves it alone (UE style: its expression inputs, an if's
  -- branches, a loop's body, the functions under it stay); a frame's (a
  -- function) and floating code's move everything inside them.
  local memo, imemo = {}, {}
  local offset
  local function inherited(el)                     -- what el gets from its parents
    local p = el.parent
    if not p then return 0, 0 end
    if imemo[el] then return imemo[el][1], imemo[el][2] end
    local x, y
    if p.head or p.float then x, y = offset(p)
    else x, y = inherited(p) end
    imemo[el] = { x, y }
    return x, y
  end
  offset = function(el)
    if not el then return 0, 0 end
    if memo[el] then return memo[el][1], memo[el][2] end
    local px, py = inherited(el)
    local dx, dy = own(el)
    memo[el] = { px + dx, py + dy }
    return px + dx, py + dy
  end
  for _, n in ipairs(g.nodes) do
    local dx, dy = offset(n)
    n.x, n.y = n.x + dx, n.y + dy
    n.odx, n.ody = dx, dy                          -- (what dragging did: a diff tells a moved node by it)
    local t = n.frame and n.frame.tag or (n.edit and n.edit.tag)
    if t then n.color, n.alpha = parse_color(t.vals.color), tonumber(t.vals.alpha) end
  end
  for _, f in ipairs(g.frames) do
    local dx, dy = offset(f)
    f.x, f.y = f.x + dx, f.y + dy
    if f.tag then f.color, f.alpha = parse_color(f.tag.vals.color), tonumber(f.tag.vals.alpha) end
  end
  -- frames grow to hold what was dragged out of them (inner frames come first in g.frames)
  for _, f in ipairs(g.frames) do
    local x1, y1, x2, y2 = f.x, f.y, f.x + f.w, f.y + f.h
    local function grow(el)
      for _, k in ipairs(el.kids or {}) do
        if not k.float then                        -- (floating code: by its nodes, below)
          x1, y1 = math.min(x1, k.x - FPAD), math.min(y1, k.y - FPAD)
          x2, y2 = math.max(x2, k.x + k.w + FPAD), math.max(y2, k.y + k.h + FPAD)
        end
        grow(k)
      end
    end
    grow(f)
    f.x, f.y, f.w, f.h = x1, y1, x2 - x1, y2 - y1
  end
  g.x0, g.y0 = 0, 0
  for _, n in ipairs(g.nodes) do g.x0 = math.min(g.x0, n.x); g.y0 = math.min(g.y0, n.y) end
  -- value types, where they're certain: pins and wires take their colour
  --   boolean integer number string table function nil   (else: unknown)
  -- From literals, operators, ---@param / ---@type / ---@return, a few library
  -- calls, and variables never written again after their declaration.
  do
    local function from_annot(ty)                  -- a LuaLS type -> ours
      if not ty then return nil end
      ty = ty:gsub("%?$", "")
      if ty == "number" or ty == "integer" or ty == "string" or ty == "boolean" or ty == "nil" then return ty end
      if ty == "table" or ty:find("%[%]$") or ty:find("^table<") or g.classes[ty] then return "table" end
      if ty == "function" or ty:find("^fun%(") then return "function" end
      if g.aliases[ty] then return "string" end
    end
    local LIB = {
      tostring = "string", type = "string", ["string.format"] = "string", ["string.sub"] = "string",
      ["string.rep"] = "string", ["string.upper"] = "string", ["string.lower"] = "string",
      ["string.reverse"] = "string", ["string.char"] = "string", ["table.concat"] = "string",
      ["string.len"] = "integer", ["math.floor"] = "integer", ["math.ceil"] = "integer",
      ["math.sqrt"] = "number", ["math.sin"] = "number", ["math.cos"] = "number", ["math.tan"] = "number",
      ["math.atan"] = "number", ["math.exp"] = "number", ["math.log"] = "number", ["math.rad"] = "number",
      ["math.deg"] = "number", ["setmetatable"] = "table",
    }
    local function path(e)
      if e.tag == "Id" then return e.name end
      if e.tag == "Index" and e.name then local o = path(e.obj); return o and (o .. "." .. e.name) end
    end
    local NUM = { integer = true, number = true }
    local type_of, decl_type
    local busy = {}
    type_of = function(e)
      if type(e) ~= "table" then return nil end
      local t = e.tag
      if t == "Number" then
        local r = e.raw:lower()
        if r:find("^0x") then return (r:find("[%.p]") and "number" or "integer") end
        return r:find("[%.e]") and "number" or "integer"
      elseif t == "String" then return "string"
      elseif t == "True" or t == "False" then return "boolean"
      elseif t == "Nil" then return "nil"
      elseif t == "Table" then return "table"
      elseif t == "Function" then return "function"
      elseif t == "Paren" then return type_of(e.e)
      elseif t == "Unop" then
        local a = type_of(e.e)
        if e.op == "not" then return "boolean" end
        if e.op == "#" then return "integer" end     -- (a string or a table without __len)
        if e.op == "-" and NUM[a] then return a end
        if e.op == "~" and a == "integer" then return "integer" end
      elseif t == "Binop" then
        local op = e.op
        if op == "==" or op == "~=" or op == "<" or op == "<=" or op == ">" or op == ">=" then return "boolean" end
        local a, b = type_of(e.l), type_of(e.r)
        if op == "and" or op == "or" then return a and a == b and a or nil end
        if op == ".." then return ((a == "string" or NUM[a]) and (b == "string" or NUM[b])) and "string" or nil end
        if not (NUM[a] and NUM[b]) then return nil end   -- (tables can do arithmetic with metamethods)
        if op == "/" or op == "^" then return "number" end
        if op == "&" or op == "|" or op == "~" or op == "<<" or op == ">>" then return "integer" end
        return (a == "integer" and b == "integer") and "integer" or "number"
      elseif t == "Id" then
        local u = use_at[e.pos]
        return u and u.decl and decl_type(u.decl)
      elseif t == "Index" then
        local p = path(e)
        if p == "math.pi" or p == "math.huge" then return "number" end
        if p == "math.maxinteger" or p == "math.mininteger" then return "integer" end
      elseif t == "Call" then
        local p = path(e.fn)
        if p and LIB[p] then return LIB[p] end
        if p == "math.random" and #e.args > 0 then return "integer" end
        if p == "math.abs" or p == "math.max" or p == "math.min" then   -- the type of their numbers
          local k
          for _, a in ipairs(e.args) do local ta = type_of(a); if not NUM[ta] then return nil end; k = (k == nil or k == ta) and ta or "number" end
          return k
        end
        local u = e.fn.tag == "Id" and use_at[e.fn.pos]   -- a local function: its ---@return
        local d = u and u.decl
        if d and d.kind == "function" and not d.assigned and d.owner.func then
          local info = g.fn_info[d.owner.func]
          local r = info and info.returns[1]
          return r and from_annot(r.type)
        end
      end
    end
    decl_type = function(d)
      if d.vtype ~= nil then return d.vtype or nil end
      if busy[d] then return nil end
      busy[d] = true
      local ty
      local o = d.owner
      if d.kind == "function" then ty = not d.assigned and "function" or nil
      elseif d.assigned then ty = nil
      elseif d.kind == "param" then
        local info = g.fn_info[o]
        ty = info and from_annot(info.params[d.name])
      elseif d.kind == "local" and o and o.tag == "Local" then
        local i
        for k, nm in ipairs(o.names) do if o.name_pos[k][1] == d.pos then i = k end end
        local an = type_above(o.line)
        if an and #o.names == 1 then ty = from_annot(an) end
        if not ty and i then
          local ex = o.exprs[i]
          if ex then
            local last = o.exprs[#o.exprs]
            if not (i == #o.exprs and (ex.tag == "Call" or ex.tag == "Invoke") and #o.names > #o.exprs) then ty = type_of(ex) end
          elseif #o.exprs == 0 or not (o.exprs[#o.exprs].tag == "Call" or o.exprs[#o.exprs].tag == "Invoke" or o.exprs[#o.exprs].tag == "Vararg") then
            ty = "nil"                             -- local x (never written): nil
          end
        end
      elseif d.kind == "loop" and o then
        if o.tag == "Fornum" then
          local a, st = type_of(o.start), o.step and type_of(o.step) or "integer"
          ty = (a == "integer" and st == "integer") and "integer" or (NUM[a] and NUM[st]) and "number" or nil
        elseif o.tag == "Forin" and d.pos == o.names_pos[1][1] and #o.exprs == 1 then
          local c = o.exprs[1]
          if c.tag == "Call" and path(c.fn) == "ipairs" then ty = "integer" end
        end
      end
      busy[d] = nil
      d.vtype = ty or false
      return ty
    end
    for _, n in ipairs(g.nodes) do
      for _, p in ipairs(n.ins or {}) do
        if p.decl then p.vtype = decl_type(p.decl)
        elseif p.e and not p.action and p.uses == nil then p.vtype = type_of(p.e) end
      end
      for i, o in ipairs(n.outs or {}) do
        if o.decl then o.vtype = decl_type(o.decl)
        elseif o.value and n.vexpr then
          if n.vcallee then                        -- a call node: its ---@return types
            local info = g.fn_info[n.vcallee]
            local r = info and info.returns[i]
            o.vtype = r and from_annot(r.type) or (i == 1 and type_of(n.vexpr)) or nil
          elseif i == 1 then o.vtype = type_of(n.vexpr) end
        end
      end
    end
    for _, n in ipairs(g.nodes) do                 -- a typed table field (---@class): what it should be
      for _, p in ipairs(n.ins) do
        if p.ftype and not p.want_type then p.want_type = from_annot(p.ftype) end
      end
    end
    -- a call node: its doc tooltip (signature + description, from the
    -- callee's annotations or the API's), and arguments of a type its
    -- parameters don't take (a warning: n.warns)
    for _, n in ipairs(g.nodes) do
      local dc = n.dcall
      if dc then
        local names, types, rets, doc = {}, {}, {}, nil
        if dc.callee then
          local info = g.fn_info[dc.callee] or annotations(dc.callee.line)
          for _, p in ipairs(dc.callee.params) do if p ~= "self" then names[#names + 1] = p end end
          if dc.callee.vararg then names[#names + 1] = "..." end
          types = info.params
          for _, r in ipairs(info.returns) do rets[#rets + 1] = r.type end
          doc = info.doc
        elseif dc.api then
          names, types, rets, doc = dc.api.params, dc.api.types or {}, dc.api.rets or {}, dc.api.doc
        end
        if dc.callee or dc.api then
          local ps = {}
          for _, p in ipairs(names) do ps[#ps + 1] = types[p] and (p .. ": " .. types[p]) or p end
          local sig = dc.title .. "(" .. table.concat(ps, ", ") .. ")" .. (#rets > 0 and (" -> " .. table.concat(rets, ", ")) or "")
          n.doc = { sig = sig, lines = doc }
        end
        if dc.api and dc.api.rets then             -- an API call's results: their ---@return types
          for i, o in ipairs(n.outs) do
            local r = dc.api.rets[i]
            if r and not o.vtype and not r:find("[|?]") then o.vtype = from_annot(r) end
          end
        end
        for _, p in ipairs(n.ins) do               -- what each argument should be (wiring converts to it)
          local want = p.param and types[p.param]
          p.want_type = want and not want:find("[|?]") and from_annot(want) or nil
        end
        if not n.floating then
          for _, p in ipairs(n.ins) do
            local want = p.param and types[p.param]
            local wt = want and not want:find("[|?]") and from_annot(want)
            local have = p.vtype
            if wt and have and have ~= "nil" and have ~= wt and not (wt == "number" and have == "integer") then
              n.warns = n.warns or {}
              n.warns[#n.warns + 1] = "'" .. p.param .. "': " .. want .. " expected, got " .. have
            end
          end
        end
      end
    end
  end
  for _, n in ipairs(g.nodes) do g.w = math.max(g.w, n.x + n.w); g.h = math.max(g.h, n.y + n.h) end
  for _, f in ipairs(g.frames) do g.w = math.max(g.w, f.x + f.w); g.h = math.max(g.h, f.y + f.h) end

  -- comment boxes: placed from the header of the function they're written in
  g.notes = {}
  for l, t in pairs(tags) do
    if t.kind == "comment" then
      local p = line_start[l]
      local fr, best
      for f, frm in pairs(frame_of) do
        if f.pos <= p and p <= f.epos and (not best or f.epos - f.pos < best) then fr, best = frm, f.epos - f.pos end
      end
      local bx, by = fr and fr.head.x or 0, fr and fr.head.y or 0
      g.notes[#g.notes + 1] = { tag = t, frame = fr, x = bx + (tonumber(t.vals.dx) or 0), y = by + (tonumber(t.vals.dy) or 0),
                                w = tonumber(t.vals.w) or 200, h = tonumber(t.vals.h) or 100, title = t.title or "" }
    end
  end

  -- goto: a faint wire to its label (in the same function; drawn only, like
  -- a jump, not a flow pin's connection)
  do
    local function fn_of(pos)                      -- the innermost function holding pos (nil: top level)
      local best
      for f in pairs(frame_of) do
        if f.pos <= pos and pos <= f.epos and (not best or f.epos - f.pos < best.epos - best.pos) then best = f end
      end
      return best or false
    end
    local labels = {}
    for _, n in ipairs(g.nodes) do
      if n.ast and n.ast.tag == "Label" then
        local key = tostring(fn_of(n.ast.pos)) .. "\0" .. n.ast.name
        labels[key] = labels[key] == nil and n or false   -- (twice: ambiguous)
      end
    end
    for _, n in ipairs(g.nodes) do
      if n.ast and n.ast.tag == "Goto" then
        local to = labels[tostring(fn_of(n.ast.pos)) .. "\0" .. n.ast.label]
        if to then g.exec[#g.exec + 1] = { from = n.id, to = to.id, back = true, jump = true }
        elseif to == nil and not (n.edit and n.edit.kind == "float") then                      -- its label is gone: Lua won't load the file
          local msg = "no visible label '" .. n.ast.label .. "' for goto"
          n.diags = n.diags or {}
          if #n.diags == 0 then n.diag_y = n.h; n.h = n.h + 4 end
          table.insert(n.diags, 1, { level = "error", msg = msg })   -- (errors first)
          n.has_error = true
          n.w = math.max(n.w, font:get_width(msg) + 2 * PADX + 14)
          n.h = n.h + lh + 6
          g.errors = (g.errors or 0) + 1
        end
      end
    end
  end

  -- the out pin each flow edge leaves from (by its label: then / else / body / done / again)
  for _, e in ipairs(g.exec) do
    local a = g.nodes[e.from]
    local want = PIN_OF[e.label] or e.label
    e.out = 1
    for k, xo in ipairs(a.xouts or {}) do if xo.name == want then e.out = k end end
  end

  -- links: from the socket declaring a variable to each socket reading it
  local owner_of = {}
  for _, n in ipairs(g.nodes) do
    for k, o in ipairs(n.outs) do if o.decl then owner_of[o.decl] = { n.id, k } end end
  end
  for _, n in ipairs(g.nodes) do
    for i, p in ipairs(n.ins) do
      local o = p.decl and owner_of[p.decl]
      if o and o[1] ~= n.id then g.links[#g.links + 1] = { from = o[1], out = o[2], to = n.id, inp = i, chip = p.chip and true or nil } end
      local sp = p.split_src                       -- a read of a split table output (p.speed): from that output
      if sp then g.links[#g.links + 1] = { from = sp.node, out = sp.out, to = n.id, inp = i, field = sp.path } end
    end
  end
  -- pending wires: floating code is its own block (a comment), so a read in it
  -- can't see a variable of another block, nor real code one of floating code.
  -- A read that resolves to nothing, of a name declared in such code (a local
  -- or local function), is drawn wired to it, dashed: it will be once the
  -- flows are wired (the text already reads it)
  do
    local function in_float(pos)
      for _, F in ipairs(g.floats or {}) do if F.pos <= pos and pos <= F.epos then return F end end
    end
    local by_name = {}
    for d, o in pairs(owner_of) do
      if (d.kind == "local" or d.kind == "function") and d.pos and d.pos > 0 then
        local l = by_name[d.name] or {}
        l[#l + 1] = { d = d, o = o, F = in_float(d.pos) }
        by_name[d.name] = l
      end
    end
    for _, n in ipairs(g.nodes) do
      for i, p in ipairs(n.ins) do
        local nm = not p.decl and not p.split_src and (p.kind == "global" and p.text or (p.uses and p.uses[1] and p.uses[1].name))
        local cands = nm and by_name[nm]
        if cands and not (p.uses and p.uses[1] and p.uses[1].decl) then
          local rpos = p.uses and p.uses[1] and p.uses[1].pos or p.pos
          local rF = rpos and in_float(rpos)
          local best
          for _, c in ipairs(cands) do
            if (rF or c.F) and c.F ~= rF and c.o[1] ~= n.id then   -- (floating on one side, not the same block)
              if not best or (c.F and not best.F) then best = c end
            end
          end
          if best then g.links[#g.links + 1] = { from = best.o[1], out = best.o[2], to = n.id, inp = i, pending = true } end
        end
      end
    end
  end
  -- what a chip's tip says: "w - parameter of run - read 4 times"
  for _, n in ipairs(g.nodes) do
    for _, p in ipairs(n.ins) do
      if p.chip then
        local d, what = p.decl, "local"
        if d.kind == "param" then
          local fr = frame_of[d.owner]
          what = "parameter of " .. ((fr and fr.title or "a function"):gsub("^local function ", ""):gsub("^function ", ""))
        elseif d.kind == "loop" then what = "loop variable"
        elseif d.kind == "function" then what = "local function" end
        local nr = #(d.refs or {})
        p.chip_tip = d.name .. "  -  " .. what .. "  -  read " .. nr .. (nr == 1 and " time" or " times")
        if not chipped(d) and d.pos and d.pos > 0 then p.chip_tip = d.name .. "  -  " .. what .. " of line " .. line_of(d.pos) .. " (far above: a chip, not a long wire)" end
      end
    end
  end

  -- warnings (n.warns: an amber outline, listed in the tooltip of its title;
  -- they don't change the layout): unused locals (their pin dimmed), a local
  -- hiding another of its name, statements that can't run (after a break or
  -- a goto, up to the next label), and (above) arguments of the wrong type
  local function warn(n, msg)
    if n.floating then return end
    n.warns = n.warns or {}
    for _, m in ipairs(n.warns) do if m == msg then return end end
    n.warns[#n.warns + 1] = msg
  end
  for _, n in ipairs(g.nodes) do
    for _, o in ipairs(n.outs) do
      local d = o.decl
      if d and d.name ~= "_" and not d.name:match("^_") then
        if (d.kind == "local" or d.kind == "function") and #d.refs == 0 then
          o.unused = true
          warn(n, "unused " .. (d.kind == "function" and "local function" or "local") .. " '" .. d.name .. "'")
        end
        local sh = d.shadows
        if sh and d.kind ~= "param" and sh.pos and sh.pos > 0 then
          warn(n, "'" .. d.name .. "' hides the " .. (sh.kind == "param" and "parameter" or sh.kind == "loop" and "loop variable" or "local")
                  .. " of line " .. line_of(sh.pos))
        end
      end
    end
  end
  do
    local seen, walk = {}, nil
    local function scan(v)                         -- the blocks in a statement (lambdas in its expressions too)
      if type(v) ~= "table" or seen[v] then return end
      seen[v] = true
      if v.stmts then return walk(v) end
      for _, x in pairs(v) do scan(x) end
    end
    walk = function(b)
      local dead
      for _, s in ipairs(b.stmts) do
        if s.tag == "Label" then dead = nil
        elseif dead then
          local id = node_of[s]
          if id then warn(g.nodes[id], "unreachable (after " .. dead .. ")") end
        end
        if s.tag == "Break" then dead = "break" elseif s.tag == "Goto" then dead = "goto " .. s.label end
        seen[s] = true
        for _, x in pairs(s) do scan(x) end
      end
    end
    walk(ast.body)
  end
  -- what the next build sizes in (the warnings are known only now, after the
  -- layout): by node key. The view builds again when they differ from the
  -- rows this one was given (rare: an edit that adds or fixes a warning).
  g.warnings, g.warn_rows = 0, {}
  local sig = {}
  for _, n in ipairs(g.nodes) do
    if n.warns then
      g.warnings = g.warnings + #n.warns
      g.warn_rows[n.wkey] = n.warns
      sig[#sig + 1] = n.wkey .. "=" .. table.concat(n.warns, "\1")
    end
  end
  table.sort(sig)
  g.warn_sig = table.concat(sig, "\2")
  local given = {}
  for k, l in pairs(wrows) do given[#given + 1] = k .. "=" .. table.concat(l, "\1") end
  table.sort(given)
  g.warn_stale = table.concat(given, "\2") ~= g.warn_sig   -- (its rows aren't the right ones: build again)
  return g
end

-- A module read by read_meta, added to an api: its classes' methods (World:query,
-- also listed by method name in `methods`, for objects of unknown class) and,
-- with an alias (local ecs = require("ecs")), its functions as alias.f.
function M.add_module(api, methods, entries, info, alias)
  local ret = info and info.ret
  for k, e in pairs(entries) do
    local mname = k:match(":([%a_][%w_]*)$")
    if mname then
      if api[k] ~= e then
        api[k] = e
        methods[mname] = methods[mname] or {}
        local dup = false
        for _, o in ipairs(methods[mname]) do dup = dup or o == e end
        if not dup then table.insert(methods[mname], e) end
      end
    elseif alias and ret and k:sub(1, #ret + 1) == ret .. "." and #k > #ret + 1 then
      api[alias .. k:sub(#ret + 1)] = e
    end
  end
end

return M

-- resolve.lua - which declaration each name refers to (Lua scoping), and
-- safe multi-span edits. Part of the nodegraph plugin (ours, not upstream lite).
--
--   local r = resolve.resolve(ast)
--   r.decls = { { name, pos, epos, kind, owner, refs = { {pos, epos}... } } }
--   r.uses  = { { name, pos, epos, decl } }       every Id (decl = nil: a global)
--   r.decl_at[pos] = decl                          by the position of its name
--   decl.assigned = true                           written again after it's declared
--   decl.shadows = decl                            the one of that name it hides (in reach before it)
--
--   local new, map = resolve.apply(src, edits)     edits = { { pos, epos, text } }
--   local ok, why = resolve.same_bindings(old_r, new_r, map, except)
--     every name (but those in except, by old position) still refers to the
--     same declaration (or stays global): renames and rewires can't capture.
local M = {}

function M.resolve(ast, probe)                     -- probe: a Function node (or "chunk"): what's visible at its end
  local decls, uses, decl_at = {}, {}, {}
  local visible
  local function collect(scope)                    -- innermost first, each name once
    visible = {}
    local seen, sc, depth = {}, scope, 0
    while sc do
      local here = {}
      for nm, d in pairs(sc) do if not seen[nm] then seen[nm] = true; here[#here + 1] = d end end
      table.sort(here, function(a, b) return a.pos > b.pos end)   -- (the latest first)
      for _, d in ipairs(here) do visible[#visible + 1] = { decl = d, depth = depth } end
      local mt = getmetatable(sc)
      sc, depth = mt and mt.__index, depth + 1
    end
  end
  local function declare(scope, name, span, kind, owner)
    local d = { name = name, pos = span[1], epos = span[2], kind = kind, owner = owner, refs = {}, shadows = scope[name] }
    decls[#decls + 1] = d
    decl_at[d.pos] = d
    scope[name] = d
    return d
  end
  local function ref(scope, name, pos, epos)
    local d = scope[name]
    uses[#uses + 1] = { name = name, pos = pos, epos = epos, decl = d }
    if d then d.refs[#d.refs + 1] = { pos, epos } end
  end
  local expr, block
  expr = function(e, scope)
    if type(e) ~= "table" then return end
    local t = e.tag
    if t == "Id" then ref(scope, e.name, e.pos, e.epos)
    elseif t == "Function" then
      local sc = setmetatable({}, { __index = scope })
      for i, p in ipairs(e.params) do declare(sc, p, e.param_pos[i], "param", e) end
      local bsc = block(e.body, sc)
      if probe == e then collect(bsc) end
    elseif t == "Index" then expr(e.obj, scope); expr(e.key, scope)
    elseif t == "Call" then expr(e.fn, scope); for _, a in ipairs(e.args) do expr(a, scope) end
    elseif t == "Invoke" then expr(e.obj, scope); for _, a in ipairs(e.args) do expr(a, scope) end
    elseif t == "Binop" then expr(e.l, scope); expr(e.r, scope)
    elseif t == "Unop" or t == "Paren" then expr(e.e, scope)
    elseif t == "Table" then for _, f in ipairs(e.fields) do expr(f.key, scope); expr(f.value, scope) end
    end
  end
  local function stmt(s, scope)
    local t = s.tag
    if t == "Local" then
      for _, e in ipairs(s.exprs) do expr(e, scope) end   -- `local x = x`: the outer x
      for i, nm in ipairs(s.names) do declare(scope, nm, s.name_pos[i], "local", s) end
    elseif t == "LocalFunction" then
      declare(scope, s.name, s.name_pos, "function", s)    -- visible in its own body
      expr(s.func, scope)
    elseif t == "Function" and s.func then              -- function a.b:c(): `a` is read
      local first = s.name:match("^[%a_][%w_]*")
      ref(scope, first, s.name_pos[1], s.name_pos[1] + #first - 1)
      if first == s.name and scope[first] then scope[first].assigned = true end   -- function f() on a local f
      expr(s.func, scope)
    elseif t == "Set" then
      for _, e in ipairs(s.exprs) do expr(e, scope) end
      for _, tg in ipairs(s.targets) do
        expr(tg, scope)
        if tg.tag == "Id" and scope[tg.name] then scope[tg.name].assigned = true end
      end
    elseif t == "CallStat" then expr(s.call, scope)
    elseif t == "Do" then block(s.body, scope)
    elseif t == "While" then expr(s.cond, scope); block(s.body, scope)
    elseif t == "Repeat" then block(s.body, scope, s.cond) -- `until` sees the body's locals
    elseif t == "If" then
      for _, c in ipairs(s.clauses) do expr(c.cond, scope); block(c.body, scope) end
      if s.orelse then block(s.orelse, scope) end
    elseif t == "Fornum" then
      expr(s.start, scope); expr(s.stop, scope); expr(s.step, scope)
      local sc = setmetatable({}, { __index = scope })
      declare(sc, s.var, s.var_pos, "loop", s)
      block(s.body, sc)
    elseif t == "Forin" then
      for _, e in ipairs(s.exprs) do expr(e, scope) end
      local sc = setmetatable({}, { __index = scope })
      for i, nm in ipairs(s.names) do declare(sc, nm, s.names_pos[i], "loop", s) end
      block(s.body, sc)
    elseif t == "Return" then for _, e in ipairs(s.exprs) do expr(e, scope) end
    end
  end
  block = function(b, scope, tail)
    local sc = setmetatable({}, { __index = scope })
    for _, s in ipairs(b.stmts) do stmt(s, sc) end
    if tail then expr(tail, sc) end
    return sc
  end
  local top = block(ast.body, {})
  if probe == "chunk" then collect(top) end
  return { decls = decls, uses = uses, decl_at = decl_at, visible = visible }
end

-- apply edits (non-overlapping spans of `src`) -> new source, and a map from
-- an old position to the new one (positions inside an edit map to its start)
function M.apply(src, edits)
  for i, e in ipairs(edits) do e.seq = e.seq or i end   -- ties: insertions first, then as given
  table.sort(edits, function(a, b)
    if a.pos ~= b.pos then return a.pos < b.pos end
    if a.epos ~= b.epos then return a.epos < b.epos end
    return a.seq < b.seq
  end)
  local out, at = {}, 1
  for _, e in ipairs(edits) do
    out[#out + 1] = src:sub(at, e.pos - 1)
    out[#out + 1] = e.text
    at = e.epos + 1
  end
  out[#out + 1] = src:sub(at)
  local function map(p)
    local d = 0
    for _, e in ipairs(edits) do
      if p > e.epos then d = d + #e.text - (e.epos - e.pos + 1)
      elseif p >= e.pos then return e.pos + d end
    end
    return p + d
  end
  return table.concat(out), map
end

function M.same_bindings(old, new, map, except)
  except = except or {}
  local new_use = {}
  for _, u in ipairs(new.uses) do new_use[u.pos] = u end
  for _, u in ipairs(old.uses) do
    if not except[u.pos] then
      local nu = new_use[map(u.pos)]
      local dp = u.decl and u.decl.pos
      local want = dp and (dp > 0 and map(dp) or -map(-dp))   -- implicit self: its function's position
      local got = nu and nu.decl and nu.decl.pos
      if not nu or want ~= got then
        return false, u
      end
    end
  end
  return true
end

-- is `s` a valid Lua name (not a keyword)?
local KW = {}
for w in ([[and break do else elseif end false for function goto if in
  local nil not or repeat return then true until while]]):gmatch("%a+") do KW[w] = true end
function M.is_name(s) return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil and not KW[s] end

return M

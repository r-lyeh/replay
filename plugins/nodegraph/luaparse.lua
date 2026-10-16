-- luaparse.lua - a Lua 5.4 parser in Lua that keeps source positions.
-- Part of the nodegraph plugin (ours, not upstream lite).
--
--   local ast, err = luaparse.parse(src)
--
-- Every node is a table { tag = "...", pos = first byte, epos = last byte,
-- line = first line, ... }, so src:sub(node.pos, node.epos) is its exact
-- text. Comments are kept in ast.comments ({ text, pos, epos, line }), for
-- annotations. On a syntax error: nil, "line N: message".
--
-- Statements: Local{names, attribs, exprs} LocalFunction{name, func}
--   Function{name, method, func} Set{targets, exprs} CallStat{call}
--   Do{body} While{cond, body} Repeat{body, cond}
--   If{clauses = {{cond, body}...}, orelse = body|nil}
--   Fornum{var, start, stop, step, body} Forin{names, exprs, body}
--   Return{exprs} Break Goto{label} Label{name}
-- Expressions: Nil True False Number{raw} String{raw} Vararg
--   Function{params, vararg, body} Table{fields = {{key|name, value}}}
--   Binop{op, l, r} Unop{op, e} Id{name} Index{obj, key|name}
--   Call{fn, args} Invoke{obj, method, args} Paren{e}
-- Blocks: Block{stmts}. The whole file: Chunk{body, comments}.

local M = {}

local KEYWORDS = {}
for w in ([[and break do else elseif end false for function goto if in
  local nil not or repeat return then true until while]]):gmatch("%a+") do KEYWORDS[w] = true end

local OPS3 = { ["..."] = true }
local OPS2 = { ["=="] = true, ["~="] = true, ["<="] = true, [">="] = true, ["//"] = true,
               ["::"] = true, ["<<"] = true, [">>"] = true, [".."] = true }

-- tokenizer --------------------------------------------------------------

local function lex(src)
  local toks, comments = {}, {}
  local i, n, line = 1, #src, 1
  local function newlines(a, b)
    local _, c = src:sub(a, b):gsub("\n", "")
    line = line + c
  end
  local function long_bracket(at)                -- [[...]] / [==[...]==] at `at`: end pos or nil
    local eq = src:match("^%[(=*)%[", at)
    if not eq then return nil end
    local close = "]" .. eq .. "]"
    local s, e = src:find(close, at + #eq + 2, true)
    if not s then error({ line = line, msg = "unfinished long string/comment" }) end
    return e
  end
  while i <= n do
    local c = src:sub(i, i)
    if c == "\n" then line = line + 1; i = i + 1
    elseif c:match("%s") then i = i + 1
    elseif src:sub(i, i + 1) == "--" then          -- comment
      local start, sline = i, line
      local e = long_bracket(i + 2)
      if not e then e = (src:find("\n", i, true) or n + 1) - 1 end
      comments[#comments + 1] = { text = src:sub(start, e), pos = start, epos = e, line = sline }
      newlines(start, e)
      i = e + 1
    elseif c:match("[%a_]") then
      local s, e = src:find("^[%w_]+", i)
      local w = src:sub(s, e)
      toks[#toks + 1] = { type = KEYWORDS[w] and "keyword" or "name", value = w, pos = s, epos = e, line = line }
      i = e + 1
    elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
      local s, e = src:find("^0[xX]%x*%.?%x*", i)
      if s then
        local s2, e2 = src:find("^[pP][%+%-]?%d+", e + 1)
        if s2 then e = e2 end
      else
        s, e = src:find("^%d*%.?%d*", i)
        local s2, e2 = src:find("^[eE][%+%-]?%d+", e + 1)
        if s2 then e = e2 end
      end
      toks[#toks + 1] = { type = "number", value = src:sub(s, e), pos = s, epos = e, line = line }
      i = e + 1
    elseif c == '"' or c == "'" then
      local j, sline = i + 1, line
      while true do
        local d = src:sub(j, j)
        if d == "" or d == "\n" then error({ line = line, msg = "unfinished string" }) end
        if d == "\\" then
          if src:sub(j + 1, j + 1) == "\n" then line = line + 1 end
          j = j + 2
        elseif d == c then break
        else j = j + 1 end
      end
      toks[#toks + 1] = { type = "string", value = src:sub(i, j), pos = i, epos = j, line = sline }
      i = j + 1
    elseif c == "[" and src:match("^%[=*%[", i) then
      local sline = line
      local e = long_bracket(i)
      toks[#toks + 1] = { type = "string", value = src:sub(i, e), pos = i, epos = e, line = sline }
      newlines(i, e)
      i = e + 1
    else
      local op = src:sub(i, i + 2)
      if not OPS3[op] then op = src:sub(i, i + 1); if not OPS2[op] then op = c end end
      if not op:match("^[%+%-%*/%%%^#&~|<>=%(%){}%[%];:,%.]") then
        error({ line = line, msg = "unexpected symbol " .. string.format("%q", op) })
      end
      toks[#toks + 1] = { type = "op", value = op, pos = i, epos = i + #op - 1, line = line }
      i = i + #op
    end
  end
  toks[#toks + 1] = { type = "eof", value = "<eof>", pos = n + 1, epos = n, line = line }
  return toks, comments
end

-- parser -------------------------------------------------------------------

local BINARY = {
  ["or"] = { 1, 1 }, ["and"] = { 2, 2 },
  ["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 }, [">="] = { 3, 3 }, ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
  ["|"] = { 4, 4 }, ["~"] = { 5, 5 }, ["&"] = { 6, 6 }, ["<<"] = { 7, 7 }, [">>"] = { 7, 7 },
  [".."] = { 9, 8 }, ["+"] = { 10, 10 }, ["-"] = { 10, 10 },
  ["*"] = { 11, 11 }, ["/"] = { 11, 11 }, ["//"] = { 11, 11 }, ["%"] = { 11, 11 },
  ["^"] = { 14, 13 },
}
local UNARY = { ["not"] = true, ["-"] = true, ["#"] = true, ["~"] = true }
local UNARY_PRIORITY = 12

function M.parse(src)
  local ok, toks, comments = pcall(lex, src)
  if not ok then
    local e = toks
    return nil, type(e) == "table" and ("line " .. e.line .. ": " .. e.msg) or tostring(e)
  end
  local p = 1
  local function peek(k) return toks[p + (k or 0)] end
  local function fail(msg, t)
    t = t or toks[p]
    error({ line = t.line, msg = msg .. " near '" .. t.value .. "'" }, 0)
  end
  local function is(v, k) local t = toks[p + (k or 0)]; return (t.type == "op" or t.type == "keyword") and t.value == v end
  local function accept(v) if is(v) then p = p + 1; return toks[p - 1] end end
  local function expect(v, what) local t = accept(v); if not t then fail("'" .. v .. "' expected" .. (what or "")) end; return t end
  local function name() local t = toks[p]; if t.type ~= "name" then fail("name expected") end; p = p + 1; return t end
  local function node(tag, first, t) t = t or {}; t.tag, t.pos, t.line = tag, first.pos, first.line; return t end
  local function finish(n) n.epos = toks[p - 1].epos; return n end

  local block, expr, funcbody

  local function block_follow(withuntil)
    local t = toks[p]
    if t.type == "eof" then return true end
    if t.type ~= "keyword" then return false end
    return t.value == "else" or t.value == "elseif" or t.value == "end" or (withuntil and t.value == "until")
  end

  local function exprlist()
    local list = { expr() }
    while accept(",") do list[#list + 1] = expr() end
    return list
  end

  local function table_cons()
    local first = expect("{")
    local n = node("Table", first, { fields = {} })
    while not is("}") do
      local f
      local t0 = toks[p]                           -- where the field starts (removing it)
      if is("[") then
        p = p + 1
        local key = expr()
        expect("]"); expect("=")
        f = { key = key, value = expr() }
      elseif peek().type == "name" and is("=", 1) then
        local k = name(); p = p + 1
        f = { name = k.value, name_pos = { k.pos, k.epos }, value = expr() }
      else
        f = { value = expr() }
      end
      f.pos = t0.pos
      n.fields[#n.fields + 1] = f
      if not accept(",") and not accept(";") then break end
    end
    expect("}")
    return finish(n)
  end

  local function call_args()
    local t = toks[p]
    if t.type == "string" then p = p + 1; return { finish(node("String", t, { raw = t.value })) } end
    if is("{") then return { table_cons() } end
    expect("(")
    local args = {}
    if not is(")") then args = exprlist() end
    expect(")")
    return args
  end

  local function primary()
    local t = toks[p]
    if t.type == "name" then p = p + 1; return finish(node("Id", t, { name = t.value })) end
    if accept("(") then
      local e = expr()
      expect(")")
      return finish(node("Paren", t, { e = e }))
    end
    fail("unexpected symbol")
  end

  local function suffixed()
    local first = toks[p]
    local e = primary()
    while true do
      if is(".") then
        p = p + 1
        local k = name()
        e = finish(node("Index", first, { obj = e, name = k.value }))
      elseif is("[") then
        p = p + 1
        local key = expr()
        expect("]")
        e = finish(node("Index", first, { obj = e, key = key }))
      elseif is(":") then
        p = p + 1
        local m = name()
        e = finish(node("Invoke", first, { obj = e, method = m.value, args = call_args() }))
      elseif is("(") or is("{") or toks[p].type == "string" then
        e = finish(node("Call", first, { fn = e, args = call_args() }))
      else
        return e
      end
    end
  end

  local function simple()
    local t = toks[p]
    if t.type == "number" then p = p + 1; return finish(node("Number", t, { raw = t.value })) end
    if t.type == "string" then p = p + 1; return finish(node("String", t, { raw = t.value })) end
    if accept("nil") then return finish(node("Nil", t)) end
    if accept("true") then return finish(node("True", t)) end
    if accept("false") then return finish(node("False", t)) end
    if accept("...") then return finish(node("Vararg", t)) end
    if is("{") then return table_cons() end
    if accept("function") then return funcbody(t) end
    return suffixed()
  end

  local function subexpr(limit)
    local first = toks[p]
    local e
    local t = toks[p]
    if (t.type == "op" or t.type == "keyword") and UNARY[t.value] then
      p = p + 1
      local operand = subexpr(UNARY_PRIORITY)
      e = finish(node("Unop", first, { op = t.value, e = operand }))
    else
      e = simple()
    end
    while true do
      local o = toks[p]
      local pr = (o.type == "op" or o.type == "keyword") and BINARY[o.value]
      if not pr or pr[1] <= limit then break end
      p = p + 1
      local r = subexpr(pr[2])
      e = finish(node("Binop", first, { op = o.value, l = e, r = r }))
    end
    return e
  end
  expr = function() return subexpr(0) end

  funcbody = function(first)                       -- after 'function' [name]: (params) body end
    local n = node("Function", first, { params = {}, param_pos = {} })
    expect("(")
    if not is(")") then
      repeat
        if accept("...") then n.vararg = true; break end
        local t = name()
        n.params[#n.params + 1] = t.value
        n.param_pos[#n.params] = { t.pos, t.epos }
      until not accept(",")
    end
    n.params_epos = expect(")").epos               -- the body starts after this
    n.body = block()
    expect("end", " (to close 'function' at line " .. first.line .. ")")
    return finish(n)
  end

  local function statement()
    local first = toks[p]
    if accept(";") then return nil end
    if accept("if") then
      local n = node("If", first, { clauses = {} })
      local cond = expr(); expect("then")
      n.clauses[1] = { cond = cond, body = block() }
      while true do
        local t = toks[p]
        if accept("elseif") then
          local c = expr(); expect("then")
          n.clauses[#n.clauses + 1] = { cond = c, body = block(), line = t.line, pos = t.pos }
        elseif accept("else") then
          n.orelse = block(); n.else_line = t.line
          expect("end", " (to close 'if' at line " .. first.line .. ")")
          break
        else
          expect("end", " (to close 'if' at line " .. first.line .. ")")
          break
        end
      end
      return finish(n)
    elseif accept("while") then
      local cond = expr(); expect("do")
      local body = block()
      expect("end", " (to close 'while' at line " .. first.line .. ")")
      return finish(node("While", first, { cond = cond, body = body }))
    elseif accept("do") then
      local body = block()
      expect("end", " (to close 'do' at line " .. first.line .. ")")
      return finish(node("Do", first, { body = body }))
    elseif accept("for") then
      local v = name()
      local vpos = { v.pos, v.epos }
      if accept("=") then
        local a = expr(); expect(",")
        local b = expr()
        local s = accept(",") and expr() or nil
        expect("do")
        local body = block()
        expect("end", " (to close 'for' at line " .. first.line .. ")")
        return finish(node("Fornum", first, { var = v.value, var_pos = vpos, start = a, stop = b, step = s, body = body }))
      end
      local names, names_pos = { v.value }, { vpos }
      while accept(",") do local t = name(); names[#names + 1] = t.value; names_pos[#names] = { t.pos, t.epos } end
      expect("in")
      local exprs = exprlist()
      expect("do")
      local body = block()
      expect("end", " (to close 'for' at line " .. first.line .. ")")
      return finish(node("Forin", first, { names = names, names_pos = names_pos, exprs = exprs, body = body }))
    elseif accept("repeat") then
      local body = block(true)
      expect("until", " (to close 'repeat' at line " .. first.line .. ")")
      return finish(node("Repeat", first, { body = body, cond = expr() }))
    elseif accept("function") then
      local nt = name()
      local nm = nt.value
      local method = false
      while accept(".") do nm = nm .. "." .. name().value end
      if accept(":") then nm = nm .. ":" .. name().value; method = true end
      local f = funcbody(first)
      f.named = true                               -- its span includes "function a.b:c"
      if method then                               -- implicit self: no text, a negative position
        table.insert(f.params, 1, "self")
        table.insert(f.param_pos, 1, { -f.pos, -f.pos })
      end
      return finish(node("Function", first, { name = nm, name_pos = { nt.pos, nt.epos }, method = method, func = f, tag2 = "stat" }))
    elseif accept("local") then
      if accept("function") then
        local nt = name()
        local f = funcbody(first)
        f.named = true
        return finish(node("LocalFunction", first, { name = nt.value, name_pos = { nt.pos, nt.epos }, func = f }))
      end
      local n = node("Local", first, { names = {}, name_pos = {}, attribs = {}, exprs = {} })
      repeat
        local t = name()
        n.names[#n.names + 1] = t.value
        n.name_pos[#n.names] = { t.pos, t.epos }
        if accept("<") then n.attribs[#n.names] = name().value; expect(">") end
      until not accept(",")
      if accept("=") then n.exprs = exprlist() end
      return finish(n)
    elseif accept("return") then
      local n = node("Return", first, { exprs = {} })
      if not block_follow(true) and not is(";") then n.exprs = exprlist() end
      accept(";")
      return finish(n)
    elseif accept("break") then
      return finish(node("Break", first))
    elseif accept("goto") then
      return finish(node("Goto", first, { label = name().value }))
    elseif accept("::") then
      local nm = name().value
      expect("::")
      return finish(node("Label", first, { name = nm }))
    end
    -- assignment or call
    local e = suffixed()
    if is("=") or is(",") then
      local targets = { e }
      while accept(",") do targets[#targets + 1] = suffixed() end
      expect("=")
      for _, t in ipairs(targets) do
        if t.tag ~= "Id" and t.tag ~= "Index" then fail("cannot assign to this", first) end
      end
      return finish(node("Set", first, { targets = targets, exprs = exprlist() }))
    end
    if e.tag ~= "Call" and e.tag ~= "Invoke" then fail("syntax error", toks[p]) end
    return finish(node("CallStat", first, { call = e }))
  end

  block = function(withuntil)
    local first = toks[p]
    local b = node("Block", first, { stmts = {} })
    while not block_follow(withuntil) do
      if is("return") then
        b.stmts[#b.stmts + 1] = statement()
        break
      end
      local s = statement()
      if s then b.stmts[#b.stmts + 1] = s end
    end
    b.epos = p > 1 and toks[p - 1].epos or 0
    return b
  end

  local ok2, res = pcall(function()
    local body = block()
    if toks[p].type ~= "eof" then fail("'<eof>' expected") end
    return body
  end)
  if not ok2 then
    return nil, type(res) == "table" and ("line " .. res.line .. ": " .. res.msg) or tostring(res)
  end
  return { tag = "Chunk", body = res, comments = comments, pos = 1, epos = #src, line = 1, src = src }
end

-- Walk every node: fn(node, parent) for expressions and statements.
function M.walk(n, fn, parent)
  if type(n) ~= "table" then return end
  if n.tag then fn(n, parent) end
  for k, v in pairs(n) do
    if k ~= "src" and k ~= "comments" and type(v) == "table" then
      if v.tag then M.walk(v, fn, n)
      else for _, x in pairs(v) do if type(x) == "table" then M.walk(x, fn, n) end end end
    end
  end
end

return M

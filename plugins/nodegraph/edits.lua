-- edits.lua - NodeGraphView: everything that changes the text (part of the
-- nodegraph plugin, ours). Each edit is a few spans of the source, applied as
-- one change (undo works) and only if the file still parses and every name
-- keeps its declaration (resolve.lua). See view.lua for the whole picture.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local DocView = require "core.docview"
local luaparse = require "plugins.nodegraph.luaparse"
local graph = require "plugins.nodegraph.graph"
local resolve = require "plugins.nodegraph.resolve"
local NodeGraphView = require "plugins.nodegraph.class"
local T = require "plugins.nodegraph.theme"
local U = require "plugins.nodegraph.util"
local rgb, C, HEAD, SOCK, GLOBAL, VALUE = T.rgb, T.C, T.HEAD, T.SOCK, T.GLOBAL, T.VALUE
local EXEC, sock_color, pin_color, kind_color, alpha = T.EXEC, T.sock_color, T.pin_color, T.kind_color, T.alpha
local line_col, names_text, names_of, pin_spans, stmt_of, name_for = U.line_col, U.names_text, U.names_of, U.pin_spans, U.stmt_of, U.name_for
local PALETTE, near_curve, frame_of, line_start, next_line, rest_blank = U.PALETTE, U.near_curve, U.frame_of, U.line_start, U.next_line, U.rest_blank
-- the text that stands for a variable that's gone (its read reads nil):
-- nil, or (nil) before . [ : ( and a string/table call; (nil) starting a
-- statement gets a ; so the line above doesn't swallow it as a call
local function nil_text(src, pos, epos)
  local after = src:match("^%s*(.)", epos + 1) or ""
  if not after:match("[%.%[:%(\"'{]") then return "nil" end
  if src:sub(1, pos - 1):match("\n[ \t]*$") or pos == 1 then return ";(nil)" end
  return "(nil)"
end
local indent_at, dedent, reindent, float_text, float_span, frame_of_node = U.indent_at, U.dedent, U.reindent, U.float_text, U.float_span, U.frame_of_node
local move_tree, movable, drag_roots, num_text, draggable, slider_value = U.move_tree, U.movable, U.drag_roots, U.num_text, U.draggable, U.slider_value
local dragged_number, hsv2rgb, rgb2hsv = U.dragged_number, U.hsv2rgb, U.rgb2hsv

function NodeGraphView:begin_edit(n, which)
  local ni = tonumber((which or ""):match("^name(%d+)$") or "")
  if ni and n.ins[ni] and n.ret_fn then            -- a return value's name: its ---@return annotation
    if self.doc:get_change_id() ~= self.change_id then self:rebuild() return end
    local info = self.g.fn_info[n.ret_fn]
    local a = info and info.returns[ni]
    local text = a and a.name or ""
    self.editing = { node = n, which = which, field = { annot = true, index = ni, fn = n.ret_fn },
                     text = text, orig = text, cur = #text + 1, change_id = self.change_id,
                     src = self.doc:get_text(1, 1, math.huge, math.huge) }
    core.redraw = true
    return
  end
  local fs = n.fields or {}
  local f = fs[which] or fs.body or fs.title
  if not f then self:flash("nothing to edit here"); return end
  if f.blocked then self:flash("not editable here: " .. f.blocked); return end
  if self.doc:get_change_id() ~= self.change_id then self:rebuild() return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local text
  if f.rename then                                 -- the names it declares, as a list
    if #f.spans == 0 and not f.vararg then self:flash("no names to rename here"); return end
    local l = {}
    for _, sp in ipairs(f.spans) do l[#l + 1] = src:sub(sp[1], sp[2]) end
    text = names_text(f, l)
  else
    text = src:sub(f.pos, f.epos)
  end
  if f.multiline then text = text:gsub("%s*\n%s*", " ") end   -- one line to edit (that span is reflowed)
  self.editing = { node = n, which = fs[which] and which or (fs.body and "body" or "title"), field = f,
                   text = text, orig = text, cur = #text + 1, src = src, change_id = self.change_id }
  core.redraw = true
end

function NodeGraphView:cancel_edit()
  local e = self.editing
  self.editing = nil
  if e then require("plugins.canvas.field").blur(e) end
  core.redraw = true
end

-- replace the whole text with `new` through the doc, as one change: only the
-- part that differs is removed and inserted (undo works, the rest stays put)
function NodeGraphView:replace_text(src, new)
  local a, n1, n2 = 1, #src, #new
  while a <= n1 and a <= n2 and src:byte(a) == new:byte(a) do a = a + 1 end
  local b1, b2 = n1, n2
  while b1 >= a and b2 >= a and src:byte(b1) == new:byte(b2) do b1, b2 = b1 - 1, b2 - 1 end
  local l1, c1 = line_col(src, a)
  local l2, c2 = line_col(src, b1 + 1)
  if b1 >= a then self.doc:remove(l1, c1, l2, c2) end
  if b2 >= a then self.doc:insert(l1, c1, new:sub(a, b2)) end
end

-- apply several edits ({pos, epos, text}) if the file still parses and every
-- name keeps its declaration; check(old_res, new_res, map) can veto more
function NodeGraphView:apply_edits(src, edits, except, check)
  local old_ast = luaparse.parse(src)
  if not old_ast then return false, "the file does not parse" end
  local old = resolve.resolve(old_ast)
  local new, map = resolve.apply(src, edits)
  local ast, err = luaparse.parse(new)
  if not ast then return false, err end
  local res = resolve.resolve(ast)
  local ok, u = resolve.same_bindings(old, res, map, except)
  if not ok then
    local l = line_col(src, u.pos)
    return false, string.format("'%s' (line %d) would refer to another variable", u.name, l)
  end
  if check then
    local ok2, why = check(old, res, map)
    if not ok2 then return false, why end
  end
  self:replace_text(src, new)
  return true
end

-- the names of a rename field as text, and back
function NodeGraphView:commit_hex(e)
  local h = e.text:match("^%s*#?(%x+)%s*$")
  if h and #h == 3 then h = h:gsub(".", "%0%0") end
  if not h or #h ~= 6 then e.err = "write it as #rrggbb"; core.redraw = true; return end
  local pk = self.picker
  self.editing = nil
  if not pk then return end
  local r, g, b = tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255
  pk.h, pk.s, pk.v = rgb2hsv(r, g, b)
  pk.h = math.min(pk.h, 0.999)
  self:picker_preview()
  local pv = self.preview
  self.preview = nil
  local edits = {}
  for _, c in ipairs(pk.comps) do
    if pv[c.pos] and pv[c.pos] ~= c.text then edits[#edits + 1] = { pos = c.pos, epos = c.epos, text = pv[c.pos] } end
  end
  if #edits > 0 and self.doc:get_change_id() == self.change_id then
    self:apply_edits(self.doc:get_text(1, 1, math.huge, math.huge), edits)
  end
end

-- a return value's name: rewrite (or add) the function's ---@return lines
function NodeGraphView:commit_annot(e)
  local name = e.text:match("^%s*(.-)%s*$")
  if name ~= "" and not resolve.is_name(name) then e.err = "not a name: " .. name; core.redraw = true; return end
  local info = self.g.fn_info[e.field.fn]
  if not info then return self:cancel_edit() end
  local src, i = e.src, e.field.index
  local edits = {}
  local a = info.returns[i]
  if a then                                        -- that line: its type stays, the name changes
    edits[1] = { pos = a.pos, epos = a.epos, text = "---@return " .. a.type .. (name ~= "" and (" " .. name) or "") }
  else                                             -- new lines, right above the function
    local lines = {}
    for k = #info.returns + 1, i do
      lines[#lines + 1] = info.indent .. "---@return any" .. ((k == i and name ~= "") and (" " .. name) or "")
    end
    local at = 1
    for _ = 2, info.line do at = (src:find("\n", at, true) or #src) + 1 end
    edits[1] = { pos = at, epos = at - 1, text = table.concat(lines, "\n") .. "\n" }
  end
  local new = resolve.apply(src, edits)
  if not luaparse.parse(new) then e.err = "that would break the file"; core.redraw = true; return end
  self.editing = nil
  self:replace_text(src, new)
  self:flash(name ~= "" and ("return value " .. i .. " is now '" .. name .. "'") or ("return value " .. i .. " has no name now"))
end

-- rename: each declared name, and every use of it
function NodeGraphView:commit_rename(e)
  local names, why = names_of(e.field, e.text)
  if not names then e.err = why; core.redraw = true; return end
  local ast = luaparse.parse(e.src)
  local res = ast and resolve.resolve(ast)
  if not res then e.err = "the file does not parse"; core.redraw = true; return end
  local function float_res(pos)                    -- floating code (a comment): resolved on its own text
    for _, F in ipairs(self.g and self.g.floats or {}) do
      if F.inner_pos and F.inner_pos <= pos and pos <= F.inner_epos then
        local src = e.src
        local shadow = src:sub(1, F.inner_pos - 1):gsub("[^\n]", " ") .. src:sub(F.inner_pos, F.inner_epos)
                       .. src:sub(F.inner_epos + 1):gsub("[^\n]", " ")
        local fast = luaparse.parse(shadow)
        return fast and resolve.resolve(fast)
      end
    end
  end
  local edits = {}
  for i, sp in ipairs(e.field.spans) do
    local d = res.decl_at[sp[1]]
    if not d then local fr = float_res(sp[1]); d = fr and fr.decl_at[sp[1]] end
    if d and d.name ~= names[i] then
      edits[#edits + 1] = { pos = d.pos, epos = d.epos, text = names[i] }
      for _, r in ipairs(d.refs) do edits[#edits + 1] = { pos = r[1], epos = r[2], text = names[i] } end
    end
  end
  if #edits == 0 then return self:cancel_edit() end
  local ok, err = self:apply_edits(e.src, edits)
  if not ok then e.err = err; core.redraw = true; return end
  self.editing = nil
end

-- sockets: inputs on a node's left edge, outputs on its right (graph.lua)
function NodeGraphView:uses_in(spans)
  local except = {}
  for _, u in ipairs(self.res and self.res.uses or {}) do
    for _, sp in ipairs(spans) do if u.pos >= sp.pos and u.pos <= sp.epos then except[u.pos] = true end end
  end
  return except
end

-- rewire: the uses behind input socket `pin` read the variable `d` instead
-- what was wired into `pin` when it's replaced or cut (UE style: the old node
-- stays): an expression node, or a function written there, kept as floating
-- code where it was drawn. Returns the edit inserting it, or nil.
function NodeGraphView:float_feeder(pin, src)
  local g = self.g
  if not g or not (pin.kind == "expr" or pin.kind == "lambda") then return nil end
  local owner, feeder
  for _, n in ipairs(g.nodes) do for _, q in ipairs(n.ins) do if q == pin then owner = n end end end
  for _, l in ipairs(g.links) do
    if l.expr and g.nodes[l.to] == owner and owner.ins[l.inp] == pin then feeder = g.nodes[l.from] end
  end
  local text, x0, y0
  if feeder and feeder.fields and feeder.fields.body then
    local f = feeder.fields.body
    text = src:sub(f.pos, f.epos)
    if feeder.vexpr and (feeder.vexpr.tag == "Call" or feeder.vexpr.tag == "Invoke") then text = "(" .. text .. ")" end   -- a value
    x0, y0 = feeder.x, feeder.y
    local function reach(n)                        -- (placed by its top-left: its own inputs' nodes)
      for _, c in ipairs(n.kids or {}) do
        if c.kind == "expr" and c.parent == n then x0, y0 = math.min(x0, c.x), math.min(y0, c.y); reach(c) end
      end
    end
    reach(feeder)
  elseif pin.kind == "lambda" and pin.pos then
    for _, fr in ipairs(g.frames) do
      if fr.func and fr.func.pos == pin.pos then text, x0, y0 = src:sub(pin.pos, pin.epos), fr.x, fr.y end
    end
  end
  if not text then return nil end
  local fr = owner and frame_of_node(owner)
  local pos, indent, pre
  pos, indent, pre, fr = self:float_place(fr, src)
  if not pos then return nil end
  local hx, hy = fr and fr.head.x or 0, fr and fr.head.y or 0
  local untag                                      -- a get node's --@expr ... get= tag goes with it
  local t = feeder and feeder.getter and feeder.edit and feeder.edit.tag
  if t and t.inline then
    local b = t.epos
    while src:sub(b + 1, b + 1) == " " do b = b + 1 end
    untag = { pos = t.pos, epos = b, text = "" }
  elseif t and t.line then
    local ls = 1
    for _ = 2, t.line do ls = (src:find("\n", ls, true) or #src) + 1 end
    local le = src:find("\n", ls, true) or #src
    untag = { pos = ls, epos = le, text = "" }
  end
  return { pos = pos, epos = pos - 1, text = pre .. float_text(dedent(text), x0 - hx, y0 - hy, indent) }, untag
end

-- autoconversion on wiring: a value of a type its pin doesn't take, both
-- certain (the pin's ---@param / class field type; the value's type), is
-- wrapped: a number into a string -> tostring(x); a string into a number ->
-- tonumber(x); anything into a boolean -> x ~= nil. Else: as it is.
local function convert(text, have, want)
  if not (have and want) or have == want or have == "nil" or have == "any" then return text end
  if (want == "number" and have == "integer") or (want == "integer" and have == "number") then return text end
  local simple = text:match("^[%w_%.]+$") or text:match("^[%w_%.:]+%b()$")
  if want == "string" and (have == "number" or have == "integer" or have == "boolean") then return "tostring(" .. text .. ")" end
  if (want == "number" or want == "integer") and have == "string" then return "tonumber(" .. text .. ")" end
  if want == "boolean" then return (simple and text or "(" .. text .. ")") .. " ~= nil" end
  return text
end
NodeGraphView.convert = convert
function NodeGraphView:rewire(pin, d, path)       -- path: a field of d (p.speed: a split table output)
  if not (pin and d) then return end
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  if not path and pin.decl and pin.decl.pos == d.pos and pin.kind ~= "expr" then return self:flash("it reads " .. d.name .. " already") end
  if path and pin.split_src and pin.split_src.path == path then return self:flash("it reads " .. path .. " already") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local spans = pin_spans(pin)
  local edits, except = {}, self:uses_in(spans)
  local text = path or convert(d.name, d.vtype or nil, pin.want_type)   -- (a type it doesn't take: converted)
  for _, u in ipairs(spans) do
    edits[#edits + 1] = { pos = u.pos, epos = u.epos, text = text }
  end
  local kept, untag = self:float_feeder(pin, src) -- (what fed it stays, floating)
  if kept then edits[#edits + 1] = kept end
  if untag then edits[#edits + 1] = untag end
  local dpos = d.pos
  local floating = false                           -- floating code is a comment: nothing resolves in it
  for _, F in ipairs(self.g.floats or {}) do
    for _, u in ipairs(spans) do if u.pos >= F.pos and u.pos <= F.epos then floating = true end end
  end
  local ok, err = self:apply_edits(src, edits, except, not floating and function(_, res, map)
    local want = dpos > 0 and map(dpos) or -map(-dpos)   -- implicit self: its function's position
    local by = {}
    for _, u in ipairs(res.uses) do by[u.pos] = u end
    local off = text:find("%f[%w_]" .. d.name:gsub("%p", "%%%0") .. "%f[^%w_]") - 1   -- (converted: the name inside tostring(...))
    for _, u in ipairs(spans) do
      local nu = by[map(u.pos) + off]
      if not (nu and nu.decl and nu.decl.pos == want) then
        return false, string.format("%s is not visible from line %d", d.name, (line_col(src, u.pos)))
      end
    end
    return true
  end)
  if not ok then return self:flash(err) end
  self:flash(string.format("%s now reads %s", pin.name, (text ~= d.name and not path) and (text .. " (converted: " .. pin.want_type .. " expected)") or text))
end

-- a socket dragged from `from` and dropped on `to` (a socket) or `node`
-- share an expression with another pin: it becomes a local, declared right
-- above the first statement using it, and both pins read that local.
--   local v = 2 + 3      <- new
--   ... v ...            <- where the expression was
--   ... v ...            <- the pin it was wired to
function NodeGraphView:share(en, pin, pnode)
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local s1, s2 = stmt_of(en), stmt_of(pnode)
  if pnode == en then return self:flash("an expression can't feed itself") end
  local own = en.slot and s1 and s1.ins[en.slot.pin_index]
  if own == pin then return self:flash("it feeds that pin already") end
  local t1 = s1 and s1.title or ""
  if s1 and s1.clause and s1.clause > 1 then t1 = "elseif" end
  if t1 == "while" or t1 == "until" or t1 == "elseif" then
    return self:flash("a " .. t1 .. " condition is evaluated again and again: share a variable instead")
  end
  local f = en.fields and en.fields.body
  if not f then return end
  if f.blocked then return self:flash("it holds a function: can't move it") end
  -- the statement it goes above: the earlier of the two
  local first = s1
  if s2 and s2.pos and s2.pos < s1.pos then first = s2 end
  if not (first and first.edit and first.edit.kind == "node" and first.edit.insert_line) then
    return self:flash("that statement doesn't start its line: share it in the text")
  end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local expr = src:sub(f.pos, f.epos)
  local used = {}                                  -- a free name
  for _, u in ipairs(self.res.uses) do used[u.name] = true end
  for _, d in ipairs(self.res.decls) do used[d.name] = true end
  local base, k = name_for(expr), 1
  local name = base
  while used[name] do k = k + 1; name = base .. k end
  local line = first.edit.top_line or first.line   -- above its tags too
  local at = 1
  for _ = 2, line do at = (src:find("\n", at, true) or #src) + 1 end
  local head = first.edit.indent .. "local " .. name .. " = "
  local spans = pin_spans(pin)
  local edits = { { pos = at, epos = at - 1, text = head .. expr .. "\n" },
                  { pos = f.pos, epos = f.epos, text = name } }
  for _, sp in ipairs(spans) do edits[#edits + 1] = { pos = sp.pos, epos = sp.epos, text = name } end
  local kept, untag = self:float_feeder(pin, src) -- (what fed that pin stays, floating)
  if kept then edits[#edits + 1] = kept end
  if untag then edits[#edits + 1] = untag end
  local all = { { pos = f.pos, epos = f.epos } }
  for _, sp in ipairs(spans) do all[#all + 1] = sp end
  local except = self:uses_in(all)
  local moved = {}                                 -- the expression's own reads, and where they go
  for _, u in ipairs(self.res.uses) do
    if u.pos >= f.pos and u.pos <= f.epos then moved[#moved + 1] = u end
  end
  local ok, err = self:apply_edits(src, edits, except, function(_, res, map)
    local by = {}
    for _, u in ipairs(res.uses) do by[u.pos] = u end
    local decl = res.decl_at[at + #first.edit.indent + #"local "]
    if not decl then return false, "the new local didn't land" end
    for _, sp in ipairs({ { pos = f.pos }, table.unpack(spans) }) do   -- both pins read it
      local nu = by[map(sp.pos)]
      if not (nu and nu.decl == decl) then
        return false, string.format("%s wouldn't be visible from line %d", name, (line_col(src, sp.pos)))
      end
    end
    for _, u in ipairs(moved) do                   -- its reads still mean the same variables
      local nu = by[at + #head + (u.pos - f.pos)]
      local want = u.decl and (u.decl.pos > 0 and map(u.decl.pos) or -map(-u.decl.pos))
      if not nu or (nu.decl and nu.decl.pos) ~= want then
        return false, string.format("%s isn't visible above line %d", u.name, first.line)
      end
    end
    return true
  end)
  if not ok then return self:flash("can't share it: " .. tostring(err)) end
  self:flash(string.format("shared as local %s (line %d)", name, line))
end

-- the tag that keeps a getter wired into a statement's pin drawn as a get
-- node: `--@expr slot=N get=name` above the statement (inline when it shares
-- its line). nil for pins of nested expression nodes (they read the name
-- plainly: a chip or a wire).
-- the edit writing a pin's --@expr tag (slot=its path in its statement):
-- change(t) sets / clears its values; nothing left but slot: the tag goes
function NodeGraphView:expr_tag_edit(pin, change, src, owner)   -- owner: its node (else found)
  local idx
  if not owner then
    for _, n in ipairs(self.g.nodes) do for i, q in ipairs(n.ins) do if q == pin then owner, idx = n, i end end end
  end
  if not owner then return nil end
  local key = pin and tostring(pin.opath or idx)
  local st = owner
  if owner.kind == "expr" then                     -- a pin of an expression node: its path (2.3)
    if not (owner.edit and owner.edit.kind == "expr") then return nil end
    key = pin and (tostring(owner.edit.slot) .. "." .. (pin.opath or idx)) or tostring(owner.edit.slot)   -- (no pin: the node's own)
    while st and st.kind == "expr" do st = st.parent end
  end
  if not key then return nil end
  local e = st and (st.node_edit or st.edit)        -- (a statement in floating code: its own place there)
  if not (e and e.kind == "node") then return nil end
  local old = e.expr_tags and e.expr_tags[key]
  local t = { kind = "expr", keys = { "slot" }, vals = { slot = key } }
  if old then for _, k in ipairs(old.keys) do if k ~= "slot" then t.keys[#t.keys + 1] = k; t.vals[k] = old.vals[k] end end end
  change(t)
  local keys = {}
  for _, k in ipairs(t.keys) do if t.vals[k] ~= nil then keys[#keys + 1] = k end end
  t.keys = keys
  local text = #keys > 1 and graph.tag_text(t) or nil
  if old and old.inline then return { pos = old.pos, epos = old.epos, text = text and ("--[[" .. text:sub(3) .. "]]") or "" } end
  if old then
    local ls = line_start(src, old.pos or 1)
    if not old.pos then                            -- (a line tag: by its line number)
      ls = 1
      for _ = 2, old.line do ls = (src:find("\n", ls, true) or #src) + 1 end
    end
    local le = (src:find("\n", ls, true) or (#src + 1)) - 1
    if not text then return { pos = ls, epos = le + 1, text = "" } end   -- (nothing left: the line goes)
    return { pos = ls, epos = le, text = src:match("^[ \t]*", ls) .. text }
  end
  if not text then return nil end
  if e.inline then return { pos = e.insert_pos, epos = e.insert_pos - 1, text = "--[[" .. text:sub(3) .. "]] " } end
  local at = 1
  for _ = 2, e.insert_line do at = (src:find("\n", at, true) or #src) + 1 end
  return { pos = at, epos = at - 1, text = e.indent .. text .. "\n" }
end

function NodeGraphView:getter_tag(pin, name, src)
  return self:expr_tag_edit(pin, function(t)
    if not t.vals.get then t.keys[#t.keys + 1] = "get" end
    t.vals.get = name
  end, src)
end
-- a floating expression wired to a pin: it moves into that pin (the text
-- feeding it is replaced) and its floating block goes
function NodeGraphView:place_expr(F, pin)
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local spans = pin_spans(pin)
  if #spans ~= 1 then return self:flash("that input reads its variable " .. #spans .. " times: wire it to one place") end
  local text = table.concat(dedent(src:sub(F.inner_pos, F.inner_epos)), " ")
  if F.unwrapped then text = table.concat(dedent(src:sub(F.expr.pos, F.expr.epos)), " ") end   -- (f(x)) -> f(x)
  -- parentheses only where operators or indexing touch it (x * v, v.y, -v)
  local sp0 = spans[1]
  local nxt = src:match("^%s*(.)", sp0.epos + 1) or ""
  local before = src:sub(1, sp0.pos - 1):match("(%S%S?)%s*$") or ""
  local prev = before:sub(-1)
  local assign = prev == "=" and not before:match("[=<>~]=$")
  local tight = nxt:match("[%.%[:%(\"'{%+%-%*/%%%^<>=~]") or (prev:match("[%+%-%*/%%%^<>=~#%.]") and not assign)
                or src:sub(1, sp0.pos - 1):match("%f[%w]not%s*$") or src:sub(1, sp0.pos - 1):match("%f[%w]and%s*$")
                or src:sub(1, sp0.pos - 1):match("%f[%w]or%s*$")
  if tight and not text:match("^[%w_%.]+$") and not text:match("^[%w_%.:]+%b()$") then text = "(" .. text .. ")" end
  local root = F.root and self.by_id[F.root]
  local conv = (F.expr and F.expr.tag == "Id") and text   -- (a type it doesn't take: converted; a getter stays a getter)
               or convert(text, root and root.outs[1] and root.outs[1].vtype, pin.want_type)
  if conv ~= text then text = tight and ("(" .. conv .. ")") or conv end
  local a, b = float_span(src, F)
  local sp = spans[1]
  local getter = F.expr and F.expr.tag == "Id" and F.expr.name   -- (a getter: the name must be visible there)
  local local_named = false
  for _, d in ipairs(self.res.decls) do if getter and d.name == getter and d.pos > 0 then local_named = true end end
  local pe = { { pos = sp.pos, epos = sp.epos, text = text }, { pos = a, epos = b, text = "" } }
  local kept, untag = self:float_feeder(pin, src) -- (what fed the pin stays, floating)
  if kept then pe[#pe + 1] = kept end
  if untag and not getter then pe[#pe + 1] = untag end   -- (a getter rewrites that tag instead)
  if getter then                                   -- a getter stays a get node there: --@expr slot=N get=name
    local tagged = self:getter_tag(pin, getter, src)
    if tagged then pe[#pe + 1] = tagged end
  end
  local ok, err = self:apply_edits(src, pe,
                                   self:uses_in({ sp }), local_named and function(_, res, map)
    for _, u in ipairs(res.uses) do
      if u.pos == map(sp.pos) and u.name == getter then
        if u.decl then return true end
        return false, getter .. " is not visible there"
      end
    end
    return true
  end or nil)
  if not ok then return self:flash("can't wire it there: " .. tostring(err)) end
  self:flash("wired: " .. pin.name .. " = " .. text)
end

function NodeGraphView:connect(from, to, node, x, y)
  if from.exec then return self:connect_exec(from, to, node, x or self.mx, y or self.my) end
  local function float_root(sk)                    -- a floating expression's result
    local n = sk and sk.node
    local F = n and n.edit and n.edit.kind == "float" and n.edit.float
    return F and F.root == n.id and sk.sock.value and F
  end
  local function float_fn(sk_or_node, nd)           -- a floating lambda: any of its header's pins, or its frame
    local n = nd or (sk_or_node and sk_or_node.node)
    if not n and x and y and self.g then             -- (dropped on a frame: its header)
      local ox, oy = self:origin()
      local fr = self:frame_at((x - ox) / self.zoom, (y - oy) / self.zoom)
      n = fr and fr.head
    end
    local F = n and n.kind == "function" and n.edit and n.edit.kind == "float" and n.edit.float
    return F and F.root == n.id and F
  end
  local Ff, Ft = float_root(from), float_root(to)
  if not Ft and from.side == "in" and not from.exec and (not to or to.side == "out") then Ft = float_fn(to, not to and node) end
  if Ff and to and to.side == "in" and not to.exec then return self:place_expr(Ff, to.sock) end
  if Ft and from.side == "in" then return self:place_expr(Ft, from.sock) end
  if to and to.exec then return self:flash("a value goes into a value pin (round), not a flow pin") end
  if from.sock.field_path and to and to.side == "in" then   -- a split table output (p.speed) -> a pin: it reads p.speed
    return self:rewire(to.sock, from.sock.base_decl, from.sock.field_path)
  end
  if to and to.sock.field_path and from.side == "in" then
    return self:rewire(from.sock, to.sock.base_decl, to.sock.field_path)
  end
  if from.side == "out" and from.sock.value and not to and not node and x and self:members_base(from) then
    return self:members_drop_menu(from, x, y)      -- a getter's result (get ecs) dropped on the background: its members
  end
  if from.sock.value then                          -- an expression's result -> a pin: share it
    if to and to.side == "in" then return self:share(from.node, to.sock, to.node) end
    return self:flash("drop it on an input (left side) of a node")
  end
  if to and to.sock.value then
    if from.side == "in" then return self:share(to.node, from.sock, from.node) end
    return self:flash("an expression's result goes into an input")
  end
  if from.side == "in" and not to and not node and x and not from.sock.action then
    return self:value_drop_menu(from, x, y)        -- an input's wire dropped on the background: what can feed it
  end
  if from.side == "in" then
    local d = to and to.side == "out" and to.sock.decl
    if not d and not to and node and node.outs[1] then d = node.outs[1].decl end
    if not d then return self:flash("drop it on an output (right side) of a node") end
    return self:rewire(from.sock, d)
  end
  if to and to.side == "in" then return self:rewire(to.sock, from.sock.decl) end
  if not to and node and node.kind == "return" and node.ast and node.ast.tag == "Return" and from.sock.decl then
    return self:add_return_value(node, from.sock.decl, from.sock.vtype)   -- a variable onto a return: one more value
  end
  if from.side == "out" and not to and not node and x and (from.sock.decl or from.sock.field_path) then
    return self:members_drop_menu(from, x, y)      -- a variable's wire dropped on the background: its members
  end
  self:flash("drop it on an input (left side) of a node")
end

-- a variable's output wire dropped on the background (ecs, p.color): what
-- can be read from it there. Its module's functions (a require: ecs.world),
-- its class's methods and fields (---@type, or what made it: ecs.world()'s
-- ---@return), the fields of the table it was made with, and the members the
-- file already reads from it (ecs.foo, p:bar()). The one picked floats there,
-- reading the variable (so it's wired).
-- what a dropped output stands for: its text (ecs, p.color) and the variable
-- it reads (nil: unknown, a global); a getter's result (get ecs, cfg.size) too
function NodeGraphView:members_base(from)
  local sock = from.sock
  local d = sock.decl or sock.base_decl
  if d then return sock.field_path and (d.name .. "." .. sock.field_path) or d.name, d end
  local e = sock.value and from.node and (from.node.get_e or from.node.vexpr)
  while e and e.tag == "Paren" do e = e.e end
  local function path(x)
    if x.tag == "Id" then return x.name, x end
    if x.tag == "Index" and x.name then local b, id = path(x.obj); return b and (b .. "." .. x.name), id end
  end
  local base, id = nil, nil
  if e then base, id = path(e) end
  if not base then return nil end
  local u                                          -- the variable it reads: resolved, else (floating) by name, above it
  for _, uu in ipairs(self.res and self.res.uses or {}) do if uu.pos == id.pos then u = uu end end
  local dd = u and u.decl
  if not dd then
    for _, c in ipairs(self.res and self.res.decls or {}) do
      if c.name == id.name and c.pos < id.pos then dd = c end
    end
  end
  return base, dd and base == dd.name and dd or nil
end

function NodeGraphView:members_drop_menu(from, x, y)
  local sock = from.sock
  local base, d = self:members_base(from)
  local fpath = sock.field_path
  local g, api = self.g, self.api or {}
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local ox, oy = self:origin()
  local gx, gy = (x - ox) / self.zoom, (y - oy) / self.zoom
  local items, seen = { { header = true, text = "Members of " .. base } }, {}
  local function add(text, t, hint)
    if seen[t.name] then return end                 -- (once a member: the first, the best known, wins)
    seen[t.name] = true
    items[#items + 1] = { text = text, hint = hint, fn = function() self:add_node(t, gx, gy) end }
  end
  local function call(sep, nm, e)                  -- base.f(args) / base:m(args): its value when it gives one
    local args, shown = {}, {}
    for i, p in ipairs(e and e.params or {}) do
      if not (i == 1 and p == "self" and (sep == ":" or e.method)) then
        shown[#shown + 1] = p
        if p ~= "..." then args[#args + 1] = self:class_default(e.types and e.types[p], g) end
      end
    end
    local txt = base .. sep .. nm .. "(" .. table.concat(args, ", ") .. ")"
    local value = e and (e.rets or e.ret_class)
    add(base .. sep .. nm .. "(" .. table.concat(shown, ", ") .. ")", { name = base .. sep .. nm, text = value and ("(" .. txt .. ")") or txt, raw = true },
        value and "value" or "call")
  end
  local function field(nm, ty)
    add(base .. "." .. nm, { name = base .. "." .. nm, text = "(" .. base .. "." .. nm .. ")", raw = true }, ty)
  end
  local function from_api(prefix, sep_override)    -- api keys prefix.f / prefix:m
    local list = {}
    for k, e in pairs(api) do
      local sep, nm = k:sub(#prefix + 1, #prefix + 1), k:sub(#prefix + 2)
      if k:sub(1, #prefix) == prefix and (sep == "." or sep == ":") and nm:match("^[%a_][%w_]*$") then
        list[#list + 1] = { sep_override or sep, nm, e }
      end
    end
    table.sort(list, function(a, b) return a[2] < b[2] end)
    for _, it in ipairs(list) do call(it[1], it[2], it[3]) end
  end
  -- what it is: a module (its name in the api), a class, a table, a string
  from_api(base)
  local cls
  local o = not fpath and d and d.owner
  if o and o.tag == "Local" then
    local ln = 1
    for _ in src:sub(1, o.pos):gmatch("\n") do ln = ln + 1 end
    local i
    for k, sp in ipairs(o.name_pos) do if sp[1] == d.pos then i = k end end
    local lines = {}
    for l in (src .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
    cls = lines[ln - 1] and lines[ln - 1]:match("^%s*%-%-%-@type%s+([%a_][%w_%.]*)")
    local ex = i and o.exprs[i]
    while ex and ex.tag == "Paren" do ex = ex.e end
    if ex and ex.tag == "Table" then
      for _, f in ipairs(ex.fields) do
        if f.name then
          local v = f.value
          if v.tag == "Function" then
            local e = { params = v.params, method = false }
            call(".", f.name, e)
          else field(f.name) end
        end
      end
    elseif ex and (ex.tag == "Call" or ex.tag == "Invoke") and not cls then
      local function path(e) if e.tag == "Id" then return e.name end
        if e.tag == "Index" and e.name then local b = path(e.obj); return b and (b .. "." .. e.name) end end
      local fe = ex.tag == "Call" and api[path(ex.fn) or ""]
      cls = fe and fe.ret_class
    end
  end
  if cls then
    from_api(cls, ":")
    for _, f in ipairs(g and g.classes[cls] and g.classes[cls].fields or {}) do field(f.name, f.type) end
  end
  if sock.vtype == "string" then from_api("string", ":") end
  -- what the file already reads from it: base.name, base:name(
  local pat = "%f[%w_]" .. base:gsub("%p", "%%%0") .. "([%.:])([%a_][%w_]*)%s*(%(?)"
  for sep, nm, paren in src:gmatch(pat) do
    if sep == ":" or paren == "(" then call(sep, nm, nil) else field(nm) end
  end
  if #items == 1 then items[2] = { text = "(nothing known in " .. base .. ")", dim = true } end
  self:open_menu(x, y, items, { search = true })
end

-- a value input's wire dropped on the background: the Add menu's values that
-- fit it (its type, when known: a condition wants a boolean...), and the
-- variables visible there; the one picked floats there and is wired in.
local RESULT = {                                   -- what each template gives (nil: a statement, not offered)
  ["Math expression"] = "number", ["Comparison"] = "boolean", ["And / or"] = "any", ["Not"] = "boolean",
  ["Length (#)"] = "integer", ["Concat (..)"] = "string", ["Number"] = "number", ["String"] = "string",
  ["True"] = "boolean", ["False"] = "boolean", ["Nil"] = "nil", ["Table"] = "table", ["List"] = "table",
  ["Vector"] = "table", ["Function (lambda)"] = "function", ["Call"] = "any",
  ["tostring(v)"] = "string", ["tonumber(s)"] = "number", ["type(v)"] = "string", ["select(n, ...)"] = "any",
  ["setmetatable(t, mt)"] = "table", ["getmetatable(t)"] = "table", ["rawget(t, k)"] = "any", ["next(t)"] = "any",
  ["pcall(f)"] = "boolean", ["load(s)"] = "function", ["string.len(s)"] = "integer", ["string.find(s, p)"] = "integer",
  ["table.concat(t, sep)"] = "string", ["table.remove(t)"] = "any", ["table.unpack(t)"] = "any",
}
local function result_of(t)
  if RESULT[t.name] then return RESULT[t.name] end
  if t.name:match("^math%.") then return "number" end
  if t.name:match("^string%.") then return "string" end
end
local function fits(want, have)
  if not want or have == "any" then return true end
  if want == have then return true end
  if (want == "number" and have == "integer") or (want == "integer" and have == "number") then return true end
  return false
end
NodeGraphView.result_of, NodeGraphView.fits = result_of, fits
function NodeGraphView:value_drop_menu(from, x, y)
  local pin, owner = from.sock, from.node
  local want = pin.name == "condition" and "boolean" or pin.vtype
  if pin.ftype and ({ number = 1, integer = 1, boolean = 1, string = 1, table = 1 })[pin.ftype] then want = want or pin.ftype end
  local ox, oy = self:origin()
  local gx, gy = (x - ox) / self.zoom, (y - oy) / self.zoom
  local pinpos = pin.pos
  local items = { { header = true, text = "Feed " .. pin.name .. (want and (" (" .. want .. ")") or "") } }
  local function after_add(at, before)
    if not at then return end
    self:rebuild()
    local F
    for _, f in ipairs(self.g.floats or {}) do if f.pos == at then F = f end end
    local delta = #self.doc:get_text(1, 1, math.huge, math.huge) - before
    local pos = (at <= pinpos) and (pinpos + delta) or pinpos
    local np
    for _, n in ipairs(self.g.nodes) do for _, q in ipairs(n.ins) do if q.pos == pos and not q.action then np = q end end end
    if F and np then self:place_expr(F, np) else self:flash("added; wire its result into " .. pin.name) end
  end
  local function add_item(text, t)
    items[#items + 1] = { text = text, fn = function()
      local before = #self.doc:get_text(1, 1, math.huge, math.huge)
      after_add(self:add_node(t, gx, gy), before)
    end }
  end
  for _, grp in ipairs(self.TEMPLATES) do
    local function walk(list)
      for _, t in ipairs(list) do
        if t.group then walk(t.items)
        else
          local r = result_of(t)
          if r and r ~= "nil" and fits(want, r) then
            local txt = t.text
            if txt:match("^[%w_%.:]+%b()$") then txt = "(" .. txt .. ")" end   -- (a call: its value, not a call statement)
            add_item(t.name, { name = t.name, text = txt })
          end
        end
      end
    end
    if grp.group == "Values" or grp.group == "Library" then walk(grp.items) end
  end
  local fr = owner and frame_of_node(owner)        -- the variables visible at that pin: getters
  local vis = self.ast and resolve.resolve(self.ast, fr and fr.func or "chunk").visible or {}
  for _, v in ipairs(vis) do
    local d = v.decl
    if d.pos > 0 and d.name ~= "_" and d.pos < (pinpos or math.huge) then
      add_item("get " .. d.name, { name = "get " .. d.name, text = d.name, raw = true })
    end
  end
  if #items == 1 then items[2] = { text = "(nothing fits " .. pin.name .. ")", dim = true } end
  self:open_menu(x, y, items, { search = true })
end

-- one more value for a function's returns: d (a variable; nil: nil) in this
-- return, at the end of what the function returns (the most any of its
-- returns has, or its ---@return lines); every other return of the function
-- gets a placeholder there (0, false, "" after d's type; nil where it had
-- fewer), so all its paths return the same values. The new value is named after d in a ---@return line above
-- the function (which names the pins). Returns ending in a call / ... (they
-- return a list) stay as they are.
local PLACEHOLDER = { integer = "0", number = "0", boolean = "false", string = '""', table = "{}" }
local ANNOT_TYPE = { integer = "integer", number = "number", boolean = "boolean", string = "string", table = "table", ["function"] = "function" }
function NodeGraphView:add_return_value(rn, d, vtype)
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local s = rn.ast
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local group = {}                                 -- the function's returns
  for _, n in ipairs(self.g.nodes) do
    local st = n.ast
    if n.kind == "return" and st and st.tag == "Return" and n.ret_fn == rn.ret_fn then group[#group + 1] = st end
  end
  local info = rn.ret_fn and self.g.fn_info[rn.ret_fn]
  local A = info and #info.returns or 0            -- the new value's place: after all of them
  for _, st in ipairs(group) do A = math.max(A, #st.exprs) end
  A = A + 1
  local function append(st, list)
    local text = table.concat(list, ", ")
    if #st.exprs > 0 then
      local p = st.exprs[#st.exprs].epos
      return { pos = p + 1, epos = p, text = ", " .. text }
    end
    local p = st.pos + #"return" - 1               -- a bare return: after the keyword
    return { pos = p + 1, epos = p, text = " " .. text }
  end
  local value = d and d.name or "nil"
  local own = {}
  for _ = #s.exprs + 1, A - 1 do own[#own + 1] = "nil" end
  own[#own + 1] = value
  local first = append(s, own)
  local edits, padded = { first }, 0
  for _, st in ipairs(group) do                    -- the function's other returns
    if st ~= s and #st.exprs < A then
      local last = st.exprs[#st.exprs]
      local list_end = last and (last.tag == "Call" or last.tag == "Invoke" or last.tag == "Vararg")
      if not list_end then
        local list = {}
        for k = #st.exprs + 1, A do list[#list + 1] = k == A and (PLACEHOLDER[vtype] or "nil") or "nil" end
        edits[#edits + 1] = append(st, list)
        padded = padded + 1
      end
    end
  end
  if info and d then                               -- its name: a ---@return line
    local a = info.returns[A]
    if a and not a.name then
      edits[#edits + 1] = { pos = a.pos, epos = a.epos, text = "---@return " .. a.type .. " " .. d.name }
    elseif not a then
      local lines = {}
      for k = #info.returns + 1, A do
        lines[#lines + 1] = info.indent .. "---@return " .. (k == A and (ANNOT_TYPE[vtype] or "any") .. " " .. d.name or "any")
      end
      local at = 1
      for _ = 2, info.line do at = (src:find("\n", at, true) or #src) + 1 end
      edits[#edits + 1] = { pos = at, epos = at - 1, text = table.concat(lines, "\n") .. "\n" }
    end
  end
  local dpos = d and d.pos
  local ok, err = self:apply_edits(src, edits, nil, d and function(_, res, map)
    local want = dpos > 0 and map(dpos) or -map(-dpos)
    local b = map(first.pos)                       -- (just past the inserted text)
    for _, u in ipairs(res.uses) do
      if u.name == d.name and u.pos >= b - #first.text and u.pos < b then
        if u.decl and u.decl.pos == want then return true end
        break
      end
    end
    return false, string.format("%s is not visible from that return", d.name)
  end)
  if not ok then return self:flash(err) end
  self:flash(string.format("returns %s too%s", value, padded > 0 and string.format(" (%d other return%s padded)", padded, padded > 1 and "s" or "") or ""))
end

-- write the edit: only its span changes, and only if the whole file still parses
function NodeGraphView:commit_edit()
  local e = self.editing
  if not e then return end
  if e.text == e.orig then return self:cancel_edit() end
  if self.doc:get_change_id() ~= e.change_id then
    self:cancel_edit()
    return self:flash("the text changed meanwhile: edit again")
  end
  if e.field.hex then return self:commit_hex(e) end
  if e.field.note then return self:commit_note(e) end
  if e.field.rename then return self:commit_rename(e) end
  if e.which:match("^key%d+$") and not resolve.is_name(e.text) then e.err = "not a name: " .. e.text; core.redraw = true; return end
  if e.field.annot then return self:commit_annot(e) end
  local new = e.src:sub(1, e.field.pos - 1) .. e.text .. e.src:sub(e.field.epos + 1)
  local ok, err = luaparse.parse(new)
  if not ok then e.err = err; core.redraw = true; return end
  local l1, c1 = line_col(e.src, e.field.pos)
  local l2, c2 = line_col(e.src, e.field.epos + 1)
  self.editing = nil
  self.doc:remove(l1, c1, l2, c2)
  self.doc:insert(l1, c1, e.text)
end

function NodeGraphView:on_text_input(text)
  local m = self.menu
  if m and m.search and not self.editing then      -- the menu's search box
    m.search = m.search .. text
    self:refilter_menu()
    return
  end
  local e = self.editing
  if not e then return end
  e.text = e.text:sub(1, e.cur - 1) .. text .. e.text:sub(e.cur)
  e.cur, e.err = e.cur + #text, nil
  core.redraw = true
end

function NodeGraphView:disconnect(uses, what, pin)
  if not uses or #uses == 0 then return end
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local edits, except = {}, self:uses_in(uses)
  for _, u in ipairs(uses) do
    local text = nil_text(src, u.pos, u.epos)
    edits[#edits + 1] = { pos = u.pos, epos = u.epos, text = text }
  end
  local kept, untag
  if pin then kept, untag = self:float_feeder(pin, src) end   -- (an expression node cut off: it stays, floating)
  if kept then edits[#edits + 1] = kept end
  if untag then edits[#edits + 1] = untag end
  local ok, err = self:apply_edits(src, edits, except)
  if not ok then
    return self:flash(err and err:match("expected") and ("can't disconnect " .. what .. ": it is assigned there") or ("can't disconnect: " .. tostring(err)))
  end
  self:flash("disconnected " .. what)
end

function NodeGraphView:disconnect_socket(sk)
  if sk.side == "in" then
    local k = sk.sock.kind
    if k == "lambda" and sk.sock.pos then             -- a function written there: it floats, the pin reads nil
      return self:disconnect({ { pos = sk.sock.pos, epos = sk.sock.epos } }, sk.sock.name, sk.sock)
    end
    if k == "literal" or k == "lambda" then return self:flash("nothing is wired to " .. sk.sock.name) end
    return self:disconnect(pin_spans(sk.sock), sk.sock.name, sk.sock)
  end
  local uses = {}                                  -- an output: every input wired to it
  for _, l in ipairs(self.g.links) do
    if self.by_id[l.from] == sk.node and l.out == sk.i then
      for _, u in ipairs(pin_spans(self.by_id[l.to].ins[l.inp])) do uses[#uses + 1] = u end
    end
  end
  if #uses == 0 then return self:flash(sk.sock.name .. " has no wires") end
  self:disconnect(uses, sk.sock.name)
end

function NodeGraphView:color_of(n)
  local t = n and (n.frame and n.frame.tag or (n.edit and n.edit.kind == "float" and n.edit.float or (n.edit and n.edit.tag)))
  return t and t.vals and t.vals.color or false
end
function NodeGraphView:set_color(nodes, c)        -- c: "#rrggbb", or nil: none
  local list = {}
  for _, m in ipairs(nodes) do
    if m.edit then list[#list + 1] = { m, function(tag) self.set_val(tag, "color", c or nil) end } end
  end
  if #list == 0 then return self:flash("this node can't keep a colour") end
  self:write_tags(list)
end

function NodeGraphView:cycle_color(n, clear)
  if not (n and n.edit) then return self:flash("this node can't keep a colour") end
  local t = n.frame and n.frame.tag or n.edit.tag
  local cur = t and t.vals.color
  local i = 1
  for k, c in ipairs(PALETTE) do if c == cur then i = k end end
  local nxt = not clear and PALETTE[i % #PALETTE + 1] or nil
  self:write_tag(n, function(tag) self.set_val(tag, "color", nxt or nil) end)
end

-- the popup menu ---------------------------------------------------------

-- the Add menu (RMB on the canvas): Lua's statements and expressions, in
-- groups; $names become free names. Bare expressions float on their own
-- (wire their result into a pin), statements float until a flow is wired in.
local function T(name, text, tags) return { name = name, text = text, tags = tags } end   -- (tags: "a;b": the search's aliases)
NodeGraphView.TEMPLATES = {
  { group = "Flow", items = {
    T("If", "if true then\nend", "branch;condition;when;else"),                 -- (then / else outs; an if wired into an else is an elseif)
    T("While", "while false do\nend", "loop"),
    T("Repeat / until", "repeat\nuntil true", "loop;do while"),
    T("For (range)", "for $i = 1, 10 do\nend", "loop;count;numeric"),
    T("For each (pairs)", "for $key, $value in pairs(nil) do\nend", "loop;iterate;foreach;table"),   -- (nil: an empty pin, wire a table in)
    T("For each (ipairs)", "for $i, $value in ipairs(nil) do\nend", "loop;iterate;foreach;array;list"),
    T("Do block", "do\nend"),
    T("Break", "break"),
    T("Label", "::$label::"),                       -- (Goto: one per label here, below)
    T("Return", "return"),
  } },
  { group = "Variables", items = {
    T("Local", "local $value = 0"),
    T("Local constant", "local $value <const> = 0"),
    T("Two locals", "local $a, $b = 0, 0"),
    T("Function", "local function $func()\nend", "def;method;procedure;subroutine"),
    T("Load (code)", 'local $chunk, $err = load("return 0")', "loadstring;eval;compile;dostring;chunk;string to code"),   -- (a string of Lua -> a function, or nil and why)
  } },
  { group = "Values", items = {
    T("Math expression", "1 + 2 * 3"),
    T("Comparison", "1 < 2"),
    T("And / or", "true and false"),
    T("Not", "not false"),
    T("Length (#)", "#{}", "count;size;len"),
    T("Concat (..)", '"a" .. "b"', "join;append;string"),
    T("Number", "0"),
    T("String", '"text"'),
    T("True", "true"),
    T("False", "false"),
    T("Nil", "nil"),
    T("Table", "{ value = 0 }"),
    T("List", "{ 1, 2, 3 }"),
    T("Vector", "{ x = 0, y = 0 }"),
    T("Function (lambda)", "function() end"),
    T("Call", 'print("hello")'),
  } },
  { group = "Library", items = {
    { group = "base", items = {
      T("print(...)", 'print("hello")', "log;debug;output;trace"), T("tostring(v)", "tostring(0)", "convert;str;to string"), T("tonumber(s)", 'tonumber("0")', "convert;parse;to number;int"),
      T("type(v)", "type(nil)"), T("assert(v, msg)", 'assert(true, "message")'), T("error(msg)", 'error("message")'),
      T("pcall(f)", "pcall(function() end)"), T("select(n, ...)", "select(1, 0)"),
      T("setmetatable(t, mt)", "setmetatable({}, {})"), T("getmetatable(t)", "getmetatable({})"),
      T("rawget(t, k)", 'rawget({}, "key")'), T("next(t)", "next({})"), T("load(s)", 'load("return 0")', "loadstring;eval;compile;dostring"),
    } },
    { group = "math", items = {
      T("math.floor(x)", "math.floor(0)"), T("math.ceil(x)", "math.ceil(0)"), T("math.abs(x)", "math.abs(0)"),
      T("math.min(a, b)", "math.min(0, 1)"), T("math.max(a, b)", "math.max(0, 1)"), T("math.sqrt(x)", "math.sqrt(2)"),
      T("math.random(a, b)", "math.random(1, 6)", "rand;dice;rnd"), T("math.sin(x)", "math.sin(0)"), T("math.cos(x)", "math.cos(0)"),
      T("math.atan(y, x)", "math.atan(0, 1)"), T("math.pi", "math.pi"), T("math.huge", "math.huge"),
    } },
    { group = "string", items = {
      T("string.format(f, ...)", 'string.format("%d", 0)'), T("string.sub(s, i, j)", 'string.sub("text", 1, 2)'),
      T("string.len(s)", 'string.len("text")'), T("string.upper(s)", 'string.upper("text")'),
      T("string.lower(s)", 'string.lower("TEXT")'), T("string.rep(s, n)", 'string.rep("ab", 3)'),
      T("string.find(s, p)", 'string.find("text", "x")'), T("string.gsub(s, p, r)", 'string.gsub("text", "t", "T")'),
    } },
    { group = "table", items = {
      T("table.insert(t, v)", "table.insert({}, 0)"), T("table.remove(t)", "table.remove({})"),
      T("table.concat(t, sep)", 'table.concat({}, ", ")'), T("table.sort(t)", "table.sort({})"),
      T("table.unpack(t)", "table.unpack({})"),
    } },
  } },
}

-- the Add menu's items: the groups above, then this file's types (---@class)
-- and functions
function NodeGraphView:add_menu(gx, gy, after)   -- after(at, t): once it's added (a flow wire dropped)
  local function add(t)
    local at = self:add_node(t, gx, gy)
    if at and after then after(at, t) end
  end
  local function build(list)
    local items = {}
    for _, t in ipairs(list) do
      if t.group then items[#items + 1] = { text = t.group, sub = build(t.items) }
      else items[#items + 1] = { text = t.name, tags = t.tags, fn = function() add(t) end } end
    end
    return items
  end
  local top = build(self.TEMPLATES)
  local g = self.g
  local types = {}                                 -- a new local of each class, with its fields
  for _, cls in ipairs(g and g.class_list or {}) do
    if cls.world then                              -- a world class (/classes/<name>): a node with that component
      local t = { name = cls.name, text = 'w:spawn("/objects/$' .. cls.name .. '", { ' .. cls.name .. ' = {} })' }
      types[#types + 1] = { text = cls.name .. "  (/classes)", fn = function() add(t) end }
    else
      local parts = {}
      for _, f in ipairs(cls.fields) do
        if not f.optional then parts[#parts + 1] = f.name .. " = " .. self:class_default(f.type, g) end
      end
      local var = cls.name:gsub("^.*%.", ""):gsub("^%u", string.lower)
      if not var:match("^[%a_][%w_]*$") then var = "value" end
      local body = #parts > 0 and ("{ " .. table.concat(parts, ", ") .. " }") or "{}"
      local t = { name = cls.name, text = "---@type " .. cls.name .. "\nlocal $" .. var .. " = " .. body }
      types[#types + 1] = { text = cls.name, fn = function() add(t) end }
    end
  end
  if #types == 0 then types[1] = { text = '(none: write ---@class Name in the text, or w:spawn("/classes/name", { ... }))', dim = true } end
  local fns = {}                                   -- a call of each function: "call f(a, b)"
  local list = {}
  for _, f in ipairs(g and g.functions or {}) do list[#list + 1] = f end
  for _, F in ipairs(g and g.floats or {}) do       -- (functions still floating: callable once wired in)
    if F.inner_pos then
      local src = self.doc:get_text(1, 1, math.huge, math.huge)
      local fast = luaparse.parse(src:sub(F.inner_pos, F.inner_epos))
      for _, st in ipairs(fast and fast.body.stmts or {}) do
        if (st.tag == "LocalFunction" or st.tag == "Function") and st.func then
          local ps = {}
          for i, p in ipairs(st.func.params) do if not (st.method and i == 1) then ps[#ps + 1] = p end end
          if st.func.vararg then ps[#ps + 1] = "..." end
          list[#list + 1] = { name = st.name, params = ps, types = {}, floating = true }
        end
      end
    end
  end
  for _, f in ipairs(list) do
    local args, shown = {}, {}
    for _, p in ipairs(f.params) do
      shown[#shown + 1] = p
      if p ~= "..." then args[#args + 1] = self:class_default(f.types[p], g) end
    end
    local t = { name = f.name, text = f.name .. "(" .. table.concat(args, ", ") .. ")" }
    fns[#fns + 1] = { text = "call " .. f.name .. "(" .. table.concat(shown, ", ") .. ")", fn = function() add(t) end,
                      hint = f.floating and "floating: wire it in to run" or nil }
  end
  if #fns == 0 then fns[1] = { text = "(none defined in this file)", dim = true } end
  -- "get ball": a getter of each variable visible where it lands (the end of
  -- the function under the mouse, else the file's top level): the
  -- function's own first, then the ones around it
  local gets = {}
  local fr = g and self:frame_at(gx, gy)
  local vis = self.ast and resolve.resolve(self.ast, fr and fr.func or "chunk").visible or {}
  for _, v in ipairs(vis) do
    local d = v.decl
    if d.pos > 0 and d.name ~= "_" then
      local t = { name = "get " .. d.name, text = d.name, raw = true }
      gets[#gets + 1] = { text = "get " .. d.name, fn = function() add(t) end, bonus = -0.5 * v.depth,
                          hint = v.depth == 0 and (fr and "here" or "top level") or nil }
    end
  end
  if #gets == 0 then gets[1] = { text = "(no variables here)", dim = true } end
  -- "set ball": an assignment of each of them (its value pin: nil, wire one
  -- in); "new local" first
  local sets = { { text = "new local", fn = function() add(T("Local", "local $value = 0")) end, bonus = 1 } }
  for _, v in ipairs(vis) do
    local d = v.decl
    if d.pos > 0 and d.name ~= "_" and d.name ~= "self" then
      local t = { name = "set " .. d.name, text = d.name .. " = nil", raw = true }
      sets[#sets + 1] = { text = "set " .. d.name, fn = function() add(t) end, bonus = -0.5 * v.depth,
                          hint = v.depth == 0 and (fr and "here" or "top level") or nil }
    end
  end
  -- "goto again": one per label of the function under the mouse (Flow)
  for _, n in ipairs(g and g.nodes or {}) do
    if n.ast and n.ast.tag == "Label" and frame_of(n) == fr then
      local t = { name = "goto " .. n.ast.name, text = "goto " .. n.ast.name, raw = true }
      for _, it in ipairs(top) do
        if it.text == "Flow" then it.sub[#it.sub + 1] = { text = "Goto " .. n.ast.name, fn = function() add(t) end } end
      end
    end
  end
  table.insert(top, 4, { text = "Types", sub = types })
  table.insert(top, 5, { text = "Functions", sub = fns })
  table.insert(top, 6, { text = "Get", sub = gets })
  table.insert(top, 7, { text = "Set", sub = sets })
  return top
end

-- the frame (function) an element sits in, or nil (top level)
function NodeGraphView:drop_place(gx, gy, src)
  local g = self.g
  local fr                                          -- the innermost frame under the point
  for _, f in ipairs(g.frames) do                  -- (inner frames come first)
    if gx >= f.x and gx <= f.x + f.w and gy >= f.y and gy <= f.y + f.h then fr = f; break end
  end
  local best, bs
  for _, n in ipairs(g.nodes) do
    local e = n.edit
    local ok = e and e.insert_line and (e.kind == "node" or (e.kind == "frame" and n.frame == fr))
    if ok and e.kind == "node" and frame_of(n) ~= fr then ok = false end
    if ok then
      local s
      if fr then                                   -- left to right
        local dx = gx - (n.x + n.w)
        if dx >= -10 then s = dx + 2 * math.abs(gy - (n.y + n.h / 2)) end
      elseif n.y <= gy then                        -- top to bottom
        s = gy - n.y + 0.1 * math.abs(gx - n.x)
      end
      if s and (not bs or s < bs) then best, bs = n, s end
    end
  end
  if not best then
    if fr then return nil end
    return 1, ""                                   -- top of the file
  end
  if best.edit.kind == "frame" then return best.edit.insert_line, best.edit.indent end
  if best.kind == "return" then                    -- nothing can follow a return: go before it
    return best.edit.top_line or best.line, best.edit.indent
  end
  local _, eol = src:find("^[^\n]*", best.epos + 1)
  if not src:sub(best.epos + 1, eol):match("^%s*$") and not src:sub(best.epos + 1, eol):match("^%s*%-%-") then
    return nil, nil, "the statement there doesn't end its line"
  end
  local l = 1
  for _ in src:sub(1, best.epos):gmatch("\n") do l = l + 1 end
  return l + 1, best.edit.indent
end

-- text helpers for moving code around
function NodeGraphView:frame_at(gx, gy)
  for _, f in ipairs(self.g.frames) do
    if gx >= f.x and gx <= f.x + f.w and gy >= f.y and gy <= f.y + f.h then return f end
  end
end
-- where floating code of a frame goes: right before its function's "end"
-- (the top level: the end of the file)
-- (a function on one line has no room: the one around it, else the top level;
-- the 4th result is the frame it went into, its position's origin)
function NodeGraphView:float_place(fr, src)
  if not fr then
    return #src + 1, "", (#src > 0 and src:sub(-1) ~= "\n") and "\n" or "", nil
  end
  local endp = fr.func.epos - 2                    -- "end"
  local ls = line_start(src, endp)
  if not src:sub(ls, endp - 1):match("^%s*$") then
    local up = fr.parent
    while up and not up.head do up = up.parent end
    return self:float_place(up, src)
  end
  return ls, src:match("^[ \t]*", ls) .. "  ", "", fr
end

-- the Add menu: the statement floats where you clicked, out of the flow;
-- wire a flow out into it to make it run
function NodeGraphView:add_node(t, gx, gy)
  if not self.g then return end
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local fr = self:frame_at(gx, gy)
  local pos, indent, pre
  pos, indent, pre, fr = self:float_place(fr, src)
  if not pos then return self:flash("that function is on one line: add it in the text") end
  local used = {}                                  -- free names: not used anywhere in the file
  for _, u in ipairs(self.res.uses) do used[u.name] = true end
  for _, d in ipairs(self.res.decls) do used[d.name] = true end
  local text = t.raw and t.text or t.text:gsub("%$([%a_][%w_]*)", function(base)
    local nm, k = base, 1
    while used[nm] do k = k + 1; nm = base .. k end
    used[nm] = true
    return nm
  end)
  local rv = result_of(t)                          -- a call that gives a value (tostring(v)...): added as that value,
  if rv and t.name ~= "Call" and text:match("^[%w_%.:]+%b()$") then text = "(" .. text .. ")" end   -- a call node with its result (not a statement)
  local hx, hy = fr and fr.head.x or 0, fr and fr.head.y or 0
  local block = pre .. float_text(dedent(text), gx - hx, gy - hy, indent)
  local ok, err = self:apply_edits(src, { { pos = pos, epos = pos - 1, text = block } })
  if not ok then return self:flash("can't add " .. t.name:lower() .. ": " .. tostring(err)) end
  local stmt = luaparse.parse(text) ~= nil         -- a statement (else an expression)
  self:flash("added " .. t.name:lower() .. (stmt and ": wire a flow out (white) into it to run it"
                                                   or ": wire its result into an input"))
  return pos + #pre + #indent                      -- (where its --[[@float header starts, in the new text)
end

-- the lines of floating code, as they'd be removed (whole lines when alone on them)
function NodeGraphView:out_place(A, k, src)
  local name = A.xouts[k] and A.xouts[k].name
  if A.kind == "start" then                        -- the file's start: before its first statement
    for _, n in ipairs(self.g.nodes) do
      if n.edit and n.edit.kind == "node" and n.edit.top_line and n.block == self.g.top_block then
        local p = 1
        for _ = 2, n.edit.top_line do p = (src:find("\n", p, true) or #src) + 1 end
        return p, "", ""
      end
    end
    return #src + 1, "", (#src > 0 and src:sub(-1) ~= "\n") and "\n" or ""
  end
  if A.kind == "function" then                     -- a header: first in its body
    local e = A.edit
    if not (e and e.insert_line) then return nil, "that function is on one line" end
    local p = 1
    for _ = 2, e.insert_line do p = (src:find("\n", p, true) or #src) + 1 end
    return p, e.indent, ""
  end
  local s = A.ast
  if not s then return nil, "that node isn't a statement" end
  local function after(p, why)                     -- the line after the one p is on
    if not rest_blank(src, p) then return nil, why or "something follows it on its line" end
    local nl = next_line(src, p)
    if not nl then return #src + 1, indent_at(src, s.pos), "\n" end
    return nl
  end
  local ind = indent_at(src, s.pos)
  if name == "" or name == "done" then             -- after the statement
    local p, why = after(s.epos + 1)
    if not p then return nil, why end
    return p, ind, (p == #src + 1 and src:sub(-1) ~= "\n") and "\n" or ""
  elseif name == "then" then
    local cl = s.clauses[A.clause or 1]
    local tp = src:find("%f[%w]then%f[%W]", cl.cond.epos + 1)
    local p, why = tp and after(tp + 4, "its body is on the same line")
    if not p then return nil, why or "no then" end
    return p, ind .. "  ", ""
  elseif name == "else" then
    local ci = A.clause or 1
    if ci < #s.clauses then                        -- it leads to an elseif: code goes before it,
      local le, lend, why, kw = self:elseif_span(s, ci + 1, src)   -- so that becomes else <code> if ... end
      if not le then return nil, why end
      -- small edits, so every name keeps its place: "elseif" -> "if", the
      -- lines below one level in, an "end" for the new if
      local more = { { pos = le, epos = kw + 5, text = ind .. "  if" } }
      local p = next_line(src, le)
      while p and p < lend do
        if src:match("^[^\n]*", p):match("%S") then more[#more + 1] = { pos = p, epos = p - 1, text = "  " } end
        p = next_line(src, p)
      end
      more[#more + 1] = { pos = lend, epos = lend - 1, text = ind .. "  end\n" }
      return le, ind .. "  ", ind .. "else\n", more
    end
    if s.orelse and s.orelse.stmts[1] then
      local first = s.orelse.stmts[1]
      local ls = line_start(src, first.pos)
      if not src:sub(ls, first.pos - 1):match("^%s*$") then return nil, "its else is on one line" end
      return ls, src:match("^[ \t]*", ls), ""
    end
    local endp = s.epos - 2
    local ls = line_start(src, endp)
    if not src:sub(ls, endp - 1):match("^%s*$") then return nil, "its end isn't on a line of its own" end
    if s.orelse then return ls, ind .. "  ", "" end  -- an empty else: right before end
    return ls, ind .. "  ", ind .. "else\n"        -- no else yet: add one
  elseif name == "body" then
    local from = s.tag == "Repeat" and s.pos + 5 or (s.tag == "While" and s.cond.epos)
                 or (s.tag == "Fornum" and (s.step or s.stop).epos) or (s.exprs and s.exprs[#s.exprs].epos)
    local dp = s.tag == "Repeat" and s.pos + 5 or src:find("%f[%w]do%f[%W]", from + 1)
    local p, why = dp and after(dp + (s.tag == "Repeat" and 1 or 2), "its body is on the same line")
    if not p then return nil, why or "no do" end
    return p, ind .. "  ", ""
  end
  return nil, "it can't lead there"
end

-- a flow wire dropped: floating code joins the flow (moved into place)
function NodeGraphView:connect_exec(from, to, node, x, y)
  if not to and node and from.side == "out" and node.xin and node ~= from.node then   -- on a node: its flow in
    to = { node = node, side = "in", i = 1, sock = node.xin, exec = true }
  end
  if not to and not node and x then return self:exec_drop_menu(from, x, y) end   -- on the background: what to add
  if not to or not to.exec or to.side == from.side then return self:flash("drop it on a flow pin (white) of the other side") end
  local o, i = from, to
  if from.side == "in" then o, i = to, from end
  local A, k, B = o.node, o.i, i.node
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local F, pos, indent, pre
  local Bf = B.edit and B.edit.kind == "float" and B.edit.float
  local Af = A.edit and A.edit.kind == "float" and A.edit.float
  local replace
  if Bf and Bf.first == B.id and not Af then       -- flow -> floating code: it runs there
    F = Bf
    if self:merge_elseif(A, k, F, src) then return end
    pos, indent, pre, replace = self:out_place(A, k, src)
    if not pos then return self:flash("can't connect: " .. tostring(indent)) end
  elseif Af and not Bf and B.edit and B.edit.kind == "node" and B.edit.top_line then   -- floating code -> flow: before it
    F = Af
    pos = 1
    for _ = 2, B.edit.top_line do pos = (src:find("\n", pos, true) or #src) + 1 end
    indent, pre = B.edit.indent, ""
  elseif Bf and Af then
    return self:flash("connect floating code to the flow first")
  else                                             -- both in the flow: B (and what follows it) moves here
    return self:move_into_flow(A, k, B, src)
  end
  local code = dedent(src:sub(F.inner_pos, F.inner_epos))
  if #code == 0 then return self:flash("that floating code is empty") end
  local a, b = float_span(src, F)
  local edits
  if pos == a or pos == b + 1 then                 -- it goes right where the float is (an empty file's start, the
    edits = { { pos = a, epos = b, text = pre .. reindent(code, indent) } }   -- end of a function): unfloated in place
  elseif pos > a and pos <= b then return self:flash("can't connect it to itself")
  else edits = { { pos = pos, epos = pos - 1, text = pre .. reindent(code, indent) }, { pos = a, epos = b, text = "" } } end
  for _, e in ipairs(replace or {}) do edits[#edits + 1] = e end   -- (out_place's other edits)
  local ok, err = self:apply_edits(src, edits)
  if not ok then return self:flash("can't connect: " .. tostring(err)) end
  self:flash("connected: it runs now")
end

-- an elseif is drawn as an if wired into the else before it. In the text:
-- the lines from clause i's `elseif` up to the if's `end` (start positions)
function NodeGraphView:elseif_span(s, i, src)
  local cl = s.clauses[i]
  local kw, p = nil, s.pos
  while true do
    local a = src:find("%f[%w]elseif%f[%W]", p)
    if not a or a > cl.cond.pos then break end
    kw, p = a, a + 6
  end
  if not kw then return nil, nil, "no elseif" end
  local le = line_start(src, kw)
  if not src:sub(le, kw - 1):match("^%s*$") then return nil, nil, "its elseif doesn't start a line" end
  local endp = s.epos - 2
  local lend = line_start(src, endp)
  if not src:sub(lend, endp - 1):match("^%s*$") then return nil, nil, "its end isn't on a line of its own" end
  return le, lend, nil, kw
end

-- those lines as an if of their own: "elseif c then ... end" -> "if c then ... end" (dedented lines)
function NodeGraphView:elseif_as_if(src, le, lend)
  local lines = dedent(src:sub(le, lend - 1))
  lines[1] = lines[1]:gsub("^elseif", "if", 1)
  lines[#lines + 1] = "end"
  return lines
end

-- a floating `if` wired into the last else (an empty one, or none): it
-- joins the chain as an elseif (true if it did)
function NodeGraphView:merge_elseif(A, k, F, src)
  local s = A.ast
  if not (s and s.tag == "If" and A.xouts[k] and A.xouts[k].name == "else") then return false end
  if (A.clause or 1) ~= #s.clauses or (s.orelse and s.orelse.stmts[1]) then return false end
  local text = table.concat(dedent(src:sub(F.inner_pos, F.inner_epos)), "\n")
  local ast = luaparse.parse(text)
  local st = ast and ast.body.stmts[1]
  if not (st and #ast.body.stmts == 1 and st.tag == "If") then return false end
  if text:sub(1, st.pos - 1):match("%S") or text:sub(st.epos + 1):match("%S") then return false end
  local head = text:sub(st.pos, st.epos - 3):gsub("%s+$", "")
  local lines = dedent("elseif" .. head:sub(3))
  local ind = indent_at(src, s.pos)
  local endp = s.epos - 2
  local lend = line_start(src, endp)
  if not src:sub(lend, endp - 1):match("^%s*$") then return false end
  local from = lend
  if s.orelse then                                 -- an empty else: it goes
    local ep, p = nil, s.clauses[#s.clauses].cond.epos
    while true do
      local a = src:find("%f[%w]else%f[%W]", p)
      if not a or a >= endp then break end
      ep, p = a, a + 4
    end
    if not ep then return false end
    from = line_start(src, ep)
    if not (src:sub(from, ep - 1):match("^%s*$") and rest_blank(src, ep + 4)) then return false end
  end
  local a, b = float_span(src, F)
  local ok, err = self:apply_edits(src, { { pos = from, epos = lend - 1, text = reindent(lines, ind) },
                                          { pos = a, epos = b, text = "" } })
  if not ok then self:flash("can't connect: " .. tostring(err)); return true end
  self:flash("connected: it's an elseif now")
  return true
end

-- a flow wire dropped on a flow in that's taken (UE: the old wire goes): the
-- statement and the ones after it in its block move to run after A's out k
-- (refused when a name would read another variable, or something left
-- behind still reads what they declare)
function NodeGraphView:move_into_flow(A, k, B, src)
  if not (B.edit and B.edit.kind == "node" and B.edit.top_line and B.block) then
    return self:flash("that node can't be moved there")
  end
  local stmts = B.block.stmts
  local last = stmts[#stmts]
  if not rest_blank(src, last.epos + 1) then return self:flash("the last of them shares its line: do it in the text") end
  local a = 1
  for _ = 2, B.edit.top_line do a = (src:find("\n", a, true) or #src) + 1 end
  local b = (src:find("\n", last.epos + 1, true)) or #src
  local pos, indent, pre, more = self:out_place(A, k, src)
  if not pos then return self:flash("can't connect: " .. tostring(indent)) end
  if pos >= a and pos <= b + 1 then return self:flash("can't wire it into itself") end
  for _, e in ipairs(more or {}) do
    if e.pos <= b and e.epos >= a then return self:flash("can't wire it into itself") end
  end
  local edits = { { pos = pos, epos = pos - 1, text = pre .. reindent(dedent(src:sub(a, b)), indent) }, { pos = a, epos = b, text = "" } }
  for _, e in ipairs(more or {}) do edits[#edits + 1] = e end
  local ok, err = self:apply_edits(src, edits, self:uses_in({ { pos = a, epos = b } }))
  if not ok then
    local nm = err and err:match("^'([^']+)'")
    return self:flash(nm and ("can't: " .. nm .. " would read another variable, or is still read where it was") or ("can't connect: " .. tostring(err)))
  end
  self:flash("rewired: it runs there now")
end

-- a flow wire dropped on the background: the Add menu there; what's picked
-- is added and wired to the pin the wire came from
function NodeGraphView:exec_drop_menu(from, x, y)
  local ox, oy = self:origin()
  local gx, gy = (x - ox) / self.zoom, (y - oy) / self.zoom
  local A, k, side = from.node, from.i, from.side
  local akey = { kind = A.kind, title = A.title, line = A.line, clause = A.clause }
  local function after(at)
    self:rebuild()                                 -- (now: the new code is in the graph)
    local F
    for _, f in ipairs(self.g.floats or {}) do if f.pos == at then F = f end end
    if not (F and F.first) then return self:flash("added (no flow pins: wire its result into an input)") end
    local A2                                       -- the node the wire came from (its line didn't move:
    for _, n in ipairs(self.g.nodes) do            -- new code goes at the end of its function / the file)
      if n.kind == akey.kind and n.title == akey.title and n.line == akey.line and n.clause == akey.clause
         and not (n.edit and n.edit.kind == "float" and n.edit.float == F) then A2 = n; break end
    end
    if not A2 then return end
    local Fn = self.g.nodes[F.first]
    if side == "out" then
      self:connect_exec({ node = A2, side = "out", i = k, sock = A2.xouts[k], exec = true },
                        { node = Fn, side = "in", i = 1, sock = Fn.xin, exec = true })
    else
      self:connect_exec({ node = Fn, side = "out", i = 1, sock = Fn.xouts[1], exec = true },
                        { node = A2, side = "in", i = 1, sock = A2.xin, exec = true })
    end
  end
  local items = { { header = true, text = side == "out" and "Add and run it here" or "Add and run it before" } }
  for _, it in ipairs(self:add_menu(gx, gy, after)) do items[#items + 1] = it end
  self:open_menu(x, y, items, { search = true })
end

-- take a statement out of the flow: it and the ones after it in its block
-- become floating code (they stop running), where they were in the graph
function NodeGraphView:disconnect_exec(B)
  if B and B.clause and B.clause > 1 and B.ast then   -- an elseif: it floats as an if of its own
    if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
    local src = self.doc:get_text(1, 1, math.huge, math.huge)
    local le, lend, why = self:elseif_span(B.ast, B.clause, src)
    if not le then return self:flash("can't take it out: " .. why) end
    local fr = B.parent
    while fr and not fr.head do fr = fr.parent end
    local pos, indent, pre
    pos, indent, pre, fr = self:float_place(fr, src)
    if not pos then return self:flash("that function is on one line: do it in the text") end
    local hx, hy = fr and fr.head.x or 0, fr and fr.head.y or 0
    local block = pre .. float_text(self:elseif_as_if(src, le, lend), B.x - hx, B.y - hy + 30, indent)
    local ok, err = self:apply_edits(src, { { pos = le, epos = lend - 1, text = "" }, { pos = pos, epos = pos - 1, text = block } },
                                     self:uses_in({ { pos = le, epos = lend - 1 } }))
    if not ok then return self:flash("can't take it out: " .. tostring(err)) end
    return self:flash("taken out of the flow: it floats as an if (and doesn't run)")
  end
  if not (B and B.edit and B.edit.kind == "node" and B.edit.top_line and B.block) then
    return self:flash("only statements in the flow can be taken out")
  end
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local stmts = B.block.stmts
  local last = stmts[#stmts]
  if not rest_blank(src, last.epos + 1) then return self:flash("the last of them shares its line: do it in the text") end
  local a = 1
  for _ = 2, B.edit.top_line do a = (src:find("\n", a, true) or #src) + 1 end
  local b = (src:find("\n", last.epos + 1, true)) or #src
  local fr = B.parent
  while fr and not fr.head do fr = fr.parent end
  local pos, indent, pre
  pos, indent, pre, fr = self:float_place(fr, src)
  if not pos then return self:flash("that function is on one line: do it in the text") end
  local hx, hy = fr and fr.head.x or 0, fr and fr.head.y or 0
  local block = pre .. float_text(dedent(src:sub(a, b)), B.x - hx, B.y - hy + 30, indent)
  local edits = { { pos = a, epos = b, text = "" }, { pos = pos, epos = pos - 1, text = block } }
  local ok, err = self:apply_edits(src, edits, self:uses_in({ { pos = a, epos = b } }))
  if not ok then
    local nm = err and err:match("^'([^']+)'")
    return self:flash(nm and ("can't: " .. nm .. " is still read further on") or ("can't take it out: " .. tostring(err)))
  end
  self:flash("taken out of the flow: it floats (and doesn't run)")
end

function NodeGraphView:delete_float(F)
  if self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local a, b = float_span(src, F)
  local ok, err = self:apply_edits(src, { { pos = a, epos = b, text = "" } })
  if not ok then return self:flash("can't delete it: " .. tostring(err)) end
  self:flash("deleted the floating code")
end

-- the flow wire under (x, y)
function NodeGraphView:delete_node(n) return self:delete_nodes({ n }) end

-- copy / cut / paste: the selected nodes' code, found in the source, goes
-- to the clipboard as text (statements whole, floating code, expressions);
-- paste drops clipboard Lua under the mouse as floating code; cut = copy +
-- delete (UE style, like the Delete key)
function NodeGraphView:selection_text(list)
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local pieces, seen = {}, {}
  for _, n in ipairs(list) do
    local e = n.edit
    local a, b
    if e and e.kind == "float" then
      if not seen[e.float] then seen[e.float] = true; a, b = e.float.inner_pos, e.float.inner_epos end
    elseif n.kind == "expr" and n.fields and n.fields.body then
      a, b = n.fields.body.pos, n.fields.body.epos
      if n.class then pieces[#pieces + 1] = { a = a, b = b, cast = n.class }; a = nil end   -- (a typed table keeps its type: --[[@as Paddle]])
    elseif n.pos and n.epos and n.kind ~= "start" then a, b = n.pos, n.epos  -- a statement (a function: whole)
    end
    if a and b and b >= a then pieces[#pieces + 1] = { a = a, b = b, stmt = n.kind ~= "expr" and not (e and e.kind == "float") } end
  end
  table.sort(pieces, function(p, q) return p.a < q.a or (p.a == q.a and p.b > q.b) end)
  local out, last = {}, 0
  for _, p in ipairs(pieces) do
    if p.a > last then                             -- (inside one already taken: it comes with it)
      local from = src:sub(line_start(src, p.a), p.a - 1):match("^%s*$") and line_start(src, p.a) or p.a
      if p.stmt and from == line_start(src, p.a) then   -- its ---@type / ---@param lines come with it (and the tags between)
        local f = from
        while f > 1 do
          local ls = line_start(src, f - 1)
          local l = src:sub(ls, f - 2)
          if l:match("^%s*%-%-%-@") then from = ls elseif not l:match("^%s*%-%-@") then break end
          f = ls
        end
      end
      local lines = dedent(src:sub(from, p.b))
      if p.cast and not src:match("^[ \t]*%-%-%[%[@as", p.b + 1) then lines[#lines] = lines[#lines] .. " --[[@as " .. p.cast .. "]]" end
      local keep = {}
      for _, l in ipairs(lines) do if not l:match("^%s*%-%-@") then keep[#keep + 1] = l end end   -- (layout tags)
      out[#out + 1] = table.concat(keep, "\n")
      last = p.b
    end
  end
  return table.concat(out, "\n")
end

function NodeGraphView:copy_selection()
  local list = self:selection()
  if #list == 0 then return false end
  local text = self:selection_text(list)
  if text == "" then self:flash("nothing to copy there"); return false end
  system.set_clipboard(text)
  self:flash("copied " .. #list .. " node" .. (#list > 1 and "s" or ""))
  return true
end

function NodeGraphView:cut_selection()
  if self:copy_selection() then self:delete_nodes(self:selection()) end
end

function NodeGraphView:paste(gx, gy)
  local text = (system.get_clipboard() or ""):gsub("\r\n?", "\n")
  text = table.concat(dedent(text), "\n")
  if text == "" then return self:flash("the clipboard is empty") end
  if not (luaparse.parse(text) or luaparse.parse("local _ = " .. text)) then
    return self:flash("the clipboard isn't Lua code")
  end
  self:add_node({ name = "Pasted code", text = text, raw = true }, gx, gy)
end

-- collapse to function: the selected statements (following one another in a
-- block) become a local function defined right before where they were, and a
-- call of it in their place. The variables they read from outside become its
-- parameters; the outside ones they assign, and the ones they declare that are
-- read after them, come back as its return values:
--   local s = a + b; print(s)  ->  local function new_function(a, b) ... return s end
--                                  local s = new_function(a, b)
-- Refused when control leaves the statements (a return, a break of a loop
-- around them, a goto out), or they use the function's `...`.
function NodeGraphView:collapse_to_function(list)
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local place = {}                                 -- statement -> { block, index }
  local function walk(t)                           -- every block (in functions, lambdas, branches...)
    if type(t) ~= "table" then return end
    if t.stmts then for i, st in ipairs(t.stmts) do place[st] = { t, i } end end
    for k, v in pairs(t) do if k ~= "src" and k ~= "comments" and type(v) == "table" then walk(v) end end
  end
  walk(self.ast.body)
  local chosen, block = {}, nil
  for _, n in ipairs(list) do
    local st = n.block_stmt or (n.edit and n.edit.kind == "node" and n.ast and place[n.ast] and n.ast)
    if n.edit and n.edit.kind == "float" then return self:flash("floating code can't go into a function: wire it in first") end
    if st and place[st] then
      if block and place[st][1] ~= block then return self:flash("select statements of one block (one after another)") end
      block = place[st][1]
      chosen[place[st][2]] = st
    end
  end
  local i1, i2 = math.huge, -math.huge
  for i in pairs(chosen) do i1, i2 = math.min(i1, i), math.max(i2, i) end
  if not block then return self:flash("select the statements to put in a function") end
  for i = i1, i2 do
    if not chosen[i] then return self:flash("select statements that follow one another (one is missing in between)") end
  end
  local s1, s2 = block.stmts[i1], block.stmts[i2]
  local A = s1.pos
  local B = math.max(s2.epos, s2.func and s2.func.epos or 0)
  local ls = line_start(src, A)
  if not src:sub(ls, A - 1):match("^%s*$") or not rest_blank(src, B + 1) then
    return self:flash("these statements share a line with others: put them on lines of their own first")
  end
  -- (their layout tags above the first one go too)
  local a = ls
  while a > 1 do
    local pl = line_start(src, a - 1)
    if not src:sub(pl, a - 2):match("^%s*%-%-@") then break end
    a = pl
  end
  local _, eol = src:find("^[^\n]*", B + 1)
  local b = math.min(#src, eol + 1)
  local function inside(p) return p >= A and p <= B end
  -- control leaving them?
  local why
  local function scan(t, loops, fn)
    if type(t) ~= "table" or why then return end
    local tag = t.tag
    if tag == "Function" then return scan(t.body, 0, true) end
    if not fn then
      if tag == "Return" then why = "a return" end
      if tag == "Vararg" then why = "the function's ..." end
      if tag == "Break" and loops == 0 then why = "a break of a loop around them" end
    end
    if tag == "Goto" then
      local found = false
      local function lab(x)
        if type(x) ~= "table" or found then return end
        if x.tag == "Label" and x.name == t.label then found = true end
        for k, v in pairs(x) do if k ~= "src" and type(v) == "table" then lab(v) end end
      end
      for i = i1, i2 do lab(block.stmts[i]) end
      if not found then why = "a goto out of them" end
    end
    local inner = (tag == "While" or tag == "Repeat" or tag == "Fornum" or tag == "Forin") and loops + 1 or loops
    for k, v in pairs(t) do if k ~= "src" and k ~= "comments" and type(v) == "table" then scan(v, inner, fn) end end
  end
  for i = i1, i2 do scan(block.stmts[i], 0, false) end
  if why then return self:flash("can't collapse to a function: " .. why .. " would leave it") end
  -- names in and out
  local params, pseen, written, wseen, outs, oseen = {}, {}, {}, {}, {}, {}
  local byname = {}
  for _, u in ipairs(self.res.uses) do
    local d = u.decl
    if inside(u.pos) and d and not inside(d.pos) then
      if byname[u.name] and byname[u.name] ~= d then return self:flash("two variables named " .. u.name .. " are used: rename one first") end
      byname[u.name] = d
      if not pseen[d] then pseen[d] = true; params[#params + 1] = d.name end
    elseif not inside(u.pos) and u.pos > B and d and inside(d.pos) and not oseen[d] then
      oseen[d] = true; outs[#outs + 1] = d.name
    end
  end
  local function writes(t)                         -- outside locals assigned in them
    if type(t) ~= "table" then return end
    if t.tag == "Set" then
      for _, tg in ipairs(t.targets) do
        if tg.tag == "Id" then
          for _, u in ipairs(self.res.uses) do
            if u.pos == tg.pos and u.decl and not inside(u.decl.pos) and not wseen[u.decl] then
              wseen[u.decl] = true; written[#written + 1] = u.name
            end
          end
        end
      end
    end
    for k, v in pairs(t) do if k ~= "src" and k ~= "comments" and type(v) == "table" then writes(v) end end
  end
  for i = i1, i2 do writes(block.stmts[i]) end
  -- the text
  local used = {}
  for _, d in ipairs(self.res.decls) do used[d.name] = true end
  for _, u in ipairs(self.res.uses) do used[u.name] = true end
  local name, k = "new_function", 1
  while used[name] do k = k + 1; name = "new_function" .. k end
  local indent = indent_at(src, A)
  local inner = indent .. "  "
  local lines = {}
  for _, l in ipairs(dedent(src:sub(ls, b))) do
    if not l:match("^%s*%-%-@") then lines[#lines + 1] = (l:gsub("%-%-%[%[@[^%]]*%]%]%s*", "")) end   -- (layout tags: laid out afresh)
  end
  local rets = {}
  for _, v in ipairs(written) do rets[#rets + 1] = v end
  for _, v in ipairs(outs) do rets[#rets + 1] = v end
  local text = indent .. "local function " .. name .. "(" .. table.concat(params, ", ") .. ")\n" .. reindent(lines, inner)
  if #rets > 0 then text = text .. inner .. "return " .. table.concat(rets, ", ") .. "\n" end
  text = text .. indent .. "end\n"
  local call = name .. "(" .. table.concat(params, ", ") .. ")"
  if #outs > 0 and #written == 0 then text = text .. indent .. "local " .. table.concat(outs, ", ") .. " = " .. call .. "\n"
  elseif #outs > 0 then
    text = text .. indent .. "local " .. table.concat(outs, ", ") .. "\n" .. indent .. table.concat(rets, ", ") .. " = " .. call .. "\n"
  elseif #written > 0 then text = text .. indent .. table.concat(written, ", ") .. " = " .. call .. "\n"
  else text = text .. indent .. call .. "\n" end
  local except = self:uses_in({ { pos = a, epos = b } })
  for _, u in ipairs(self.res.uses) do if u.decl and oseen[u.decl] then except[u.pos] = true end end
  local hl = 1
  for _ in src:sub(1, a - 1):gmatch("\n") do hl = hl + 1 end
  local ok, err = self:apply_edits(src, { { pos = a, epos = b, text = text } }, except)
  if not ok then return self:flash("can't collapse to a function: " .. tostring(err)) end
  self.select_line = hl                            -- (its header, selected)
  self:flash("collapsed " .. (i2 - i1 + 1) .. " statement" .. (i2 > i1 and "s" or "") .. " into " .. name
             .. "(" .. table.concat(params, ", ") .. "): double-click its header to rename it")
end

function NodeGraphView:delete_nodes(list)
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local spans, floats, exprs, stmts, clauses = {}, {}, {}, {}, {}
  local chosen = {}
  for _, n in ipairs(list) do chosen[n] = true end
  do                                               -- repeat and until go together: both selected, or neither
    local rep, unt = {}, {}
    for _, n in ipairs(self.g.nodes) do
      if n.ast and n.ast.tag == "Repeat" then
        if n.title == "until" then unt[n.ast] = n elseif n.title == "repeat" then rep[n.ast] = n end
      end
    end
    for st, r in pairs(rep) do
      local u = unt[st]
      if u and (chosen[r] or chosen[u]) and not (chosen[r] and chosen[u]) then
        return self:flash("repeat and its until go together: select both to delete them")
      end
    end
  end
  local function inside(p) for _, sp in ipairs(spans) do if p >= sp.pos and p <= sp.epos then return true end end end
  local all_chosen                                 -- (below)
  local part = {}                                  -- an expression inside floating code (not its root): just it, like in the flow
  for _, n in ipairs(list) do
    local e = n.edit
    if e and e.kind == "float" and n.kind == "expr" and e.float.root ~= n.id and n.fields and n.fields.body
       and n.parent and n.parent.id then part[n] = true end
  end
  for _, n in ipairs(list) do                       -- what goes
    local e = n.edit
    if part[n] then -- (below, with the expressions)
    elseif e and e.kind == "float" then floats[e.float] = true
    elseif e and e.kind == "node" and n.pos and n.block then stmts[#stmts + 1] = n
    elseif n.clause and n.clause > 1 and n.ast and n.ast.tag == "If" then clauses[#clauses + 1] = n end
  end
  for F in pairs(floats) do
    local a, b = float_span(src, F)
    spans[#spans + 1] = { pos = a, epos = b, kind = "float" }
  end
  -- code sharing its line (if c then b.hidden = true return end): just its
  -- text goes, with its inline tags before it and the spaces after it
  local function inline_start(n)
    local p = n.pos
    local e = n.edit
    if e and e.inline then
      if e.tag and e.tag.pos < p then p = e.tag.pos end
      for _, t in pairs(e.expr_tags or {}) do if t.pos and t.pos < p then p = t.pos end end
    end
    return p
  end
  local function exact_end(epos)
    local b = epos
    while src:sub(b + 1, b + 1):match("[ \t;]") do b = b + 1 end
    return b
  end
  -- a function's header: the whole function goes (its body with it), and its
  -- ---@ annotations and layout tags above it (a function isn't a step of
  -- the flow around it: nothing there floats)
  for _, n in ipairs(list) do
    local st = n.kind == "function" and not (n.edit and n.edit.kind == "float") and n.block_stmt
    if st and not inside(st.pos) then
      local e2 = math.max(st.epos, st.func and st.func.epos or 0)
      local a, b = st.pos, exact_end(e2)
      local ls = line_start(src, st.pos)
      if src:sub(ls, st.pos - 1):match("^%s*$") and rest_blank(src, e2 + 1) then
        a = ls
        while a > 1 do                             -- (the lines above that belong to it)
          local pl = line_start(src, a - 1)
          if not src:sub(pl, a - 2):match("^%s*%-%-%-?@") then break end
          a = pl
        end
        local _, eol = src:find("^[^\n]*", e2 + 1)
        b = math.min(#src, eol + 1)
      end
      spans[#spans + 1] = { pos = a, epos = b, kind = "func", node = n }
    end
  end
  -- every statement of a block selected (a do block or a function: theirs)
  local node_by_ast = {}
  for _, n in ipairs(self.g.nodes) do
    if n.ast and n.edit and n.edit.kind == "node" then node_by_ast[n.ast] = node_by_ast[n.ast] or n end
    if n.block_stmt then node_by_ast[n.block_stmt] = n end
  end
  function all_chosen(b)
    for _, st in ipairs(b and b.stmts or {}) do
      local n = node_by_ast[st]
      if n then if not chosen[n] then return false end
      elseif st.tag == "Do" then if not all_chosen(st.body) then return false end
      else return false end
    end
    return true
  end
  do                                               -- a do block whose statements all go: it goes too
    local function walk(b)
      for _, st in ipairs(b and b.stmts or {}) do
        if st.tag == "Do" and #st.body.stmts > 0 and all_chosen(st.body) and not inside(st.pos) then
          local ls = line_start(src, st.pos)
          local _, eol = src:find("^[^\n]*", st.epos + 1)
          if src:sub(ls, st.pos - 1):match("^%s*$") and rest_blank(src, st.epos + 1) then
            spans[#spans + 1] = { pos = ls, epos = math.min(#src, eol + 1), kind = "do" }
          else spans[#spans + 1] = { pos = st.pos, epos = exact_end(st.epos), kind = "do" } end
        else
          for _, k in ipairs({ "body", "orelse" }) do if type(st[k]) == "table" and st[k].stmts then walk(st[k]) end end
          for _, c in ipairs(st.clauses or {}) do walk(c.body) end
          if st.func then walk(st.func.body) end
        end
      end
    end
    walk(self.ast and self.ast.body)
  end
  table.sort(stmts, function(p, q) return p.pos < q.pos end)
  for _, n in ipairs(stmts) do
    if not inside(n.pos) then                      -- (inside another one: it goes with it)
      local _, eol = src:find("^[^\n]*", n.epos + 1)
      if not rest_blank(src, n.epos + 1) or not src:sub(line_start(src, n.pos), n.pos - 1):match("^%s*$") then
        spans[#spans + 1] = { pos = inline_start(n), epos = exact_end(n.epos), kind = "stmt", node = n }
        goto next_stmt
      end
      local a = 1
      for _ = 2, n.edit.top_line do a = (src:find("\n", a, true) or #src) + 1 end
      spans[#spans + 1] = { pos = a, epos = math.min(#src, eol + 1), kind = "stmt", node = n }
    end
    ::next_stmt::
  end
  for _, n in ipairs(clauses) do                   -- an elseif: its clause goes (elseif c then ... up to what follows)
    local st, k = n.ast, n.clause
    local cl = st.clauses[k]
    if not inside(cl.cond.pos) then
      local kw, p = nil, st.clauses[k - 1].cond.epos
      while true do
        local a = src:find("%f[%w]elseif%f[%W]", p)
        if not a or a > cl.cond.pos then break end
        kw, p = a, a + 6
      end
      local last = cl.body.stmts[#cl.body.stmts]
      local from, nxt = (last and last.epos or cl.cond.epos) + 1, nil
      for _, w in ipairs({ "elseif", "else", "end" }) do
        local a = src:find("%f[%w]" .. w .. "%f[%W]", from)
        if a and (not nxt or a < nxt) then nxt = a end
      end
      if kw and nxt then
        local a, b = kw, nxt - 1
        local ls, ln = line_start(src, kw), line_start(src, nxt)
        if src:sub(ls, kw - 1):match("^%s*$") and src:sub(ln, nxt - 1):match("^%s*$") then   -- whole lines (and its tags above)
          a, b = ls, ln - 1
          if n.edit and n.edit.top_line then
            local t = 1
            for _ = 2, n.edit.top_line do t = (src:find("\n", t, true) or #src) + 1 end
            a = math.min(a, t)
          end
        end
        spans[#spans + 1] = { pos = a, epos = b, kind = "clause", node = n }
      end
    end
  end
  for _, n in ipairs(list) do                       -- a lambda's header: the function goes, its pin reads nil
    local f = n.kind == "function" and not n.block_stmt and not (n.edit and n.edit.kind == "float") and n.frame and n.frame.func
    if f and f.tag == "Function" and f.pos and not inside(f.pos) then exprs[#exprs + 1] = { pos = f.pos, epos = f.epos, node = n } end
  end
  for _, n in ipairs(list) do                       -- expression nodes in the flow: their pin reads nil
    if n.kind == "expr" and (part[n] or not (n.edit and n.edit.kind == "float")) and n.fields and n.fields.body
       and not inside(n.fields.body.pos) then
      local f = n.fields.body
      local p = n.parent
      while p and chosen[p] == nil and p.kind == "expr" do p = p.parent end
      if not (p and chosen[p]) then exprs[#exprs + 1] = { pos = f.pos, epos = f.epos, node = n } end
    end
  end
  -- UE style, only the node goes: the expression nodes feeding a deleted one
  -- (and not deleted themselves) stay, as floating code where they were,
  -- ready to be wired elsewhere. (Variables and literals were just its pins.)
  local orphans = {}
  local lambdas = {}                               -- (and the functions written into it: as frames)
  local function orphan_kids(n)
    for _, k in ipairs(n.kids or {}) do
      if k.kind == "expr" and k.parent == n and k.slot and k.fields and k.fields.body then
        if chosen[k] then orphan_kids(k) else orphans[#orphans + 1] = k end
      elseif k.head and k.func and k.parent == n then
        if not chosen[k.head] then lambdas[#lambdas + 1] = { fr = k, owner = n } end   -- (its header selected too: it goes)
      end
    end
  end
  for _, ex in ipairs(exprs) do orphan_kids(ex.node) end
  for _, sp in ipairs(spans) do if sp.kind == "stmt" or sp.kind == "clause" then orphan_kids(sp.node) end end   -- (a statement's too)
  for _, n in ipairs(list) do if n.title == "until" and n.ast and n.ast.tag == "Repeat" then orphan_kids(n) end end   -- (until's condition)
  -- a deleted branch / loop takes only itself: its bodies stay, floating where
  -- they were drawn (an if's elseif chain stays as an if of its own)
  local stmt_node = {}
  for _, n in ipairs(self.g.nodes) do if n.ast and n.edit and n.edit.kind == "node" then stmt_node[n.ast] = stmt_node[n.ast] or n end end
  local rescued = {}
  local function rescue(text, at, fallback)
    if text and text:match("%S") then rescued[#rescued + 1] = { text = text, node = at or fallback, below = not at } end
  end
  local function block(b)                          -- a body's text, and its first statement's node
    local s1, s2 = b and b.stmts[1], b and b.stmts[#b.stmts]
    if not s1 or all_chosen(b) then return nil end -- (all of it selected too: it all goes)
    local ls = line_start(src, s1.pos)             -- (from its line; on the if's line: from it)
    local a = src:sub(ls, s1.pos - 1):match("^%s*$") and ls or (stmt_node[s1] and inline_start(stmt_node[s1]) or s1.pos)
    return src:sub(a, s2.epos), stmt_node[s1]
  end
  for _, sp in ipairs(spans) do
    local n, st = sp.node, sp.kind == "stmt" and sp.node.ast
    local t = st and st.tag
    if sp.kind == "clause" then                    -- an elseif's body
      local tx, nd = block(n.ast.clauses[n.clause].body)
      rescue(tx, nd, n)
    elseif t == "If" then
      local tx, nd = block(st.clauses[1].body)
      rescue(tx, nd, n)
      local c2 = st.clauses[2]
      if c2 then                                   -- elseif ... end: an if of its own
        local kw, p = nil, st.clauses[1].cond.epos
        while true do
          local a = src:find("%f[%w]elseif%f[%W]", p)
          if not a or a > c2.cond.pos then break end
          kw, p = a, a + 6
        end
        local n2
        for _, m in ipairs(self.g.nodes) do if m.ast == st and m.clause == 2 then n2 = m end end
        local rest_chosen = n2 and chosen[n2]
        for k = 2, #st.clauses do rest_chosen = rest_chosen and all_chosen(st.clauses[k].body) end
        rest_chosen = rest_chosen and (not st.orelse or all_chosen(st.orelse))
        if kw and not rest_chosen then rescue(src:match("^[ \t]*", line_start(src, kw)) .. "if" .. src:sub(kw + 6, st.epos), n2, n) end
      elseif st.orelse then
        local tx, nd = block(st.orelse)
        rescue(tx, nd, n)
      end
    elseif t == "While" or t == "Fornum" or t == "Forin" or t == "Do" or t == "Repeat" then
      local tx, nd = block(st.body)
      rescue(tx, nd, n)
    end
  end
  -- what follows a deleted statement in its block floats, a run at a time
  local parked = {}
  local by_block = {}
  for _, sp in ipairs(spans) do
    if sp.kind == "stmt" then
      local b = sp.node.block
      by_block[b] = by_block[b] or {}
      by_block[b][sp.node.idx] = sp
    end
  end
  for b, del in pairs(by_block) do
    local run
    local first_del = math.huge                    -- (a label isn't a step: the flow goes on through it)
    for i, sp in pairs(del) do if not (sp.node.ast and sp.node.ast.tag == "Label") then first_del = math.min(first_del, i) end end
    for i = first_del + 1, first_del == math.huge and 0 or #b.stmts + 1 do
      local st = b.stmts[i]
      local gone = del[i] or (st and inside(st.pos))
      if st and not gone then
        run = run or { stmts = {}, anchor = del[first_del].node }   -- (anchor: a deleted node of that block: its frame)
        run.stmts[#run.stmts + 1] = st
      end
      if (gone or not st) and run then parked[#parked + 1] = run; run = nil end
    end
  end
  local node_of_stmt = {}
  for _, n in ipairs(self.g.nodes) do if n.ast and n.edit and n.edit.kind == "node" then node_of_stmt[n.ast] = node_of_stmt[n.ast] or n end end
  for _, run in ipairs(parked) do
    local s1, s2 = run.stmts[1], run.stmts[#run.stmts]
    local n1 = node_of_stmt[s1]
    if not n1 then                                 -- (a function statement: its header node, placed by the text)
      for _, n in ipairs(self.g.nodes) do
        if n.ast == s1 or n.pos == s1.pos or (s1.func and n.ast == s1.func) then n1 = n1 or n end
      end
      if not n1 then                               -- (a do block has no node: its first one inside)
        for _, n in ipairs(self.g.nodes) do
          if n.pos and n.pos >= s1.pos and n.pos <= s1.epos and (not n1 or n.pos < n1.pos) then n1 = n end
        end
      end
      n1 = n1 or list[1]
      local e2 = math.max(s2.epos, s2.func and s2.func.epos or 0)   -- (a function statement ends with its body)
      local ls = line_start(src, s1.pos)
      local whole = src:sub(ls, s1.pos - 1):match("^%s*$") and rest_blank(src, e2 + 1)
      local _, eol = src:find("^[^\n]*", e2 + 1)
      run.pos, run.epos, run.node = whole and ls or s1.pos, whole and math.min(#src, eol + 1) or exact_end(e2), n1
      goto next_run
    end
    local e2 = math.max(s2.epos, s2.func and s2.func.epos or 0)   -- (a function statement ends with its body)
    if not n1.edit.top_line or not rest_blank(src, e2 + 1) then   -- (sharing lines: just their text)
      run.pos, run.epos, run.node = inline_start(n1), exact_end(e2), n1
      goto next_run
    end
    local a = 1
    for _ = 2, n1.edit.top_line do a = (src:find("\n", a, true) or #src) + 1 end
    local _, eol = src:find("^[^\n]*", e2 + 1)
    run.pos, run.epos, run.node = a, math.min(#src, eol + 1), n1
    ::next_run::
  end
  if #spans == 0 and #exprs == 0 then
    return self:flash("nothing here can be deleted from the graph")
  end
  -- the variables declared in what goes: their reads elsewhere become nil
  local gone_decl = {}
  for _, d in ipairs(self.res.decls) do if d.pos > 0 and inside(d.pos) then gone_decl[d] = true end end
  local function nil_for(u)
    return nil_text(src, u.pos, u.epos)
  end
  local written = {}                               -- x = ... : a write keeps its name (nil = 0 is no Lua)
  do
    local ast = luaparse.parse(src)
    local function walk(t)
      if type(t) ~= "table" then return end
      if t.tag == "Set" then for _, tg in ipairs(t.targets) do if tg.tag == "Id" then written[tg.pos] = true end end end
      for k, v in pairs(t) do if k ~= "src" and k ~= "comments" and type(v) == "table" then walk(v) end end
    end
    walk(ast and ast.body)
  end
  local edits, nils_in_run = {}, {}
  local kept = {}
  for _, u in ipairs(self.res.uses) do
    if u.decl and gone_decl[u.decl] and not inside(u.pos) then
      local in_run
      for _, run in ipairs(parked) do if u.pos >= run.pos and u.pos <= run.epos then in_run = run end end
      if in_run then
        -- (floating code: names stay as they are, nothing resolves in it)
      elseif written[u.pos] then kept[u.pos] = true
      else edits[#edits + 1] = { pos = u.pos, epos = u.epos, text = nil_for(u) } end
    end
  end
  for _, sp in ipairs(spans) do edits[#edits + 1] = { pos = sp.pos, epos = sp.epos, text = "" } end
  for _, ex in ipairs(exprs) do edits[#edits + 1] = { pos = ex.pos, epos = ex.epos, text = "nil" } end
  for _, ex in ipairs(exprs) do                    -- a get node: its --@expr ... get= tag goes too
    local t = ex.node and ex.node.getter and ex.node.edit and ex.node.edit.tag
    if t and t.inline then
      local b = t.epos
      while src:sub(b + 1, b + 1) == " " do b = b + 1 end
      edits[#edits + 1] = { pos = t.pos, epos = b, text = "" }
    elseif t and t.line then
      local ls = 1
      for _ = 2, t.line do ls = (src:find("\n", ls, true) or #src) + 1 end
      edits[#edits + 1] = { pos = ls, epos = src:find("\n", ls, true) or #src, text = "" }
    end
  end
  for _, l in ipairs(lambdas) do                   -- lambdas: floating, their frames where they were
    local fr = l.fr
    rescued[#rescued + 1] = { text = src:sub(fr.func.pos, fr.func.epos), node = fr.head, at = { fr.x, fr.y }, owner = l.owner }
  end
  for _, r in ipairs(rescued) do                   -- the bodies: floating, where they were drawn
    local k = r.node
    local fr = frame_of_node(r.owner or k)        -- (a lambda: where its statement was)
    local pos, indent, pre
    pos, indent, pre, fr = self:float_place(fr, src)
    if not pos then return self:flash("that function is on one line: delete it in the text") end
    local hx, hy = fr and fr.head.x or 0, fr and fr.head.y or 0
    local x, y = k.x, r.below and (k.y + k.h + 24) or k.y
    if r.at then x, y = r.at[1], r.at[2] end
    edits[#edits + 1] = { pos = pos, epos = pos - 1, text = pre .. float_text(dedent(r.text), x - hx, y - hy, indent) }
  end
  for _, k in ipairs(orphans) do                   -- its inputs: floating, where they were drawn
    local fr = frame_of_node(k)
    local pos, indent, pre
    pos, indent, pre, fr = self:float_place(fr, src)
    if not pos then return self:flash("that function is on one line: delete it in the text") end
    local hx, hy = fr and fr.head.x or 0, fr and fr.head.y or 0
    local f = k.fields.body
    local text = src:sub(f.pos, f.epos)
    if k.vexpr and (k.vexpr.tag == "Call" or k.vexpr.tag == "Invoke") then text = "(" .. text .. ")" end   -- a value, not a call statement
    local x0, y0 = k.x, k.y                        -- (a float is placed by its left edge: its own inputs' nodes)
    local function reach(n)
      for _, c in ipairs(n.kids or {}) do
        if c.kind == "expr" and c.parent == n then x0, y0 = math.min(x0, c.x), math.min(y0, c.y); reach(c) end
      end
    end
    reach(k)
    edits[#edits + 1] = { pos = pos, epos = pos - 1, text = pre .. float_text(dedent(text), x0 - hx, y0 - hy, indent) }
  end
  for _, run in ipairs(parked) do                  -- moved into floating code, at the end of its function
    local holes = {}                               -- floating code between its statements stays where it is
    for _, F in ipairs(self.g.floats or {}) do
      local fa, fb = float_span(src, F)
      if fa >= run.pos and fb <= run.epos and not floats[F] then holes[#holes + 1] = { fa, fb } end
    end
    table.sort(holes, function(p, q) return p[1] < q[1] end)
    local parts, at = {}, run.pos
    for _, h in ipairs(holes) do
      if h[1] > at then edits[#edits + 1] = { pos = at, epos = h[1] - 1, text = "" }; parts[#parts + 1] = src:sub(at, h[1] - 1) end
      at = h[2] + 1
    end
    if at <= run.epos then edits[#edits + 1] = { pos = at, epos = run.epos, text = "" }; parts[#parts + 1] = src:sub(at, run.epos) end
    local fr = (run.anchor or run.node).parent       -- (the frame of the block it was in)
    while fr and not fr.head do fr = fr.parent end
    local pos, indent, pre
    pos, indent, pre, fr = self:float_place(fr, src)
    if not pos then return self:flash("that function is on one line: delete it in the text") end
    local text = table.concat(parts)
    if nils_in_run[run] and #holes == 0 then text = resolve.apply(text, nils_in_run[run]) end
    text = text:gsub("[ \t;]+(\n)", "%1"):gsub("[ \t;]+$", "")   -- (no trailing spaces)
    local hx, hy = fr and fr.head.x or 0, fr and fr.head.y or 0
    edits[#edits + 1] = { pos = pos, epos = pos - 1, text = pre .. float_text(dedent(text), run.node.x - hx, run.node.y - hy, indent) }
  end
  local all = {}
  for _, sp in ipairs(spans) do all[#all + 1] = sp end
  for _, ex in ipairs(exprs) do all[#all + 1] = ex end
  for _, run in ipairs(parked) do all[#all + 1] = { pos = run.pos, epos = run.epos } end
  local except = self:uses_in(all)
  for _, e in ipairs(edits) do if e.text == "nil" or e.text == "(nil)" or e.text == ";(nil)" then except[e.pos] = true end end
  for p in pairs(kept) do except[p] = true end
  local frames = {}                                -- where the deletion was: what's left there keeps its place
  for _, n in ipairs(list) do frames[frame_of_node(n) or "top"] = true end
  local old_g = self.g
  local ok, err = self:apply_edits(src, edits, except)
  if not ok and os.getenv("NG_DEBUG_DELETE") then
    local f = io.open(os.getenv("NG_DEBUG_DELETE"), "w"); f:write((resolve.apply(src, edits))); f:close()
  end
  if not ok then return self:flash("can't delete: " .. tostring(err)) end
  local _, map = resolve.apply(src, edits)
  self:keep_places(old_g, frames, map)
  self.sel, self.selected = {}, nil
  local k = #spans + #exprs
  self:flash("deleted " .. k .. (k == 1 and " node" or " nodes") .. (#parked > 0 and "; what followed floats now" or "")
             .. (#orphans > 0 and ("; " .. #orphans .. " input" .. (#orphans > 1 and "s float" or " floats") .. " now") or "")
             .. (#rescued > 0 and ("; its bod" .. (#rescued > 1 and "ies float" or "y floats")) or ""))
end

-- after an edit that changes the layout (a deletion: the room its nodes took
-- goes, so what was right of them would slide left), the nodes left in those
-- frames stay where they were drawn: each that moved gets an offset (dx, dy)
-- making up for it. Nodes are matched by their code's position, through the
-- edit's map. Written as a second change right away (it undoes with the first).
local function ident(n)
  local p = n.kind == "expr" and n.fields and n.fields.body and n.fields.body.pos or n.pos
  return p and (n.kind .. ":" .. p) or nil
end
function NodeGraphView:keep_places(old_g, frames, map)
  if not old_g then return end
  self:rebuild()
  if not self.g then return end
  local new_by = {}
  for _, m in ipairs(self.g.nodes) do
    local id = ident(m)
    if id and not (m.edit and m.edit.kind == "float") then new_by[id] = m end
  end
  local list, seen = {}, {}
  for _, n in ipairs(old_g.nodes) do
    local p = n.kind == "expr" and n.fields and n.fields.body and n.fields.body.pos or n.pos
    local m = p and not (n.edit and n.edit.kind == "float") and frames[frame_of_node(n) or "top"]
              and new_by[n.kind .. ":" .. map(p)]
    if m then
      local dx, dy = n.x - m.x, n.y - m.y
      if math.abs(dx) >= 1 or math.abs(dy) >= 1 then
        for _, it in ipairs(drag_roots({ m })) do
          if not seen[it[2]] then
            seen[it[2]] = true
            local ddx, ddy = math.floor(dx + 0.5), math.floor(dy + 0.5)
            list[#list + 1] = { it[1], function(t)
              local nx, ny = (tonumber(t.vals.dx) or 0) + ddx, (tonumber(t.vals.dy) or 0) + ddy
              self.set_val(t, "dx", nx ~= 0 and tostring(nx) or nil)
              self.set_val(t, "dy", ny ~= 0 and tostring(ny) or nil)
            end }
          end
        end
      end
    end
  end
  if #list > 0 then self:write_tags(list); self:rebuild() end
end

-- comment boxes ------------------------------------------------------------

-- the frame (function) a node is in, or nil
function NodeGraphView:add_comment(nodes)
  if #nodes == 0 or self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
  for _, n in ipairs(nodes) do
    x1, y1 = math.min(x1, n.x), math.min(y1, n.y)
    x2, y2 = math.max(x2, n.x + n.w), math.max(y2, n.y + n.h)
  end
  local m, top = 16, 30
  local fr = frame_of_node(nodes[1])
  local function inside(f, g) while g do if g == f then return true end g = frame_of(g) end end
  for _, n in ipairs(nodes) do                     -- nodes of several functions: the one around them all
    while fr and not inside(fr, frame_of_node(n)) do fr = frame_of(fr) end
  end
  while fr do                                      -- a function on one line has no room: the one around it
    local nl = src:find("\n", fr.func.params_epos or fr.func.pos, true)
    if nl and nl < fr.func.epos then break end
    fr = frame_of(fr)
  end
  local hx, hy = fr and fr.head.x or 0, fr and fr.head.y or 0
  local pos, indent = 1, ""
  if fr then                                       -- the line after the function's header
    local nl = src:find("\n", fr.func.params_epos or fr.func.pos, true)
    pos = nl + 1
    local first = fr.func.body.stmts[1]
    indent = first and indent_at(src, first.pos) or (indent_at(src, fr.func.pos) .. "  ")
  end
  local t = { kind = "comment", keys = { "dx", "dy", "w", "h" },
              vals = { dx = tostring(math.floor(x1 - m - hx)), dy = tostring(math.floor(y1 - m - top - hy)),
                       w = tostring(math.floor(x2 - x1 + 2 * m)), h = tostring(math.floor(y2 - y1 + 2 * m + top)) },
              title = "Comment" }
  local ok, err = self:apply_edits(src, { { pos = pos, epos = pos - 1, text = indent .. graph.tag_text(t) .. "\n" } })
  if not ok then return self:flash("can't add a comment: " .. tostring(err)) end
  self:flash("comment added: double-click its headline to name it")
end

-- a comment's line, rewritten (change(tag) edits it) or removed (change = nil)
function NodeGraphView:note_edit(nt, change, src)
  local ls = 1
  for _ = 2, nt.tag.line do ls = (src:find("\n", ls, true) or #src) + 1 end
  local le = (src:find("\n", ls, true) or (#src + 1)) - 1
  if not change then return { pos = ls, epos = math.min(#src, le + 1), text = "" } end
  local t = { kind = "comment", keys = {}, vals = {}, title = nt.tag.title }
  for _, k in ipairs(nt.tag.keys) do t.keys[#t.keys + 1] = k; t.vals[k] = nt.tag.vals[k] end
  change(t)
  return { pos = ls, epos = le, text = src:match("^[ \t]*", ls) .. graph.tag_text(t) }
end

function NodeGraphView:set_note_color(nt, c)    -- c: "#rrggbb", or nil: the default
  if self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  self:replace_text(src, resolve.apply(src, { self:note_edit(nt, function(t)
    if c and not t.vals.color then t.keys[#t.keys + 1] = "color" end
    t.vals.color = c
    if not c then for i, k in ipairs(t.keys) do if k == "color" then table.remove(t.keys, i) break end end end
  end, src) }))
end

function NodeGraphView:delete_note(nt)
  if self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  self:replace_text(src, resolve.apply(src, { self:note_edit(nt, nil, src) }))
  self:flash("comment deleted (its nodes stay)")
end

function NodeGraphView:rename_note(nt)
  local t = nt.title or ""
  self.editing = { note = nt, which = "note", field = { note = true }, text = t, orig = t, cur = #t + 1,
                   change_id = self.change_id, src = self.doc:get_text(1, 1, math.huge, math.huge) }
  core.redraw = true
end

function NodeGraphView:commit_note(e)
  self.editing = nil
  local title = e.text:gsub("\r", "")             -- (its lines kept: SHIFT+ENTER)
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  self:replace_text(src, resolve.apply(src, { self:note_edit(e.note, function(t) t.title = title end, src) }))
end

-- the nodes inside a comment box (wholly; folded: the box it unfolds to)
function NodeGraphView:nodes_in_note(nt)
  local l = {}
  local w, h = nt.full_w or nt.w, nt.full_h or nt.h
  for _, n in ipairs(self.g.nodes) do
    if n.x >= nt.x and n.y >= nt.y and n.x + n.w <= nt.x + w and n.y + n.h <= nt.y + h then l[#l + 1] = n end
  end
  return l
end

-- "new local": one more name and value (local a = 1 -> local a, value = 1, 0)
-- one more operand at the end of a concat: a .. b -> a .. b .. ""
function NodeGraphView:add_concat_operand(n)
  if not n or not n.concat or self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local last = n.concat[#n.concat].epos
  local ok, err = self:apply_edits(src, { { pos = last + 1, epos = last, text = ' .. ""' } })
  if not ok then return self:flash("can't add a string: " .. tostring(err)) end
  self:flash("added " .. string.char(96 + math.min(#n.concat + 1, 26)))
end

function NodeGraphView:add_local_value(s)
  if self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local used = {}
  for _, u in ipairs(self.res.uses) do used[u.name] = true end
  for _, d in ipairs(self.res.decls) do used[d.name] = true end
  local nm, k = "value", 1
  while used[nm] do k = k + 1; nm = "value" .. k end
  local lastn = s.name_pos[#s.name_pos][2]
  local attrib = src:match("^%s*<%a+>", lastn + 1)    -- local x <const>
  if attrib then lastn = lastn + #attrib end
  local lastv = s.exprs[#s.exprs].epos
  local ok, err = self:apply_edits(src, { { pos = lastn + 1, epos = lastn, text = ", " .. nm },
                                          { pos = lastv + 1, epos = lastv, text = ", 0" } })
  if not ok then return self:flash("can't add a value: " .. tostring(err)) end
  self:flash("added " .. nm)
end

-- a function's parameters: "+ add parameter" (arg1, arg2...: after its last
-- argN, a name that function doesn't use yet, before "..." or ")"); remove one (not while the body uses it; a
-- local function's calls in this file lose that argument too)
function NodeGraphView:add_param(f)
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local words = {}                                 -- taken: the function's own names (its parameters, what
  for w in src:sub(f.pos, f.epos):gmatch("[%a_][%w_]*") do words[w] = true end   -- its body reads: not to hide those)
  local k = 1                                      -- (after its last argN: arg1, arg2, arg3...)
  for _, p in ipairs(f.params) do local n = tonumber(p:match("^arg(%d+)$")); if n and n >= k then k = n + 1 end end
  while words["arg" .. k] do k = k + 1 end
  local nm = "arg" .. k
  local last                                       -- the last written parameter (not an implicit self)
  for _, sp in ipairs(f.param_pos or {}) do if sp[1] > 0 then last = sp end end
  local edit
  if f.vararg then                                 -- before the "..."
    local from = last and last[2] + 1 or f.pos
    local d = src:find("...", from, true)
    if not d or d > f.params_epos then return self:flash("can't find the function's (...)") end
    edit = { pos = d, epos = d - 1, text = nm .. ", " }
  elseif last then
    edit = { pos = last[2] + 1, epos = last[2], text = ", " .. nm }
  else
    edit = { pos = f.params_epos, epos = f.params_epos - 1, text = nm }
  end
  local ok, err = self:apply_edits(src, { edit })
  if not ok then return self:flash("can't add a parameter: " .. tostring(err)) end
  self:flash("added parameter " .. nm)
end

function NodeGraphView.param_index(f, pos)
  for i, sp in ipairs(f and f.param_pos or {}) do if sp[1] == pos and pos > 0 then return i end end
end

function NodeGraphView:remove_param(f, i)
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local sp = f.param_pos[i]
  local nm = f.params[i]
  local ast = luaparse.parse(src)
  local res = ast and resolve.resolve(ast)
  if not res then return self:flash("the file does not parse") end
  local d = res.decl_at[sp[1]]
  local R, A = res, ast                            -- (the parse the function is in)
  if not d then                                    -- floating code: resolved on its own text
    for _, F in ipairs(self.g and self.g.floats or {}) do
      if F.inner_pos and F.inner_pos <= sp[1] and sp[1] <= F.inner_epos then
        local shadow = src:sub(1, F.inner_pos - 1):gsub("[^\n]", " ") .. src:sub(F.inner_pos, F.inner_epos)
                       .. src:sub(F.inner_epos + 1):gsub("[^\n]", " ")
        local fa = luaparse.parse(shadow)
        local fr = fa and resolve.resolve(fa)
        d = fr and fr.decl_at[sp[1]]
        if d then R, A = fr, fa end
      end
    end
  end
  if d and #d.refs > 0 then
    return self:flash("can't remove " .. nm .. ": the function uses it (" .. #d.refs .. (#d.refs == 1 and " place)" or " places)"))
  end
  local prev                                       -- the written parameter before it, the one after it
  for j = i - 1, 1, -1 do if f.param_pos[j][1] > 0 then prev = f.param_pos[j]; break end end
  local nxt = f.param_pos[i + 1]
  local edits = {}
  if prev then                                     -- ", b"
    edits[1] = { pos = prev[2] + 1, epos = sp[2], text = "" }
  elseif nxt then                                  -- "a, "
    edits[1] = { pos = sp[1], epos = nxt[1] - 1, text = "" }
  elseif f.vararg then                             -- "a, ..."
    local dd = src:find("...", sp[2] + 1, true)
    edits[1] = { pos = sp[1], epos = (dd or sp[2] + 1) - 1, text = "" }
  else
    edits[1] = { pos = sp[1], epos = sp[2], text = "" }
  end
  -- the calls of a local function: their argument at that place goes too
  local name_decl
  for _, dd in ipairs(R.decls) do
    local o = dd.owner
    if dd.kind == "function" and o.func and o.func.pos == f.pos then name_decl = dd end   -- (a fresh parse: by position)
    if dd.kind == "local" and o.exprs then         -- local f = function(...) end
      for k, sp2 in ipairs(o.name_pos) do if sp2[1] == dd.pos and o.exprs[k] and o.exprs[k].pos == f.pos then name_decl = dd end end
    end
  end
  local calls = 0
  if name_decl then
    local at = {}
    for _, r in ipairs(name_decl.refs) do at[r[1]] = true end
    local skip = 0                                 -- (an implicit self is not an argument)
    for j = 1, i - 1 do if f.param_pos[j][1] < 0 then skip = skip + 1 end end
    local ai = i - skip
    local function walk(e)
      if type(e) ~= "table" then return end
      if e.tag == "Call" and e.fn and e.fn.tag == "Id" and at[e.fn.pos] then
        local a = e.args[ai]
        if a and not (ai == #e.args and (a.tag == "Call" or a.tag == "Invoke" or a.tag == "Vararg")) then
          local ep, pp
          if ai > 1 then pp, ep = e.args[ai - 1].epos + 1, a.epos
          elseif e.args[2] then pp, ep = a.pos, e.args[2].pos - 1
          else pp, ep = a.pos, a.epos end
          edits[#edits + 1] = { pos = pp, epos = ep, text = "" }
          calls = calls + 1
        end
      end
      for _, v in pairs(e) do if type(v) == "table" then walk(v) end end
    end
    walk(A)
  end
  local ok, err = self:apply_edits(src, edits)
  if not ok then return self:flash("can't remove " .. nm .. ": " .. tostring(err)) end
  self:flash("removed parameter " .. nm .. (calls > 0 and (" (and its argument in " .. calls .. (calls == 1 and " call)" or " calls)")) or ""))
end

-- the mouse ------------------------------------------------------------------

function NodeGraphView.set_val(t, k, v)
  if v ~= nil and t.vals[k] == nil then t.keys[#t.keys + 1] = k end
  t.vals[k] = v
end

-- change a node's tag (change(tag) edits tag.vals) and write it into the doc:
-- replace the --@ line, add one above the statement, or drop an empty one
function NodeGraphView:write_tag(n, change) return self:write_tags({ { n, change } }) end

-- several at once, as one change of the text: each { node, change }
function NodeGraphView:write_tags(list)
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local ls = { 1 }
  for i in src:gmatch("()\n") do ls[#ls + 1] = i + 1 end
  ls[#ls + 1] = #src + 2
  local edits, done = {}, {}
  for k, it in ipairs(list) do
    local n, change = it[1], it[2]
    if it.note then                                -- a comment box (moved with its nodes)
      local e = self:note_edit(it.note, change, src)
      e.seq = k
      edits[#edits + 1] = e
      n = {}
    end
    local e = n.edit
    if e and e.kind == "float" then                -- floating code: its header line keeps dx, dy, colour
      local F = e.float
      if not done[F] then
        done[F] = true
        local t = { kind = "float", keys = {}, vals = {} }
        for _, key in ipairs(F.keys) do t.keys[#t.keys + 1] = key; t.vals[key] = F.vals[key] end
        if not t.vals.dx then t.keys[#t.keys + 1] = "dx"; t.vals.dx = "0" end
        if not t.vals.dy then t.keys[#t.keys + 1] = "dy"; t.vals.dy = "0" end
        change(t)
        if t.vals.dx == nil then t.vals.dx = "0" end   -- (a float always keeps its place)
        if t.vals.dy == nil then t.vals.dy = "0" end
        local parts = {}
        for _, key in ipairs(t.keys) do if t.vals[key] ~= nil then parts[#parts + 1] = key .. "=" .. t.vals[key] end end
        edits[#edits + 1] = { pos = F.header.pos, epos = F.header.epos,
                              text = "--[" .. F.level .. "[@float " .. table.concat(parts, " "), seq = k }
      end
    elseif e and e.inline then                     -- an inline tag: --[[@node dx= dy=]] before the code
      local old = e.kind == "frame" and n.frame and n.frame.tag or e.tag
      local t = { kind = e.kind, keys = {}, vals = {} }
      if e.kind == "expr" and not old then t.keys[1], t.vals.slot = "slot", tostring(e.slot) end
      if old then for _, key in ipairs(old.keys) do t.keys[#t.keys + 1] = key; t.vals[key] = old.vals[key] end end
      change(t)
      local text = graph.tag_text(t)
      text = text and ("--[[" .. text:sub(3) .. "]]")
      if old and old.inline then
        local b = old.epos
        if not text then while src:sub(b + 1, b + 1) == " " do b = b + 1 end end   -- (its space goes too)
        edits[#edits + 1] = { pos = old.pos, epos = b, text = text or "", seq = 100000 + k }
      elseif old and ls[old.line] then              -- (a line tag: rewritten on its line)
        local a, b = ls[old.line], ls[old.line + 1] - 2
        if text then
          edits[#edits + 1] = { pos = a, epos = b, text = src:match("^[ \t]*", a) .. "--" .. text:sub(5, -3), seq = 100000 + k }
        else
          edits[#edits + 1] = { pos = a, epos = math.min(#src, b + 1), text = "", seq = 100000 + k }
        end
      elseif text then
        edits[#edits + 1] = { pos = e.insert_pos, epos = e.insert_pos - 1, text = text .. " ", seq = 100000 + k }
      end
    elseif e then
      local old = n.frame and n.frame.tag or e.tag
      local t = { kind = e.kind, keys = {}, vals = {} }
      if e.kind == "expr" and not old then t.keys[1], t.vals.slot = "slot", tostring(e.slot) end   -- which pin it feeds
      if old then for _, key in ipairs(old.keys) do t.keys[#t.keys + 1] = key; t.vals[key] = old.vals[key] end end
      change(t)
      local text = graph.tag_text(t)
      local seq = (e.kind == "frame" and 0 or 100000) + k   -- a frame's tag above a statement's
      if old and ls[old.line] then
        local a, b = ls[old.line], ls[old.line + 1] - 2  -- the line, without its newline
        if text then
          local indent = src:match("^[ \t]*", a)
          edits[#edits + 1] = { pos = a, epos = b, text = indent .. text, seq = seq }
        else
          edits[#edits + 1] = { pos = a, epos = math.min(#src, b + 1), text = "", seq = seq }   -- the whole line goes
        end
      elseif text and e.insert_line and ls[e.insert_line] then
        local a = ls[e.insert_line]
        edits[#edits + 1] = { pos = a, epos = a - 1, text = e.indent .. text .. "\n", seq = seq }
      end
    end
  end
  if #edits == 0 then return end
  local new = resolve.apply(src, edits)
  self:replace_text(src, new)
end

-- selection: self.sel = { [node] = true }, self.selected = the active one
NodeGraphView.GRID = 24                              -- graph units (the grid drawn: 24 * zoom)
function NodeGraphView:nudge(dx, dy)
  local sel = self:selection()
  local roots = drag_roots(sel)
  if #roots == 0 then return self:flash("nothing selected can be moved") end
  local px, py = math.huge, math.huge
  for _, n in ipairs(sel) do px, py = math.min(px, n.x), math.min(py, n.y) end
  local G = math.floor(self.GRID * SCALE + 0.5)
  local function step(v, d)
    if d == 0 then return v end
    local cell = v / G
    local snapped = d < 0 and math.floor(cell) or math.ceil(cell)
    if math.abs(cell - snapped) < 1e-6 or snapped * G == v then snapped = snapped + d end   -- on the grid: a cell
    return snapped * G
  end
  local mx, my = math.floor(step(px, dx) - px + 0.5), math.floor(step(py, dy) - py + 0.5)
  if mx == 0 and my == 0 then return end
  local list = {}
  for _, it in ipairs(roots) do
    list[#list + 1] = { it[1], function(t)
      local nx = (tonumber(t.vals.dx) or 0) + mx
      local ny = (tonumber(t.vals.dy) or 0) + my
      self.set_val(t, "dx", nx ~= 0 and tostring(nx) or nil)
      self.set_val(t, "dy", ny ~= 0 and tostring(ny) or nil)
    end }
  end
  self:write_tags(list)
end

function NodeGraphView:set_literal(pos, epos, text)
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local ok, err = self:apply_edits(src, { { pos = pos, epos = epos, text = text } })
  if not ok then self:flash("can't write " .. text .. ": " .. tostring(err)) end
end

-- a slider: the value under x (snapped to the step: given, else 1 for whole
-- ranges and values, else a hundredth of the range)
NodeGraphView.FIELD_TYPES = {
  { name = "Number",   key = "value",   value = "0" },
  { name = "String",   key = "text",    value = '""' },
  { name = "Boolean",  key = "enabled", value = "false" },
  { name = "Vector",   key = "pos",     value = "{ x = 0, y = 0 }" },
  { name = "Colour",   key = "color",   value = "{ 255, 255, 255 }" },
  { name = "Table",    key = "data",    value = "{}" },
  { name = "Function", key = "fn",      value = "function() end" },
}

-- "+ add field": choose its type
function NodeGraphView:retype_field(n, pin, ft)
  local f = pin.field
  if not f or self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local vpos = pin.pos
  local edits = { { pos = vpos, epos = pin.epos, text = ft.value } }
  if ft.name == "Colour" and f.key_pos and not pin.name:lower():find("colou?r") then
    local used = {}
    for _, p in ipairs(n.ins) do used[p.name] = true end
    local key, k = "color", 1
    while used[key] do k = k + 1; key = "color" .. k end
    edits[2] = { pos = f.key_pos[1], epos = f.key_pos[2], text = key }
  end
  local ok, err = self:apply_edits(src, edits, self:uses_in({ { pos = vpos, epos = pin.epos } }))
  if not ok then return self:flash("can't change it: " .. tostring(err)) end
  self:flash(pin.name .. " is a " .. ft.name:lower() .. " now")
end

-- a table node's fields: add one ("+ add field"), remove one (RMB on its row)
function NodeGraphView:add_field(n, ft)
  local t = n.tnode
  if not t or self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local used, positional = {}, #t.fields > 0
  for _, f in ipairs(t.fields) do
    if f.name then used[f.name] = true; positional = false elseif f.key then positional = false end
  end
  ft = ft or self.FIELD_TYPES[1]
  local key, k = ft.key, 1
  if ft.exact then positional = false                -- a class's field: its own name, always keyed
  else while used[key] do k = k + 1; key = ft.key .. k end end
  local entry = positional and ft.value or (key .. " = " .. ft.value)
  local edit
  if #t.fields == 0 then
    edit = { pos = t.pos + 1, epos = t.epos - 1, text = " " .. entry .. " " }
  else
    local last = t.fields[#t.fields]
    local ls = src:sub(1, last.pos - 1):match(".*\n()") or 1
    local first_line = src:sub(1, t.pos):match(".*\n()") or 1
    local sep = ", "
    if ls ~= first_line and src:sub(ls, last.pos - 1):match("^%s*$") then   -- one field a line: a new line
      sep = ",\n" .. src:sub(ls, last.pos - 1)
    end
    edit = { pos = last.value.epos + 1, epos = last.value.epos, text = sep .. entry }
  end
  local ok, err = self:apply_edits(src, { edit })
  if not ok then return self:flash("can't add a field: " .. tostring(err)) end
  self:flash("added " .. (positional and "an item" or key))
end

-- the value a new field of a LuaLS type starts with (---@field name type)
function NodeGraphView:class_default(ty, g)
  ty = (ty or ""):gsub("%?$", "")
  if ty == "number" or ty == "integer" then return "0" end
  if ty == "string" then return '""' end
  if ty == "boolean" then return "false" end
  if ty:lower():find("colou?r") then return "{ 255, 255, 255 }" end
  if ty:find("^fun") or ty == "function" then return "function() end" end
  local a = g and g.aliases[ty]
  if a and a[1] then return string.format("%q", a[1]) end
  if ty:find("%[%]$") or ty:find("^table") or (g and g.classes[ty]) then return "{}" end
  if ty:find('^".*"$') or ty:find("^'.*'$") then return ty end
  return "nil"
end

-- add a field its class declares but the table lacks
function NodeGraphView:add_class_field(n, cf)
  self:add_field(n, { key = cf.name, value = cf.default or self:class_default(cf.type, self.g), exact = true })   -- (a world class's: its value)
end

-- remove an input pin, and what it stands for in the text: a value of
-- `local a, b = 1, 2` (b and 2 go; b's reads elsewhere read nil), of a
-- multiple assignment, of a return, an argument of a call, an operand of a
-- concat (a .. b .. c). Table fields: remove_field. Returns the menu label, or
-- nil when that pin can't go on its own.
local function list_cut(list, k)                   -- a list item's span, with its comma (or its ..)
  if #list == 1 then return list[1].pos, list[1].epos end
  if k < #list then return list[k].pos, list[k + 1].pos - 1 end
  return list[k - 1].epos + 1, list[k].epos
end
function NodeGraphView:removable(n, i)
  local pin = n and n.ins[i]
  if not pin or pin.action then return nil end
  if pin.field then return nil end                 -- (a table field: "Remove field")
  local st = n.ast
  if n.kind == "local" and st and st.tag == "Local" and #st.exprs > 0 then
    if #st.names < 2 or i > #st.exprs or (i == #st.exprs and #st.names > #st.exprs) then return nil end
    local d = self.res.decl_at[st.name_pos[i][1]]
    local reads, src = 0, self.doc:get_text(1, 1, math.huge, math.huge)
    for _, r in ipairs(d and d.refs or {}) do
      local after = src:match("^%s*(.?.?)", r[2] + 1) or ""
      if not (after:sub(1, 1) == "=" and after:sub(2, 2) ~= "=") then reads = reads + 1 end
    end
    if reads > 0 then return "Remove " .. st.names[i] .. (reads > 1 and " (its " .. reads .. " reads become nil)" or " (its read becomes nil)") end
    return "Remove " .. st.names[i] .. " (and its value)"
  elseif n.kind == "set" and st and st.tag == "Set" then
    if #st.targets < 2 or i > #st.exprs or (i == #st.exprs and #st.targets > #st.exprs) then return nil end
    return "Remove " .. pin.name .. " (and its value)"
  elseif n.kind == "return" and st and st.tag == "Return" and pin.ret_index then
    return "Remove value " .. i .. " of this return"
  elseif n.concat then
    for k, o in ipairs(n.concat) do if o == pin.e and k > 2 then return "Remove operand " .. pin.name end end   -- (a and b stay)
  else
    local call = n.vexpr and (n.vexpr.tag == "Call" or n.vexpr.tag == "Invoke") and n.vexpr or (st and st.tag == "CallStat" and st.call)
    if call then for _, a in ipairs(call.args) do if a == pin.e then return "Remove argument " .. pin.name end end end
  end
  return nil
end
function NodeGraphView:remove_pin(n, i)
  if self.doc:get_change_id() ~= self.change_id then return self:flash("the text changed meanwhile: try again") end
  local pin = n.ins[i]
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local st = n.ast
  local spans, gone = {}, nil
  local function cut(list, k) local a, b = list_cut(list, k); spans[#spans + 1] = { pos = a, epos = b } end
  if n.kind == "local" then
    local names = {}
    for k, sp in ipairs(st.name_pos) do names[k] = { pos = sp[1], epos = sp[2] } end
    cut(names, i); cut(st.exprs, i)
    gone = self.res.decl_at[st.name_pos[i][1]]
  elseif n.kind == "set" then
    cut(st.targets, i); cut(st.exprs, i)
  elseif n.kind == "return" then
    cut(st.exprs, i)
  elseif n.concat then
    for k, o in ipairs(n.concat) do
      if o == pin.e then
        local ops = n.concat
        if k < #ops then spans[1] = { pos = o.pos, epos = ops[k + 1].pos - 1 }
        else spans[1] = { pos = ops[k - 1].epos + 1, epos = o.epos } end
      end
    end
  else
    local call = n.vexpr and (n.vexpr.tag == "Call" or n.vexpr.tag == "Invoke") and n.vexpr or st.call
    for k, a in ipairs(call.args) do if a == pin.e then cut(call.args, k) end end
  end
  local edits, except = {}, self:uses_in(spans)
  for _, sp in ipairs(spans) do edits[#edits + 1] = { pos = sp.pos, epos = sp.epos, text = "" } end
  if gone then                                     -- the removed variable: its reads read nil (a write keeps its name)
    for _, r in ipairs(gone.refs or {}) do
      local after = src:match("^%s*(.?.?)", r[2] + 1) or ""
      if not (after:sub(1, 1) == "=" and after:sub(2, 2) ~= "=") then
        edits[#edits + 1] = { pos = r[1], epos = r[2], text = nil_text(src, r[1], r[2]) }
      end
      except[r[1]] = true
    end
  end
  local ok, err = self:apply_edits(src, edits, except)
  if not ok then return self:flash("can't remove it: " .. tostring(err)) end
  self:flash("removed " .. pin.name)
end

function NodeGraphView:remove_field(pin)
  local f = pin.field
  if not f or self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local a, b = f.pos, f.epos
  local after = src:match("^%s*[,;]", b + 1)
  if after then                                    -- "field, ": with the separator after it
    b = b + #after
    local ls = src:sub(1, a - 1):match(".*\n()") or 1
    local rest_eol = src:match("^[ \t]*\n", b + 1) or src:match("^[ \t]*%-%-[^\n]*\n", b + 1)   -- (and its comment)
    if src:sub(ls, a - 1):match("^%s*$") and rest_eol then a, b = ls, b + #rest_eol   -- its whole line
    else b = b + #(src:match("^[ \t]*", b + 1)) end
  else                                             -- the last one: with the separator before it
    local before = src:sub(1, a - 1):match("()%s*[,;]%s*$")
    if before then a = before end
  end
  local spans = { { pos = a, epos = b } }
  local ok, err = self:apply_edits(src, { { pos = a, epos = b, text = "" } }, self:uses_in(spans))
  if not ok then return self:flash("can't remove it: " .. tostring(err)) end
  self:flash("removed " .. pin.name)
end

-- a number dragged sideways: the value for an offset of dx pixels

-- split pins (UE's "split struct pin"): a table input shown as a pin per field
-- on its node ("pos.x", "pos.y"), each wired / edited on its own. View state
-- (self.split, by slot key; kept in the workspace). A pin holding a table
-- constructor just splits; one reading a table (`f(pos)`) is written as one
-- first, `f({ x = pos.x, y = pos.y })`, its fields from the table it was
-- declared with or the class of its parameter / field. Merging back writes
-- `pos` again when every field is still `pos.<field>`.
local function bare(e) while e and e.tag == "Paren" do e = e.e end return e end
function NodeGraphView:split_fields_of(n, pin)
  local e = bare(pin and pin.e)
  if not e or pin.action or pin.split_of or not pin.opath then return nil end
  if e.tag == "Table" then return #e.fields > 0 and "here" or nil end
  if not (e.tag == "Id" or (e.tag == "Index" and e.name)) then return nil end
  local names = {}
  local d = pin.decl
  local o = d and d.owner
  if o and o.tag == "Local" and not d.assigned then   -- local pos = { x = 0, y = 0 }
    for k, nm in ipairs(o.names) do
      local ex = bare(o.exprs[k])
      if nm == d.name and ex and ex.tag == "Table" then
        for _, f in ipairs(ex.fields) do if f.name then names[#names + 1] = f.name end end
      end
    end
  end
  if #names == 0 then                              -- its parameter's / field's class
    local ty = pin.ftype
    local dc = n.dcall
    if not ty and dc and pin.param then
      local types = dc.api and dc.api.types or (dc.callee and self.g.fn_info[dc.callee] and self.g.fn_info[dc.callee].params) or {}
      ty = types[pin.param]
    end
    ty = ty and ty:gsub("%?$", "")
    local cls = ty and self.g.classes and self.g.classes[ty]
    for _, cf in ipairs(cls and cls.fields or {}) do names[#names + 1] = cf.name end
  end
  return #names > 0 and names or nil
end
-- split: the tag (--@expr slot=N split=1), and for a variable its table first
function NodeGraphView:split_pin(n, pin)
  local names = self:split_fields_of(n, pin)
  if not names or self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local tag = self:expr_tag_edit(pin, function(t)
    if not t.vals.split then t.keys[#t.keys + 1] = "split" end
    t.vals.split = "1"
  end, src)
  if not tag then return self:flash("can't split this pin (its statement takes no tags)") end
  local edits, except = { tag }, nil
  if names ~= "here" then
    local e = bare(pin.e)
    local base = src:sub(e.pos, e.epos)
    local parts = {}
    for _, nm in ipairs(names) do parts[#parts + 1] = nm .. " = " .. base .. "." .. nm end
    edits[2] = { pos = e.pos, epos = e.epos, text = "{ " .. table.concat(parts, ", ") .. " }" }
    except = self:uses_in({ { pos = e.pos, epos = e.epos } })   -- (its read of pos: rewritten on purpose)
  end
  local ok, err = self:apply_edits(src, edits, except)
  if not ok then return self:flash("can't split it: " .. tostring(err)) end
  self:flash("split " .. pin.name .. (names ~= "here" and (": " .. #names .. " fields") or " into its fields"))
end
-- merge: the tag goes; every field still `base.<its name>`: `base` again
function NodeGraphView:merge_pin(n, pin)
  if not pin.split_of or self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local tag = self:expr_tag_edit({ opath = pin.split_of }, function(t) t.vals.split = nil end, src, n)   -- (the pin as written: its path)
  if not tag then return self:flash("can't merge it here") end
  local edits = { tag }
  local t = pin.split_table
  local base                                       -- every field still `base.<its name>`: write `base` again
  for _, f in ipairs(t and t.fields or {}) do
    local v = bare(f.value)
    local b = f.name and v and v.tag == "Index" and v.name == f.name and src:sub(v.obj.pos, v.obj.epos)
    if not b or (base and b ~= base) then base = false; break end
    base = b
  end
  local except
  if base and base:match("^[%a_][%w_%.]*$") then
    edits[2] = { pos = t.pos, epos = t.epos, text = base }
    except = self:uses_in({ { pos = t.pos, epos = t.epos } })
  else base = nil end
  local ok, err = self:apply_edits(src, edits, except)
  if not ok then return self:flash("can't merge it: " .. tostring(err)) end
  self:flash(base and ("merged back into " .. base) or "merged: one table pin again")
end

-- split outputs: a table node assigned to a variable (local p = {...}): an
-- output per field (p.speed), mirrored on the right of its rows; a field
-- holding a table (a colour) can be split too. In the text: the table node's
-- tag, --@expr slot=N outs=1[,color...]
function NodeGraphView:split_outputs(n, field)   -- field: nil = the table's own; else that field's table
  if not n or self.doc:get_change_id() ~= self.change_id then return end
  if not n.split_base then return self:name_table(n) end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local tag = self:expr_tag_edit(nil, function(t)
    local l = {}
    for nm in (t.vals.outs or ""):gmatch("[^,]+") do l[#l + 1] = nm end
    if #l == 0 then l[1] = "1" end
    if field then
      local has = false
      for _, nm in ipairs(l) do if nm == field then has = true end end
      if not has then l[#l + 1] = field end
    end
    if not t.vals.outs then t.keys[#t.keys + 1] = "outs" end
    t.vals.outs = table.concat(l, ",")
  end, src, n)
  if not tag then return self:flash("can't split its outputs here (its statement takes no tags)") end
  local ok, err = self:apply_edits(src, { tag })
  if not ok then return self:flash("can't split it: " .. tostring(err)) end
  self:flash("split " .. (field and (n.split_base.text .. "." .. field) or n.split_base.text) .. " into outputs")
end
function NodeGraphView:merge_outputs(n, field)   -- field: nil = all of them
  if not (n and n.split_outs) or self.doc:get_change_id() ~= self.change_id then return end
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local tag = self:expr_tag_edit(nil, function(t)
    if not field then t.vals.outs = nil; return end
    local l = {}
    for nm in (t.vals.outs or ""):gmatch("[^,]+") do if nm ~= field then l[#l + 1] = nm end end
    t.vals.outs = #l > 0 and table.concat(l, ",") or nil
  end, src, n)
  if not tag then return end
  local ok, err = self:apply_edits(src, { tag })
  if not ok then return self:flash("can't merge it: " .. tostring(err)) end
  self:flash("merged " .. (field and (n.split_base.text .. "." .. field) or n.split_base.text) .. "'s outputs")
end

-- a table not assigned to a variable yet, split into outputs: it's assigned
-- first (the outputs read its fields: tbl.x). Floating ({...} on its own):
-- it becomes `local tbl = {...}` there; fed into a pin: `local tbl = {...}`
-- right above that statement, the pin reads tbl. Its tag (outs=1) with it.
function NodeGraphView:name_table(n)
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local e = n.vexpr
  if not (e and e.pos) then return end
  local used = {}
  for _, u in ipairs(self.res.uses) do used[u.name] = true end
  for _, d in ipairs(self.res.decls) do used[d.name] = true end
  local name, k = "tbl", 1
  while used[name] do k = k + 1; name = "tbl" .. k end
  local body = src:sub(e.pos, e.epos)
  local F = n.edit and n.edit.kind == "float" and n.edit.float
  local edits
  if F and F.root == n.id then                     -- floating: assigned in place
    local ind = src:match("^[ \t]*", line_start(src, e.pos))
    edits = { { pos = e.pos, epos = e.epos, text = "--@expr slot=1 outs=1\n" .. ind .. "local " .. name .. " = " .. body } }
  else                                             -- fed into a pin: a local above its statement
    local st = stmt_of(n)
    local se = st and st.edit
    if not (se and se.kind == "node" and se.insert_line and not se.inline) then
      return self:flash("can't name that table here (its statement shares its line): do it in the text")
    end
    local at = 1
    for _ = 2, se.top_line or se.insert_line do at = (src:find("\n", at, true) or #src) + 1 end
    local ind = se.indent or ""
    edits = { { pos = at, epos = at - 1, text = ind .. "--@expr slot=1 outs=1\n" .. ind .. "local " .. name .. " = " .. body:gsub("\n", "\n" .. ind) .. "\n" },
              { pos = e.pos, epos = e.epos, text = name } }
  end
  local ok, err = self:apply_edits(src, edits, self:uses_in({ { pos = e.pos, epos = e.epos } }))
  if not ok then return self:flash("can't name that table: " .. tostring(err)) end
  self:flash("assigned to " .. name .. " and split into outputs")
end

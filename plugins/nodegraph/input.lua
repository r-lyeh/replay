-- input.lua - NodeGraphView: the mouse, the keys, the menus, hit testing
-- (part of the nodegraph plugin, ours). See view.lua for the mouse scheme.
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
local indent_at, dedent, reindent, float_text, float_span, frame_of_node = U.indent_at, U.dedent, U.reindent, U.float_text, U.float_span, U.frame_of_node
local move_tree, movable, drag_roots, num_text, draggable, slider_value = U.move_tree, U.movable, U.drag_roots, U.num_text, U.draggable, U.slider_value
local dragged_number, hsv2rgb, rgb2hsv = U.dragged_number, U.hsv2rgb, U.rgb2hsv

function NodeGraphView:row_at(n, y, x)
  local ox, oy = self:origin()
  local z = self.zoom
  if y < oy + (n.y + n.head_h) * z then return "title" end
  local half = (style.font:get_height() + 4) / 2
  for i, pin in ipairs(n.ins) do                   -- an input's row: the expression behind it
    if math.abs(y - (oy + (n.y + pin.y) * z)) <= half * z then
      local label_end = ox + (n.x + 10 * SCALE) * z + style.font:get_width(pin.name) * z
      if pin.ret_index and n.ret_fn and x and x <= label_end then return "name" .. i end   -- a return value's name
      if x and x <= label_end and n.fields and n.fields["key" .. i] then return "key" .. i end   -- a field's name
      if x and x <= label_end and n.fields and n.fields["var" .. i] then return "var" .. i end   -- a set local's variable
      if n.fields and n.fields["slot" .. i] then return "slot" .. i end
    end
  end
  return "body"
end

function NodeGraphView:socket_at(x, y)
  if not self.g then return nil end
  local ox, oy = self:origin()
  local z = self.zoom
  if z < 0.4 then return nil end                   -- far out the sockets would cover the nodes: drags move them
  local r = math.max(5, 8 * SCALE * z)
  for k = #self.g.nodes, 1, -1 do
    local n = self.g.nodes[k]
    if not n.hidden and x >= ox + n.x * z - r and x <= ox + (n.x + n.w) * z + r and y >= oy + n.y * z and y <= oy + (n.y + n.h) * z then
      if n.xin then                                -- flow pins first
        local ex, ey = self:exec_xy(n, "in", 1, ox, oy)
        if math.abs(x - ex) <= r and math.abs(y - ey) <= r then return { node = n, side = "in", i = 1, sock = n.xin, exec = true } end
      end
      for k, xo in ipairs(n.xouts or {}) do
        local ex, ey = self:exec_xy(n, "out", k, ox, oy)
        if math.abs(x - ex) <= r and math.abs(y - ey) <= r then return { node = n, side = "out", i = k, sock = xo, exec = true } end
      end
      for _, side in ipairs({ "in", "out" }) do
        for i, sk in ipairs(side == "in" and n.ins or n.outs) do
          local sx, sy = self:socket_xy(n, side, i, ox, oy)
          if not sk.action and math.abs(x - sx) <= r and math.abs(y - sy) <= r then
            return { node = n, side = side, i = i, sock = side == "in" and n.ins[i] or n.outs[i] }
          end
        end
      end
    end
  end
end

-- what an input pin stands for in the text: its variable's uses, or the
-- whole expression behind it (a literal, an expression node's, a lambda)
local function editing() local v = core.active_view; return v and v:is(NodeGraphView) and v.editing ~= nil end
local function cont(b) return b and b >= 0x80 and b < 0xC0 end    -- utf-8 continuation byte
local FIELD = require "plugins.canvas.field"      -- (the text typed: plugins/canvas/field.lua, shared)
local step = FIELD.step
-- the edit box (a field, a name, a comment's headline, the picker's hex):
-- typed in lite (plugins/textproxy.lua, through canvas.field): selection,
-- words, the clipboard, undo. Enter applies (a comment: SHIFT+Enter a new
-- line), Escape or a click elsewhere cancels. Focused on the first update
-- after self.editing is set; closed when self.editing goes (alive).
function NodeGraphView:focus_edit()
  local e = self.editing
  if not e or FIELD.focused(e) or e.tp_closed then return end
  FIELD.focus(e, {
    font = select(2, self:fonts()), multiline = e.note ~= nil,
    on_key = function(k)
      if k == "return" or k == "keypad enter" then
        if e.note and keymap.modkeys["shift"] then e.tp:insert("\n") return true end
        if self.editing == e then self:commit_edit() end
        return true
      end
      if k == "escape" then if self.editing == e then self:cancel_edit() end return true end
      return false
    end,
    on_change = function() e.err = nil; core.redraw = true end,
    on_blur = function() e.tp_closed = true; if self.editing == e then self:cancel_edit() end end,   -- (a click elsewhere: cancel)
  })
  if e.tp then e.tp.opts.alive = function() return self.editing == e end end
end
local ng_update = NodeGraphView.update
function NodeGraphView:update(...)
  if self.editing then self:focus_edit() end
  return ng_update(self, ...)
end

-- the nearest pin a wire dragged from `from` can end on, within a short
-- reach of the mouse (SNAP px on screen): the other side, the same kind
-- (flow / value), on another node
NodeGraphView.SNAP = 22
function NodeGraphView:snap_socket(x, y, from)
  local g = self.g
  if not g or self.zoom < 0.4 then return nil end
  local ox, oy = self:origin()
  local best, bd = nil, (self.SNAP * SCALE) ^ 2
  local want = from.side == "out" and "in" or "out"
  local function try(n, side, i, sock, exec)
    local sx, sy
    if exec then sx, sy = self:exec_xy(n, side, i, ox, oy) else sx, sy = self:socket_xy(n, side, i, ox, oy) end
    local d = (sx - x) ^ 2 + (sy - y) ^ 2
    if d < bd then best, bd = { node = n, side = side, i = i, sock = sock, exec = exec or nil }, d end
  end
  for _, n in ipairs(g.nodes) do
    if n ~= from.node then
      if from.exec then
        if want == "in" and n.xin then try(n, "in", 1, n.xin, true) end
        if want == "out" then for k, xo in ipairs(n.xouts or {}) do try(n, "out", k, xo, true) end end
      else
        for i, sk in ipairs(want == "in" and n.ins or n.outs) do
          if not sk.action then try(n, want, i, sk) end
        end
      end
    end
  end
  return best
end

-- what hovering lights up: a pin (its wires, the pins at their other ends)
-- or, off the pins, every wire under the mouse (overlapping ones too) and
-- their end pins. { links = {[link]=true}, execs = {[e]=true}, socks = {[sock]=true}, key }
function NodeGraphView:highlight_at(x, y, sk)
  local g = self.g
  if not g or self.press then return nil end
  local hl = { links = {}, execs = {}, socks = {}, n = 0 }
  local ox, oy = self:origin()
  local function add_link(l)
    hl.links[l] = true; hl.n = hl.n + 1
    hl.socks[self.by_id[l.from].outs[l.out]] = true
    hl.socks[self.by_id[l.to].ins[l.inp]] = true
  end
  local function add_exec(e)
    local a, b = self.by_id[e.from], self.by_id[e.to]
    if not (a.xouts[e.out or 1] and b.xin) then return end
    hl.execs[e] = true; hl.n = hl.n + 1
    hl.socks[a.xouts[e.out or 1]] = true
    hl.socks[b.xin] = true
  end
  if sk then
    local s = sk.sock
    hl.socks[s] = true
    for _, l in ipairs(g.links) do
      if self.by_id[l.from].outs[l.out] == s or self.by_id[l.to].ins[l.inp] == s then add_link(l) end
    end
    for _, e in ipairs(g.exec) do
      local a, b = self.by_id[e.from], self.by_id[e.to]
      if (a.xouts[e.out or 1] == s) or (b.xin == s and not (e.back and not e.jump)) then add_exec(e) end
    end
    hl.key = tostring(s)
    return hl
  end
  local r = 5 * SCALE
  for _, l in ipairs(g.links) do
    local a, b = self.by_id[l.from], self.by_id[l.to]
    if not l.chip and not ((a.proxy or b.proxy) and self:shown(a) == self:shown(b)) then   -- (not inside a folded function)
      local x1, y1 = self:socket_xy(a, "out", l.out, ox, oy)
      local x2, y2 = self:socket_xy(b, "in", l.inp, ox, oy)
      if near_curve(x, y, x1, y1, x2, y2, r) then add_link(l) end
    end
  end
  for _, e in ipairs(g.exec) do
    local a, b = self.by_id[e.from], self.by_id[e.to]
    if not e.back and a.xouts[e.out or 1] and b.xin and self:shown(a) ~= self:shown(b) then
      local x1, y1 = self:exec_xy(a, "out", e.out or 1, ox, oy)
      local x2, y2 = self:exec_xy(b, "in", 1, ox, oy)
      local ym = e.wrap and x2 < x1 and self:wrap_y(b, oy) or nil
      if U.near_path(x, y, U.exec_path(x1, y1, x2, y2, ym, self.zoom * SCALE), r) then add_exec(e) end
    end
  end
  if hl.n == 0 then return nil end
  local ks = {}
  for l in pairs(hl.links) do ks[#ks + 1] = tostring(l) end
  for e in pairs(hl.execs) do ks[#ks + 1] = tostring(e) end
  table.sort(ks)
  hl.key = table.concat(ks, ",")
  return hl
end

function NodeGraphView:wire_at(x, y)
  if not self.g then return nil end
  local ox, oy = self:origin()
  for k = #self.g.links, 1, -1 do
    local l = self.g.links[k]
    local a, b = self.by_id[l.from], self.by_id[l.to]
    local x1, y1 = self:socket_xy(a, "out", l.out, ox, oy)
    local x2, y2 = self:socket_xy(b, "in", l.inp, ox, oy)
    if not ((a.proxy or b.proxy) and self:shown(a) == self:shown(b)) and near_curve(x, y, x1, y1, x2, y2, 5 * SCALE) then return l end
  end
end

-- disconnect: these uses read nil instead ("(nil)" where something follows: nil.x is no Lua)
-- popup menus: { text, fn } items, { header = true, text } titles and
-- { text, sub = items } submenus (hovering opens them beside it). A menu
-- taller than the view shows what fits and scrolls with the wheel.
-- { swatches = PALETTE, fn(colour) }: a row of colour squares (false: none)
-- (the menus themselves: plugins/canvas/menu.lua, shared; the graph keeps
-- its open one in self.menu and adds find to it)
local CM = require "plugins.canvas.menu"
NodeGraphView.SWATCH_STEP = CM.SWATCH_STEP
function NodeGraphView:menu_bounds() return { x = self.position.x, y = self.position.y, w = self.size.x, h = self.size.y } end
function NodeGraphView:make_menu(x, y, items, parent, search) return CM.make(x, y, items, self:menu_bounds(), parent, search) end

-- opts.search: a search box on top (the Add menu): typing filters every item
-- of every submenu, fuzzy ("math e": Math expression), best first
local MENU_CMD = { up = "nodegraph:menu-up", down = "nodegraph:menu-down", pageup = "nodegraph:menu-page-up",
                   pagedown = "nodegraph:menu-page-down", ["return"] = "nodegraph:menu-pick", ["keypad enter"] = "nodegraph:menu-pick",
                   home = "nodegraph:menu-first", ["end"] = "nodegraph:menu-last" }
local GRAPH_KEYS = { ["nodegraph:find"] = true, ["nodegraph:find-next"] = true, ["nodegraph:find-previous"] = true,
                     ["nodegraph:save"] = true }   -- (the rest, while its search types: the text's, CTRL+A all of it...)
function NodeGraphView:open_menu(x, y, items, opts)
  local m = CM.open(x, y, items, self:menu_bounds(), opts)
  self.menu = m
  if m and m.search then                           -- its search box: typed in lite (plugins/textproxy.lua)
    CM.edit_search(m, {
      changed = function() self:refilter_menu() end,
      alive = function() return self.menu == m end,
      keys = function(k)                           -- the menu's keys first (up, down, page up / down, home, end, enter, escape)
        if k == "escape" then self.menu = nil; core.redraw = true; return true end
        local function as_graph(cmd)               -- (its commands act on the graph: it, for them)
          local prev = core.active_view
          core.active_view = self
          local done = command.perform(cmd)
          if core.active_view == self then core.active_view = prev end
          core.redraw = true
          return done
        end
        local mods = keymap.modkeys["ctrl"] or keymap.modkeys["alt"] or keymap.modkeys["shift"]
        local cmd = MENU_CMD[k]
        if cmd and not mods then as_graph(cmd) return true end   -- (home / end: the list's; SHIFT+HOME / END select the text)
        for _, c in ipairs(keymap.map[require("plugins.textproxy").stroke(k)] or {}) do   -- (the graph's own keys: CTRL+F, F3, CTRL+S)
          if GRAPH_KEYS[c] and as_graph(c) then return true end
        end
        return false
      end,
    })
  end
end
NodeGraphView.fuzzy_score = CM.fuzzy_score

function NodeGraphView:refilter_menu()
  local m = self.menu
  if not (m and m.search) then return end
  CM.refilter(m, self:menu_bounds())
  if m.find then if m.search:match("%S") then self.find_last = m.search end; self:find_follow() end
end

-- what find matches a node by: its title, its code and its pins' names
-- (a "new local" is found by the variable it declares)
local function find_key(n, code)
  local names = {}
  for _, p in ipairs(n.ins or {}) do if p.name and not p.action then names[#names + 1] = p.name end end
  for _, o in ipairs(n.outs or {}) do if o.name then names[#names + 1] = o.name end end
  return (n.title .. " " .. code .. " " .. table.concat(names, " ")):lower()
end

-- F3 / shift+F3 with the find box closed: the next / previous node matching
-- the last search (best first, as the box listed them; it wraps around)
function NodeGraphView:find_again(d)
  local q = self.find_last
  if not (q and q:match("%S") and self.g) then return self:flash("nothing to find again: CTRL+F first") end
  local text = self.doc:get_text(1, 1, math.huge, math.huge)
  local hits = {}
  for _, n in ipairs(self.g.nodes) do
    local code = n.fields and n.fields.body and text:sub(n.fields.body.pos, n.fields.body.epos):gsub("%s+", " ") or table.concat(n.lines or {}, " ")
    local key = find_key(n, code)
    local sc = NodeGraphView.fuzzy_score(q, key, (n.title .. "  " .. code):sub(1, 44))
    if sc then hits[#hits + 1] = { n = n, s = sc, key = key } end
  end
  if #hits == 0 then return self:flash("no node matches '" .. q .. "'") end
  table.sort(hits, function(a, b) if a.s ~= b.s then return a.s > b.s end return a.key < b.key end)
  local at = 0
  for i, h in ipairs(hits) do if h.n == self.selected then at = i end end
  local i = ((at - 1 + d) % #hits) + 1
  if at == 0 then i = d > 0 and 1 or #hits end
  self:find_show(hits[i].n)
  self:flash(string.format("'%s': %d of %d", q, i, #hits))
end

-- ctrl+f: find a node. A box in the top-right corner; typing filters every
-- node by its title and code (fuzzy, best first) and the best one is shown
-- at once: selected, the camera glides to it, and the text (if it's open
-- beside) goes to its line. Up / down go through the others; enter (or a
-- click) keeps it and closes; ctrl+f again or a click elsewhere closes.
function NodeGraphView:open_find()
  if not self.g then return end
  local w = math.min(420 * SCALE, self.size.x - 20 * SCALE)
  local x, y = self.position.x + self.size.x - w - 10 * SCALE, self.position.y + 34 * SCALE
  local hint = { { text = "type to find a node (title or code)", dim = true } }
  self:open_menu(x, y, hint, { search = true })
  local m = self.menu
  m.find, m.w, m.w0, m.flat, m.fixed_w, m.max_rows = true, w, w, {}, w, 12
  local text = self.doc:get_text(1, 1, math.huge, math.huge)
  for _, n in ipairs(self.g.nodes) do
    local code = n.fields and n.fields.body and text:sub(n.fields.body.pos, n.fields.body.epos):gsub("%s+", " ") or table.concat(n.lines or {}, " ")
    local label = n.title .. (code ~= "" and code ~= n.title and ("  " .. code) or "")
    if #label > 44 then label = label:sub(1, 41) .. "..." end
    m.flat[#m.flat + 1] = { text = label, node = n, hint = n.line and ("line " .. n.line) or nil,
                            key = find_key(n, code), fn = function() self:find_show(n, true) end }
  end
  m.node_of = {}
  for _, it in ipairs(m.flat) do m.node_of[it.fn] = it.node end
end
function NodeGraphView:find_show(n, done)          -- select it, glide to it, its line in the text
  if not n then return end
  self:select({ n })
  local z = self.zoom
  local tx, ty = self:clamp_pan(self.size.x / 2 - (n.x + n.w / 2) * z, self.size.y / 2 - (n.y + n.h / 2) * z)
  self.scroll_anim = { fx = self.pan.x, fy = self.pan.y, tx = tx, ty = ty, t0 = system.get_time() }
  if n.line then self:goto_line(n.line, true) end
  if done then self:flash("found " .. n.title .. (n.line and (" (line " .. n.line .. ")") or "")) end
  core.redraw = true
end
function NodeGraphView:find_follow()               -- the hot result, shown as it changes
  local m = self.menu
  local it = m and m.find and m.hot and m.items[m.hot]
  if it and it.fn and m.node_of[it.fn] and m.shown ~= it.fn then
    m.shown = it.fn
    self:find_show(m.node_of[it.fn])
  end
end

function NodeGraphView:menus() return CM.chain(self.menu) end   -- the open menus, the first one to the deepest
function NodeGraphView:menu_at(x, y) return CM.at(self.menu, x, y) end
function NodeGraphView:menu_item_at(x, y) return CM.item_at(self.menu, x, y) end   -- (an item that can be picked)
function NodeGraphView:menu_hover(x, y) return CM.hover(self.menu, x, y, self:menu_bounds()) end   -- (a submenu's item opens it beside)

function NodeGraphView:context_menu(x, y, at_pin)
  local wg = not at_pin and not self:node_at(x, y) and self:widget_at(x, y)
  if wg and wg.kind == "chip" and wg.node and wg.i then   -- a chip: its pin's menu (at its pin, right of it)
    local ox, oy = self:origin()
    local sx, sy = self:socket_xy(wg.node, wg.side, wg.i, ox, oy)
    if sx then return self:context_menu(sx, sy, true) end
  end
  local n = self:node_at(x, y)
  if not n then local sk = self:socket_at(x, y); n = sk and sk.node end   -- (a pin on its node's edge: that node)
  local ox, oy = self:origin()
  local gx, gy = (x - ox) / self.zoom, (y - oy) / self.zoom
  local items = {}
  local sel = self:selection()
  local nt = not n and self:note_at(x, y)
  if nt then                                       -- a comment's headline
    self:open_menu(x, y, { { header = true, text = nt.title ~= "" and nt.title or "comment" },
      { swatches = PALETTE, current = nt.tag.vals.color or false, fn = function(c) self:set_note_color(nt, c) end },
      { text = nt.collapsed and "Expand" or "Minimize", fn = function() self:toggle_collapse(nt) end },
      { text = "Rename comment", fn = function() self:rename_note(nt) end },
      { header = true, sep = true, text = "" },
      { text = "Delete comment", fn = function() self:delete_note(nt) end } })
    return
  end
  -- the order: colours; what every node has (shortest first: Minimize, Add
  -- comment, Go to definition, Show source code); then what's particular to
  -- that node; then a separator and Delete, always last
  local SEP = { header = true, sep = true, text = "" }
  if n and self.sel and self.sel[n] and #sel > 1 then   -- on the selection
    items[#items + 1] = { header = true, text = #sel .. " nodes" }
    items[#items + 1] = { swatches = PALETTE, current = self:color_of(n), fn = function(c) self:set_color(sel, c) end }
    local any = false
    for _, m in ipairs(sel) do any = any or not m.collapsed end
    items[#items + 1] = { text = any and "Minimize" or "Expand", fn = function()
      for _, m in ipairs(sel) do if (not m.collapsed) == any and self.ckeys[m] then self.collapsed[self.ckeys[m]] = any or nil end end
      self:rebuild(); core.redraw = true
    end }
    items[#items + 1] = { text = "Add comment", fn = function() self:add_comment(sel) end }
    items[#items + 1] = { text = "Collapse to function", fn = function() self:collapse_to_function(sel) end }
    items[#items + 1] = SEP
    items[#items + 1] = { text = "Delete " .. #sel .. " nodes", fn = function() self:delete_nodes(sel) end }
  elseif n then
    items[#items + 1] = { header = true, text = n.title }
    if n.edit then                                 -- colours first: a row of squares (the first: none)
      items[#items + 1] = { swatches = PALETTE, current = self:color_of(n), fn = function(c) self:set_color({ n }, c) end }
    end
    local common = {}                              -- the ones every node has: shortest first
    if self:collapsible(n) then
      common[#common + 1] = { text = n.collapsed and "Expand" or "Minimize", fn = function() self:toggle_collapse(n) end }
    end
    common[#common + 1] = { text = "Add comment", fn = function() self:add_comment((self.sel and self.sel[n]) and sel or { n }) end }
    do                                             -- where what it uses is defined (the pin under the mouse first); dim: none
      local pi = tonumber((self:row_at(n, y, x) or ""):match("%d+$") or "")
      local pin = pi and n.ins[pi]
      if self:definition_of(n, pin) then
        common[#common + 1] = { text = "Go to definition", fn = function() self:goto_definition(n, pin) end }
      else
        common[#common + 1] = { text = "Go to definition", dim = true }
      end
    end
    common[#common + 1] = { text = "Show source code", fn = function() if n.line then self:goto_line(n.line) end end }
    for i, it in ipairs(common) do it.order = i end
    table.sort(common, function(a, b) if #a.text ~= #b.text then return #a.text < #b.text end return a.order < b.order end)
    for _, it in ipairs(common) do items[#items + 1] = it end
    if n.table then                                -- its outputs: a field each (a table assigned to a variable)
      local sk = self:socket_at(x, y)
      local o = sk and sk.side == "out" and sk.node == n and sk.sock
      local ri = tonumber((self:row_at(n, y, x) or ""):match("%d+$") or "")
      local fname = (o and o.split_out and o.name) or (n.split_outs and ri and n.ins[ri] and n.ins[ri].field and n.ins[ri].name)
      local nested = false
      for nm in (n.split_outs or ""):gmatch("[^,]+") do if nm == fname then nested = true end end
      local fv
      for _, p in ipairs(n.ins) do if fname and p.name == fname then fv = p.e end end
      while fv and fv.tag == "Paren" do fv = fv.e end
      if not n.split_base then                     -- (not assigned yet: it will be, local tbl = {...})
        items[#items + 1] = { text = "Split " .. ((o and o.name ~= "" and o.name) or (n.outs[1] and n.outs[1].name ~= "" and n.outs[1].name) or "table"), fn = function() self:split_outputs(n) end }
      elseif not n.split_outs then
        items[#items + 1] = { text = "Split " .. n.split_base.text, fn = function() self:split_outputs(n) end }
      else
        if fname and not fname:find("[%.%[]") and fv and fv.tag == "Table" and not nested then
          items[#items + 1] = { text = "Split " .. n.split_base.text .. "." .. fname, fn = function() self:split_outputs(n, fname) end }
        elseif nested then
          items[#items + 1] = { text = "Merge " .. n.split_base.text .. "." .. fname, fn = function() self:merge_outputs(n, fname) end }
        end
        items[#items + 1] = { text = "Merge " .. n.split_base.text, fn = function() self:merge_outputs(n) end }
      end
    end
    if n.table then                                -- the field under the mouse
      local which = self:row_at(n, y, x)
      local i = tonumber(which:match("%d+$") or "")
      local pin = i and n.ins[i]
      if pin and pin.field then
        items[#items + 1] = { text = "Remove field " .. pin.name, fn = function() self:remove_field(pin) end }
        for _, ft in ipairs(self.FIELD_TYPES) do
          items[#items + 1] = { text = "Make " .. pin.name .. " a " .. ft.name:lower(), fn = function() self:retype_field(n, pin, ft) end }
        end
      end
      items[#items + 1] = { text = "Add field...", fn = function() self:add_field_menu(n, x, y) end }
    end
    do                                             -- a function's parameter (its header's output): rename, remove
      local sk = self:socket_at(x, y)
      local f = n.kind == "function" and n.frame and n.frame.func
      local o = f and sk and sk.side == "out" and sk.node == n and sk.sock
      if f and not o then                          -- (or its name: the right half of that row)
        local ox, oy = self:origin()
        local half = (style.font:get_height() + 4) / 2 * self.zoom
        for i, q in ipairs(n.outs) do
          local sx, sy = self:socket_xy(n, "out", i, ox, oy)
          if math.abs(y - sy) <= half and x >= ox + (n.x + n.w / 2) * self.zoom and x <= sx then o = q end
        end
      end
      local pi = o and o.decl and self.param_index(f, o.decl.pos)
      if pi then
        if n.fields and n.fields.title then
          items[#items + 1] = { text = "Rename parameter " .. o.name, fn = function() self:begin_edit(n, "title") end }
        end
        items[#items + 1] = { text = "Remove parameter " .. o.name, fn = function() self:remove_param(f, pi) end }
      end
    end
    do                                             -- the pin under the mouse: remove it (and what it stands for)
      local which = self:row_at(n, y, x)
      local pi = tonumber((which or ""):match("%d+$") or "")
      local label = pi and self:removable(n, pi)
      if pi and n.fields and n.fields["var" .. pi] then   -- a set local's variable: rename it (and its reads)
        items[#items + 1] = { text = "Rename variable " .. n.ins[pi].name, fn = function() self:begin_edit(n, "var" .. pi) end }
      end
      if label then items[#items + 1] = { text = label, fn = function() self:remove_pin(n, pi) end } end
      local pin = pi and n.ins[pi]                  -- a table pin: a pin per field (and back)
      if pin and pin.split_of then
        local nm = pin.name:match("^(.-)%.[^%.]*$") or pin.name
        items[#items + 1] = { text = "Merge " .. nm, fn = function() self:merge_pin(n, pin) end }
      elseif pin and self:split_fields_of(n, pin) then
        items[#items + 1] = { text = "Split " .. pin.name, fn = function() self:split_pin(n, pin) end }
      end
    end
    do                                             -- the variable under the mouse: where it's declared, written, read
      local d = self:decl_at(n, x, y)
      if d then
        items[#items + 1] = { text = (self:pin_of(d) and "Unpin references of " or "Pin references of ") .. d.name,
                              fn = function() self:toggle_pin(d) end }
      end
    end
    if n.edit and n.edit.kind == "node" and n.block then
      items[#items + 1] = { text = "Collapse to function", fn = function() self:collapse_to_function({ n }) end }
    end
    if n.line and n.kind ~= "expr" and not n.floating and self.doc and self.doc.filename then   -- the world stops its tick here
      local B = require "plugins.nodegraph.breaks"
      local on = B.has(self.doc.filename, n.line)
      items[#items + 1] = { text = on and "Remove breakpoint" or "Add breakpoint",
                            fn = function()
                              B.set(self.doc.filename, n.line, not on)
                              if not on and self.at_load(n) then
                                self:flash(self.is_root(self.doc.filename) and self.AT_BOOT_NOTE or self.AT_LOAD_NOTE)
                              elseif not on and self:at_setup(n) then self:flash(self.AT_SETUP_NOTE) end
                            end }
    end
    if (n.edit and (n.edit.kind == "node" or n.edit.kind == "float")) or n.kind == "expr" or n.block_stmt then
      items[#items + 1] = SEP
      items[#items + 1] = { text = n.edit and n.edit.kind == "float" and "Delete (this floating code)" or "Delete",
                            fn = function() self:delete_node(n) end }
    end
  else
    items[#items + 1] = { header = true, text = "Add" }
    if #self.back > 0 then items[#items + 1] = { text = "Go back", fn = function() self:go_back() end } end   -- (after a go to definition)
    if #self.pins > 0 then items[#items + 1] = { text = "Unpin all references", fn = function() self:unpin_all() end } end
    for _, it in ipairs(self:add_menu(gx, gy)) do items[#items + 1] = it end
    local ow = package.loaded["plugins.openwith"]   -- this file's other ways (its text, hex...: plugins/openwith.lua)
    local f = self.doc and self.doc.filename
    local owi = ow and f and ow.item(f, self)       -- (Open tab with >, Open beside with >)
    local owb = ow and f and ow.beside_item(f, self)
    if self.plugin_menu or owi or owb then items[#items + 1] = SEP end
    for _, it in ipairs({ owi or false, owb or false }) do
      if it then items[#items + 1] = { text = it.text, sub = function() return CM.from_lite(it.sub()) end } end
    end
    if self.plugin_menu then                         -- (last: the plugin's common commands, a submenu: editor.lua)
      local ok, sub = pcall(self.plugin_menu)
      if ok and sub and #sub > 0 then items[#items + 1] = { text = "Plugin: nodegraph", sub = sub } end
    end
    return self:open_menu(x, y, items, { search = true })
  end
  self:open_menu(x, y, items)
end

-- adding and deleting statements -----------------------------------------

-- what can be dropped from the menu: $names become free names
function NodeGraphView:exec_wire_at(x, y)
  if not self.g then return nil end
  local ox, oy = self:origin()
  for k = #self.g.exec, 1, -1 do
    local e = self.g.exec[k]
    local a, b = self.by_id[e.from], self.by_id[e.to]
    if not e.back and a.xouts[e.out] and b.xin and self:shown(a) ~= self:shown(b) then
      local x1, y1 = self:exec_xy(a, "out", e.out, ox, oy)
      local x2, y2 = self:exec_xy(b, "in", 1, ox, oy)
      local ym = e.wrap and x2 < x1 and self:wrap_y(b, oy) or nil
      if U.near_path(x, y, U.exec_path(x1, y1, x2, y2, ym, self.zoom * SCALE), 5 * SCALE) then return e end
    end
  end
end

-- delete nodes, UE style: what they're wired to is disconnected first.
--   a statement: its lines go; what reads the variables it declared reads nil;
--     the statements after it in its block lose their flow in: they float
--     (and stop running), where they were
--   an expression node in the flow: the pin it fed is left with nil
--   floating code: the whole block goes
function NodeGraphView:on_mouse_pressed(button, x, y, clicks)
  if self.menu then                                -- a menu is open: pick, or close it
    local it, m = self:menu_item_at(x, y)
    if it and it.sub and button == "left" then     -- a submenu: open it (it stays open)
      self:menu_hover(x, y)
      return true
    end
    if m and not it and button == "left" then return true end   -- a title: nothing
    if it and it.swatches and button == "left" then  -- a colour square
      local k = math.floor((x - m.x - 12 * SCALE) / (self.SWATCH_STEP * SCALE)) + 1
      if k < 1 or k > #it.swatches then return true end
      self.menu = nil
      core.redraw = true
      it.fn(it.swatches[k] or nil)
      return true
    end
    self.menu = nil
    core.redraw = true
    if button ~= "right" then                      -- left: that item (or nothing)
      if button == "left" and it and it.fn then it.fn() end
      return true
    end                                            -- right: close it, carry on (a new menu)
  end
  if not self.menu and self:changes_at(x, y) then   -- the list of changes (diff.lua)
    if button == "left" then self:changes_click(x, y) end
    return true
  end
  if button == "left" then                         -- the error / warning count (top-left): the next one
    for _, h in ipairs(self.status_hits or {}) do
      if x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then
        if h.kind == "changes" then                -- "N changes" (top-right): the list, open / closed
          if self.changes then self:close_changes() else self:open_changes() end
        elseif h.kind == "syntax" then self:goto_err()   -- the syntax error: its place
        elseif h.kind ~= "help" then self:next_issue(h.kind) end   -- (the (i): hovering is all)
        return true
      end
    end
  end
  local n = self:node_at(x, y)
  local e = self.editing
  if e then
    local b = self.edit_box
    local in_box = b and x >= b.x - 4 and x <= b.x + b.w and y >= b.y and y <= b.y + b.h
    if button == "left" and self.edit_box and (in_box or (not e.hex and not e.note and n == e.node)) then   -- in the box: lite places the caret, a drag selects
      if FIELD.mouse(e, "pressed", x, y, clicks) then self.edit_drag = true end
      core.redraw = true
      return true
    end
    self:cancel_edit()                             -- a click elsewhere: cancel
  end
  if button == "right" then                        -- pan on drag, menu on release
    self.rpress = { x = x, y = y, lx = x, ly = y, moved = false }
    return true
  end
  if button ~= "left" then return false end
  if self.picker then                              -- the colour picker: drag in it, or close it
    local box, sv, hue, al, hex = self:picker_rects()
    local function inr(r) return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h end
    if inr(hex) then                               -- type a colour: #rrggbb
      local t = self:picker_hex()
      self.editing = { node = self.picker.node, which = "hex", hex = true, field = { hex = true },
                       text = t, orig = t, cur = #t + 1, change_id = self.change_id,
                       src = self.doc:get_text(1, 1, math.huge, math.huge) }
      core.redraw = true
      return true
    end
    if inr(sv) or inr(hue) or inr(al) then
      local what = inr(sv) and "sv" or inr(hue) and "hue" or "alpha"
      self.press = { x = x, y = y, lx = x, ly = y, pick = what, moved = true }
      self:pick_at(what, x, y)
      return true
    end
    self.picker = nil
    core.redraw = true
    if inr(box) then return true end
  end
  local wg = not keymap.modkeys["alt"] and clicks == 1 and self:widget_at(x, y)
  if wg and wg.kind == "breakpoint" then           -- a breakpoint's dot: a click removes it (like the text's gutter)
    require("plugins.nodegraph.breaks").set(self.doc.filename, wg.line, false)
    return true
  end
  if wg and wg.kind == "chip" then                 -- a chip: drag a wire from its pin (rewire), or click: keep it lit
    self.press = { x = x, y = y, lx = x, ly = y, moved = false, dx = 0, dy = 0, chip = wg.decl,
                   sock = { node = wg.node, side = wg.side, i = wg.i, sock = wg.pin } }
    return true
  end
  if wg and wg.kind == "swatch" then               -- a colour: open the picker
    self:open_picker(wg)
    return true
  end
  if wg and wg.kind == "action" then               -- a button row
    local pin = wg.pin
    if pin.action == "addvar" then self:add_local_value(pin.stmt)
    elseif pin.action == "addret" then self:add_return_value(wg.node, nil)
    elseif pin.action == "addcat" then self:add_concat_operand(wg.node)
    elseif pin.action == "addparam" then self:add_param(pin.stmt)
    elseif pin.action == "add" then self:add_field_menu(wg.node, wg.x, wg.y + wg.h)
    elseif pin.action == "classfield" then self:add_class_field(wg.node, pin.cfield)
    elseif pin.action == "more" then self.expanded[pin.tpos] = true; self:rebuild()
    elseif pin.action == "less" then self.expanded[pin.tpos] = nil; self:rebuild() end
    core.redraw = true
    return true
  end
  if wg and wg.kind == "slider" then               -- a slider: the value under the mouse
    self.press = { x = x, y = y, lx = x, ly = y, slider = wg, moved = true }
    self.preview = { [wg.pos] = slider_value(wg, x) }
    return true
  end
  if wg and wg.kind == "enum" then                 -- a drop-down: its values in a menu
    local q = wg.text:sub(1, 1)
    local items = { { header = true, text = wg.pin.name } }
    for _, it in ipairs(wg.enum) do
      items[#items + 1] = { text = it, fn = function() self:set_literal(wg.pos, wg.epos, q .. it .. q) end }
    end
    self:open_menu(wg.x, wg.y + wg.h, items)
    return true
  end
  if wg and wg.kind == "bool" then                 -- a checkbox: toggle it
    self:set_literal(wg.pos, wg.epos, wg.text == "true" and "false" or "true")
    return true
  elseif wg and wg.kind == "num" then              -- a number: drag sideways to change it
    self.press = { x = x, y = y, lx = x, ly = y, numdrag = wg, moved = false }
    return true
  end
  local sk = self:socket_at(x, y)
  local chev = not sk and not keymap.modkeys["alt"] and self:chevron_at(x, y)
  self.chev_press = chev or nil                    -- the chevron: a click (no drag) folds / unfolds that node
  local rz, side
  if not sk and not self:node_at(x, y) and not self:note_chevron_at(x, y) then rz, side = self:note_edge_at(x, y) end   -- (its chevron: not an edge)
  if rz then                                       -- a comment's edge / corner: resize it (written on release)
    self.press = { x = x, y = y, lx = x, ly = y, resize = rz, side = side, moved = false,
                   x0 = rz.x, y0 = rz.y, w0 = rz.w, h0 = rz.h }
    return true
  end
  local nt = not sk and not self:node_at(x, y) and self:note_at(x, y)
  if nt then                                       -- a comment's headline: drag it (with its nodes) / rename it
    local nchev = self:note_chevron_at(x, y) == nt
    if clicks >= 2 and not nchev then self:rename_note(nt); return true end
    local inside = self:nodes_in_note(nt)
    self.press = { x = x, y = y, lx = x, ly = y, note = nt, roots = drag_roots(inside), moved = false, dx = 0, dy = 0,
                   note_chev = nchev or nil }   -- (its chevron: a click folds / unfolds it)
    return true
  end
  if keymap.modkeys["alt"] then                    -- ALT+LMB: disconnect
    if sk and sk.exec then                         -- a flow pin: take what follows out of the flow
      if sk.side == "in" then self:disconnect_exec(sk.node)
      else
        for _, e in ipairs(self.g.exec) do
          if not e.back and self.by_id[e.from] == sk.node and e.out == sk.i then return self:disconnect_exec(self.by_id[e.to]) or true end
        end
        self:flash("nothing is wired to it")
      end
      return true
    end
    local ch = not sk and self:widget_at(x, y)      -- a chip: like its socket (the pin reads nil; a header's: all its reads)
    if ch and ch.kind == "chip" then
      self:disconnect_socket({ node = ch.node, side = ch.side, i = ch.i, sock = ch.pin })
      return true
    end
    local ew = not sk and self:exec_wire_at(x, y)
    if ew then self:disconnect_exec(self.by_id[ew.to]); return true end
    if sk then self:disconnect_socket(sk)
    else
      local l = self:wire_at(x, y)
      if l then self:disconnect(pin_spans(self.by_id[l.to].ins[l.inp]), self.by_id[l.to].ins[l.inp].name)
      else self:flash("ALT+click a socket or a wire to unlink it") end
    end
    return true
  end
  if clicks >= 2 and n and not sk and not chev then   -- double-click: edit what is in that row
    self.press = nil
    self:begin_edit(n, self:row_at(n, y, x))
    return true
  end
  if clicks >= 2 and not sk then                   -- on the background: show it all
    self.press = nil
    self:fit()
    return true
  end
  self.press = { x = x, y = y, lx = x, ly = y, node = not sk and n or nil, sock = sk, moved = false, dx = 0, dy = 0,
                 box = not sk and not n, add = keymap.modkeys["shift"] or keymap.modkeys["ctrl"] }
  return true
end


-- move an element and everything hanging from it (live, while dragging)
function NodeGraphView:select(list, add)
  if not add then self.sel = {} end
  self.sel = self.sel or {}
  for _, n in ipairs(list) do self.sel[n] = true end
  self.selected = #list == 1 and list[1] or (add and self.selected or nil)   -- a box: no active one
  core.redraw = true
end

function NodeGraphView:selection()
  local l = {}
  for _, n in ipairs(self.g and self.g.nodes or {}) do if self.sel and self.sel[n] then l[#l + 1] = n end end
  return l
end

function NodeGraphView:on_mouse_moved(x, y, dx, dy)
  if self.edit_drag and self.editing then FIELD.mouse(self.editing, "moved", x, y) return end
  self.mx, self.my = x, y
  if not self.press and not self.menu and self:changes_hover(x, y) then self.cursor = "arrow"; return end   -- (the list of changes)
  if self.menu then                                -- the item under the mouse
    self:menu_hover(x, y)
    self.cursor = "arrow"
    return
  end
  local r = self.rpress
  if r then                                        -- RMB drag: pan
    if math.abs(x - r.x) + math.abs(y - r.y) > 4 then r.moved = true end
    if r.moved then
      self.pan.x, self.pan.y = self.pan.x + x - r.lx, self.pan.y + y - r.ly
      core.redraw = true
    end
    r.lx, r.ly = x, y
    return
  end
  local p = self.press
  if p then
    dx, dy = x - p.lx, y - p.ly                    -- from positions (relative motion can be 0)
    p.lx, p.ly = x, y
    local was = p.moved
    if math.abs(x - p.x) + math.abs(y - p.y) > 4 then p.moved = true end
    if p.pick then self:pick_at(p.pick, x, y); return end   -- the colour follows the mouse
    if p.slider then                               -- the slider follows the mouse
      self.preview = { [p.slider.pos] = slider_value(p.slider, x) }
      core.redraw = true
      return
    end
    if p.numdrag then                              -- the value follows the mouse (written on release)
      if p.moved then
        self.preview = { [p.numdrag.pos] = dragged_number(p.numdrag.text, x - p.x) }
        core.redraw = true
      end
      return
    end
    if p.sock and p.moved then p.snap = self:snap_socket(x, y, p.sock) end   -- (a pin near the mouse: the wire snaps to it)
    if p.sock or p.box then core.redraw = true; return end   -- a wire / the box follows the mouse
    if p.resize then                               -- a comment box's edge follows the mouse
      local nt, z, MIN_W, MIN_H = p.resize, self.zoom, 80, 50
      local ddx, ddy = (x - p.x) / z, (y - p.y) / z
      if p.side:find("r") then nt.w = math.max(MIN_W, p.w0 + ddx) end
      if p.side:find("b") then nt.h = math.max(MIN_H, p.h0 + ddy) end
      if p.side:find("l") then local w = math.max(MIN_W, p.w0 - ddx); nt.x, nt.w = p.x0 + p.w0 - w, w end
      if p.side:find("t") then local h = math.max(MIN_H, p.h0 - ddy); nt.y, nt.h = p.y0 + p.h0 - h, h end
      core.redraw = true
      return
    end
    if p.note then                                 -- a comment box and its nodes follow the mouse
      if p.moved then
        local z = self.zoom
        for _, it in ipairs(p.roots) do U.move_node(it[2], dx / z, dy / z) end
        p.note.x, p.note.y = p.note.x + dx / z, p.note.y + dy / z
        p.dx, p.dy = p.dx + dx / z, p.dy + dy / z
        core.redraw = true
      end
      return
    end
    local n = p.node
    if p.moved and n and movable(n) then
      if not was then                              -- the drag starts: what moves
        if not (self.sel and self.sel[n]) then self:select({ n }) end
        p.roots = drag_roots(self:selection())
      end
      local z = self.zoom                          -- in graph units
      for _, it in ipairs(p.roots) do U.move_node(it[2], dx / z, dy / z) end   -- written on release
      p.dx, p.dy = p.dx + dx / z, p.dy + dy / z
      core.redraw = true
    end
    return
  end
  local h = self:node_at(x, y)
  local sk = self:socket_at(x, y)
  if h ~= self.hover or (sk and sk.sock) ~= self.hover_sock then
    self.hover, self.hover_sock = h, sk and sk.sock
    core.redraw = true
  end
  local hh                                         -- over a title: its doc / warnings tooltip
  if h and not sk then
    local _, oy = self:origin()
    local top = oy + h.y * self.zoom
    if y >= top and y < top + h.head_h * self.zoom then hh = h end
  end
  if hh ~= self.hover_head then self.hover_head = hh; core.redraw = true end
  if hh and hh.doc then core.redraw = true end      -- (the tip follows the mouse)
  local hl = self:highlight_at(x, y, sk)           -- a hovered pin or wire: it, its wires, the pins at their ends
  if (hl and hl.key or nil) ~= (self.hl and self.hl.key or nil) then self.hl = hl; core.redraw = true end
  local wg = self:widget_at(x, y)
  local ha = wg and wg.kind == "action" and wg.pin or nil
  if ha ~= self.hover_action then self.hover_action = ha; core.redraw = true end
  local hd = wg and wg.kind == "chip" and wg.decl or nil
  self.hover_chip = wg and wg.kind == "chip" and wg or nil   -- (its value, from the probe: a tooltip)
  if hd ~= self.hover_decl then self.hover_decl, self.chip_tip = hd, wg and wg.kind == "chip" and wg.pin.chip_tip or nil; core.redraw = true end
  local _, edge = nil, nil
  if not h and not sk and not self:note_chevron_at(x, y) then _, edge = self:note_edge_at(x, y) end
  local hs                                         -- over the error / warning count: a link
  for _, s in ipairs(self.status_hits or {}) do
    if x >= s.x and x <= s.x + s.w and y >= s.y and y <= s.y + s.h then hs = s.kind end
  end
  if hs ~= self.hover_status then self.hover_status = hs; core.redraw = true end
  local ch = not sk and self:chevron_at(x, y)
  if ch ~= self.hover_chev then self.hover_chev = ch; core.redraw = true end
  local nch = not h and not sk and self:note_chevron_at(x, y) or nil
  if nch ~= self.hover_note_chev then self.hover_note_chev = nch; core.redraw = true end
  self.cursor = hs and "hand" or edge and (edge:find("[lr]") and "sizeh" or "sizev")
                or wg and (wg.kind == "num" or wg.kind == "slider") and "sizeh" or (h or sk or wg) and "hand" or "arrow"
end

function NodeGraphView:on_mouse_released(button, x, y)
  if self.edit_drag then
    self.edit_drag = nil
    if self.editing then FIELD.mouse(self.editing, "released", x, y) end
    return
  end
  if button == "right" then
    local r = self.rpress
    self.rpress = nil
    if r and not r.moved then self:context_menu(x, y) end
    return
  end
  local p = self.press
  self.press = nil
  local cp = self.chev_press
  self.chev_press = nil
  if not p then return end
  core.redraw = true
  if cp and not p.moved and p.node == cp then return self:toggle_collapse(cp) end
  if p.note_chev and not p.moved then return self:toggle_collapse(p.note) end
  if p.resize then                                -- a comment box resized: its tag
    local nt = p.resize
    local ddx, ddy = math.floor(nt.x - p.x0 + 0.5), math.floor(nt.y - p.y0 + 0.5)
    local w, h = math.floor(nt.w + 0.5), math.floor(nt.h + 0.5)
    if p.moved and (ddx ~= 0 or ddy ~= 0 or w ~= math.floor(p.w0 + 0.5) or h ~= math.floor(p.h0 + 0.5)) then
      self:write_tags({ { note = nt, nil, function(t)
        t.vals.dx = tostring((tonumber(t.vals.dx) or 0) + ddx)
        t.vals.dy = tostring((tonumber(t.vals.dy) or 0) + ddy)
        t.vals.w, t.vals.h = tostring(w), tostring(h)
      end } })
    end
    return
  end
  if p.slider then                                -- a slider: write its value
    local pv = self.preview and self.preview[p.slider.pos]
    self.preview = nil
    if pv and pv ~= p.slider.text then self:set_literal(p.slider.pos, p.slider.epos, pv) end
    return
  end
  if p.numdrag then                               -- a number dragged: write it
    local pv = self.preview and self.preview[p.numdrag.pos]
    self.preview = nil
    if p.moved and pv and pv ~= p.numdrag.text then self:set_literal(p.numdrag.pos, p.numdrag.epos, pv) end
    return
  end
  if p.pick then                                  -- the colour picker: write its parts
    local pv = self.preview
    self.preview = nil
    local pk = self.picker
    if pk and pv then
      local edits = {}
      for _, c in ipairs(pk.comps) do
        if pv[c.pos] and pv[c.pos] ~= c.text then edits[#edits + 1] = { pos = c.pos, epos = c.epos, text = pv[c.pos] } end
      end
      if #edits > 0 and self.doc:get_change_id() == self.change_id then
        local src = self.doc:get_text(1, 1, math.huge, math.huge)
        self:apply_edits(src, edits)
      end
    end
    return                                         -- (the picker stays: rebuild finds its colour again)
  end
  if p.chip and not p.moved then                  -- a chip clicked: its variable stays lit (again: off)
    self.lit_decl = self.lit_decl ~= p.chip and p.chip or nil
    return
  end
  if p.sock then                                  -- a wire dropped: rewire
    if p.moved then self:connect(p.sock, self:snap_socket(x, y, p.sock) or self:socket_at(x, y), self:node_at(x, y), x, y) end
    return
  end
  if p.box then                                   -- the box: select what it touches
    if not p.moved then self.lit_decl = nil; return self:select({}, p.add) end   -- (a lit chip goes dark too)
    local z = self.zoom
    local ox, oy = self:origin()
    local x1, y1 = (math.min(p.x, x) - ox) / z, (math.min(p.y, y) - oy) / z
    local x2, y2 = (math.max(p.x, x) - ox) / z, (math.max(p.y, y) - oy) / z
    local l = {}
    for _, n in ipairs(self.g and self.g.nodes or {}) do
      if not n.hidden and n.x < x2 and n.x + n.w > x1 and n.y < y2 and n.y + n.h > y1 then l[#l + 1] = n end
    end
    self:select(l, p.add)
    if #l > 0 then self:flash(#self:selection() .. " selected") end
    return
  end
  if not p.moved then                             -- a click: select it (shift / ctrl: toggle)
    local n = p.node
    if p.add and n then
      self.sel = self.sel or {}
      if self.sel[n] then self.sel[n] = nil; if self.selected == n then self.selected = nil end
      else self.sel[n] = true; self.selected = n end
    else
      self:select({ n })
    end
    if n and n.line and not self.editing then self:goto_line(n.line, true) end
  elseif p.roots and (p.dx ~= 0 or p.dy ~= 0) then  -- a drag: keep it, as offsets in the tags
    if p.note then                                 -- (a comment box moves too)
      local ddx, ddy = math.floor(p.dx + 0.5), math.floor(p.dy + 0.5)
      local list = { { note = p.note, nil, function(t)
        t.vals.dx = tostring((tonumber(t.vals.dx) or 0) + ddx)
        t.vals.dy = tostring((tonumber(t.vals.dy) or 0) + ddy)
      end } }
      for _, it in ipairs(p.roots) do
        list[#list + 1] = { it[1], function(t)
          local nx, ny = (tonumber(t.vals.dx) or 0) + ddx, (tonumber(t.vals.dy) or 0) + ddy
          self.set_val(t, "dx", nx ~= 0 and tostring(nx) or nil)
          self.set_val(t, "dy", ny ~= 0 and tostring(ny) or nil)
        end }
      end
      self:write_tags(list)
      return
    end
    local ddx, ddy = math.floor(p.dx + 0.5), math.floor(p.dy + 0.5)
    local list = {}
    for _, it in ipairs(p.roots) do
      list[#list + 1] = { it[1], function(t)
        local nx = (tonumber(t.vals.dx) or 0) + ddx
        local ny = (tonumber(t.vals.dy) or 0) + ddy
        self.set_val(t, "dx", nx ~= 0 and tostring(nx) or nil)
        self.set_val(t, "dy", ny ~= 0 and tostring(ny) or nil)
      end }
    end
    self:write_tags(list)
  end
end

-- arrows: move the selection on the grid. The pivot (the selection's top-left
-- corner) first snaps to the grid in that direction, then moves a cell a press.
local function nudging()
  local v = core.active_view
  return v and v:is(NodeGraphView) and not v.editing and not v.menu and v.sel and next(v.sel) ~= nil
end
command.add(nudging, {
  ["nodegraph:delete-selection"] = function()
    local v = core.active_view
    v:delete_nodes(v:selection())
  end,
  ["nodegraph:nudge-left"]  = function() core.active_view:nudge(-1, 0) end,
  ["nodegraph:nudge-right"] = function() core.active_view:nudge(1, 0) end,
  ["nodegraph:nudge-up"]    = function() core.active_view:nudge(0, -1) end,
  ["nodegraph:nudge-down"]  = function() core.active_view:nudge(0, 1) end,
})
local function in_graph()                          -- the graph has the keys (and isn't editing a field)
  local v = core.active_view
  return v and v:is(NodeGraphView) and not v.editing
end
command.add(in_graph, {
  ["nodegraph:undo"] = function() core.active_view.doc:undo() end,
  ["nodegraph:redo"] = function() core.active_view.doc:redo() end,
  ["nodegraph:paste"] = function()                 -- under the mouse (else the middle of the view)
    local v = core.active_view
    local mx, my = v.mx, v.my
    if not (mx and mx >= v.position.x and mx <= v.position.x + v.size.x and my >= v.position.y and my <= v.position.y + v.size.y) then
      mx, my = v.position.x + v.size.x / 2, v.position.y + v.size.y / 2
    end
    local ox, oy = v:origin()
    v:paste((mx - ox) / v.zoom, (my - oy) / v.zoom)
  end,
})
-- the Add menu's search box: type to filter; up / down choose, enter adds it,
-- backspace erases (ctrl+backspace: all)
local function searching()
  local v = core.active_view
  return v and v:is(NodeGraphView) and not v.editing and v.menu and v.menu.search ~= nil
end
local function menu_step(m, d) CM.step(m, d); if m.find then core.active_view:find_follow() end end
local function menu_jump(m, to) CM.jump(m, to); if m.find then core.active_view:find_follow() end end
local function page(m) return math.max(1, m.rows - 1) end
command.add(searching, {
  ["nodegraph:menu-page-down"] = function() local m = core.active_view.menu; menu_jump(m, (m.hot or 0) + page(m)) end,
  ["nodegraph:menu-page-up"] = function() local m = core.active_view.menu; menu_jump(m, (m.hot or 1) - page(m)) end,
  ["nodegraph:menu-first"] = function() menu_jump(core.active_view.menu, 1) end,
  ["nodegraph:menu-last"] = function() local m = core.active_view.menu; menu_jump(m, #m.items) end,
  ["nodegraph:menu-backspace"] = function() local v = core.active_view; CM.erase(v.menu, v:menu_bounds()); v:refilter_menu() end,
  ["nodegraph:menu-clear"] = function() local v = core.active_view; CM.erase(v.menu, v:menu_bounds(), true); v:refilter_menu() end,
  ["nodegraph:menu-down"] = function() menu_step(core.active_view.menu, 1) end,
  ["nodegraph:menu-up"] = function() menu_step(core.active_view.menu, -1) end,
  ["nodegraph:menu-pick"] = function()
    local v = core.active_view
    local m = v.menu
    local it = m.hot and m.items[m.hot]
    if it and it.sub then return menu_step(m, 1) end
    if it and it.fn then v.menu = nil; core.redraw = true; it.fn() end
  end,
})
keymap.add {
  ["down"] = "nodegraph:menu-down", ["up"] = "nodegraph:menu-up",
  ["return"] = "nodegraph:menu-pick", ["keypad enter"] = "nodegraph:menu-pick",
  ["pagedown"] = "nodegraph:menu-page-down", ["pageup"] = "nodegraph:menu-page-up",
  ["home"] = "nodegraph:menu-first", ["end"] = "nodegraph:menu-last",
}

-- ctrl+a: select every node (again, with all of them selected: none);
-- ctrl+shift+a or ctrl+d: select none (Illustrator / GIMP, Photoshop).
command.add(in_graph, {
  ["nodegraph:select-all"] = function()
    local v = core.active_view
    local all = v.g and v.g.nodes or {}
    if #all > 0 and #v:selection() == #all then
      v:select({})
      v:flash("selection cleared")
    else
      v:select(all)
      v:flash(#all .. " selected")
    end
  end,
  ["nodegraph:select-none"] = function()
    local v = core.active_view
    if #v:selection() > 0 then v:select({}); v:flash("selection cleared") end
  end,
})
keymap.add { ["ctrl+a"] = "nodegraph:select-all", ["ctrl+shift+a"] = "nodegraph:select-none", ["ctrl+d"] = "nodegraph:select-none" }
command.add(function()                             -- (also while a menu is open: ctrl+f again closes find)
  local v = core.active_view
  return v and v:is(NodeGraphView) and not v.editing
end, {
  ["nodegraph:find"] = function()
    local v = core.active_view
    if v.menu and v.menu.find then v.menu = nil; core.redraw = true; return end
    v.menu = nil
    v:open_find()
  end,
})
keymap.add { ["ctrl+f"] = "nodegraph:find" }
command.add(function()
  local v = core.active_view
  return v and v:is(NodeGraphView) and not v.editing
end, {
  ["nodegraph:find-next"] = function()             -- (with the box open: the next result)
    local v = core.active_view
    if v.menu and v.menu.find then return menu_step(v.menu, 1) end
    v.menu = nil
    v:find_again(1)
  end,
  ["nodegraph:find-previous"] = function()
    local v = core.active_view
    if v.menu and v.menu.find then return menu_step(v.menu, -1) end
    v.menu = nil
    v:find_again(-1)
  end,
  ["nodegraph:save"] = function()                  -- ctrl+s in the graph: the file (undo still works after)
    local v = core.active_view
    v.doc:save()
    core.log("Saved \"%s\"", v.doc.filename)
    v:flash("saved")
  end,
})
command.add(in_graph, { ["nodegraph:go-back"] = function() core.active_view:go_back() end })
keymap.add { ["f3"] = "nodegraph:find-next", ["shift+f3"] = "nodegraph:find-previous", ["ctrl+s"] = "nodegraph:save",
             ["alt+up"] = "nodegraph:go-back" }
keymap.add { ["alt+left"] = "nodegraph:go-back" }   -- (alt+up too; added last: the one shown as its key)
command.add(nudging, {
  ["nodegraph:copy"] = function() core.active_view:copy_selection() end,
  ["nodegraph:cut"] = function() core.active_view:cut_selection() end,
})
keymap.add {
  ["ctrl+z"] = "nodegraph:undo", ["ctrl+shift+z"] = "nodegraph:redo",
  ["ctrl+c"] = "nodegraph:copy", ["ctrl+x"] = "nodegraph:cut", ["ctrl+v"] = "nodegraph:paste",
}
keymap.add { ["ctrl+y"] = "nodegraph:redo" }       -- (ctrl+shift+z too; added last: the one shown as its key)
keymap.add {
  ["delete"] = "nodegraph:delete-selection",
  ["left"] = "nodegraph:nudge-left", ["right"] = "nodegraph:nudge-right",
  ["up"] = "nodegraph:nudge-up", ["down"] = "nodegraph:nudge-down",
}

-- nothing selected: the keys scroll the camera, arrows 20% of the view,
-- page up / down 75% vertically, home / end 75% sideways
local function scrolling()
  local v = core.active_view
  return v and v:is(NodeGraphView) and not v.editing and not v.menu and not (v.sel and next(v.sel) ~= nil)
end
local SMALL, BIG = 0.20, 0.75
command.add(scrolling, {
  ["nodegraph:scroll-left"]  = function() core.active_view:scroll_by(-SMALL, 0) end,
  ["nodegraph:scroll-right"] = function() core.active_view:scroll_by(SMALL, 0) end,
  ["nodegraph:scroll-up"]    = function() core.active_view:scroll_by(0, -SMALL) end,
  ["nodegraph:scroll-down"]  = function() core.active_view:scroll_by(0, SMALL) end,
  ["nodegraph:page-up"]      = function() core.active_view:scroll_by(0, -BIG) end,
  ["nodegraph:page-down"]    = function() core.active_view:scroll_by(0, BIG) end,
  ["nodegraph:page-left"]    = function() core.active_view:scroll_by(-BIG, 0) end,
  ["nodegraph:page-right"]   = function() core.active_view:scroll_by(BIG, 0) end,
})
keymap.add {
  ["left"] = "nodegraph:scroll-left", ["right"] = "nodegraph:scroll-right",
  ["up"] = "nodegraph:scroll-up", ["down"] = "nodegraph:scroll-down",
  ["pageup"] = "nodegraph:page-up", ["pagedown"] = "nodegraph:page-down",
  ["home"] = "nodegraph:page-left", ["end"] = "nodegraph:page-right",
}

-- wheel: scroll; shift+wheel or a horizontal wheel (x): sideways; ctrl+wheel: zoom
function NodeGraphView:on_mouse_wheel(y, x)
  local step = 60 * SCALE
  if self.menu then                                -- a long menu scrolls
    local m = self:menu_at(self.mx or 0, self.my or 0)
    if m and #m.items > m.rows and y and y ~= 0 then
      m.scroll = math.max(0, math.min(#m.items - m.rows, m.scroll - (y > 0 and 3 or -3)))
      m.child, m.hot = nil, nil
      core.redraw = true
    end
    return
  end
  if keymap.modkeys["ctrl"] then
    if y ~= 0 then self:zoom_at(y > 0 and 1.1 or 1 / 1.1, self.mx, self.my) end
    return
  end
  if keymap.modkeys["shift"] then
    self.pan.x = self.pan.x + y * step
  else
    self.pan.y = self.pan.y + y * step
  end
  if type(x) == "number" and x ~= 0 then self.pan.x = self.pan.x - x * step end
  core.redraw = true
end

-- like DocView:scroll_to_line (other plugins call it on the active view):
-- select the node of that line and bring it into view
function NodeGraphView:widget_at(x, y)
  for i = #(self.hits or {}), 1, -1 do
    local h = self.hits[i]
    if x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then return h end
  end
end

-- write a literal (a widget's value) in place
function NodeGraphView:add_field_menu(n, x, y)
  local items = { { header = true, text = "Add field" } }
  for _, ft in ipairs(self.FIELD_TYPES) do
    items[#items + 1] = { text = ft.name, fn = function() self:add_field(n, ft) end }
  end
  self:open_menu(x, y, items)
end

-- a field's value replaced by the start value of another type (a colour also
-- renames a key without "color" in it, so it shows as one)

function NodeGraphView:open_picker(hit)
  local r, g, b = hit.rgb[1] / 255, hit.rgb[2] / 255, hit.rgb[3] / 255
  local h, sat, v = rgb2hsv(r, g, b)
  local comps = hit.comps or hit.pin.comps         -- (a "#rrggbb" string: one part, the whole literal)
  local c4 = not hit.hexstr and comps[4]
  local a = hit.hexstr and hit.alpha or (c4 and (tonumber(c4.text) or 0) / (hit.unit and 1 or 255)) or nil
  self.picker = { pin = hit.pin, comps = comps, hexstr = hit.hexstr, unit = hit.unit, h = h, s = sat, v = v, a = a,
                  x = hit.x, y = hit.y + hit.h + 4 * SCALE, pos0 = comps[1].pos }
  core.redraw = true
end

-- box, saturation/value square, hue bar, alpha bar (with 4 parts), hex row: the shared picker's (plugins/canvas/picker.lua)
local CPICK = require "plugins.canvas.picker"
function NodeGraphView:picker_rects() return CPICK.rects(self.picker) end
function NodeGraphView:picker_hex() return CPICK.hex(self.picker) end

-- the picker's point at (x, y) -> h / s / v, and the preview of the parts
function NodeGraphView:pick_at(what, x, y)
  CPICK.pick_at(self.picker, what, x, y)
  self:picker_preview()
end

function NodeGraphView:picker_preview()
  local pk = self.picker
  local r, g, b = hsv2rgb(pk.h, pk.s, pk.v)
  local pv = {}
  local function byte(v) return math.floor(v * 255 + 0.5) end
  if pk.hexstr then                                -- the string, as "#rrggbb" (+ aa when it had alpha)
    pv[pk.comps[1].pos] = pk.hexstr .. string.format("#%02x%02x%02x", byte(r), byte(g), byte(b))
                          .. (pk.a and string.format("%02x", byte(pk.a)) or "") .. pk.hexstr
  else
    for k, c in ipairs(pk.comps) do
      local v = ({ r, g, b, pk.a })[k]
      if v then pv[c.pos] = pk.unit and string.format("%.2f", v) or tostring(byte(v)) end
    end
  end
  self.preview = pv
  core.redraw = true
end

-- a comment box's edge or corner under the mouse (to resize it): the note,
-- and which sides move ("l"/"r", "t"/"b": "rb" is the bottom-right corner)
function NodeGraphView:note_edge_at(x, y)
  local m = 6 * SCALE
  for i = #(self.note_hits or {}), 1, -1 do
    local h = self.note_hits[i]
    local x2, y2 = h.x + h.w, h.y + h.bh
    if not h.note.collapsed and x >= h.x - m and x <= x2 + m and y >= h.y - m and y <= y2 + m then
      local side = (math.abs(x - h.x) <= m and "l" or math.abs(x - x2) <= m and "r" or "")
                .. (math.abs(y - h.y) <= m and "t" or math.abs(y - y2) <= 2 * m and "b" or "")
      if side ~= "" and (x2 - x <= 2 * m and y2 - y <= 2 * m) then side = "rb" end   -- (the grip)
      if side ~= "" then return h.note, side end
    end
  end
end

-- a click on "N errors" / "N warnings" (top-left): the view glides to the
-- next node with one (in the order of the text, around again after the
-- last), selects it and says what it is: "warning 2/6 (line 150): ..."
function NodeGraphView:next_issue(kind)
  local list = {}
  if kind == "breakpoint" then                     -- (the breakpoints: their nodes)
    local B = require "plugins.nodegraph.breaks"
    for _, l in ipairs(B.lines(self.doc.filename)) do local n = self:line_node(l); if n then list[#list + 1] = n end end
  end
  for _, n in ipairs(self.g and self.g.nodes or {}) do
    if kind == "error" and n.has_error or kind == "warning" and n.warns then list[#list + 1] = n end
  end
  if #list == 0 then return end
  table.sort(list, function(a, b)
    if (a.line or 0) ~= (b.line or 0) then return (a.line or 0) < (b.line or 0) end
    return a.id < b.id
  end)
  self.issue_at = self.issue_at or {}
  local last = self.issue_at[kind]
  local k = 1
  if last then                                     -- the one after the last shown (by line: survives a rebuild)
    for i, n in ipairs(list) do
      if (n.line or 0) > last.line or ((n.line or 0) == last.line and n.id > last.id) then k = i; break end
      if i == #list then k = 1 end
    end
  end
  local n = list[k]
  self.issue_at[kind] = { line = n.line or 0, id = n.id }
  if self.zoom < 0.8 then                          -- (far out: close enough to read it)
    local cx, cy = self.size.x / 2, self.size.y / 2
    self.pan.x = cx - (cx - self.pan.x) / self.zoom
    self.pan.y = cy - (cy - self.pan.y) / self.zoom
    self.zoom = 1
  end
  self:glide_to(n)
  local msgs = {}
  for _, d in ipairs(n.diags) do if (d.level == "warning") == (kind == "warning") then msgs[#msgs + 1] = d.msg end end
  if kind == "breakpoint" then msgs = { n.title } end
  if #msgs == 0 then msgs = n.warns or { "?" } end
  local m = msgs[1]
  self:flash(string.format("%s %d/%d%s: %s%s", kind, k, #list, n.line and (" (line " .. n.line .. ")") or "",
                           type(m) == "table" and m.msg or tostring(m), #msgs > 1 and string.format("  (+%d more)", #msgs - 1) or "")
             .. (n.hidden and "   (inside something folded)" or ""))
end
function NodeGraphView:note_chevron_at(x, y)     -- a comment box's chevron under the mouse: its box
  for i = #(self.note_hits or {}), 1, -1 do
    local h = self.note_hits[i]
    if x >= h.x and x <= h.x + h.chev_w + 4 * SCALE and y >= h.y and y <= h.y + h.h then return h.note end
  end
end
function NodeGraphView:note_at(x, y)
  for i = #(self.note_hits or {}), 1, -1 do
    local h = self.note_hits[i]
    if x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then return h.note end
  end
end

-- the popup menu (RMB)

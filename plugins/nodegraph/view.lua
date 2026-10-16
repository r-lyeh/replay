
-- view.lua - NodeGraphView: a lite tab that shows a Lua file as a node graph.
-- Part of the nodegraph plugin (ours, not upstream lite). Step 1: read-only.
--
-- The graph is another view of the same document: it is rebuilt whenever the
-- text changes (typing, undo, reload from disk). Drag the background to pan,
-- wheel to scroll; hover a node to see where its values come from and go
-- (data wires); click it to jump to its line in the text.
-- Step 2: drag a node (or a function's header) to move it; right-click it
-- to change its colour. Both are written into the source as --@node /
-- --@frame comments (see graph.lua), through the document: undo works.
-- Step 3: click a node to select it (the text view follows); double-click
-- its expressions (or the title of a "set": its targets) to edit them in
-- place. Enter applies, a click elsewhere cancels. The edit replaces only
-- that span of text, and only if the whole file still parses.
-- Step 4: double-click the title of a node that declares names (a local, a
-- loop, a function's header) to rename them: every use follows, and the
-- edit is refused if a name would capture or be captured by another.
-- Style (Blender-like): inputs are sockets on a node's left, the variables it
-- declares are sockets on its right, joined by wires. Drag from an input to
-- an output (or the other way) to make that input read that variable (rewire).
-- Mouse: LMB selects, drags nodes, drags wires between sockets; ALT+LMB on a
-- socket or wire disconnects it (its reads become nil); RMB+drag pans; RMB
-- opens a menu: add a statement there (background) or colour / delete (node).
-- Arrow keys move the selection on the grid.
-- Navigation: wheel scrolls (shift+wheel or a horizontal wheel: sideways),
-- ctrl+wheel zooms the graph around the mouse (the graph has its own fonts,
-- so lite's own zoom doesn't change it). Double-click the background to see
-- the whole graph; it can't be scrolled out of sight.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"
local luaparse = require "plugins.nodegraph.luaparse"
local graph = require "plugins.nodegraph.graph"
local resolve = require "plugins.nodegraph.resolve"

local NodeGraphView = require "plugins.nodegraph.class"
local T = require "plugins.nodegraph.theme"
local U = require "plugins.nodegraph.util"
local C, rgb, alpha = T.C, T.rgb, T.alpha

-- the graph's fonts: its own, at its zoom (lite's style fonts follow lite's zoom)
local FONT_FILE, CODE_FILE = DATADIR .. "/data/fonts/font.ttf", DATADIR .. "/data/fonts/monospace.ttf"
local font_cache = {}
local function font_at(file, size)
  size = math.max(4, math.floor(size * 2 + 0.5) / 2)
  local k = file .. "@" .. size
  if not font_cache[k] then font_cache[k] = renderer.font.load(file, size) end
  return font_cache[k]
end
local BASE_FONT, BASE_CODE = 14 * SCALE, 13.5 * SCALE
local ZMIN = 0.1                                   -- (the most: T.cfg.zoom_max, config.lua)

-- Blender's node editor, more or less (fixed colours: a node editor, not a text theme)
function NodeGraphView:new(doc)
  NodeGraphView.super.new(self)
  self.cursor = "arrow"
  self.pan = { x = 40 * SCALE, y = 60 * SCALE }
  self.zoom = 1
  self.expanded = {}                               -- big tables shown whole (table position -> true)
  self.mx, self.my = 0, 0
  if type(doc) == "table" and doc.filename and not doc.get_text then   -- workspace state
    local state = doc
    local ok, d = pcall(core.open_doc, state.filename)
    doc = ok and d or nil
    if state.pan then self.pan = { x = state.pan[1], y = state.pan[2] }; self.restored = true end
    if state.zoom then self.zoom = math.max(ZMIN, math.min(T.cfg.zoom_max, state.zoom)) end
    for _, k in ipairs(state.collapsed or {}) do self.collapsed = self.collapsed or {}; self.collapsed[k] = true end
    for _, l in ipairs(state.breaks or {}) do require("plugins.nodegraph.breaks").set(state.filename, l, true) end
    self.pins = {}
    for _, p in ipairs(state.pins or {}) do
      if type(p) == "table" and p.name then self.pins[#self.pins + 1] = { name = p.name, line = p.line or 1, color = p.color } end
    end
  end
  self.collapsed = self.collapsed or {}            -- collapsed nodes, by collapse_key (kept in the workspace)
  self.pins = self.pins or {}                      -- pinned references: { name, line, color, decl, nodes } (kept too)
  self.back = {}                                   -- where "go to definition" came from (go back)
  self.doc = doc
  self.err = doc == nil and "no file" or nil
end

-- API definitions for pin names: runtime/meta/*.lua (LuaLS ---@meta stubs:
-- dd.lua, lua.lua...), read again when one of them changes
local ROOT = rawget(_G, "REPLAY_ROOT") or (DATADIR .. "/../../..")   -- (the repo: Lite is in editor/3rd/lite)
local META_DIR = ROOT .. "/runtime/meta"
local meta_cache, meta_stamp
function NodeGraphView.api()
  local files = system.list_dir(META_DIR) or {}
  table.sort(files)
  local stamp = {}
  for _, f in ipairs(files) do
    if f:match("%.lua$") then
      local info = system.get_file_info(META_DIR .. "/" .. f)
      stamp[#stamp + 1] = f .. "@" .. tostring(info and info.modified)
    end
  end
  stamp = table.concat(stamp, ";")
  if stamp ~= meta_stamp then
    meta_cache, meta_stamp = {}, stamp
    for _, f in ipairs(files) do
      local fh = f:match("%.lua$") and io.open(META_DIR .. "/" .. f, "rb")
      if fh then
        graph.read_meta(fh:read("*a"), luaparse.parse, meta_cache); fh:close()
        for _, e in pairs(meta_cache) do e.file = e.file or (META_DIR .. "/" .. f) end   -- (go to definition)
      end
    end
  end
  return meta_cache
end

-- modules, for call pins: the engine's (runtime/*.lua: their classes, e.g.
-- World:query) and the ones a file requires (recursively). Read again when
-- they change. `local ecs = require("ecs")` makes ecs.world() known, and
-- what it returns (a World): w:spawn(path, components)...
local RUNTIME_DIR = ROOT .. "/runtime"
local mod_cache = {}
local function read_module(path)
  local fi = system.get_file_info(path)
  if not fi then return nil end
  local c = mod_cache[path]
  if c and c.stamp == fi.modified then return c end
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local src = fh:read("*a")
  fh:close()
  local entries, info = graph.read_meta(src, luaparse.parse, {})
  for _, e in pairs(entries) do e.file = path end   -- (go to definition: its file, its line)
  c = { stamp = fi.modified, entries = entries, info = info }
  mod_cache[path] = c
  return c
end
local function find_module(name, dirs)
  local rel = name:gsub("%.", "/")
  for _, d in ipairs(dirs) do
    for _, p in ipairs({ d .. "/" .. rel .. ".lua", d .. "/" .. rel .. "/init.lua" }) do
      if system.get_file_info(p) then return p end
    end
  end
end
function NodeGraphView.api_for(ast, filedir)
  local api, methods = {}, {}
  for k, v in pairs(NodeGraphView.api()) do api[k] = v end
  local function add_classes(m) graph.add_module(api, methods, m.entries, m.info) end
  for _, f in ipairs(system.list_dir(RUNTIME_DIR) or {}) do   -- the engine's modules: their classes
    if f:match("%.lua$") then
      local m = read_module(RUNTIME_DIR .. "/" .. f)
      if m then add_classes(m) end
    end
  end
  local dirs, seen = { filedir or ".", ".", RUNTIME_DIR }, {}
  local function add_require(alias, name, depth)
    local path = find_module(name, dirs)
    local key = path and (path .. "@" .. tostring(alias))
    if not path or seen[key] then return end
    seen[key] = true
    local m = read_module(path)
    if not m then return end
    graph.add_module(api, methods, m.entries, m.info, alias)   -- its functions, by the name the file gave it
    if depth < 4 then for _, r in ipairs(m.info.requires) do add_require(nil, r.name, depth + 1) end end
  end
  for _, s in ipairs(ast.body.stmts) do            -- the file's own requires
    if s.tag == "Local" then
      for k, e in ipairs(s.exprs) do
        if e.tag == "Call" and e.fn.tag == "Id" and e.fn.name == "require" and e.args[1] and e.args[1].tag == "String" then
          add_require(s.names[k], e.args[1].raw:sub(2, -2), 0)
        end
      end
    end
  end
  return api, methods
end

-- closing the last view of a changed file asks first, like a text tab
function NodeGraphView:try_close(do_close)
  if self.doc and #core.get_views_referencing_doc(self.doc) == 1 then
    return DocView.try_close(self, do_close)
  end
  do_close()
end

function NodeGraphView:get_name()
  local name = self.doc and self.doc.filename and self.doc.filename:match("[^/\\]*$") or "?"
  return "graph: " .. name .. (self.doc and self.doc:is_dirty() and "*" or "")
end

-- what the workspace plugin keeps for this tab (restored by NodeGraphView(state))
function NodeGraphView:get_state()
  if not (self.doc and self.doc.filename) then return nil end
  local col = {}
  for k in pairs(self.collapsed or {}) do col[#col + 1] = k end
  table.sort(col)
  local pins = {}
  for _, p in ipairs(self.pins or {}) do pins[#pins + 1] = { name = p.name, line = p.line, color = p.color } end
  local br = require("plugins.nodegraph.breaks").lines(self.doc.filename)
  return { filename = self.doc.filename, pan = { self.pan.x, self.pan.y }, zoom = self.zoom,
           collapsed = #col > 0 and col or nil, pins = #pins > 0 and pins or nil,
           breaks = #br > 0 and br or nil }
end

-- a statement outside every function runs once, when the file loads (the
-- world's systems run every frame; only their code can be stopped at)
local function above(n)                            -- (a function's header: from around its own frame)
  if n.kind == "function" and n.frame then return n.frame.parent end
  return n.parent
end
function NodeGraphView.at_load(n)
  local e = above(n)
  while e do
    if e.func then return false end
    e = e.parent
  end
  return true
end
NodeGraphView.AT_LOAD_NOTE = "this line runs when its file loads: it stops at Play / Rewind (the file runs again then)"
NodeGraphView.AT_BOOT_NOTE = "the main script's top level: it stops at Play / Rewind (it runs again then, a dry run: the game keeps the edited world)"
-- the world's main script (host_world_file): its top level runs again at Play / Rewind
function NodeGraphView.is_root(filename)
  local hf = rawget(_G, "host_world_file")
  local f = hf and hf()
  return f and filename and require("plugins.nodegraph.breaks").same(f, filename) or false
end
function NodeGraphView:wont_stop(n)                -- (none now: a file's top level runs again at Play / Rewind, and stops there)
  return false
end
NodeGraphView.AT_SETUP_NOTE = "a system's setup: it stops when the system is built (the first frame after Play / Rewind, or after an edit of it)"

-- the functions given to ecs.system(...) (a system: its setup, then its run function)
function NodeGraphView.factories(ast)
  local set = {}
  local function walk(e)
    if type(e) ~= "table" then return end
    if e.tag == "Call" and e.fn and e.fn.tag == "Index" and e.fn.name == "system" and e.args[1] and e.args[1].tag == "Function" then
      set[e.args[1].pos] = true
    end
    for _, v in pairs(e) do if type(v) == "table" then walk(v) end end
  end
  walk(ast)
  return set
end

-- a statement in a system's setup (in ecs.system's function, not in a function inside it)
function NodeGraphView:at_setup(n)
  local e = above(n)
  while e and not e.func do e = e.parent end
  if not (e and self.ast) then return false end
  if not self.factory_set or self.factory_ast ~= self.ast then
    self.factory_set, self.factory_ast = NodeGraphView.factories(self.ast), self.ast
  end
  return self.factory_set[e.func.pos] == true
end

-- a folder world's classes (graph.lua: M.folder_classes), read with lite's system
local LITE_FS = {
  list = function(dir) return system.list_dir(dir) end,
  is_dir = function(p) local i = system.get_file_info(p) return i and i.type == "dir" end,
}
function NodeGraphView.world_classes(filename) return graph.folder_classes(filename, LITE_FS) end

-- the graph of another text of this file (diff.lua: an earlier state), laid
-- out like this one; nil if it doesn't parse
function NodeGraphView:build_of(src)
  local ast = luaparse.parse(src)
  if not ast then return nil end
  local res = resolve.resolve(ast)
  local filedir = self.doc.filename and self.doc.filename:match("^(.*)[/\\][^/\\]*$") or "."
  local api, api_methods = NodeGraphView.api_for(ast, filedir)
  local ok, g = pcall(graph.build, ast, { font = font_at(FONT_FILE, BASE_FONT), code_font = font_at(CODE_FILE, BASE_CODE), res = res,
                                          expanded = self.expanded, parse = luaparse.parse, resolve = resolve.resolve,
                                          grid = math.floor(self.GRID * SCALE + 0.5), api = api, api_methods = api_methods,
                                          warn_rows = self.warn_rows, world_classes = NodeGraphView.world_classes(self.doc.filename),
                                          file_kind = (graph.file_info(self.doc.filename)), file_desc = select(2, graph.file_info(self.doc.filename)) })
  return ok and g or nil
end

function NodeGraphView:rebuild()
  self.change_id = self.doc:get_change_id()
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  if self.doc.filename and self.doc.filename:match("%.hurdy$") then
    self.err = "hurdy files: not yet (Lua only for now)"
    return
  end
  local ast, err = luaparse.parse(src)
  if not ast then                                  -- keep showing the last good graph
    self.err, self.err_line = err, tonumber(tostring(err):match("^line (%d+)"))   -- (its node: err_node)
    return
  end
  local res = resolve.resolve(ast)                 -- names -> declarations (sockets, rewire)
  local filedir = self.doc.filename and self.doc.filename:match("^(.*)[/\\][^/\\]*$") or "."
  local api, api_methods = NodeGraphView.api_for(ast, filedir)   -- dd.text(x, y, text, color), w:query...: pin names
  local wclasses = NodeGraphView.world_classes(self.doc.filename)
  local fkind, fdesc = graph.file_info(self.doc.filename)
  local function build()
    return pcall(graph.build, ast, { font = font_at(FONT_FILE, BASE_FONT), code_font = font_at(CODE_FILE, BASE_CODE), res = res,
                                     expanded = self.expanded, parse = luaparse.parse, resolve = resolve.resolve,
                                     grid = math.floor(self.GRID * SCALE + 0.5), api = api, api_methods = api_methods,
                                     warn_rows = self.warn_rows,   -- (the grid drawn; the warnings' rows, from the last build)
                                     world_classes = wclasses,   -- (a folder world's /classes)
                                     file_kind = fkind, file_desc = fdesc })   -- (a folder world's data file: its type)
  end
  local ok, g = build()
  if ok and g.warn_stale then                      -- the warnings changed: again, with their rows sized in
    self.warn_rows = g.warn_rows
    ok, g = build()
  end
  if not ok then self.err = "graph: " .. tostring(g); return end
  self.warn_rows = g.warn_rows
  self.g, self.err, self.err_line, self.res, self.ast = g, nil, nil, res, ast
  if self.note_state then self:note_state(src) end   -- (diff.lua: the changes since opened)
  local ls = { 1 }                                 -- where each line starts (line_at)
  for p in src:gmatch("\n()") do ls[#ls + 1] = p end
  self.line_starts = ls
  self.api, self.api_methods = api, api_methods
  self.by_id = g.nodes
  -- the node standing for `old` in the new graph: same kind and title, same
  -- occurrence (lines shift when tags are written; titles rarely change)
  local function key_of(list)
    local keys, count = {}, {}
    for _, n in ipairs(list) do
      local k = n.kind .. "\0" .. n.title
      count[k] = (count[k] or 0) + 1
      keys[n] = k .. "\0" .. count[k]
    end
    return keys
  end
  local new_by = {}
  for n, k in pairs(key_of(g.nodes)) do new_by[k] = n end
  local old_keys = self.g_keys or {}
  local function same(old) return old_keys[old] and new_by[old_keys[old]] end
  if self.select_line then                        -- a node just added: select it
    self.sel, self.selected = {}, nil
    for _, n in ipairs(g.nodes) do if n.line == self.select_line then self.selected = n; self.sel[n] = true; break end end
    self.select_line = nil
  else                                             -- keep the selection on the same lines
    local sel, act = {}, self.selected and same(self.selected)
    for old in pairs(self.sel or {}) do local n = same(old); if n then sel[n] = true end end
    self.sel, self.selected = sel, act
  end
  self.g_keys = key_of(g.nodes)
  self:apply_collapse()
  self:refresh_pins()
  self.hover, self.hover_sock = nil, nil
  if self.picker then                              -- the colour being picked, in the new graph
    local found
    for _, n in ipairs(g.nodes) do
      for _, p in ipairs(n.ins) do
        if p.comps and p.comps[1].pos == self.picker.pos0 then found = p end
        if self.picker.hexstr and p.kind == "literal" and p.pos == self.picker.pos0 then found = p end
      end
    end
    if found then
      self.picker.pin = found
      self.picker.comps = self.picker.hexstr and { { pos = found.pos, epos = found.epos, text = found.text } } or found.comps
    else self.picker = nil end
  end
end

-- collapsed nodes (Blender style): a node folds into its header, its pins
-- gathered on its edges (the wires stay); a function's header folds the whole
-- function: its frame shrinks to the header, the nodes inside are hidden and
-- the wires reaching them end on the header. Nothing is re-laid out (the
-- rest stays where it is). Which ones: by a key that survives edits (kind,
-- title, pin names, which of the alike), kept with the workspace.
function NodeGraphView:collapse_key(n)
  return self.ckeys and self.ckeys[n]
end
function NodeGraphView:apply_collapse()
  local g = self.g
  local keys, count = {}, {}
  for _, n in ipairs(g.nodes) do
    local names = {}
    for _, p in ipairs(n.ins) do names[#names + 1] = p.name end
    local k = n.kind .. "|" .. n.title .. "|" .. table.concat(names, ",")
    count[k] = (count[k] or 0) + 1
    keys[n] = k .. "|" .. count[k]
  end
  self.ckeys = keys
  local font = font_at(FONT_FILE, BASE_FONT)
  for _, n in ipairs(g.nodes) do
    if self.collapsed[keys[n]] and n.kind ~= "start" then
      n.collapsed = true
      local hh = n.head_h
      n.full_w, n.full_h = n.w, n.h
      local w = font:get_width(n.title) + 2 * graph.PADX + graph.CHEV + 6
      if n.xouts and n.xouts[1] and n.xouts[1].name ~= "" then w = w + font:get_width(n.xouts[1].name) + 8 end
      n.w, n.h = math.min(n.w, math.max(w, 60)), hh
      for _, p in ipairs(n.ins) do p.y = hh / 2 end
      for _, p in ipairs(n.outs) do p.y = hh / 2 end
      for _, p in ipairs(n.xouts or {}) do p.y = hh / 2 end
    end
  end
  for _, f in ipairs(g.frames) do                  -- a folded function: its frame around its header only
    if f.head.collapsed then
      f.collapsed = true
      f.w = f.head.w + 2 * graph.FPAD
      f.h = f.head.h + 2 * graph.FPAD
    end
  end
  local function proxy(el)                         -- the outermost folded function around el (not its own header)
    local px
    local p = el.parent
    while p do
      if p.head and p.head.collapsed and p.head ~= el then px = p.head end
      p = p.parent
    end
    return px
  end
  for _, n in ipairs(g.nodes) do
    local px = proxy(n)
    if px then n.hidden, n.proxy = true, px end
  end
  for _, f in ipairs(g.frames) do
    local px = proxy(f.head)
    if px then f.hidden = true end
  end
  for _, nt in ipairs(g.notes or {}) do
    local fr = nt.frame
    if fr and (fr.collapsed or fr.hidden) then nt.hidden = true end
  end
  -- folded comment boxes: the box shrinks to its headline; what's wholly
  -- inside it (nodes, functions, smaller boxes) is hidden, the wires reaching
  -- it end on the headline. Kept like folded nodes (by title, which of the alike).
  local ncount = {}
  local hh = font:get_height() + 8                 -- (its headline, at zoom 1)
  for _, nt in ipairs(g.notes or {}) do
    local k = "note|" .. nt.title
    ncount[k] = (ncount[k] or 0) + 1
    nt.key = k .. "|" .. ncount[k]
    nt.is_note, nt.head_h = true, hh
  end
  for _, nt in ipairs(g.notes or {}) do
    if self.collapsed[nt.key] and not nt.hidden then
      nt.collapsed = true
      local function inside(e) return e.x >= nt.x and e.y >= nt.y and e.x + e.w <= nt.x + nt.w and e.y + e.h <= nt.y + nt.h end
      for _, n in ipairs(g.nodes) do if inside(n) then n.hidden, n.proxy = true, nt end end
      for _, f in ipairs(g.frames) do if inside(f) then f.hidden = true end end
      for _, o in ipairs(g.notes) do if o ~= nt and inside(o) then o.hidden = true end end
      nt.full_w, nt.full_h = nt.w, nt.h
      nt.w = math.min(nt.w, math.max(120, font:get_width(nt.title ~= "" and nt.title or "comment") + graph.CHEV + 30))
      nt.h = hh
    end
  end
  for _, n in ipairs(g.nodes) do                   -- (a folded function inside a folded box: the box)
    local p = n.proxy
    if p and p.hidden and p.proxy then n.proxy = p.proxy end
  end
end
function NodeGraphView:collapsible(n)
  return n.kind ~= "start" and (n.collapsed or n.frame ~= nil or n.h > n.head_h + 4)
end
-- the chevron under the mouse: its node
function NodeGraphView:chevron_at(x, y)
  local n = self:node_at(x, y)
  if not (n and self:collapsible(n)) then return nil end
  local ox, oy = self:origin()
  local z = self.zoom
  local lx = (x - ox) / z - n.x
  if (y - oy) / z - n.y <= n.head_h and lx >= 5 and lx <= 8 + graph.CHEV then return n end
end
-- the node a wire to n ends on: n, or the folded function's header around it
function NodeGraphView:shown(n) return n and (n.proxy or n) end
function NodeGraphView:toggle_collapse(n)
  local k = n.is_note and n.key or self.ckeys and self.ckeys[n]
  if not k then return end
  self.collapsed[k] = not self.collapsed[k] or nil
  self:rebuild()
  core.redraw = true
end

-- rebuilding takes a few ms per hundred nodes: right away when the graph made
-- the change (it's the active view), else once the typing pauses (0.2 s)
NodeGraphView.REBUILD_DELAY = 0.2
function NodeGraphView:update()
  -- a tab behind another one isn't built (nor kept up to date) until it's
  -- shown: a workspace with many graph tabs opens without building them all
  local node = core.root_view.root_node:get_node_for_view(self)
  if node and node.active_view ~= self then return NodeGraphView.super.update(self) end
  self:poll_probe()
  local cid = self.doc and self.doc:get_change_id()
  if cid and cid ~= self.change_id then
    local now = system.get_time()
    if cid ~= self.seen_change then self.seen_change, self.seen_at = cid, now end
    if core.active_view == self or not self.g or now - self.seen_at >= self.REBUILD_DELAY then
      self:rebuild()
      core.redraw = true
    else
      core.redraw = true                           -- (keep ticking until it's time)
    end
  end
  if self.pending_line then self:land_pending() end
  if not self.restored and not self.fitted and self.g and self.size.x > 0 then   -- a new tab: all of it in view
    self.fitted = true
    self:fit(0.75)
  end
  self:animate_scroll()
  self:keep_in_view()
  if self.anim_due() then core.redraw = true end   -- (beads, fading flow: 30 steps a second, not every frame)
  NodeGraphView.super.update(self)
end

-- screen <-> graph: screen = origin + graph * zoom
function NodeGraphView:origin()
  return self.position.x + self.pan.x, self.position.y + self.pan.y
end

-- the fonts at the current zoom
function NodeGraphView:fonts()
  return font_at(FONT_FILE, BASE_FONT * self.zoom), font_at(CODE_FILE, BASE_CODE * self.zoom)
end

function NodeGraphView:node_at(x, y)
  if not self.g then return nil end
  local ox, oy = self:origin()
  local z = self.zoom
  for i = #self.g.nodes, 1, -1 do
    local n = self.g.nodes[i]
    if not n.hidden and x >= ox + n.x * z and x < ox + (n.x + n.w) * z and y >= oy + n.y * z and y < oy + (n.y + n.h) * z then return n end
  end
end

-- keys scroll the camera (nothing selected): a share of the view, eased
-- (in-out cubic); presses while it moves add up. Panning by hand stops it.
NodeGraphView.SCROLL_TIME = 0.28
function NodeGraphView:scroll_by(fx, fy)
  local a = self.scroll_anim
  local tx, ty = self.pan.x, self.pan.y
  if a then tx, ty = a.tx, a.ty end
  tx, ty = self:clamp_pan(tx - fx * self.size.x, ty - fy * self.size.y)
  self.scroll_anim = { fx = self.pan.x, fy = self.pan.y, tx = tx, ty = ty, t0 = system.get_time() }
  core.redraw = true
end
function NodeGraphView:animate_scroll()
  local a = self.scroll_anim
  if not a then return end
  if a.lx and (a.lx ~= self.pan.x or a.ly ~= self.pan.y) then self.scroll_anim = nil; return end   -- moved by hand
  local t = math.min(1, (system.get_time() - a.t0) / self.SCROLL_TIME)
  local e = t < 0.5 and 4 * t * t * t or 1 - (-2 * t + 2) ^ 3 / 2
  self.pan.x, self.pan.y = a.fx + (a.tx - a.fx) * e, a.fy + (a.ty - a.fy) * e
  a.lx, a.ly = self.pan.x, self.pan.y
  if t >= 1 then self.scroll_anim = nil end
  core.redraw = true
end

-- the graph can't be scrolled out of sight: some of it always stays in view
function NodeGraphView:clamp_pan(px, py)
  local g = self.g
  if not g or self.size.x <= 0 then return px, py end
  local z, m = self.zoom, 80 * SCALE
  local x0, y0 = (g.x0 or 0) * z, (g.y0 or 0) * z
  local x1, y1 = g.w * z, g.h * z
  px = math.min(px, self.size.x - m - x0)          -- its left edge: not past the right side
  px = math.max(px, m - x1)                        -- its right edge: not past the left side
  py = math.min(py, self.size.y - m - y0)
  py = math.max(py, m - y1)
  return px, py
end
function NodeGraphView:keep_in_view()
  local g = self.g
  if not g or self.size.x <= 0 then return end
  local px, py = self:clamp_pan(self.pan.x, self.pan.y)
  if px ~= self.pan.x or py ~= self.pan.y then
    self.pan.x, self.pan.y = px, py
    core.redraw = true
  end
end

-- the whole graph in view, centred, filling `frac` of it (default 0.9;
-- a new graph tab opens at 0.75), within the zoom limits
function NodeGraphView:fit(frac)
  local g = self.g
  if not g or self.size.x <= 0 then return end
  frac = frac or 0.9
  local top = style.font:get_height() + 8 * SCALE  -- under the header bar
  local aw, ah = self.size.x, self.size.y - top
  local x0, y0 = g.x0 or 0, g.y0 or 0
  local gw, gh = math.max(g.w - x0, 1), math.max(g.h - y0, 1)
  self.zoom = math.max(ZMIN, math.min(1, frac * aw / gw, frac * ah / gh))
  self.pan.x = (aw - gw * self.zoom) / 2 - x0 * self.zoom
  self.pan.y = top + (ah - gh * self.zoom) / 2 - y0 * self.zoom
  core.redraw = true
end

-- zoom by `f` keeping the graph point under (sx, sy) where it is
function NodeGraphView:zoom_at(f, sx, sy)
  local z = math.max(ZMIN, math.min(T.cfg.zoom_max, self.zoom * f))
  if z == self.zoom then return end
  local ox, oy = self:origin()
  local gx, gy = (sx - ox) / self.zoom, (sy - oy) / self.zoom
  self.zoom = z
  self.pan.x = sx - gx * z - self.position.x
  self.pan.y = sy - gy * z - self.position.y
  core.redraw = true
end

-- input ----------------------------------------------------------------

-- byte offset -> line, column (lite's doc positions)
-- a short message: a refusal / failure (what was asked didn't happen) shows
-- top-left in red with the errors; anything else on the bottom line
local REFUSAL = { "^can't", "can't ", "^cannot", "not visible", "would refer", "^nothing", "^no ", "^not ",
  "^that ", "^drop it", "^select ", "^the text changed", "^the clipboard", "^it holds", "^it feeds", "^it reads",
  "^floating code can't", "^connect floating", "^only ", "^repeat and", "^these statements", "^two variables",
  "^the last of them", "^a value goes", "^an? %w+ condition", "^an expression", "expected", "^not editable",
  "^hurdy files" }
function NodeGraphView.is_refusal(msg)
  msg = tostring(msg or "")
  if msg:find("converted:", 1, true) then return false end   -- (autoconversion: done, just saying how)
  if msg:find("^%a+ %d+/%d+") then return false end            -- ("warning 2/6 ...": where the count link went)
  for _, p in ipairs(REFUSAL) do if msg:find(p) then return true end end
  return false
end
function NodeGraphView:flash(msg)                  -- a short note (see draw.lua: where it shows)
  self.note = { text = msg, t = system.get_time(), err = NodeGraphView.is_refusal(msg) or nil }
  core.redraw = true
end

-- the row of a node under y: "title" or "body"
function NodeGraphView:scroll_to_line(line)
  if not self.g then return end
  local best
  for _, n in ipairs(self.g.nodes) do
    if n.line and n.line <= line and (not best or n.line > best.line) then best = n end
  end
  if not best then return end
  self:select({ best })
  local z = self.zoom
  self.pan.x = self.size.x / 2 - (best.x + best.w / 2) * z
  self.pan.y = self.size.y / 2 - (best.y + best.h / 2) * z
end

-- a click in the text: select the innermost node whose code holds that
-- character (an expression node beats its statement, a statement its
-- function), and bring it into view if it isn't already
function NodeGraphView:locate(line, col)
  if self.change_id ~= self.doc:get_change_id() then self:rebuild() end   -- (typed into, not rebuilt yet)
  local g = self.g
  if not g then return end
  local off = 0
  for i = 1, line - 1 do off = off + #(self.doc.lines[i] or "") end
  off = off + col
  local best, bspan
  for _, n in ipairs(g.nodes) do
    local sp = n.ast or (n.fields and n.fields.body)
    if n.kind == "start" then sp = nil end
    if sp and sp.pos and sp.epos and sp.pos <= off and off <= sp.epos + 1 and (not best or sp.epos - sp.pos < bspan) then
      best, bspan = n, sp.epos - sp.pos
    end
  end
  if not best then                                 -- between statements: the one above
    for _, n in ipairs(g.nodes) do
      if n.line and n.kind ~= "start" and n.line <= line and (not best or n.line > best.line) then best = n end
    end
  end
  if not best then return end
  self:select({ best })
  local z, ox, oy = self.zoom, self.pan.x, self.pan.y
  local top = style.font:get_height() + 8 * SCALE  -- under the header bar
  local x0, y0 = ox + best.x * z, oy + best.y * z
  local x1, y1 = x0 + best.w * z, y0 + best.h * z
  if x0 < 0 or y0 < top or x1 > self.size.x or y1 > self.size.y then
    self.pan.x = self.size.x / 2 - (best.x + best.w / 2) * z
    self.pan.y = (self.size.y + top) / 2 - (best.y + best.h / 2) * z
  end
  core.redraw = true
end

-- the text view of the same document: show `line` there (open one beside if
-- needed); keep_focus: the graph stays the active view
function NodeGraphView:goto_line(line, keep_focus)
  self.doc:set_selection(line, 1)
  local mine = core.root_view.root_node:get_node_for_view(self)
  local views = {}                                 -- every text view of this file: { node, view }
  local function find(node)
    if node.type == "leaf" then
      for _, v in ipairs(node.views) do
        if v:is(DocView) and v.doc == self.doc then views[#views + 1] = { node, v } end
      end
    else find(node.a); find(node.b) end
  end
  find(core.root_view.root_node)
  if self.flipped then self.flipped:scroll_to_line(line, true, true) end   -- the text it flips back to
  local shown
  for _, it in ipairs(views) do                    -- all of them follow; another pane's is brought up
    it[2]:scroll_to_line(line, true, true)
    if it[1] ~= mine then it[1]:set_active_view(it[2]); shown = shown or it[2] end
  end
  if shown then
    core.set_active_view(keep_focus and self or shown)
  elseif not keep_focus then                       -- none beside: open one
    local dv = views[1] and views[1][2] or DocView(self.doc)
    if not views[1] then mine:split("left", dv) else mine:set_active_view(dv) end
    dv:scroll_to_line(line, true, true)
    core.set_active_view(dv)
  end
end

-- drawing --------------------------------------------------------------
-- Blender-like: rounded nodes on a grid, a coloured header, sockets on the
-- edges (inputs left, outputs right) joined by curved wires. Everything is
-- drawn at the view's zoom: graph units * zz, pixel sizes * Z (= SCALE * zoom).

-- the rest of the view: what changes the text, the mouse and keys, drawing
-- the running world: what this file's code did in the frame shown -----------
-- (host_probe, editor/editor.c / editor/probe.h): the lines that ran (how many times)
-- and the locals' values there, as short strings. Asked ~20 times a second
-- while the tab is shown; the world records only while some graph asks.
-- self.probe = { t = game time, lines = { [line] = { n = runs, v = { name = "value" } } } }
function NodeGraphView:poll_probe()
  local hp = rawget(_G, "host_probe")
  if not (hp and self.doc and self.doc.filename) then return end
  local now = system.get_time()
  if self.probe_at and now - self.probe_at < 0.05 then return end
  self.probe_at = now
  self.abs_file = self.abs_file or system.absolute_path(self.doc.filename) or self.doc.filename
  local s = hp(self.abs_file)
  if s == self.probe_src then return end
  self.probe_src = s
  local f = s and load(s, "=probe", "t", {})
  local ok, t = false, nil
  if f then ok, t = pcall(f) end
  local old_t = self.probe and self.probe.t
  self.probe = ok and type(t) == "table" and t.lines and next(t.lines) and t or nil
  local P = self.probe                             -- stopped at a breakpoint in this file: there (once a stop)
  if P and P.brk and P.brk_n ~= self.brk_seen then
    self.brk_seen = P.brk_n
    local best = self.line_node and self:line_node(P.brk)   -- (the first statement on that line)
    if best then self:glide_to(best) end
  end
  local new_t = self.probe and self.probe.t      -- the frame shown went back (timeline dragged left,
  if old_t and new_t then                          -- rewound): the beads run backwards a while (draw.lua)
    if new_t < old_t then self.flow_back_at = now elseif new_t > old_t then self.flow_back_at = nil end
  end
  core.redraw = true
end
function NodeGraphView:line_at(pos)                -- the line of a position in the text
  local ls = self.line_starts
  if not ls or not pos then return nil end
  local lo, hi, best = 1, #ls, 1
  while lo <= hi do
    local m = math.floor((lo + hi) / 2)
    if ls[m] <= pos then best = m; lo = m + 1 else hi = m - 1 end
  end
  return best
end
function NodeGraphView:ran(n)                      -- that node's line ran in the frame shown: how many times
  local P = self.probe
  local r = P and n and n.line and P.lines[n.line]
  return r and r.n
end
-- the value of a node's output pin (a variable it declares or writes): the
-- locals a line keeps are as it starts, so it's read on the next line that ran
-- and knows it; none yet (stopped on this very line, before it ran): "not yet"
function NodeGraphView:out_value(n, pin)
  local P = self.probe
  local d = P and pin and pin.decl
  if not (d and n and n.line) then return nil end
  local last = n.line
  if self.line_at and n.epos then last = self:line_at(n.epos) or last end
  local lines = {}
  for l in pairs(P.lines) do if l > last then lines[#lines + 1] = l end end
  table.sort(lines)
  for _, l in ipairs(lines) do
    local r = P.lines[l]
    if r.v[d.name] then return r.v[d.name], d.name, r.n, l end
  end
  if P.brk and P.brk >= n.line and P.brk <= last then
    return "(not yet: stopped before line " .. P.brk .. " ran)", d.name, 1, n.line
  end
end
-- the value of a node's input pin that reads a variable (a chip too): at its line
function NodeGraphView:pin_value(n, pin)
  local P = self.probe
  local d = P and pin and pin.decl
  if not d then return nil end
  local sp = U.pin_spans(pin)
  local line = self:line_at(sp and sp[1] and sp[1].pos or n.pos)
  local r = line and P.lines[line]
  if r and r.v[d.name] then return r.v[d.name], d.name, r.n, line end
end
-- an expression's value in the frame shown (a wire from an expression node):
-- the world evaluates its text with the locals it recorded at its line. Only
-- expressions that can't change the game: no calls but to functions that only
-- compute (SAFE: math.*, string functions that make a new string, tostring,
-- tonumber, type, select; runtime/probe.lua refuses the rest, and a local of
-- one of those names shadowing it)
local SAFE = { tostring = true, tonumber = true, type = true, select = true,
  math = { abs = 1, ceil = 1, floor = 1, max = 1, min = 1, sqrt = 1, sin = 1, cos = 1, tan = 1, asin = 1, acos = 1,
           atan = 1, atan2 = 1, exp = 1, log = 1, pow = 1, fmod = 1, modf = 1, deg = 1, rad = 1, huge = 1, pi = 1,
           tointeger = 1, type = 1, ult = 1, maxinteger = 1, mininteger = 1 },
  string = { byte = 1, char = 1, find = 1, format = 1, len = 1, lower = 1, upper = 1, rep = 1, reverse = 1, sub = 1, match = 1 } }
NodeGraphView.SAFE_CALLS = SAFE
local function safe_callee(f)
  if f.tag == "Id" then return SAFE[f.name] == true end
  if f.tag == "Index" and f.name and f.obj and f.obj.tag == "Id" then
    local lib = SAFE[f.obj.name]
    return type(lib) == "table" and lib[f.name] ~= nil
  end
  return false
end
local function pure(e, depth)
  if type(e) ~= "table" then return true end
  depth = (depth or 0) + 1
  if depth > 100 or e.tag == "Invoke" or e.tag == "Function" or e.tag == "Vararg" then return false end
  if e.tag == "Call" then
    if not safe_callee(e.fn) then return false end
    for _, a in ipairs(e.args or {}) do if not pure(a, depth) then return false end end
    return true
  end
  for _, v in pairs(e) do if type(v) == "table" and not pure(v, depth) then return false end end
  return true
end
function NodeGraphView:expr_value(a)
  local P, e = self.probe, a and a.vexpr
  local ev = rawget(_G, "host_probe_eval")
  if not (P and e and e.pos and ev and self.g and self.g.src and self.abs_file) then return nil end
  P.evals = P.evals or {}
  local c = P.evals[e]
  if c == nil then
    c = false
    local line = self:line_at(e.pos)
    local r = line and P.lines[line]
    if r and pure(e) then
      local v = ev(self.abs_file, line, self.g.src:sub(e.pos, e.epos))
      if v then c = { v, r.n, line, true } end
    end
    P.evals[e] = c
  end
  if c then return c[1], c[2], c[3], c[4] end   -- (4th: computed here, not recorded)
end
-- the value a data wire carried: its variable, read where the wire ends
-- (from an expression node: the expression's value)
function NodeGraphView:link_value(l)
  local P = self.probe
  if not P then return nil end
  if l.expr then
    local a, b = self.by_id[l.from], self.by_id[l.to]
    local v, n, line, computed = self:expr_value(a)
    if v then return v, b and b.ins[l.inp] and b.ins[l.inp].name or "result", n, line, computed end
    return nil
  end
  if l.field then                                  -- from a split table output: that field, where it's read
    local b = self.by_id[l.to]
    local pin = b and b.ins[l.inp]
    local line = self:line_at(pin and pin.pos or (b and b.pos))
    local r = line and P.lines[line]
    local ev = rawget(_G, "host_probe_eval")
    if not (r and ev and self.abs_file) then return nil end
    P.evals = P.evals or {}
    local key = l.field .. "@" .. line
    if P.evals[key] == nil then P.evals[key] = ev(self.abs_file, line, l.field) or false end
    if P.evals[key] then return P.evals[key], l.field, r.n, line end
    return nil
  end
  local a, b = self.by_id[l.from], self.by_id[l.to]
  local o = a and a.outs[l.out]
  local d = o and o.decl
  if not d then return nil end
  local pin = b.ins[l.inp]
  local sp = pin and U.pin_spans(pin)
  local line = self:line_at(sp and sp[1] and sp[1].pos or b.pos)
  local r = line and P.lines[line]
  if r and r.v[d.name] then return r.v[d.name], d.name, r.n, line end
end

-- pinned references -----------------------------------------------------------
-- RMB on a variable (a pin reading it, the node declaring it, a get node, a
-- chip) > "Pin references of x": every node that declares, writes or reads
-- it is outlined, and a crosshair runs through each one across the whole view,
-- in a colour of its own (the palette, one per pinned variable). They stay
-- until "Unpin references of x" (or "Unpin all references" on the
-- background); kept with the workspace (by name and line) and across edits.
function NodeGraphView:decl_at(n, x, y)         -- the variable under the mouse on node n
  local wg = self:widget_at(x, y)
  if wg and wg.kind == "chip" and wg.decl then return wg.decl end
  local ox, oy = self:origin()
  local z = self.zoom
  local half = (style.font:get_height() + 4) / 2
  for _, side in ipairs({ "ins", "outs" }) do
    for _, p in ipairs(n[side]) do
      if p.decl and p.y and math.abs(y - (oy + (n.y + p.y) * z)) <= half * z then return p.decl end
    end
  end
  if n.getter and n.fields and n.fields.body then
    for _, u in ipairs(self.res.uses) do if u.pos == n.fields.body.pos then return u.decl end end
  end
  local only
  for _, o in ipairs(n.outs) do if o.decl then if only and only ~= o.decl then only = false break end only = o.decl end end
  return only or nil
end
function NodeGraphView:node_around(pos)          -- the innermost node whose text holds pos
  local best, bw
  for _, n in ipairs(self.g.nodes) do
    local a, b = n.pos, n.epos
    if n.fields and n.fields.body and n.kind == "expr" then a, b = n.fields.body.pos, n.fields.body.epos end
    if a and b and pos >= a and pos <= b and (not bw or b - a < bw) then best, bw = n, b - a end
  end
  return best
end
-- the nodes of d: node -> "decl" | "write" | "read"; and the counts
function NodeGraphView:references(d)
  local src = self.doc:get_text(1, 1, math.huge, math.huge)
  local nodes, reads, writes = {}, 0, 0
  local function mark(n, kind)
    if not n then return end
    n = n.proxy or n
    local old = nodes[n]
    if old == "decl" or (old == "write" and kind == "read") then return end
    nodes[n] = kind
  end
  for _, n in ipairs(self.g.nodes) do
    for _, o in ipairs(n.outs) do if o.decl == d then mark(n, "decl") end end
  end
  local seen = {}
  local function use(pos, epos)
    if seen[pos] then return end
    seen[pos] = true
    local after = src:match("^%s*(.?.?)", epos + 1) or ""
    local w = after:sub(1, 1) == "=" and after:sub(2, 2) ~= "="
    if w then writes = writes + 1 else reads = reads + 1 end
    mark(self:node_around(pos), w and "write" or "read")
  end
  for _, u in ipairs(self.res.uses) do
    if u.decl == d then use(u.pos, u.epos) end
  end
  for _, r in ipairs(d.refs or {}) do use(r[1], r[2]) end   -- (floating code: its own names)
  for _, l in ipairs(self.g.links) do              -- (another block's reads of it: the pending wires)
    local a = self.by_id[l.from]
    if l.pending and a and a.outs[l.out] and a.outs[l.out].decl == d then
      local b = self.by_id[l.to]
      local p = b and b.ins[l.inp]
      local u = p and p.uses and p.uses[1]
      if u then use(u.pos, u.epos) else mark(b, "read") end
    end
  end
  return nodes, reads, writes
end
function NodeGraphView:pin_of(d)                 -- its pin, if pinned
  for i, p in ipairs(self.pins) do if p.decl == d then return p, i end end
end
function NodeGraphView:toggle_pin(d)
  if not d then return self:flash("no variable there") end
  local p, i = self:pin_of(d)
  if p then
    table.remove(self.pins, i)
    core.redraw = true
    return self:flash("unpinned " .. d.name)
  end
  local used = {}
  for _, q in ipairs(self.pins) do used[q.color] = true end
  local color
  for k = 2, #U.PALETTE do if not used[U.PALETTE[k]] then color = U.PALETTE[k] break end end
  color = color or U.PALETTE[2 + #self.pins % (#U.PALETTE - 1)]
  local nodes, reads, writes = self:references(d)
  local count = 0
  for _ in pairs(nodes) do count = count + 1 end
  self.pins[#self.pins + 1] = { decl = d, name = d.name, line = self:line_at(d.pos), color = color, nodes = nodes }
  core.redraw = true
  self:flash(string.format("pinned %s: %d read%s, %d write%s, in %d node%s", d.name, reads, reads == 1 and "" or "s",
    writes, writes == 1 and "" or "s", count, count == 1 and "" or "s"))
end
function NodeGraphView:unpin_all()
  self.pins = {}
  core.redraw = true
end
function NodeGraphView:refresh_pins()           -- after a rebuild: the same variables (name, nearest line)
  for i = #self.pins, 1, -1 do
    local p = self.pins[i]
    local best, bd
    for _, d in ipairs(self.res.decls) do
      if d.name == p.name and d.pos > 0 then
        local dl = math.abs(self:line_at(d.pos) - p.line)
        if not bd or dl < bd then best, bd = d, dl end
      end
    end
    if best then
      p.decl, p.line = best, self:line_at(best.pos)
      p.nodes = self:references(best)
    else table.remove(self.pins, i) end
  end
end

-- go to definition ----------------------------------------------------------
-- RMB > "Go to definition" on a node: where what it uses is defined. A call:
-- its function (this file's frame, else the module's file, opened as a graph
-- in a tab, or an API stub of runtime/meta); a get node, a variable's pin: the
-- node that declares it. The view glides there and selects it; "Go back"
-- (RMB on the background, or alt+left / alt+up) returns.
local function path_of(e)                          -- a.b.c as text
  if e.tag == "Id" then return e.name end
  if e.tag == "Index" and e.name then local p = path_of(e.obj); return p and (p .. "." .. e.name) end
  if e.tag == "Paren" then return path_of(e.e) end
end
function NodeGraphView:decl_node(d)              -- the node declaring d (its output, or a header's)
  for _, n in ipairs(self.g.nodes) do
    for _, o in ipairs(n.outs) do if o.decl == d then return n end end
  end
end
function NodeGraphView:frame_named(name, method)  -- this file's function frame: "function name" / "...:method"
  for _, f in ipairs(self.g.frames) do
    local t = f.head.title:gsub("%s*%(.*$", "")
    local fn = t:match("^local function (.+)$") or t:match("^function (.+)$")
    if fn and (fn == name or (method and fn:match(":" .. method .. "$"))) then return f.head end
  end
end
-- the target: { node = n } here, or { file = path, line = l } elsewhere; nil: none
function NodeGraphView:definition_of(n, pin)
  local res = self.res
  local function use_decl(e)
    for _, u in ipairs(res.uses) do if u.pos == e.pos then return u.decl end end
  end
  if pin and pin.decl then local t = self:decl_node(pin.decl); if t and t ~= n then return { node = t } end end
  if n.getter and n.fields and n.fields.body then
    local d = use_decl(n.fields.body)
    local t = d and self:decl_node(d)
    if t then return { node = t } end
  end
  local c = n.vexpr or (n.ast and n.ast.tag == "CallStat" and n.ast.call)
  if c and (c.tag == "Call" or c.tag == "Invoke") then
    local api, entry
    if c.tag == "Call" then
      local p = path_of(c.fn)
      local base = c.fn
      while base.tag ~= "Id" and base.obj do base = base.obj end
      local d = base.tag == "Id" and use_decl(base)
      if d and p == base.name then
        local t = self:decl_node(d)
        if t then return { node = t } end
      end
      local h = p and self:frame_named(p)
      if h then return { node = h } end
      entry = p and self.api and self.api[p]
    else
      local h = self:frame_named(nil, c.method)
      if h then return { node = h } end
      local list = self.api_methods and self.api_methods[c.method]
      entry = list and list[1]
    end
    if entry and entry.file then return { file = entry.file, line = entry.line or 1 } end
  end
end
-- a syntax error (the text doesn't parse; the graph is the last good one):
-- the node closest to it, the last one starting at or before its line (the
-- first one if none does); folded inside something: what it's folded into
function NodeGraphView:err_node()
  local l = self.err and self.err_line
  if not l or not self.g then return nil end
  local best, first
  for _, n in ipairs(self.g.nodes) do
    if n.line and n.kind ~= "start" and n.kind ~= "expr" and not n.is_note then
      if n.line <= l and (not best or n.line > best.line) then best = n end
      if not first or n.line < first.line then first = n end
    end
  end
  best = best or first
  while best and best.hidden and best.proxy and best.proxy ~= best do best = best.proxy end
  return best
end
-- a click on the syntax error (top-left): the view glides to its node, the
-- text's cursor goes to its line (flip to the text: it's there)
function NodeGraphView:goto_err()
  local n = self:err_node()
  if self.err_line then self.doc:set_selection(math.min(self.err_line, #self.doc.lines), 1) end
  if not n then return self:flash(self.err or "?") end
  if self.zoom < 0.8 then                          -- (far out: close enough to read it)
    local cx, cy = self.size.x / 2, self.size.y / 2
    self.pan.x = cx - (cx - self.pan.x) / self.zoom
    self.pan.y = cy - (cy - self.pan.y) / self.zoom
    self.zoom = 1
  end
  self:glide_to(n)
end

function NodeGraphView:glide_to(n)               -- the view glides to n (centred), n selected
  if n.proxy then n = n.proxy end                  -- (inside a folded function: its header)
  local z = self.zoom
  local tx = self.size.x / 2 - (n.x + n.w / 2) * z
  local ty = self.size.y / 2 - (n.y + n.h / 2) * z
  tx, ty = self:clamp_pan(tx, ty)
  self.scroll_anim = { fx = self.pan.x, fy = self.pan.y, tx = tx, ty = ty, t0 = system.get_time() }
  if not n.is_note then self:select({ n }) end     -- (a folded comment box: shown, not selected)
  core.redraw = true
end
function NodeGraphView:goto_definition(n, pin)
  local t = self:definition_of(n, pin)
  if not t then return self:flash("no definition found for " .. n.title) end
  if t.node then
    self.back[#self.back + 1] = { view = self, x = self.pan.x, y = self.pan.y, zoom = self.zoom }
    self:glide_to(t.node)
    return self:flash("definition: " .. t.node.title .. " (ALT+LEFT: back)")
  end
  local ok, doc = pcall(core.open_doc, t.file)    -- another file: its graph, in a tab of this pane
  if not ok then return self:flash("can't open " .. t.file) end
  local view
  local function find(node)
    if node.type == "leaf" then
      for _, v in ipairs(node.views) do if getmetatable(v) == NodeGraphView and v.doc == doc then view = view or v end end
    else find(node.a); find(node.b) end
  end
  find(core.root_view.root_node)
  local here = core.root_view.root_node:get_node_for_view(self)
  if not view then
    view = NodeGraphView(doc)
    here:add_view(view)
  else
    local nd = core.root_view.root_node:get_node_for_view(view)
    if nd then nd:set_active_view(view) end
  end
  core.set_active_view(view)
  view.back[#view.back + 1] = { view = self, x = self.pan.x, y = self.pan.y, zoom = self.zoom }
  view.pending_line = t.line
  self:flash("definition: " .. t.file:match("[^/\\]*$") .. ":" .. t.line)
end
function NodeGraphView:go_back()
  local b = table.remove(self.back)
  if not b then return self:flash("nothing to go back to") end
  if b.view ~= self then                           -- (from another file's graph: back to its tab)
    local nd = core.root_view.root_node:get_node_for_view(b.view)
    if nd then nd:set_active_view(b.view); core.set_active_view(b.view) end
    return
  end
  self.zoom = b.zoom
  self.scroll_anim = { fx = self.pan.x, fy = self.pan.y, tx = b.x, ty = b.y, t0 = system.get_time() }
  core.redraw = true
end
function NodeGraphView:land_pending()             -- opened for a definition: glide to that line's node
  local l = self.pending_line
  if not (l and self.g and self.size.x > 0) then return end
  self.pending_line = nil
  self.fitted = true
  local best
  for _, n in ipairs(self.g.nodes) do
    if n.line == l and (not best or n.kind == "function") then best = n end
  end
  if not best then                                 -- (the closest node at or after it)
    for _, n in ipairs(self.g.nodes) do
      if n.line and n.line >= l and (not best or n.line < best.line) then best = n end
    end
  end
  if best then
    self.zoom = 1
    local n = best.proxy or best
    if n.is_note then n = best end                  -- (in a folded comment box: where it would be)
    self.pan.x, self.pan.y = self:clamp_pan(self.size.x / 2 - (n.x + n.w / 2), self.size.y / 2 - (n.y + n.h / 2))
    self:select({ n })
  end
end

require "plugins.nodegraph.edits"
require "plugins.nodegraph.input"
require "plugins.nodegraph.diff"
require "plugins.nodegraph.draw"

return NodeGraphView

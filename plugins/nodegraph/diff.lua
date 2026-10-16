-- diff.lua - NodeGraphView: the changes made since the graph was opened, and
-- a graph diff against any of them (part of the nodegraph plugin, ours). A
-- sketch: kept apart so it can become a plugin of its own (its own tab).
--
-- Every text the graph is rebuilt from is kept, per document (a graph tab
-- closed and opened again keeps its list; the first one: the file as saved
-- when the document had unsaved changes already, else as opened). "N
-- changes" top-right (teal) opens the list, newest first. A
-- click on one diffs that state against the current one, on the current
-- graph: added nodes outlined green, changed amber, removed ones drawn where
-- they were as red ghosts, moved ones (dragged: their offsets changed) also
-- drawn where they were, at 25%. The list's [x] closes it: the graph as it is.
-- Nodes pair by kind, title and which of the alike (the key the selection
-- follows across rebuilds); changed = same key, other pins / code.
local core = require "core"
local style = require "core.style"
local NodeGraphView = require "plugins.nodegraph.class"
local T = require "plugins.nodegraph.theme"

local MAX = 64                                     -- states kept (the first, as opened, always)
local ADDED, CHANGED, REMOVED = T.rgb"#5ec46e", T.rgb"#e8b04d", T.rgb"#e0464e"

local function lines_of(s)
  local t = {}
  for l in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
  return t
end
local function summary(a, b)                       -- "line 45: +2 -1": what changed from a to b
  local la, lb = lines_of(a), lines_of(b)
  local i = 1
  while la[i] and la[i] == lb[i] do i = i + 1 end
  local ja, jb = #la, #lb
  while ja >= i and jb >= i and la[ja] == lb[jb] do ja, jb = ja - 1, jb - 1 end
  return string.format("line %d: +%d -%d", i, jb - i + 1, ja - i + 1)
end

local histories = setmetatable({}, { __mode = "k" })   -- a document -> its states

function NodeGraphView:note_state(src)             -- (rebuild: each text the graph was built from)
  if self.history_doc ~= self.doc then self.history_doc, self.diff = self.doc, nil end   -- (another file)
  local h = histories[self.doc]
  if not h then
    h = {}
    histories[self.doc] = h
    local f = self.doc:is_dirty() and self.doc.filename and io.open(self.doc.filename, "rb")
    if f then                                      -- changed before any graph showed it: from the file as saved
      local disk = f:read("*a"); f:close()
      if disk and disk ~= src then h[1] = { src = disk, u = 1, t = os.time(), label = "as saved" } end
    end
  end
  self.history = h
  -- h.cur: the state the text is in. Each state keeps the document's undo
  -- position (its change id): undo goes back to the last state at or before
  -- it, redo forward again (only the cursor moves, the count with it, even
  -- when undo stops between two kept states); a new edit drops what was
  -- ahead (as undo's own redo does) and goes on top
  local u = self.doc:get_change_id()
  local cur = h.cur or #h
  if h[cur] and h[cur].src == src then h[cur].u = h[cur].u or u; return end
  local function new_state()
    for i = #h, cur + 1, -1 do h[i] = nil end
    h[#h + 1] = { src = src, u = u, t = os.time(), label = h[#h] and summary(h[#h].src, src) or "as opened" }
    if #h > MAX then table.remove(h, 2) end
    h.cur = #h
  end
  if not h[cur] then new_state()
  elseif u < (h[cur].u or u) then                  -- undo
    local at = 1
    for i = cur - 1, 1, -1 do if (h[i].u or 0) <= u then at = i; break end end
    h.cur = at
  else                                             -- redo, or a new edit
    local at
    local redoing = self.doc.redo_stack and self.doc.redo_stack.idx > 1
    for i = cur + 1, #h do
      if (h[i].u or math.huge) <= u and (redoing or h[i].src == src) then at = i end
    end
    if at then h.cur = at
    elseif not redoing then new_state() end         -- (redoing, between two kept states: it stays)
  end
  if self.diff then                                -- the current state moved: again (off if what it diffs isn't behind it)
    local i
    for k = 1, h.cur - 1 do if h[k] == self.diff.entry then i = k end end
    if i then self:diff_with(self.diff.entry) else self.diff = nil end
  end
  core.redraw = true
end

local function keyed(nodes)                        -- kind, title, which of the alike -> node
  local by, count = {}, {}
  for _, n in ipairs(nodes) do
    local k = n.kind .. "\0" .. n.title
    count[k] = (count[k] or 0) + 1
    by[k .. "\0" .. count[k]] = n
  end
  return by
end
local function sig(n)                              -- what a node says: its pins (names, values), its code
  local t = { n.title }
  for _, p in ipairs(n.ins or {}) do t[#t + 1] = (p.name or "") .. "=" .. (p.text or "") end
  for _, o in ipairs(n.outs or {}) do t[#t + 1] = ">" .. (o.name or "") end
  for _, l in ipairs(n.lines or {}) do t[#t + 1] = type(l) == "table" and (l.text or "") or tostring(l) end
  return table.concat(t, "\1")
end

function NodeGraphView:diff_with(entry)
  local old = entry and self:build_of(entry.src)
  if not (old and self.g) then self.diff = nil; return self:flash("can't build that state's graph") end
  local a, b = keyed(old.nodes), keyed(self.g.nodes)
  local d = { entry = entry, added = {}, changed = {}, removed = {}, moved = {}, n_add = 0, n_chg = 0 }
  for k, n in pairs(b) do
    local o = a[k]
    if not o then d.added[n] = true; d.n_add = d.n_add + 1
    else
      if sig(o) ~= sig(n) then d.changed[n] = true; d.n_chg = d.n_chg + 1 end
      if (o.odx or 0) ~= (n.odx or 0) or (o.ody or 0) ~= (n.ody or 0) then d.moved[#d.moved + 1] = o end   -- (dragged)
    end
  end
  for k, o in pairs(a) do if not b[k] and o.kind ~= "start" then d.removed[#d.removed + 1] = o end end
  self.diff = d
  core.redraw = true
end

function NodeGraphView:open_changes()
  self.changes = { scroll = 0 }
  core.redraw = true
end
function NodeGraphView:n_changes()                 -- (the "N changes" link, top-right)
  local h = self.doc and histories[self.doc]
  return h and (h.cur or #h) - 1 or 0
end
NodeGraphView.CHANGES_COLOR = T.rgb"#3cc8c8"       -- teal: not a warning / error / breakpoint, not a diff colour
function NodeGraphView:close_changes()
  self.changes, self.diff = nil, nil
  core.redraw = true
end

-- drawing: outlines and ghosts (draw.lua, after the nodes), the list (on top)
function NodeGraphView:diff_draw(ox, oy)
  local d = self.diff
  if not d then return end
  local zz = self.zoom
  local t = math.max(2, 3 * SCALE * zz)
  local function box(x, y, w, h, c)
    renderer.draw_rect(x - t, y - t, w + 2 * t, t, c); renderer.draw_rect(x - t, y + h, w + 2 * t, t, c)
    renderer.draw_rect(x - t, y, t, h, c); renderer.draw_rect(x + w, y, t, h, c)
  end
  for _, n in ipairs(self.g.nodes) do
    local c = d.added[n] and ADDED or d.changed[n] and CHANGED
    if c and not n.hidden then box(ox + n.x * zz, oy + n.y * zz, n.w * zz, n.h * zz, c) end
  end
  local F = self:fonts()
  for _, o in ipairs(d.moved) do                  -- moved: where it was, at 25%
    local x, y, w, h = ox + o.x * zz, oy + o.y * zz, o.w * zz, o.h * zz
    local head = o.color or T.HEAD[o.kind] or T.HEAD.call
    renderer.draw_rect(x, y, w, h, { T.C.body[1], T.C.body[2], T.C.body[3], 64 })
    renderer.draw_rect(x, y, w, o.head_h * zz, { head[1], head[2], head[3], 64 })
    if zz >= 0.3 then renderer.draw_text(F, o.title, x + 6 * SCALE * zz, y + 2 * SCALE * zz, { 255, 255, 255, 64 }) end
  end
  for _, o in ipairs(d.removed) do                -- where it was: a red ghost
    local x, y, w, h = ox + o.x * zz, oy + o.y * zz, o.w * zz, o.h * zz
    renderer.draw_rect(x, y, w, h, { REMOVED[1], REMOVED[2], REMOVED[3], 50 })
    box(x, y, w, h, { REMOVED[1], REMOVED[2], REMOVED[3], 200 })
    if zz >= 0.3 then renderer.draw_text(F, o.title, x + 6 * SCALE * zz, y + 2 * SCALE * zz, REMOVED) end
  end
end

local function layout(self)                        -- the list's box and rows (newest first, not the current one)
  local f = style.font
  local rh = f:get_height() + 6 * SCALE
  local w = 300 * SCALE
  local x = self.position.x + self.size.x - w - 12 * SCALE
  local y = self.position.y + 36 * SCALE
  local rows = {}
  local h = self.history or {}
  local cur = h.cur or #h                          -- (states ahead of it: undone, not listed)
  for i = cur - 1, math.max(1, cur - 16), -1 do rows[#rows + 1] = i end
  return x, y, w, rh, rows
end

function NodeGraphView:draw_changes()
  if not self.changes then return end
  local f = style.font
  local x, y, w, rh, rows = layout(self)
  local hgt = rh * (math.max(1, #rows) + 1) + (self.diff and rh or 0) + 6 * SCALE
  renderer.draw_rect(x, y, w, hgt, { 24, 24, 24, 240 })
  renderer.draw_rect(x, y, w, rh, { 45, 45, 50, 255 })
  renderer.draw_text(f, "Diff changes since opened", x + 8 * SCALE, y + 3 * SCALE, style.text)
  local cx = x + w - f:get_width("x") - 10 * SCALE   -- [x]
  renderer.draw_text(f, "x", cx, y + 3 * SCALE, self.changes.hot == "close" and style.accent or style.dim)
  local yy = y + rh
  if #rows == 0 then renderer.draw_text(f, "(no changes yet)", x + 8 * SCALE, yy + 3 * SCALE, style.dim) end
  local h = self.history
  for _, i in ipairs(rows) do
    local e = h[i]
    local on = self.diff and self.diff.entry == e
    if on then renderer.draw_rect(x, yy, w, rh, { 70, 60, 30, 255 })
    elseif self.changes.hot == i then renderer.draw_rect(x, yy, w, rh, { 40, 40, 46, 255 }) end
    local text = os.date("%H:%M:%S", e.t) .. "   " .. (i == 1 and (e.label == "as saved" and e.label or "as opened") or e.label)
    renderer.draw_text(f, text, x + 8 * SCALE, yy + 3 * SCALE, on and style.accent or style.text)
    yy = yy + rh
  end
  if self.diff then                                -- what that state has / lacks against now
    local d = self.diff
    local s = string.format("now: +%d added  ~%d changed  -%d removed  %d moved", d.n_add, d.n_chg, #d.removed, #d.moved)
    renderer.draw_text(f, s, x + 8 * SCALE, yy + 3 * SCALE, style.dim)
  end
end

-- the mouse: true when the list took it
function NodeGraphView:changes_at(x, y)
  if not self.changes then return nil end
  local bx, by, w, rh, rows = layout(self)
  local hgt = rh * (math.max(1, #rows) + 1) + (self.diff and rh or 0) + 6 * SCALE
  if x < bx or x > bx + w or y < by or y > by + hgt then return nil end
  if y < by + rh then return x > bx + w - 30 * SCALE and "close" or "title" end
  local k = math.floor((y - by - rh) / rh) + 1
  return rows[k] or "box"
end
function NodeGraphView:changes_click(x, y)
  local hit = self:changes_at(x, y)
  if not hit then return false end
  if hit == "close" then self:close_changes()
  elseif type(hit) == "number" then
    local e = self.history[hit]
    if self.diff and self.diff.entry == e then self.diff = nil; core.redraw = true   -- (again: off)
    else self:diff_with(e) end
  end
  return true
end
function NodeGraphView:changes_hover(x, y)
  if not self.changes then return end
  local hit = self:changes_at(x, y)
  if hit ~= self.changes.hot then self.changes.hot = hit; core.redraw = true end
  return hit ~= nil
end

return NodeGraphView

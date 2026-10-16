-- editor.lua - the dialog plugin's tab: a .dialog file as a chart (runs in
-- Lite; see editor/3rd/lite/data/plugins/projectplugins.lua for what P gives).
-- The file is the text (Lite colours it: data/languages/language_dialog.lua);
-- this view shows it as boxes: the character's lines on the left, the
-- player's answers beside the line that asks, arrows to what comes next, the
-- #topic lines below. Double-click a box: its line in the text. Edits here
-- (move a box, drag its right edge to link, the RMB menu) are text edits of
-- the doc (undoable); a moved box keeps //@dx,dy on its line. The tab's
-- icon (or *Edit as text*) flips between the two; the chart follows the text
-- as it's typed. Its format and how games run it: runtime/dialog.lua.
local P = ...
P.title = "Dialog"                                 -- (its name in menus: Open with, the main menu's Plugins)
P.commands = { { "Edit as text", "dialog:edit-as-text" } }
local core = require "core"
local command = require "core.command"
local style = require "core.style"
local canvas = require "plugins.canvas"
local D = canvas.draw
local DocView = require "core.docview"
local Dialog = dofile((rawget(_G, "REPLAY_ROOT") or (DATADIR .. "/../../..")) .. "/runtime/dialog.lua")

local DEFAULTS = { width = 240 }
local cfg = {}
local function load_config()
  local c = P.read("config")
  cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if type(c) == "table" then for k, v in pairs(c) do if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then cfg[k] = v end end end
  cfg.width = math.max(120, math.min(600, cfg.width))
end

local DView = canvas.View:extend()
DView.grid = 24

function DView:new(state)
  DView.super.new(self)
  self.filename = state and state.filename or ""
  if state and state.cam then self:set_camera(state.cam) end
  self:reload()
end
function DView:get_name() return self.filename:match("[^/\\]*$") end
function DView:get_state() return { filename = self.filename, cam = self:camera_state() } end

local function doc_of(filename)                    -- an open doc of that file (its text, unsaved too)
  local abs = system.absolute_path(filename) or filename
  for _, d in ipairs(core.docs) do
    if d.filename and (system.absolute_path(d.filename) or d.filename) == abs then return d end
  end
end
function DView:source()
  local d = self.doc or doc_of(self.filename)
  if d then return d:get_text(1, 1, math.huge, math.huge), d end
  local f = io.open(self.filename, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

-- the boxes: { n | topic, x, y, w, h, lines = { wrapped text }, kind = "say" | "answer" | "topic", row }
local LH, PAD = 16, 8
local function wrap(text, chars)
  local out, cur = {}, ""
  for word in text:gmatch("%S+") do
    if #cur + #word + 1 > chars and cur ~= "" then out[#out + 1] = cur; cur = word
    else cur = cur == "" and word or (cur .. " " .. word) end
  end
  if cur ~= "" or #out == 0 then out[#out + 1] = cur end
  return out
end
function DView:reload()
  local src = self:source()
  self.src = src
  if not src then self.err = "can't read " .. self.filename; self.boxes = {}; return end
  local d = Dialog.parse(src)
  self.d, self.err = d, nil
  local answer = {}
  for _, n in ipairs(d.order) do for _, c in ipairs(d.lines[n].choices or {}) do answer[c] = n end end
  local W, gap = cfg.width, 60
  local chars = math.floor((W - 2 * PAD) / 7)
  local boxes, by, y, scene = {}, {}, 0, 1
  local col_y = { 0, 0 }
  for _, n in ipairs(d.order) do
    local L = d.lines[n]
    if L.scene ~= scene then                       -- (a scene break: a little more room)
      scene = L.scene
      y = math.max(col_y[1], col_y[2]) + 40
      col_y = { y, y }
    end
    local text = (L.choices and "" or "") .. Dialog.plain(L.parts)
    local emotes = {}
    for _, p in ipairs(L.parts) do if p.emote then emotes[#emotes + 1] = ":" .. p.emote .. ":" end end
    if #emotes > 0 then text = text .. "  " .. table.concat(emotes, " ") end
    local lines = wrap(n .. "  " .. text, chars)
    local h = #lines * LH + 2 * PAD
    local col = answer[n] and 2 or 1
    local bx = (col - 1) * (W + gap)
    local b = { n = n, x = bx, y = math.max(col_y[col], col == 2 and (by[answer[n]] and by[answer[n]].by or 0) or 0), w = W, h = h, lines = lines,
                kind = answer[n] and "answer" or "say", row = L.row, next = L.next, choices = L.choices }
    col_y[col] = b.y + h + 14
    if col == 1 then col_y[2] = math.max(col_y[2], b.y) end
    b.bx, b.by = b.x, b.y                          -- (where the layout puts it; //@dx,dy moves it from there)
    b.x, b.y = b.x + (L.dx or 0), b.y + (L.dy or 0)
    boxes[#boxes + 1] = b
    by[n] = b
  end
  local ty = math.max(col_y[1], col_y[2]) + 50
  local names = {}
  for name in pairs(d.topics) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local T = d.topics[name]
    local lines = wrap("#" .. name .. "  " .. Dialog.plain(T.parts), chars * 2)
    local b = { topic = name, x = 0, y = ty, w = 2 * W + gap, h = #lines * LH + 2 * PAD, lines = lines, kind = "topic", row = T.row }
    boxes[#boxes + 1] = b
    ty = ty + b.h + 14
    b.bx, b.by = b.x, b.y
    b.x, b.y = b.x + (T.dx or 0), b.y + (T.dy or 0)
  end
  self.boxes, self.by = boxes, by
  self.errors = d.errors
  core.redraw = true
end

function DView:bounds()
  local x0, y0, x1, y1
  for _, b in ipairs(self.boxes or {}) do
    x0, y0 = math.min(x0 or b.x, b.x), math.min(y0 or b.y, b.y)
    x1, y1 = math.max(x1 or b.x + b.w, b.x + b.w), math.max(y1 or b.y + b.h, b.y + b.h)
  end
  if not x0 then return nil end
  return x0 - 20, y0 - 20, x1 - x0 + 40, y1 - y0 + 40
end

function DView:box_at(wx, wy)
  for _, b in ipairs(self.boxes or {}) do
    if wx >= b.x and wx < b.x + b.w and wy >= b.y and wy < b.y + b.h then return b end
  end
end
function DView:goto_row(row)                       -- its text, at that row (flipped in this tab)
  local node = core.root_view.root_node:get_node_for_view(self)
  local v = node and require("plugins.tabflip").flip(node, self)
  if v and v.doc and row then
    v.doc:set_selection(row, 1)
    if v.scroll_to_line then v:scroll_to_line(row, true, true) end
  end
end
-- editing: every change goes through the text (undoable; the chart follows it)
-- a row's text <-> { n | topic, body, choices, next, comment, dx, dy }
local function row_parts(raw)
  raw = raw:gsub("[\r\n]+$", "")
  local t = {}
  local dx, dy = raw:match("//@(%-?%d+),(%-?%d+)%s*$")
  if dx then t.dx, t.dy = tonumber(dx), tonumber(dy); raw = raw:gsub("%s*//@%-?%d+,%-?%d+%s*$", "") end
  local c = raw:find("//", 1, true)
  if c then t.comment = raw:sub(c); raw = raw:sub(1, c - 1) end
  raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
  local n, rest = raw:match("^(%d+)%s*(.*)$")
  if n then
    t.n = tonumber(n)
    local body, list = rest:match("^(.-)%s*%[([%d%s,]*)%]%s*$")
    if body then
      t.choices = {}
      for x in list:gmatch("%d+") do t.choices[#t.choices + 1] = tonumber(x) end
      rest = body
    else
      local b2, to = rest:match("^(.-)%s*%->%s*(%d+)%s*$")
      if b2 then rest, t.next = b2, tonumber(to) end
    end
    t.body = rest
  else
    t.topic, t.body = raw:match("^#([%a_][%w_]*)%s*(.*)$")
    t.body = t.body or raw
  end
  return t
end
local function row_text(t)
  local s = t.n and (t.n .. " " .. t.body) or t.topic and ("#" .. t.topic .. " " .. t.body) or t.body
  if t.choices and #t.choices > 0 then s = s .. " [" .. table.concat(t.choices, ",") .. "]"
  elseif t.next then s = s .. " -> " .. t.next end
  if t.comment then s = s .. "  " .. t.comment end
  if (t.dx or 0) ~= 0 or (t.dy or 0) ~= 0 then s = s .. "  //@" .. t.dx .. "," .. t.dy end
  return s
end
DView.row_parts, DView.row_text = row_parts, row_text

function DView:edit_doc()                          -- the doc edits go to (opened if no tab has it)
  self.doc = self.doc or doc_of(self.filename) or core.open_doc(self.filename)
  return self.doc
end
function DView:get_row(row) return (self:edit_doc().lines[row] or ""):gsub("\n$", "") end
function DView:set_row(row, text)
  local doc = self:edit_doc()
  if self:get_row(row) == text then return end
  doc:remove(row, 1, row, math.huge)
  doc:insert(row, 1, text)
end
function DView:insert_row(after, text)             -- a new row after `after` -> its row
  local doc = self:edit_doc()
  after = math.min(after, #doc.lines)
  doc:insert(after, math.huge, "\n" .. text)
  return after + 1
end
function DView:delete_row(row)
  local doc = self:edit_doc()
  if row < #doc.lines then doc:remove(row, 1, row + 1, 1)
  elseif row > 1 then doc:remove(row - 1, math.huge, row, math.huge)
  else doc:remove(1, 1, 1, math.huge) end
end
function DView:changed() self:reload(); self.dirty = self.doc and self.doc:is_dirty() or false; core.redraw = true end
function DView:save()
  local doc = self:edit_doc()
  doc:save()
  self.dirty = false
end
function DView:box_of(id)
  for _, b in ipairs(self.boxes or {}) do if (b.topic and ("#" .. b.topic) or b.n) == id then return b end end
end
function DView:free_number(after)                  -- the first line number after `after` not taken
  local n = (after or -1) + 1
  while self.d.lines[n] do n = n + 1 end
  return n
end
function DView:last_row(b)                         -- the row a line's new answers / next go after
  local row = b.row
  for _, c in ipairs(b.choices or {}) do local cb = self.by[c]; if cb and cb.row > row then row = cb.row end end
  return row
end
function DView:move_to(id, wx, wy)                 -- write where its box is: //@dx,dy from its place
  local b = self:box_of(id)
  if not b then return end
  local t = row_parts(self:get_row(b.row))
  t.dx, t.dy = math.floor(wx - b.bx + 0.5), math.floor(wy - b.by + 0.5)
  self:set_row(b.row, row_text(t))
  self:changed()
end
function DView:link(from, to)                      -- an arrow from a line to line `to`: a choice, or its next
  local b = self.by[from]
  if not b then return end
  local t = row_parts(self:get_row(b.row))
  if t.choices then
    for _, c in ipairs(t.choices) do if c == to then return end end
    t.choices[#t.choices + 1] = to
  else t.next = to end
  self:set_row(b.row, row_text(t))
  self:changed()
end
function DView:unlink(from)
  local b = self.by[from]
  if not b then return end
  local t = row_parts(self:get_row(b.row))
  t.choices, t.next = nil, nil
  self:set_row(b.row, row_text(t))
  self:changed()
end
-- a new line: after line `from` (as its answer, or as its next), or alone; at wx, wy if given -> its number
function DView:new_line(from, how, wx, wy, text)
  local n, row
  if from then
    local b = self.by[from]
    n = self:free_number(from)
    local t = row_parts(self:get_row(b.row))
    local nt = { n = n, body = text or "..." }
    if how == "answer" then
      t.choices = t.choices or {}
      t.next = nil
      t.choices[#t.choices + 1] = n
    else
      nt.next = t.next                             -- (in the chain: the new line leads where it led)
      if t.choices then t.choices[#t.choices + 1] = n else t.next = n end
    end
    self:set_row(b.row, row_text(t))
    row = self:insert_row(self:last_row(b), row_text(nt))
  else
    local top, last = -1, 0
    for _, m in ipairs(self.d.order) do top = math.max(top, m); last = math.max(last, self.d.lines[m].row) end
    n = self:free_number(top)
    row = self:insert_row(last, row_text({ n = n, body = text or "..." }))
  end
  self:changed()
  if wx then self:move_to(n, wx, wy) end
  self.sel = n
  return n
end
function DView:new_topic(wx, wy)
  local name, i = "topic", 1
  while self.d.topics[name] do i = i + 1; name = "topic" .. i end
  self:insert_row(#self:edit_doc().lines, "#" .. name .. " ...")
  self:changed()
  if wx then self:move_to("#" .. name, wx, wy) end
  self.sel = "#" .. name
  return name
end
function DView:delete(id)                          -- a line (and the arrows to it) or a #topic
  local b = self:box_of(id)
  if not b then return end
  if not b.topic then
    for _, m in ipairs(self.d.order) do
      local L = self.d.lines[m]
      local refers = L.next == id
      for _, c in ipairs(L.choices or {}) do refers = refers or c == id end
      if m ~= id and refers then
        local t = row_parts(self:get_row(L.row))
        if t.next == id then t.next = nil end
        if t.choices then
          local keep = {}
          for _, c in ipairs(t.choices) do if c ~= id then keep[#keep + 1] = c end end
          t.choices = keep
        end
        self:set_row(L.row, row_text(t))
      end
    end
  end
  self:delete_row(b.row)
  if self.sel == id then self.sel = nil end
  self:changed()
end

local SOCKET = 10                                  -- (the right edge of a box: drag from it to link)
function DView:socket_at(wx, wy)
  for _, b in ipairs(self.boxes or {}) do
    if not b.topic and wy >= b.y and wy < b.y + b.h and math.abs(wx - (b.x + b.w)) <= SOCKET then return b end
  end
end
function DView:on_canvas_pressed(button, wx, wy, clicks)
  if button ~= "left" then return false end
  local s = self:socket_at(wx, wy)
  if s and clicks < 2 then
    self.wiring = { from = s.n, x = wx, y = wy, x0 = wx, y0 = wy }
    self.sel = s.n
    core.redraw = true
    return true
  end
  local b = self:box_at(wx, wy)
  if b then
    self.sel = b.topic and ("#" .. b.topic) or b.n
    if clicks >= 2 then self:goto_row(b.row)
    else self.dragging = { id = self.sel, ox = wx - b.x, oy = wy - b.y, x0 = b.x, y0 = b.y } end
    core.redraw = true
    return true
  end
  return false
end
function DView:on_canvas_moved(wx, wy)
  if self.dragging then                            -- (moved live; written on release)
    local g = self.dragging
    local b = self:box_of(g.id)
    if b then b.x, b.y = math.floor(wx - g.ox + 0.5), math.floor(wy - g.oy + 0.5) end
    g.moved = true
    core.redraw = true
    return
  end
  if self.wiring then self.wiring.x, self.wiring.y = wx, wy; core.redraw = true; return end
  local b = self:box_at(wx, wy)
  local hot = b and (b.topic and ("#" .. b.topic) or b.n)
  local sock = self:socket_at(wx, wy)
  sock = sock and sock.n
  if hot ~= self.hot or sock ~= self.hot_socket then self.hot, self.hot_socket = hot, sock; core.redraw = true end
  self.cursor = sock and "hand" or "arrow"
end
function DView:on_canvas_released(button, wx, wy)
  local g, w = self.dragging, self.wiring
  self.dragging, self.wiring = nil, nil
  if g and g.moved then
    local b = self:box_of(g.id)
    if b and (b.x ~= g.x0 or b.y ~= g.y0) then self:move_to(g.id, b.x, b.y) end
  elseif w then
    local t = self:box_at(wx, wy)
    if t and not t.topic then self:link(w.from, t.n)
    elseif not t and math.abs(wx - w.x0) + math.abs(wy - w.y0) > 20 then
      local fb = self.by[w.from]
      self:new_line(w.from, fb and fb.choices and "answer" or "next", wx, wy - LH)
    end
  end
  core.redraw = true
end

local next_check = 0
function DView:update()
  DView.super.update(self)
  local now = system.get_time()
  if now < (self.next_check or 0) then return end
  self.next_check = now + 0.25                     -- the text changed (typed, or on disk): drawn again
  local src = self:source()
  if src ~= self.src then self:reload() end
  self.dirty = self.doc ~= nil and self.doc:is_dirty() or false
  if now >= next_check then
    next_check = now + 0.5
    if P.changed("config") then load_config(); self:reload() end
    if P.changed("files") then P.open_with(P.read("files") or {}, DView) end
  end
end

local KIND = {                                     -- box colours: header stripe, fill
  say = { { 240, 120, 200, 255 }, { 44, 40, 58, 255 } },
  answer = { { 110, 170, 250, 255 }, { 36, 44, 60, 255 } },
  topic = { { 250, 200, 90, 255 }, { 52, 46, 34, 255 } },
}
function DView:draw_canvas()
  local px, py = self.position.x, self.position.y
  if self.err then renderer.draw_text(style.font, self.err, px + style.padding.x, py + style.padding.y, style.error or style.text) return end
  local z = self:z()
  local font = D.font(math.max(6, math.floor(12 * z)))
  local function S(x, y) return self:to_screen(x, y) end
  local wire_c = { style.dim[1], style.dim[2], style.dim[3], 200 }
  for _, b in ipairs(self.boxes or {}) do          -- the arrows first (under the boxes)
    local x1, y1 = S(b.x + b.w, b.y + b.h / 2)
    local function to(t, c)
      local tb = self.by[t]
      if not tb then return end
      if tb == b then                              -- (to itself: a small loop on its right)
        local lx, ly = S(b.x + b.w + 18, b.y + b.h / 2)
        D.wire(x1, y1 - 6 * z, lx, ly, c, math.max(1, 1.5 * z))
        D.wire(lx, ly, x1, y1 + 6 * z, c, math.max(1, 1.5 * z))
        return
      end
      local lw = math.max(1, 1.5 * z)
      if tb.x > b.x then                           -- the next column: from its right side to the other's left
        local x2, y2 = S(tb.x, tb.y + tb.h / 2)
        D.wire(x1, y1, x2, y2, c, lw)
        D.arrow(x2, y2, 1, 0, 6 * z, c, lw)
        return
      end
      local sx, sy = S(b.x, b.y + b.h / 2)          -- the same column, or back left: out of its left side
      local x2, y2
      if tb.x == b.x then x2, y2 = S(tb.x, tb.y + tb.h / 2)   -- (into the other's left side, round the left)
      else x2, y2 = S(tb.x + tb.w, tb.y + tb.h / 2) end
      local bend = 30 * z
      local c2x = tb.x == b.x and x2 - bend or x2 + bend
      D.bezier(sx, sy, sx - bend, sy, c2x, y2, x2, y2, c, lw)
      D.arrow(x2, y2, tb.x == b.x and 1 or -1, 0, 6 * z, c, lw)
    end
    for _, c in ipairs(b.choices or {}) do to(c, { 110, 170, 250, 200 }) end
    if b.next then to(b.next, wire_c) end
  end
  for _, b in ipairs(self.boxes or {}) do
    local x, y = S(b.x, b.y)
    local w, h = b.w * z, b.h * z
    local k = KIND[b.kind]
    local id = b.topic and ("#" .. b.topic) or b.n
    D.rrect(x, y, w, h, 5 * z, lite_bg and lite_bg(k[2]) or k[2])
    D.rrect(x, y, 4 * z, h, 2 * z, k[1])
    if id == self.sel or id == self.hot then
      local c = id == self.sel and style.accent or { 255, 255, 255, 60 }
      renderer.draw_rect(x, y, w, math.max(1, z), c); renderer.draw_rect(x, y + h - math.max(1, z), w, math.max(1, z), c)
      renderer.draw_rect(x, y, math.max(1, z), h, c); renderer.draw_rect(x + w - math.max(1, z), y, math.max(1, z), h, c)
    end
    for i, l in ipairs(b.lines) do
      renderer.draw_text(font, l, x + PAD * z + 2 * z, y + (PAD + (i - 1) * LH) * z, style.text)
    end
    if not b.topic and (id == self.hot or id == self.sel or b.n == self.hot_socket) then   -- its socket: drag to link
      D.socket(x + w, y + h / 2, 9 * z, k[1], b.n == self.hot_socket)
    end
  end
  local g = self.wiring
  if g and self.by[g.from] then                    -- a link being dragged
    local b = self.by[g.from]
    local x1, y1 = S(b.x + b.w, b.y + b.h / 2)
    local x2, y2 = S(g.x, g.y)
    D.wire(x1, y1, x2, y2, style.accent, math.max(1, 2 * z))
  end
end
function DView:draw_overlay()
  local d = self.d
  if not d then return end
  local e = self.errors and self.errors[1]
  self:draw_status(e and ("line " .. e[1] .. ": " .. e[2]) or string.format("%s   %d lines, %d topics   drag its right edge: link   double-click: its text",
    self:get_name(), #d.order, #self.boxes - #d.order))
end

function DView:edit_text()
  local node = core.root_view.root_node:get_node_for_view(self)
  if node then require("plugins.tabflip").flip(node, self) end
end
function DView:menu_items()
  local DIV = require("plugins.contextmenu").DIVIDER
  local wx, wy = self:to_world(self.mx or 0, self.my or 0)
  local id = self.hot
  local b = id ~= nil and self:box_of(id)
  local items = {}
  local function add(text, f, tags) items[#items + 1] = { text = text, command = f, tags = tags } end
  if b then
    if not b.topic then
      local n = b.n
      if b.kind == "say" then add("Add answer", function() self:new_line(n, "answer") end, "choice;option;reply") end
      if not b.choices then add("Add next line", function() self:new_line(n, "next") end, "after;then;continue") end
      if b.next or b.choices then add("Unlink", function() self:unlink(n) end, "arrows;remove;disconnect") end
    end
    add(b.topic and "Delete topic" or "Delete line", function() self:delete(id) end, "remove")
    if (b.x ~= b.bx or b.y ~= b.by) then add("Reset position", function() self:move_to(id, b.bx, b.by) end, "layout;place") end
    add("Edit as text", function() self:goto_row(b.row) end, "source;code;flip")
  else
    add("New line", function() self:new_line(nil, nil, wx, wy) end, "add;say")
    add("New #topic", function() self:new_topic(wx, wy) end, "add;subject;ask")
    add("Edit as text", function() self:edit_text() end, "source;code;flip")
  end
  items[#items + 1] = DIV
  add("Fit", function() self:fit() end, "zoom;all")
  add("Reload", function() self:reload() end)
  add("Copy path", function() system.set_clipboard(self.filename) end)
  return items
end

command.add(function() return core.active_view and core.active_view:is(DView) end, {
  ["dialog:edit-as-text"] = function() core.active_view:edit_text() end,
  ["dialog:undo"] = function() local v = core.active_view; v:edit_doc():undo(); v:changed() end,
  ["dialog:redo"] = function() local v = core.active_view; v:edit_doc():redo(); v:changed() end,
  ["dialog:delete"] = function()
    local v = core.active_view
    if v.sel ~= nil and not require("plugins.contextmenu").show_context_menu then v:delete(v.sel) end
  end,
})
require("core.keymap").add { ["ctrl+z"] = "dialog:undo", ["ctrl+y"] = "dialog:redo", ["ctrl+shift+z"] = "dialog:redo", ["delete"] = "dialog:delete" }

-- a tab flips between the text and this chart (the icon left of its name)
local function exts()
  local set = {}
  for _, e in ipairs(P.read("files") or {}) do if type(e) == "string" then set[(e:lower():gsub("^%.", ""))] = true end end
  return set
end
require("plugins.tabflip").register {
  key = "dialog",
  name = "dialog",
  text = function(view)
    local f = view:is(DocView) and view.doc and view.doc.filename
    local e = f and f:match("%.([^%./\\]+)$")
    return e ~= nil and exts()[e:lower()] == true
  end,
  alt = function(view) return view:is(DView) end,
  to_alt = function(view)
    local v = DView({ filename = system.absolute_path(view.doc.filename) or view.doc.filename })
    v.doc = view.doc
    v:reload()
    return v
  end,
  to_text = function(view) return DocView(view.doc or core.open_doc(view.filename)) end,
  icon = function(x, y, s, c)                      -- two speech bubbles
    local t = math.max(1, math.floor(s / 7))
    local function bubble(bx, by, bw, bh)
      renderer.draw_rect(bx, by, bw, t, c); renderer.draw_rect(bx, by + bh - t, bw, t, c)
      renderer.draw_rect(bx, by, t, bh, c); renderer.draw_rect(bx + bw - t, by, t, bh, c)
    end
    bubble(x, y, math.floor(s * 0.7), math.floor(s * 0.45))
    bubble(x + math.floor(s * 0.3), y + math.floor(s * 0.55), math.floor(s * 0.7), math.floor(s * 0.45))
  end,
  tip = "Show as a chart",
  menu = "Toggle chart / text",
}

load_config()
P.open_with(P.read("files") or {}, DView)
return DView

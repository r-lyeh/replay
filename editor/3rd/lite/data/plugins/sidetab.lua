-- sidetab.lua - the left tab, drawn by Lite (Replay): the world's tree (its
-- filter box on top), and the selection's properties below it, the line
-- between them dragged up / down. It sits left of Lite's pane, under the
-- host's toolbar (host_side(): where, surface px); the host shows that part
-- of Lite's surface every frame, whatever the view, and sends it the mouse
-- there (and the keyboard while a value or the filter is typed).
--
-- The data is the viewer's (runtime/boot.lua, another Lua state):
--   host_world(fn, ...)   fn(world, ...) there (viewer_outline, viewer_props...)
--   host_tab(cmd, ...)    the host's side of it (replay.c, editor/side.h):
--     "state" -> { selected, sel = { all selected }, stopped, savable, ... }
--     "inspect" path (select it, open its source), "toggle" path (CTRL+click),
--     "prop" fn id ... (viewer_prop_<fn>(w, selection, id, ...)), "save" /
--     "undo" (the selection's), "tree_action" path item, "open_system" comp,
--     "hover" path (outlined in the game), "focus" on (the keyboard), ...
-- Tree rows: a click selects (on release; dragging reorders among
-- siblings), CTRL+click adds / removes, the box folds, RMB its menu.
-- Properties: as before in C (editor/tab.h): drag a number (SHIFT x10,
-- CTRL x0.1) or click to type, a slider, a toggle, drop-downs (lite's menus).
local core = require "core"
local style = require "core.style"
local keymap = require "core.keymap"
local RootView = require "core.rootview"
local ContextMenu = require "plugins.contextmenu"
local Field = require "plugins.canvas.field"
local Tip = require "plugins.canvas.tip"

local S = { tree = { scroll = 1, rows = 1, n = 0 }, props = { scroll = 0, list = {}, vis = 1 },
            filter = Field.new(""), images = {}, tip = { t = 0 } }
local P = 1                                        -- points -> px (SCALE), set each frame

local function F() return rawget(_G, "host_ui_font") or style.font end
local function row_h() return F():get_height() + math.floor(4 * P) end
local function lw() return math.max(1, math.floor(P)) end
local function host(cmd, ...) local f = rawget(_G, "host_tab"); if f then return f(cmd, ...) end end
local function world(fn, ...) local f = rawget(_G, "host_world"); if f then return f(fn, ...) end end
local function menu_open() return ContextMenu.show_context_menu end

local function fit(text, w)                        -- cut with ".." to fit w px
  text = tostring(text or "")
  local f = F()
  if f:get_width(text) <= w then return text end
  local lo, hi = 0, #text
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if f:get_width(text:sub(1, mid) .. "..") <= w then lo = mid else hi = mid - 1 end
  end
  while lo > 0 and text:byte(lo + 1) and text:byte(lo + 1) >= 0x80 and text:byte(lo + 1) < 0xC0 do lo = lo - 1 end
  return text:sub(1, lo) .. ".."
end
local function text_at(x, top, s, color)          -- s in a row whose top is top -> the x after it
  local f, rh = F(), row_h()
  return renderer.draw_text(f, s, x, top + math.floor((rh - f:get_height()) / 2), color)
end
local function rect(x, y, w, h, c) renderer.draw_rect(x, y, w, h, c) end
local function frame(x, y, w, h, c)
  local t = lw()
  rect(x, y, w, t, c); rect(x, y + h - t, w, t, c); rect(x, y, t, h, c); rect(x + w - t, y, t, h, c)
end
local function mix(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, 255 } end
local function syn(k) return style.syntax and style.syntax[k] or style.text end
local function inr(r, x, y) return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end

-- ---------------------------------------------------------------------------
-- the layout (px; the host's points times P), from the tab's rect
-- ---------------------------------------------------------------------------
local function layout()
  local x, y, w, h = 0, 0, 0, 0
  local hs = rawget(_G, "host_side")
  if hs then x, y, w, h = hs() end
  S.on = x and w and w > 0 and h > 0
  if not S.on then return end
  local L = {}
  L.x, L.y, L.w, L.h = x, y, w, h
  L.TW = w + 3 * P                                  -- the tab's width (its right edge: the host's, dragged there)
  L.row = row_h()
  L.bottom = y + h
  L.filter = { x = 6 * P, y = y + 3 * P, w = L.TW - 12 * P, h = L.row + 2 * P }
  L.tree_top = y + L.row + 10 * P                  -- the first tree row's top
  local pct = S.state and S.state.split or 50
  local foot = math.floor(L.bottom * pct / 100)
  foot = math.min(foot, L.bottom - 6 * L.row)
  foot = math.max(foot, L.tree_top + P + 3 * L.row)
  L.foot = foot                                    -- the line between the tree and the properties
  L.rows = math.max(1, math.min(256, math.floor((foot - L.tree_top - 5 * P) / L.row)))
  L.ptop = foot + 2 * P                            -- the properties' header
  L.pw = L.TW - 14 * P                             -- what their rows use (the scrollbar's in the rest)
  L.prow0 = L.ptop + L.row + 7 * P                 -- their first row's top
  L.pvis = math.max(1, math.floor((L.bottom - L.prow0 - 5 * P) / L.row))
  L.vx = math.floor(L.pw * 0.5)                    -- the value column
  L.vw = L.pw - L.vx - 4 * P
  L.sw = L.pw - 6 * P - L.vx                       -- a slider's span
  S.L = L
end

-- the tree's lines, Windows style (as editor/tab.h drew them): level L's
-- line at cx(L), each row's box (children) centred on it
local function cx(lv) return math.floor(12 * P + 4 * P + lv * 11 * P) end
local function name_x(lv) return cx(lv) + math.floor(11 * P + 5 * P) end
local HALF = function() return math.floor(4 * P) end

-- thumbnails (settings: thumbnails, px): /assets' previewed files as a matrix
local THUMB_PAD = 4
local function thumb_cw(px) return (px + 2 * THUMB_PAD) * P end
local function thumb_span(px) return math.ceil(((px + THUMB_PAD + 3) * P + row_h()) / row_h()) end
local function thumb_x0(lv) return cx(lv) + 7 * P end
local function grid_of(i)                          -- row i's grid: k (its line's row), kind, cells
  local g = S.tree.grids and S.tree.grids[i]
  if type(g) ~= "string" then return nil end
  local k, kind, rest = g:match("^(%d+)\n([^\n]*)\n(.*)$")
  if not k then return nil end
  local cells = {}
  for c in (rest .. "\n"):gmatch("(.-)\n") do if c ~= "" then cells[#cells + 1] = c end end
  return { k = tonumber(k), kind = kind, cells = cells }
end
local function image_of(path)
  local c = S.images[path]
  if c == nil then
    c = false
    local file = host("asset_file", path)
    if file then local img = renderer.image.load(file); c = img or false end
    S.images[path] = c
  end
  return c or nil
end

-- ---------------------------------------------------------------------------
-- fetching (every frame: playing, values change): the tree's visible rows,
-- the selection's properties; a change -> a redraw
-- ---------------------------------------------------------------------------
local function fetch_tree()
  local L, st, T = S.L, S.state, S.tree
  T.n = 0
  if not st.world then return end
  local thumb = nil
  if st.thumbs and st.thumbs > 0 then
    thumb = { cw = thumb_cw(st.thumbs), span = thumb_span(st.thumbs), room = L.TW - 8 * P - thumb_x0(0), ind = 11 * P }
  end
  local filter = S.filter.text
  for pass = 1, 2 do
    local out, total, paths, sel, kinds, shapes, grids =
      world("viewer_outline", math.max(1, T.scroll), L.rows, st.selected or "", st.reveal or false, filter, thumb)
    if type(out) ~= "table" then return end
    local first = T.scroll
    if st.reveal and sel and sel > 0 and (sel < T.scroll or sel >= T.scroll + L.rows) then T.scroll = sel - math.floor(L.rows / 2) end
    if T.scroll > total - L.rows + 1 then T.scroll = total - L.rows + 1 end
    if T.scroll < 1 then T.scroll = 1 end
    if T.scroll == first or pass == 2 then
      T.names, T.paths, T.kinds, T.shapes, T.grids, T.total = out, paths or {}, kinds or {}, shapes or {}, grids or {}, total or 0
      T.n = #out
      break
    end
  end
  if st.reveal then host("revealed"); st.reveal = false end
  T.ms = (not st.stopped and T.n > 0) and host("prof", T.paths) or nil
end

local KIND = { num = "n", bool = "b", str = "s", code = "c", table = "t", info = "i", color = "k", choice = "h",
               add = "a", member = "m", pick = "p", member_row = "M", action = "A" }
local function fetch_props()
  local st, PR = S.state, S.props
  PR.list = {}
  if not st.world or not st.selected or st.selected == "" then return end
  local rows = world("viewer_props", st.sel)
  if type(rows) ~= "table" then return end
  for _, r in ipairs(rows) do
    local p = { id = tostring(r[1] or ""), label = tostring(r[2] or "?"), text = tostring(r[3] or ""),
                kind = KIND[r[4] or "lit"] or "l", depth = tonumber(r[5]) or 0, mixed = r[6] and true or false,
                over = r[7] and true or false, cls = type(r[8]) == "string" and r[8]:sub(1, 1) or "",
                def = type(r[9]) == "string" and r[9] or "", opts = type(r[11]) == "string" and r[11] or "",
                tip = type(r[12]) == "string" and r[12] or "", ktext = type(r[13]) == "string" and r[13] or "",
                kopts = type(r[14]) == "string" and r[14] or "" }
    if type(r[10]) == "string" then
      local lo, hi, ri = r[10]:match("^range (%S+) (%S+) (%S+)")
      if lo then p.range, p.lo, p.hi, p.rint = true, tonumber(lo), tonumber(hi), ri ~= "0" end
    end
    PR.list[#PR.list + 1] = p
  end
end

local function sig_of(t, out)                      -- what was fetched, as text (did it change?)
  for k, v in pairs(t) do
    if type(v) == "table" then sig_of(v, out) else out[#out + 1] = tostring(k) .. "=" .. tostring(v) end
  end
  return out
end

function S:update()
  P = SCALE
  self.state = host("state") or {}
  layout()
  if not self.on then return end
  local st = self.state
  if st.selected ~= self.last_sel then self.last_sel = st.selected; self.props.scroll = 0 end
  fetch_tree()
  fetch_props()
  local id = host("take_rename")                   -- a field just added (+ component > a type): type its name now
  if id then
    local i = self:prop_find(id)
    if i and not self.edit then
      local p = self.props.list[i]
      if p.kind == "p" or p.kind == "h" then self:pick_open(i) else self:begin_edit(i) end
    end
  end
  local s = table.concat(sig_of({ st, self.tree.names or {}, self.tree.paths or {}, self.tree.ms or {}, self.tree.scroll,
                                  self.props.scroll, self.L.foot, self.L.TW, self.L.bottom, self.L.row }, {}), "|")
  for _, p in ipairs(self.props.list) do s = s .. p.id .. p.text .. tostring(p.mixed) .. tostring(p.over) .. p.cls end
  if s ~= self.sig then self.sig = s; core.redraw = true end
  if self.tip.want and not self.tip.shown and system.get_time() - self.tip.t >= Tip.DELAY then core.redraw = true end
end

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------
local function draw_scroll(sb, x, top, h, total, shown, first)   -- a thumb only, as lite's (4 pt, over the rows)
  sb.x, sb.top, sb.h, sb.total, sb.shown, sb.first = x, top, h, total, shown, first
  if not (total > shown and shown > 0 and h > 0) then sb.on = false return end
  sb.on = true
  local th = math.min(h, math.max(20 * P, h * shown / total))
  local ty = math.floor(top + (h - th) * first / (total - shown))
  sb.thumb = { x = x - 4 * P, y = ty, w = 4 * P, h = math.floor(th) }
  rect(sb.thumb.x, sb.thumb.y, sb.thumb.w, sb.thumb.h, (sb.drag or sb.hot) and (style.scrollbar2 or style.text) or (style.scrollbar or style.dim))
end
local function scroll_hit(sb, x, y)
  local t = sb.on and sb.thumb
  return t and x >= t.x - 3 * P and x < t.x + t.w + 2 * P and y >= t.y and y < t.y + t.h
end
local function scroll_first_at(sb, y, grab)
  local th = sb.thumb.h
  local span = sb.h - th
  if span <= 0 then return 0 end
  return math.floor((y - grab - sb.top) / span * (sb.total - sb.shown) + 0.5)
end
S.sb_tree, S.sb_props = {}, {}

local function tree_lines(shape, top)              -- -> where its name starts
  local lv = #shape - 2
  local f = F()
  if lv < 0 then return math.floor(cx(0) - f:get_width("/") / 2) end
  local L, t, h = S.L, lw(), HALF()
  local mid = top + math.floor((L.row - t) / 2)
  local bot = top + L.row
  local c, nx = cx(lv), name_x(lv)
  local own, fold = shape:sub(lv + 1, lv + 1), shape:sub(lv + 2, lv + 2)
  for i = 1, lv do if shape:sub(i, i) == "|" then rect(cx(i - 1), top, t, L.row, style.dim) end end
  if fold == "g" then
    if own == "T" then rect(c, top, t, L.row, style.dim) end
    return nx
  end
  rect(c, top, t, (own == "T" and bot or mid + t) - top, style.dim)
  rect(c, mid, nx - 3 * P - c, t, style.dim)
  if fold == "-" then rect(cx(lv + 1), mid, t, bot - mid, style.dim) end
  if fold == "-" or fold == "+" then
    local bx, by, bs = c - h, mid - h, 2 * h + t
    rect(bx, by, bs, bs, style.background2)
    frame(bx, by, bs, bs, style.text)
    rect(c - 2 * P, mid, 4 * P + t, t, style.accent)
    if fold == "+" then rect(c, mid - 2 * P, t, 4 * P + t, style.accent) end
  end
  return nx
end

local BANDS = { { 52, 144, 248 }, { 37, 192, 222 }, { 46, 229, 175 }, { 82, 250, 127 }, { 136, 252, 87 },
                { 195, 236, 60 }, { 242, 203, 44 }, { 255, 157, 34 }, { 255, 105, 30 }, { 255, 55, 55 } }
local function prof_bar(top, ms)                   -- a node's ms a tick out of a frame (1000 / 60 ms), right to left
  if not ms or ms < 0.001 then return end
  local L = S.L
  local f = math.min(1, ms / (1000 / 60))
  local k = math.min(10, math.floor(f * 10) + 1)
  local w = math.max(2 * P, f * (L.TW - 6 * P))
  local b = BANDS[k]
  rect(L.TW - 3 * P - w, top, w, L.row, { b[1], b[2], b[3], 110 + (k - 1) * 14 })
end

local function is_sel(p)
  local st = S.state
  if p == st.selected then return true end
  for _, q in ipairs(st.sel or {}) do if q == p then return true end end
  return false
end

function S:draw_grid(i, top, mx, my)               -- row i: a line of thumbnails (once: its first row shown)
  local g = grid_of(i)
  if not g then return end
  local L, px = self.L, self.state.thumbs
  local lv = #(self.tree.shapes[i] or "") - 2
  local cw, x0 = thumb_cw(px), thumb_x0(lv)
  local y0, ch = top - g.k * L.row, thumb_span(px) * L.row
  core.push_clip_rect(L.x, L.tree_top, L.TW - 5 * P, self.L.rows * L.row)
  local f = F()
  for j, path in ipairs(g.cells) do
    local c = { x = x0 + (j - 1) * cw, y = y0, w = cw - P, h = ch - P }
    if c.x + c.w > L.TW - 5 * P then break end
    local primary = path == self.state.selected
    local sel = primary or is_sel(path)
    local hot = inr(c, mx, my) and not menu_open()
    if sel or hot then rect(c.x, c.y, c.w, c.h, primary and style.selection or sel and style.line_highlight or style.background3) end
    local s = px * P
    local ix, iy = c.x + THUMB_PAD * P, c.y + THUMB_PAD * P
    rect(ix, iy, s, s, style.background)
    local img = g.kind == "image" and image_of(path)
    if img then
      local w, h = img:get_size()
      if w and w > 0 and h > 0 then
        local k = math.min(s / w, s / h)
        if k > 1 and s >= 2 * math.max(w, h) then k = math.floor(k) end
        renderer.draw_image(img, ix + math.floor((s - w * k) / 2), iy + math.floor((s - h * k) / 2), w * k, h * k)
      end
    else
      renderer.draw_text(f, path:match("%.([^./]+)$") or "?", ix + 3 * P, iy + 2 * P, style.dim)
    end
    local stem = (path:match("([^/]+)$") or path):gsub("^(.+)%.[^.]*$", "%1")
    local shown = fit(stem, cw - 4 * P)
    renderer.draw_text(f, shown, c.x + math.floor((c.w - f:get_width(shown)) / 2), c.y + (THUMB_PAD + 2) * P + s,
                       (sel or hot) and style.accent or style.text)
  end
  core.pop_clip_rect()
end

function S:draw_tree(mx, my)
  local L, T, st, f = self.L, self.tree, self.state, F()
  local tw = L.TW
  if st.world then                                 -- the filter box
    local r = L.filter
    local hover = inr(r, mx, my)
    rect(r.x, r.y, r.w, r.h, style.background)
    frame(r.x, r.y, r.w, r.h, (self.filter_focus or hover) and style.dim or (style.scrollbar2 or style.dim))
    local e = self.filter
    local xw = #e.text > 0 and f:get_width("x") + 10 * P or 0
    self.filter_x = { x = r.x + r.w - xw, y = r.y, w = xw, h = r.h }
    local tx, ty = r.x + 6 * P, r.y + math.floor((r.h - f:get_height()) / 2)
    core.push_clip_rect(r.x, r.y, r.w - xw, r.h)
    if #e.text > 0 or self.filter_focus then
      Field.draw(e, f, tx, ty, syn("normal"), style.caret)
    else
      renderer.draw_text(f, "filter", tx, ty, style.dim)
    end
    core.pop_clip_rect()
    if #e.text > 0 then renderer.draw_text(f, "x", self.filter_x.x + 4 * P, ty, inr(self.filter_x, mx, my) and syn("normal") or style.dim) end
  end
  for i = 1, T.n do
    local top = L.tree_top + (i - 1) * L.row
    local path, shape = T.paths[i] or "/", T.shapes[i] or " "
    if T.grids[i] then
      tree_lines(shape, top)
      local g = grid_of(i)
      if g and (g.k == 0 or i == 1) then self:draw_grid(i, top, mx, my) end
    else
      local primary = path == st.selected
      local sel = primary or is_sel(path)
      if sel then rect(2 * P, top, tw - 5 * P, L.row, primary and style.selection or style.line_highlight) end
      local ms = T.ms and T.ms[i]
      if ms and ms > 0 then prof_bar(top, ms) end
      local x = tree_lines(shape, top)
      local kind = T.kinds[i]
      local hot = mx >= 0 and mx < tw and my >= top and my < top + L.row and not menu_open()
      local c = (sel or hot) and style.accent or kind == "v" and style.dim or kind == "c" and mix(style.text, style.dim, 0.35)
                or kind == "x" and syn("function") or style.text
      local name, count = tostring(T.names[i] or ""):match("^([^\t]*)\t?(.*)$")
      local room = tw - 5 * P - x - (count ~= "" and f:get_width(" (00)") or 0)
      local ex = text_at(x, top, fit(name, room), c)
      if count ~= "" then text_at(ex + f:get_width(" "), top, count, (sel or hot) and style.text or style.dim) end
      if ms and ms >= 0.005 and mx >= 0 and mx < tw and my >= top and my < top + L.row then   -- hovered: its ms
        local t = string.format("%.2fms %5.2f%%", ms, ms * 100 / (1000 / 60))
        local w = math.ceil(f:get_width(t))
        local bg = style.background3
        rect(tw - 6 * P - w, top, w + 3 * P, L.row, { bg[1], bg[2], bg[3], 230 })
        text_at(tw - 4 * P - w, top, t, style.accent)
      end
    end
    local d = self.drag
    if d and d.kind == "tree" and d.moving and d.target == path then
      rect(2 * P, top + (d.after and L.row - 2 * P or -P), tw - 5 * P, 2 * P, style.caret)
    end
  end
  draw_scroll(self.sb_tree, tw - 5 * P, L.tree_top, L.rows * L.row, T.total or 0, L.rows, (T.scroll or 1) - 1)
end

local function member_cols(tw)                     -- a member's row: its name, its type (a link), its kind (a link)
  local f = F()
  return math.floor(tw * 0.40), math.floor(tw - math.max(f:get_width("{}"), f:get_width("var")) - 2 * P)
end
local function kind_glyph(k)
  local c = k:sub(1, 1)
  return c == "[" and "[]" or c == "(" and "()" or c == "{" and "{}" or "var"
end
local function draw_link(x, top, text, c, maxw, hot)   -- a drop-down's value: a link (underlined)
  local f = F()
  local s = fit(text, maxw)
  local ex = text_at(x, top, s, hot and style.accent or c)
  local ty = top + math.floor((S.L.row - f:get_height()) / 2)
  rect(x, ty + f:get_height() - 2 * P, ex - x, lw(), c)
  return ex
end

function S:can_save() local st = self.state return st.stopped and st.savable and st.selected and st.selected ~= "" and st.sel_dirty end
function S:can_undo()
  local st = self.state
  return st.selected and st.selected ~= "" and st.sel_dirty and (st.stopped and st.savable or (not st.stopped))
end

function S:draw_props(mx, my)
  local L, st, PR, f = self.L, self.state, self.props, F()
  local tw, full = L.pw, L.TW
  local top = L.ptop
  local bw = math.ceil(math.max(f:get_width("Save"), f:get_width("Undo"))) + 8 * P
  self.undo_r = { x = tw - 4 * P - bw, y = top + 3 * P, w = bw, h = L.row + P }
  self.save_r = { x = tw - 8 * P - 2 * bw, y = top + 3 * P, w = bw, h = L.row + P }
  for i, b in ipairs({ { self.save_r, "Save", self:can_save() }, { self.undo_r, "Undo", self:can_undo() } }) do
    local r, label, can = b[1], b[2], b[3]
    rect(r.x, r.y, r.w, r.h, can and inr(r, mx, my) and style.selection or style.line_highlight)
    renderer.draw_text(f, label, r.x + math.floor((r.w - f:get_width(label)) / 2), r.y + math.floor((r.h - f:get_height()) / 2),
                       not can and style.dim or i == 1 and syn("string") or style.accent)
  end
  local head = "props"
  if st.selected and st.selected ~= "" then
    if (st.nsel or 1) > 1 then head = "props  " .. st.nsel .. " selected"
    else head = "props  " .. (st.selected:match("([^/]+)$") or "/") end
  end
  text_at(12 * P, top + 3 * P, fit(head, self.save_r.x - 4 * P - 12 * P), style.accent)
  local y0 = L.prow0
  if not st.selected or st.selected == "" then
    text_at(12 * P, y0, fit("select a node", tw - 10 * P), style.dim)
    text_at(12 * P, y0 + L.row, fit("CTRL+click: more", tw - 10 * P), style.dim)
    self.sb_props.on = false
    return
  end
  local n = #PR.list
  if PR.scroll > n - L.pvis then PR.scroll = n - L.pvis end
  if PR.scroll < 0 then PR.scroll = 0 end
  local vx, vw = L.vx, L.vw
  local hover = (mx >= 0 and mx < full and my >= top and not menu_open()) and self:prop_at(my) or nil
  for k = 0, L.pvis - 1 do
    local i = PR.scroll + k + 1
    local p = PR.list[i]
    if not p then break end
    local rt = y0 + k * L.row
    local editing = self.edit and self.edit.id == p.id
    local active = (self.press and self.press.id == p.id) or editing
    if (i == hover and p.kind ~= "t" and p.kind ~= "i") or active then
      rect(2 * P, rt, full - 5 * P, L.row, active and style.selection or style.line_highlight)
    end
    local lx = 12 * P + p.depth * 9 * P
    if p.kind == "M" then                          -- a member: a line above it, its name, its type and kind links
      local tx, kx = member_cols(tw)
      if k > 0 then rect(2 * P, rt - P, full - 5 * P, lw(), style.divider) end
      if editing then
        self:draw_field(lx - 2 * P, rt - P, tx - lx - 4 * P, lx, rt, tx - lx - 8 * P)
      else
        text_at(lx, rt, fit(p.label, tx - lx - 6 * P), style.accent)
      end
      local on_row = i == hover
      draw_link(tx, rt, p.text, syn("function"), kx - tx - 8 * P, on_row and mx >= tx - 2 * P and mx < kx - 2 * P)
      draw_link(kx, rt, kind_glyph(p.ktext), syn("function"), tw - kx, on_row and mx >= kx - 2 * P)
    else
      local lwid = vx - 4 * P - lx
      if p.kind == "t" and p.text == "" then lwid = tw - 4 * P - lx end
      local c = p.depth == 0 and style.accent or style.text
      if p.cls == "i" then c = style.dim end
      if p.cls == "d" then rect(4 * P, rt, 2 * P, L.row - P, style.caret); c = style.text end
      if p.over then c = style.warn; rect(4 * P, rt, 2 * P, L.row - P, style.warn) end
      if p.kind == "a" or p.kind == "m" or (p.kind == "p" and p.label:sub(1, 1) == "+") then c = style.caret end
      text_at(lx, rt, fit(p.label, lwid), c)
      local d = self.drag
      if d and d.kind == "system" and d.moving and p.kind == "c" and p.depth == 0 and d.target == p.label then
        rect(2 * P, rt + (d.after and L.row - 2 * P or -P), full - 5 * P, 2 * P, style.caret)
      end
      if editing then
        self:draw_field(vx - 2 * P, rt - P, tw - vx - P, vx, rt, vw)
      elseif not (p.kind == "t" and p.text == "") then
        if p.kind == "n" and p.range and not p.mixed then   -- a slider: its place in the range, behind the number
          local fr = math.max(0, math.min(1, ((tonumber(p.text) or 0) - p.lo) / ((p.hi - p.lo) ~= 0 and (p.hi - p.lo) or 1)))
          rect(vx - 2 * P, rt, L.sw + 2 * P, L.row - P, style.background)
          rect(vx - 2 * P, rt, math.floor((L.sw + 2 * P) * fr), L.row - P, style.selection)
        end
        local tx = vx
        if p.kind == "k" and not p.mixed then      -- a colour: a swatch, then its numbers
          local r, g, b = p.text:match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
          local sw = math.floor(L.row * 1.4)
          rect(vx, rt + P, sw, L.row - 3 * P, { tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0, 255 })
          frame(vx, rt + P, sw, L.row - 3 * P, style.scrollbar2 or style.dim)
          tx = vx + sw + 4 * P
        end
        local drop = ((p.kind == "h" or (p.kind == "p" and (p.depth > 0 or p.label:sub(1, 1) == "+"))) and not p.mixed) or p.kind == "A"
        local t = p.mixed and "--" or p.text
        local col = p.kind == "n" and syn("number") or p.kind == "b" and syn("literal") or p.kind == "s" and syn("string")
                    or p.kind == "c" and syn("keyword") or syn("normal")
        if p.kind == "t" and p.text == "class" then col = style.caret end
        if p.kind == "i" then col = syn("comment") end
        if p.mixed or p.cls == "i" then col = style.dim end
        if p.kind == "s" and not p.mixed then t = '"' .. t .. '"' end
        if p.kind == "h" then col = syn("string") end
        if p.kind == "p" and p.depth > 0 then col = syn("function") end
        if p.kind == "p" and p.depth == 0 then col = syn("comment") end
        if p.kind == "a" or p.kind == "A" then col = style.caret end
        if p.kind == "m" then col = style.dim end
        if p.cls == "i" then col = style.dim end
        if drop then
          if p.kind == "p" and p.label:sub(1, 1) == "+" then col = style.caret end
          draw_link(tx, rt, t, col, vw - (tx - vx), i == hover and mx >= vx - 2 * P and mx < tw)
        else
          text_at(tx, rt, fit(t, vw - (tx - vx)), col)
        end
      end
    end
  end
  draw_scroll(self.sb_props, full - 5 * P, y0, L.pvis * L.row, n, L.pvis, PR.scroll)
end

function S:draw_field(bx, by, bw, x, top, room)    -- the value being typed, in its box
  local L, f, e = self.L, F(), self.edit.field
  rect(bx, by, bw, L.row + P, style.background)
  frame(bx, by, bw, L.row + P, style.scrollbar2 or style.dim)
  local ty = top + math.floor((L.row - f:get_height()) / 2)
  core.push_clip_rect(x, by, room, L.row + P)
  Field.draw(e, f, x, ty, syn("normal"), style.caret)   -- (typing: Lite's selection and caret, plugins/textproxy.lua)
  core.pop_clip_rect()
end

function S:draw()
  if not self.on then return end
  local L = self.L
  local mx, my = core.root_view.mouse.x, core.root_view.mouse.y
  if not self.inside_now then mx, my = -1e9, -1e9 end
  core.push_clip_rect(L.x, L.y, L.w, L.h)
  rect(L.x, L.y, L.w, L.h, style.background2)      -- (lite's side bar)
  self:draw_tree(mx, my)
  local split = self.split_drag and (style.pane_divider_drag or { 0x3f, 0xb8, 0xd8, 255 })   -- (as lite's own splits: core/node.lua)
                or self.split_hot and (style.pane_divider_hover or { 0x3a, 0x7d, 0x90, 255 })
                or (style.pane_divider or { 0x2a, 0x3c, 0x44, 255 })
  rect(0, L.foot - P, L.TW - 3 * P, 3 * P, split)   -- the line you can drag (lite's splits: node.lua)
  self:draw_props(mx, my)
  core.pop_clip_rect()
end

-- tooltips: over everything (an overlay), after the mouse rests
local TipOverlay = { modal = false }                -- (shown over everything, but the mouse stays where it is)
function TipOverlay.draw_overlay()
  local s = S
  s.tip.shown = false
  if not s.on or not s.tip.want or menu_open() or s.press or s.edit or s.drag then return end
  if system.get_time() - s.tip.t < Tip.DELAY then return end
  local W, H = renderer.get_size()
  local x, y, w, h = Tip.text(s.tip.want, s.tip.x, s.tip.y, { x = 0, y = 0, w = W, h = H })
  s.tip.shown = true
  return { x, y, w, h }
end
table.insert(core.overlays, TipOverlay)

function S:tip_text(mx, my)
  local st, L = self.state, self.L
  if inr(self.save_r, mx, my) or inr(self.undo_r, mx, my) then
    local what = (st.nsel or 1) > 1 and "the selected nodes" or "this node"
    local on_save = inr(self.save_r, mx, my)
    if not st.selected or st.selected == "" then return "Select a node first" end
    if on_save and not st.savable then return "This world can't be saved" end
    if on_save and not st.stopped then return "Stop the game first: changes made while playing aren't saved" end
    if not on_save and st.stopped and not st.savable then return "Undo: this world has no saved copy" end
    if not st.sel_dirty then return st.stopped and ("No changes: " .. what .. " matches the disk") or ("No changes since Play for " .. what) end
    if on_save and st.script then return "Save " .. what .. " as overrides (" .. tostring(st.opath) .. ")" end
    if on_save then return "Save " .. what .. " to disk (only its own components)" end
    if st.stopped then return "Undo: put " .. what .. " back as it is on disk" end
    return "Undo: put " .. what .. " back as it was when Play was pressed"
  end
  local i = my >= L.ptop and self:prop_at(my)
  if not i then return nil end
  local p, comp = self.props.list[i], ""
  for j = i, 1, -1 do if self.props.list[j].depth == 0 then comp = self.props.list[j].label break end end
  if p.over then return "Overridden: differs from the script. Right-click: back to the script's value" end
  if p.kind == "M" then
    local tx, kx = member_cols(L.pw)
    if mx >= kx - 2 * P then
      local mv = p.ktext:match(":(.*)$")
      return (mv and ("{} map of " .. mv .. " values") or p.ktext) .. ". Click: one value (var), a list ([] array), keys alone (() set), or keys and values ({} map: then its values' type; its keys: the type)"
    end
    if mx >= tx - 2 * P then return "Its type: a plain one or one of your classes" end
    return "A member. Double-click: rename it. Right-click: rename or remove"
  end
  if p.tip ~= "" then return p.tip end
  if p.cls == "e" then return "An item of its collection. Right-click: remove it" end
  if p.kind == "a" then local c = p.label:sub(3) return "Add a " .. c .. " component: what its class /classes/" .. c .. " starts with" end
  if p.cls == "i" then return "From its class /classes/" .. comp .. " (this node doesn't have it). Change it, or right-click: it's set here" end
  if p.range then return string.format("%g..%g%s (its member's min, max): drag to set it, CTRL+click to type it", p.lo, p.hi, p.rint and ", whole numbers" or "") end
  if p.kind == "h" then return "One of a few (its member's options): click to pick one" end
  if p.cls == "d" then return "Differs from its class /classes/" .. comp .. ": " .. p.def .. ". Right-click: back to the class's value" end
  if p.kind == "i" then return p.label .. " " .. p.text end
  if p.kind == "t" and p.depth == 0 and p.text == "class" then return "A " .. comp .. " has a class: /classes/" .. comp .. ", what every " .. comp .. " starts with" end
  return nil
end

-- ---------------------------------------------------------------------------
-- where things are
-- ---------------------------------------------------------------------------
function S:inside(x, y) local L = self.L return self.on and L and x >= L.x and x < L.x + L.w and y >= L.y and y < L.y + L.h end
function S:prop_at(y)
  local L = self.L
  if y < L.prow0 then return nil end
  local k = math.floor((y - L.prow0) / L.row)
  if k < 0 or k >= L.pvis then return nil end
  local i = self.props.scroll + k + 1
  return self.props.list[i] and i or nil
end
function S:prop_find(id) for i, p in ipairs(self.props.list) do if p.id == id then return i end end end
function S:tree_index(y)
  local L = self.L
  if y < L.tree_top or y >= L.foot - 3 * P then return nil end
  local i = math.floor((y - L.tree_top) / L.row) + 1
  return (i >= 1 and i <= self.tree.n) and i or nil
end
function S:tree_hit(x, y)                          -- the node under the point (a thumbnail's cell too)
  local i = self:tree_index(y)
  if not i then return nil end
  if self.tree.grids[i] then
    local g = grid_of(i)
    if not g then return nil end
    local px = self.state.thumbs
    local lv = #(self.tree.shapes[i] or "") - 2
    local cw, x0 = thumb_cw(px), thumb_x0(lv)
    local y0 = self.L.tree_top + (i - 1 - g.k) * self.L.row
    local j = math.floor((x - x0) / cw) + 1
    if x < x0 or j < 1 or j > #g.cells or y < y0 or y >= y0 + thumb_span(px) * self.L.row then return nil end
    return g.cells[j], i
  end
  return self.tree.paths[i], i
end
function S:on_fold_box(i, x)
  local shape = self.tree.shapes[i] or ""
  local lv = #shape - 2
  local fold = shape:sub(lv + 2, lv + 2)
  if lv < 0 or (fold ~= "-" and fold ~= "+") then return false end
  return x >= cx(lv) - HALF() - 2 * P and x <= cx(lv) + HALF() + 2 * P
end
function S:on_split(y) return math.abs(y - self.L.foot) <= 3 * P end

-- ---------------------------------------------------------------------------
-- typing: a value, or the filter
-- ---------------------------------------------------------------------------
function S:set_focus()
  self.filter_focus = Field.focused(self.filter)
  core.redraw = true                               -- (the keyboard: Lite's while a box types, plugins/textproxy.lua tells the host)
end
function S:begin_edit(i)
  local p = self.props.list[i]
  if not p then return end
  local text = (p.kind == "p" or p.kind == "M") and p.label or (p.mixed or p.kind == "m") and "" or p.text
  if self.filter_focus then Field.blur(self.filter) end
  local e = { id = p.id, kind = p.kind, field = Field.new(text) }
  self.edit = e
  Field.focus(e.field, {                           -- (Lite edits it: selection, words, the clipboard, undo)
    font = F(), select_all = true,                 -- (all of it selected: typing replaces it)
    on_key = function(k)
      if k == "return" or k == "keypad enter" then self:end_edit(true) return true end
      if k == "escape" then self:end_edit(false) return true end
      if k == "tab" then                           -- commit, then type the next value
        local j = self:prop_find(e.id)
        self:end_edit(true)
        self:refetch()
        for n = (j or 0) + 1, #self.props.list do
          if ("nsl"):find(self.props.list[n].kind, 1, true) then self:begin_edit(n) break end
        end
        return true
      end
      return false
    end,
    on_blur = function() if self.edit == e then self:end_edit(true) end end,   -- (a click elsewhere in Lite: kept)
  })
  self:set_focus()
end
function S:end_edit(commit)
  local e = self.edit
  if not e then return end
  self.edit = nil
  Field.blur(e.field)
  if not commit and e.id == 'return { "?name" }' then host("naming_cancel") end   -- (renaming a new node: ESC keeps its name)
  if commit then host("prop", "viewer_prop_set", e.id, e.field.text, e.kind == "s" and "str" or "lit") end
  self:set_focus()
end
function S:focus_filter()
  if Field.focused(self.filter) then return end
  if self.edit then self:end_edit(true) end
  Field.focus(self.filter, {
    font = F(),
    on_key = function(k)
      if k == "return" or k == "keypad enter" then Field.blur(self.filter); self:set_focus() return true end
      if k == "escape" then
        if #self.filter.text > 0 then Field.set(self.filter, ""); self.tree.scroll = 1
        else Field.blur(self.filter); self:set_focus() end
        return true
      end
      return false
    end,
    on_change = function() self.tree.scroll = 1; core.redraw = true end,
    on_blur = function() self:set_focus() end,
  })
  self:set_focus()
end
function S:blur()                                  -- a click elsewhere: the value typed is kept, the filter left
  if self.edit then self:end_edit(true) end
  if Field.focused(self.filter) then Field.blur(self.filter); self:set_focus() end
end
function S:refetch() self.state = host("state") or self.state; fetch_props() end

-- ---------------------------------------------------------------------------
-- menus: the tree's (a node's), a member's, a drop-down's (lite's own)
-- ---------------------------------------------------------------------------
local function parse_items(s)                      -- "a|b>x,y|c" -> { { "a" }, { "b", sub = { "x", "y" } }, { "c" } }
  local out = {}
  for it in (s .. "|"):gmatch("(.-)|") do
    if it ~= "" then
      local name, sub = it:match("^([^>]*)>(.*)$")
      if name then
        local list = {}
        for x in (sub .. ","):gmatch("(.-),") do if x ~= "" then list[#list + 1] = x end end
        out[#out + 1] = { name, sub = list }
      else out[#out + 1] = { it } end
    end
  end
  return out
end
local function menu_items(parsed, cur, act)        -- act(item [, sub])
  local items = {}
  for _, it in ipairs(parsed) do
    if it[1] == "-" then items[#items + 1] = ContextMenu.DIVIDER
    elseif it.sub then
      local sub = {}
      for _, x in ipairs(it.sub) do sub[#sub + 1] = { text = x, command = function() act(it[1], x) end } end
      items[#items + 1] = { text = it[1], sub = sub }
    else
      items[#items + 1] = { text = it[1], checked = cur ~= nil and cur ~= "" and it[1] == cur or nil, command = function() act(it[1]) end }
    end
  end
  return items
end
function S:tree_menu(path, x, y)
  local s = world("viewer_tree_menu", path)
  if type(s) ~= "string" or s == "" then return end
  local items = menu_items(parse_items(s), nil, function(item, sub)
    host("tree_action", path, sub and (item .. ":" .. sub) or item)
  end)
  ContextMenu:show_items(x, y, items, { search = #items > 6 })
end
function S:pick_list(i, list, cur, x, which)       -- a row's drop-down (which: "" its own, "kind", "type", "name")
  local p = self.props.list[i]
  if not p then return end
  local parsed = parse_items(list)
  if #parsed == 0 then return end
  local id = p.id
  local items = menu_items(parsed, cur, function(item, sub)
    if not sub and item == "Rename" then
      local j = self:prop_find(id)
      if j then self:begin_edit(j) end
      return
    end
    host("prop", "viewer_prop_pick", id, sub and (item .. ":" .. sub) or item, which)
  end)
  local L = self.L
  local rt = L.prow0 + (i - 1 - self.props.scroll) * L.row
  ContextMenu:show_items(x - 4 * P, rt + L.row, items, { search = which == "" or which == "type" or #parsed > 6 })
  local m = ContextMenu.m
  if m and m.y < rt + L.row and rt - m.h >= 0 then m.y = rt - m.h end   -- (no room below: up from the row)
end
function S:pick_open(i)                            -- a row's own list (kinds p, h)
  local p = self.props.list[i]
  self:pick_list(i, p.opts, (p.kind == "p" and p.depth == 0) and "" or p.text, self.L.vx, "")
end

-- ---------------------------------------------------------------------------
-- the mouse
-- ---------------------------------------------------------------------------
function S:prop_click(i, x, clicks)
  local p = self.props.list[i]
  local k = p.kind
  if k == "n" then                                 -- scrub, or (on release) type it
    if p.range and keymap.modkeys["ctrl"] then self:begin_edit(i) return end   -- (a slider: CTRL+click types it)
    local v = tonumber(p.text) or 0
    local isint = v == math.floor(v)
    local a = math.abs(v)
    self.press = { id = p.id, x = x, sent = 0, scrub = false, slide = p.range, isint = isint,
                   base = isint and 0.5 or a < 1 and 0.005 or a < 100 and 0.05 or 0.5 }
    if p.range then self.press.scrub = true; self:slide(x) end
  elseif k == "b" then host("prop", "viewer_prop_toggle", p.id)
  elseif k == "h" or k == "p" then self:pick_open(i)
  elseif k == "M" then
    local tx, kx = member_cols(self.L.pw)
    if x >= kx - 2 * P then self:pick_list(i, p.kopts, p.ktext, kx, "kind")
    elseif x >= tx - 2 * P then self:pick_list(i, p.opts, p.text, tx, "type")
    elseif clicks >= 2 then self:begin_edit(i) end
  elseif k == "a" then host("prop", "viewer_prop_add_class", p.id)
  elseif k == "A" then host("action", p.opts)
  elseif k == "s" or k == "l" or k == "k" or k == "m" then self:begin_edit(i)
  end
end
function S:slide(x)
  local L = self.L
  local f = L.sw > 0 and (x - L.vx) / L.sw or 0
  host("prop", "viewer_prop_slide", self.press.id, math.max(0, math.min(1, f)))
end
function S:scrub(x)
  local pr = self.press
  if pr.slide then self:slide(x) return end
  local dx = (x - pr.x) / P                        -- (in points: the steps as before)
  if not pr.scrub and math.abs(dx) > 3 then pr.scrub = true end
  if not pr.scrub then return end
  local k = keymap.modkeys["shift"] and 10 or keymap.modkeys["ctrl"] and 0.1 or 1
  local want = dx * pr.base * k
  if pr.isint and k >= 1 then want = math.floor(want + 0.5) end
  local d = want - pr.sent
  if d == 0 then return end
  if pr.isint and d == math.floor(d) and math.tointeger then d = math.tointeger(d) or d end
  host("prop", "viewer_prop_add", pr.id, d)
  pr.sent = want
end

function S:pressed(button, x, y, clicks)
  local L, st = self.L, self.state
  self.held = (self.held or 0) + 1
  if self.filter_focus and not inr(L.filter, x, y) then Field.blur(self.filter); self:set_focus() end
  if button == "left" then
    for _, sb in ipairs({ self.sb_tree, self.sb_props }) do
      if scroll_hit(sb, x, y) then
        if self.edit then self:end_edit(true) end
        sb.drag = true
        sb.grab = y - sb.thumb.y
        self.sb_drag = sb
        return true
      end
    end
    if st.world and inr(L.filter, x, y) then
      if #self.filter.text > 0 and inr(self.filter_x, x, y) then
        Field.set(self.filter, ""); self.tree.scroll = 1
        if not Field.focused(self.filter) then self.filter = Field.new("") end
      else
        local was = Field.focused(self.filter)
        self:focus_filter()
        if was or clicks > 1 or true then Field.mouse(self.filter, "pressed", x, y, clicks); self.field_drag = self.filter end
      end
      self:set_focus()
      return true
    end
    if self:on_split(y) then
      if self.edit then self:end_edit(true) end
      if clicks == 2 then host("split", false) else self.split_drag = true end
      return true
    end
  end
  if y >= L.foot then                              -- the properties
    if button == "left" and (inr(self.save_r, x, y) or inr(self.undo_r, x, y)) then
      if self.edit then self:end_edit(true) end
      if inr(self.save_r, x, y) then if self:can_save() then host("save") end
      elseif self:can_undo() then host("undo") end
      return true
    end
    local i = self:prop_at(y)
    if button == "left" then
      if i then
        local p = self.props.list[i]
        if self.edit and self.edit.id ~= p.id then self:end_edit(true) end
        if self.edit and self.edit.id == p.id then   -- (typing it: a click in it places the caret, a drag selects)
          Field.mouse(self.edit.field, "pressed", x, y, clicks); self.field_drag = self.edit.field
          return true
        end
        self:prop_click(i, x, clicks)
        if p.kind == "c" and p.depth == 0 then   -- a system: open on release, drag = reorder
          self.drag = { kind = "system", comp = p.label, path = st.selected, y0 = y }
        elseif p.kind == "c" then host("open_system", p.label) end
      elseif self.edit then self:end_edit(true) end
    elseif button == "right" and i then
      local p = self.props.list[i]
      if self.edit then self:end_edit(false) end
      if p.kind == "M" then self:pick_list(i, "Rename|Remove", "", 13 * P, "name")
      elseif p.over then host("prop", "viewer_prop_revert", p.id)
      elseif p.cls == "d" or p.cls == "i" then host("prop", "viewer_prop_class_revert", p.id)
      elseif p.cls == "e" then host("prop", "viewer_prop_remove", p.id) end
    end
    return true
  end
  if self.edit then self:end_edit(true) end        -- the tree
  local hit, i = self:tree_hit(x, y)
  if button == "left" and hit then
    local ctrl = keymap.modkeys["ctrl"] or host("take_ctrl")
    if not ctrl and i and not self.tree.grids[i] and self:on_fold_box(i, x) then world("viewer_tree_fold", hit)
    elseif ctrl then host("toggle", hit)
    else self.drag = { kind = "tree", path = hit, y0 = y } end
  elseif button == "right" and hit then
    self:tree_menu(hit, x, y)
  end
  return true
end

function S:moved(x, y)
  local L = self.L
  if self.field_drag then Field.mouse(self.field_drag, "moved", x, y) return end
  if self.sb_drag then
    local sb = self.sb_drag
    local first = math.max(0, math.min(sb.total - sb.shown, scroll_first_at(sb, y, sb.grab)))
    if sb == self.sb_tree then self.tree.scroll = first + 1 else self.props.scroll = first end
    core.redraw = true
    return
  end
  if self.split_drag then
    host("split", math.floor(y * 100 / L.bottom + 0.5))
    core.redraw = true
    return
  end
  local d = self.drag
  if d then
    if not d.moving and math.abs(y - d.y0) > 4 * P then d.moving = true end
    if d.moving then self:drag_target(y) end
    core.redraw = true
    return
  end
  if self.press then self:scrub(x) return end
  -- hovering
  local hot = self.split_hot
  self.split_hot = self:on_split(y)
  if hot ~= self.split_hot then core.redraw = true end
  local th = y < L.foot and self:tree_hit(x, y) or nil
  if th ~= self.hover then self.hover = th; host("hover", th or "") end
  for _, sb in ipairs({ self.sb_tree, self.sb_props }) do
    local h = scroll_hit(sb, x, y) and true or false
    if h ~= (sb.hot or false) then sb.hot = h; core.redraw = true end
  end
  local tip = self:tip_text(x, y)
  if tip ~= self.tip.want or math.abs(x - (self.tip.x or 0)) > 0 then
    if tip ~= self.tip.want then self.tip.t = system.get_time() end
    self.tip.want, self.tip.x, self.tip.y = tip, x, y
  end
  core.redraw = true                               -- (hover lights rows and links)
  -- the cursor: what a click would do
  local cur = "arrow"
  if self.split_hot then cur = "sizev"
  elseif #self.filter.text > 0 and inr(self.filter_x, x, y) then cur = "hand"   -- (its x: clears it)
  elseif inr(L.filter, x, y) then cur = "ibeam"
  elseif inr(self.save_r, x, y) then cur = self:can_save() and "hand" or "arrow"
  elseif inr(self.undo_r, x, y) then cur = self:can_undo() and "hand" or "arrow"
  elseif y >= L.foot then
    local i = self:prop_at(y)
    local k = i and self.props.list[i].kind
    cur = k == "n" and "sizeh" or (k == "s" or k == "l" or k == "k") and "ibeam"
          or (k and ("bchpam"):find(k, 1, true)) and "hand" or "arrow"
    if k == "M" then local tx = member_cols(L.pw); cur = x >= tx - 2 * P and "hand" or "arrow" end
  elseif th then cur = "hand" end
  system.set_cursor(cur)
end

function S:drag_target(y)
  local d, L = self.drag, self.L
  d.target = nil
  if d.kind == "tree" then
    local i = self:tree_index(y)
    if not i or self.tree.grids[i] then return end
    local t = self.tree.paths[i]
    local pa, pb = d.path:match("^(.*)/[^/]*$") or "/", t:match("^(.*)/[^/]*$") or "/"
    if pa == "" then pa = "/" end
    if pb == "" then pb = "/" end
    if t == d.path or pa ~= pb or t == "/" then return end
    d.target = t
    d.after = y - (L.tree_top + (i - 1) * L.row) > L.row / 2
  else
    local i = self:prop_at(y)
    local p = i and self.props.list[i]
    if not p or p.kind ~= "c" or p.depth ~= 0 or p.label == d.comp then return end
    d.target = p.label
    d.after = y - (L.prow0 + (i - 1 - self.props.scroll) * L.row) > L.row / 2
  end
end

function S:released(button)
  self.held = math.max(0, (self.held or 1) - 1)
  if self.field_drag then Field.mouse(self.field_drag, "released", 0, 0); self.field_drag = nil return end
  if self.sb_drag then self.sb_drag.drag = nil; self.sb_drag = nil; core.redraw = true return end
  if self.split_drag then self.split_drag = false; host("split", true); core.redraw = true return end
  local d = self.drag
  if d and button == "left" then
    self.drag = nil
    if d.moving then
      if d.target then
        if d.kind == "tree" then world("viewer_tree_move", d.path, d.target, d.after)
        else world("viewer_system_move", d.path, d.comp, d.target, d.after) end
        host("changed")
      end
    elseif d.kind == "tree" then host("inspect", d.path)
    else host("open_system", d.comp) end
    core.redraw = true
    return
  end
  if self.press and button == "left" then
    local pr = self.press
    self.press = nil
    if not pr.scrub then local i = self:prop_find(pr.id); if i then self:begin_edit(i) end end
    core.redraw = true
  end
end

function S:wheel(dy)
  local L = self.L
  local mx, my = core.root_view.mouse.x, core.root_view.mouse.y
  if keymap.modkeys["ctrl"] then host("font", dy > 0 and 1 or dy < 0 and -1 or 0) return end
  if my >= L.foot then
    self.props.rest = (self.props.rest or 0) - dy * 3
    local n = self.props.rest >= 0 and math.floor(self.props.rest) or math.ceil(self.props.rest)
    self.props.rest = self.props.rest - n
    self.props.scroll = self.props.scroll + n
  else
    self.tree.rest = (self.tree.rest or 0) - dy * 3
    local n = self.tree.rest >= 0 and math.floor(self.tree.rest) or math.ceil(self.tree.rest)
    self.tree.rest = self.tree.rest - n
    self.tree.scroll = self.tree.scroll + n
  end
  core.redraw = true
end

-- the root view sends it what's in its rect (or held there); lite's menus first
local captured = false
local rv_pressed, rv_released, rv_moved, rv_wheel =
  RootView.on_mouse_pressed, RootView.on_mouse_released, RootView.on_mouse_moved, RootView.on_mouse_wheel
function RootView:on_mouse_pressed(button, x, y, clicks)
  if not menu_open() and S:inside(x, y) then
    captured = true
    S.inside_now = true
    S.tip.want = nil
    return S:pressed(button, x, y, clicks)
  end
  if not menu_open() then S:blur() end
  return rv_pressed(self, button, x, y, clicks)
end
function RootView:on_mouse_released(button, ...)
  if captured then
    S:released(button)
    if (S.held or 0) == 0 then captured = false end
    return
  end
  return rv_released(self, button, ...)
end
function RootView:on_mouse_moved(x, y, ...)
  if not menu_open() and (captured or S:inside(x, y)) then
    self.mouse.x, self.mouse.y = x, y
    S.inside_now = true
    return S:moved(x, y)
  end
  if S.inside_now then                             -- (out of it: nothing hovered there now)
    S.inside_now = false
    S.tip.want = nil
    if S.hover then S.hover = nil; host("hover", "") end
    S.split_hot = false
    core.redraw = true
  end
  return rv_moved(self, x, y, ...)
end
function RootView:on_mouse_wheel(dy, ...)
  if not menu_open() and S:inside(self.mouse.x, self.mouse.y) then return S:wheel(dy) end
  return rv_wheel(self, dy, ...)
end
core.side = S                                      -- (core.step: updated, drawn beside the pane)
rawset(_G, "lite_side_blur", function() S:blur() end)   -- (the host: a click outside lite)
return S

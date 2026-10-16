-- menu.lua - canvas.menu: popup menus drawn on a canvas (Replay), the node
-- graph's, shared: items, headers, separators, submenus (hovering opens them
-- beside), dim items, hints on the right, rows of colour squares, a search
-- box that filters every item of every submenu (fuzzy, best first), a scroll
-- bar when taller than the view, the keyboard (up / down / page / home /
-- end / enter / backspace).
--
--   local menu = canvas.menu
--   local m = menu.open(x, y, items, bounds, { search = true })   -- bounds: { x, y, w, h } (the view)
--   menu.draw(m, mx, my)                 -- (last: over everything)
--   local it, sub = menu.item_at(m, mx, my); menu.hover(m, mx, my, bounds)
--   menu.step(m, 1); menu.jump(m, 1); menu.type(m, "a", bounds); menu.erase(m, bounds)
--
-- items: { text =, fn = function() end, hint = "", dim = true, checked = true / false, sub = { ... },
--   tags = "alias;other words" (the search finds it by these too) },
-- { header = true, text = }, { sep = true } (or { header = true, sep = true }),
-- { swatches = canvas.picker.PALETTE, current =, fn = function(colour) end }.
-- A menu is plain data ({ x, y, w, h, items, rows, scroll, hot, child, search... }):
-- the view keeps it (the node graph: self.menu) and adds what it needs.
local core = require "core"
local style = require "core.style"
local T = require "plugins.canvas.theme"
local D = require "plugins.canvas.draw"
local Picker = require "plugins.canvas.picker"
local C, rgb = T.C, T.rgb

local M = {}
M.SWATCH_STEP = 22

local function utf8_cont(b) return b and b >= 128 and b < 192 end

-- a menu at x, y (kept inside bounds; parent: the menu it opens from)
function M.make(x, y, items, bounds, parent, search)
  local f = style.font
  local w = search and f:get_width("Search...") + 40 * SCALE or 0
  for _, it in ipairs(items) do
    if it.swatches then w = math.max(w, #it.swatches * M.SWATCH_STEP * SCALE - 16 * SCALE)
    elseif it.text then w = math.max(w, f:get_width(it.text) + (it.sub and 16 * SCALE or 0) + (it.hint and f:get_width(it.hint) + 24 * SCALE or 0)) end
  end
  local ih = f:get_height() + 8 * SCALE
  local top = search and ih + 6 * SCALE or 0       -- (a search box: a row above the items)
  local px, py, sw, sh = bounds.x, bounds.y, bounds.w, bounds.h
  local rows = math.max(1, math.min(#items, math.floor((sh - 8 * SCALE - top) / ih)))
  local mw, mh = w + 32 * SCALE, rows * ih + 8 * SCALE + top
  if x + mw > px + sw then                         -- no room on the right: to the left (of its parent)
    x = math.max(px, parent and parent.x - mw + 2 * SCALE or x - mw)
  end
  if y + mh > py + sh then y = math.max(py, py + sh - mh) end
  core.redraw = true
  return { x = x, y = y, w = mw, h = mh, ih = ih, items = items, rows = rows, scroll = 0, parent = parent, top = top }
end

-- opts.search: a search box on top: typing filters every item of every submenu
function M.open(x, y, items, bounds, opts)
  local search = opts and opts.search
  local m = M.make(x, y, items, bounds, nil, search)
  if search then
    m.search, m.all, m.x0, m.y0, m.w0 = "", items, m.x, m.y, m.w
    m.flat = {}
    local function walk(list, path)
      for _, it in ipairs(list) do
        if it.sub and type(it.sub) == "table" then walk(it.sub, path and (path .. " > " .. it.text) or it.text)
        elseif it.fn and not it.header then
          m.flat[#m.flat + 1] = { text = it.text, fn = it.fn, hint = path, key = ((path or "") .. " " .. it.text):lower(),
                                  tags = it.tags and (";" .. it.tags:lower() .. ";"),   -- (aliases: "a;b;c": whole words of the query, never letters scattered)
                                  bonus = it.bonus, rank = #m.flat + 1 }
        end
      end
    end
    walk(items, nil)
  end
  return m
end

-- how well a query matches a text (nil: not at all). Each word of the query
-- must be found; a word matches as a substring (better at a word's start)
-- or, failing that, as a subsequence.
function M.fuzzy_score(query, key, name)
  local score, loose = 0, false                    -- loose: some word matched only as scattered letters
  name = name:lower()
  for word in query:lower():gmatch("%S+") do
    local best
    local s = 1
    while true do                                  -- substrings: at a word start is best
      local a = key:find(word, s, true)
      if not a then break end
      local start = a == 1 or key:sub(a - 1, a - 1):match("[^%w]") ~= nil
      local v = (start and 10 or 4) + (name:find(word, 1, true) and 3 or 0)
      best = math.max(best or 0, v)
      s = a + 1
    end
    if not best then                               -- a subsequence: m..e..x
      local i, gaps, last = 1, 0, nil
      for c in word:gmatch(".") do
        local a = key:find(c, i, true)
        if not a then i = nil break end
        if last and a > last + 1 then gaps = gaps + 1 end
        last, i = a, a + 1
      end
      if i then best = math.max(1, 3 - gaps); loose = true end
    end
    if not best then return nil end
    score = score + best
  end
  return score - #name / 100, loose                -- (ties: the shorter name)
end

-- the search changed: its items again (best first)
function M.refilter(m, bounds)
  if not (m and m.search) then return end
  local q = m.search
  local items
  if not q:match("%S") then
    items = m.all
  else
    local hits = {}
    for _, it in ipairs(m.flat) do
      local s, loose = M.fuzzy_score(q, it.key, it.text)
      if (not s or loose) and it.tags then         -- an alias: each word of the query starts one of them
        local t = 0
        for word in q:lower():gmatch("%S+") do
          if not it.tags:find(";" .. word, 1, true) and not it.tags:find(" " .. word, 1, true) then t = nil break end
          t = t + 6
        end
        if t then s, loose = t, false end
      end
      if s then hits[#hits + 1] = { it = it, s = s + (it.bonus or 0), loose = loose } end
    end
    local tight = false                            -- real matches found: scattered-letter ones are noise then
    for _, h in ipairs(hits) do if not h.loose then tight = true break end end
    if tight then
      local keep = {}
      for _, h in ipairs(hits) do if not h.loose then keep[#keep + 1] = h end end
      hits = keep
    end
    table.sort(hits, function(a, b)
      if a.s ~= b.s then return a.s > b.s end
      if a.it.rank and b.it.rank then return a.it.rank < b.it.rank end
      return a.it.key < b.it.key
    end)
    items = {}
    for _, h in ipairs(hits) do items[#items + 1] = { text = h.it.text, fn = h.it.fn, hint = h.it.hint } end
    if #items == 0 then items[1] = { text = "(no match)", dim = true } end
  end
  local nm = M.make(m.x0, m.y0, items, bounds, nil, true)
  m.items, m.rows, m.h, m.scroll, m.child = items, nm.rows, nm.h, 0, nil
  m.w = m.fixed_w or math.max(m.w0, nm.w)
  if m.max_rows then m.rows = math.min(m.rows, m.max_rows); m.h = m.rows * m.ih + 8 * SCALE + m.top end
  m.hot = nil
  for i, it in ipairs(items) do if not it.header and not it.dim and not it.sub then m.hot = i break end end
  if not q:match("%S") then m.hot = nil end
  core.redraw = true
end
function M.type(m, text, bounds) m.search = m.search .. text; M.refilter(m, bounds) end
-- its search box typed in lite (plugins/textproxy.lua: selection, words, the
-- clipboard, undo). opts: keys(k) -> true (the menu's own: up, down, enter...),
-- changed() (default: refilter in opts.bounds()), alive() (the menu still open)
function M.edit_search(m, opts)
  if not (m and m.search) then return nil end
  opts = opts or {}
  local TP = require "plugins.textproxy"
  m.tp = TP.open(m.search, {
    font = style.font,
    on_key = opts.keys,
    on_change = function(t)
      m.search = t
      if opts.changed then opts.changed() else M.refilter(m, opts.bounds and opts.bounds()) end
    end,
    on_blur = function() m.tp = nil; if opts.blurred then opts.blurred() end end,
    alive = opts.alive,
  })
  return m.tp
end
function M.end_search(m) local h = m and m.tp; if h then m.tp = nil; h:close() end end
function M.search_at(m, x, y)                      -- on its search box? (its rect: as last drawn)
  local r = m and m.search_rect
  return r and x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4]
end
function M.erase(m, bounds, all)                   -- backspace (all: ctrl+backspace)
  local s = m.search
  if all then m.search = "" else
    local i = #s
    while i > 0 and utf8_cont(s:byte(i)) do i = i - 1 end
    m.search = s:sub(1, math.max(0, i - 1))
  end
  M.refilter(m, bounds)
end

function M.chain(m)                                -- the open menus, the first one to the deepest
  local list = {}
  while m do list[#list + 1] = m; m = m.child end
  return list
end
function M.at(m, x, y)                             -- the menu under the point (the deepest first), the row there
  local list = M.chain(m)
  for k = #list, 1, -1 do
    local mm = list[k]
    if x >= mm.x and x <= mm.x + mm.w and y >= mm.y and y <= mm.y + mm.h then
      local r = math.floor((y - mm.y - 4 * SCALE - (mm.top or 0)) / mm.ih) + 1
      if r >= 1 and r <= mm.rows then return mm, r + mm.scroll end
      return mm, nil
    end
  end
end
function M.item_at(m, x, y)                        -- an item that can be picked, and its menu
  local mm, i = M.at(m, x, y)
  local it = mm and i and mm.items[i]
  return it and not it.header and not it.sep and it or nil, mm
end
function M.open_child(mm, i, bounds)               -- item i's submenu, beside its row (-> it)
  local it = mm.items[i]
  if not (it and it.sub) then return nil end
  if not (mm.child and mm.child.from == i) then
    local sub = type(it.sub) == "function" and it.sub() or it.sub
    mm.child = M.make(mm.x + mm.w - 2 * SCALE, mm.y + (mm.top or 0) + (i - 1 - mm.scroll) * mm.ih, sub, bounds, mm)
    mm.child.from = i
  end
  return mm.child
end
function M.hover(m, x, y, bounds)                  -- hovering a submenu's item opens it beside its row
  local mm, i = M.at(m, x, y)
  if not mm then return end
  if i ~= mm.hot then mm.hot = i; core.redraw = true end
  local it = i and mm.items[i]
  if it and it.sub then
    M.open_child(mm, i, bounds)
  elseif it and not it.header and mm.child then
    mm.child = nil
    core.redraw = true
  end
end
function M.swatch_at(m, it, x)                     -- (a row of colour squares: the one at x)
  local k = math.floor((x - m.x - 12 * SCALE) / (M.SWATCH_STEP * SCALE)) + 1
  return it.swatches[k] ~= nil and k or nil
end

local function pickable(it) return it and not it.header and not it.dim and not it.sep end
function M.step(m, d)                              -- up / down (it wraps)
  local n, i = #m.items, m.hot or (d > 0 and 0 or #m.items + 1)
  for _ = 1, n do
    i = i + d
    if i < 1 then i = n elseif i > n then i = 1 end
    if pickable(m.items[i]) then break end
  end
  m.hot, m.child = i, nil
  if i <= m.scroll then m.scroll = i - 1 elseif i > m.scroll + m.rows then m.scroll = i - m.rows end
  core.redraw = true
end
function M.jump(m, to)                             -- to an item (no wrap): the nearest pickable one there
  local n = #m.items
  to = math.max(1, math.min(n, to))
  local i = to
  while i <= n and not pickable(m.items[i]) do i = i + 1 end
  if i > n then i = to; while i >= 1 and not pickable(m.items[i]) do i = i - 1 end end
  if i < 1 then return end
  m.hot, m.child = i, nil
  if i <= m.scroll then m.scroll = i - 1 elseif i > m.scroll + m.rows then m.scroll = i - m.rows end
  core.redraw = true
end
function M.page(m) return math.max(1, m.rows - 1) end
-- its scroll bar (on its right edge, when it scrolls): pressed -> the menu
-- (dragged from there: M.drag_bar); the thumb's middle follows the mouse
local BAR_W = 10
function M.bar_at(m, x, y)
  local list = M.chain(m)
  for k = #list, 1, -1 do
    local mm = list[k]
    if #mm.items > mm.rows and x >= mm.x + mm.w - BAR_W * SCALE and x <= mm.x + mm.w
       and y >= mm.y + (mm.top or 0) and y <= mm.y + mm.h then return mm end
  end
end
function M.drag_bar(mm, y)
  local top = mm.top or 0
  local span = mm.h - top
  local f = (y - mm.y - top) / math.max(1, span)
  mm.scroll = math.max(0, math.min(#mm.items - mm.rows, math.floor(f * #mm.items - mm.rows / 2 + 0.5)))
  mm.child = nil
  core.redraw = true
end
function M.wheel(m, x, y, dy)                      -- -> true when a menu there scrolled
  local mm = M.at(m, x, y)
  if not mm or #mm.items <= mm.rows then return mm ~= nil end
  mm.scroll = math.max(0, math.min(#mm.items - mm.rows, mm.scroll - (dy > 0 and 1 or -1)))
  mm.child = nil
  core.redraw = true
  return true
end

-- its colours: the node graph's (dark, blue hover), or with the light theme
-- (canvas.theme's `light`: plugins/nodegraph/theme.lua's set_light) the
-- theme's own popup colours, as the main menu (editor/bar.h)
local function look()
  if not T.light then
    return { bg = rgb"#181818", shadow = C.shadow, field = C.field, text = C.text, dim = C.dim, sep = rgb"#3c3c44",
             hot = rgb"#4772b3", hottext = C.text, open = rgb"#33415a", caret = C.active, frame = C.frame, border = nil }
  end
  local function st(k, d) return style[k] or rgb(d) end
  return { bg = st("background3", "#ffffff"), shadow = T.alpha(rgb"#000000", 40), field = st("background", "#fbfbfc"),
           text = st("text", "#5b5f68"), dim = st("dim", "#a3a7af"), sep = st("divider", "#dcdee2"),
           hot = st("selection", "#bfe5ee"), hottext = st("accent", "#2b2f36"), open = st("line_highlight", "#e5e8eb"),
           caret = st("caret", "#0b97b0"), frame = st("divider", "#dcdee2"), border = st("divider", "#dcdee2") }
end

function M.draw(m, mx, my)
  local f, r = style.font, 4 * SCALE
  local K = look()
  mx, my = mx or -1, my or -1
  for _, mm in ipairs(M.chain(m)) do
    D.rrect(mm.x + 2 * SCALE, mm.y + 3 * SCALE, mm.w, mm.h, r, K.shadow)
    if K.border then D.rrect(mm.x - 1, mm.y - 1, mm.w + 2, mm.h + 2, r, K.border) end
    D.rrect(mm.x, mm.y, mm.w, mm.h, r, K.bg)
    core.push_clip_rect(mm.x, mm.y, mm.w, mm.h)
    local y = mm.y + 4 * SCALE
    if mm.search then                              -- the search box
      local bx, bw, bh = mm.x + 6 * SCALE, mm.w - 12 * SCALE, mm.ih
      D.rrect(bx, y, bw, bh, 3 * SCALE, K.field)
      local empty = mm.search == ""
      local tx = bx + 8 * SCALE
      mm.search_rect = { bx, y, bw, bh }
      if mm.tp and mm.tp:alive() then              -- (typed in lite: its selection, its caret)
        if empty then renderer.draw_text(f, "Search...", tx, y + 4 * SCALE, K.dim) end
        mm.tp:place(tx, y + 4 * SCALE, f:get_height())
        require("plugins.textproxy").draw(mm.tp, f, tx, y + 4 * SCALE, K.text, style.selection, K.caret)
      else
        renderer.draw_text(f, empty and "Search..." or mm.search, tx, y + 4 * SCALE, empty and K.dim or K.text)
        local cx = empty and tx or tx + f:get_width(mm.search)
        renderer.draw_rect(cx, y + 3 * SCALE, style.caret_width, bh - 6 * SCALE, K.caret)
      end
      y = y + mm.top
    end
    for i = mm.scroll + 1, mm.scroll + mm.rows do
      local it = mm.items[i]
      if not it then break end
      if it.swatches then                          -- colour squares; the first one: none
        local smy = (my >= y and my < y + mm.ih) and my or nil
        Picker.swatches(mm.x + 12 * SCALE, y + 4 * SCALE, it.swatches, it.current, mx, smy, M.SWATCH_STEP * SCALE, mm.ih - 8 * SCALE)
      elseif it.sep then                           -- a separator: a line across
        renderer.draw_rect(mm.x + 8 * SCALE, y + mm.ih / 2, mm.w - 16 * SCALE, math.max(1, SCALE), K.sep)
      elseif it.header then
        renderer.draw_text(f, it.text, mm.x + 10 * SCALE, y + 4 * SCALE, K.dim)
        renderer.draw_rect(mm.x + 6 * SCALE, y + mm.ih - 2 * SCALE, mm.w - 12 * SCALE, math.max(1, SCALE), K.frame)
      else
        local open = mm.child and mm.child.from == i
        local lit = mm.hot == i and not it.dim
        if lit or open then D.rrect(mm.x + 3 * SCALE, y, mm.w - 6 * SCALE, mm.ih, 3 * SCALE, open and mm.hot ~= i and K.open or K.hot) end
        if it.checked then                         -- (checked: a dot left of its text)
          local d = math.max(2, math.floor(4 * SCALE))
          D.rrect(mm.x + 8 * SCALE - d / 2, y + mm.ih / 2 - d / 2, d, d, d / 2, lit and K.hottext or K.text)
        end
        renderer.draw_text(f, it.text, mm.x + 16 * SCALE, y + 4 * SCALE, it.dim and K.dim or (lit and K.hottext or K.text))
        if it.hint then                            -- (its key, or where a search result lives)
          renderer.draw_text(f, it.hint, mm.x + mm.w - 12 * SCALE - f:get_width(it.hint) - (it.sub and 10 * SCALE or 0), y + 4 * SCALE, K.dim)
        end
        if it.sub then                             -- a submenu: a small arrow
          local ax, ay, s = mm.x + mm.w - 14 * SCALE, y + mm.ih / 2, 3 * SCALE
          for k = 0, s do renderer.draw_rect(ax + k, ay - s + k, 1 * SCALE, 2 * (s - k) + 1, K.dim) end
        end
      end
      y = y + mm.ih
    end
    if #mm.items > mm.rows then                    -- a scroll bar
      local top = mm.top or 0                      -- (below the search box)
      local th = (mm.h - top) * mm.rows / #mm.items
      local ty = mm.y + top + (mm.h - top - th) * mm.scroll / (#mm.items - mm.rows)
      local hot = mm.bar_hot or mm.bar_drag
      D.rrect(mm.x + mm.w - (hot and 6 or 4) * SCALE, ty + 2 * SCALE, (hot and 4 or 2) * SCALE, th - 4 * SCALE, SCALE, hot and K.text or K.dim)
    end
    core.pop_clip_rect()
  end
end

-- lite's own menu items ({ text, info, command } from projectplugins,
-- openwith, the contextmenu) as canvas menu items ({ text, hint, fn, sub })
-- (eager: submenus built now, so a search finds their items; dividers:
-- separators; a command's key as its hint)
function M.from_lite(items, eager)
  local out = {}
  local ok_cm, cm = pcall(require, "plugins.contextmenu")
  local DIV = ok_cm and type(cm) == "table" and cm.DIVIDER
  local keymap = require "core.keymap"
  for _, it in ipairs(items or {}) do
    if it == DIV or (it and it.sep and not it.text) then
      if #out > 0 and not out[#out].sep then out[#out + 1] = { sep = true } end
    elseif it.text then
      local o = { text = it.text, hint = it.info, checked = it.checked, tags = it.tags }
      if it.sub then
        if eager then
          local ok, list = pcall(function() return type(it.sub) == "function" and it.sub() or it.sub end)
          o.sub = M.from_lite(ok and list or {}, true)
          if #o.sub == 0 then o.sub, o.dim = nil, true end
        else
          o.sub = function() return M.from_lite(type(it.sub) == "function" and it.sub() or it.sub) end
        end
      elseif type(it.command) == "function" then o.fn = it.command
      elseif type(it.command) == "string" then
        local c = it.command
        o.fn = function() require("core.command").perform(c) end
        o.hint = o.hint or (keymap.reverse_map and keymap.reverse_map[c] or nil)
      else o.dim = true end
      out[#out + 1] = o
    end
  end
  if out[#out] and out[#out].sep then out[#out] = nil end
  return out
end

return M

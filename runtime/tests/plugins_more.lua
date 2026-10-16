-- plugins_more.lua - the tilemap editor, "Open with >", the plugins' own tabs
-- (the main menu's Plugins >) and the shared colour picker, in lite.
--   play games/pong.lua --stopped --lite "dofile('runtime/tests/plugins_more.lua')@3" --frames 100000 --shot x.bmp
-- NG_EXIT exits when done. SHOW=tilemap|picker|openwith: leaves that in front
-- and doesn't exit (a screenshot: --frames 400 --shot x.bmp).
local core = require "core"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local show = os.getenv("SHOW")
  local function open(path)
    core.root_view:open_doc(core.open_doc(path))
    coroutine.yield(0.2)
    return core.active_view
  end
  local log0 = #(core.log_items or {})
  local function errors_since(n)
    for k = n + 1, #(core.log_items or {}) do
      local it = core.log_items[k]
      if tostring(it.text):lower():find("error", 1, true) or tostring(it.text):find("attempt to", 1, true) then return it.text end
    end
  end
  local tmp = os.tmpname()

  -- the tilemap editor: the sample opens; paint, fill, rect, erase, undo, save, read back
  local tm = tmp .. ".tmap"
  local src = io.open("plugins/tilemap/samples/island.tmap", "rb"):read("*a")
  local f = io.open(tm, "wb"); f:write(src); f:close()
  local v = open(tm)
  check(v and v.map and v.img, "tilemap: a .tmap opens in its tab, the tileset loaded")
  if v and v.map then
    local Map = require "plugins.tilemap.map"
    check(v.map.w == 40 and v.map.h == 26 and #v.map.layers == 3, "tilemap: the sample's size and layers")
    check(Map.get(v.map, 1, 0, 0) == 9, "tilemap: deep water in the corner")
    v.layer, v.sel, v.tool = 1, { 20, 20 }, "paint"
    v:begin_edit(); v:apply("left", 2, 2, true)
    check(Map.get(v.map, 1, 2, 2) == 20 and v.dirty, "tilemap: painted bricks")
    v.sel = { 16, 33 }                             -- (a 2 x 2 stamp: planks, log / ores)
    local st = v:stamp()
    check(st.w == 2 and st.h == 2 and st[1] == 16 and st[4] == 33, "tilemap: a stamp of 2 x 2 tiles")
    v:begin_edit(); v:apply("left", 5, 5, true)
    check(Map.get(v.map, 1, 6, 6) == 33, "tilemap: the stamp painted")
    v.sel, v.tool = { 4, 4 }, "fill"
    v:begin_edit(); v:apply("left", 0, 0, true)
    check(Map.get(v.map, 1, 0, 0) == 4 and Map.get(v.map, 1, 39, 25) == 4, "tilemap: fill (the deep water: sand)")
    v:undo_step(true)
    check(Map.get(v.map, 1, 0, 0) == 9, "tilemap: undo")
    Map.rect(v.map, 2, 1, 1, 3, 2, { w = 1, h = 1, 2 })
    check(Map.get(v.map, 2, 1, 1) == 2 and Map.get(v.map, 2, 3, 2) == 2 and Map.get(v.map, 2, 4, 2) ~= 2, "tilemap: a rectangle")
    v.layer = 2
    v:apply("right", 3, 2, true)
    check(Map.get(v.map, 2, 3, 2) == false, "tilemap: RMB erases")
    Map.resize(v.map, 10, 8)
    check(v.map.w == 10 and #v.map.layers[1].cells == 80, "tilemap: resize")
    v:save()
    local back = load(io.open(tm, "rb"):read("*a"), "=tmap", "t", {})()
    check(back and back.w == 10 and #back.layers[1].rows == 8 and #back.layers[1].rows[1] == 20, "tilemap: saved, reads back")
    check(not v:takes_right(v.position.x + 1, v.position.y + 1), "tilemap: RMB on its panel: the menu")
    coroutine.yield(0.3)
  end
  if show == "tilemap" then return end

  -- Open with: a .lua has text, its graph, hex; the tab menu gets the submenu
  local ow = require "plugins.openwith"
  local keys = {}
  for _, o in ipairs(ow.list("games/pong.lua")) do keys[#keys + 1] = o.key end
  local ks = table.concat(keys, ",")
  check(ks:find("text", 1, true) and ks:find("nodegraph", 1, true) and ks:find("hexedit", 1, true), "openwith: a .lua: " .. ks)
  local pk = {}
  for _, o in ipairs(ow.list("plugins/tilemap/tiles.png")) do pk[#pk + 1] = o.key end
  local ps = table.concat(pk, ",")
  check(not ps:find("text", 1, true) and ps:find("texviewer", 1, true) and ps:find("hexedit", 1, true), "openwith: a .png: no text: " .. ps)
  local it = ow.item("games/pong.lua")
  check(it and it.text == "Open tab with" and #it.sub() >= 3, "openwith: the submenu")
  local hv = ow.open("hexedit", "games/pong.lua")
  check(hv and hv.f and core.active_view == hv, "openwith: Open tab with > Hex editor")
  local again = ow.open("hexedit", "games/pong.lua")
  check(again == hv, "openwith: again: the same tab, focused")
  local gv = ow.open("nodegraph", "games/pong.lua")
  check(gv and gv ~= hv and gv.doc, "openwith: Open tab with > Node graph")
  -- Open beside with: in the other pane; the text's graph beside keeps its document
  local tabflip = require "plugins.tabflip"
  local tv = ow.open("text", "games/pong.lua")
  local tnode = core.root_view.root_node:get_node_for_view(tv)
  local bi = ow.beside_item("games/pong.lua", tv)
  local marks = {}
  for _, x in ipairs(bi and bi.sub() or {}) do marks[x.text] = x.info or "" end
  check(bi and bi.text == "Open beside with" and marks["Node graph"] == "CTRL+\\" and marks["Text"] == "a copy", "openwith: Open beside with > (CTRL+\\ marked, a copy)")
  local bg = ow.open_beside("nodegraph", "games/pong.lua", tv)
  local bnode = bg and core.root_view.root_node:get_node_for_view(bg)
  check(bg and bg.doc == tv.doc and bnode and bnode ~= tnode, "openwith: Open beside with > Node graph: the pane beside, the same document")
  local bh = ow.open_beside("hexedit", "games/pong.lua", tv)
  check(bh and core.root_view.root_node:get_node_for_view(bh) == bnode, "openwith: Open beside with > Hex editor: that pane too")
  check(ow.open_beside("hexedit", "games/pong.lua", tv) == bh, "openwith: beside again: the same tab")
  -- tab menus: each way once, not the view's own last items (Plugin: x)
  local menu = require "plugins.contextmenu"
  local function tab_menu_of(v)
    local n = core.root_view.root_node:get_node_for_view(v)
    require("plugins.tabmenu").show(n, v, 10, 10)
    local count = {}
    for _, x in ipairs(menu.all or {}) do if x.text then count[x.text] = (count[x.text] or 0) + 1 end end
    menu:hide()
    return count
  end
  for _, v in ipairs({ tv, bg, bh }) do
    local c = tab_menu_of(v)
    local plug = false
    for k in pairs(c) do if k:find("^Plugin:") then plug = true end end
    check(c["Open tab with"] == 1 and c["Open beside with"] == 1 and not plug and not c["Open a copy beside"],
          "tab menu: Open tab with / beside once, no Plugin: (" .. tostring(getmetatable(v).__name or "?") .. ")")
  end
  for _, v in ipairs({ bh, bg }) do                -- (the pane beside goes again)
    local n = core.root_view.root_node:get_node_for_view(v)
    if n then n:set_active_view(v); n:close_active_view(core.root_view.root_node) end
  end
  -- a menu taller than the window scrolls: the wheel, the keys, its bar
  local items = {}
  for k = 1, 200 do items[k] = { text = "item " .. k, command = function() end } end
  table.insert(menu.itemset, 1, { predicate = function() return true end, items = items })   -- (first: this one shows)
  menu:show(20, 20)
  table.remove(menu.itemset, 1)
  coroutine.yield(0.5)                             -- (it opens: grown to its height)
  local m = menu.m
  local _, sh = renderer.get_size()                -- (menus: over the whole window, not just lite's pane)
  check(m and m.rows < #m.items and m.y + m.h <= sh, "menu: taller than the window: it fits, it scrolls")
  menu:wheel(m.x + 5, m.y + m.top + 20, -2)
  check(m.scroll > 0, "menu: the wheel scrolls it (" .. tostring(m.scroll) .. ")")
  m.hot = 1; menu:move(-1)                         -- (up from the first: the last, in view)
  check(m.hot == 200 and m.scroll == 200 - m.rows, "menu: the keys keep the selected item in view")
  local CMod = require "plugins.canvas.menu"
  local bx, by = m.x + m.w - 3, m.y + m.top + 1
  check(CMod.bar_at(m, bx, by) == m, "menu: its scroll bar")
  menu:on_mouse_pressed("left", bx, by, 1); menu:on_mouse_moved(bx, by); menu:released()
  check(m.scroll == 0 and menu.show_context_menu, "menu: its bar dragged to the top (it stays open)")
  -- the look: the node graph's menu (canvas.menu) for every right-click menu
  check(m.search == "" and m.items[1].text == "item 1", "menu: canvas.menu's, with its search box")
  menu:hide()
  -- the markdown preview's contents: a section per ## of HELP.md, its ### in a submenu
  local mdv = ow.open("markdown", "docs/HELP.md"); coroutine.yield(0.5)
  local cs = mdv and mdv.contents_items and mdv:contents_items(mdv:layout()) or {}
  local subs, plain = 0, 0
  for _, it in ipairs(cs) do if it.sub then subs = subs + 1 else plain = plain + 1 end end
  local s1
  for _, it in ipairs(cs) do if it.sub and not s1 then s1 = it.sub() end end
  check(#cs >= 5 and #cs <= 10 and subs >= 3 and s1 and s1[1].info == "top" and #s1 > 1, "markdown: contents in sections (" .. #cs .. " items, " .. subs .. " submenus)")
  if mdv then local n = core.root_view.root_node:get_node_for_view(mdv); n:set_active_view(mdv); n:close_active_view(core.root_view.root_node) end
  coroutine.yield(0.3)
  if show == "openwith" then return end

  -- RMB on a chip (a variable read, left of its pin): its pin's menu, not the graph's
  if gv and gv.hits then
    core.set_active_view(gv)
    local t0 = system.get_time()
    repeat coroutine.yield(0.1) until gv.g or system.get_time() - t0 > 5
    local target                                   -- a node with a chip: in the middle, at 100%
    for _, n in ipairs(gv.g and gv.g.nodes or {}) do
      for _, p in ipairs(n.ins or {}) do if p.chip and not target then target = n end end
    end
    if target then
      gv.zoom = 1
      gv.pan.x, gv.pan.y = gv.size.x / 2 - (target.x + target.w / 2), gv.size.y / 2 - (target.y + target.h / 2)
      gv.fitted, gv.restored = true, true
    end
    coroutine.yield(0.2); gv:draw()
    local chip
    local kinds = {}
    for _, h in ipairs(gv.hits) do kinds[h.kind] = (kinds[h.kind] or 0) + 1; if h.kind == "chip" and h.side == "in" and not chip then chip = h end end
    local ks = {}
    for k, n in pairs(kinds) do ks[#ks + 1] = k .. "=" .. n end
    check(chip ~= nil, "nodegraph: pong.lua's graph shows chips: " .. table.concat(ks, " ") .. " size " .. gv.size.x .. "x" .. gv.size.y)
    if chip then
      gv.menu = nil
      gv:context_menu(chip.x + 2, chip.y + chip.h / 2)
      local first = gv.menu and gv.menu.items and gv.menu.items[1]
      check(first and first.header and first.text == chip.node.title, "nodegraph: RMB on a chip: its node's menu (" .. tostring(first and first.text) .. ")")
      local okd, errd = pcall(gv.draw, gv)          -- (its colour squares drawn, the mouse off them: no error)
      check(okd, "nodegraph: the menu with colour squares draws: " .. tostring(errd))
      gv.menu = nil
    end
  end

  -- keys: one bound elsewhere (space: the particle editor's play) doesn't eat the text here
  local keymap = require "core.keymap"
  core.set_active_view(gv or core.active_view)
  check(keymap.on_key_pressed("space") == false, "keys: space, bound for another view: not taken (its text goes in)")
  check(keymap.get_binding("nodegraph:redo") == "ctrl+y", "keys: redo shows CTRL+Y (" .. tostring(keymap.get_binding("nodegraph:redo")) .. ")")
  -- a comment box's title: several lines (SHIFT+ENTER), one line in its tag
  local G = require "plugins.nodegraph.graph"
  local tg = G.parse_tag("--@comment w=200 h=100 title=first line\\nsecond line")
  check(tg and tg.title == "first line\nsecond line", "nodegraph: a comment's title: two lines")
  check(G.tag_text(tg) == "--@comment w=200 h=100 title=first line\\nsecond line", "nodegraph: written back on one line: " .. tostring(G.tag_text(tg)))
  -- a menu open: its backspace wins (a markdown tab's backspace is "back")
  local cm = require "plugins.contextmenu"
  local dv = open("docs/HELP.md")                -- (a markdown tab: its backspace is "back")
  cm:show(dv.position.x + 50, dv.position.y + 50)
  check(cm.show_context_menu, "menu: open over a markdown tab")
  if cm.show_context_menu then
    core.root_view:on_text_input("ab")
    keymap.on_key_pressed("space")
    core.root_view:on_text_input(" ")              -- (space: its text, once no key took it)
    core.root_view:on_text_input("c")
    keymap.on_key_pressed("backspace")
    check(cm.m and cm.m.search == "ab ", "menu: typed 'ab c', backspace: '" .. tostring(cm.m and cm.m.search) .. "'")
    cm:hide()
  end

  -- the main menu's Plugins > <plugin> >: its commands with their keys
  local menu = lite_plugin_menu("nodegraph")
  check(menu:find("Find...\tCTRL+F", 1, true) and menu:find("Changes and diff", 1, true) and menu:find("Settings", 1, true),
        "plugins: the node graph's menu: Find CTRL+F, changes, settings")
  check(lite_plugin_menu("tilemap"):find("Paint\tB", 1, true), "plugins: the tilemap's: Paint B")

  -- the main menu's Plugins >: the plugins with a tab; a new untitled one
  local pp = require "plugins.projectplugins"
  local names = {}
  for _, t in ipairs(pp.tabs()) do names[#names + 1] = t.name end
  local ns = table.concat(names, ",")
  check(ns:find("particles", 1, true) and ns:find("tilemap", 1, true) and ns:find("sfxr", 1, true), "plugins: tabs: " .. ns)
  check(type(lite_plugin_tabs()) == "string" and lite_plugin_tabs():find("tilemap\tTilemap editor", 1, true), "plugins: the host's list")
  local nv = pp.open_tab("tilemap")
  check(nv and nv.untitled and nv:get_name() == "untitled.tmap" and core.active_view == nv, "plugins: Plugins > Tilemap editor: untitled")
  local pv = pp.open_tab("particles")
  check(pv and pv.untitled and pv.def and pv:get_name() == "untitled.pfx", "plugins: Plugins > Particle editor: untitled")
  coroutine.yield(0.3)

  -- the shared colour picker: the particle editor's colour rows open it
  local UI = require "plugins.canvas.ui"
  local P = require "plugins.canvas.picker"
  local got
  local p = P.new(100, 100, { 255, 0, 0, 255 }, function(c) got = c end, { alpha = true })
  check(P.hex(p) == "#ff0000", "picker: red")
  local _, sv = P.rects(p)
  p:pressed("left", sv.x + sv.w - 1, sv.y + sv.h / 2)
  p:released()
  check(got and got[1] > 100 and got[2] < 10, "picker: a drag in the square: a darker red")
  local _, _, _, _, hx = P.rects(p)
  p:pressed("left", hx.x + 2, hx.y + 2)
  core.on_event("textinput", "#00ff00")           -- (as real keys come: lite types it, plugins/textproxy.lua; all of it selected: replaced)
  core.on_event("keypressed", "return")
  check(got and got[1] == 0 and got[2] == 255 and got[3] == 0, "picker: a hex typed")
  local r, g, b, a = P.parse_hex("#abc")
  check(r == 0xaa and g == 0xbb and b == 0xcc and a == nil, "picker: #rgb")
  check(not p:pressed("left", 1, 1), "picker: a click outside: not its")
  if pv and pv.right then                          -- the particle editor's "Colour start": a click opens the picker
    pv.right.scroll = 1e6                          -- (the colours: at the bottom of its panel)
    pv:draw(); pv:draw()
    for _, h in ipairs(pv.right.hits) do
      if not UI.popup and h.press and not h.drag and not h.wheel and h[4] > 0 then
        local before = UI.popup
        h.press(h[1] + 1, h[2] + 1, 1, "left")
        if UI.popup and UI.popup ~= before then break end
      end
    end
    check(UI.popup ~= nil, "picker: a colour row opens it")
    if show == "picker" then core.redraw = true return end
    UI.popup = nil
  end
  -- the shared widgets (plugins/canvas): field, scrollbar, menu, ui's list / field / stepper
  local Fd = require "plugins.canvas.field"
  local e = Fd.new("héllo")
  Fd.left(e); Fd.left(e); Fd.backspace(e)
  check(e.text == "hélo" and e.cur == 4, "field: backspace in the middle (" .. e.text .. "," .. e.cur .. ")")
  Fd.home(e); Fd.insert(e, "> "); Fd.finish(e); Fd.left(e); Fd.left(e); Fd.left(e)
  check(e.text == "> hélo" and e.cur == 4, "field: home, insert, utf-8 steps (" .. e.cur .. ")")
  local SB = require("plugins.canvas.scrollbar").new()
  SB:draw(0, 0, 10, 100, 1000, 100, 0)
  local on, pos = SB:pressed(5, 99)
  check(on and pos > 850, "scrollbar: a click at the bottom: near the end (" .. tostring(pos) .. ")")
  SB:released()
  local CM = require "plugins.canvas.menu"
  local picked
  local m = CM.open(10, 10, { { text = "Apple", fn = function() picked = "a" end }, { text = "More", sub = { { text = "Banana split", fn = function() picked = "b" end } } } },
                    { x = 0, y = 0, w = 800, h = 600 }, { search = true })
  CM.type(m, "ban", { x = 0, y = 0, w = 800, h = 600 })
  check(#m.items == 1 and m.items[1].text == "Banana split" and m.hot == 1, "menu: search finds in submenus")
  m.items[m.hot].fn()
  check(picked == "b", "menu: picked")
  if v and v.map then                              -- the tilemap's layers: ui:list, a name typed in ui:field
    core.set_active_view(v)
    v:draw()
    local UI = require "plugins.canvas.ui"
    local fieldhit
    for _, h in ipairs(v.left.hits) do if h.press and h.tip and h.tip:find("rename") then fieldhit = h end end
    check(fieldhit ~= nil, "tilemap: its layer's name field")
    if fieldhit then
      v:on_mouse_pressed("left", fieldhit[1] + 2, fieldhit[2] + 2, 1); v:on_mouse_released("left", fieldhit[1] + 2, fieldhit[2] + 2)
      check(UI.editing ~= nil, "tilemap: the name field types")
      local km = require "core.keymap"             -- (as real keys come: lite edits it, plugins/textproxy.lua; the click put the caret at the start)
      km.modkeys["ctrl"] = true; core.on_event("keypressed", "a"); km.modkeys["ctrl"] = false   -- (CTRL+A: all of it, typing replaces it)
      core.on_event("textinput", "water b")       -- (b: the paint tool's key; typed here, it's text)
      core.on_event("keypressed", "return")
      check(v.map.layers[v.layer].name == "water b" and UI.editing == nil, "tilemap: renamed: " .. tostring(v.map.layers[v.layer].name))
    end
  end
  local av = open("games/lcd/assets/lcd.atlas.lua")   -- the atlas: its panels on canvas.ui
  if av and av.ui_left then
    av:draw(); coroutine.yield(0.1); av:draw()
    local rowhit
    for _, h in ipairs(av.ui_left.hits) do if h.press and not rowhit then rowhit = h end end
    check(rowhit ~= nil, "atlas: its list rows")
    if rowhit then rowhit.press(rowhit[1] + 2, rowhit[2] + 2, 1, "left"); check(av.sel ~= nil, "atlas: a row picks its frame: " .. tostring(av.sel)) end
    check(#av.ui_right.hits >= 0 and #av.ui_top.hits > 0, "atlas: toolbar buttons")
  else check(false, "atlas: opens") end

  local err = errors_since(log0)
  check(not err, "no errors logged: " .. tostring(err))
  for _, x in ipairs({ tm, tmp }) do os.remove(x) end
  print(string.format("plugins more: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(fail_n == 0 and 0 or 1) end
end)

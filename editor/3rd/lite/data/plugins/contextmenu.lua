-- contextmenu.lua - the right-click menu (lite's, extended for Replay).
--
-- A menu per kind of view: menu:register(predicate, items [, key]).
--   predicate: a view class (or its module name), or function(x, y) -> bool
--   items: a list, or a function returning one (built when the menu opens:
--          marks and labels can follow the state). An item:
--            { text = "Fit", command = "core:..." | function() end,
--              info = "dbl-click" (a hint at the right),
--              checked = true / false (a bullet / room for one) }
--          or ContextMenu.DIVIDER, or a submenu: { text = "Plugin: x",
--          sub = items (or a function returning them) }: hovering it (or
--          Right / Enter on it) opens its items beside it; Left closes it.
--          Typing searches the submenus' items too ("Plugin: x > Reload").
-- ContextMenu.last: functions(view) -> an item or nil, put at the bottom of
-- every menu, after a divider (none when the menu has nothing else)
-- (projectplugins.lua: a plugin's own view gets "Plugin: <name>", its common
-- commands: source, reload, settings...)
--   key: registering again with the same key replaces that entry (a plugin
--        reloaded)
-- The first entry that matches opens, except that a class's entry gives way
-- to one for a subclass of it (plugins/canvas registers its views' menus; a
-- plugin's own view, extending one of them, can register its own).
-- It looks and works as the node graph's (plugins/canvas/menu.lua draws it,
-- the same for every right-click menu): a search box on top (typing filters
-- every item of every submenu, best first), submenus beside (any depth), a
-- scroll bar when taller than the window (the wheel; drag it), Up / Down /
-- PageUp / PageDown / Home / End move, Right / Left in and out of a submenu,
-- Enter picks, Backspace takes a letter back, ESC or a click elsewhere
-- closes it.
-- Project plugins get it as P.menu(View, items) (projectplugins.lua).
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local Object = require "core.object"
local RootView = require "core.rootview"

local DIVIDER = {}

local ContextMenu = Object:extend()

ContextMenu.DIVIDER = DIVIDER

ContextMenu.last = {}

function ContextMenu:new()
  self.itemset = {}
  self.show_context_menu = false
end

local CM = require "plugins.canvas.menu"

local function bounds()                            --< Replay: the whole window (popups are drawn over everything: core.overlays)
  local w, h = renderer.get_size()
  return { x = 0, y = 0, w = w, h = h }
end

function ContextMenu:register(predicate, items, key)
  if type(predicate) == "string" then
    predicate = require(predicate)
  end
  local class
  if type(predicate) == "table" then
    class = predicate
    predicate = function() return core.active_view:is(class) end
  end
  local entry = { predicate = predicate, items = items, key = key, class = class }
  if key then
    for i, e in ipairs(self.itemset) do
      if e.key == key then self.itemset[i] = entry return end
    end
  end
  table.insert(self.itemset, entry)
end

local function derives(class, base)               -- class is base, or extends it
  while class do
    if class == base then return true end
    class = class.super
  end
  return false
end

function ContextMenu:show(x, y)
  self.all = nil
  local best                                       -- the first that matches; a subclass's menu wins over its parent's
  for _, entry in ipairs(self.itemset) do
    if entry.predicate(x, y) then
      if not best then best = entry
      elseif best.class and entry.class and entry.class ~= best.class and derives(entry.class, best.class) then best = entry end
    end
  end
  if best then
    local items = best.items
    if type(items) == "function" then items = items() end
    self.all = items
  end
  local last = {}                                  -- (at its bottom: "Plugin: <name>" for a plugin's view; a view
  for _, fn in ipairs(best and not self.no_last and ContextMenu.last or {}) do   --  with a menu of its own, as the node graph, adds it there; not a tab's: tabmenu.lua)
    local ok, it = pcall(fn, core.active_view)
    if ok and it then last[#last + 1] = it end
  end
  if #last > 0 then
    local all = {}
    for _, it in ipairs(self.all or {}) do all[#all + 1] = it end
    if #all > 0 then all[#all + 1] = DIVIDER end
    for _, it in ipairs(last) do all[#all + 1] = it end
    self.all = all
  end
  local items = CM.from_lite(self.all or {}, true)  -- (the canvas menu's items; submenus now: the search finds theirs)
  if #items == 0 then return false end
  self.m = CM.open(x, y, items, bounds(), { search = true })
  self.focus = self.m
  self.show_context_menu = true
  self:edit_search()
  core.redraw = true
  return true
end

-- Replay: a menu of given items at x, y (surface pixels): the host's menus
-- (plugins/mainmenu.lua: the bar's), anything. items: canvas.menu's or lite's
-- (as registered menus' items); opts.search (default: on), opts.on_close
function ContextMenu:show_items(x, y, items, opts)
  opts = opts or {}
  self:hide()
  local list = items
  if not opts.canvas then list = CM.from_lite(items or {}, true) end
  if #list == 0 then return false end
  self.m = CM.open(x, y, list, bounds(), { search = opts.search ~= false })
  self.focus = self.m
  self.on_close = opts.on_close
  self.show_context_menu = true
  self:edit_search()
  core.redraw = true
  return true
end

-- its search box: typed in lite (plugins/textproxy.lua). The menu's own keys
-- first: up / down / page up / down / home / end / enter / escape always;
-- left / right (submenus) while nothing is typed (then they move the caret);
-- SHIFT, CTRL, ALT + a key: the text's (SHIFT+HOME selects to its start...)
local MENU_KEYS
function ContextMenu:edit_search()
  local m = self.m
  if not (m and m.search) then return end
  CM.edit_search(m, {
    bounds = bounds,
    changed = function() CM.refilter(m, bounds()); self.focus = m end,
    alive = function() return self.m == m and self.show_context_menu end,
    keys = function(k)
      local cmd = MENU_KEYS[k]
      if not cmd or keymap.modkeys["ctrl"] or keymap.modkeys["alt"] or keymap.modkeys["shift"] then return false end
      if (k == "left" or k == "right" or k == "backspace") and m.search ~= "" then return false end
      if k == "backspace" then return false end
      command.perform(cmd)
      return true
    end,
  })
end

function ContextMenu:hide()
  local was = self.show_context_menu
  CM.end_search(self.m)                            -- (lite's focus back where it was: an item's command acts there)
  self.m, self.focus, self.drag = nil, nil, nil
  self.show_context_menu = false
  self.all = nil
  core.redraw = true
  local f = self.on_close
  self.on_close = nil
  if was and f then pcall(f) end
end

-- inside it (its search box too; an open submenu): a click there doesn't close it
function ContextMenu:inside(x, y) return self.m ~= nil and CM.at(self.m, x, y) ~= nil end

function ContextMenu:on_mouse_moved(px, py)
  if not self.show_context_menu then return end
  if self.drag then CM.drag_bar(self.drag, py) return true end
  if self.search_drag and self.m and self.m.tp then self.m.tp:mouse_moved(px, py) return true end
  for _, mm in ipairs(CM.chain(self.m)) do mm.bar_hot = nil end
  local bar = CM.bar_at(self.m, px, py)
  if bar then bar.bar_hot = true; core.redraw = true
  else
    CM.hover(self.m, px, py, bounds())
    local mm = CM.at(self.m, px, py)
    if mm then self.focus = mm end
  end
  if self:inside(px, py) then system.set_cursor("arrow") end
  return true
end

function ContextMenu:on_selected(item)
  if item.fn then item.fn() end
end

local function run(self, it)                       -- an item picked: closed first, then its command
  if not it or it.dim or it.header or it.sep then return end
  self:hide()
  self:on_selected(it)
end

function ContextMenu:on_mouse_pressed(button, x, y, clicks)
  if self.show_context_menu and self:inside(x, y) then
    local bar = button == "left" and CM.bar_at(self.m, x, y)
    if bar then self.drag = bar; CM.drag_bar(bar, y) return true end
    if button == "left" and self.m.tp and CM.search_at(self.m, x, y) then   -- (its search box: the caret there, a drag selects)
      self.m.tp:mouse_pressed("left", x, y, clicks)
      self.search_drag = true
      return true
    end
    local it, mm = CM.item_at(self.m, x, y)
    if it and it.sub then                          -- (a submenu: open it, into it)
      local _, i = CM.at(self.m, x, y)
      local child = CM.open_child(mm, i, bounds())
      if child then self.focus = child; CM.jump(child, 1) end
    elseif it and button == "left" then run(self, it) end
    return true                                    -- (the search box, a separator: it stays open)
  end
  local was = self.show_context_menu
  self:hide()
  local v = core.active_view                       --< Replay: a view that takes RMB there (the tilemap's erase): not the menu
  if button == "right" and v and v.takes_right and v:takes_right(x, y) then return was end
  if button == "right" then
    return self:show(x, y) or was
  end
  return was
end
function ContextMenu:released()                    -- (the end of a drag of its scroll bar)
  if self.search_drag then
    self.search_drag = nil
    if self.m and self.m.tp then self.m.tp:mouse_released("left") end
    return true
  end
  if not self.drag then return false end
  self.drag = nil
  return true
end
function ContextMenu:wheel(x, y, dy)               -- -> true when it was over the menu
  if not self.show_context_menu then return false end
  return CM.wheel(self.m, x, y, dy) and true or false
end

-- the keyboard while it's open (the commands below): move, pick, type, close
local function focus(self)
  local f = self.focus or self.m
  for _, mm in ipairs(CM.chain(self.m)) do if mm == f then return f end end
  self.focus = self.m
  return self.m
end
function ContextMenu:move(d) CM.step(focus(self), d) end
function ContextMenu:page(d) local f = focus(self); CM.jump(f, (f.hot or 1) + d * CM.page(f)) end
function ContextMenu:ends(last) local f = focus(self); CM.jump(f, last and #f.items or 1) end
function ContextMenu:pick()
  local f = focus(self)
  local it = f.hot and f.items[f.hot]
  if it and it.sub then return self:right() end
  run(self, it)
end
function ContextMenu:right()                       -- into the selected item's submenu
  local f = focus(self)
  local it = f.hot and f.items[f.hot]
  if not (it and it.sub) then return end
  local child = CM.open_child(f, f.hot, bounds())
  if child then self.focus = child; CM.jump(child, 1) end
end
function ContextMenu:left()                        -- out of the submenu
  local f = focus(self)
  if f.parent then f.parent.child = nil; self.focus = f.parent; core.redraw = true end
end
function ContextMenu:type(text) CM.type(self.m, text, bounds()); self.focus = self.m end
function ContextMenu:erase() CM.erase(self.m, bounds()); self.focus = self.m end

function ContextMenu:update() end
function ContextMenu:draw() end                    --< Replay: drawn over everything, after the views (core.overlays)
function ContextMenu:draw_overlay()                -- -> where it drew: its menu and the submenus open
  if not (self.show_context_menu and self.m) then return nil end
  CM.draw(self.m, core.root_view.mouse.x, core.root_view.mouse.y)
  local r = {}
  for _, mm in ipairs(CM.chain(self.m)) do
    local m = 6 * SCALE                            -- (its shadow too)
    r[#r + 1] = mm.x - m; r[#r + 1] = mm.y - m; r[#r + 1] = mm.w + 2 * m; r[#r + 1] = mm.h + 2 * m
  end
  return r
end


local menu = ContextMenu()
table.insert(core.overlays, menu)
local function in_pane(x, y)                       --< Replay: the views' area (the surface is the whole window)
  local p = core.pane
  return not p or (x >= p.x and y >= p.y and x < p.x + p.w and y < p.y + p.h)
end
local root_view_on_mouse_pressed = RootView.on_mouse_pressed
local root_view_on_mouse_moved = RootView.on_mouse_moved
local root_view_update = RootView.update
local root_view_draw = RootView.draw
local root_view_on_text_input = RootView.on_text_input
local root_view_on_mouse_wheel = RootView.on_mouse_wheel
local root_view_on_mouse_released = RootView.on_mouse_released

function RootView:on_mouse_wheel(dy, ...)          --< Replay: the wheel scrolls an open menu
  if menu:wheel(self.mouse.x, self.mouse.y, dy) then return end
  if not in_pane(self.mouse.x, self.mouse.y) then return end
  return root_view_on_mouse_wheel(self, dy, ...)
end
function RootView:on_mouse_released(...)           --< Replay: the end of a drag of its scroll bar
  if menu:released() then return end
  return root_view_on_mouse_released(self, ...)
end

function RootView:on_mouse_moved(x, y, ...)
  if menu.show_context_menu then self.mouse.x, self.mouse.y = x, y end   --< Replay: (its hover: drawn where the mouse is)
  if menu:on_mouse_moved(x, y, ...) then return end
  return root_view_on_mouse_moved(self, x, y, ...)
end

function RootView:on_text_input(text, ...)       --< Replay: typing filters an open menu
  if menu.show_context_menu then menu:type(text) return end
  return root_view_on_text_input(self, text, ...)
end

-- copied from core.rootview
function RootView:on_mouse_pressed(button, x,y, clicks)
  if menu.show_context_menu and menu:inside(x, y) then   --< Replay: a click in the open menu is the menu's
    menu:on_mouse_pressed(button, x, y, clicks)
    return
  end
  if not in_pane(x, y) then menu:hide() return end  --< Replay: outside the views (the host sent it: a menu was open): closes it
  local div = self.root_node:get_divider_overlapping_point(x, y)
  if div then
    if clicks == 2 then                            --< Replay: a double-click puts it back (its default, else half way)
      div.divider = div.default_divider or 0.5
      self.dragged_divider = nil
      core.redraw = true
      return
    end
    self.dragged_divider = div
    return
  end
  local node = self.root_node:get_child_overlapping_point(x, y)
  local idx = node:get_tab_overlapping_point(x, y)
  if idx then
    menu:hide()
    node:set_active_view(node.views[idx])
    if button == "right" or button == "middle" or node.hovered_close == idx then --< @r-lyeh middle>right; close button (lite-xl)
      node:close_active_view(self.root_node)
    elseif button == "left" then                   --< Replay: a tab can be dragged to another pane (see core.rootview)
      self.tab_drag = { node = node, view = node.views[idx], x = x, y = y, moved = false }
    end
  else
    core.set_active_view(node.active_view)
    -- send to context menu first
    if not menu:on_mouse_pressed(button, x, y, clicks) then
      node.active_view:on_mouse_pressed(button, x, y, clicks)
    end
  end
end

function RootView:update(...)
  root_view_update(self, ...)
  menu:update()
end

function RootView:draw(...)
  root_view_draw(self, ...)
  menu:draw()
end

command.add(nil, {
  ["context:show"] = function()
    menu:show(core.active_view.position.x, core.active_view.position.y)
  end
})

--< Replay: the keyboard while a menu is open (added last: they win over the views')
command.add(function() return menu.show_context_menu end, {
  ["context:up"] = function() menu:move(-1) end,
  ["context:down"] = function() menu:move(1) end,
  ["context:pick"] = function() menu:pick() end,
  ["context:close"] = function() menu:hide(); core.redraw = true end,
  ["context:erase"] = function() menu:erase() end,
  ["context:right"] = function() menu:right() end,
  ["context:left"] = function() menu:left() end,
  ["context:pageup"] = function() menu:page(-1) end,
  ["context:pagedown"] = function() menu:page(1) end,
  ["context:home"] = function() menu:ends(false) end,
  ["context:end"] = function() menu:ends(true) end,
})

-- while a menu is open its keys win, whatever else binds them (a markdown
-- tab's backspace, a graph's arrows): checked before the keymap
MENU_KEYS = { up = "context:up", down = "context:down", ["return"] = "context:pick", ["keypad enter"] = "context:pick",
                    escape = "context:close", backspace = "context:erase", right = "context:right", left = "context:left",
                    pageup = "context:pageup", pagedown = "context:pagedown", home = "context:home", ["end"] = "context:end" }
local on_key_pressed = keymap.on_key_pressed
function keymap.on_key_pressed(k, ...)
  local cmd = menu.show_context_menu and MENU_KEYS[k]
  if cmd and not (keymap.modkeys["ctrl"] or keymap.modkeys["alt"]) then
    command.perform(cmd)
    return true
  end
  return on_key_pressed(k, ...)
end

keymap.add {
  ["menu"] = "context:show",
  ["up"] = "context:up",
  ["down"] = "context:down",
  ["return"] = "context:pick",
  ["keypad enter"] = "context:pick",
  ["escape"] = "context:close",
  ["backspace"] = "context:erase",
  ["right"] = "context:right",
  ["left"] = "context:left",
}

-- register some sensible defaults
menu:register("core.docview", function()
  local items = {
    { text = "Cut", command = "doc:cut", tags = "clipboard;move" },
    { text = "Copy", command = "doc:copy", tags = "clipboard;duplicate" },
    { text = "Paste", command = "doc:paste", tags = "clipboard;insert" },
    DIVIDER,
  }
  local ow = package.loaded["plugins.openwith"]          --< Replay: its ways, in a tab here or in the pane beside
  local v = core.active_view                             --  (its graph, hex...: plugins/openwith.lua)
  local f = v and v.doc and v.doc.filename
  local t = ow and f and ow.item(f, v)
  local b = ow and f and ow.beside_item(f, v)
  if t then items[#items + 1] = t end
  if b then items[#items + 1] = b
  elseif package.loaded["plugins.tabmenu"] then items[#items + 1] = { text = "Open a copy beside", info = "CTRL+\\", command = "tab:copy-beside" } end   -- (no file yet)
  for _, extra in ipairs(menu.docview_extras) do          --< Replay: more from plugins (the node graph's watches)
    local more = extra(v)
    if more and #more > 0 then
      items[#items + 1] = DIVIDER
      for _, it in ipairs(more) do items[#items + 1] = it end
    end
  end
  items[#items + 1] = DIVIDER
  items[#items + 1] = { text = "Command Palette...", command = "core:find-command", tags = "commands;actions;run;search" }
  return items
end)
menu.docview_extras = {}                                 --< Replay: function(view) -> items, for a text's menu

return menu

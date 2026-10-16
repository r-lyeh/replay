-- tabmenu.lua - every tab's right-click menu (Replay, ours): close it, the
-- ones to its right, the unmodified ones; its file's ways, in a tab here or
-- in the pane beside (Open tab with >, Open beside with >: openwith.lua),
-- the tab itself moved there (tabflip.lua);
-- copy its path, show it in the file manager; and, for a tab that flips
-- (plugins/tabflip.lua: a Lua file's graph, a markdown file's preview), its
-- toggle. Commands: tab:open-beside (CTRL+\), tab:copy-beside,
-- tab:move-beside. While a menu is open a click is its (an item, its search
-- line) or closes it. A click on a tab's flip icon: tabflip.lua; middle click
-- and the cross close (lite).
local core = require "core"
local command = require "core.command"
local tabflip = require "plugins.tabflip"

local M = {}
-- more items for a tab that shows a file: M.file_items[key] = function(path, view) -> an item or nil
-- key: a reloaded plugin replaces its own
M.file_items = {}

local tab_ctx                                      -- the tab the menu is for: { node, view }
local function tab_path(view)
  local f = view and (view.doc and view.doc.filename or view.filename)
  if not f then return nil end
  f = system.absolute_path and system.absolute_path(f) or f
  return (f:gsub("\\", "/"))
end
local function close_views(node, list)             -- (each unsaved one asks, with "Confirm close" on: DocView.try_close)
  for _, v in ipairs(list) do
    if node:get_view_idx(v) then node:set_active_view(v); node:close_active_view(core.root_view.root_node) end
  end
end
local tab_items = {
  { text = "Close tab", command = function()
      local n, v = tab_ctx.node, tab_ctx.view
      if n:get_view_idx(v) then n:set_active_view(v); n:close_active_view(core.root_view.root_node) end
    end },
  { text = "Close tabs to the right", command = function()
      local n, v = tab_ctx.node, tab_ctx.view
      local i, list = n:get_view_idx(v), {}
      for k = (i or #n.views) + 1, #n.views do list[#list + 1] = n.views[k] end
      close_views(n, list)
      if n:get_view_idx(v) then n:set_active_view(v) end
    end },
  { text = "Close unmodified tabs", command = function()
      local n, list = tab_ctx.node, {}
      for _, x in ipairs(n.views) do if x.doc and not x.doc:is_dirty() then list[#list + 1] = x end end
      close_views(n, list)
    end },
  "-",
  { text = "Copy path", command = function()
      local p = tab_path(tab_ctx.view)
      if p then system.set_clipboard(p); core.log("copied %s", p) else core.log("this tab has no file") end
    end },
  { text = "Browse folder", command = function()
      local p = tab_path(tab_ctx.view)
      if not p then return core.log("this tab has no file") end
      if PLATFORM == "Windows" then system.exec(string.format('explorer /select,"%s"', (p:gsub("/", "\\"))))
      elseif PLATFORM == "Mac OS X" then system.exec(string.format("open -R %q", p))
      else system.exec(string.format("xdg-open %q", p:match("^(.*)/[^/]*$") or ".")) end
    end },
}
local function pane_items()                        -- the file's ways, here or beside (plugins/openwith.lua); the move
  local n, v = tab_ctx.node, tab_ctx.view
  local items = {}
  local path = tab_path(v)
  local ow = path and package.loaded["plugins.openwith"]
  local t = ow and ow.item(path, v)
  if t then items[#items + 1] = t end
  local b = ow and ow.beside_item(path, v, n)
  if b then items[#items + 1] = b
  else items[#items + 1] = { text = "Open a copy beside", info = "CTRL+\\", command = function() tabflip.copy_beside(n, v) end } end   -- (no file: a copy)
  items[#items + 1] = { text = "Move to the pane beside", command = function() tabflip.move_beside(n, v) end }
  return items
end
local function tab_menu()                          -- (a tab that flips: its toggle last, named by its kind)
  local items = {}
  local DIV = require("plugins.contextmenu").DIVIDER
  for i, it in ipairs(tab_items) do
    items[#items + 1] = it
    if i == 3 then                                 -- (after the closes: the panes)
      items[#items + 1] = DIV
      for _, b in ipairs(pane_items()) do items[#items + 1] = b end
    end
  end
  local path = tab_ctx and tab_path(tab_ctx.view)
  if path then                                     -- (a plugin's own items for a file: M.file_items)
    local first = true
    for _, f in pairs(M.file_items) do
      local it = f(path, tab_ctx.view)
      if it then
        if first then items[#items + 1] = DIV; first = false end
        items[#items + 1] = it
      end
    end
  end
  local k = tab_ctx and tabflip.kind_of(tab_ctx.view)
  if k then
    items[#items + 1] = require("plugins.contextmenu").DIVIDER
    items[#items + 1] = { text = k.menu or "Toggle view", command = function()
      local n, v = tab_ctx.node, tab_ctx.view
      if n:get_view_idx(v) then tabflip.flip(n, v) end
    end }
  end
  return items
end
local showing = false
function M.show(node, view, x, y)                  -- view's tab menu at (x, y): the right-click on its tab
  local menu = require "plugins.contextmenu"
  tab_ctx = { node = node, view = view }
  showing = true
  menu.no_last = true                              -- (the tab's menu: not the view's own last items, "Plugin: x"...)
  local ok = menu:show(x, y)
  menu.no_last = nil
  showing = false
  return ok
end
core.add_thread(function()
  local menu = require "plugins.contextmenu"
  for i, it in ipairs(tab_items) do if it == "-" then tab_items[i] = menu.DIVIDER end end
  menu:register(function() return showing end, tab_menu)
  table.insert(menu.itemset, 1, table.remove(menu.itemset))   -- (first: checked before the text's own menu)
  local RootView = require "core.rootview"
  local on_mouse_pressed = RootView.on_mouse_pressed
  function RootView:on_mouse_pressed(button, x, y, clicks)
    if menu.show_context_menu then                 -- the menu is open: a click is its (an item, or closing it)
      if menu.inside and menu:inside(x, y) then return menu:on_mouse_pressed(button, x, y, clicks) end   -- (an item, its search line)
      menu:hide()
    end
    if button == "right" and not self.root_node:get_divider_overlapping_point(x, y) then
      local node = self.root_node:get_child_overlapping_point(x, y)
      local idx = node and node.type == "leaf" and node:get_tab_overlapping_point(x, y)
      if idx then
        do                  -- under the tab, not over it (the tab row takes clicks)
          node:set_active_view(node.views[idx])
          core.set_active_view(node.views[idx])
          local tx, ty, _, th = node:get_tab_rect(idx)
          M.show(node, node.views[idx], x, ty + th)
          return true
        end
      end
    end
    return on_mouse_pressed(self, button, x, y, clicks)
  end
end)

-- the same from the keyboard (the active tab), and the text's menu (contextmenu.lua)
local function active() local v = core.active_view return core.root_view.root_node:get_node_for_view(v), v end
command.add(function() local n = active() return n ~= nil end, {
  ["tab:open-beside"] = function() local n, v = active() tabflip.open_beside(n, v) end,
  ["tab:copy-beside"] = function() local n, v = active() tabflip.copy_beside(n, v) end,
  ["tab:move-beside"] = function() local n, v = active() tabflip.move_beside(n, v) end,
})
core.add_thread(function() require("core.keymap").add { ["ctrl+\\"] = "tab:open-beside" } end)

return M

-- hostmenu.lua - the host's menus, drawn by lite (Replay). replay.c draws the
-- tree, the properties and the bar itself, but every popup menu is lite's:
-- the main menu (the bar's ☰), the Network and lobby menus, the tree's
-- right-click menu, a property's drop-down. The host sends a menu as text;
-- it opens as a right-click menu does (plugins/contextmenu.lua, drawn by
-- plugins/canvas/menu.lua: a search box, submenus, a scroll bar when it
-- doesn't fit, the keyboard), over everything in the window (core.overlays).
-- A click on an item answers the host: host_call("pick <id> <path>") (path:
-- "3", or "2.5" in a submenu); closing it without a pick: "closed <id>".
--
--   lite_host_menu(id, x, y, text [, search [, above]])   -- x, y: host points (the menu's top left);
--     above: where it goes up from instead when there's no room below (a bar's button)
--   text: a line an item: depth \t kind \t text \t info \t flags
--     depth: 0 at the top, 1 in the item above's submenu...; kind: i (an
--     item), s (a separator), h (a header); info: shown on the right (a
--     key, a value); flags: c (a dot: the current one), d (dimmed: not now)
local core = require "core"
local ContextMenu = require "plugins.contextmenu"

local M = {}

local function parse(text)
  local root = {}
  local stack = { { items = root, last = nil } }    -- stack[d + 1]: the list at depth d
  for line in (text or ""):gmatch("[^\n]+") do
    local depth, kind, label, info, flags = line:match("^(%d+)\t(%a)\t([^\t]*)\t?([^\t]*)\t?([^\t]*)$")
    depth = tonumber(depth)
    if depth then
      while #stack > depth + 1 do table.remove(stack) end
      if #stack < depth + 1 then                    -- (deeper: the item above opens this list)
        local parent = stack[#stack].last
        if parent then
          parent.sub = parent.sub or {}
          stack[#stack + 1] = { items = parent.sub }
        end
      end
      local list = stack[#stack].items
      local it
      if kind == "s" then it = ContextMenu.DIVIDER
      else
        it = { text = label, info = info ~= "" and info or nil }
        if flags:find("c", 1, true) then it.checked = true end
        if flags:find("d", 1, true) then it.dim = true end
        if kind == "h" then it.header = true end
      end
      list[#list + 1] = it
      stack[#stack].last = it ~= ContextMenu.DIVIDER and it or nil
    end
  end
  return root
end

-- each leaf answers the host with its path ("2.5")
local function wire(id, items, prefix)
  local n = 0
  for _, it in ipairs(items) do
    if it ~= ContextMenu.DIVIDER then
      n = n + 1
      local path = prefix and (prefix .. "." .. n) or tostring(n)
      if it.sub then wire(id, it.sub, path)
      elseif not it.dim and not it.header then
        it.command = function() if host_call then host_call("pick " .. id .. " " .. path) end end
      end
    end
  end
end

function M.open(id, x, y, text, search, above)
  local items = parse(text)
  wire(id, items)
  local ok = ContextMenu:show_items(x * SCALE, y * SCALE, items, {
    search = search ~= false,
    on_close = function() if host_call then host_call("closed " .. id) end end,
  })
  local m = ContextMenu.m
  if ok and m and above and above >= 0 and m.y < y * SCALE then   -- (no room below: up from `above` instead, if it fits there)
    m.y = math.max(0, above * SCALE - m.h)
  end
  if not ok and host_call then host_call("closed " .. id) end
  core.redraw = true
  return ok
end
function M.close() ContextMenu:hide() end
function M.open_now() return ContextMenu.show_context_menu end

rawset(_G, "lite_host_menu", M.open)                -- (rawset: lite's globals are strict)
rawset(_G, "lite_host_menu_close", M.close)

return M

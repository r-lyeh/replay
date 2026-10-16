-- openwith.lua - "Open tab with >" / "Open beside with >" (Replay, ours): every way a file can open in a
-- tab: as text, as each tab-flip kind's other view (a .lua's node graph, a
-- .md's preview, an atlas's sheet), in the plugin its extension belongs to,
-- and in any plugin that opens any file (the hex editor). A file with two ways
-- or more gets the submenu: in its tab's right-click menu, its text's, a
-- plugin view's, and the tree's (an asset's: runtime/boot.lua).
--
--   local openwith = require "plugins.openwith"
--   openwith.register {
--     key = "hexedit", name = "Hex editor", order = 90,   -- (its place in the list)
--     can = function(path) return true end,               -- can it open this file?
--     open = function(path) return HexView({ filename = path }) end,   -- a new view (not placed)
--     is = function(view, path) end,                      -- does this tab show it that way?
--   }
--   openwith.list(path) -> the openers that can, in order
--   openwith.open(key, path [, node]) -> the view: the tab showing it that way
--     (focused), else a new tab in node (the active pane)
--   openwith.item(path [, view]) -> { text = "Open tab with", sub = ... } | nil (fewer than two):
--     in this pane (a tab already showing it that way: focused)
--   openwith.beside_item(path [, view [, node]]) -> { text = "Open beside with", sub = ... }:
--     in the pane beside (made if none). The way view shows it: a copy; its
--     other view (a .lua's graph, a graph's text): kept in step with it
--     (tabflip.open_beside); the one CTRL+\ opens is marked
local core = require "core"
local DocView = require "core.docview"

local M = { openers = {} }

local function abs(p) return (system.absolute_path(p) or p):gsub("\\", "/") end
local function same(a, b) return a and b and abs(a) == abs(b) end
local function view_file(v) return v and (v.doc and v.doc.filename or v.filename) end

function M.register(o)
  for i, x in ipairs(M.openers) do if x.key == o.key then M.openers[i] = o; return o end end
  M.openers[#M.openers + 1] = o
  return o
end

local NAMES = { text = "Text", nodegraph = "Node graph", markdown = "Markdown preview", atlaspacker = "Atlas packer" }
local function title(key)                          -- a plugin's P.title, else ours, else its name
  local ok, pp = pcall(require, "plugins.projectplugins")
  local rec = ok and pp.plugins and pp.plugins[key]
  return rec and rec.P.title or NAMES[key] or key
end
M.title = title

local function looks_text(path)                    -- (no NUL in its first 4 KiB)
  local f = io.open(path, "rb")
  if not f then return false end
  local head = f:read(4096) or ""
  f:close()
  return not head:find("\0", 1, true)
end

-- the openers that come with the editor: text, the tab-flip kinds, the plugins by extension
local function builtins()
  local list = {}
  list[#list + 1] = { key = "text", name = "Text", order = 10,
    can = looks_text,
    open = function(path) return DocView(core.open_doc(path)) end,
    is = function(v) return getmetatable(v) == DocView end }
  local okf, tabflip = pcall(require, "plugins.tabflip")
  if okf then
    for _, k in ipairs(tabflip.kinds) do
      list[#list + 1] = { key = k.key, name = title(k.key), order = 20,
        can = function(path)
          local probe = setmetatable({ doc = { filename = path } }, DocView)
          local ok, yes = pcall(k.text, probe)
          return ok and yes
        end,
        open = function(path) return k.to_alt(DocView(core.open_doc(path))) end,
        is = function(v) local ok, yes = pcall(k.alt, v) return ok and yes end }
    end
  end
  local okp, pp = pcall(require, "plugins.projectplugins")
  if okp and pp.by_ext then
    local seen = {}
    for _, r in pairs(pp.by_ext) do
      if not seen[r.plugin] then
        seen[r.plugin] = true
        local View = r.view
        list[#list + 1] = { key = r.plugin, name = title(r.plugin), order = 30,
          can = function(path) return pp.view_for(path) == View end,
          open = function(path) return View({ filename = abs(path) }) end,
          is = function(v) return v.is and v:is(View) end }
      end
    end
  end
  return list
end

function M.list(path)
  if not path then return {} end
  local all, out, keys = builtins(), {}, {}
  for _, o in ipairs(M.openers) do all[#all + 1] = o end
  for _, o in ipairs(all) do
    if not keys[o.key] then                        -- (one per key: a plugin that flips too counts once)
      local ok, yes = pcall(o.can, path)
      if ok and yes then keys[o.key] = true; out[#out + 1] = o end
    end
  end
  table.sort(out, function(a, b) if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end return a.name < b.name end)
  return out
end

local function find(path, o)                       -- a tab already showing path that way: node, view
  local hit
  local function walk(node)
    if hit then return end
    if node.type == "leaf" then
      for _, v in ipairs(node.views) do
        if not hit and same(view_file(v), path) and o.is(v, path) then hit = { node, v } end
      end
    else walk(node.a) walk(node.b) end
  end
  walk(core.root_view.root_node)
  if hit then return hit[1], hit[2] end
end

function M.open(key, path, node)
  local o
  for _, x in ipairs(M.list(path)) do if x.key == key then o = x end end
  if not o then core.error("can't open %s with %s", tostring(path), tostring(key)) return nil end
  local n, v = find(path, o)
  if v then n:set_active_view(v); core.set_active_view(v); return v end
  local ok, view = pcall(o.open, abs(path))
  if not ok or not view then core.error("open with %s: %s", o.name, tostring(view)) return nil end
  node = node or core.root_view:get_active_node()
  if node.locked and core.last_active_view then
    core.set_active_view(core.last_active_view)
    node = core.root_view:get_active_node()
  end
  node:add_view(view)
  core.root_view.root_node:update_layout()
  core.redraw = true
  return view
end

-- the submenus for a file (view: the tab they're for, its way marked)
local function node_of(view) return view and core.root_view.root_node:get_node_for_view(view) end
function M.item(path, view)
  local list = M.list(path)
  if #list < 2 then return nil end
  return { text = "Open tab with", sub = function()
    local items = {}
    for _, o in ipairs(list) do
      local here = view and same(view_file(view), path) and o.is(view, path)
      items[#items + 1] = { text = o.name, info = here and "this tab" or nil, command = function()
        M.open(o.key, path, node_of(view))
      end }
    end
    return items
  end }
end
M.tab_item = M.item

-- which way CTRL+\ (tab:open-beside) opens view beside: its other view (a
-- tab that flips), else the same (a copy)
local function beside_kind(view, path)
  local tabflip = package.loaded["plugins.tabflip"]
  local k, is_alt
  if tabflip then k, is_alt = tabflip.kind_of(view) end
  if k then return is_alt and "text" or k.key, k end
  for _, o in ipairs(M.list(path)) do if o.is(view, path) then return o.key end end
end
function M.open_beside(key, path, view, node)
  local tabflip = require "plugins.tabflip"
  node = node or node_of(view) or core.root_view:get_active_node()
  local o
  for _, x in ipairs(M.list(path)) do if x.key == key then o = x end end
  if not o then core.error("can't open %s with %s", tostring(path), tostring(key)) return nil end
  local mine = view and same(view_file(view), path)
  if mine and o.is(view, path) then return tabflip.copy_beside(node, view) end      -- (the same way: a copy)
  if mine and beside_kind(view, path) == key then return tabflip.open_beside(node, view) end   -- (its other view: in step)
  local b = tabflip.beside_node(node)
  for _, v in ipairs(b and b.views or {}) do                                        -- (the pane beside shows it so already)
    if same(view_file(v), path) and o.is(v, path) then b:set_active_view(v); core.set_active_view(v); return v end
  end
  local ok, nv = pcall(o.open, abs(path))
  if not ok or not nv then core.error("open with %s: %s", o.name, tostring(nv)) return nil end
  return tabflip.place_beside(node, nv)
end
function M.beside_item(path, view, node)
  local list = M.list(path)
  if #list < 1 then return nil end
  return { text = "Open beside with", sub = function()
    local items, ck = {}, view and beside_kind(view, path)
    for _, o in ipairs(list) do
      local here = view and same(view_file(view), path) and o.is(view, path)
      items[#items + 1] = { text = o.name, info = (o.key == ck and "CTRL+\\") or (here and "a copy") or nil, command = function()
        M.open_beside(o.key, path, view, node or node_of(view))
      end }
    end
    return items
  end }
end

-- in every menu that's for a file: a plugin view's (the last items: contextmenu.last)
do
  local ok, menu = pcall(require, "plugins.contextmenu")
  if ok and type(menu) == "table" and menu.last then
    table.insert(menu.last, 1, function(view)
      if getmetatable(view) == DocView then return nil end   -- (a text tab: its own menu has it, contextmenu.lua)
      local f = view_file(view)
      return f and M.item(f, view) or nil
    end)
    table.insert(menu.last, 2, function(view)
      if getmetatable(view) == DocView then return nil end
      local f = view_file(view)
      return f and M.beside_item(f, view) or nil
    end)
  end
end

return M

-- projectplugins.lua - the project's own plugins (Replay), pure Lua.
--
-- Every folder of the project's plugins/ (host_plugins_dir, set by the
-- viewer: next to games/) that has an editor.lua is loaded here, in lite, at
-- start. The same folders show in the viewer's tree as /plugins/<name>, their
-- data leaves (*.lua that are plain data: which files it opens, its config)
-- as components you edit and save there.
--
-- editor.lua runs with one argument, P:
--   P.name, P.dir            the plugin's name, its folder
--   P.read(leaf)             a data leaf of its folder ("config" ->
--                            config.lua), read in an empty sandbox; nil if
--                            missing or not data
--   P.changed(leaf)          has that leaf changed on disk since the last
--                            P.read of it? (saved from the tree, or by hand)
--   P.open_with(exts, View)  files with those extensions open in View (a
--                            core.view subclass, View({ filename = abs })),
--                            not the text editor ("atlas.lua": two parts,
--                            ui.atlas.lua); calling it again replaces
--                            this plugin's list. View is kept as the module
--                            "projectplugins.<name>", so the workspace
--                            reopens its tabs (View:get_state() -> a table
--                            with `filename`, given back to View(state)).
--   P.menu(View, items)      its right-click menu (the standard one, with a
--                            search: plugins/contextmenu.lua); items: a list
--                            or a function returning one ({ text, command,
--                            info, checked }, menu.DIVIDER). Replaced when the
--                            plugin reloads
--   P.source()               opens its editor.lua (and its data leaves) here
--   P.reload()               runs editor.lua again: its open tabs come back
--                            with the new code (their state kept). Saving
--                            one of its .lua files here reloads it too
--                            (P.reloadable = false: not; a restart does)
--   P.view(View)             a view class of its own that opens no file type
--                            (open_with's views count already): its menu
--                            gets the "Plugin: <name>" submenu (last) too
--   P.menu_items             (optional) a function returning more of its
--                            common commands, for that submenu
--   P.require(mod)           one of its folder's modules, mod.lua (a plugin
--                            in several files): require "plugins.<name>.<mod>"
--                            finds it too (data/replay.lua), init.lua for none
-- A plugin view (or any view with wants_ctrl_wheel, as canvas views) gets
-- the wheel with CTRL as well (lite's scale plugin takes CTRL+wheel
-- elsewhere: the code's font). To draw on a canvas (camera, nodes, wires):
-- plugins/canvas.
local core = require "core"
local RootView = require "core.rootview"

local M = { by_ext = {}, plugins = {} }            -- by_ext: ext -> { plugin = name, view = View }; plugins: name -> { P, editor, view }

local function ext_of(f)                           -- (a two-part one first, if a plugin took it: "atlas.lua")
  if type(f) ~= "string" then return nil end
  local e2 = f:match("[^/\\]%.([^%./\\]+%.[^%./\\]+)$")
  if e2 and M.by_ext[e2:lower()] then return e2:lower() end
  local e = f:match("%.([^%./\\]+)$")
  return e and e:lower()
end

function M.view_for(filename)
  local e = ext_of(filename)
  return e and M.by_ext[e] and M.by_ext[e].view
end

-- a file whose extension a plugin took opens in its view (the text Doc lite
-- loaded for it is let go: no view keeps it)
local open_doc = RootView.open_doc
function RootView:open_doc(doc)
  local View = doc and M.view_for(doc.filename)
  if not View then return open_doc(self, doc) end
  local node = self:get_active_node()
  if node.locked and core.last_active_view then
    core.set_active_view(core.last_active_view)
    node = self:get_active_node()
  end
  local abs = system.absolute_path(doc.filename) or doc.filename
  for _, v in ipairs(node.views) do               -- (its tab: the plugin's view, or its text flipped to (plugins/tabflip))
    local vf = v.filename or (v.doc and v.doc.filename and (system.absolute_path(v.doc.filename) or v.doc.filename))
    if vf == abs then node:set_active_view(v) return v end
  end
  local view = View({ filename = abs })
  node:add_view(view)
  self.root_node:update_layout()
  return view
end

local function read_data(file)
  local f = io.open(file, "rb")
  if not f then return nil end
  local src = f:read("*a")
  f:close()
  local fn = load(src, "=" .. file, "t", {})     -- (data only: no globals, no code runs with any power)
  if not fn then return nil end
  local ok, v = pcall(fn)
  return ok and v or nil
end

local function mtime(file)
  local info = system.get_file_info(file)
  return info and info.modified
end

-- every view in every pane (to swap a reloaded plugin's tabs)
local function each_view(fn)
  local function walk(node)
    if node.type == "leaf" then
      for i, v in ipairs(node.views) do fn(node, i, v) end
    else walk(node.a) walk(node.b) end
  end
  walk(core.root_view.root_node)
end

-- run a plugin's editor.lua (again): -> ok
local function run(rec)
  local fn, err = loadfile(rec.editor)
  if not fn then core.error("plugin %s: %s", rec.P.name, tostring(err)) return false end
  return core.try(fn, rec.P)
end

function M.reload(name)
  local rec = M.plugins[name]
  if not rec then return false end
  if rec.P.reloadable == false then                -- (it patches lite too deeply: the node graph)
    core.warn("plugin %s: restart the editor to run its new code", name)
    return false
  end
  local old, old_views = rec.view, rec.views
  rec.views = {}
  if not run(rec) then rec.views = old_views return false end            -- (failed: the old code stays, its tabs too)
  local new = rec.view
  if old and new and new ~= old then               -- its tabs: the new code, the same state
    each_view(function(node, i, v)
      if getmetatable(v) == old then
        local ok, nv = pcall(new, v.get_state and v:get_state() or {})
        if ok and nv then
          nv.position, nv.size = v.position, v.size
          node.views[i] = nv
          if node.active_view == v then node.active_view = nv end
          if core.active_view == v then core.set_active_view(nv) end
          if v.on_unload then pcall(v.on_unload, v) end
        else core.error("plugin %s: %s", name, tostring(nv)) end
      end
    end)
  end
  core.log("Reloaded plugin %s", name)
  core.redraw = true
  return true
end

local function add_plugin(name, pdir, editor)
  local P, seen = { name = name, dir = pdir }, {}
  local rec = { P = P, editor = editor, views = {} }
  M.plugins[name] = rec
  function P.view(View)                            -- a view of its own (not opening files: the node graph's), for its menu
    for _, v in ipairs(rec.views) do if v == View then return end end
    rec.views[#rec.views + 1] = View
  end
  function P.read(leaf)
    local file = pdir .. PATHSEP .. leaf .. ".lua"
    seen[leaf] = mtime(file) or false
    return read_data(file)
  end
  function P.changed(leaf)
    local file = pdir .. PATHSEP .. leaf .. ".lua"
    return seen[leaf] ~= nil and (mtime(file) or false) ~= seen[leaf]
  end
  function P.open_with(exts, View)
    for e, r in pairs(M.by_ext) do if r.plugin == name then M.by_ext[e] = nil end end
    for _, e in ipairs(exts or {}) do
      if type(e) == "string" then M.by_ext[e:lower():gsub("^%.", "")] = { plugin = name, view = View } end
    end
    package.loaded["projectplugins." .. name] = View
    rec.view = View
  end
  function P.menu(View, items)
    local ok, menu = pcall(require, "plugins.contextmenu")
    if ok and type(menu) == "table" then menu:register(View, items, "plugin:" .. name) end
  end
  function P.source()
    local files = system.list_dir(pdir) or {}
    table.sort(files)
    for _, f in ipairs(files) do                   -- (its data leaves, then editor.lua in front)
      if f:match("%.lua$") and f ~= "editor.lua" then core.root_view:open_doc(core.open_doc(pdir .. PATHSEP .. f)) end
    end
    core.root_view:open_doc(core.open_doc(editor))
  end
  function P.reload() return M.reload(name) end
  function P.require(mod) return require("plugins." .. name .. (mod and mod ~= "" and ("." .. mod) or "")) end
  if run(rec) then core.log_quiet("Loaded project plugin %q", name) end
end

local dir = host_plugins_dir
if dir and system.get_file_info(dir) then
  local names = system.list_dir(dir) or {}
  table.sort(names)
  for _, name in ipairs(names) do
    local pdir = dir .. PATHSEP .. name
    local editor = pdir .. PATHSEP .. "editor.lua"
    if name:sub(1, 1) ~= "." and system.get_file_info(editor) then add_plugin(name, pdir, editor) end
  end
end

-- a plugin's code saved here (any .lua of its folder that isn't data): it reloads
local Doc = require "core.doc"
local doc_save = Doc.save
function Doc:save(...)
  local r = doc_save(self, ...)
  local f = self.filename and (system.absolute_path(self.filename) or self.filename)
  if f and dir and f:match("%.lua$") then
    for name, rec in pairs(M.plugins) do
      local pd = system.absolute_path(rec.P.dir) or rec.P.dir
      if f:sub(1, #pd + 1) == pd .. PATHSEP and read_data(f) == nil then
        core.add_thread(function() M.reload(name) end)
      end
    end
  end
  return r
end

-- the wheel over a plugin's view is its own, CTRL too (the scale plugin
-- takes CTRL+wheel for the code's font: it loads after us, so this wraps
-- RootView once every plugin is in, as the node graph does)
core.add_thread(function()
  local on_mouse_wheel = RootView.on_mouse_wheel
  function RootView:on_mouse_wheel(...)
    local node = self.root_node:get_child_overlapping_point(self.mouse.x, self.mouse.y)
    local v = node and node.active_view
    if v then
      if v.wants_ctrl_wheel then return v:on_mouse_wheel(...) end   -- (a canvas view: plugins/canvas)
      local mt = getmetatable(v)
      for _, rec in pairs(M.plugins) do
        if rec.view and mt == rec.view then return v:on_mouse_wheel(...) end
      end
    end
    return on_mouse_wheel(self, ...)
  end
end)

-- "Plugin: <name>" at the bottom of the right-click menu of a plugin's view:
-- its common commands (contextmenu.lua: ContextMenu.last, a submenu)
local function browse(dir)
  if PLATFORM == "Windows" then system.exec(string.format('explorer "%s"', (dir:gsub("/", "\\"))))
  elseif PLATFORM == "Mac OS X" then system.exec(string.format("open %q", dir))
  else system.exec(string.format("xdg-open %q", dir)) end
end
function M.common_items(name)                      -- -> { text, info, command }...
  local rec = M.plugins[name]
  if not rec then return {} end
  local P, dir = rec.P, rec.P.dir
  local function has(f) return system.get_file_info(dir .. PATHSEP .. f) ~= nil end
  local function open(f) return function() core.root_view:open_doc(core.open_doc(dir .. PATHSEP .. f)) end end
  local items = {
    { text = "Source", info = "editor.lua", command = function() P.source() end },
    { text = "Reload", info = P.reloadable == false and "restart" or nil, command = function() P.reload() end },
  }
  if has("config.lua") then items[#items + 1] = { text = "Settings", info = "config.lua", command = open("config.lua") } end
  if has("files.lua") then items[#items + 1] = { text = "Files it opens", info = "files.lua", command = open("files.lua") } end
  if has("README.md") then items[#items + 1] = { text = "About", info = "README.md", command = open("README.md") } end
  items[#items + 1] = { text = "Browse folder", command = function() browse(dir) end }
  if type(P.menu_items) == "function" then         -- (its own common commands)
    local ok, more = pcall(P.menu_items)
    if ok and type(more) == "table" then for _, it in ipairs(more) do items[#items + 1] = it end end
  end
  return items
end
-- the plugins that show a tab: the main menu's Plugins > (replay.c). One
-- with P.tab (a function -> a new view, or nil when it asked for something
-- itself) opens that: the particle editor a new untitled effect. Any other
-- with a view asks for a file of its kind (its extensions), on lite's command
-- line, and opens it there (plugins/openwith.lua).
function M.tabs()                                  -- -> { { name, title }... } by title
  local list = {}
  for name, rec in pairs(M.plugins) do
    if type(rec.P.tab) == "function" or rec.view or #(rec.views or {}) > 0 then
      list[#list + 1] = { name = name, title = rec.P.title or name }
    end
  end
  table.sort(list, function(a, b) return a.title:lower() < b.title:lower() end)
  return list
end
local function place(view)
  if core.root_view.root_node:get_node_for_view(view) then return view end
  local node = core.root_view:get_active_node()
  if node.locked and core.last_active_view then core.set_active_view(core.last_active_view); node = core.root_view:get_active_node() end
  node:add_view(view)
  core.root_view.root_node:update_layout()
  core.redraw = true
  return view
end
function M.open_tab(name)                          -- its tab, apart (in the active pane)
  local rec = M.plugins[name]
  if not rec then core.error("no plugin %s", tostring(name)) return end
  if type(rec.P.tab) == "function" then
    local ok, view = core.try(rec.P.tab)
    return ok and view and place(view) or nil
  end
  local exts = {}
  for e, r in pairs(M.by_ext) do if r.plugin == name then exts[#exts + 1] = e end end
  table.sort(exts)
  local common = require "core.common"
  local label = (rec.P.title or name) .. (#exts > 0 and (" (" .. table.concat(exts, ", ") .. ")") or "") .. ": a file"
  core.command_view:enter(label, function(text)
    local p = system.absolute_path(text) or text
    if not system.get_file_info(p) then core.error("%s: no such file: %s", name, text) return end
    require("plugins.openwith").open(name, (p:gsub("\\", "/")))
  end, function(text)
    local out = {}
    for _, f in ipairs(common.path_suggest(text)) do   -- (folders, and its kind of file)
      local info = system.get_file_info(f)
      local e = f:match("%.([^%./\\]+)$")
      if (info and info.type == "dir") or #exts == 0 or (e and M.by_ext[e:lower()] and M.by_ext[e:lower()].plugin == name) then out[#out + 1] = f end
    end
    return out
  end)
end
-- a plugin's menu (the main menu's Plugins > <plugin> >): its tab, its
-- commands with their keys (P.commands = { { "Find", "nodegraph:find" }... }:
-- run on its tab, the active one or the last one shown), then its common
-- items (settings, about, source, reload...)
local function pretty_key(stroke)
  if not stroke then return nil end
  return (stroke:gsub("[^+]+", function(k) return #k == 1 and k:upper() or k:upper() end))
end
local function plugin_view(name)                   -- its tab (the active one first): node, view
  local v = core.active_view
  if M.plugin_of(v) == name then return core.root_view.root_node:get_node_for_view(v), v end
  local hit
  local function walk(node)
    if hit then return end
    if node.type == "leaf" then
      local av = node.active_view
      if M.plugin_of(av) == name then hit = { node, av } return end
      for _, x in ipairs(node.views) do if not hit and M.plugin_of(x) == name then hit = { node, x } end end
    else walk(node.a) walk(node.b) end
  end
  walk(core.root_view.root_node)
  if hit then return hit[1], hit[2] end
end
function M.menu(name)
  local rec = M.plugins[name]
  if not rec then return {} end
  local P = rec.P
  local keymap = require "core.keymap"
  local command = require "core.command"
  local items = { { text = type(P.tab) == "function" and "New tab" or "Open a file...", run = function() M.open_tab(name) end } }
  if type(P.commands) == "table" and #P.commands > 0 then
    items[#items + 1] = { sep = true }
    for _, c in ipairs(P.commands) do
      local cmd = c[2]
      items[#items + 1] = { text = c[1], info = c.key or pretty_key(keymap.get_binding(cmd)), run = function()
        local node, v = plugin_view(name)
        if not v then core.log("%s: open one of its tabs first", P.title or name) return end
        node:set_active_view(v)
        core.set_active_view(v)
        if not command.perform(cmd) then core.log("%s: %s can't run here now", P.title or name, c[1]) end
      end }
    end
  end
  items[#items + 1] = { sep = true }
  for _, it in ipairs(M.common_items(name)) do
    items[#items + 1] = { text = it.text, info = it.info, run = type(it.command) == "function" and it.command or function() command.perform(it.command) end }
  end
  return items
end
function M.run_menu(name, i)
  local it = M.menu(name)[i]
  if it and it.run then core.try(it.run) end
  core.redraw = true
end
rawset(_G, "lite_plugin_menu", function(name)      -- (the host: "i|-\ttext\tinfo\n"...)
  local out = {}
  for _, it in ipairs(M.menu(name)) do
    out[#out + 1] = it.sep and "-\t\t" or ("i\t" .. tostring(it.text):gsub("[\t\n]", " ") .. "\t" .. tostring(it.info or ""):gsub("[\t\n]", " "))
  end
  return table.concat(out, "\n")
end)
rawset(_G, "lite_plugin_tabs", function()          -- (the host: "name\ttitle\n"...; rawset: lite's globals are strict)
  local out = {}
  for _, t in ipairs(M.tabs()) do out[#out + 1] = t.name .. "\t" .. t.title end
  return table.concat(out, "\n")
end)

function M.plugin_of(view)                         -- the plugin whose view this is, or nil
  if not (view and view.is) then return nil end
  for name, rec in pairs(M.plugins) do
    if rec.view and view:is(rec.view) then return name end
    for _, v in ipairs(rec.views or {}) do if view:is(v) then return name end end
  end
end
do
  local ok, menu = pcall(require, "plugins.contextmenu")
  if ok and type(menu) == "table" and menu.last then
    table.insert(menu.last, function(view)
      local name = M.plugin_of(view)
      if name then return { text = "Plugin: " .. name, sub = function() return M.common_items(name) end } end
    end)
  end
end

return M

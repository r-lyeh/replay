-- replay.lua - starts lite inside Replay's editor (editor/editor.c runs it with lite's
-- folder, editor/3rd/lite, as its argument). Like lite's own start-up, but data
-- comes from that folder, errors are reported instead of exiting, and
-- os.exit() (the quit command) becomes a request the host acts on.
-- The lite_* globals here are what editor/editor.c calls by name.

local datadir = ...
core = {}  -- declared before strict.lua loads
SCALE = tonumber(os.getenv('LITE_SCALE')) or SCALE
PATHSEP = package.config:sub(1, 1)
EXEDIR = datadir  -- temp files, user init
USERDIR = datadir .. '/data/user/'
package.path = datadir .. '/data/?.lua;' .. datadir .. '/data/?/init.lua;' .. package.path
-- a project plugin's modules (plugins/<name>/<mod>.lua, its init.lua) are
-- `require "plugins.<name>.<mod>"` too, found before lite's own (so a
-- plugin moved out of data/plugins, as the node graph, wins over a stale copy)
if host_plugins_dir then
  local pdir = tostring(host_plugins_dir):gsub('[/\\]+$', '')
  local searchers = package.searchers or package.loaders
  table.insert(searchers, 2, function(name)
    local plug, rest = name:match('^plugins%.([%w_%-]+)(.*)$')
    if not plug then return nil end
    local file = pdir .. '/' .. plug .. (rest == '' and '/init.lua' or ('/' .. rest:sub(2):gsub('%.', '/') .. '.lua'))
    local f = io.open(file, 'rb')
    if not f then return nil end
    f:close()
    local fn, err = loadfile(file)
    if not fn then error(err, 0) end
    return fn
  end)
end
os.exit = function() lite_quit() error('lite: quit', 0) end
-- lite_open(file, line): open (or focus) a file with the cursor on a line.
-- Declared before core loads: strict.lua forbids new globals afterwards.
lite_open = function(file, line)
  local doc = core.open_doc(file)
  local view = core.root_view:open_doc(doc)
  if (line or 1) < 1 then core.redraw = true return end  -- 0: just open / focus it (keep its cursor)
  line = math.max(1, math.min(math.floor(line or 1), #doc.lines))
  doc:set_selection(line, 1)
  view:scroll_to_line(line, true, true)
  core.redraw = true
end
-- lite_open_error(file, line, msg): show where code fails to compile: a
-- graph of that file, if one is open and has nodes (the last good parse:
-- the node of that line, selected and centred, the message flashed on
-- it), else lite_open (its text).
lite_open_error = function(file, line, msg)
  local okb, B = pcall(require, 'plugins.nodegraph.breaks')
  local graph
  local function walk(node)
    if node.type == 'leaf' then
      for _, v in ipairs(node.views) do
        if not graph and okb and v.locate and v.g and v.doc and v.doc.filename and B.same(v.doc.filename, file) then graph = { node, v } end
      end
    else walk(node.a) walk(node.b) end
  end
  walk(core.root_view.root_node)
  if not graph then return lite_open(file, line) end
  local node, v = graph[1], graph[2]
  node:set_active_view(v)
  core.set_active_view(v)
  v.doc:set_selection(math.max(1, math.min(line or 1, #v.doc.lines)), 1)
  v:scroll_to_line(line or 1)
  if msg and v.flash then v:flash(msg) end
  core.redraw = true
end
-- lite_log(level, text): our messages in lite's status bar / log view
-- (level 0 info, 1 warning, 2 error: coloured, style.warn / style.error)
-- One log item per message: the first line is the text (also shown in
-- the status bar), the rest (a traceback) is its `info`, which lite's
-- log view draws dim under it.
lite_log = function(level, text, at)
  text = text:gsub('\t', '  ')
  local first, rest = text:match('^([^\n]*)\n(.*)$')
  first = first or text
  local item = (level >= 2 and core.error or level == 1 and core.warn or core.log)('%s', first)
  if item then
    if at and at ~= '' then item.at = at end
    if rest and rest ~= '' then item.info = rest end
  end
end
-- lite_show_log(): focus the Log tab, or open it if there is none. Extra
-- Log tabs (the workspace plugin restores tabs) are closed: only one.
-- lite_theme(name): 'dark' (the theme lite started with: its defaults,
-- or what user/init.lua chose) or 'light' (themes/replay_light.lua, ours;
-- the node graph's canvas too). The colours
-- lite started with are kept the first time, to come back to.
host_ui_font = false  -- the viewer's own font size (editor_ui_font), else style.font
-- lite_set_bg_alpha(a): the game shows through lite's backgrounds (the
-- viewer: 1 - its fade; editor only: 1). lite_bg(c): c with that alpha, for
-- what is a background (View:draw_background, the current line, the active
-- tab, the minimap, a canvas's grid). Text, selection, popups: opaque.
lite_bg_alpha = 1
lite_set_bg_alpha = function(a)
  a = math.max(0, math.min(1, tonumber(a) or 1))
  if a ~= lite_bg_alpha then lite_bg_alpha = a; core.redraw = true end
end
lite_bg = function(c)
  if lite_bg_alpha >= 1 then return c end
  return { c[1], c[2], c[3], math.floor((c[4] or 255) * lite_bg_alpha + 0.5) }
end
do
  local dark
  local function copy(t) local c = {} for i, v in ipairs(t) do c[i] = v end return c end
  lite_theme = function(name)
    local style = require('core.style')
    if not dark then
      dark = { syntax = {} }
      for k, v in pairs(style) do if type(v) == 'table' and type(v[1]) == 'number' then dark[k] = copy(v) end end
      for k, v in pairs(style.syntax) do dark.syntax[k] = copy(v) end
    end
    for k, v in pairs(style) do  -- (a colour the light theme added: gone again)
      if type(v) == 'table' and type(v[1]) == 'number' and not dark[k] then style[k] = nil end
    end
    for k, v in pairs(dark) do if k ~= 'syntax' then style[k] = copy(v) end end
    for k, v in pairs(dark.syntax) do style.syntax[k] = copy(v) end
    if name == 'light' then dofile(DATADIR .. '/data/themes/replay_light.lua') end
    local ok, NT = pcall(require, 'plugins.nodegraph.theme')  -- (the graph's canvas: light too)
    if ok and NT.set_light then NT.set_light(name == 'light') end
    core.redraw = true
  end
end
-- F1 (replay.c: help_open): the help for where you are. In a plugin's tab
-- (projectplugins.plugin_of) whose folder has a HELP.md: that one; else the
-- main help (docs/HELP.md, `main`). In the markdown preview (plugins/markdown).
-- the repo's root (Lite lives in <root>/editor/3rd/lite): runtime/, plugins/, docs/
rawset(_G, 'REPLAY_ROOT', DATADIR .. '/../../..')
-- Ctrl+O's folder: the loaded game's, when it's a folder game (games/<name>/),
-- else games/ (replay_open_prompt: lite's own prompt, when the system has no
-- file dialog)
rawset(_G, 'replay_open_dir', function()
  local f = host_world_file and host_world_file()
  f = f and ('/' .. f:gsub('\\', '/')):gsub('/+$', '')
  local info = f and system.get_file_info(f:sub(2))
  local dir = f and (info and info.type == 'dir' and f:sub(2) or f:match('^/(.*/games/[^/]+)/'))
  dir = dir or (REPLAY_ROOT .. '/games')
  dir = system.absolute_path(dir) or dir
  return (dir:gsub('[/\\]', PATHSEP)) .. PATHSEP
end)
rawset(_G, 'replay_open_prompt', function()
  local common = require 'core.common'
  core.command_view:enter("Open File", function(text)
    core.root_view:open_doc(core.open_doc(text))
  end, common.path_suggest)
end)
lite_help = function(main)
  local file = main
  local ok, pp = pcall(require, 'plugins.projectplugins')
  local name = ok and pp.plugin_of and pp.plugin_of(core.active_view)
  local rec = name and pp.plugins and pp.plugins[name]
  if rec and rec.P and rec.P.dir then
    local h = rec.P.dir .. PATHSEP .. 'HELP.md'
    if system.get_file_info(h) then file = h end
  end
  local ow = package.loaded['plugins.openwith']
  if ow and ow.open('markdown', file) then return file end
  core.root_view:open_doc(core.open_doc(file))
  return file
end
lite_show_log = function()
  local LogView = require('core.logview')
  local found = {}
  local function find(node)
    if node.type == 'leaf' then
      for _, v in ipairs(node.views) do if v:is(LogView) then found[#found + 1] = { node, v } end end
    else find(node.a) find(node.b) end
  end
  find(core.root_view.root_node)
  for i = #found, 2, -1 do
    local n, v = found[i][1], found[i][2]
    n:set_active_view(v)
    n:close_active_view(core.root_view.root_node)
  end
  local node, view = found[1] and found[1][1], found[1] and found[1][2]
  if node then node:set_active_view(view)
  else
    node = core.root_view:get_active_node()
    if node.locked and core.last_active_view then
      core.set_active_view(core.last_active_view)
      node = core.root_view:get_active_node()
    end
    if not node.locked then node:add_view(LogView()) end
  end
  core.redraw = true
end
-- lite_hide_log(): close every Log tab. lite_log_shown(): is one open?
local function log_tabs()
  local LogView, found = require('core.logview'), {}
  local function find(node)
    if node.type == 'leaf' then
      for _, v in ipairs(node.views) do if v:is(LogView) then found[#found + 1] = { node, v } end end
    else find(node.a) find(node.b) end
  end
  find(core.root_view.root_node)
  return found
end
lite_hide_log = function()
  for _, it in ipairs(log_tabs()) do
    it[1]:set_active_view(it[2])
    it[1]:close_active_view(core.root_view.root_node)
  end
  core.redraw = true
end
lite_log_shown = function() return #log_tabs() > 0 end
-- lite_wants_keys(): typing goes to lite (code, the command line, a field
-- being edited in a graph, its menu / picker); else the host may give the
-- keys to the game (mixed view while playing)
lite_wants_keys = function()
  local v = core.active_view
  if not v then return false end
  if v.editing or v.menu or v.picker then return true end
  return v:is(require('core.docview'))
end
-- lite_boot_log(arg): the Log tab at start (1 shown, else hidden; the host
-- decides: command line, then its settings). After the first step: the
-- workspace plugin restores the last session's tabs, a Log tab among them.
lite_boot_log = function(arg)
  if arg == 1 then lite_show_log() else lite_hide_log() end
end
core = require('core')
core.init()
